'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const contentPolicy = require('../server/content-filter-policy');
const source = fs.readFileSync(path.join(__dirname, '../server/index.js'), 'utf8');

function deliveryHelper(personalizeReceivedMessages, errors = []) {
  const start = source.indexOf('async function recipientMediaMessage(');
  const end = source.indexOf('\nfunction driveMediaCacheTtl(', start);
  return vm.runInNewContext(`(${source.slice(start, end).trim()})`, {
    personalizeReceivedMessages,
    console: { error(...args) { errors.push(args); } },
  });
}

function historyHandler(method, route, rowSets) {
  let handler;
  const events = [];
  const queries = [];
  const pool = { async query(sql, values) {
    queries.push({ sql, values });
    assert.ok(rowSets.length, 'unexpected database query');
    return { rows: rowSets.shift() };
  } };
  const start = source.indexOf(`app.${method}('${route}',`);
  assert.ok(start > 0);
  const end = source.indexOf('\n});', start) + 5;
  vm.runInNewContext(source.slice(start, end), {
    app: { [method](...args) { handler = args.at(-1); } },
    auth() {},
    getPool: async () => pool,
    teenContactAllowed: async () => true,
    messageAfterConversationClear: () => 'TRUE',
    decryptAudioTranscript: () => null,
    ...contentPolicy,
    async retainVisibleReceivedMessages(db, userId, rows) {
      assert.equal(db, pool);
      events.push({ kind: 'retain', userId, ids: rows.map(row => row.id) });
    },
    async personalizeReceivedMessages(db, userId, rows) {
      assert.equal(db, pool);
      events.push({ kind: 'personalize', userId, ids: rows.map(row => row.id) });
      return rows.map(row => row.sender_id === userId || !row.file_url
        ? row : { ...row, file_url: `/personal/${userId}/${row.id}` });
    },
  });
  const res = {
    statusCode: 200,
    status(code) { this.statusCode = code; return this; },
    json(value) { this.body = JSON.parse(JSON.stringify(value)); return this; },
  };
  return { handler, res, events, queries };
}

test('live text delivery does not query personal media', async () => {
  const personalize = deliveryHelper(() => assert.fail('unexpected media query'));
  const message = { id: 'text', text: 'hello' };
  assert.equal(await personalize({}, 'recipient', message), message);
});

test('live file delivery uses the recipient copy without changing the sender payload', async () => {
  const message = { id: 'photo', fileUrl: '/sender/photo', fileType: 'image' };
  const pool = {};
  const personalize = deliveryHelper(async (db, userId, rows) => {
    assert.equal(db, pool);
    assert.equal(userId, 'recipient');
    assert.equal(rows[0], message);
    return [{ ...rows[0], fileUrl: '/recipient/photo' }];
  });
  assert.equal((await personalize(pool, 'recipient', message)).fileUrl, '/recipient/photo');
  assert.equal(message.fileUrl, '/sender/photo');
});

test('temporary copy lookup failure still delivers the committed source file', async () => {
  const errors = [];
  const message = { id: 'photo', fileUrl: '/sender/photo' };
  const personalize = deliveryHelper(async () => { throw new Error('database busy'); }, errors);
  assert.equal(await personalize({}, 'recipient', message), message);
  assert.equal(errors.length, 1);
});

