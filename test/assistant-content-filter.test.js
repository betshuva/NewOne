'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const policy = require('../server/content-filter-policy');
const { assertSenderMediaAllowed, getEffectiveSenderFilter } = require('../server/sender-content-filter');
const { projectFilteredHistory, projectOwnScans, prepareFilterHistoryChange } = require('../server/filter-media-history');

const { DEFAULT_CONTENT_FILTER: ALL, UNFILTERED_ASSISTANT_IDS: ASSISTANTS,
  isUnfilteredAssistantConversation } = policy;
const BLOCKED = { ...ALL, men: false, women: false, children: false,
  video: false, enforceGeneralFilter: true };
const USER = '10000000-0000-4000-8000-000000000001';
const CONTACT = '10000000-0000-4000-8000-000000000002';
const SCAN = '00000000-0000-4000-8000-000000000001';
const MESSAGE = '20000000-0000-4000-8000-000000000001';
const CLASSIFICATION = { detectedCategories: ['men', 'women', 'children'], uncertain: true };
const source = fs.readFileSync(require.resolve('../server/index.js'), 'utf8');

function section(start, end) {
  const from = source.indexOf(start);
  const to = source.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from);
  return source.slice(from, to);
}

function response() {
  return { statusCode: 200, headers: {}, status(code) { this.statusCode = code; return this; },
    set(name, value) { this.headers[name] = value; return this; },
    json(data) { this.data = JSON.parse(JSON.stringify(data)); return this; } };
}

test('only the two exact official assistant IDs have category-unrestricted private conversations', () => {
  for (const assistant of ASSISTANTS) {
    assert.equal(isUnfilteredAssistantConversation(USER, assistant), true);
    assert.equal(isUnfilteredAssistantConversation(assistant, USER), true);
    assert.equal(isUnfilteredAssistantConversation(USER, assistant + '-spoof'), false);
  }
  for (const other of [SCAN, CONTACT, 'Israel Betshuva Guide', 'AI', null, undefined])
    assert.equal(isUnfilteredAssistantConversation(USER, other), false);
});

test('assistant outbound sends skip personal preferences while viewing policy remains scoped', async () => {
  const db = { async query(sql) {
    assert.match(sql, /^SELECT u.content_filter AS general_filter/);
    return { rows: [{ general_filter: BLOCKED, scoped_filter: BLOCKED }] };
  } };
  for (const assistant of ASSISTANTS) {
    for (const [userId, contextId] of [[USER, assistant], [assistant, USER]]) {
      for (const type of ['image', 'video', 'document']) {
        const actual = await assertSenderMediaAllowed(db, { userId,
          contextType: 'chat', contextId, type, classification: CLASSIFICATION });
        assert.equal(actual, null);
      }
    }
    assert.deepEqual(await getEffectiveSenderFilter(db, USER, 'contact', assistant), ALL);
    assert.deepEqual(await getEffectiveSenderFilter(db, USER, 'group', assistant),
      policy.normalizeContentFilter(BLOCKED));
    assert.deepEqual(await getEffectiveSenderFilter(db, USER, 'general', assistant),
      policy.normalizeContentFilter(BLOCKED));
  }
  for (const contextId of [SCAN, CONTACT])
    assert.deepEqual(await getEffectiveSenderFilter(db, USER, 'chat', contextId),
      policy.normalizeContentFilter(BLOCKED));
  await assert.rejects(getEffectiveSenderFilter({ query: async () => ({ rows: [] }) },
    USER, 'chat', ASSISTANTS[0]), { code: 'SENDER_USER_NOT_FOUND' });
});

