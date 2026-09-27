'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { Client } = require('pg');
const { SHORT_USER_ID_SCHEMA, shortenCapturedFileName } = require('../server/user-short-id');
const owner = 'c519a188-fcca-4aaa-bd69-c0d227ca7959';
const other = 'd519a188-fcca-4aaa-bd69-c0d227ca7959';
const stem = 'betshuva-photo-2026-09-23_11-52-25-52-ID-';

test('legacy capture names use the authenticated creator number and preserve suffixes', async () => {
  const pool = { async query(sql, values) {
    assert.equal(sql, 'SELECT short_id FROM users WHERE id=$1');
    assert.deepEqual(values, [owner]);
    return { rows: [{ short_id: '742' }] };
  } };
  assert.equal(await shortenCapturedFileName(pool, owner, `${stem}${owner}_2.jpg`), `${stem}742_2.jpg`);
  const audio = stem.replace('photo', 'audio');
  assert.equal(await shortenCapturedFileName(pool, owner, `${audio}${owner}.mp3`), `${audio}742.mp3`);
  for (const name of ['report.pdf', `${stem}742.jpg`, `${stem}${other}.jpg`]) {
    assert.equal(await shortenCapturedFileName({ query() { throw Error('Unexpected lookup'); } }, owner, name), name);
  }
  await assert.rejects(shortenCapturedFileName({ query: async () => ({ rows: [] }) }, owner, `${stem}${owner}.jpg`));
});

test('short number migration backfills accounts, is repeatable, and allocates unique numbers',
  { skip: process.env.RUN_DB_TESTS !== '1' }, async () => {
    const db = new Client({ connectionString: process.env.DATABASE_URL,
      ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' } : false });
    await db.connect();
    try {
      await db.query('SET search_path=pg_temp');
      await db.query('CREATE TEMP TABLE users(id UUID PRIMARY KEY)');
      await db.query('INSERT INTO users(id) VALUES($1),($2)', [owner, other]);
      await db.query(SHORT_USER_ID_SCHEMA);
      const before = (await db.query('SELECT id,short_id FROM users ORDER BY id')).rows;
      assert.equal(new Set(before.map(row => row.short_id)).size, 2);
      assert.ok(before.every(row => /^[1-9][0-9]*$/.test(row.short_id)));
      await db.query(SHORT_USER_ID_SCHEMA);
      assert.deepEqual((await db.query('SELECT id,short_id FROM users ORDER BY id')).rows, before);
      await db.query('DELETE FROM users WHERE id=$1', [other]);
      const added = (await db.query('INSERT INTO users(id) VALUES($1) RETURNING short_id', [other])).rows[0];
      assert.ok(BigInt(added.short_id) > BigInt(before[1].short_id));
      await assert.rejects(db.query('UPDATE users SET short_id=$1 WHERE id=$2', [before[0].short_id, other]), { code: '428C9' });
      await assert.rejects(db.query('UPDATE users SET short_id=NULL WHERE id=$1', [owner]), { code: '428C9' });
      await assert.rejects(db.query('INSERT INTO users(id,short_id) OVERRIDING SYSTEM VALUE VALUES(gen_random_uuid(),$1)', [before[0].short_id]), { code: '23505' });
      await assert.rejects(db.query('INSERT INTO users(id,short_id) VALUES(gen_random_uuid(),999)'), { code: '428C9' });
    } finally { await db.end(); }
  });
