'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { assertSenderMediaAllowed } = require('../server/sender-content-filter');
const { contentAllowedByFilter, imageAllowedByFilter } = require('../server/content-filter-policy');
const { recordFilterDecision } = require('../server/filter-audit');
const { resolveAssistantInput } = require('../server/assistant-input');

const source = fs.readFileSync(require.resolve('../server/index.js'), 'utf8');
const ALL = { text: true, video: true, nonHumanImages: true,
  men: true, women: true, children: true };
const MEN = { category: 'men', detectedCategories: ['men'], uncertain: false };
const USER = '20000000-0000-4000-8000-000000000001';
const CONTACT = '20000000-0000-4000-8000-000000000002';
const FILE = '20000000-0000-4000-8000-000000000003';
const BOT = '20000000-0000-4000-8000-000000000004';
const GUIDE = '00000000-0000-4000-8000-000000000002';
const SAFE = '00000000-0000-4000-8000-000000000003';
const MESSAGE = '20000000-0000-4000-8000-000000000005';
const URL = '/uploads/previously-approved-photo.jpg';

function section(startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start + startMarker.length);
  assert.ok(start >= 0 && end > start, `Missing server section: ${startMarker}`);
  return source.slice(start, end);
}

function harness({ own = true, shared = false, men = false, classification = MEN,
  type = 'image', scoped = ALL, enforce = true, recipientFilter = ALL, isContact = true } = {}) {
  const state = {
    general: { ...ALL, men, enforceGeneralFilter: enforce }, scoped, recipientFilter,
    file: { id: FILE, file_type: type, original_name: 'photo.jpg',
      moderation_details: { classification } },
    events: [], queries: [], emitted: [], relayed: [], notices: [], recipientReads: 0,
  };
  const db = {
    async query(sql, values) {
      state.queries.push({ sql, values });
      const normalized = sql.trim();
      if (normalized.startsWith('SELECT file_type FROM stored_files')) return { rows: [state.file] };
      if (normalized.startsWith('SELECT id FROM stored_files')) return { rows: [{id: FILE}] };
      if (normalized.startsWith('SELECT id FROM users')) return { rows: [{ id: USER }] };
      if (normalized.startsWith('INSERT INTO messages')) return { rows: [{ id: MESSAGE, created_at: '2026-09-27T09:00:00Z' }] };
      if (normalized.startsWith('INSERT INTO message_status')) return { rows: [] };
      if (normalized.startsWith('SELECT name FROM users')) return { rows: [{ name: 'Recipient' }] };
      if (normalized.startsWith('SELECT 1 FROM stored_files sf'))
        return { rows: own ? [{ '?column?': 1 }] : [] };
      if (normalized.startsWith('SELECT sf.moderation_details FROM shared_gifs'))
        return { rows: shared ? [{ moderation_details: state.file.moderation_details }] : [] };
      if (normalized.startsWith('SELECT id,file_type,moderation_details FROM stored_files'))
        return { rows: [state.file] };
      if (normalized.startsWith('SELECT file_type,original_name,moderation_details'))
        return { rows: [state.file] };
      if (normalized.startsWith('SELECT moderation_details->'))
        return { rows: [{ classification: state.file.moderation_details.classification }] };
      if (normalized.startsWith('SELECT u.content_filter AS general_filter')) {
        assert.equal(values[0], USER, 'sender, not recipient, determines the added guard');
        return { rows: [{ general_filter: state.general,
          scoped_filter: values[1] === 'general' ? null : state.scoped }] };
      }
      if (normalized.startsWith('SELECT 1 FROM blocked_users')) return { rows: [] };
      if (normalized.startsWith('INSERT INTO filter_audit_events')) {
        state.events.push({ kind: values[0], userId: values[1], actorId: values[2],
          scopeType: values[3], scopeId: values[4], fileId: values[6],
          details: JSON.parse(values[7]) });
        return { rows: [state.events.at(-1)] };
      }
      throw new Error('Unexpected database operation: ' + normalized);
    },
  };
  let socketHandler;
  const socket = { user: { id: USER, name: 'Sender' }, handshake: { address: '127.0.0.1' },
    on(event, handler) { assert.equal(event, 'chat:message'); socketHandler = handler; },
    emit(event, data) { state.emitted.push({ event, data }); },
  };
  const context = vm.createContext({
    ...require('./helpers/system-audit-stubs'),
    assertSenderMediaAllowed, contentAllowedByFilter, imageAllowedByFilter,
    recordFilterDecision, resolveAssistantInput, logActivity() {}, sendPush() {},
    notifyDestinationFilterBlock: async () => {},
    SCAN_BOT_ID: BOT, SYSTEM_USER_ID: GUIDE, SAFE_INFORMATION_USER_ID: SAFE,
    getEffectiveRecipientFilter: async () => {
      state.recipientReads++;
      return { isContact, filter: state.recipientFilter };
    },
    getPool: async () => db,
    notifyRejectedSend: async (pool, notice) => {
      assert.equal(pool, db);
      state.notices.push(notice);
    },
    normalizeBuiltinStickerId: () => null,
    moderateChatText: () => ({ blocked: false }),
    verifyMessageLinks: async () => {},
    teenContactAllowed: async () => true,
    decryptAudioTranscript: () => null,
    allowSocketEvent: () => true,
    relay: (...args) => state.relayed.push(args),
    onlineUsers: new Map(), SYSTEM_USER_NAME: 'Guide', SAFE_INFORMATION_USER_NAME: 'AI',
    createSystemExchange: async (_db, _user, _question, _file, assistantId) => ({
      sent: { id: 'sent', created_at: '2026-09-24T00:00:00Z' },
      reply: { id: 'reply', created_at: '2026-09-24T00:00:00Z' },
      answer: `Reply from ${assistantId}`,
    }),
    console: { error() {}, warn() {} },
    socket,
  });
  // Execute the real functions and real transport handlers. The only mocked
  // boundary is persistence/external effects; removing a guard fails behavior.
  vm.runInContext(section('async function validateApprovedFile(', '\nconst scanLabelNames ='), context);
  vm.runInContext(section('async function resolveSystemInput(', '\nasync function createSystemExchange('), context);
  vm.runInContext(section('async function sendPrivateHttpMessage(', "\napp.post('/api/messages',"), context);
  vm.runInContext(section("  socket.on('chat:message',", "  socket.on('chat:typing',"), context);
  return { state, db, context, validate: (contextType = 'chat', contextId = CONTACT) =>
    context.validateApprovedFile(db, USER, URL, contextType, contextId),
  async http(extra = {}) {
    const response = { statusCode: 200, data: null,
      status(code) { this.statusCode = code; return this; },
      json(data) { this.data = data; return this; } };
    await context.sendPrivateHttpMessage({ user: socket.user, body: {
      toUserId: CONTACT, fileUrl: URL, fileName: 'photo.jpg', fileType: 'image', ...extra,
    } }, response);
    return response;
  },
  socket: extra => socketHandler({ toUserId: CONTACT, fileUrl: URL,
    fileName: 'photo.jpg', fileType: 'image', ...extra }),
  };
}

