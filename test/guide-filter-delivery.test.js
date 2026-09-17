'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const contentPolicy = require('../server/content-filter-policy');
const { shortFilterReason, formatGroupFilterNotice } = require('../server/guide-filter-notice');

const source = fs.readFileSync(require.resolve('../server/index.js'), 'utf8');
const USER = '10000000-0000-4000-8000-000000000001';
const CONTACT = '10000000-0000-4000-8000-000000000002';
const GROUP = '10000000-0000-4000-8000-000000000003';
const GUIDE = '00000000-0000-4000-8000-000000000001';
const FILE = '10000000-0000-4000-8000-000000000004';
const ALLOWED_MEMBER = '10000000-0000-4000-8000-000000000061';
const BLOCKED_MEN = '10000000-0000-4000-8000-000000000062';
const BLOCKED_WOMEN = '10000000-0000-4000-8000-000000000063';
const FILE_URL = '/betshuva-app/uploads/test/approved-photo.png';
const ALL = { text: true, video: true, nonHumanImages: true,
  men: true, women: true, children: true };
const DENY = { ...ALL, text: false, video: false, men: false };
const MEN = { category: 'men', detectedCategories: ['men'], uncertain: false };

function section(startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start + startMarker.length);
  assert.ok(start >= 0 && end > start, `Missing server section: ${startMarker}`);
  return source.slice(start, end);
}

