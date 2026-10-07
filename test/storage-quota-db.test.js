'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { Pool, Client } = require('pg');
const quota = require('../server/storage-quota');

test('storage allowance, reservations and personal Drive migration', {
  skip: process.env.RUN_DB_TESTS !== '1',
}, async t => {
  const schema = `quota_test_${crypto.randomBytes(8).toString('hex')}`;
  const options = { connectionString: process.env.DATABASE_URL };
  const db = new Client(options); await db.connect();
  await db.query(`CREATE SCHEMA "${schema}"`);
  const pool = new Pool({ ...options, options: `-c search_path=${schema}`, max: 5 });
  t.after(async () => { await pool.end(); await db.query(`DROP SCHEMA "${schema}" CASCADE`); await db.end(); });
  await pool.query(`CREATE TABLE users(id UUID PRIMARY KEY);
    CREATE TABLE stored_files(id UUID PRIMARY KEY DEFAULT gen_random_uuid(),user_id UUID,
      file_size BIGINT,content_sha256 TEXT,content_purged_at TIMESTAMPTZ,released_at TIMESTAMPTZ,
      release_scheduled_at TIMESTAMPTZ,moderation_status TEXT DEFAULT 'approved',
      moderation_details JSONB DEFAULT '{}',public_url TEXT,storage_path TEXT,created_at TIMESTAMPTZ DEFAULT now());
    CREATE TABLE cloud_backup_accounts(user_id UUID PRIMARY KEY,status TEXT,encrypted_refresh_token TEXT);
    CREATE TABLE user_backup_settings(user_id UUID PRIMARY KEY,provider TEXT,encrypted_data_key TEXT,data_key_version INTEGER);
    CREATE TABLE pending_scans(file_url TEXT);
    CREATE TABLE deleted_media_sources(storage_path TEXT);
    CREATE TABLE media_backup_items(stored_file_id UUID PRIMARY KEY,user_id UUID,status TEXT,remote_file_id TEXT,
      encrypted_sha256 TEXT,plaintext_sha256 TEXT,encryption_metadata JSONB,attempt_count INTEGER DEFAULT 0,updated_at TIMESTAMPTZ);
    CREATE TABLE central_drive_objects(id UUID DEFAULT gen_random_uuid(),file_id UUID,status TEXT,next_attempt_at TIMESTAMPTZ);`);
  await pool.query(quota.SCHEMA);
  async function owner() {
    const id = crypto.randomUUID(); await pool.query('INSERT INTO users VALUES($1)', [id]); return id;
  }
  async function insert(user, size, hash = crypto.randomBytes(32).toString('hex'), reservation = null) {
    return (await pool.query(`INSERT INTO stored_files(user_id,file_size,content_sha256,quota_reservation)
      VALUES($1,$2,$3,$4) RETURNING *`, [user, size, hash, reservation])).rows[0];
  }
  async function connect(user, free = 1e10) {
    await pool.query("INSERT INTO cloud_backup_accounts VALUES($1,'connected','opaque-test-token')", [user]);
    await pool.query("INSERT INTO user_backup_settings(user_id,encrypted_data_key) VALUES($1,'key')", [user]);
    await pool.query(`INSERT INTO storage_drive_health(user_id,token_hash,ready_until,free_bytes)
      VALUES($1,encode(sha256(convert_to('opaque-test-token','UTF8')),'hex'),now()+interval '1 hour',$2)`, [user, free]);
  }
  await t.test('2 GB boundary is exact, all content types count, duplicates count once and deletion frees space', async () => {
    const user = await owner(); const hash = crypto.randomBytes(32).toString('hex');
    const first = await insert(user, quota.LIMIT, hash);
    const duplicate = await insert(user, quota.LIMIT, hash);
    assert.equal((await quota.status(pool, user)).usedBytes, quota.LIMIT);
    await assert.rejects(insert(user, 1), { code: 'P2001' });
    await pool.query('DELETE FROM stored_files WHERE id=$1', [first.id]);
    assert.equal((await quota.status(pool, user)).usedBytes, quota.LIMIT);
    await pool.query('DELETE FROM stored_files WHERE id=$1', [duplicate.id]);
    assert.equal((await quota.status(pool, user)).usedBytes, 0);
    await insert(user, 1);
  });
  await t.test('parallel inserts cannot overrun the quota', async () => {
    const user = await owner(); await insert(user, quota.LIMIT - 10);
    const results = await Promise.allSettled([insert(user, 8), insert(user, 8)]);
    assert.equal(results.filter(r => r.status === 'fulfilled').length, 1);
    assert.equal((await quota.status(pool, user)).usedBytes, quota.LIMIT - 2);
  });
  await t.test('upload reservations prevent parallel session bypass and are consumed atomically', async () => {
    const user = await owner(); await insert(user, quota.LIMIT - 10);
    const reservation = crypto.randomUUID(); await quota.reserve(pool, user, reservation, 8);
    await assert.rejects(quota.reserve(pool, user, crypto.randomUUID(), 8), { code: 'P2001' });
    await insert(user, 8, undefined, reservation);
    const state = await quota.status(pool, user);
    assert.equal(state.reservedBytes, 0); assert.equal(state.usedBytes, quota.LIMIT - 2);
    const other = await owner(); const occupied = crypto.randomUUID(); await quota.reserve(pool, other, occupied, 1);
    await assert.rejects(quota.reserve(pool, user, occupied, 1), { status: 409 });
  });
  await t.test('notifications precede the limit at 80%, 90% and 95%', async () => {
    const user = await owner();
    for (const [bytes, level] of [[1599999999,0],[1,80],[200000000,90],[100000000,95],[100000000,100]]) {
      await insert(user, bytes); assert.equal((await quota.status(pool, user)).warningLevel, level);
    }
  });
  await t.test('connected Drive receives even small files and unavailable, full or overloaded Drive blocks safely', async () => {
    const user = await owner(); await connect(user);
    const file = await insert(user, 100);
    assert.equal(file.storage_tier, 'personal'); assert.equal((await quota.status(pool, user)).usedBytes, 0);
    await pool.query("UPDATE storage_drive_health SET ready_until=now()-interval '1 second' WHERE user_id=$1", [user]);
    await assert.rejects(insert(user, 100), { code: 'P2001' });
    await pool.query("UPDATE storage_drive_health SET ready_until=now()+interval '1 hour',free_bytes=10 WHERE user_id=$1", [user]);
    await assert.rejects(insert(user, 100), { code: 'P2003' });
    await pool.query('UPDATE storage_drive_health SET free_bytes=10000000000 WHERE user_id=$1', [user]);
    await assert.rejects(insert(user, 512*1024*1024), { code: 'P2002' });
    const largeOwner = await owner(); await connect(largeOwner);
    const reservation = crypto.randomUUID();
    assert.equal(await quota.reserve(pool, largeOwner, reservation, 3000000000), 'personal');
    await assert.rejects(quota.reserve(pool, largeOwner, crypto.randomUUID(), 1), { code: 'P2002' });
    await quota.release(pool, largeOwner, reservation);
    assert.equal((await insert(largeOwner, 3000000000)).storage_tier, 'personal');
    await assert.rejects(insert(largeOwner, 1), { code: 'P2002' });
  });
  await t.test('all old files migrate on connection and central copies retire only after a fresh successful read', async () => {
    const user = await owner(); const source = await insert(user, 100);
    await pool.query("INSERT INTO central_drive_objects(file_id,status) VALUES($1,'verified')", [source.id]);
    await pool.query(`INSERT INTO media_backup_items(stored_file_id,user_id,status,plaintext_sha256,encryption_metadata)
      VALUES($1,$2,'verified',$3,'{"keySource":"server_vault"}')`, [source.id, user, source.content_sha256]);
    await connect(user); await quota.queueUserMigration(pool, user);
    assert.equal((await pool.query('SELECT storage_tier FROM stored_files WHERE id=$1',[source.id])).rows[0].storage_tier,'personal');
    const maintenance = verifyBytes => quota.createMaintenance({ getPool: async () => pool,
      verifyAccount: async () => {}, verifyBytes, lockKey: crypto.randomBytes(4).readInt32BE() });
    await maintenance(async () => { throw Error('unavailable'); })();
    assert.equal((await pool.query('SELECT status FROM central_drive_objects WHERE file_id=$1',[source.id])).rows[0].status,'verified');
    await pool.query("UPDATE media_backup_items SET status='verified' WHERE stored_file_id=$1",[source.id]);
    await maintenance(async () => Buffer.alloc(100))();
    assert.equal((await pool.query('SELECT status FROM central_drive_objects WHERE file_id=$1',[source.id])).rows[0].status,'delete_pending');
  });
  await t.test('completed blocked scans migrate to personal storage, active scans remain untouched', async () => {
    const user = await owner();
    const files = [];
    for (const status of ['rejected','stopped','pending']) {
      const file = await insert(user, 100);
      await pool.query('UPDATE stored_files SET moderation_status=$2 WHERE id=$1', [file.id,status]);
      files.push(file);
    }
    await connect(user);
    await quota.queueUserMigration(pool, user);
    for (let i = 0; i < files.length; i++) {
      const row = (await pool.query('SELECT storage_tier,moderation_status FROM stored_files WHERE id=$1',[files[i].id])).rows[0];
      assert.equal(row.storage_tier, i === 2 ? 'service' : 'personal');
    }
    const file = files[0];
    await pool.query(`INSERT INTO media_backup_items(stored_file_id,user_id,status,plaintext_sha256,encryption_metadata)
      VALUES($1,$2,'verified',$3,'{"keySource":"server_vault"}')`, [file.id,user,file.content_sha256]);
    await quota.createMaintenance({ getPool: async () => pool, verifyAccount: async () => {},
      verifyBytes: async () => Buffer.alloc(100), lockKey: crypto.randomBytes(4).readInt32BE() })();
    assert.ok((await pool.query('SELECT personal_storage_verified_at FROM stored_files WHERE id=$1',[file.id])).rows[0].personal_storage_verified_at);
  });
});