function apiHarness({ contactExists = true, recipientExists = true } = {}) {
  const routes = {};
  const writes = [];
  const db = { async query(sql) {
    if (sql.startsWith('SELECT u.content_filter, c.filter_override'))
      return { rows: recipientExists ? [{ content_filter: BLOCKED, filter_override: BLOCKED }] : [] };
    if (sql.includes('FROM user_contacts c JOIN users u'))
      return { rows: contactExists ? [{ owner_filter: BLOCKED, filter_override: BLOCKED,
        filter_choice_confirmed: false, has_sent_message: false }] : [] };
    if (sql.includes('AS counterpart_filter_available'))
      return { rows: [{ counterpart_filter_available: false }] };
    if (sql.startsWith('SELECT 1 FROM user_contacts'))
      return { rows: contactExists ? [{ found: 1 }] : [] };
    if (['BEGIN', 'COMMIT', 'ROLLBACK'].includes(sql)) {
      writes.push(sql); return { rows: [] };
    }
    throw new Error('Unexpected SQL: ' + sql);
  }, release() {}, async connect() { return this; } };
  const context = { ...policy, app: {
    get(path, ...handlers) { routes['GET ' + path] = handlers.at(-1); },
    put(path, ...handlers) { routes['PUT ' + path] = handlers.at(-1); },
  }, authWithDbCheck() {}, getPool: async () => db,
  getPhoneSharingStatus: async () => ({ shared: false }),
  applyPhoneSharingChoices: async () => ({ shared: false }),
  phoneSharingChoices: () => ({}), lockFilterOwner: async () => BLOCKED,
  notifyPhoneSharingChange() {}, io: {}, onlineUsers: new Map(),
  prepareFilterHistoryChange() { throw new Error('Assistant settings must not hide or delete history'); },
  };
  vm.runInNewContext(section('async function getEffectiveRecipientFilter(',
    '\nasync function buildGroupDeliveryPlan('), context);
  vm.runInNewContext(section("app.get('/api/contacts/:userId/filter-settings',",
    "\napp.post('/api/contacts/match',"), context);
  return { db, writes, context, async call(method, path, other, body = {}) {
    const res = response();
    await routes[method + ' ' + path]({ user: { id: USER }, params: { userId: other }, body }, res);
    return res;
  } };
}

for (const assistant of ASSISTANTS) {
  test(`official assistant ${assistant.slice(-1)} receiving and comparison endpoints report all allowed without reciprocal approval`, async () => {
    const api = apiHarness();
    const incoming = await api.context.getEffectiveRecipientFilter(api.db, USER, assistant);
    assert.equal(incoming.isContact, true);
    assert.deepEqual({ ...incoming.filter }, ALL);
    const receiving = await api.call('GET', '/api/users/:userId/receiving-filter', assistant);
    assert.equal(receiving.statusCode, 200);
    assert.deepEqual(receiving.data.filter, ALL);
    const settings = await api.call('GET', '/api/contacts/:userId/filter-settings', assistant);
    assert.deepEqual(settings.data.filter, ALL);
    assert.equal(settings.data.requiresChoice, false);
    assert.equal(settings.data.enforceGeneralFilter, false);
    assert.equal(settings.data.filteringDisabled, true);
    const comparison = await api.call('GET', '/api/contacts/:userId/filter-comparison', assistant);
    assert.equal(comparison.statusCode, 200);
    assert.equal(comparison.data.counterpartFilterAvailable, true);
    assert.deepEqual(comparison.data.recipientFilter, ALL);
    assert.deepEqual(comparison.data.personalFilter, ALL);
    for (const body of [{ filter: BLOCKED, existingMediaAction: 'delete' }, { inherit: true }]) {
      const saved = await api.call('PUT', '/api/contacts/:userId/filter-settings', assistant, body);
      assert.equal(saved.statusCode, 200);
      assert.deepEqual(saved.data.filter, ALL);
      assert.equal(saved.data.filteringDisabled, true);
    }
    assert.deepEqual(api.writes, ['BEGIN', 'COMMIT', 'BEGIN', 'COMMIT']);
  });
}

test('ordinary contacts retain restrictive filters and pending comparison privacy', async () => {
  const api = apiHarness();
  const settings = await api.call('GET', '/api/contacts/:userId/filter-settings', CONTACT);
  assert.deepEqual(settings.data.filter, policy.normalizeContentFilter(BLOCKED));
  assert.equal(settings.data.requiresChoice, true);
  assert.equal(settings.data.enforceGeneralFilter, true);
  const comparison = await api.call('GET', '/api/contacts/:userId/filter-comparison', CONTACT);
  assert.equal(comparison.data.counterpartFilterAvailable, false);
  assert.equal(comparison.data.recipientFilter, null);
  assert.deepEqual(comparison.data.personalFilter, policy.normalizeContentFilter(BLOCKED));
});