// Exercise the real transport branches, authorization wrapper and approved-file
// validator. Only persistence, sender-policy lookup and notification effects are
// replaced, so an inaccessible URL cannot become accessible through a fixture.
function harness(options = {}) {
  const state = { queries: [], notifications: [], noticeAttempts: [],
    senderChecks: [], rejections: [], relayed: [], writes: [], pushes: [],
    logs: [], events: [], accessible: options.accessible !== false };
  const file = { id: FILE, user_id: USER, public_url: FILE_URL,
    original_name: 'original-server-name.png', file_type: options.recordedType || 'image',
    file_size: 123, moderation_status: options.status || 'approved',
    content_purged_at: options.purged ? '2026-09-18T00:00:00Z' : null,
    moderation_details: { classification: options.classification || MEN } };
  const filter = options.destinationAllowed ? ALL : (options.filter || DENY);
  const rows = value => ({ rows: value });
  async function query(sql, values = [], transaction = false) {
    state.queries.push({ sql, values, transaction });
    const normalized = sql.trim().replace(/\s+/g, ' ');
    if (/^(BEGIN|COMMIT|ROLLBACK|SET LOCAL)/.test(normalized)) return rows([]);
    if (normalized.includes('pg_advisory_xact_lock')) return rows([{}]);
    if (normalized.startsWith('SELECT 1 FROM blocked_users'))
      return rows(options.blockedContact ? [{}] : []);
    if (normalized.startsWith('SELECT 1 FROM stored_files sf'))
      return rows(state.accessible && file.moderation_status === 'approved' ? [{}] : []);
    if (normalized.startsWith('SELECT sf.moderation_details FROM shared_gifs')) return rows([]);
    if (normalized.startsWith("SELECT moderation_details->'classification'"))
      return rows([{ classification: file.moderation_details.classification }]);
    if (normalized.startsWith('SELECT gm.user_id, u.name'))
      return rows(options.groupMembers || (options.partialGroup ? [
        { user_id: ALLOWED_MEMBER, name: 'מקבל מורשה', content_filter: ALL },
        { user_id: BLOCKED_MEN, name: 'חוסם גברים', content_filter: { ...ALL, men: false } },
        { user_id: BLOCKED_WOMEN, name: 'חוסם נשים', content_filter: { ...ALL, women: false } },
      ] : []));
    if (/SELECT .*FROM group_members gm/.test(normalized))
      return rows(options.nonMember ? [] : [{ role: 'member', send_permission: 'all',
        group_name: options.groupName || 'קבוצת בדיקה', content_filter: filter }]);
    if (/SELECT .*FROM stored_files/.test(normalized)) {
      if (options.missingFile) return rows([]);
      if (/moderation_status\s*=\s*'approved'/.test(normalized) && file.moderation_status !== 'approved') return rows([]);
      if (/content_purged_at IS NULL/.test(normalized) && file.content_purged_at) return rows([]);
      return rows([structuredClone(file)]);
    }
    if (/SELECT .*FROM users/.test(normalized)) return rows([{ id: CONTACT, name: 'חבר לדוגמה' }]);
    if (/SELECT .*FROM groups/.test(normalized)) return rows([{ id: GROUP, name: options.groupName || 'קבוצת בדיקה' }]);
    if (normalized.startsWith('SELECT 1 FROM user_contacts')) return rows([{}]);
    if (normalized.startsWith('INSERT INTO messages')) {
      state.writes.push({ sql, values });
      return rows([{ id: '10000000-0000-4000-8000-000000000099',
        created_at: '2026-09-18T00:00:00Z' }]);
    }
    if (normalized.startsWith('UPDATE messages SET delivery_summary') ||
        normalized.startsWith('INSERT INTO message_status')) return rows([]);
    throw new Error(`Unexpected fixture query: ${normalized}`);
  }
  const client = { query: (sql, values) => query(sql, values, true), release() {} };
  const pool = { query: (sql, values) => query(sql, values), connect: async () => client };
  const socketHandlers = {};
  let groupHttp;
  const socket = { user: { id: USER, name: 'השולח', isTeen: false },
    handshake: { address: '127.0.0.1' },
    on(name, handler) { socketHandlers[name] = handler; },
    emit(event, data) { state.rejections.push({ event, data }); } };
  const context = vm.createContext({
    ...contentPolicy, shortFilterReason, formatGroupFilterNotice, console: { error(...args) { state.logs.push(args); }, warn() {} },
    app: { post(_route, ...handlers) { groupHttp = handlers.at(-1); } },
    auth() {}, messageRateLimit() {}, socket, SYSTEM_USER_ID: GUIDE,
    SYSTEM_USER_NAME: 'ישראל מדריך בתשובה', SAFE_INFORMATION_USER_ID: 'safe', SCAN_BOT_ID: 'scan',
    getPool: async () => pool, normalizeBuiltinStickerId: () => null,
    moderateChatText: () => ({ blocked: false }), verifyMessageLinks: async () => {},
    teenContactAllowed: async () => true, allowSocketEvent: () => true,
    clientIp: () => '127.0.0.1', recordBlockedChat() {},
    getStoredImageClassification: async () => file.moderation_details.classification,
    getEffectiveRecipientFilter: async () => ({ isContact: true,
      filter: contentPolicy.normalizeContentFilter(filter) }),
    getGroupContentFilter: async () => contentPolicy.normalizeContentFilter(filter), recordFilterDecision: async () => {},
    assertSenderFileAllowed: async (db, userId, url, kind, target) => {
      state.senderChecks.push({ db, userId, url, kind, target });
      if (options.senderBlocked) throw Object.assign(new Error('sender policy denies image'),
        { code: 'SENDER_CONTENT_FILTERED', status: 403 });
    },
    notifyGuideFilterBlock: async notice => {
      state.noticeAttempts.push(notice);
      state.events.push('guide-notice');
      if (options.noticeFailure) throw new Error('notification database unavailable');
      if (options.revokeDuringNotice) state.accessible = false;
      if (options.changeDuringNotice) Object.assign(file, structuredClone(options.changeDuringNotice));
      assert.equal(typeof notice.authorize, 'function', 'reauthorize before notification transaction writes');
      if (await notice.authorize(client) !== true) return null;
      state.notifications.push(notice);
      return { duplicate: false, fileMessageId: 'guide-file', noticeMessageId: 'guide-reason' };
    },
    onlineUsers: new Map(), relay: (...args) => state.relayed.push(args),
    sendPush: (...args) => state.pushes.push(args), logActivity() {},
    recipientMediaMessage: async (_db, _user, message) => message,
    writeSenderFilteredMedia: async (_db, _options, write) => {
      const saved = await write(pool);
      state.events.push('original-persisted');
      return saved;
    },
  });
  vm.runInContext(section('async function buildGroupDeliveryPlan(', '\nasync function getGroupContentFilter('), context);
  vm.runInContext(section('async function notifyDestinationFilterBlock(', '\nasync function validateApprovedFile('), context);
  vm.runInContext(section('async function validateApprovedFile(', '\nasync function assertSenderFileAllowed('), context);
  vm.runInContext(section('async function sendPrivateHttpMessage(', "\napp.post('/api/messages',"), context);
  vm.runInContext(section("app.post('/api/groups/:id/messages',", "\napp.get('/api/groups/:id/messages',"), context);
  vm.runInContext(section("  socket.on('chat:message',", "  socket.on('chat:typing',"), context);
  vm.runInContext(section("  socket.on('group:message',", "  socket.on('group:typing',"), context);
  return { state, context, pool, async send(transport, group, override = {}) {
    const body = { toUserId: CONTACT, groupId: GROUP, fileUrl: FILE_URL,
      fileName: 'untrusted-client-name.png', fileType: 'image', ...override };
    if (transport === 'socket') {
      await socketHandlers[group ? 'group:message' : 'chat:message'](body);
      return state.rejections.find(event => event.event === 'message:rejected')?.data;
    }
    const response = { statusCode: 200, status(code) { this.statusCode = code; return this; },
      json(data) { this.data = data; return this; } };
    await (group ? groupHttp : context.sendPrivateHttpMessage)(
      { user: socket.user, params: { id: GROUP }, body }, response);
    return response;
  } };
}

