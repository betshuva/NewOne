'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const vm = require('node:vm');
const { wrapVaultKey, unwrapVaultKey } = require('../server/backup-vault-key');
const { encryptBuffer, decryptBuffer } = require('../server/media-backup-crypto');

test('actual backup worker saves explicitly requested Excel when automatic backup is off', {
  skip: process.env.RUN_DB_TESTS !== '1',
}, async t => {
  const { Client } = require('pg');
  const db = new Client({ connectionString: process.env.DATABASE_URL,
    ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' } : false });
  const oldKey = process.env.BACKUP_TOKEN_ENCRYPTION_KEY;
  process.env.BACKUP_TOKEN_ENCRYPTION_KEY = 'guide-export-integration-test-key-with-32-characters';
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'guide-backup-test-'));
  await db.connect();
  try {
    // Every write below targets session-local TEMP tables, never live records.
    await db.query(`CREATE TEMP TABLE stored_files(id uuid PRIMARY KEY,user_id uuid,storage_path text,
      file_size bigint,mime_type text,content_sha256 text,moderation_status text,
      created_at timestamptz DEFAULT now(),released_at timestamptz,content_purged_at timestamptz);
      CREATE TEMP TABLE user_backup_settings(user_id uuid PRIMARY KEY,enabled boolean,
        encrypted_data_key text,data_key_version integer);
      CREATE TEMP TABLE cloud_backup_accounts(user_id uuid PRIMARY KEY,provider text,status text,
        encrypted_refresh_token text);
      CREATE TEMP TABLE media_backup_items(id serial PRIMARY KEY,user_id uuid,stored_file_id uuid,
        provider text,status text,plaintext_sha256 text,encrypted_sha256 text,remote_file_id text,
        encryption_metadata jsonb,attempt_count integer DEFAULT 0,last_error text,
        verified_at timestamptz,updated_at timestamptz DEFAULT now(),
        UNIQUE(stored_file_id,provider));`);
    const userId = crypto.randomUUID();
    const fileId = crypto.randomUUID();
    const otherFileId = crypto.randomUUID();
    const key = crypto.randomBytes(32);
    const plain = Buffer.from('synthetic Excel bytes owned by fixture account');
    const hash = crypto.createHash('sha256').update(plain).digest('hex');
    await fs.writeFile(path.join(directory, 'fixture.xlsx'), plain);
    await db.query(`INSERT INTO user_backup_settings VALUES($1,FALSE,$2,1);
    `, [userId, wrapVaultKey(key, userId)]);
    await db.query("INSERT INTO cloud_backup_accounts VALUES($1,'google_drive','connected','fixture-token')", [userId]);
    for (const id of [fileId, otherFileId]) await db.query(`INSERT INTO stored_files
      (id,user_id,storage_path,file_size,mime_type,content_sha256,moderation_status)
      VALUES($1,$2,'fixture.xlsx',$3,'application/octet-stream',$4,'approved')`, [id,userId,plain.length,hash]);
    await db.query(`INSERT INTO media_backup_items(user_id,stored_file_id,provider,status,encryption_metadata)
      VALUES($1,$2,'google_drive','queued','{"guideRequested":true}')`, [userId,fileId]);
    const source = await fs.readFile(require.resolve('../server/index.js'), 'utf8');
    const start = source.indexOf('async function runAutomaticBackupWorker(');
    const end = source.indexOf('async function runAutomaticRestoreQueue(', start);
    const uploaded = [];
    const failures = [];
    let rejectUploads = true;
    const pool = { query: (...args) => db.query(...args), connect: async () => ({
      query: (...args) => db.query(...args), release() {},
    }) };
    const worker = vm.runInNewContext(`${source.slice(start, end)};runAutomaticBackupWorker`, {
      getPool: async () => pool, path, fs, crypto, Buffer, UPLOAD_ROOT: directory,
      unwrapVaultKey, encryptBackupBuffer: encryptBuffer, logActivity() {},
      console: { error: (...args) => failures.push(args.join(' ')) },
      personalDrive: {
        decryptRefreshToken: (encrypted, owner) => {
          assert.equal(encrypted, 'fixture-token'); assert.equal(owner, userId); return 'token';
        },
        uploadAppDataFile: async (token, name, bytes, mime, properties) => {
          if (rejectUploads) throw new Error('synthetic Drive outage');
          assert.equal(token, 'token');
          uploaded.push({ name, bytes: Buffer.from(bytes), mime, properties });
          return { id: `remote-${uploaded.length}` };
        },
        deleteAppDataFile: async () => {},
      },
    });
    await t.test('failed explicit backup retains its request and can retry', async () => {
      await worker(901); // Isolated advisory-lock key, separate from live workers.
      const row = (await db.query('SELECT * FROM media_backup_items WHERE stored_file_id=$1', [fileId])).rows[0];
      assert.equal(row.status, 'failed');
      assert.equal(row.encryption_metadata.guideRequested, true);
      assert.equal(row.attempt_count, 1);
      assert.equal(uploaded.length, 0);
      assert.match(failures[0], /synthetic Drive outage/);
      await db.query("UPDATE media_backup_items SET updated_at=now()-interval '11 minutes' WHERE stored_file_id=$1", [fileId]);
    });
    await t.test('retry uploads encrypted bytes and manifest without enabling other backups', async () => {
      rejectUploads = false;
      await worker(901);
      const row = (await db.query('SELECT * FROM media_backup_items WHERE stored_file_id=$1', [fileId])).rows[0];
      assert.equal(row.status, 'verified');
      assert.equal(row.attempt_count, 2);
      assert.equal(row.encryption_metadata.guideRequested, true);
      assert.equal(uploaded.length, 2);
      assert.notDeepEqual(uploaded[0].bytes, plain);
      const manifest = JSON.parse(uploaded[1].bytes.toString());
      const restored = decryptBuffer({ version: 1, ...manifest.encryption,
        ciphertext: uploaded[0].bytes }, key, manifest.encryption.associatedData);
      assert.deepEqual(restored, plain);
      assert.equal(manifest.storedFileId, fileId);
      assert.equal(row.encryption_metadata.manifestRemoteId, 'remote-2');
      assert.equal((await db.query('SELECT enabled FROM user_backup_settings WHERE user_id=$1', [userId])).rows[0].enabled, false);
      await worker(901);
      assert.equal(uploaded.length, 2);
      assert.equal((await db.query('SELECT 1 FROM media_backup_items WHERE stored_file_id=$1', [otherFileId])).rows.length, 0);
    });
  } finally {
    await db.end();
    await fs.rm(directory, { recursive: true, force: true });
    if (oldKey === undefined) delete process.env.BACKUP_TOKEN_ENCRYPTION_KEY;
    else process.env.BACKUP_TOKEN_ENCRYPTION_KEY = oldKey;
  }
});
