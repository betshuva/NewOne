'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const { registerMessageReactions, REACTION_EMOJI_SCHEMA } = require('../server/message-reactions');
const { contentAllowedByFilter } = require('../server/content-filter-policy');
const id = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const [a, b, c, outsider, messageId, groupId, groupMessage] = [201, 202, 203, 204, 205, 206, 207].map(id);

async function api(t, pool) {
  const app = express();
  app.use(express.json());
  registerMessageReactions(app, {
    auth: (req, res, next) => {
      const userId = req.headers['x-test-user'];
      if (![a, b, c, outsider].includes(userId)) return res.sendStatus(401);
      req.user = { id: userId };
      next();
    },
    rateLimit: (req, res, next) => next(), getPool: async () => pool, contentAllowedByFilter,
    // Intentionally no production transport hooks in these isolated fixtures.
  });
  const server = app.listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  return async (userId, { message = messageId, details = false, body } = {}) => {
    const response = await fetch(`http://127.0.0.1:${server.address().port}/api/messages/${message}/reactions${details ? '/details' : ''}`, {
      method: body === undefined ? 'GET' : 'PUT',
      headers: { 'Content-Type': 'application/json', ...(userId ? { 'x-test-user': userId } : {}) },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    return { status: response.status, headers: response.headers,
      body: response.status === 200 ? await response.json() : null };
  };
}

function memoryPool() {
  const rows = new Map([[a, { user_id: a, name: 'אני', profile_pic_url: 'emoji:🌻', emoji: '🙏' }],
    [b, { user_id: b, name: 'חבר', profile_pic_url: null, emoji: '❤️' }]]);
  const writes = [], reads = [];
  const pool = { query: async (sql, values) => {
    if (sql.startsWith('SELECT m.id,m.sender_id')) {
      reads.push(values);
      return { rows: values[0] === messageId && [a, b].includes(values[1])
        ? [{ id: messageId, sender_id: a, recipient_id: b, type: 'text' }] : [] };
    }
    if (sql.startsWith('SELECT r.user_id,actor.name')) return { rows: [...rows.values()]
      .sort((left, right) => left.emoji.localeCompare(right.emoji)) };
    if (sql.startsWith('SELECT u.id,m.sender_id')) return { rows: [a, b].map(userId =>
      ({ id: userId, sender_id: a, type: 'text' })) };
    if (sql.startsWith('SELECT name FROM users')) return { rows: [{ name: 'אני' }] };
    if (sql.startsWith('WITH changed AS')) {
      assert.match(sql, /INSERT INTO message_reactions\(message_id,user_id,emoji\)\s+VALUES\(\$1,\$2,\$3\)/);
      assert.match(sql, /ON CONFLICT\(message_id,user_id\)/);
      writes.push({ sql, values });
      const row = rows.get(values[1]);
      if (row?.emoji === values[2]) return { rows: [] };
      rows.set(values[1], { user_id: values[1], name: 'אני', profile_pic_url: null, emoji: values[2] });
      return { rows: [{ updated_at: new Date() }] };
    }
    if (sql.startsWith('DELETE FROM message_reactions')) {
      assert.match(sql, /WHERE message_id=\$1 AND user_id=\$2/);
      writes.push({ sql, values });
      return { rows: rows.delete(values[1]) ? [{ updated_at: new Date() }] : [] };
    }
    if (sql.startsWith('SELECT emoji,COUNT')) {
      const counts = new Map();
      for (const row of rows.values()) {
        const summary = counts.get(row.emoji) || { emoji: row.emoji, count: 0, mine: false };
        summary.count++;
        summary.mine ||= row.user_id === values[1];
        counts.set(row.emoji, summary);
      }
      return { rows: [...counts.values()] };
    }
    assert.fail('unexpected fixture query');
  } };
  return { pool, rows, writes, reads };
}

test('reaction details require authentication and visible-message access before any identities are read', async t => {
  const fixture = memoryPool();
  const request = await api(t, fixture.pool);
  assert.equal((await request(null, { details: true })).status, 401);
  assert.equal((await request(outsider, { details: true })).status, 404);
  assert.equal((await request(a, { message: 'invalid', details: true })).status, 400);
  assert.equal(fixture.writes.length, 0);
  assert.deepEqual(fixture.reads, [[messageId, outsider]]);
});

test('reaction details return a matching summary and only minimal, server-owned actor fields', async t => {
  const fixture = memoryPool();
  // Unexpected database fields must not accidentally become API fields.
  Object.assign(fixture.rows.get(b), { email: 'private@example.test', phone: 'private', mine: true, is_admin: true });
  const request = await api(t, fixture.pool);
  const response = await request(a, { details: true });
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.equal(response.body.users.length, 2);
  const mine = response.body.users.find(row => row.user_id === a);
  const other = response.body.users.find(row => row.user_id === b);
  assert.deepEqual(mine, { user_id: a, name: 'אני', photo_url: 'emoji:🌻', emoji: '🙏', mine: true });
  assert.deepEqual(other, { user_id: b, name: 'חבר', photo_url: null, emoji: '❤️', mine: false });
  assert.equal(response.body.reactions.reduce((sum, row) => sum + row.count, 0), response.body.users.length);
  assert.equal(response.body.reactions.find(row => row.emoji === '❤️').mine, false);
  assert.ok(Array.isArray((await request(a)).body), 'legacy GET still returns its summary array');
});

test('forged actor fields cannot replace another participant reaction', async t => {
  const fixture = memoryPool();
  const otherBefore = structuredClone(fixture.rows.get(b));
  const request = await api(t, fixture.pool);
  const response = await request(a, { body: { emoji: '😂', userId: b, user_id: b, actorId: b,
    actor_id: b, mine: false, message_id: groupMessage } });
  assert.equal(response.status, 200);
  assert.equal(fixture.rows.get(a).emoji, '😂');
  assert.deepEqual(fixture.rows.get(b), otherBefore);
  assert.deepEqual(fixture.writes[0].values.slice(0, 3), [messageId, a, '😂']);
});

test('forged actor fields cannot remove another participant reaction and outsiders cannot write', async t => {
  const fixture = memoryPool();
  const otherBefore = structuredClone(fixture.rows.get(b));
  const request = await api(t, fixture.pool);
  assert.equal((await request(a, { body: { emoji: null, user_id: b, actorId: b, mine: false } })).status, 200);
  assert.equal(fixture.rows.has(a), false);
  assert.deepEqual(fixture.rows.get(b), otherBefore);
  assert.deepEqual(fixture.writes[0].values, [messageId, a]);
  assert.equal((await request(outsider, { body: { emoji: null, userId: b } })).status, 404);
  assert.equal(fixture.writes.length, 1);
  assert.deepEqual(fixture.rows.get(b), otherBefore);
});

// Explicit opt-in: all data is connection-local TEMP fixtures. pg_temp is
// first in search_path, the test runs in one transaction and always rolls back.
// No public table data, user account, receipt or push service is changed.
test('PostgreSQL reaction details enforce private/group audience, avatar policy and actor ownership', {
  skip: process.env.RUN_REACTION_DETAILS_DB_TESTS !== '1',
}, async t => {
  const { Client } = require('pg');
  const db = new Client({ connectionString: process.env.DATABASE_URL, connectionTimeoutMillis: 10000,
    ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' } : false });
  await db.connect();
  try {
    await db.query('BEGIN');
    await db.query('SET LOCAL search_path=pg_temp,public');
    await db.query(`
      CREATE TEMP TABLE users(id uuid PRIMARY KEY,name text,profile_pic_url text,birth_date date DEFAULT '1990-01-01',content_filter jsonb);
      CREATE TEMP TABLE messages(id uuid PRIMARY KEY,sender_id uuid,recipient_id uuid,group_id uuid,type text,file_url text,
        created_at timestamptz DEFAULT now(),deleted_for_everyone boolean DEFAULT false,deleted_for_sender boolean DEFAULT false);
      CREATE TEMP TABLE group_members(group_id uuid,user_id uuid,status text,joined_at timestamptz DEFAULT '-infinity',filter_override jsonb);
      CREATE TEMP TABLE groups(id uuid PRIMARY KEY,creator_id uuid,name text,content_filter jsonb);
      CREATE TEMP TABLE user_contacts(owner_id uuid,contact_id uuid,filter_override jsonb);
      CREATE TEMP TABLE stored_files(public_url text,file_type text,moderation_status text,content_purged_at timestamptz,moderation_details jsonb);
      CREATE TEMP TABLE message_user_deletions(message_id uuid,user_id uuid);
      CREATE TEMP TABLE blocked_users(blocker_id uuid,blocked_id uuid);
      CREATE TEMP TABLE conversation_user_state(user_id uuid,kind text,target_id uuid,cleared_at timestamptz);
      CREATE TEMP TABLE message_reactions(message_id uuid,user_id uuid,
        emoji text CHECK (emoji IN ('👍','❤️','😂','🙏','😮','😢')),
        updated_at timestamptz DEFAULT now(),PRIMARY KEY(message_id,user_id));
      CREATE TEMP TABLE message_status(message_id uuid,user_id uuid,status text,reactions_read_at timestamptz DEFAULT now(),PRIMARY KEY(message_id,user_id));
    `);
    const isolation = await db.query(`SELECT c.relname,c.relpersistence,n.nspname
      FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE c.oid=ANY(ARRAY['users','messages','group_members','groups','user_contacts','stored_files',
        'message_user_deletions','blocked_users','conversation_user_state','message_reactions','message_status']::regclass[])`);
    assert.equal(isolation.rows.length, 11);
    assert.ok(isolation.rows.every(row => row.relpersistence === 't' && row.nspname.startsWith('pg_temp_')));
    await db.query(REACTION_EMOJI_SCHEMA);
    const scopedSql = require('node:fs').readFileSync(require.resolve('../server/scoped-content-filter.sql'), 'utf8');
    await db.query(scopedSql.replace('FUNCTION betshuva_effective_filter', 'FUNCTION pg_temp.betshuva_effective_filter'));
    const originalQuery = db.query.bind(db);
    db.query = (sql, values) => originalQuery(sql.replaceAll('betshuva_effective_filter(', 'pg_temp.betshuva_effective_filter('), values);
    const filter = { text: true, nonHumanImages: true, men: true, women: false, children: false };
    for (const userId of [a, b, c, outsider])
      await db.query('INSERT INTO users(id,name,content_filter) VALUES($1,$2,$3)', [userId, `fixture-${userId.slice(-3)}`, JSON.stringify(filter)]);
    await db.query("INSERT INTO messages(id,sender_id,recipient_id,type) VALUES($1,$2,$3,'text')", [messageId, a, b]);
    await db.query('INSERT INTO groups(id,creator_id,name) VALUES($1,$2,$3)', [groupId, a, 'קבוצת בדיקה']);
    await db.query("INSERT INTO group_members(group_id,user_id,status) VALUES($1,$2,'member'),($1,$3,'member'),($1,$4,'member')", [groupId, a, b, c]);
    await db.query("INSERT INTO messages(id,sender_id,group_id,type) VALUES($1,$2,$3,'text')", [groupMessage, a, groupId]);
    await db.query("INSERT INTO message_reactions(message_id,user_id,emoji) VALUES($1,$2,'🙏'),($1,$3,'❤️'),($4,$2,'🙏'),($4,$3,'❤️'),($4,$5,'😂')", [messageId, a, b, groupMessage, c]);
    const request = await api(t, db);
    const snapshot = async () => (await db.query('SELECT user_id,emoji,updated_at::text FROM message_reactions WHERE message_id=$1 AND user_id=$2', [messageId, b])).rows;
    await t.test('auth and unauthorized private/group readers and writers are rejected', async () => {
      assert.equal((await request(null, { details: true })).status, 401);
      for (const message of [messageId, groupMessage]) {
        assert.equal((await request(outsider, { message, details: true })).status, 404);
        assert.equal((await request(outsider, { message, body: { emoji: '😮', user_id: a } })).status, 404);
      }
    });
    await t.test('custom catalog endpoints and details round-trip without modifying another actor', async () => {
      const before = await snapshot();
      for (const emoji of ['[[bt-emoji:001]]', '[[bt-emoji:150]]']) {
        const response = await request(a, { body: { emoji, user_id: b, actorId: b, mine: false } });
        assert.equal(response.status, 200);
        assert.ok(response.body.some(row => row.emoji === emoji && row.mine));
        const details = await request(a, { details: true });
        assert.equal(details.body.users.find(row => row.user_id === a).emoji, emoji);
        assert.equal(details.body.users.find(row => row.user_id === b).emoji, '❤️');
        assert.deepEqual(await snapshot(), before);
      }
      assert.equal((await request(a, { body: { emoji: null, user_id: b } })).status, 200);
      assert.deepEqual(await snapshot(), before);
      await request(a, { body: { emoji: '🙏' } });
    });
    await t.test('private own replace/remove preserve the other actor emoji and timestamp despite forged ownership', async () => {
      const before = await snapshot();
      assert.equal((await request(a, { body: { emoji: '👍', user_id: b, actorId: b, mine: false } })).status, 200);
      assert.deepEqual(await snapshot(), before);
      assert.equal((await request(a, { body: { emoji: null, userId: b, actor_id: b } })).status, 200);
      assert.deepEqual(await snapshot(), before);
      assert.deepEqual((await request(a, { details: true })).body.reactions, [{ emoji: '❤️', count: 1, mine: false }]);
      assert.equal((await request(b, { body: { emoji: '🙏' } })).status, 200);
      assert.equal((await request(b, { details: true })).body.users[0].mine, true);
    });
    await t.test('concurrent group changes and forged removals remain isolated to each authenticated actor', async () => {
      const thirdBefore = (await db.query(`SELECT user_id,emoji,updated_at::text FROM message_reactions
        WHERE message_id=$1 AND user_id=$2`, [groupMessage, c])).rows;
      const changed = await Promise.all([
        request(a, { message: groupMessage, body: { emoji: '😮', user_id: b } }),
        request(b, { message: groupMessage, body: { emoji: '😢', actorId: c, mine: true } }),
      ]);
      assert.ok(changed.every(response => response.status === 200));
      let rows = (await db.query('SELECT user_id,emoji FROM message_reactions WHERE message_id=$1 ORDER BY user_id', [groupMessage])).rows;
      assert.deepEqual(rows, [{ user_id: a, emoji: '😮' }, { user_id: b, emoji: '😢' }, { user_id: c, emoji: '😂' }]);
      const removed = await Promise.all([
        request(a, { message: groupMessage, body: { emoji: null, userId: c } }),
        request(b, { message: groupMessage, body: { emoji: null, user_id: c } }),
      ]);
      assert.ok(removed.every(response => response.status === 200));
      rows = (await db.query(`SELECT user_id,emoji,updated_at::text FROM message_reactions
        WHERE message_id=$1 ORDER BY user_id`, [groupMessage])).rows;
      assert.deepEqual(rows, thirdBefore);
      await request(a, { message: groupMessage, body: { emoji: '🙏' } });
      await request(b, { message: groupMessage, body: { emoji: '❤️' } });
    });
    await t.test('avatars follow viewer image preferences and detail identities have only minimal fields', async () => {
      await db.query("UPDATE users SET profile_pic_url='/fixture-woman' WHERE id=$1", [b]);
      await db.query(`INSERT INTO stored_files(public_url,file_type,moderation_status,moderation_details)
        VALUES('/fixture-woman','image','approved','{"classification":{"category":"women"}}')`);
      let response = await request(a, { details: true });
      assert.equal(response.body.users[0].photo_url, null);
      assert.deepEqual(Object.keys(response.body.users[0]).sort(), ['emoji', 'mine', 'name', 'photo_url', 'user_id']);
      await db.query('UPDATE users SET content_filter=$2 WHERE id=$1', [a, JSON.stringify({ ...filter, women: true })]);
      response = await request(a, { details: true });
      assert.equal(response.body.users[0].photo_url, '/fixture-woman');
      await db.query("UPDATE stored_files SET moderation_status='rejected'");
      assert.equal((await request(a, { details: true })).body.users[0].photo_url, null);
      await db.query('UPDATE users SET content_filter=$2 WHERE id=$1', [a, JSON.stringify(filter)]);
    });
    await t.test('group details filter blocked actor identities in both directions without changing legacy summary', async () => {
      for (const block of [[b, c], [c, b]]) {
        await db.query('INSERT INTO blocked_users(blocker_id,blocked_id) VALUES($1,$2)', block);
        const response = await request(b, { message: groupMessage, details: true });
        assert.equal(response.status, 200);
        assert.deepEqual(response.body.users.map(row => row.user_id).sort(), [a, b].sort());
        assert.equal(response.body.reactions.reduce((sum, row) => sum + row.count, 0), 2);
        assert.equal((await request(b, { message: groupMessage })).body.reduce((sum, row) => sum + row.count, 0), 3);
        await db.query('DELETE FROM blocked_users');
      }
    });
    await t.test('left, newly joined and underage group viewers cannot read identities', async () => {
      await db.query("UPDATE group_members SET status='left' WHERE user_id=$1", [b]);
      assert.equal((await request(b, { message: groupMessage, details: true })).status, 404);
      await db.query("UPDATE group_members SET status='member',joined_at=now()+INTERVAL '1 day' WHERE user_id=$1", [b]);
      assert.equal((await request(b, { message: groupMessage, details: true })).status, 404);
      await db.query("UPDATE group_members SET joined_at='-infinity' WHERE user_id=$1", [b]);
      await db.query('UPDATE users SET birth_date=CURRENT_DATE WHERE id=$1', [b]);
      assert.equal((await request(b, { message: groupMessage, details: true })).status, 404);
      await db.query("UPDATE users SET birth_date='1990-01-01' WHERE id=$1", [b]);
    });
    await t.test('hidden, cleared and content-filtered messages reveal no reaction identities', async () => {
      await db.query('INSERT INTO message_user_deletions(message_id,user_id) VALUES($1,$2)', [groupMessage, b]);
      assert.equal((await request(b, { message: groupMessage, details: true })).status, 404);
      await db.query('DELETE FROM message_user_deletions');
      await db.query("INSERT INTO conversation_user_state(user_id,kind,target_id,cleared_at) VALUES($1,'group',$2,now())", [b, groupId]);
      assert.equal((await request(b, { message: groupMessage, details: true })).status, 404);
      await db.query('DELETE FROM conversation_user_state');
      await db.query("UPDATE messages SET type='image',file_url='/fixture-woman' WHERE id=$1", [groupMessage]);
      assert.equal((await request(b, { message: groupMessage, details: true })).status, 404);
      assert.equal((await request(a, { message: groupMessage, details: true })).status, 200);
      await db.query('UPDATE messages SET deleted_for_everyone=true WHERE id=$1', [groupMessage]);
      assert.equal((await request(a, { message: groupMessage, details: true })).status, 404);
    });
  } finally {
    await db.query('ROLLBACK');
    await db.end();
  }
});
