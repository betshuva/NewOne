'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const vm = require('node:vm');
const sharp = require('sharp');
const crypto = require('node:crypto');
const source = fs.readFileSync(require.resolve('../server/index.js'), 'utf8');
const artwork = require('../server/unicode-emoji-artwork');
const { createUnicodeEmojiModerator } = require('../server/unicode-emoji-moderation');
const contentPolicy = require('../server/content-filter-policy');
const { inlineEmojiModerationText } = require('../server/inline-custom-emoji');
const ALL = { text: true, video: true, nonHumanImages: true, men: true, women: true, children: true };
const WOMEN = { category: 'women', detectedCategories: ['women'], uncertain: false };

function section(startMarker, endMarker) {
  const start = source.indexOf(startMarker), end = source.indexOf(endMarker, start + startMarker.length);
  assert.ok(start >= 0 && end > start, `Missing handler section ${startMarker}`);
  return source.slice(start, end);
}

const moderateChatText = vm.runInNewContext(section('const DEFAULT_FEMALE_LABELS =',
  'function redactHarmfulLanguageForDisplay') + ';moderateChatText', { inlineEmojiModerationText });

function json(value) { return JSON.parse(JSON.stringify(value)); }

async function harness(t, { result = { blocked: false, classification: WOMEN },
  recipientFilter = ALL, groupFilter = ALL, members, editGroup = false, attachment = false } = {}) {
  const directory = await fsp.mkdtemp(path.join(os.tmpdir(), 'betshuva-emoji-routes-'));
  t.after(() => fsp.rm(directory, { recursive: true, force: true }));
  const state = { scans: 0, downloads: 0, queries: [], inserts: [], updates: [],
    emits: [], relays: [], pushes: [], filterDecisions: [], harmfulRecords: [], errors: [],
    hiddenAtDelivery: false, effects: [] };
  const loadArtwork = artwork.createKeyboardEmojiArtworkLoader({ cacheDirectory: directory,
    fetch: async url => {
      state.downloads++;
      const filename = new URL(url).pathname.split('/').at(-1);
      return new Response(await fsp.readFile(path.join(__dirname, 'fixtures', 'keyboard-emoji-artwork', filename)));
    } });
  const inspect = createUnicodeEmojiModerator({ extractEmoji: artwork.extractKeyboardEmoji,
    loadArtwork, moderationVersion: 'fixture-moderation', artworkVersion: artwork.ARTWORK_VERSION,
    scanImage: async (bytes, options) => {
      const metadata = await sharp(bytes).metadata();
      assert.equal(metadata.format, 'png'); assert.equal(metadata.width, 128);
      assert.equal(options.tracking.userId, 'sender');
      state.scans++; return structuredClone(result);
    } }).inspect;
  const current = { id: 'message-1', sender_id: 'sender', recipient_id: editGroup ? null : 'recipient',
    group_id: editGroup ? 'group' : null, type: 'text', body: 'old message',
    delivery_summary: { priorDeliveryFlag: true } };
  const pool = { async query(sql, values = []) {
    state.queries.push({ sql, values });
    const normalized = sql.trim();
    if (normalized.startsWith('INSERT INTO messages')) {
      state.inserts.push({ sql, values });
      return { rows: [{ id: 'message-1', created_at: '2026-10-13T00:00:00Z' }] };
    }
    if (normalized.startsWith('UPDATE messages')) {
      state.updates.push({ sql, values }); return { rows: [{ ...current }] };
    }
    if (normalized.includes('FROM messages WHERE id=')) return { rows: [{ ...current }] };
    if (normalized.startsWith('SELECT 1 FROM blocked_users') || normalized.startsWith('INSERT INTO message_status'))
      return { rows: [] };
    if (normalized.startsWith('SELECT file_type FROM stored_files')) return { rows: [{ file_type: 'image' }] };
    if (normalized.startsWith('SELECT name FROM users')) return { rows: [{ name: 'Recipient' }] };
    if (normalized.startsWith('SELECT name FROM groups')) return { rows: [{ name: 'Group' }] };
    if (normalized.startsWith('SELECT gm.role')) return { rows: [{ role: 'member', send_permission: 'all', group_name: 'Group' }] };
    if (normalized.includes('FROM group_members gm') && normalized.includes('gm.user_id<>'))
      return { rows: members || [{ user_id: 'recipient', name: 'Recipient', content_filter: recipientFilter }] };
    if (normalized.startsWith('SELECT user_id FROM group_members'))
      return { rows: members || [{ user_id: 'recipient', name: 'Recipient', content_filter: recipientFilter }] };
    throw new Error('Unexpected fixture query: ' + normalized);
  } };
  const callbacks = new Map(), httpRoutes = new Map();
  const socket = { user: { id: 'sender', name: 'Sender' }, handshake: { address: '127.0.0.1' },
    on(event, handler) { callbacks.set(event, handler); },
    emit(event, payload) { state.emits.push({ event, payload }); } };
  const context = vm.createContext({
    ...require('./helpers/system-audit-stubs'), ...contentPolicy,
    ...artwork, createUnicodeEmojiModerator, crypto, Buffer,
    SYSTEM_USER_ID: 'guide', SAFE_INFORMATION_USER_ID: 'safe', SCAN_BOT_ID: 'scan',
    MODERATION_CACHE_VERSION: 'fixture-moderation',
    getPool: async () => pool, socket,
    app: { patch(route, ...handlers) { httpRoutes.set(route, handlers.at(-1)); } }, auth() {},
    normalizeBuiltinStickerId: () => null, moderateChatText,
    verifyMessageLinks: async () => {}, teenContactAllowed: async () => true,
    recordBlockedChat: (...args) => state.harmfulRecords.push(args), clientIp: () => '127.0.0.1',
    allowSocketEvent: () => true,
    getStoredImageClassification: async (_db, fileUrl) => fileUrl ? {
      category: 'nonHumanImages', detectedCategories: ['nonHumanImages'], uncertain: false,
    } : null,
    validateApprovedFile: async () => true,
    getEffectiveRecipientFilter: async () => ({ isContact: true, filter: recipientFilter }),
    getGroupContentFilter: async () => groupFilter,
    recordFilterDecision: async (_db, event) => state.filterDecisions.push(event),
    notifyDestinationFilterBlock: async () => {}, notifyGroupFilterBlocks: async () => {},
    writeSenderFilteredMedia: async (db, _options, write) => write(db),
    recipientMediaMessage: async (_pool, _user, message) => state.hiddenAtDelivery
      ? { ...message, text: null, body: null, fileUrl: null, file_url: null,
        filter_hidden: true, hidden_reason: 'content_filter' } : message,
    onlineUsers: new Map([['recipient', 'recipient-socket']]),
    io: { to: target => ({ emit: (event, payload) => state.emits.push({ target, event, payload }) }) },
    relay: (target, event, payload) => state.relays.push({ target, event, payload }),
    sendPush: (...args) => state.pushes.push(args), logActivity() {},
    shortFilterReason: () => 'fixture destination blocked',
    inspectUnicodeEmojiText: (text, userId) => inspect(text, { userId }),
    console: { warn() {}, error: (...args) => state.errors.push(args) },
  });
  // Execute the actual HTTP preparation helper once the gateway patch exists,
  // so these tests exercise its request field contract as well as the routes.
  vm.runInContext(section('async function prepareUnicodeEmojiMessage(',
    '\nfunction redactHarmfulLanguageForDisplay('), context);
  vm.runInContext(section('async function buildGroupDeliveryPlan(',
    '\nasync function getGroupContentFilter('), context);
  vm.runInContext(section('async function sendPrivateHttpMessage(',
    "\napp.post('/api/messages',"), context);
  vm.runInContext(section('async function sendGroupHttpMessage(',
    "\napp.get('/api/groups/:id/messages',"), context);
  vm.runInContext(section("  socket.on('chat:message',", "  socket.on('chat:typing',"), context);
  vm.runInContext(section("  socket.on('group:message',", "  socket.on('group:typing',"), context);
  vm.runInContext(section("app.patch('/api/messages/:id',", "\napp.delete('/api/contacts/:userId/friendship',"), context);

  async function send(transport, text = 'שלום 😉', { deferred = false } = {}) {
    const file = attachment ? { fileUrl: '/fixture/approved-landscape.png',
      fileName: 'landscape.png', fileType: 'image' } : {};
    if (transport === 'private_socket' || transport === 'group_socket') {
      const payload = transport === 'private_socket' ? { toUserId: 'recipient', text, ...file }
        : { groupId: 'group', clientMessageId: 'client-1', text, ...file };
      await callbacks.get(transport === 'private_socket' ? 'chat:message' : 'group:message')(payload);
      return null;
    }
    const response = { statusCode: 200, status(code) { this.statusCode = code; return this; },
      json(body) { this.body = body; return this; } };
    const req = { user: socket.user, params: { id: transport === 'edit' ? 'message-1' : 'group' },
      body: transport === 'edit' ? { body: text } : { toUserId: 'recipient', text, ...file }, ip: '127.0.0.1' };
    if (deferred) req.messageEffects = state.effects;
    if (transport === 'private_http') await context.sendPrivateHttpMessage(req, response);
    else if (transport === 'group_http') await context.sendGroupHttpMessage(req, response);
    else await httpRoutes.get('/api/messages/:id')(req, response);
    return response;
  }
  return { state, send, prepare: req => context.prepareUnicodeEmojiMessage(req) };
}

