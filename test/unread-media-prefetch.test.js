const test = require('node:test');
const assert = require('node:assert/strict');
const { registerUnreadMediaPrefetch, MAX_FILE_BYTES, MAX_TOTAL_BYTES } = require('../server/unread-media-prefetch');

const row = (i, overrides = {}) => ({ id: String(i), sender_id: `sender-${i}`,
  recipient_id: 'viewer', group_id: null, type: 'image',
  file_url: `/files/${i}.jpg`, file_size: 100, ...overrides });

async function run(rows, { hidden = [], forbidden = [], teen = false, videoAllowed = true } = {}) {
  let handler, output, status = 200;
  const queries = [];
  registerUnreadMediaPrefetch({ get(path, auth, callback) {
    assert.equal(path, '/api/media/unread-prefetch'); handler = callback;
  } }, { auth: () => {}, getPool: async () => ({ query: async (sql, values) => {
    queries.push({ sql, values }); return { rows };
  } }), projectFilteredHistory: async (_, __, items) => items.map(item =>
    hidden.includes(item.id) ? { ...item, filter_hidden: true, file_url: null } : item),
  contentAllowedByFilter: () => videoAllowed,
  teenContactAllowed: async (_, __, id) => !forbidden.includes(id) });
  await handler({ user: { id: 'viewer', isTeen: teen } }, {
    set(name, value) { assert.equal(name, 'Cache-Control'); assert.equal(value, 'no-store'); },
    status(code) { status = code; return this; }, json(value) { output = value; },
  });
  return { output, status, queries };
}

test('selection is read-only and enforces unread, moderation, membership and deletion boundaries', async () => {
  const { output, queries } = await run([row(1)]);
  assert.equal(output.items.length, 1);
  const sql = queries[0].sql;
  assert.doesNotMatch(sql, /^\s*(INSERT|UPDATE|DELETE)\s/im);
  for (const guard of ["ms.status<>'read'", "sf.moderation_status='approved'",
    'sf.content_purged_at IS NULL', "personal_member.status='member'",
    'personal_member.joined_at', 'message_user_deletions', 'conversation_user_state']) {
    assert.ok(sql.includes(guard), guard);
  }
  assert.deepEqual(queries[0].values, ['viewer', false, MAX_FILE_BYTES]);
});

test('hidden media, forbidden teen contacts and video policies never expose a URL', async () => {
  const { output } = await run([row(1), row(2), row(3, { type: 'video' }), row(4)],
    { hidden: ['1'], forbidden: ['sender-2'], videoAllowed: false });
  assert.deepEqual(output.items.map(item => item.messageId), ['4']);
});

test('bounded bytes, URL deduplication and per-conversation limits protect startup', async () => {
  const rows = [row(1, { file_size: MAX_FILE_BYTES + 1 }), row(2, { file_size: 0 }),
    ...Array.from({ length: 8 }, (_, i) => row(i + 10, {
      group_id: 'group', file_size: MAX_FILE_BYTES,
    })), row(25, { file_url: '/files/10.jpg' })];
  const { output } = await run(rows);
  assert.equal(output.items.length, 5);
  assert.equal(output.items.reduce((sum, item) => sum + item.bytes, 0), MAX_TOTAL_BYTES);
  assert.ok(output.items.every(item => item.kind === 'group' && item.targetId === 'group'));
});

test('at most twenty small items are returned and teen SQL excludes groups', async () => {
  const { output, queries } = await run(Array.from({ length: 30 }, (_, i) => row(i)), { teen: true });
  assert.equal(output.items.length, 20);
  assert.equal(queries[0].values[1], true);
  assert.ok(queries[0].sql.includes('(NOT $2 OR m.group_id IS NULL)'));
});
