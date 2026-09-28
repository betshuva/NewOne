'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { previewForPolicy, loadForwardFilterPreview, registerForwardFilterPreview } = require('../server/forward-filter-preview');
const { DEFAULT_CONTENT_FILTER: all, resolveScopedContentFilter } = require('../server/content-filter-policy');
const sender = '00000000-0000-4000-8000-000000000010';
const recipient = '00000000-0000-4000-8000-000000000011';
const group = '00000000-0000-4000-8000-000000000012';
const image = { known: true, type: 'image', classification: { detectedCategories: ['men', 'children'] } };

test('mixed selections report the blocked count and only the restricted categories', () => {
  const result = previewForPolicy({ ...all, children: false }, [image, { known: true, type: 'text' }], 'user');
  assert.equal(result.status, 'blocked');
  assert.equal(result.blockedCount, 1);
  assert.match(result.reason, /1 מתוך 2/);
  assert.match(result.reason, /ילדים/);
  assert.doesNotMatch(result.reason, /גברים/);
  assert.equal(previewForPolicy(all, [image], 'user').status, 'allowed');
});

test('video, uncertain images, non-human images and enforced overrides match delivery policy', () => {
  assert.match(previewForPolicy({ ...all, video: false }, [{ known: false, type: 'video' }], 'group').reason, /סרטונים חסומים.*הקבוצה/);
  assert.equal(previewForPolicy(all, [{ known: false, type: 'image' }], 'user').status, 'unknown');
  assert.equal(previewForPolicy({ ...all, women: false }, [{ known: true, type: 'image', classification: { uncertain: true } }], 'user').status, 'blocked');
  assert.equal(previewForPolicy({ ...all, women: false, men: false }, [{ known: true, type: 'image', classification: { category: 'nonHumanImages' } }], 'user').status, 'allowed');
  const enforced = resolveScopedContentFilter({ ...all, children: false, enforceGeneralFilter: true }, all);
  assert.equal(previewForPolicy(enforced, [image], 'user').status, 'blocked');
});

function database({ files = [], users = [], groups = [] } = {}) {
  const queries = [];
  return { queries, async query(sql) {
    queries.push(sql);
    assert.match(sql.trim(), /^SELECT/); // Opening the picker never sends or records a rejection.
    if (sql.includes('FROM stored_files sf')) return { rows: files };
    if (sql.includes('FROM users u LEFT JOIN')) return { rows: users };
    if (sql.includes('FROM groups g JOIN')) return { rows: groups };
    assert.fail('unexpected query');
  } };
}

test('batch uses authorized stored classification, ignores client claims and honors scoped receiving rules', async () => {
  const db = database({
    files: [{ public_url: '/image', file_type: 'image', classification: image.classification }],
    users: [{ id: recipient, is_contact: true, content_filter: all, filter_override: { children: false } }],
    groups: [{ id: group, content_filter: all }],
  });
  const results = await loadForwardFilterPreview(db, sender,
    [{ fileUrl: '/image', fileType: 'text', classification: { category: 'nonHumanImages' } }],
    [{ kind: 'user', id: recipient }, { kind: 'group', id: group }]);
  assert.equal(results[0].status, 'blocked');
  assert.equal(results[1].status, 'allowed');
  assert.match(db.queries[0], /sf.user_id=\$1/);
  assert.match(db.queries[0], /sf.moderation_status='approved'/);
  assert.match(db.queries[0], /sf.content_purged_at IS NULL/);
  assert.match(db.queries[2], /gm.status='member'/);
});

test('missing media and inaccessible groups stay unknown; non-contacts do not disclose filter policy', async () => {
  const db = database({ users: [{ id: recipient, is_contact: false, content_filter: { ...all, children: false } }] });
  const results = await loadForwardFilterPreview(db, sender, [{ fileUrl: '/private', fileType: 'image' }],
    [{ kind: 'user', id: recipient }, { kind: 'group', id: group }]);
  assert.ok(results.every(r => r.status === 'unknown'));
  assert.match(results[0].reason, /בקשת הקשר/);
  assert.doesNotMatch(JSON.stringify(results), /children|ילדים/);
});

test('self filters apply, built-in assistant exemption applies and unknown files never become allowed', async () => {
  const assistant = '00000000-0000-4000-8000-000000000002';
  const db = database({ files: [{ public_url: '/image', file_type: 'image', classification: image.classification }],
    users: [{ id: sender, is_contact: true, content_filter: { ...all, men: false } },
      { id: assistant, content_filter: { ...all, men: false } }] });
  const results = await loadForwardFilterPreview(db, sender, [{ fileUrl: '/image' }],
    [{ kind: 'user', id: sender }, { kind: 'user', id: assistant }]);
  assert.equal(results[0].status, 'blocked');
  assert.equal(results[1].status, 'allowed');
  const unavailable = await loadForwardFilterPreview(database({ users: [{ id: sender, is_contact: true, content_filter: all }] }), sender,
    [{ fileUrl: '/not-visible', fileType: 'image' }], [{ kind: 'user', id: sender }]);
  assert.equal(unavailable[0].status, 'unknown');
});

test('route requires authentication; oversized or invalid requests are rejected before queries', async () => {
  const auth = () => {};
  let registered;
  registerForwardFilterPreview({ post: (...args) => { registered = args; } }, { auth, getPool: async () => database() });
  assert.equal(registered[0], '/api/forward/filter-preview');
  assert.equal(registered[1], auth);
  for (const [messages, targets] of [[[], []], [[{}], [{ kind: 'user', id: 'bad' }]], [Array(501).fill({}), []]]) {
    const db = database();
    await assert.rejects(loadForwardFilterPreview(db, sender, messages, targets), { status: 400 });
    assert.equal(db.queries.length, 0);
  }
});