test('private HTTP effects recheck a newly hidden Unicode message before realtime emission and push', async t => {
  const h = await harness(t), text = 'פרטי 😉';
  const response = await h.send('private_http', text, { deferred: true });
  assert.equal(response.statusCode, 200); assert.equal(h.state.inserts.length, 1);
  assert.equal(h.state.emits.length, 0); assert.equal(h.state.pushes.length, 0);
  h.state.hiddenAtDelivery = true;
  for (const effect of h.state.effects) await effect();
  const realtime = h.state.emits.find(event => event.event === 'chat:message');
  assert.ok(realtime); assert.equal(realtime.payload.filter_hidden, true);
  assert.equal(realtime.payload.text, null); assert.equal(realtime.payload.body, null);
  assert.equal(h.state.pushes.length, 0, 'a late preference change must not leak text in push');
  assert.equal(h.state.inserts[0].values[2], text, 'the sender retains their original message');
});

test('private HTTP caption effects do not push hidden text or media after a late preference change', async t => {
  const h = await harness(t, { attachment: true });
  const response = await h.send('private_http', 'כיתוב 😉', { deferred: true });
  assert.equal(response.statusCode, 200);
  h.state.hiddenAtDelivery = true;
  for (const effect of h.state.effects) await effect();
  const realtime = h.state.emits.find(event => event.event === 'chat:message');
  assert.equal(realtime.payload.text, null); assert.equal(realtime.payload.fileUrl, null);
  assert.equal(h.state.pushes.length, 0);
});