for (const transport of ['http', 'socket']) {
  for (const group of [false, true]) {
    const scope = `${transport} ${group ? 'group' : 'private'}`;
    test(`${scope} rejected approved forward sends one sender-only guide notice`, async () => {
      const h = harness();
      const response = await h.send(transport, group);
      if (transport === 'http') assert.equal(response.statusCode, 403);
      else assert.match(response.reason, /חסום/);
      assert.equal(h.state.notifications.length, 1);
      const notice = h.state.notifications[0];
      assert.equal(notice.userId, USER);
      assert.equal(notice.guideUserId, GUIDE);
      assert.equal(notice.targetType, group ? 'group' : 'chat');
      assert.equal(notice.targetId, group ? GROUP : CONTACT);
      assert.equal(notice.fileUrl, FILE_URL);
      assert.equal(notice.fileName, 'original-server-name.png');
      assert.equal(notice.fileType, 'image');
      assert.ok(h.state.senderChecks.length >= 2, 'initial and transaction authorization');
      assert.ok(h.state.queries.some(entry => entry.transaction && /FOR SHARE/.test(entry.sql)));
      assert.equal(h.state.writes.length, 0, 'destination receives no saved message');
      assert.equal(h.state.relayed.length, 0, 'destination receives no realtime message');
    });

    test(`${scope} text remains available with legacy restrictions and creates no guide attachment`, async () => {
      const h = harness();
      const response = await h.send(transport, group,
        { fileUrl: null, fileName: null, fileType: 'text', text: 'ordinary text' });
      if (transport === 'http') assert.equal(response.statusCode, 200);
      else assert.equal(response, undefined);
      assert.equal(h.state.notifications.length, 0);
      assert.equal(h.state.noticeAttempts.length, 0);
      assert.equal(h.state.writes.length, 1);
    });

    test(`${scope} notification failure preserves rejection without delivery`, async () => {
      const h = harness({ noticeFailure: true });
      const response = await h.send(transport, group);
      if (transport === 'http') assert.equal(response.statusCode, 403);
      else assert.match(response.reason, /חסום/);
      assert.equal(h.state.notifications.length, 0);
      assert.equal(h.state.writes.length, 0);
      assert.equal(h.state.relayed.length, 0);
    });
  }
}