test('assistant exemptions do not fabricate missing users or contacts', async () => {
  const api = apiHarness({ contactExists: false, recipientExists: false });
  for (const assistant of ASSISTANTS) {
    for (const path of ['/api/contacts/:userId/filter-settings',
      '/api/users/:userId/receiving-filter', '/api/contacts/:userId/filter-comparison'])
      assert.equal((await api.call('GET', path, assistant)).statusCode, 404);
    assert.equal((await api.call('PUT', '/api/contacts/:userId/filter-settings', assistant)).statusCode, 404);
  }
});

test('assistant history bypasses category and prior hide choices, never moderation or deletion', async () => {
  const message = { id: MESSAGE, file_url: '/approved/photo', type: 'image' };
  for (const assistant of ASSISTANTS) {
    for (const [sender_id, recipient_id] of [[USER, assistant], [assistant, USER]]) {
      const row = { id: MESSAGE, sender_id, recipient_id, group_id: null,
        type: 'image', filter: BLOCKED, action: 'hide', classification: CLASSIFICATION,
        moderation_status: 'approved' };
      const db = { query: async () => ({ rows: [row] }) };
      assert.equal((await projectFilteredHistory(db, USER, [message]))[0].file_url, message.file_url);
      row.moderation_status = 'rejected';
      const rejected = (await projectFilteredHistory(db, USER, [message]))[0];
      assert.equal(rejected.file_url, null);
      assert.equal(rejected.hidden_reason, 'moderation');
      row.moderation_status = 'approved'; row.content_purged_at = new Date();
      assert.equal((await projectFilteredHistory(db, USER, [message]))[0].file_url, null);
      row.content_purged_at = null; row.deleted = true;
      assert.equal((await projectFilteredHistory(db, USER, [message])).length, 0);
      row.deleted = false; row.action = 'delete';
      assert.equal((await projectFilteredHistory(db, USER, [message])).length, 0);
      row.action = null; row.group_id = CONTACT;
      assert.equal((await projectFilteredHistory(db, USER, [message], { groupId: CONTACT }))[0].file_url, null);
    }
  }
});

test('general preference tightening cannot hide or delete private assistant image history', async () => {
  const rows = ASSISTANTS.flatMap(assistant => [[USER, assistant], [assistant, USER]]
    .map(([sender_id, recipient_id]) => ({ id: MESSAGE, sender_id, recipient_id,
      group_id: null, general_filter: ALL, contact_filter: null, classification: CLASSIFICATION })));
  const db = { query: async sql => {
    assert.match(sql, /^SELECT m.id,m.group_id/);
    return { rows };
  } };
  const change = await prepareFilterHistoryChange(db, USER, { kind: 'general' }, BLOCKED, 'delete');
  assert.equal(change.affectedCount, 0);
  assert.deepEqual(change.fileIds, []);
});

test('synthetic assistant uploads show only safety-approved previews', async () => {
  const file = { id: MESSAGE, user_id: USER, public_url: '/approved/photo',
    moderation_status: 'approved', moderation_details: { classification: CLASSIFICATION } };
  const db = { query: async sql => {
    if (sql.startsWith('SELECT sf.* FROM stored_files')) return { rows: [file] };
    if (sql.startsWith('SELECT u.content_filter AS general_filter'))
      return { rows: [{ general_filter: BLOCKED, scoped_filter: BLOCKED }] };
    throw new Error('Unexpected SQL: ' + sql);
  } };
  const scan = { id: 'scan_' + MESSAGE, type: 'video', file_url: file.public_url };
  for (const assistant of ASSISTANTS) {
    const opts = { contextType: 'chat', contextId: assistant };
    file.moderation_status = 'approved';
    assert.equal((await projectOwnScans(db, USER, [scan], opts))[0].file_url, file.public_url);
    for (const status of ['pending', 'rejected']) {
      file.moderation_status = status;
      const actual = (await projectOwnScans(db, USER, [scan], opts))[0];
      assert.equal(actual.file_url, null);
      assert.equal(actual.hidden_reason, 'moderation');
    }
  }
});
