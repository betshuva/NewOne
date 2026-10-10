'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const { REACTIONS, ALLOWED_REACTIONS, REACTION_EMOJI_SCHEMA,
  registerMessageReactions } = require('../server/message-reactions');
const { inlineEmojiPlainText } = require('../server/inline-custom-emoji');
const { contentAllowedByFilter } = require('../server/content-filter-policy');
const id = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const [a, b, messageId] = [501, 502, 503].map(id);
const token = n => `[[bt-emoji:${String(n).padStart(3, '0')}]]`;

function fixture() {
  const rows = new Map([[b, { user_id: b, name: 'חבר', profile_pic_url: null,
    emoji: '❤️', updated_at: '2026-10-01T12:00:00.000Z' }]]);
  const queries = [], writes = [], pushes = [], events = [];
  const pool = { query: async (sql, values) => {
    queries.push({ sql, values });
    if (sql.startsWith('SELECT m.id,m.sender_id')) return { rows: [{ id: messageId,
      sender_id: a, recipient_id: b, type: 'text' }] };
    if (sql.startsWith('SELECT u.id,m.sender_id')) return { rows: [a, b].map(userId =>
      ({ id: userId, sender_id: a, type: 'text' })) };
    if (sql.startsWith('SELECT name FROM users')) return { rows: [{ name: 'אני' }] };
    if (sql.startsWith('WITH changed AS')) {
      assert.match(sql, /ON CONFLICT\(message_id,user_id\)/);
      writes.push({ sql, values });
      if (rows.get(values[1])?.emoji === values[2]) return { rows: [] };
      const updated_at = new Date();
      rows.set(values[1], { user_id: values[1], name: 'אני', profile_pic_url: null,
        emoji: values[2], updated_at });
      return { rows: [{ updated_at }] };
    }
    if (sql.startsWith('DELETE FROM message_reactions')) {
      assert.match(sql, /WHERE message_id=\$1 AND user_id=\$2/);
      writes.push({ sql, values });
      return { rows: rows.delete(values[1]) ? [{ updated_at: new Date() }] : [] };
    }
    if (sql.startsWith('SELECT r.user_id,actor.name')) return { rows: [...rows.values()] };
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
    assert.fail('unexpected library fixture query');
  } };
  return { pool, rows, queries, writes, pushes, events };
}