test('private history retains visible messages without retaining pending or private synthetic entries', async () => {
  const incoming = { id: 'incoming', sender_id: 'friend', type: 'image',
    file_url: '/source/incoming', created_at: '2026-09-01T10:00:00Z' };
  const outgoing = { id: 'outgoing', sender_id: 'me', type: 'image',
    file_url: '/source/outgoing', created_at: '2026-09-01T10:01:00Z' };
  const scan = { id: 'scan_pending', sender_id: 'me', file_url: '/pending',
    message_status: 'pending_scan', created_at: '2026-09-01T10:02:00Z' };
  const request = { id: 'request_pending', sender_id: 'me', file_url: '/request',
    created_at: '2026-09-01T10:03:00Z' };
  const filter = { id: 'private_filter', created_at: '2026-09-01T10:04:00Z' };
  const fixture = historyHandler('get', '/api/messages/:userId',
    [[incoming, outgoing], [scan], [request], [filter]]);
  await fixture.handler({ user: { id: 'me' }, params: { userId: 'friend' }, query: {} }, fixture.res);
  assert.equal(fixture.res.statusCode, 200);
  assert.deepEqual(fixture.events, [
    { kind: 'retain', userId: 'me', ids: ['incoming', 'outgoing'] },
    { kind: 'personalize', userId: 'me', ids: ['incoming', 'outgoing'] },
  ]);
  assert.equal(fixture.res.body[0].file_url, '/personal/me/incoming');
  assert.equal(fixture.res.body[1].file_url, '/source/outgoing');
  assert.equal(fixture.res.body[2].file_url, '/pending');
  assert.equal(fixture.res.body[3].file_url, '/request');
  assert.deepEqual(Array.from(fixture.queries[0].values), ['me', 'friend']);
});

test('group history applies personal content filtering before retention and preserves sender scan state', async () => {
  const allowed = { id: 'allowed', sender_id: 'friend', type: 'image',
    image_classification: { category: 'nonHumanImages' }, file_url: '/allowed',
    created_at: '2026-09-01T10:00:00Z' };
  const blocked = { id: 'blocked', sender_id: 'friend', type: 'image',
    image_classification: { category: 'women' }, file_url: '/blocked',
    created_at: '2026-09-01T10:01:00Z' };
  const ownScan = { id: 'scan_rejected', sender_id: 'me', file_url: '/own-scan',
    message_status: 'rejected_scan', created_at: '2026-09-01T10:02:00Z' };
  const fixture = historyHandler('get', '/api/groups/:id/messages',
    [[{ content_filter: { women: false } }], [allowed, blocked], [ownScan]]);
  await fixture.handler({ user: { id: 'me' }, params: { id: 'group' }, query: {} }, fixture.res);
  assert.equal(fixture.res.statusCode, 200);
  assert.deepEqual(fixture.events, [
    { kind: 'retain', userId: 'me', ids: ['allowed'] },
    { kind: 'personalize', userId: 'me', ids: ['allowed'] },
  ]);
  assert.deepEqual(fixture.res.body.map(row => row.id), ['allowed', 'scan_rejected']);
  assert.equal(fixture.res.body[0].file_url, '/personal/me/allowed');
  assert.equal(fixture.res.body[1].file_url, '/own-scan');
});

test('a nonmember cannot trigger group media retention', async () => {
  const fixture = historyHandler('get', '/api/groups/:id/messages', [[]]);
  await fixture.handler({ user: { id: 'outsider' }, params: { id: 'group' }, query: {} }, fixture.res);
  assert.equal(fixture.res.statusCode, 403);
  assert.equal(fixture.events.length, 0);
});

test('accepting a group invitation retains only missed messages permitted by the accepted filter', async () => {
  const allowed = { id: 'allowed', sender_id: 'friend', type: 'image',
    image_classification: { category: 'nonHumanImages' }, file_url: '/allowed' };
  const blocked = { id: 'blocked', sender_id: 'friend', type: 'image',
    image_classification: { category: 'women' }, file_url: '/blocked' };
  const fixture = historyHandler('post', '/api/groups/:id/join', [
    [{ status: 'pending', pending_since: '2026-09-01T09:00:00Z', content_filter: {} }],
    [], [allowed, blocked],
  ]);
  const notifications = [];
  await fixture.handler({
    user: { id: 'me', name: 'member' }, params: { id: 'group' }, body: { filter: { women: false } },
    app: { get: () => ({ to: () => ({ emit: (...args) => notifications.push(args) }) }) },
  }, fixture.res);
  assert.equal(fixture.res.statusCode, 200);
  assert.deepEqual(fixture.events, [
    { kind: 'retain', userId: 'me', ids: ['allowed'] },
    { kind: 'personalize', userId: 'me', ids: ['allowed'] },
  ]);
  assert.deepEqual(fixture.res.body.missedMessages.map(row => row.id), ['allowed']);
  assert.equal(fixture.res.body.missedMessages[0].file_url, '/personal/me/allowed');
  assert.equal(notifications.length, 1);
});