test('approved owned files and shared GIFs are transferable regardless of sender viewing preferences', async () => {
  for (const options of [{}, { own: false, shared: true }]) {
    const h = harness(options);
    assert.equal(await h.validate(), true);
    assert.equal(h.state.events.length, 0);
  }
  const pending = harness({ own: false, shared: true, isContact: false });
  assert.equal(await pending.validate(), true, 'safe shared GIFs can enter contact approval');
  assert.equal(await harness({ own: false, shared: false }).validate(), false);
});

for (const type of ['image', 'video', 'document']) test(`${type}: real HTTP/socket sends obey recipient, not sender viewing choices`, async () => {
  const h = harness({ type, men: false, enforce: true, scoped: { ...ALL, men: false, video: false } });
  const response = await h.http({ fileType: type });
  assert.equal(response.statusCode, 200, JSON.stringify(response.data));
  assert.equal(response.data.id, MESSAGE);
  await h.socket({ fileType: type });
  assert.equal(h.state.queries.filter(q => /INSERT INTO messages/.test(q.sql)).length, 2);
  assert.equal(h.state.events.length, 0);
  assert.equal(h.state.notices.length, 0);
});

for (const type of ['image', 'video', 'document']) test(`${type}: recipient restriction rejects forged file type on both transports`, async () => {
  const h = harness({ type, recipientFilter: { ...ALL, men: false, video: false } });
  const response = await h.http({ fileType: 'text', fileName: 'misleading.txt', text: 'caption' });
  assert.equal(response.statusCode, 403);
  assert.equal(response.data.code, 'RECIPIENT_CONTENT_FILTERED');
  await h.socket({ fileType: 'text', fileName: 'misleading.txt', text: 'caption' });
  assert.equal(h.state.queries.some(q => /INSERT INTO messages/.test(q.sql)), false);
  assert.equal(h.state.relayed.length, 0);
  assert.equal(h.state.emitted.at(-1).event, 'message:rejected');
  assert.ok(h.state.events.every(event => event.userId === CONTACT && event.details.messageType === type));
});

test('sending an existing approved file to either official assistant ignores category preferences', async () => {
  for (const assistant of [GUIDE, SAFE]) {
    const h = harness();
    const input = await h.context.resolveSystemInput(h.db, USER, assistant,
      { fileUrl: URL, fileName: 'photo.jpg' });
    assert.equal(input.file.url, URL);
    assert.equal(h.state.events.length, 0);
    const response = await h.http({ toUserId: assistant });
    assert.equal(response.statusCode, 200);
    assert.equal(response.data.systemReply.fromUserId, assistant);
    assert.equal(h.state.notices.length, 0);
  }
});

test('official assistant socket sends allow safe files while both transports still reject inaccessible files', async () => {
  for (const assistant of [GUIDE, SAFE]) {
    const socket = harness();
    await socket.socket({ toUserId: assistant });
    assert.equal(socket.state.emitted[0].event, 'chat:message');
    assert.equal(socket.state.emitted[0].data.fromUserId, assistant);
    assert.equal(socket.state.notices.length, 0);
    const inaccessible = harness({ own: false, shared: false });
    assert.equal((await inaccessible.http({ toUserId: assistant })).statusCode, 403);
    await inaccessible.socket({ toUserId: assistant });
    assert.equal(inaccessible.state.emitted[0].event, 'message:rejected');
    assert.equal(inaccessible.state.relayed.length, 0);
  }
});

test('scan bot always uses the sender general policy even when its contact override allows everything', async () => {
  const h = harness({ enforce: false, scoped: ALL });
  await assert.rejects(h.validate('chat', BOT), { code: 'SENDER_CONTENT_FILTERED' });
  assert.equal(h.state.events[0].scopeType, 'general');
  assert.equal(h.state.events[0].scopeId, null);
});

test('recipient changes are checked again while sender changes no longer block sending', async () => {
  const h = harness({ men: true });
  assert.equal((await h.http()).statusCode, 200);
  h.state.general.men = false;
  assert.equal((await h.http()).statusCode, 200);
  h.state.recipientFilter = { ...ALL, men: false };
  assert.equal((await h.http()).statusCode, 403);
});