for (const transport of ['private_http', 'group_http'])
  test(`${transport}: forwarding through the send API reuses a scan but rechecks current destination policy`, async t => {
    const recipientFilter = { ...ALL }, groupFilter = { ...ALL };
    const h = await harness(t, { recipientFilter, groupFilter });
    const first = await h.send(transport, 'הודעה מקורית 😉');
    assert.equal(first.statusCode, 200); assert.equal(h.state.scans, 1);
    assert.equal(h.state.inserts.length, 1);
    recipientFilter.women = false; groupFilter.women = false;
    const forwarded = await h.send(transport, 'הודעה מקורית 😉');
    assert.equal(forwarded.statusCode, 403);
    assert.equal(h.state.inserts.length, 1, 'a fresh destination check must block the forwarded copy');
    assert.equal(h.state.scans, 1, 'forwarding must not duplicate the immutable glyph scan');
  });

const transports = ['private_http', 'group_http', 'private_socket', 'group_socket', 'edit'];
for (const transport of transports) {
  for (const [name, result, code, status] of [
    ['blocked', { blocked: true, blockedBy: 'fixture' }, 'EMOJI_CONTENT_BLOCKED', 422],
    ['pending', { pending: true, classification: WOMEN }, 'EMOJI_SCAN_PENDING', 503],
  ]) test(`${transport}: ${name} emoji prevents message persistence`, async t => {
    const h = await harness(t, { result });
    const response = await h.send(transport);
    assert.equal(h.state.scans, 1);
    assert.equal(h.state.inserts.length, 0); assert.equal(h.state.updates.length, 0);
    assert.equal(h.state.relays.length, 0); assert.equal(h.state.pushes.length, 0);
    assert.equal(h.state.harmfulRecords.length, 0, 'visual scan failure is not harmful-language abuse');
    if (response) { assert.equal(response.statusCode, status); assert.equal(response.body.code, code); }
    else {
      const rejection = h.state.emits.find(event => event.event === 'message:rejected');
      assert.ok(rejection); assert.equal(rejection.payload.code, code);
    }
  });

  test(`${transport}: approved catalog keyboard emoji use the existing text path without a provider`, async t => {
    const h = await harness(t), response = await h.send(transport, 'שלום 😀 👍🏽');
    assert.equal(h.state.scans, 0); assert.equal(h.state.downloads, 0);
    if (response) assert.equal(response.statusCode, 200, JSON.stringify(response.body));
    assert.equal(h.state.inserts.length + h.state.updates.filter(write => /SET body=/.test(write.sql)).length, 1);
    assert.deepEqual(h.state.errors, []);
  });
}