async function api(t, state) {
  const app = express();
  app.use(express.json());
  registerMessageReactions(app, {
    auth: (req, res, next) => { req.user = { id: a }; next(); },
    rateLimit: (req, res, next) => next(), getPool: async () => state.pool, contentAllowedByFilter,
    notifyReaction: (viewer, payload) => state.events.push({ viewer, payload }),
    sendPush: async (viewer, title, body, data) => state.pushes.push({ viewer, title, body, data }),
  });
  const server = app.listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  return async (body, details = false) => {
    const response = await fetch(`http://127.0.0.1:${server.address().port}/api/messages/${messageId}/reactions${details ? '/details' : ''}`, {
      method: body === undefined ? 'GET' : 'PUT', headers: { 'Content-Type': 'application/json' },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    await new Promise(resolve => setImmediate(resolve));
    return { status: response.status, body: await response.json() };
  };
}

test('reaction library contains exactly six legacy reactions and the 150 immutable bundled IDs', () => {
  assert.deepEqual(REACTIONS, ['👍', '❤️', '😂', '🙏', '😮', '😢']);
  assert.equal(ALLOWED_REACTIONS.length, 156);
  assert.equal(new Set(ALLOWED_REACTIONS).size, 156);
  assert.ok(Object.isFrozen(REACTIONS) && Object.isFrozen(ALLOWED_REACTIONS));
  assert.deepEqual(ALLOWED_REACTIONS.slice(6), Array.from({ length: 150 }, (_, index) => token(index + 1)));
  const bundled = require('../flutter_app/assets/stickers/user-catalog.json').categories.find(category => category.id === 'user-stickers');
  const hosted = require('../expression-library/catalog.json').categories.find(category => category.id === 'user-stickers');
  assert.deepEqual(bundled.labels, hosted.labels, 'notification labels and bundled artwork IDs must agree');
  assert.equal(inlineEmojiPlainText(token(1)), '[שמחה]');
  assert.equal(inlineEmojiPlainText(token(150)), '[זהירות מקישור לא ידוע]');
});

test('all 156 exact reactions round-trip through the API and socket payload while push bodies stay readable', async t => {
  const state = fixture();
  const otherBefore = structuredClone(state.rows.get(b));
  const request = await api(t, state);
  for (const emoji of ALLOWED_REACTIONS) {
    const response = await request({ emoji });
    assert.equal(response.status, 200, emoji);
    assert.ok(response.body.some(row => row.emoji === emoji && row.mine === true), emoji);
    assert.equal(state.events.at(-1).payload.emoji, emoji);
    assert.equal(state.pushes.at(-1).body, `הגיב/ה ${inlineEmojiPlainText(emoji)}`);
    assert.doesNotMatch(state.pushes.at(-1).body, /\[\[bt-emoji:/);
    assert.deepEqual(state.rows.get(b), otherBefore);
  }
  const details = await request(undefined, true);
  assert.equal(details.status, 200);
  assert.equal(details.body.users.find(user => user.mine).emoji, token(150));
  assert.equal(details.body.users.find(user => !user.mine).emoji, '❤️');
  assert.equal(state.pushes.length, 156);
});

test('noncanonical IDs, text, URLs and compound values are rejected before any database query', async t => {
  const state = fixture();
  const request = await api(t, state);
  const invalid = [token(0), token(151), '[[bt-emoji:1]]', '[[bt-emoji:0001]]', '[[BT-EMOJI:001]]',
    '[[bt-emoji:001]] ', ' [[bt-emoji:001]]', 'text [[bt-emoji:001]]', token(1) + token(2),
    'https://betshuva.com/betshuva-app/expression-library/user-20260907/sticker-001.png',
    '\uE000', '🔥', '❤', '', 1, true, [token(1)], { emoji: token(1) }];
  for (const emoji of invalid) assert.equal((await request({ emoji })).status, 400, JSON.stringify(emoji));
  assert.equal((await request({})).status, 400);
  assert.equal(state.queries.length, 0);
  assert.equal(state.writes.length, 0);
  assert.equal(state.pushes.length, 0);
  assert.equal(state.events.length, 0);
});

test('custom reaction replacement and removal remain bound to the authenticated owner', async t => {
  const state = fixture();
  const otherBefore = structuredClone(state.rows.get(b));
  const request = await api(t, state);
  for (const emoji of [token(1), token(150)]) {
    assert.equal((await request({ emoji, user_id: b, userId: b, actorId: b, actor_id: b, mine: false })).status, 200);
    assert.deepEqual(state.writes.at(-1).values.slice(0, 3), [messageId, a, emoji]);
    assert.deepEqual(state.rows.get(b), otherBefore);
  }
  assert.equal((await request({ emoji: null, user_id: b, actorId: b, mine: false })).status, 200);
  assert.deepEqual(state.writes.at(-1).values, [messageId, a]);
  assert.deepEqual(state.rows.get(b), otherBefore);
  assert.equal(state.rows.has(a), false);
});

// Opt-in only: the migration and inserts resolve to one connection-local TEMP
// table inside a transaction. Public tables and user data are never modified.
test('PostgreSQL migration widens only the named CHECK, preserves rows and is idempotent', {
  skip: process.env.RUN_REACTION_LIBRARY_DB_TESTS !== '1',
}, async () => {
  const { Client } = require('pg');
  const db = new Client({ connectionString: process.env.DATABASE_URL, connectionTimeoutMillis: 10000,
    ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' } : false });
  await db.connect();
  try {
    await db.query('BEGIN');
    await db.query('SET LOCAL search_path=pg_temp,public');
    await db.query(`CREATE TEMP TABLE message_reactions(message_id uuid,user_id uuid,
      emoji text NOT NULL CHECK (emoji IN ('👍','❤️','😂','🙏','😮','😢')),
      updated_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(message_id,user_id),
      CONSTRAINT reaction_fixture_guard CHECK (user_id IS NOT NULL))`);
    const table = (await db.query(`SELECT c.relpersistence,n.nspname FROM pg_class c
      JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.oid='message_reactions'::regclass`)).rows[0];
    assert.equal(table.relpersistence, 't');
    assert.match(table.nspname, /^pg_temp_/);
    await db.query("INSERT INTO message_reactions(message_id,user_id,emoji,updated_at) VALUES($1,$2,'❤️','2026-10-01T12:00:00Z')", [messageId, b]);
    const snapshot = async () => (await db.query('SELECT user_id,emoji,updated_at::text FROM message_reactions ORDER BY user_id')).rows;
    const constraints = async () => (await db.query(`SELECT oid,conname,pg_get_constraintdef(oid) AS definition
      FROM pg_constraint WHERE conrelid='message_reactions'::regclass ORDER BY conname`)).rows;
    const before = await snapshot();
    const oldConstraints = await constraints();
    await db.query(REACTION_EMOJI_SCHEMA);
    assert.deepEqual(await snapshot(), before);
    const firstConstraints = await constraints();
    assert.deepEqual(firstConstraints.filter(row => row.conname !== 'message_reactions_emoji_check'),
      oldConstraints.filter(row => row.conname !== 'message_reactions_emoji_check'));
    await db.query(REACTION_EMOJI_SCHEMA);
    assert.deepEqual(await constraints(), firstConstraints, 'second startup must retain the CHECK OID');
    assert.deepEqual(await snapshot(), before, 'schema startup must retain existing timestamps');
    for (const emoji of ALLOWED_REACTIONS) {
      await db.query(`INSERT INTO message_reactions(message_id,user_id,emoji) VALUES($1,$2,$3)
        ON CONFLICT(message_id,user_id) DO UPDATE SET emoji=EXCLUDED.emoji`, [messageId, a, emoji]);
    }
    const rowsBeforeInvalid = await snapshot();
    for (const emoji of [token(0), token(151), 'text ' + token(1), 'https://example.test/image.png']) {
      await db.query('SAVEPOINT invalid_reaction');
      await assert.rejects(db.query('UPDATE message_reactions SET emoji=$1 WHERE user_id=$2', [emoji, a]),
        error => error.code === '23514' && error.constraint === 'message_reactions_emoji_check');
      await db.query('ROLLBACK TO SAVEPOINT invalid_reaction');
    }
    assert.deepEqual(await snapshot(), rowsBeforeInvalid);
    await db.query(REACTION_EMOJI_SCHEMA);
    assert.deepEqual(await constraints(), firstConstraints);
    assert.deepEqual(await snapshot(), rowsBeforeInvalid);
  } finally {
    await db.query('ROLLBACK');
    await db.end();
  }
});
