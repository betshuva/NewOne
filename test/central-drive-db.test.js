'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { Pool, Client } = require('pg');
const central = require('../server/central-drive');
const personal = require('../server/personal-drive');
const digest = bytes => crypto.createHash('sha256').update(bytes).digest('hex');

test('central Drive storage migrates, restores, releases and deletes independently of personal backups', {
  skip: process.env.RUN_DB_TESTS !== '1',
}, async t => {
  const oldKey = process.env.BACKUP_TOKEN_ENCRYPTION_KEY;
  process.env.BACKUP_TOKEN_ENCRYPTION_KEY = 'test-only-central-drive-master-key-longer-than-32';
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'central-drive-'));
  const schema = `central_test_${crypto.randomBytes(8).toString('hex')}`;
  const lockKey = crypto.randomBytes(4).readInt32BE();
  const options = { connectionString: process.env.DATABASE_URL,
    ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: true } : false };
  const db = new Client(options); await db.connect(); let pool;
  t.after(async () => {
    if (pool) await pool.end();
    await db.query(`DROP SCHEMA IF EXISTS "${schema}" CASCADE`); await db.end();
    await fs.rm(root, { recursive: true, force: true });
    if (oldKey === undefined) delete process.env.BACKUP_TOKEN_ENCRYPTION_KEY;
    else process.env.BACKUP_TOKEN_ENCRYPTION_KEY = oldKey;
  });
  await db.query(`CREATE SCHEMA "${schema}"`);
  pool = new Pool({ ...options, options: `-c search_path=${schema}`, max: 4 });
  await pool.query(`CREATE TABLE stored_files(id UUID PRIMARY KEY,user_id UUID,storage_path TEXT,
    public_url TEXT,file_size BIGINT,mime_type TEXT,content_sha256 TEXT,moderation_status TEXT DEFAULT 'approved',
    moderation_details JSONB DEFAULT '{}',content_purged_at TIMESTAMPTZ,released_at TIMESTAMPTZ,created_at TIMESTAMPTZ DEFAULT now());
    CREATE TABLE pending_scans(file_url TEXT);
    CREATE TABLE cloud_backup_accounts(user_id UUID,status TEXT);
    CREATE TABLE deleted_media_sources(storage_path TEXT);
    CREATE TABLE media_backup_items(stored_file_id UUID,status TEXT);`);
  await pool.query(central.SCHEMA);
  await pool.query(`INSERT INTO central_drive_account(id,email,encrypted_token,enabled)
    VALUES(1,$1,$2,true)`, [central.ACCOUNT, personal.encryptRefreshToken('test-refresh', central.TOKEN_OWNER)]);
  const remote = new Map(), legacy = new Map();
  let corrupt = false, failUpload = false, failDelete = false, uploadHook = null, reservations = 0, quota = '10000000000';
  const fake = {
    identity: async () => ({ user: { emailAddress: central.ACCOUNT }, storageQuota: { limit: quota, usage: '0' } }),
    reserve: async () => { reservations++; return `remote-${crypto.randomUUID()}`; },
    upload: async (row, bytes) => {
      remote.set(row.remote_file_id, Buffer.from(bytes));
      if (uploadHook) await uploadHook(row);
      if (failUpload) throw new Error('simulated lost response after upload');
      return { id: row.remote_file_id };
    },
    download: async row => {
      if (!remote.has(row.remote_file_id)) throw new Error('missing remote');
      return corrupt ? Buffer.from('corrupt') : remote.get(row.remote_file_id);
    },
    remove: async id => { if (failDelete) throw new Error('provider offline'); remote.delete(id); },
  };
  const service = () => central.createCentralStorage({ getPool: async () => pool,
    uploadRoot: root, spoolRoot: path.join(root, 'spool'), makeTransport: () => fake, lockKey,
    readSource: async (_db, _root, file) => {
      try { return await fs.readFile(path.join(root, file.storage_path)); }
      catch (error) { if (error.code !== 'ENOENT') throw error;
        if (legacy.has(file.id)) return legacy.get(file.id); throw error; }
    } });
  async function seed({ local = true } = {}) {
    await pool.query('TRUNCATE stored_files CASCADE; TRUNCATE pending_scans,deleted_media_sources,media_backup_items,cloud_backup_accounts');
    await pool.query('UPDATE central_drive_account SET enabled=true');
    remote.clear(); legacy.clear(); corrupt = false; failUpload = false; failDelete = false; uploadHook = null; quota = '10000000000';
    const file = { id: crypto.randomUUID(), user_id: crypto.randomUUID(), storage_path: `${crypto.randomUUID()}.bin` };
    const plain = Buffer.from('private Hebrew media שלום ' + crypto.randomUUID());
    await pool.query(`INSERT INTO stored_files(id,user_id,storage_path,public_url,file_size,mime_type,content_sha256,released_at)
      VALUES($1,$2,$3,$4,$5,'application/octet-stream',$6,$7)`,
    [file.id, file.user_id, file.storage_path, `/uploads/${file.storage_path}`, plain.length, digest(plain), local ? null : new Date()]);
    if (local) await fs.writeFile(path.join(root, file.storage_path), plain);
    else legacy.set(file.id, plain);
    return { file, plain, filename: path.join(root, file.storage_path) };
  }
  await t.test('a user without personal backup gets encrypted central storage and verified release', async () => {
    const { file, plain, filename } = await seed();
    const result = await service().runBatch();
    assert.equal(result.transferred, 1); assert.equal(result.released, 1);
    await assert.rejects(fs.stat(filename), { code: 'ENOENT' });
    assert.notDeepEqual([...remote.values()][0], plain);
    assert.deepEqual(await central.readFile(pool, file, () => fake), plain);
    await assert.rejects(central.readFile(pool, { ...file, user_id: crypto.randomUUID() }, () => fake));
    await pool.query('UPDATE central_drive_account SET enabled=false');
    assert.deepEqual(await central.readFile(pool, file, () => fake), plain, 'pausing new transfers preserves old files');
    corrupt = true; await assert.rejects(central.readFile(pool, file, () => fake));
  });
  await t.test('connecting personal Drive prevents central uploads before tier migration, retaining existing delivery', async () => {
    const { file, plain, filename } = await seed();
    await pool.query("INSERT INTO cloud_backup_accounts VALUES($1,'connected')", [file.user_id]);
    assert.equal((await service().runBatch()).transferred, 0);
    assert.deepEqual(await fs.readFile(filename), plain);
    await pool.query('TRUNCATE cloud_backup_accounts');
    await service().runBatch();
    await pool.query("INSERT INTO cloud_backup_accounts VALUES($1,'connected')", [file.user_id]);
    assert.deepEqual(await central.readFile(pool, file, () => fake), plain);
  });
  await t.test('existing cloud-only personal media is migrated without recreating local bytes', async () => {
    const { file, plain, filename } = await seed({ local: false });
    const result = await service().runBatch();
    assert.equal(result.transferred, 1);
    assert.deepEqual(await central.readFile(pool, file, () => fake), plain);
    await assert.rejects(fs.stat(filename), { code: 'ENOENT' });
  });
  await t.test('rescans can read retained cloud bytes while public delivery stays blocked', async () => {
    const { file, plain } = await seed();
    await service().runBatch();
    await pool.query("UPDATE stored_files SET moderation_status='pending'");
    assert.equal(await central.deliveryRecord(pool, file.storage_path), null);
    assert.equal(await central.readFile(pool, file, () => fake), null);
    assert.deepEqual(await central.readFile(pool, file, () => fake, { forProcessing: true }), plain);
    await assert.rejects(central.readFile(pool, { ...file, user_id: crypto.randomUUID() }, () => fake,
      { forProcessing: true }));
    await pool.query('INSERT INTO deleted_media_sources(storage_path) VALUES($1)', [file.storage_path]);
    assert.equal(await central.readFile(pool, file, () => fake, { forProcessing: true }), null);
  });
  for (const condition of ["moderation_status='pending'", "moderation_status='rejected'",
    "moderation_status='stopped'", "moderation_details='{\"pending\":true}'", 'content_purged_at=now()']) {
    await t.test(`ineligible source remains local: ${condition}`, async () => {
      const { filename, plain } = await seed();
      await pool.query(`UPDATE stored_files SET ${condition}`);
      assert.equal((await service().runBatch()).transferred, 0);
      assert.deepEqual(await fs.readFile(filename), plain);
    });
  }
  await t.test('full cloud quota and corrupt verification retain the local source', async () => {
    const { filename, plain } = await seed(); quota = '1';
    assert.equal((await service().runBatch()).quotaFull, true); quota = '10000000000'; corrupt = true;
    assert.equal((await service().runBatch()).failed, 1);
    assert.deepEqual(await fs.readFile(filename), plain);
    assert.equal((await pool.query('SELECT status FROM central_drive_objects')).rows[0].status, 'failed');
  });
  await t.test('a lost upload response is recovered under the same reserved remote ID', async () => {
    const { file, plain } = await seed(); const before = reservations; failUpload = true;
    assert.equal((await service().runBatch()).failed, 1);
    await pool.query('UPDATE central_drive_objects SET next_attempt_at=now()'); failUpload = false;
    assert.equal((await service().runBatch()).transferred, 1);
    assert.equal(reservations, before + 1); assert.equal(remote.size, 1);
    assert.deepEqual(await central.readFile(pool, file, () => fake), plain);
  });
  await t.test('failed release transaction restores the local file', async () => {
    const { filename, plain } = await seed();
    await pool.query(`CREATE FUNCTION fail_release() RETURNS trigger AS $$ BEGIN
      IF NEW.released_at IS NOT NULL THEN RAISE EXCEPTION 'simulated release failure'; END IF; RETURN NEW;
      END; $$ LANGUAGE plpgsql;
      CREATE TRIGGER reject_release BEFORE UPDATE OF released_at ON stored_files FOR EACH ROW EXECUTE FUNCTION fail_release();`);
    try {
      assert.equal((await service().runBatch()).failed, 1);
      assert.deepEqual(await fs.readFile(filename), plain);
    } finally { await pool.query('DROP TRIGGER reject_release ON stored_files; DROP FUNCTION fail_release()'); }
  });
  await t.test('deleting a file mid-upload keeps a durable remote deletion record', async () => {
    const { file } = await seed();
    uploadHook = async () => pool.query('DELETE FROM stored_files WHERE id=$1', [file.id]);
    await service().runBatch({ limit: 1 });
    const row = (await pool.query('SELECT * FROM central_drive_objects')).rows[0];
    assert.equal(row.status, 'delete_pending'); assert.equal(row.file_id, null); assert.ok(row.remote_file_id);
    uploadHook = null; failDelete = true;
    assert.equal((await service().runBatch()).failed, 1); assert.equal(remote.size, 1);
    failDelete = false; await pool.query('UPDATE central_drive_objects SET next_attempt_at=now()');
    assert.equal((await service().runBatch()).deleted, 1); assert.equal(remote.size, 0);
  });
  await t.test('purging content and removing an account revoke delivery and enqueue cloud deletion', async () => {
    for (const change of ['content_purged_at=now()', 'user_id=NULL']) {
      const { file } = await seed(); await service().runBatch();
      await pool.query(`UPDATE stored_files SET ${change}`);
      assert.equal(await central.deliveryRecord(pool, file.storage_path), null);
      assert.equal((await service().runBatch()).deleted, 1); assert.equal(remote.size, 0);
    }
  });
});
