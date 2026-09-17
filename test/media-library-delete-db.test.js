'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { Client, Pool } = require('pg');
const { MEDIA_DELETE_SCHEMA, createMediaLibraryDeletion } = require('../server/media-library-delete');
const { RECEIVED_MEDIA_SCHEMA, createReceivedMediaService,
  personalizeReceivedMessages, retainVisibleReceivedMessages } = require('../server/received-media');

const id = n => `86000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const [alice, bob, carol, group, source, second, message] = [1, 2, 3, 4, 10, 11, 20].map(id);

test('explicit media deletion validates selections before accessing storage', async () => {
  const service = createMediaLibraryDeletion({ uploadRoot: '/not-used', secret: 'test' });
  const pool = { query() { assert.fail('invalid input reached storage'); }, connect() { assert.fail('invalid input reached storage'); } };
  for (const ids of [[], ['invalid'], null, Array.from({ length: 1001 }, (_, n) => id(n))])
    await assert.rejects(service.preview(pool, alice, { ids }), error => error.status === 400);
  await assert.rejects(service.confirm(pool, alice, { ids: [source], confirmationToken: 'made-up' }),
    error => error.code === 'INVALID_DELETE_CONFIRMATION');
});

test('confirmed personal deletion preserves received copies and checks concurrent delivery state', {
  skip: process.env.RUN_DB_TESTS !== '1',
}, async t => {
  const config = { connectionString: process.env.DATABASE_URL,
    ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' } : false };
  const admin = new Client(config);
  const schema = `media_delete_test_${crypto.randomBytes(10).toString('hex')}`;
  const uploadRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'media-delete-test-'));
  let pool;
  await admin.connect();
  try {
    await admin.query(`CREATE SCHEMA ${schema}`);
    pool = new Pool({ ...config, max: 8, options: `-c search_path=${schema}` });
    await pool.query(`
      CREATE TABLE users(id uuid PRIMARY KEY,name text,profile_pic_url text);
      CREATE TABLE groups(id uuid PRIMARY KEY,name text,profile_pic_url text);
      CREATE TABLE group_members(group_id uuid REFERENCES groups(id),user_id uuid REFERENCES users(id),
        status text DEFAULT 'member',joined_at timestamptz DEFAULT '2000-01-01',PRIMARY KEY(group_id,user_id));
      CREATE TABLE messages(id uuid DEFAULT gen_random_uuid() PRIMARY KEY,sender_id uuid REFERENCES users(id),
        recipient_id uuid REFERENCES users(id),group_id uuid REFERENCES groups(id),type text DEFAULT 'image',body text,
        file_url text,file_name text,file_size bigint,delivery_summary jsonb,created_at timestamptz DEFAULT now(),
        deleted_for_everyone boolean DEFAULT false,deleted_for_sender boolean DEFAULT false);
      CREATE TABLE message_user_deletions(message_id uuid,user_id uuid,PRIMARY KEY(message_id,user_id));
      CREATE TABLE conversation_user_state(user_id uuid,kind text,target_id uuid,cleared_at timestamptz,
        PRIMARY KEY(user_id,kind,target_id));
      CREATE TABLE stored_files(id uuid DEFAULT gen_random_uuid() PRIMARY KEY,user_id uuid REFERENCES users(id),
        original_name text NOT NULL,storage_path text NOT NULL UNIQUE,public_url text NOT NULL UNIQUE,
        file_type text DEFAULT 'image',mime_type text DEFAULT 'image/png',file_size bigint DEFAULT 4,
        content_sha256 text,moderation_status text DEFAULT 'approved',moderation_details jsonb,
        content_purged_at timestamptz,blocked_content_expires_at timestamptz,context_type text,context_id uuid,
        visual_fingerprint jsonb,released_at timestamptz,created_at timestamptz DEFAULT now());
      CREATE TABLE media_backup_items(stored_file_id uuid REFERENCES stored_files(id) ON DELETE CASCADE,
        provider text DEFAULT 'google_drive',status text,remote_file_id text,encryption_metadata jsonb,
        PRIMARY KEY(stored_file_id,provider));
      CREATE TABLE cloud_backup_accounts(user_id uuid,status text,encrypted_refresh_token text);
      CREATE TABLE pending_scans(id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,user_id uuid,
        to_user_id uuid,group_id uuid,file_url text,file_name text,file_type text);
      CREATE TABLE message_requests(id uuid DEFAULT gen_random_uuid() PRIMARY KEY,sender_id uuid,
        recipient_id uuid,file_url text);
      CREATE TABLE listings(id uuid PRIMARY KEY,image_url text,title text);
      CREATE TABLE listing_images(id uuid PRIMARY KEY,listing_id uuid,url text);
      CREATE TABLE education_forms(id uuid PRIMARY KEY,file_url text,file_name text,title text);
      CREATE TABLE shared_gifs(id uuid PRIMARY KEY,stored_file_id uuid REFERENCES stored_files(id) ON DELETE CASCADE,status text);
      CREATE TABLE app_settings(key_name text PRIMARY KEY,value text);
    `);
    await pool.query(RECEIVED_MEDIA_SCHEMA);
    await pool.query(MEDIA_DELETE_SCHEMA);
    const remoteDeleted = [];
    let driveFails = false;
    let time = Date.now();
    const service = createMediaLibraryDeletion({ uploadRoot, secret: 'isolated-test-secret', now: () => time,
      drive: { decryptRefreshToken(value) { return value; }, async deleteAppDataFile(_token, remoteId) {
        if (driveFails) throw new Error('isolated cloud failure');
        remoteDeleted.push(remoteId);
      } },
    });
    const receiver = createReceivedMediaService({ getPool: async () => pool, uploadRoot, publicBase: '/test-media' });
    const url = file => `/test-media/${file}.png`;
    const addFile = async (file = source, owner = alice) => {
      await fs.writeFile(path.join(uploadRoot, `${file}.png`), 'data');
      await pool.query(`INSERT INTO stored_files(id,user_id,original_name,storage_path,public_url,content_sha256,moderation_details)
        VALUES($1,$2,'original.png',$3,$4,$5,'{"classification":{"category":"men"}}')`,
      [file, owner, `${file}.png`, url(file), crypto.createHash('sha256').update('data').digest('hex')]);
    };
    const reset = async () => {
      await pool.query(`TRUNCATE users,groups,group_members,messages,message_user_deletions,conversation_user_state,
        stored_files,media_backup_items,cloud_backup_accounts,pending_scans,message_requests,listings,listing_images,
        education_forms,shared_gifs,personal_media_content,received_message_media,deleted_media_sources,media_deletion_jobs CASCADE`);
      await pool.query("INSERT INTO users(id,name) VALUES($1,'Alice'),($2,'Bob'),($3,'Carol')", [alice, bob, carol]);
      await pool.query("INSERT INTO groups(id,name) VALUES($1,'Friends')", [group]);
      await pool.query('INSERT INTO group_members(group_id,user_id) VALUES($1,$2),($1,$3),($1,$4)', [group, alice, bob, carol]);
      remoteDeleted.length = 0; driveFails = false;
      await addFile();
    };
    const send = async (recipient = bob, messageId = message) => pool.query(`INSERT INTO messages(id,sender_id,recipient_id,file_url,file_name)
      VALUES($1,$2,$3,$4,'original.png')`, [messageId, alice, recipient, url(source)]);
    const preview = (ids = [source], owner = alice) => service.preview(pool, owner, { ids });
    const confirm = (view, owner = alice) => service.confirm(pool, owner, { ids: view.ids, confirmationToken: view.confirmationToken });
    const sourceExists = async () => (await pool.query('SELECT 1 FROM stored_files WHERE id=$1', [source])).rowCount === 1;

    await t.test('owner checks precede reference details; signatures bind owner and exact IDs', async () => {
      await reset(); await send();
      await assert.rejects(preview([source], bob), error => error.status === 404);
      const view = await preview();
      assert.equal(view.pendingRecipients[0].name, 'Bob');
      await assert.rejects(confirm(view, bob), error => error.code === 'INVALID_DELETE_CONFIRMATION');
      await assert.rejects(service.confirm(pool, alice, { ids: [second], confirmationToken: view.confirmationToken }),
        error => error.code === 'INVALID_DELETE_CONFIRMATION');
      assert.equal(await sourceExists(), true);
    });

    await t.test('private pending copy is warned, cancelled only on confirmation, and cannot recover', async () => {
      await reset(); await send();
      const view = await preview();
      assert.equal(view.fileCount, 1); assert.equal(view.copyCount, 1); assert.equal(view.pendingCount, 1);
      assert.deepEqual(view.pendingRecipients, [{ id: bob, name: 'Bob', groupId: null, groupName: null, count: 1 }]);
      assert.equal(await sourceExists(), true); // Preview is strictly read only.
      assert.equal((await pool.query('SELECT status FROM received_message_media')).rows[0].status, 'queued');
      assert.deepEqual((await confirm(view)).deletedIds, [source]);
      assert.equal(await sourceExists(), false);
      assert.equal((await pool.query('SELECT status FROM received_message_media')).rows[0].status, 'skipped');
      assert.equal(await receiver.runOnce(), 0);
      await retainVisibleReceivedMessages(pool, bob, [{ id: message }]);
      assert.equal((await pool.query('SELECT status FROM received_message_media')).rows[0].status, 'skipped');
      const projected = await personalizeReceivedMessages(pool, bob, [{ id: message, file_url: url(source) }]);
      assert.equal(projected[0].file_deleted, true); assert.equal(projected[0].file_url, null);
      await assert.rejects(send(carol, id(21)), /MEDIA_DELETED/);
      await assert.rejects(pool.query('INSERT INTO pending_scans(user_id,to_user_id,file_url) VALUES($1,$2,$3)',
        [alice, carol, url(source)]), /MEDIA_DELETED/);
    });

    await t.test('received private copy survives original deletion and remains available to an offline recipient', async () => {
      await reset(); await send(); await receiver.runOnce();
      const own = (await pool.query('SELECT * FROM stored_files WHERE user_id=$1', [bob])).rows[0];
      const view = await preview();
      assert.equal(view.pendingCount, 0);
      await confirm(view);
      assert.equal(await fs.readFile(path.join(uploadRoot, own.storage_path), 'utf8'), 'data');
      assert.equal((await pool.query('SELECT file_url FROM messages WHERE id=$1', [message])).rows[0].file_url, url(source));
      const projected = await personalizeReceivedMessages(pool, bob, [{ id: message, file_url: url(source) }]);
      assert.equal(projected[0].file_url, own.public_url);
      assert.equal(projected[0].file_deleted, undefined);
      assert.equal((await pool.query('SELECT status,source_file_id FROM received_message_media')).rows[0].status, 'ready');
    });

    await t.test('group warning distinguishes durable copies, queued recipients and intentional skips', async () => {
      await reset();
      await pool.query(`INSERT INTO messages(id,sender_id,group_id,file_url,delivery_summary)
        VALUES($1,$2,$3,$4,$5)`, [message, alice, group, url(source), { deliveredTo: [{ id: bob }, { id: carol }] }]);
      await pool.query("UPDATE received_message_media SET next_attempt_at=now()+interval '1 day' WHERE user_id=$1", [carol]);
      await receiver.runOnce();
      let view = await preview();
      assert.equal(view.pendingCount, 1);
      assert.equal(view.pendingRecipients[0].groupName, 'Friends');
      await pool.query("UPDATE received_message_media SET status='skipped' WHERE status='queued'");
      view = await preview(); assert.equal(view.pendingCount, 0);
      const readyBefore = (await pool.query("SELECT stored_file_id FROM received_message_media WHERE status='ready'")).rows[0].stored_file_id;
      await confirm(view);
      assert.equal((await pool.query('SELECT 1 FROM stored_files WHERE id=$1', [readyBefore])).rowCount, 1);
    });

    await t.test('a new send or completed recipient copy requires a new confirmation', async () => {
      await reset(); const beforeSend = await preview(); await send();
      await assert.rejects(confirm(beforeSend), error => error.code === 'DELETE_PREVIEW_CHANGED' && error.preview.pendingCount === 1);
      const beforeCopy = await preview(); await receiver.runOnce();
      await assert.rejects(confirm(beforeCopy), error => error.code === 'DELETE_PREVIEW_CHANGED' && error.preview.pendingCount === 0);
      assert.equal(await sourceExists(), true);
      const expired = await preview(); time += 11 * 60 * 1000;
      await assert.rejects(confirm(expired), error => error.code === 'DELETE_PREVIEW_CHANGED');
      assert.equal(await sourceExists(), true);
    });

    await t.test('legacy history warns only visible readers, while an authorized queued copy survives a clear', async () => {
      await reset();
      await pool.query(`INSERT INTO messages(id,sender_id,group_id,file_url) VALUES($1,$2,$3,$4)`,
        [message, alice, group, url(source)]);
      await pool.query("UPDATE group_members SET joined_at=now()+interval '1 day' WHERE user_id=$1", [carol]);
      let view = await preview();
      assert.deepEqual(view.pendingRecipients.map(row => row.id), [bob]);
      await pool.query('INSERT INTO message_user_deletions VALUES($1,$2)', [message, bob]);
      view = await preview(); assert.equal(view.pendingCount, 0);
      await pool.query("INSERT INTO received_message_media(message_id,user_id,source_file_id,status) VALUES($1,$2,$3,'queued')",
        [message, bob, source]);
      view = await preview(); assert.equal(view.pendingCount, 1); assert.equal(view.pendingRecipients[0].id, bob);
      await confirm(view);
      assert.equal((await pool.query('SELECT status FROM received_message_media')).rows[0].status, 'skipped');
    });

    await t.test('pending scan and contact request are included and cancelled without deleting received messages', async () => {
      await reset();
      await pool.query('INSERT INTO pending_scans(user_id,to_user_id,file_url) VALUES($1,$2,$3)', [alice, bob, url(source)]);
      await pool.query('INSERT INTO message_requests(sender_id,recipient_id,file_url) VALUES($1,$2,$3)', [alice, carol, url(source)]);
      const view = await preview(); assert.equal(view.pendingCount, 2); assert.equal(view.pendingRecipientCount, 2);
      await confirm(view);
      assert.equal((await pool.query('SELECT 1 FROM pending_scans')).rowCount, 0);
      assert.equal((await pool.query('SELECT 1 FROM message_requests')).rowCount, 0);
    });

    await t.test('linked media uses are disclosed and detached while enclosing records remain', async () => {
      await reset();
      await pool.query('UPDATE users SET profile_pic_url=$1 WHERE id=$2', [url(source), alice]);
      await pool.query('UPDATE groups SET profile_pic_url=$1 WHERE id=$2', [url(source), group]);
      await pool.query("INSERT INTO listings VALUES($1,$2,'listing')", [id(50), url(source)]);
      await pool.query('INSERT INTO listing_images VALUES($1,$2,$3)', [id(51), id(50), url(source)]);
      await pool.query("INSERT INTO education_forms VALUES($1,$2,'original.png','form')", [id(52), url(source)]);
      await pool.query("INSERT INTO shared_gifs VALUES($1,$2,'active')", [id(53), source]);
      const view = await preview(); assert.equal(view.linkedUses.length, 6);
      await confirm(view);
      assert.equal((await pool.query('SELECT title,image_url FROM listings')).rows[0].title, 'listing');
      assert.equal((await pool.query('SELECT image_url FROM listings')).rows[0].image_url, null);
      assert.equal((await pool.query('SELECT file_url,file_name FROM education_forms')).rows[0].file_url, null);
      assert.equal((await pool.query('SELECT name FROM groups')).rows[0].name, 'Friends');
      assert.equal((await pool.query('SELECT 1 FROM shared_gifs')).rowCount, 0);
      await assert.rejects(pool.query('UPDATE groups SET profile_pic_url=$1 WHERE id=$2', [url(source), group]), /MEDIA_DELETED/);
    });

    await t.test('backup failures are reported per file without cancelling that file’s deliveries', async () => {
      await reset(); await send(); await addFile(second);
      await pool.query("INSERT INTO media_backup_items(stored_file_id,status,remote_file_id) VALUES($1,'verified','cloud')", [source]);
      let view = await preview([source, second]); assert.equal(view.hasBackup, true); assert.equal(view.fileCount, 1); assert.equal(view.copyCount, 2);
      let result = await confirm(view);
      assert.deepEqual(result.deletedIds, [second]); assert.equal(result.failed[0].code, 'BACKUP_RECONNECT_REQUIRED');
      assert.equal((await pool.query('SELECT status FROM received_message_media')).rows[0].status, 'queued');
      assert.equal(await sourceExists(), true);
      await pool.query("INSERT INTO cloud_backup_accounts VALUES($1,'connected','isolated-token')", [alice]);
      driveFails = true; view = await preview(); result = await confirm(view);
      assert.equal(result.failed.length, 0); assert.equal(await sourceExists(), false);
      assert.deepEqual(result.deletedIds, [source]); assert.equal(result.cleanupPendingCount, 1);
      assert.equal(result.cleanupPendingBytes, 4); assert.equal(result.deletedBytes, 0);
      assert.equal((await pool.query('SELECT 1 FROM deleted_media_sources WHERE public_url=$1', [url(source)])).rowCount, 1);
      await service.cleanup(pool);
      await assert.rejects(fs.access(path.join(uploadRoot, `${source}.png`)), error => error.code === 'ENOENT');
      driveFails = false;
      await pool.query('UPDATE media_deletion_jobs SET next_attempt_at=now()');
      await service.cleanup(pool);
      assert.equal((await pool.query('SELECT 1 FROM media_deletion_jobs')).rowCount, 0);
      assert.deepEqual(remoteDeleted, ['cloud']);
    });

    await t.test('deletion of a received personal copy never falls back to the sender source', async () => {
      await reset(); await send(); await receiver.runOnce();
      const copy = (await pool.query('SELECT id FROM stored_files WHERE user_id=$1', [bob])).rows[0].id;
      await confirm(await preview([copy], bob), bob);
      assert.equal(await sourceExists(), true);
      const projected = await personalizeReceivedMessages(pool, bob, [{ id: message, file_url: url(source) }]);
      assert.equal(projected[0].file_deleted, true); assert.equal(projected[0].file_url, null);
      await retainVisibleReceivedMessages(pool, bob, [{ id: message }]);
      assert.equal(await receiver.runOnce(), 0);
    });

    await t.test('an in-flight recipient worker commits before deletion rechecks its preview', async () => {
      await reset(); await send(); const view = await preview();
      const worker = await pool.connect();
      try {
        await worker.query('BEGIN');
        await worker.query('SELECT * FROM received_message_media WHERE message_id=$1 FOR UPDATE', [message]);
        const deleting = confirm(view);
        await worker.query("UPDATE received_message_media SET status='skipped' WHERE message_id=$1", [message]);
        await worker.query('COMMIT');
        await assert.rejects(deleting, error => error.code === 'DELETE_PREVIEW_CHANGED');
        assert.equal(await sourceExists(), true);
      } finally { await worker.query('ROLLBACK').catch(() => {}); worker.release(); }
    });

    await t.test('a stale concurrent sender blocked on source SHARE cannot publish after deletion', async () => {
      await reset(); const view = await preview();
      let startDelete, allowDelete;
      const started = new Promise(resolve => { startDelete = resolve; });
      const allowed = new Promise(resolve => { allowDelete = resolve; });
      const gatedPool = { query: pool.query.bind(pool), async connect() {
        const client = await pool.connect(); let mutated = false;
        return { release: () => client.release(), async query(sql, args) {
          if (sql.startsWith('DELETE FROM stored_files')) mutated = true;
          if (sql === 'COMMIT' && mutated) { startDelete(); await allowed; }
          return client.query(sql, args);
        } };
      } };
      const deleting = service.confirm(gatedPool, alice, view);
      await started;
      const staleSend = send(bob).then(() => null, error => error);
      allowDelete();
      assert.deepEqual((await deleting).deletedIds, [source]);
      assert.match((await staleSend).message, /MEDIA_DELETED/);
      assert.equal((await pool.query('SELECT 1 FROM messages')).rowCount, 0);
    });

    await t.test('a SQL deletion failure leaves original bytes, deliveries and backup data intact', async () => {
      await reset(); await send();
      const faultPool = { query: pool.query.bind(pool), async connect() {
        const client = await pool.connect();
        return { release: () => client.release(), query(sql, args) {
          if (sql.startsWith('DELETE FROM stored_files')) throw new Error('isolated SQL delete failure');
          return client.query(sql, args);
        } };
      } };
      const result = await service.confirm(faultPool, alice, await preview());
      assert.equal(result.failed.length, 1); assert.deepEqual(result.deletedIds, []);
      assert.equal(await sourceExists(), true);
      assert.equal(await fs.readFile(path.join(uploadRoot, `${source}.png`), 'utf8'), 'data');
      assert.equal((await pool.query('SELECT status FROM received_message_media')).rows[0].status, 'queued');
      assert.equal((await pool.query('SELECT 1 FROM media_deletion_jobs')).rowCount, 0);
      assert.equal((await pool.query('SELECT 1 FROM deleted_media_sources')).rowCount, 0);
      assert.equal(remoteDeleted.length, 0);
    });

    await t.test('a failed logical COMMIT cannot perform any filesystem or cloud deletion', async () => {
      await reset(); await send();
      await pool.query("INSERT INTO media_backup_items(stored_file_id,status,remote_file_id) VALUES($1,'verified','cloud')", [source]);
      await pool.query("INSERT INTO cloud_backup_accounts VALUES($1,'connected','isolated-token')", [alice]);
      const faultPool = { query: pool.query.bind(pool), async connect() {
        const client = await pool.connect(); let mutated = false;
        return { release: () => client.release(), query(sql, args) {
          if (sql.startsWith('DELETE FROM stored_files')) mutated = true;
          if (sql === 'COMMIT' && mutated) throw new Error('isolated COMMIT failure');
          return client.query(sql, args);
        } };
      } };
      await assert.rejects(service.confirm(faultPool, alice, await preview()), /isolated COMMIT failure/);
      assert.equal(await sourceExists(), true);
      assert.equal(await fs.readFile(path.join(uploadRoot, `${source}.png`), 'utf8'), 'data');
      assert.equal(remoteDeleted.length, 0);
      assert.equal((await pool.query('SELECT 1 FROM media_deletion_jobs')).rowCount, 0);
      assert.equal((await pool.query('SELECT status FROM received_message_media')).rows[0].status, 'queued');
    });

    await t.test('partial Drive cleanup persists progress and finishes after a new worker starts', async () => {
      await reset();
      await pool.query(`INSERT INTO media_backup_items(stored_file_id,status,remote_file_id,encryption_metadata)
        VALUES($1,'verified','payload','{"manifestRemoteId":"manifest"}')`, [source]);
      await pool.query("INSERT INTO cloud_backup_accounts VALUES($1,'connected','isolated-token')", [alice]);
      const removed = [];
      const flaky = createMediaLibraryDeletion({ uploadRoot, secret: 'flaky', drive: {
        decryptRefreshToken(value) { return value; }, async deleteAppDataFile(_refresh, remote) {
          if (remote === 'manifest') throw new Error('isolated manifest failure');
          removed.push(remote);
        },
      } });
      const result = await flaky.confirm(pool, alice, await flaky.preview(pool, alice, { ids: [source] }));
      assert.deepEqual(result.deletedIds, [source]); assert.deepEqual(result.failed, []);
      assert.equal(result.cleanupPendingCount, 1); assert.equal(await sourceExists(), false);
      await flaky.cleanup(pool);
      const job = (await pool.query('SELECT * FROM media_deletion_jobs')).rows[0];
      assert.equal(job.local_deleted, true); assert.equal(job.cloud_payload_deleted, true);
      assert.equal(job.cloud_manifest_deleted, false); assert.deepEqual(removed, ['payload']);
      const restarted = createMediaLibraryDeletion({ uploadRoot, drive: {
        decryptRefreshToken(value) { return value; }, async deleteAppDataFile(_refresh, remote) { removed.push(remote); },
      } });
      await pool.query('UPDATE media_deletion_jobs SET next_attempt_at=now()');
      await restarted.cleanup(pool);
      assert.deepEqual(removed, ['payload', 'manifest']);
      assert.equal((await pool.query('SELECT 1 FROM media_deletion_jobs')).rowCount, 0);
    });

    await t.test('cleanup SQL failure after unlink retains a retryable job without resurrecting metadata', async () => {
      await reset();
      const faultPool = { query: pool.query.bind(pool), async connect() {
        const client = await pool.connect();
        return { release: () => client.release(), query(sql, args) {
          if (sql.startsWith('UPDATE media_deletion_jobs SET local_deleted')) throw new Error('isolated progress failure');
          return client.query(sql, args);
        } };
      } };
      const result = await service.confirm(faultPool, alice, await preview());
      assert.deepEqual(result.deletedIds, [source]); assert.deepEqual(result.failed, []);
      assert.equal(result.cleanupPendingCount, 1); assert.equal(await sourceExists(), false);
      await assert.rejects(fs.access(path.join(uploadRoot, `${source}.png`)), error => error.code === 'ENOENT');
      await pool.query('UPDATE media_deletion_jobs SET next_attempt_at=now()');
      await service.cleanup(pool);
      assert.equal((await pool.query('SELECT 1 FROM media_deletion_jobs')).rowCount, 0);
    });
  } finally {
    if (pool) await pool.end();
    await admin.query(`DROP SCHEMA IF EXISTS ${schema} CASCADE`);
    await admin.end();
    await fs.rm(uploadRoot, { recursive: true, force: true });
  }
});