for (const transport of transports) {
  test(`${transport}: visually checked emoji retain original text and persist their classification`, async t => {
    const h = await harness(t), text = 'שלום 😉', response = await h.send(transport, text);
    if (response) assert.equal(response.statusCode, 200, JSON.stringify(response.body));
    assert.equal(h.state.scans, 1);
    if (transport === 'edit') {
      assert.equal(h.state.inserts.length, 0);
      assert.equal(h.state.updates.find(write => /SET body=/.test(write.sql)).values[0], text);
    } else {
      assert.equal(h.state.inserts.length, 1);
      assert.equal(h.state.inserts[0].values[2], text);
    }
    const summaries = [...h.state.inserts, ...h.state.updates].flatMap(write => write.values)
      .filter(value => typeof value === 'string' && value.includes('inlineEmojiClassification'))
      .map(value => JSON.parse(value));
    assert.ok(summaries.length > 0, 'approved glyph classification must survive persistence');
    const summary = summaries.find(value => value.inlineEmojiClassification);
    assert.equal(summary.inlineEmojiClassification.inlineEmoji, true);
    assert.deepEqual(json(summary.inlineEmojiClassification.detectedCategories), ['women']);
    if (transport !== 'edit') {
      const realtime = [...h.state.emits, ...h.state.relays].find(event => event.target &&
        event.target !== 'sender' && ['chat:message', 'group:message'].includes(event.event));
      assert.ok(realtime, 'approved messages must reach their intended online recipient');
      assert.equal(realtime.payload.classification.inlineEmoji, true);
      assert.equal(realtime.payload.text, text);
    }
    assert.deepEqual(h.state.errors, []);
  });
}

test('HTTP preflight reuses a result only for the same complete visible text', async t => {
  const h = await harness(t), req = { user: { id: 'sender' }, body: { text: 'שלום 😉' } };
  const first = await h.prepare(req);
  assert.equal(h.state.scans, 1);
  assert.deepEqual(json(await h.prepare(req)), json(first));
  assert.equal(h.state.scans, 1);
  req.body.text = 'שלום 😞';
  const second = await h.prepare(req);
  assert.equal(h.state.scans, 2);
  assert.notEqual(second.artworkHash, first.artworkHash);
});

for (const [description, options] of [
  ['private recipient', { recipientFilter: { ...ALL, women: false } }],
  ['group', { editGroup: true, groupFilter: { ...ALL, women: false } }],
]) test(`edit: the ${description} policy prevents replacing text with a restricted emoji`, async t => {
  const h = await harness(t, options), response = await h.send('edit');
  assert.equal(h.state.scans, 1);
  assert.equal(response.statusCode, 403, JSON.stringify(response.body));
  assert.equal(h.state.inserts.length, 0); assert.equal(h.state.updates.length, 0);
});

for (const transport of ['private_http', 'private_socket'])
  test(`${transport}: receiver category preferences still reject an otherwise approved emoji`, async t => {
    const h = await harness(t, { recipientFilter: { ...ALL, women: false } });
    const response = await h.send(transport);
    assert.equal(h.state.scans, 1); assert.equal(h.state.inserts.length, 0);
    assert.equal(h.state.relays.length, 0); assert.equal(h.state.pushes.length, 0);
    if (response) assert.equal(response.statusCode, 403);
    else assert.ok(h.state.emits.some(event => event.event === 'message:rejected'));
  });