for (const [name, options] of Object.entries({
  inaccessible: { accessible: false }, missing: { missingFile: true },
  unsafe: { status: 'rejected' }, pending: { status: 'pending' },
  purged: { purged: true }, senderBlocked: { senderBlocked: true },
})) {
  test(`${name} file never gains access through a guide notice`, async () => {
    const h = harness(options);
    const response = await h.send('http', false);
    assert.equal(response.statusCode, 403);
    assert.equal(h.state.notifications.length, 0);
    assert.equal(h.state.noticeAttempts.length, 0);
    assert.equal(h.state.writes.length, 0);
    assert.equal(h.state.relayed.length, 0);
  });
}

test('access revoked before guide transaction creates no notification or delivery', async () => {
  const h = harness({ revokeDuringNotice: true });
  const response = await h.send('http', false);
  assert.equal(response.statusCode, 403);
  assert.equal(h.state.noticeAttempts.length, 1);
  assert.equal(h.state.notifications.length, 0);
  assert.equal(h.state.writes.length, 0);
});

test('client cannot label an allowed image as blocked video to manufacture a notice', async () => {
  const h = harness({ classification: { category: 'nonHumanImages',
    detectedCategories: ['nonHumanImages'], uncertain: false } });
  const response = await h.send('http', false, { fileType: 'video' });
  assert.equal(response.statusCode, 403);
  assert.equal(h.state.notifications.length, 0);
  assert.equal(h.state.noticeAttempts.length, 0);
});

for (const group of [false, true]) {
  test(`${group ? 'group nonmembership' : 'blocked contact'} does not notify guide`, async () => {
    const h = harness(group ? { nonMember: true } : { blockedContact: true });
    const response = await h.send('http', group);
    assert.equal(response.statusCode, 403);
    assert.equal(h.state.notifications.length, 0);
    assert.equal(h.state.noticeAttempts.length, 0);
  });
}

test('scan/approval failure remains separate from destination-filter guidance', async () => {
  const h = harness({ destinationAllowed: true, accessible: false });
  const response = await h.send('http', false);
  assert.equal(response.statusCode, 403);
  assert.match(response.data.error, /סריקה/);
  assert.equal(h.state.noticeAttempts.length, 0);
  assert.equal(h.state.notifications.length, 0);
});


for (const transport of ['http', 'socket']) {
  test(`${transport} partial group delivery aggregates only blocked members after original persistence`, async () => {
    const h = harness({ destinationAllowed: true, partialGroup: true,
      classification: { category: 'people', detectedCategories: ['men', 'women'], uncertain: false } });
    const response = await h.send(transport, true);
    if (transport === 'http') {
      assert.equal(response.statusCode, 200);
      assert.equal(response.data.deliverySummary.deliveredCount, 1);
      assert.equal(response.data.deliverySummary.blockedCount, 2);
    } else {
      assert.equal(response, undefined);
      const acknowledgement = h.state.rejections.find(event => event.event === 'group:message');
      assert.equal(acknowledgement.data.deliverySummary.deliveredCount, 1);
      assert.equal(acknowledgement.data.deliverySummary.blockedCount, 2);
    }
    assert.equal(h.state.writes.length, 1);
    assert.equal(h.state.notifications.length, 1);
    const notice = h.state.notifications[0];
    assert.equal(notice.userId, USER);
    assert.equal(notice.targetId, GROUP);
    assert.equal(notice.noticeText, 'בקבוצה ״קבוצת בדיקה״ נחסם ל:\n' +
      '• חוסם גברים — תוכן הכולל גברים חסום\n' +
      '• חוסם נשים — תוכן הכולל נשים חסום');
    assert.doesNotMatch(notice.noticeText, /מקבל מורשה/);
    assert.ok(h.state.events.indexOf('original-persisted') < h.state.events.indexOf('guide-notice'));
    const deliveredTargets = h.state.relayed.filter(([, event]) => event === 'group:message').map(([target]) => target);
    assert.ok(deliveredTargets.includes(ALLOWED_MEMBER));
    assert.ok(!deliveredTargets.includes(BLOCKED_MEN));
    assert.ok(!deliveredTargets.includes(BLOCKED_WOMEN));
    assert.ok(h.state.pushes.some(([target, , , data]) => target === USER && data.fromUserId === GUIDE));
  });

  test(`${transport} allowed group delivery does not create a guide warning`, async () => {
    const h = harness({ destinationAllowed: true });
    const response = await h.send(transport, true);
    if (transport === 'http') assert.equal(response.statusCode, 200);
    assert.equal(h.state.writes.length, 1);
    assert.equal(h.state.notifications.length, 0);
    assert.equal(h.state.noticeAttempts.length, 0);
  });
}


