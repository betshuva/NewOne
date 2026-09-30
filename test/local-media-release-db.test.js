'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { Client } = require('pg');
const drive = require('../server/personal-drive');
const { createVaultKey, wrapVaultKey } = require('../server/backup-vault-key');
const { encryptBuffer } = require('../server/media-backup-crypto');
const { releaseLocalMediaBatch } = require('../server/local-media-release');

test('automatic local release verifies live cloud bytes and preserves active references', {
  skip: process.env.RUN_DB_TESTS !== '1',
}, async t => {
  const db = new Client({ connectionString: process.env.DATABASE_URL,
    ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' } : false });
  await db.connect();
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'release-test-'));
  const previous = process.env.BACKUP_TOKEN_ENCRYPTION_KEY;
  process.env.BACKUP_TOKEN_ENCRYPTION_KEY = 'test-only-release-master-key-longer-than-32-bytes';
  const remote = new Map();
  t.mock.method(drive, 'downloadAppDataFile', async (_token, id) => {
    if (!remote.has(id)) throw new Error('Remote file unavailable');
    return remote.get(id);
  });
  const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
  let failUpdate = false;
  const pool = {
    query: (...args) => db.query(...args),
    connect: async () => ({ release() {}, query(sql, args) {
      if (failUpdate && sql.startsWith('UPDATE stored_files SET released_at')) {
        failUpdate = false;
        throw new Error('Injected database failure');
      }
      return db.query(sql, args);
    } }),
  };
  const errors = [];
  const run = () => releaseLocalMediaBatch({ pool, uploadRoot: root,
    onError: (_id, error) => errors.push(error.message) });
  const id = crypto.randomUUID();
  const user = crypto.randomUUID();
  const plain = Buffer.from('media still referenced by private and group messages');
  const file = path.join(root, 'media.bin');
  async function seed() {
    await db.query('TRUNCATE stored_files,media_backup_items,user_backup_settings,cloud_backup_accounts,pending_scans,messages');
    const key = createVaultKey();
    const encrypted = encryptBuffer(plain, key, 'owner-bound');
    remote.set('remote', encrypted.ciphertext);
    await fs.writeFile(file, plain);
    await db.query(`INSERT INTO stored_files VALUES($1,$2,'media.bin','/uploads/media.bin',$3,$4,'approved',NULL,NULL,NULL,now())`,
      [id,user,plain.length,hash(plain)]);
    await db.query(`INSERT INTO media_backup_items VALUES($1,$2,'google_drive','verified','remote',now(),$3,$4,$5)`,
      [id,user,hash(encrypted.ciphertext),hash(plain),JSON.stringify({ ...encrypted,
        ciphertext: undefined, associatedData: 'owner-bound', keySource: 'server_vault' })]);
    await db.query('INSERT INTO user_backup_settings VALUES($1,TRUE,$2)', [user,wrapVaultKey(key,user)]);
    await db.query("INSERT INTO cloud_backup_accounts VALUES($1,'google_drive','connected',$2)",
      [user,drive.encryptRefreshToken('test-refresh',user)]);
    await db.query("INSERT INTO messages VALUES('/uploads/media.bin')");
  }
  try {
    await db.query(`SET search_path=pg_temp;
      CREATE TEMP TABLE stored_files(id uuid,user_id uuid,storage_path text,public_url text,
        file_size bigint,content_sha256 text,moderation_status text,moderation_details jsonb,
        content_purged_at timestamptz,released_at timestamptz,release_scheduled_at timestamptz);
      CREATE TEMP TABLE media_backup_items(stored_file_id uuid,user_id uuid,provider text,status text,
        remote_file_id text,restore_verified_at timestamptz,encrypted_sha256 text,plaintext_sha256 text,encryption_metadata jsonb);
      CREATE TEMP TABLE user_backup_settings(user_id uuid,enabled boolean,encrypted_data_key text);
      CREATE TEMP TABLE cloud_backup_accounts(user_id uuid,provider text,status text,encrypted_refresh_token text);
      CREATE TEMP TABLE pending_scans(file_url text);
      CREATE TEMP TABLE messages(file_url text);`);
    await t.test('active message remains linked while only local bytes are removed', async () => {
      await seed();
      const result = await run();
      assert.equal(result.released, 1);
      assert.equal(result.bytes, plain.length);
      await assert.rejects(fs.stat(file), { code: 'ENOENT' });
      assert.ok((await db.query('SELECT released_at FROM stored_files')).rows[0].released_at);
      assert.equal((await db.query('SELECT * FROM messages')).rowCount, 1);
      assert.equal((await db.query('SELECT * FROM media_backup_items')).rowCount, 1);
      assert.equal((await run()).released, 0);
    });
    for (const condition of [
      "UPDATE user_backup_settings SET enabled=FALSE",
      "UPDATE cloud_backup_accounts SET status='error'",
      'UPDATE media_backup_items SET restore_verified_at=NULL',
      "UPDATE media_backup_items SET user_id='11111111-1111-4111-8111-111111111111'",
      "UPDATE stored_files SET moderation_status='pending'",
      "UPDATE stored_files SET moderation_details='{\"pending\":true}'",
      'UPDATE stored_files SET content_purged_at=now()',
      'UPDATE stored_files SET release_scheduled_at=NULL',
      "INSERT INTO pending_scans VALUES('/uploads/media.bin')",
    ]) {
      await t.test(`ineligible file stays local: ${condition}`, async () => {
        await seed(); await db.query(condition);
        assert.equal((await run()).released, 0);
        assert.deepEqual(await fs.readFile(file), plain);
      });
    }
    for (const broken of ['missing', 'corrupt', 'wrong-key']) {
      await t.test(`${broken} backup retains local bytes and defers retry`, async () => {
        await seed();
        if (broken === 'missing') remote.delete('remote');
        if (broken === 'corrupt') remote.set('remote', Buffer.from('corrupt'));
        if (broken === 'wrong-key') await db.query('UPDATE user_backup_settings SET encrypted_data_key=$1',
          [wrapVaultKey(createVaultKey(),user)]);
        assert.equal((await run()).failed, 1);
        assert.deepEqual(await fs.readFile(file), plain);
        assert.equal((await run()).examined, 0);
      });
    }
    await t.test('failed database update restores the local bytes', async () => {
      await seed(); failUpdate = true;
      assert.equal((await run()).failed, 1);
      assert.deepEqual(await fs.readFile(file), plain);
      assert.equal((await db.query('SELECT released_at FROM stored_files')).rows[0].released_at, null);
    });
  } finally {
    if (previous === undefined) delete process.env.BACKUP_TOKEN_ENCRYPTION_KEY;
    else process.env.BACKUP_TOKEN_ENCRYPTION_KEY = previous;
    await db.end();
    await fs.rm(root, { recursive: true, force: true });
  }
});
