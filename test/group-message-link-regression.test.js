const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const server = fs.readFileSync(path.join(__dirname, '..', 'server', 'index.js'), 'utf8');
const start = server.indexOf("  socket.on('group:message',");
const end = server.indexOf("  socket.on('group:typing',", start);
assert.ok(start >= 0 && end > start, 'group message handler must be present');
const handlerSource = server.slice(start, end);

function groupHarness({ isTeen = false, member = { role: 'member', send_permission: 'all' }, linkError } = {}) {
  const events = [];
  const verified = [];
  const queries = [];
  const errors = [];
  const pool = {
    async query(sql, values) {
      queries.push({ sql, values });
      if (sql.includes('FROM group_members')) return { rows: member ? [member] : [] };
      if (sql.includes('INSERT INTO messages')) {
        return { rows: [{ id: 'message-1', created_at: '2026-09-09T00:00:00Z' }] };
      }
      if (sql.startsWith('UPDATE messages SET delivery_summary')) return { rows: [] };
      if (sql.startsWith('SELECT name FROM groups')) return { rows: [{ name: 'Test group' }] };
      throw new Error(`Unexpected query: ${sql}`);
    },
  };
  let handler;
  const socket = {
    user: { id: 'sender-1', name: 'Test sender', isTeen },
    handshake: { address: '127.0.0.1' },
    on(event, callback) {
      assert.equal(event, 'group:message');
      handler = callback;
    },
    emit(event, payload) { events.push({ event, payload }); },
  };
  vm.runInNewContext(handlerSource, {
    socket,
    normalizeBuiltinStickerId: () => null,
    allowSocketEvent: () => true,
    moderateChatText: () => ({ blocked: false }),
    recordBlockedChat: () => assert.fail('ordinary test text should not be blocked'),
    async verifyMessageLinks(text) {
      verified.push(text);
      if (linkError) throw linkError;
    },
    LINK_BLOCKED_MESSAGE: 'unsafe link blocked',
    getPool: async () => pool,
    getGroupContentFilter: async () => 'general',
    contentAllowedByFilter: () => true,
    buildGroupDeliveryPlan: async () => ({ summary: { total: 0 }, delivered: [] }),
    logActivity: () => {},
    relay: () => assert.fail('no external recipients in this test'),
    sendPush: () => assert.fail('no external recipients in this test'),
    console: { warn() {}, error(...args) { errors.push(args); } },
  });
  return {
    events, verified, queries, errors,
    send: text => handler({ groupId: 'group-1', clientMessageId: 'client-1', text }),
  };
}

test('ordinary group text is checked, persisted and acknowledged without a private recipient', async () => {
  const harness = groupHarness();
  await harness.send('שלום לכולם');

  assert.deepEqual(harness.errors, []);
  assert.deepEqual(harness.verified, ['שלום לכולם']);
  const saved = harness.queries.find(query => query.sql.includes('INSERT INTO messages'));
  assert.ok(saved, 'normal group messages must reach persistence');
  assert.equal(saved.values[0], 'sender-1');
  assert.equal(saved.values[1], 'group-1');
  assert.equal(saved.values[2], 'שלום לכולם');
  assert.equal(harness.events.length, 1);
  assert.equal(harness.events[0].event, 'group:message');
  assert.equal(harness.events[0].payload.id, 'message-1');
  assert.equal(harness.events[0].payload.clientMessageId, 'client-1');
});

test('unsafe links still reject the group message before database access', async () => {
  const harness = groupHarness({ linkError: new Error('unsafe URL') });
  await harness.send('https://unsafe.example.test');

  assert.deepEqual(harness.errors, []);
  assert.deepEqual(harness.verified, ['https://unsafe.example.test']);
  assert.equal(harness.queries.length, 0);
  assert.equal(harness.events.length, 1);
  assert.equal(harness.events[0].event, 'message:rejected');
  assert.equal(harness.events[0].payload.groupId, 'group-1');
  assert.equal(harness.events[0].payload.clientMessageId, 'client-1');
  assert.equal(harness.events[0].payload.reason, 'unsafe link blocked');
});

test('teen group restriction still rejects messages before checking links or using the database', async () => {
  const harness = groupHarness({ isTeen: true });
  await harness.send('שלום');

  assert.deepEqual(harness.errors, []);
  assert.equal(harness.verified.length, 0);
  assert.equal(harness.queries.length, 0);
  assert.equal(harness.events.length, 1);
  assert.equal(harness.events[0].event, 'message:rejected');
  assert.match(harness.events[0].payload.reason, /נוער/);
});

for (const [description, member] of [
  ['nonmembers', null],
  ['nonadmins in an admin-only group', { role: 'member', send_permission: 'admin' }],
]) {
  test(`group permissions still prevent persistence for ${description}`, async () => {
    const harness = groupHarness({ member });
    await harness.send('שלום');

    assert.deepEqual(harness.errors, []);
    assert.equal(harness.queries.length, 1);
    assert.match(harness.queries[0].sql, /FROM group_members/);
    assert.equal(harness.events.length, 0);
  });
}