for (const transport of ['group_http', 'group_socket']) {
  test(`${transport}: group category preferences reject an otherwise approved emoji`, async t => {
    const h = await harness(t, { groupFilter: { ...ALL, women: false } });
    const response = await h.send(transport);
    assert.equal(h.state.scans, 1); assert.equal(h.state.inserts.length, 0);
    if (response) assert.equal(response.statusCode, 403);
    else assert.ok(h.state.emits.some(event => event.event === 'message:rejected'));
  });

  test(`${transport}: group delivery applies each recipient filter independently`, async t => {
    const h = await harness(t, { members: [
      { user_id: 'allowed', name: 'Allowed', content_filter: ALL },
      { user_id: 'restricted', name: 'Restricted', content_filter: { ...ALL, women: false } },
    ] });
    const response = await h.send(transport);
    if (response) assert.equal(response.statusCode, 200);
    assert.equal(h.state.inserts.length, 1);
    assert.ok(h.state.relays.some(event => event.target === 'allowed'));
    assert.equal(h.state.relays.some(event => event.target === 'restricted'), false);
    assert.equal(h.state.pushes.some(args => args[0] === 'restricted'), false);
    const summary = h.state.updates.map(write => write.values[0]).filter(value => typeof value === 'string')
      .map(value => JSON.parse(value)).find(value => value.deliveredCount !== undefined);
    assert.equal(summary.deliveredCount, 1); assert.equal(summary.blockedCount, 1);
  });
}

for (const transport of transports)
  test(`${transport}: harmful text is blocked before scanning an unfamiliar accompanying emoji`, async t => {
    const h = await harness(t), response = await h.send(transport, 'טמבל 😉');
    assert.equal(h.state.scans, 0); assert.equal(h.state.inserts.length, 0); assert.equal(h.state.updates.length, 0);
    assert.equal(h.state.harmfulRecords.length, 1);
    if (response) assert.equal(response.body.code, 'CHAT_CONTENT_BLOCKED');
    else assert.equal(h.state.emits.find(event => event.event === 'message:rejected').payload.code, 'CHAT_CONTENT_BLOCKED');
  });

for (const transport of transports.filter(value => value !== 'edit')) {
  test(`${transport}: an allowed landscape cannot hide a restricted emoji in its caption`, async t => {
    const restriction = transport.startsWith('private')
      ? { recipientFilter: { ...ALL, women: false } } : { groupFilter: { ...ALL, women: false } };
    const h = await harness(t, { attachment: true, ...restriction });
    const response = await h.send(transport);
    assert.equal(h.state.scans, 1);
    assert.equal(h.state.inserts.length, 0); assert.equal(h.state.updates.length, 0);
    assert.equal(h.state.relays.length, 0); assert.equal(h.state.pushes.length, 0);
    if (response) assert.equal(response.statusCode, 403, JSON.stringify(response.body));
    else assert.ok(h.state.emits.some(event => event.event === 'message:rejected'));
  });

  test(`${transport}: approved image captions persist their own emoji classification`, async t => {
    const h = await harness(t, { attachment: true }), text = 'כיתוב 😉';
    const response = await h.send(transport, text);
    if (response) assert.equal(response.statusCode, 200, JSON.stringify(response.body));
    assert.equal(h.state.scans, 1); assert.equal(h.state.inserts.length, 1);
    assert.equal(h.state.inserts[0].values[2], text);
    assert.equal(h.state.inserts[0].values[3], 'image', 'emoji must not replace the attachment type');
    const summaries = [...h.state.inserts, ...h.state.updates].flatMap(write => write.values)
      .filter(value => typeof value === 'string' && value.includes('inlineEmojiClassification'))
      .map(value => JSON.parse(value));
    const summary = summaries.find(value => value.inlineEmojiClassification);
    assert.ok(summary, 'caption classification must survive attachment persistence');
    assert.equal(summary.inlineEmojiClassification.inlineEmoji, true);
    assert.deepEqual(json(summary.inlineEmojiClassification.detectedCategories), ['women']);
    assert.deepEqual(h.state.errors, []);
  });
}

for (const transport of ['group_http', 'group_socket'])
  test(`${transport}: attachment captions also obey each group recipient's emoji preferences`, async t => {
    const h = await harness(t, { attachment: true, members: [
      { user_id: 'allowed', name: 'Allowed', content_filter: ALL },
      { user_id: 'restricted', name: 'Restricted', content_filter: { ...ALL, women: false } },
    ] });
    const response = await h.send(transport);
    if (response) assert.equal(response.statusCode, 200, JSON.stringify(response.body));
    assert.equal(h.state.inserts.length, 1);
    assert.ok(h.state.relays.some(event => event.target === 'allowed'));
    assert.equal(h.state.relays.some(event => event.target === 'restricted'), false);
    assert.equal(h.state.pushes.some(args => args[0] === 'restricted'), false);
  });