for (const [name, change] of Object.entries({
  unsafe: { moderation_status: 'rejected' },
  purged: { content_purged_at: '2026-09-18T00:00:00Z' },
  typeChanged: { file_type: 'video' },
  classificationChanged: { moderation_details: { classification: {
    category: 'nonHumanImages', detectedCategories: ['nonHumanImages'], uncertain: false } } },
})) {
  test(`${name} during transaction recheck cancels stale guide attachment`, async () => {
    const h = harness({ changeDuringNotice: change });
    const response = await h.send('http', false);
    assert.equal(response.statusCode, 403);
    assert.equal(h.state.noticeAttempts.length, 1);
    assert.equal(h.state.notifications.length, 0);
    assert.equal(h.state.writes.length, 0);
    assert.equal(h.state.relayed.length, 0);
  });
}


for (const transport of ['http', 'socket']) {
  test(`${transport} group members with the same reason still receive separate explanation rows`, async () => {
    const h = harness({ destinationAllowed: true, groupMembers: [
      { user_id: ALLOWED_MEMBER, name: 'מקבל מורשה', content_filter: ALL },
      { user_id: BLOCKED_MEN, name: 'דני', content_filter: { ...ALL, men: false } },
      { user_id: BLOCKED_WOMEN, name: 'רוני', content_filter: { ...ALL, men: false } },
    ] });
    const response = await h.send(transport, true);
    if (transport === 'http') assert.equal(response.statusCode, 200);
    assert.equal(h.state.notifications.length, 1);
    assert.equal(h.state.notifications[0].noticeText, 'בקבוצה ״קבוצת בדיקה״ נחסם ל:\n' +
      '• דני — תוכן הכולל גברים חסום\n• רוני — תוכן הכולל גברים חסום');
    assert.equal(h.state.pushes.find(([target]) => target === USER)[2],
      h.state.notifications[0].noticeText);
  });

  test(`${transport} all group members remain listed past eight names and 600 characters`, async () => {
    const members = Array.from({ length: 24 }, (_, index) => ({
      user_id: `20000000-0000-4000-8000-${String(index).padStart(12, '0')}`,
      name: `משתתף מספר ${String(index + 1).padStart(2, '0')} עם שם משפחה ארוך`,
      content_filter: { ...ALL, men: false },
    }));
    const h = harness({ destinationAllowed: true, groupMembers: members });
    const response = await h.send(transport, true);
    if (transport === 'http') assert.equal(response.statusCode, 200);
    const expected = ['בקבוצה ״קבוצת בדיקה״ נחסם ל:',
      ...members.map(member => `• ${member.name} — תוכן הכולל גברים חסום`)].join('\n');
    assert.ok(expected.length > 600);
    assert.equal(h.state.notifications.length, 1);
    assert.equal(h.state.notifications[0].noticeText, expected);
    assert.equal(h.state.notifications[0].noticeText.split('\n').length, 25);
    assert.doesNotMatch(h.state.notifications[0].noticeText, /ועוד \d+ חברים/);
  });
}
