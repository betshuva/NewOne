'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const test = require('node:test');
const { Client } = require('pg');
const { createMaintenance } = require('../server/storage-quota');

test('personal storage maintenance waits for restore verification and rechecks under its lock', {
  skip: process.env.RUN_DB_TESTS !== '1',
}, async t => {
  const db = new Client({
    connectionString: process.env.DATABASE_URL,
    ssl: process.env.DB_SSL === 'true'
      ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' }
      : false,
  });
  await db.connect();
  t.after(() => db.end());
  await db.query('SET search_path=pg_temp');
  // All fixtures and mutations are session-local; no service worker or Drive
  // request is invoked by these tests.
  await db.query([
    'CREATE TEMP TABLE stored_files(id uuid PRIMARY KEY,user_id uuid,file_size bigint,',
    'content_sha256 text,storage_tier text,personal_storage_verified_at timestamptz,',
    'content_purged_at timestamptz,release_scheduled_at timestamptz,created_at timestamptz,',
    "moderation_status text,moderation_details jsonb,public_url text,storage_path text);",
    'CREATE TEMP TABLE media_backup_items(stored_file_id uuid PRIMARY KEY,user_id uuid,',
    'status text,remote_file_id text,encrypted_sha256 text,plaintext_sha256 text,',
    'encryption_metadata jsonb,restore_verified_at timestamptz,attempt_count integer,updated_at timestamptz);',
    'CREATE TEMP TABLE cloud_backup_accounts(user_id uuid,status text,encrypted_refresh_token text);',
    'CREATE TEMP TABLE user_backup_settings(user_id uuid,encrypted_data_key text);',
    'CREATE TEMP TABLE storage_upload_reservations(expires_at timestamptz);',
    'CREATE TEMP TABLE storage_drive_health(user_id uuid,ready_until timestamptz,token_hash text);',
    'CREATE TEMP TABLE pending_scans(file_url text);',
    'CREATE TEMP TABLE deleted_media_sources(storage_path text);',
    'CREATE TEMP TABLE central_drive_objects(file_id uuid,status text,next_attempt_at timestamptz);',
  ].join('\n'));
  const user = crypto.randomUUID();
  const file = crypto.randomUUID();
  const plain = Buffer.from('maintenance eligibility fixture bytes');
  const hash = crypto.createHash('sha256').update(plain).digest('hex');
  await db.query("INSERT INTO cloud_backup_accounts VALUES($1,'connected','fixture-token')", [user]);
  await db.query("INSERT INTO user_backup_settings VALUES($1,'fixture-key')", [user]);

  async function reset(restored) {
    await db.query('TRUNCATE stored_files,media_backup_items,central_drive_objects');
    await db.query('INSERT INTO stored_files(id,user_id,file_size,content_sha256,storage_tier,created_at,'
      + 'moderation_status,moderation_details,public_url,storage_path) VALUES'
      + "($1,$2,$3,$4,'personal',now(),'approved','{}','/fixture','fixture.bin')",
    [file,user,plain.length,hash]);
    await db.query('INSERT INTO media_backup_items(stored_file_id,user_id,status,plaintext_sha256,'
      + 'encryption_metadata,restore_verified_at,attempt_count) VALUES'
      + "($1,$2,'verified',$3,'{\"keySource\":\"server_vault\"}',$4,3)",
    [file,user,hash,restored ? new Date() : null]);
    await db.query("INSERT INTO central_drive_objects VALUES($1,'verified',NULL)", [file]);
  }

  let verifyCalls = 0;
  let withdrawRestoreAfterListing = false;
  let listed = [];
  const pool = {
    async query(sql, values) {
      const result = await db.query(sql, values);
      if (/SELECT sf\.id FROM stored_files sf/.test(sql)) {
        listed = result.rows.map(row => row.id);
        if (withdrawRestoreAfterListing && result.rows.length) {
          await db.query('UPDATE media_backup_items SET restore_verified_at=NULL WHERE stored_file_id=$1',
            [file]);
        }
      }
      return result;
    },
    async connect() {
      return { query: db.query.bind(db), release() {} };
    },
  };
  const tick = createMaintenance({
    getPool: async () => pool,
    verifyAccount: async () => {},
    lockKey: crypto.randomBytes(4).readInt32BE(),
    async verifyBytes(row) {
      verifyCalls++;
      assert.equal(row.id, file);
      assert.equal(row.plaintext_sha256, hash);
      assert.equal(row.content_sha256, hash);
      return Buffer.from(plain);
    },
  });

  await t.test('a pending restore never starts a competing cloud download', async () => {
    await reset(false);
    verifyCalls = 0;
    await tick();
    assert.deepEqual(listed, []);
    assert.equal(verifyCalls, 0);
    const row = (await db.query('SELECT personal_storage_verified_at,release_scheduled_at '
      + 'FROM stored_files WHERE id=$1', [file])).rows[0];
    assert.equal(row.personal_storage_verified_at, null);
    assert.equal(row.release_scheduled_at, null);
    assert.equal((await db.query('SELECT status FROM central_drive_objects WHERE file_id=$1',
      [file])).rows[0].status, 'verified');
  });

  await t.test('an older completed restore can still verify and retire its central copy', async () => {
    await reset(true);
    verifyCalls = 0;
    await tick();
    assert.deepEqual(listed, [file]);
    assert.equal(verifyCalls, 1);
    const row = (await db.query('SELECT personal_storage_verified_at,release_scheduled_at '
      + 'FROM stored_files WHERE id=$1', [file])).rows[0];
    assert.ok(row.personal_storage_verified_at);
    assert.ok(row.release_scheduled_at);
    assert.equal((await db.query('SELECT status FROM central_drive_objects WHERE file_id=$1',
      [file])).rows[0].status, 'delete_pending');
  });

  await t.test('a newly confirmed personal restore needs no redundant maintenance download', async () => {
    await reset(true);
    await db.query('UPDATE stored_files SET personal_storage_verified_at=now() WHERE id=$1', [file]);
    verifyCalls = 0;
    await tick();
    assert.deepEqual(listed, []);
    assert.equal(verifyCalls, 0);
  });

  await t.test('eligibility withdrawn after listing cannot pass the locked reread', async () => {
    await reset(true);
    verifyCalls = 0;
    withdrawRestoreAfterListing = true;
    await tick();
    assert.deepEqual(listed, [file], 'the file was a candidate before the state changed');
    assert.equal(verifyCalls, 0, 'the locked SELECT must honor pending restore state');
    const row = (await db.query('SELECT personal_storage_verified_at,release_scheduled_at '
      + 'FROM stored_files WHERE id=$1', [file])).rows[0];
    assert.equal(row.personal_storage_verified_at, null);
    assert.equal(row.release_scheduled_at, null);
    assert.equal((await db.query('SELECT status FROM media_backup_items WHERE stored_file_id=$1',
      [file])).rows[0].status, 'verified');
  });
});
