'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { registerConversationSearch, searchText } = require('../server/conversation-search');
const id = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const actor = id(1), peer = id(2), group = id(3);

function harness(pool, overrides = {}) {
  let handler;
  registerConversationSearch({ get: (_path, ...args) => { handler = args.at(-1); } }, {
    auth() {}, rateLimit() {}, getPool: async () => pool,
    teenContactAllowed: async () => true,
    projectFilteredHistory: async (_, __, rows) => rows,
    projectGuideFilterNotice: row => row, ...overrides,
  });
  return async (query, user = { id: actor }) => {
    const out = { status: 200 };
    const res = { set() { return res; }, status(code) { out.status = code; return res; },
      json(body) { out.body = body; return res; } };
    await handler({ query, user }, res);
    return out;
  };
}

test('search normalizes Hebrew vowel marks and mixed case', () => {
  assert.equal(searchText('שָׁלוֹם Yaniv'), searchText('שלום yaniv'));
});

test('filter-hidden matches, filtered group text, and disallowed teen chats are excluded', async () => {
  const row = { id: id(9), conversation_id: peer, body: 'שלום', group_id: null, created_at: '2026-01-01' };
  for (const overrides of [
    { teenContactAllowed: async () => false },
    { projectFilteredHistory: async (_, __, rows) => rows.map(row => ({ ...row, filter_hidden: true })) },
    { projectFilteredHistory: async () => [] },
    { projectGuideFilterNotice: row => ({ ...row, body: 'פרטי סינון' }) },
  ]) {
    const invoke = harness({ query: async () => ({ rows: [row] }) }, overrides);
    assert.deepEqual((await invoke({ q: 'שלום' })).body.messages, []);
  }
});

test('pagination preserves microseconds and rejects malformed cursors', async () => {
  const rows = Array.from({ length: 501 }, (_, i) => ({ id: id(i + 10),
    body: 'no match', created_at: new Date('2026-01-01'), cursor_at: '2026-01-01T00:00:00.123456Z' }));
  const calls = [];
  const invoke = harness({ query: async (sql, values) => { calls.push({ sql, values }); return { rows }; } });
  const first = await invoke({ q: 'שלום' });
  assert.deepEqual(first.body.messages, []);
  const cursor = JSON.parse(Buffer.from(first.body.nextCursor, 'base64url'));
  assert.equal(cursor.at, rows[499].cursor_at);
  assert.equal(cursor.id, rows[499].id);
  await invoke({ q: 'שלום', cursor: first.body.nextCursor });
  assert.equal(calls[1].values[2], rows[499].cursor_at);
  assert.equal((await invoke({ q: 'שלום', cursor: 'invalid' })).status, 400);
  assert.equal(calls.length, 2);
});

test('real SQL only searches visible private/group history and decrypted bodies', {
  skip: process.env.RUN_DB_TESTS !== '1',
}, async () => {
  require('dotenv').config({ quiet: true });
  const { Client } = require('pg');
  const { decryptMessageRows, encryptMessageText } = require('../server/message-at-rest');
  const db = new Client({ connectionString: process.env.DATABASE_URL });
  await db.connect();
  try {
    await db.query('BEGIN');
    await db.query(`CREATE TEMP TABLE users (id uuid, name text);
      CREATE TEMP TABLE groups (id uuid, name text);
      CREATE TEMP TABLE group_members (group_id uuid,user_id uuid,status text,joined_at timestamptz);
      CREATE TEMP TABLE messages (id uuid,sender_id uuid,recipient_id uuid,group_id uuid,
        body text,type text,file_name text,created_at timestamptz,deleted_for_everyone boolean DEFAULT false,
        deleted_for_sender boolean DEFAULT false,delivery_summary jsonb);
      CREATE TEMP TABLE message_user_deletions (message_id uuid,user_id uuid);
      CREATE TEMP TABLE conversation_user_state (user_id uuid,kind text,target_id uuid,cleared_at timestamptz);`);
    await db.query('INSERT INTO users VALUES($1,$2),($3,$4)', [actor, 'me', peer, 'peer']);
    await db.query('INSERT INTO groups VALUES($1,$2)', [group, 'group']);
    await db.query("INSERT INTO group_members VALUES($1,$2,'member','2026-01-02')", [group, actor]);
    const body = encryptMessageText('שלום מוצפן');
    for (const [n, sender, recipient, groupId, at] of [
      [10, actor, peer, null, '2026-01-03'], [11, peer, actor, null, '2026-01-03'],
      [12, peer, null, group, '2026-01-03'], [13, peer, id(99), null, '2026-01-03'],
      [14, peer, null, group, '2026-01-01'], [15, peer, null, id(98), '2026-01-03'],
      [16, actor, peer, null, '2026-01-03'], [17, peer, actor, null, '2026-01-03'],
      [18, peer, actor, null, '2026-01-03'], [19, actor, peer, null, '2025-01-01'],
    ]) {
      await db.query("INSERT INTO messages(id,sender_id,recipient_id,group_id,created_at,body,type) VALUES($1,$2,$3,$4,$5,$6,'text')",
        [id(n), sender, recipient, groupId, at, body]);
    }
    await db.query('UPDATE messages SET deleted_for_sender=true WHERE id=$1', [id(16)]);
    await db.query('UPDATE messages SET deleted_for_everyone=true WHERE id=$1', [id(17)]);
    await db.query('INSERT INTO message_user_deletions VALUES($1,$2)', [id(18), actor]);
    await db.query("INSERT INTO conversation_user_state VALUES($1,'chat',$2,'2026-01-01')", [actor, peer]);
    const invoke = harness({ query: async (...args) => decryptMessageRows(await db.query(...args)) });
    const result = await invoke({ q: 'שלום' });
    assert.equal(result.status, 200);
    assert.deepEqual(result.body.messages.map(m => m.id).sort(), [10, 11, 12].map(id));
    assert.equal(result.body.messages.find(m => m.id === id(12)).kind, 'group');
    const teen = await invoke({ q: 'שלום' }, { id: actor, isTeen: true });
    assert.deepEqual(teen.body.messages.map(m => m.id).sort(), [10, 11].map(id));
  } finally { await db.query('ROLLBACK'); await db.end(); }
});
