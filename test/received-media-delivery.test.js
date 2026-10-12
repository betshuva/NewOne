'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const contentPolicy = require('../server/content-filter-policy');
const source = fs.readFileSync(path.join(__dirname, '../server/index.js'), 'utf8');

function deliveryHelper(personalizeReceivedMessages, errors = [], projectFilteredHistory = async (_db, _user, rows) => rows) {
  const start = source.indexOf('async function recipientMediaMessage(');
  const end = source.indexOf('\nfunction driveMediaCacheTtl(', start);
  return vm.runInNewContext(`(${source.slice(start, end).trim()})`, {
    personalizeReceivedMessages,
    projectFilteredHistory,
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
    ...require('../server/chat-history-window'),
    teenContactAllowed: async () => true,
    messageAfterConversationClear: () => 'TRUE',
    decryptAudioTranscript: () => null,
    projectGuideFilterNotice: row => row,
    SYSTEM_USER_ID: 'guide',
    SAFE_INFORMATION_USER_ID: 'info',
    ...contentPolicy,
    // PIN transactions have dedicated suites. This domain fixture represents
    // an authorized PIN grant while retaining the pending-membership gate.
    async filterPinQuery(db, req, sql, values) {
      assert.equal(db, pool);
      assert.ok(req.user.id);
      assert.match(sql, /WHERE group_id=\$1 AND user_id=\$2 AND status='pending'/);
      return db.query(sql, values);
    },
    async projectFilteredHistory(_db, userId, rows, options = {}) {
      return rows.map(row => options.groupId && row.sender_id !== userId &&
        row.image_classification?.category === 'women'
        ? { ...row, file_url: null, filter_hidden: true } : row);
    },
    // Synthetic scan filtering has its own DB suite; these tests exercise the
    // retention boundary and must provide the history route's dependency.
    async projectOwnScans(_db, _userId, rows) { return rows; },
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
    { kind: 'personalize', userId: 'me', ids: ['allowed', 'blocked'] },
  ]);
  assert.deepEqual(fixture.res.body.map(row => row.id), ['allowed', 'blocked', 'scan_rejected']);
  assert.equal(fixture.res.body[1].file_url, null);
  assert.equal(fixture.res.body[1].filter_hidden, true);
  assert.equal(fixture.res.body[0].file_url, '/personal/me/allowed');
  assert.equal(fixture.res.body[2].file_url, '/own-scan');
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
  assert.equal(notifications.length, 2);
  assert.equal(notifications[0][0], 'contact:phone-sharing');
});


test('a filter lookup failure never exposes the source image', async () => {
  const message={id:'photo',fileUrl:'/sender/photo'};
  const fn=deliveryHelper(async()=>assert.fail('personal copy lookup must not run'),[],
    async()=>{throw new Error('policy unavailable');});
  const result=await fn({},'recipient',message);
  assert.equal(result.fileUrl,null);assert.equal(result.filter_hidden,true);
});

test('a failed personal copy lookup preserves a hidden image decision', async () => {
  const message={id:'photo',fileUrl:'/sender/photo'};
  const fn=deliveryHelper(async()=>{throw new Error('copy unavailable');},[],
    async()=>[{...message,fileUrl:null,filter_hidden:true}]);
  const result=await fn({},'recipient',message);
  assert.equal(result.fileUrl,null);assert.equal(result.filter_hidden,true);
});

test('actual live Unicode text projection checks the receiving filter without a media lookup', async () => {
  const message = { id: 'emoji-text', fromUserId: 'sender', fileType: 'text', text: 'שלום 😉',
    classification: { inlineEmoji: true, category: 'women', detectedCategories: ['women'], uncertain: false } };
  let projections = 0;
  const fn = deliveryHelper(() => assert.fail('Unicode text has no personal media copy'), [],
    async (_db, recipient, rows, options) => {
      projections++; assert.equal(recipient, 'recipient'); assert.equal(options.groupId, null);
      assert.equal(rows[0], message);
      assert.equal(contentPolicy.contentAllowedByFilter({ women: false }, 'text', rows[0].classification), false);
      return [{ ...rows[0], text: null, body: null, filter_hidden: true, hidden_reason: 'content_filter' }];
    });
  const visible = await fn({}, 'recipient', message);
  assert.equal(projections, 1); assert.equal(visible.text, null); assert.equal(visible.body, null);
  assert.equal(visible.filter_hidden, true); assert.equal(message.text, 'שלום 😉');
});

