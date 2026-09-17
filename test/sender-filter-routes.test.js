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
const GUIDE = '20000000-0000-4000-8000-000000000005';
const SAFE = '20000000-0000-4000-8000-000000000006';
const URL = '/uploads/previously-approved-photo.jpg';

function section(startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start + startMarker.length);
  assert.ok(start >= 0 && end > start, `Missing server section: ${startMarker}`);
  return source.slice(start, end);
}

function harness({ own = true, shared = false, men = false, classification = MEN,
  type = 'image', scoped = ALL, enforce = true } = {}) {
  const state = {
    general: { ...ALL, men, enforceGeneralFilter: enforce }, scoped,
    file: { id: FILE, file_type: type, original_name: 'photo.jpg',
      moderation_details: { classification } },
    events: [], queries: [], emitted: [], relayed: [], notices: [], recipientReads: 0,
  };
  const db = {
    async query(sql, values) {
      state.queries.push({ sql, values });
      const normalized = sql.trim();
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
    assertSenderMediaAllowed, contentAllowedByFilter, imageAllowedByFilter,
    recordFilterDecision, resolveAssistantInput,
    SCAN_BOT_ID: BOT, SYSTEM_USER_ID: GUIDE, SAFE_INFORMATION_USER_ID: SAFE,
    getEffectiveRecipientFilter: async () => {
      state.recipientReads++;
      return { isContact: true, filter: ALL };
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

function assertBlockedBeforeMessage(h) {
  assert.equal(h.state.events.length, 1);
  assert.equal(h.state.events[0].userId, USER);
  assert.equal(h.state.events[0].details.reasonCode, 'sender_content_filter');
  assert.equal(h.state.queries.some(q => /INSERT INTO messages/.test(q.sql)), false);
  assert.equal(h.state.relayed.length, 0);
}

test('real approved-file validation rejects reuse of an old approved male photo', async () => {
  const h = harness();
  await assert.rejects(h.validate(), { code: 'SENDER_CONTENT_FILTERED', status: 403 });
  assertBlockedBeforeMessage(h);
  assert.equal(h.state.events[0].details.source, 'approved_file_send');
});

test('a file shared through the GIF library still obeys sender filtering', async () => {
  const h = harness({ own: false, shared: true });
  await assert.rejects(h.validate(), { code: 'SENDER_CONTENT_FILTERED' });
  assertBlockedBeforeMessage(h);
  assert.equal(h.state.events[0].details.source, 'shared_gif_send');
});

test('authoritative file approval still permits allowed objects and denies inaccessible files', async () => {
  const objects = harness({ classification: { category: 'nonHumanImages', detectedCategories: ['nonHumanImages'] } });
  assert.equal(await objects.validate(), true);
  assert.equal(objects.state.events.length, 0);
  const inaccessible = harness({ own: false, shared: false });
  assert.equal(await inaccessible.validate(), false);
  assert.equal(inaccessible.state.events.length, 0);
});

test('real HTTP handler rejects sender-blocked media even when the recipient allows it', async () => {
  const h = harness();
  const response = await h.http();
  assert.equal(response.statusCode, 403);
  assert.equal(response.data.code, 'SENDER_CONTENT_FILTERED');
  assert.equal(response.data.blockedBy, 'sender_filter');
  assert.ok(h.state.recipientReads >= 1);
  assert.equal(h.state.notices.length, 1);
  assert.equal(h.state.notices[0].userId, USER);
  assert.equal(h.state.notices[0].toUserId, CONTACT);
  assert.equal(h.state.notices[0].error.code, 'SENDER_CONTENT_FILTERED');
  assertBlockedBeforeMessage(h);
});

test('real HTTP handler cannot disguise an approved male photo as text', async () => {
  const h = harness();
  const response = await h.http({ fileType: 'text', fileName: 'misleading.txt', text: 'caption' });
  assert.equal(response.statusCode, 403);
  assert.equal(response.data.code, 'SENDER_CONTENT_FILTERED');
  assert.equal(h.state.events[0].details.messageType, 'image');
  assertBlockedBeforeMessage(h);
});

test('real socket handler rejects forged media type without relaying it', async () => {
  const h = harness();
  await h.socket({ fileType: 'text', fileName: 'misleading.txt', text: 'caption' });
  assert.equal(h.state.emitted.length, 1);
  assert.equal(h.state.emitted[0].event, 'message:rejected');
  assert.equal(h.state.emitted[0].data.code, 'SENDER_CONTENT_FILTERED');
  assert.equal(h.state.emitted[0].data.blockedBy, 'sender_filter');
  assert.equal(h.state.notices.length, 1);
  assert.equal(h.state.notices[0].userId, USER);
  assertBlockedBeforeMessage(h);
});

test('sending an existing approved file to an assistant uses the same sender guard', async () => {
  const h = harness();
  await assert.rejects(h.context.resolveSystemInput(h.db, USER, GUIDE,
    { fileUrl: URL, fileName: 'photo.jpg' }), { code: 'SENDER_CONTENT_FILTERED' });
  assertBlockedBeforeMessage(h);
  const response = await harness().http({ toUserId: GUIDE });
  assert.equal(response.statusCode, 403);
});

test('sender-blocked assistant sends receive the same private text explanation', async () => {
  const http = harness();
  assert.equal((await http.http({ toUserId: GUIDE })).statusCode, 403);
  assert.equal(http.state.notices.length, 1);
  const socket = harness();
  await socket.socket({ toUserId: GUIDE });
  assert.equal(socket.state.notices.length, 1);
  assert.equal(socket.state.notices[0].userId, USER);
  assert.equal(socket.state.relayed.length, 0);
});

test('scan bot always uses the sender general policy even when its contact override allows everything', async () => {
  const h = harness({ enforce: false, scoped: ALL });
  await assert.rejects(h.validate('chat', BOT), { code: 'SENDER_CONTENT_FILTERED' });
  assert.equal(h.state.events[0].scopeType, 'general');
  assert.equal(h.state.events[0].scopeId, null);
});

test('revalidation after a preference change prevents resending a previously allowed file', async () => {
  const h = harness({ men: true });
  assert.equal(await h.validate(), true);
  h.state.general.men = false;
  await assert.rejects(h.validate(), { code: 'SENDER_CONTENT_FILTERED' });
  assertBlockedBeforeMessage(h);
});