test('allowed live Unicode text keeps its classification and original text without a media lookup', async () => {
  const message = { id: 'emoji-text', text: 'שלום 😉', classification: {
    inlineEmoji: true, category: 'women', detectedCategories: ['women'], uncertain: false } };
  let projections = 0;
  const fn = deliveryHelper(() => assert.fail('text must not query a media copy'), [],
    async (_db, _recipient, rows) => { projections++; return rows; });
  assert.equal(await fn({}, 'recipient', message), message);
  assert.equal(projections, 1);
});

test('Unicode text is fully hidden when the receiving filter lookup fails or returns no row', async () => {
  const message = { id: 'emoji-text', text: 'שלום 😉', body: 'שלום 😉', classification: {
    inlineEmoji: true, category: 'women', detectedCategories: ['women'], uncertain: false } };
  for (const project of [async () => { throw new Error('fixture policy failure'); }, async () => []]) {
    const fn = deliveryHelper(() => assert.fail('hidden text must not query media'), [], project);
    const hidden = await fn({}, 'recipient', message);
    assert.equal(hidden.text, null); assert.equal(hidden.body, null);
    assert.equal(hidden.fileUrl, null); assert.equal(hidden.file_url, null);
    assert.equal(hidden.filter_hidden, true); assert.equal(message.text, 'שלום 😉');
  }
});

test('a disallowed caption is hidden before its otherwise permitted file is personalized', async () => {
  const message = { id: 'caption', groupId: 'group', text: 'כיתוב 😉', body: 'כיתוב 😉',
    fileUrl: '/sender/landscape', fileType: 'image',
    classification: contentPolicy.combineMessageClassifications({ category: 'nonHumanImages',
      detectedCategories: ['nonHumanImages'], uncertain: false }, {
      inlineEmoji: true, category: 'women', detectedCategories: ['women'], uncertain: false }) };
  const fn = deliveryHelper(() => assert.fail('hidden caption must not personalize a file'), [],
    async (_db, _recipient, rows, options) => {
      assert.equal(options.groupId, 'group');
      assert.equal(contentPolicy.contentAllowedByFilter({ women: false }, 'image', rows[0].classification), false);
      return [{ ...rows[0], fileUrl: null, text: null, body: null, filter_hidden: true }];
    });
  const hidden = await fn({}, 'recipient', message);
  assert.equal(hidden.text, null); assert.equal(hidden.body, null); assert.equal(hidden.fileUrl, null);
  assert.equal(hidden.filter_hidden, true); assert.equal(message.fileUrl, '/sender/landscape');
});

test('a permitted caption retains its checked text while switching to the recipient file copy', async () => {
  const message = { id: 'caption', text: 'כיתוב 😉', fileUrl: '/sender/landscape', fileType: 'image',
    classification: { inlineEmoji: true, category: 'women', detectedCategories: ['women'], uncertain: false } };
  let projections = 0;
  const fn = deliveryHelper(async (_db, recipient, rows) => {
    assert.equal(recipient, 'recipient');
    return [{ ...rows[0], fileUrl: '/recipient/landscape' }];
  }, [], async (_db, _recipient, rows) => { projections++; return rows; });
  const result = await fn({}, 'recipient', message);
  assert.equal(projections, 1); assert.equal(result.text, 'כיתוב 😉');
  assert.equal(result.classification.inlineEmoji, true); assert.equal(result.fileUrl, '/recipient/landscape');
  assert.equal(message.fileUrl, '/sender/landscape');
});
