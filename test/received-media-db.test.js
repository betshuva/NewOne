'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { Client, Pool } = require('pg');

const id = n => `70000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const [alice, bob, carol, david, group] = [1, 2, 3, 4, 5].map(id);
const sha256 = bytes => crypto.createHash('sha256').update(bytes).digest('hex');

test('received media has independent ownership and deduplicates actual content per account', {
  skip: process.env.RUN_DB_TESTS !== '1',
}, async t => {
  const { RECEIVED_MEDIA_SCHEMA, migrateReceivedMedia, createReceivedMediaService,
    retainVisibleReceivedMessages, personalizeReceivedMessages } = require('../server/received-media');
  const config = {
    connectionString: process.env.DATABASE_URL,
    ssl: process.env.DB_SSL === 'true'
      ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' } : false,
  };
  const admin = new Client(config);
  // Separate connections are necessary to test real concurrent transactions.
  // The unique schema has no public fallback: missing fixtures fail closed.
  const schema = `received_media_test_${crypto.randomBytes(10).toString('hex')}`;
  const uploadRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'received-media-test-'));
  let pool;
  await admin.connect();
  try {
    await admin.query(`CREATE SCHEMA ${schema}`);
    pool = new Pool({ ...config, max: 6, options: `-c search_path=${schema}` });
    await pool.query(`
      CREATE TABLE users(id uuid PRIMARY KEY);
      CREATE TABLE groups(id uuid PRIMARY KEY);
      CREATE TABLE group_members(group_id uuid REFERENCES groups(id) ON DELETE CASCADE,
        user_id uuid REFERENCES users(id) ON DELETE CASCADE,status text DEFAULT 'member',
        joined_at timestamptz DEFAULT '2000-01-01',PRIMARY KEY(group_id,user_id));
      CREATE TABLE messages(id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
        sender_id uuid REFERENCES users(id) ON DELETE CASCADE,
        recipient_id uuid REFERENCES users(id) ON DELETE CASCADE,
        group_id uuid REFERENCES groups(id) ON DELETE CASCADE,
        type text DEFAULT 'image',body text,file_url text,file_name text,file_size bigint,
        delivery_summary jsonb,created_at timestamptz DEFAULT clock_timestamp(),
        deleted_for_everyone boolean DEFAULT false,deleted_for_sender boolean DEFAULT false);
      CREATE TABLE message_user_deletions(message_id uuid REFERENCES messages(id) ON DELETE CASCADE,
        user_id uuid REFERENCES users(id) ON DELETE CASCADE,PRIMARY KEY(message_id,user_id));
      CREATE TABLE conversation_user_state(user_id uuid REFERENCES users(id) ON DELETE CASCADE,
        kind text,target_id uuid,cleared_at timestamptz,hidden boolean DEFAULT false,
        PRIMARY KEY(user_id,kind,target_id));
      CREATE TABLE stored_files(id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
        user_id uuid REFERENCES users(id) ON DELETE SET NULL,original_name text NOT NULL,
        storage_path text NOT NULL UNIQUE,public_url text NOT NULL UNIQUE,mime_type text,
        file_type text,file_size bigint DEFAULT 0,context_type text,context_id uuid,
        moderation_status text DEFAULT 'pending',moderation_details jsonb,
        content_sha256 text,visual_fingerprint jsonb,release_scheduled_at timestamptz,
        released_at timestamptz,content_purged_at timestamptz,blocked_content_expires_at timestamptz,
        created_at timestamptz DEFAULT clock_timestamp());
      CREATE TABLE app_settings(key_name text PRIMARY KEY,value text,updated_at timestamptz DEFAULT now());
      CREATE TABLE media_backup_items(id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
        user_id uuid,stored_file_id uuid REFERENCES stored_files(id) ON DELETE CASCADE,
        provider text,status text,remote_file_id text,plaintext_sha256 text,encrypted_sha256 text,
        encryption_metadata jsonb,verified_at timestamptz,restore_verified_at timestamptz,
        UNIQUE(stored_file_id,provider));
      CREATE TABLE user_backup_settings(user_id uuid PRIMARY KEY,enabled boolean DEFAULT false,
        provider text,storage_mode text DEFAULT 'backup_only',encrypted_data_key text);
      CREATE TABLE cloud_backup_accounts(user_id uuid,status text,encrypted_refresh_token text);
      CREATE TABLE classification_shadow_jobs(stored_file_id uuid PRIMARY KEY
        REFERENCES stored_files(id) ON DELETE CASCADE);
    `);
    await pool.query(RECEIVED_MEDIA_SCHEMA);
    const service = (options = {}) => createReceivedMediaService({
      getPool: async () => pool, uploadRoot, publicBase: '/isolated-uploads', ...options,
    });
    let sequence = 100;
    const reset = async () => {
      await pool.query(`TRUNCATE received_message_media,personal_media_content,
        message_user_deletions,conversation_user_state,group_members,messages,
        media_backup_items,classification_shadow_jobs,stored_files,user_backup_settings,
        cloud_backup_accounts,groups,users,app_settings CASCADE`);
      await pool.query('INSERT INTO users VALUES($1),($2),($3),($4)', [alice,bob,carol,david]);
      await pool.query('INSERT INTO groups VALUES($1)', [group]);
      await pool.query('INSERT INTO group_members(group_id,user_id) VALUES($1,$2),($1,$3),($1,$4)',
        [group,alice,bob,carol]);
      await fs.rm(uploadRoot, { recursive: true, force: true });
      await fs.mkdir(uploadRoot, { recursive: true });
    };
    const source = async (owner = alice, bytes = Buffer.from('same received image'), options = {}) => {
      const fileId = id(++sequence);
      const storagePath = `source-${sequence}.${options.extension || 'png'}`;
      const url = `/isolated-uploads/${storagePath}`;
      await fs.writeFile(path.join(uploadRoot,storagePath),bytes);
      const row = (await pool.query(`INSERT INTO stored_files(id,user_id,original_name,storage_path,
        public_url,mime_type,file_type,file_size,context_type,moderation_status,moderation_details,content_sha256)
        VALUES($1,$2,$3,$4,$5,$6,$7,$8,'chat',$9,$10,$11) RETURNING *`, [
        fileId,owner,options.name || storagePath,storagePath,url,options.mime || 'image/png',
        options.type || 'image',bytes.length,options.status || 'approved',
        { classification: 'safe', test: true },options.hash === undefined ? sha256(bytes) : options.hash,
      ])).rows[0];
      return { ...row, bytes };
    };
    const message = async (file, options = {}) => (await pool.query(`INSERT INTO messages(
      id,sender_id,recipient_id,group_id,file_url,file_name,file_size,delivery_summary,created_at,
      deleted_for_everyone) VALUES($1,$2,$3,$4,$5,$6,$7,$8,COALESCE($9::timestamptz,clock_timestamp()),$10)
      RETURNING *`, [
      id(++sequence),options.sender || file.user_id,options.group ? null : (options.recipient || bob),
      options.group || null,file.public_url,file.original_name,file.file_size,
      options.delivered === undefined ? null : { deliveredTo: options.delivered.map(userId => ({id:userId,name:'recipient'})) },
      options.createdAt || null,options.deleted || false,
    ])).rows[0];
    const copies = async owner => (await pool.query(
      "SELECT * FROM stored_files WHERE user_id=$1 AND context_type='received'", [owner])).rows;
    const retained = async (messageId, owner = bob) => (await pool.query(
      'SELECT * FROM received_message_media WHERE message_id=$1 AND user_id=$2', [messageId,owner])).rows[0];
    const run = async (worker = service()) => {
      // The worker is bounded. Drain a small fixture independently of its batch size.
      for (let i = 0; i < 8; i++) {
        const pending = await pool.query("SELECT 1 FROM received_message_media WHERE status='queued' AND next_attempt_at<=now() LIMIT 1");
        if (!pending.rows.length) break;
        await worker.runOnce();
      }
    };

    await t.test('duplicates from different senders and a group resolve to one owned file', async () => {
      await reset();
      const first = await source(alice);
      const second = await source(carol,first.bytes,{name:'renamed-photo.png'});
      const messages = [await message(first),await message(second),
        await message(second,{group,delivered:[alice,bob,carol]})];
      await run();
      const owned = await copies(bob);
      assert.equal(owned.length,1);
      assert.notEqual(owned[0].id,first.id);
      assert.notEqual(owned[0].storage_path,first.storage_path);
      assert.equal(owned[0].context_id,null);
      assert.equal(owned[0].content_sha256,sha256(first.bytes));
      assert.deepEqual(await fs.readFile(path.join(uploadRoot,owned[0].storage_path)),first.bytes);
      assert.equal(new Set(await Promise.all(messages.map(async row => (await retained(row.id)).stored_file_id))).size,1);
      const personalized = await personalizeReceivedMessages(pool,bob,messages);
      assert.equal(new Set(personalized.map(row => row.file_url)).size,1);
      assert.equal(personalized[0].file_url,owned[0].public_url);
      assert.equal((await pool.query('SELECT COUNT(*)::int AS count FROM personal_media_content WHERE user_id=$1',[bob])).rows[0].count,1);
    });

    await t.test('two workers cannot create duplicate copies for concurrent receipts', async () => {
      await reset();
      const first = await source();
      const second = await source(carol,first.bytes);
      await Promise.all([message(first),message(second)]);
      await Promise.all([service().runOnce(),service().runOnce()]);
      await run();
      assert.equal((await copies(bob)).length,1);
      assert.equal((await pool.query("SELECT COUNT(*)::int AS count FROM received_message_media WHERE user_id=$1 AND status='ready'",[bob])).rows[0].count,2);
    });

    await t.test('different recipients receive separate owners and separate durable paths', async () => {
      await reset();
      const file = await source();
      await message(file);
      await message(file,{recipient:carol});
      await run();
      const bobFile = (await copies(bob))[0];
      const carolFile = (await copies(carol))[0];
      assert.ok(bobFile && carolFile);
      assert.notEqual(bobFile.id,carolFile.id);
      assert.notEqual(bobFile.storage_path,carolFile.storage_path);
      assert.deepEqual(await fs.readFile(path.join(uploadRoot,bobFile.storage_path)),file.bytes);
      assert.deepEqual(await fs.readFile(path.join(uploadRoot,carolFile.storage_path)),file.bytes);
    });

    await t.test('actual bytes distinguish content even with the same original filename', async () => {
      await reset();
      await message(await source(alice,Buffer.from('first image'),{name:'photo.png'}));
      await message(await source(carol,Buffer.from('second image'),{name:'photo.png'}));
      await run();
      const owned = await copies(bob);
      assert.equal(owned.length,2);
      assert.equal(new Set(owned.map(row => row.content_sha256)).size,2);
    });

    await t.test('an approved file already owned by the recipient is reused even when the source is offline', async () => {
      await reset();
      const owned = await source(bob);
      const incoming = await source(alice,owned.bytes);
      const sent = await message(incoming);
      await fs.unlink(path.join(uploadRoot,incoming.storage_path));
      await run();
      assert.equal((await retained(sent.id)).stored_file_id,owned.id);
      assert.equal((await copies(bob)).length,0);
      assert.equal((await pool.query('SELECT COUNT(*)::int AS count FROM stored_files WHERE user_id=$1',[bob])).rows[0].count,1);
    });

    await t.test('legacy sources without a hash are hashed by bytes and deduplicated', async () => {
      await reset();
      const first = await source(alice,Buffer.from('legacy content'),{hash:null});
      const second = await source(carol,first.bytes,{hash:null,name:'different-name.png'});
      await message(first);
      await message(second);
      await run();
      const owned = await copies(bob);
      assert.equal(owned.length,1);
      assert.equal(owned[0].content_sha256,sha256(first.bytes));
    });

    await t.test('a hashless legacy self-message retains its own source without making a second file', async () => {
      await reset();
      const own = await source(bob,Buffer.from('own legacy file'),{hash:null});
      const sent = await message(own,{sender:bob,recipient:bob});
      await run();
      assert.equal((await copies(bob)).length,0);
      assert.equal((await retained(sent.id)).stored_file_id,own.id);
      assert.equal((await pool.query('SELECT COUNT(*)::int AS count FROM stored_files WHERE user_id=$1',[bob])).rows[0].count,1);
    });

    await t.test('document, video and audio copies retain the approved metadata', async () => {
      await reset();
      const originals=[];
      for (const [type,mime,extension] of [
        ['document','application/pdf','pdf'],['video','video/mp4','mp4'],['audio','audio/mpeg','mp3'],
      ]) {
        const file = await source(alice,Buffer.from(`approved ${type}`),{type,mime,extension});
        originals.push(file);
        await message(file);
      }
      await run();
      const owned = await copies(bob);
      assert.equal(owned.length,3);
      for (const original of originals) {
        const copy = owned.find(row => row.content_sha256===original.content_sha256);
        assert.ok(copy);
        assert.equal(copy.mime_type,original.mime_type);
        assert.equal(copy.file_type,original.file_type);
        assert.equal(copy.original_name,original.original_name);
        assert.equal(copy.moderation_status,'approved');
        assert.deepEqual(copy.moderation_details,original.moderation_details);
      }
    });

    await t.test('a received guide spreadsheet keeps private storage and rewrites links to its owner copy', async () => {
      await reset();
      const file = await source(alice,Buffer.from('private spreadsheet fixture'),{
        type:'document',extension:'xlsx',
        mime:'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      });
      const privatePath=`.guide-files/${file.id}.xlsx`;
      await fs.mkdir(path.join(uploadRoot,'.guide-files'),{recursive:true});
      await fs.rename(path.join(uploadRoot,file.storage_path),path.join(uploadRoot,privatePath));
      file.storage_path=privatePath;
      file.public_url=`/betshuva-app/api/guide-files/${file.id}/download`;
      const metadata={generatedBy:'system_guide',sourceMessageId:id(++sequence),rowCount:6};
      await pool.query('UPDATE stored_files SET storage_path=$2,public_url=$3,moderation_details=$4 WHERE id=$1',[
        file.id,file.storage_path,file.public_url,metadata,
      ]);
      const sent=await message(file);
      const body=`[Download spreadsheet](betshuva://app/guide-file/${file.id})`;
      await pool.query('UPDATE messages SET body=$2 WHERE id=$1',[sent.id,body]);
      sent.body=body;
      await run();
      const copy=(await copies(bob))[0];
      assert.ok(copy);
      assert.equal(copy.storage_path,`.guide-files/${copy.id}.xlsx`);
      assert.equal(copy.public_url,`/betshuva-app/api/guide-files/${copy.id}/download`);
      assert.deepEqual(copy.moderation_details,metadata);
      const personal=(await personalizeReceivedMessages(pool,bob,[sent]))[0];
      assert.equal(personal.file_url,copy.public_url);
      assert.equal(personal.body,`[Download spreadsheet](betshuva://app/guide-file/${copy.id})`);
      const socket={id:sent.id,fileUrl:file.public_url,text:body};
      const personalSocket=(await personalizeReceivedMessages(pool,bob,[socket]))[0];
      assert.equal(personalSocket.text,personal.body);
      assert.equal(personalSocket.fileUrl,copy.public_url);
      const {loadOwnedGuideFile,readGuideFileBytes}=require('../server/guide-files');
      const downloadable=await loadOwnedGuideFile(pool,bob,copy.id);
      assert.equal(downloadable.id,copy.id);
      assert.equal(await loadOwnedGuideFile(pool,carol,copy.id),null);
      assert.equal(await loadOwnedGuideFile(pool,bob,file.id),null);
      assert.deepEqual(await readGuideFileBytes(pool,uploadRoot,downloadable),file.bytes);
      assert.equal((await pool.query('SELECT body FROM messages WHERE id=$1',[sent.id])).rows[0].body,body);
    });

    await t.test('only actual delivered group members are queued, with no sender or bot copy', async () => {
      await reset();
      const bot='00000000-0000-4000-8000-000000000003';
      await pool.query('INSERT INTO users VALUES($1)',[bot]);
      const file = await source();
      await message(file,{group,delivered:[alice,bob,bot]});
      await message(file,{recipient:alice});
      await message(file,{recipient:bot});
      await run();
      assert.equal((await copies(bob)).length,1);
      assert.equal((await copies(carol)).length,0);
      assert.equal((await copies(alice)).length,0);
      assert.equal((await copies(bot)).length,0);
    });

    await t.test('late group delivery summaries enqueue only the newly delivered eligible recipient', async () => {
      await reset();
      const file = await source();
      const sent = await message(file,{group});
      await run();
      assert.equal((await copies(bob)).length,0);
      await pool.query('UPDATE messages SET delivery_summary=$2 WHERE id=$1',[sent.id,
        {deliveredTo:[{id:bob,name:'Bob'},{id:david,name:'not a member'}]}]);
      await run();
      assert.equal((await copies(bob)).length,1);
      assert.equal((await copies(carol)).length,0);
      assert.equal((await copies(david)).length,0);
    });

    await t.test('URL personalization is private to the recipient and supports socket camelCase fields', async () => {
      await reset();
      const file = await source();
      const sent = await message(file);
      await run();
      const copy = (await copies(bob))[0];
      const socket = {id:sent.id,fileUrl:file.public_url,fileName:'forwarded.png',body:'caption'};
      assert.deepEqual((await personalizeReceivedMessages(pool,bob,[socket]))[0],{...socket,fileUrl:copy.public_url});
      assert.deepEqual((await personalizeReceivedMessages(pool,carol,[socket]))[0],socket);
      assert.deepEqual((await personalizeReceivedMessages(pool,alice,[socket]))[0],socket);
      assert.equal((await pool.query('SELECT file_url FROM messages WHERE id=$1',[sent.id])).rows[0].file_url,file.public_url);
    });

    await t.test('pending and rejected sources never become recipient-owned media', async () => {
      await reset();
      await message(await source(alice,Buffer.from('pending'),{status:'pending'}));
      await message(await source(alice,Buffer.from('rejected'),{status:'rejected'}));
      await run();
      assert.equal((await copies(bob)).length,0);
      assert.equal((await pool.query("SELECT 1 FROM received_message_media WHERE status='ready'")).rows.length,0);
    });

    await t.test('a source rejected after delivery is rechecked before retaining its bytes', async () => {
      await reset();
      const file = await source();
      const sent = await message(file);
      await pool.query("UPDATE stored_files SET moderation_status='rejected' WHERE id=$1",[file.id]);
      await run();
      assert.equal((await copies(bob)).length,0);
      assert.equal((await retained(sent.id)).status,'skipped');
    });

    await t.test('global moderation rejection propagates to already retained copies', async () => {
      await reset();
      const file = await source();
      const sent = await message(file);
      await message(file,{recipient:carol});
      await run();
      const details={reason:'global moderation decision'};
      await pool.query(`UPDATE stored_files SET moderation_status='rejected',moderation_details=$2,
        blocked_content_expires_at='2030-01-01' WHERE id=$1`,[file.id,details]);
      for (const copy of [...await copies(bob),...await copies(carol)]) {
        assert.equal(copy.moderation_status,'rejected');
        assert.deepEqual(copy.moderation_details,details);
        assert.equal(copy.blocked_content_expires_at.toISOString(),'2030-01-01T00:00:00.000Z');
      }
      assert.equal((await personalizeReceivedMessages(pool,bob,[sent]))[0].file_url,(await copies(bob))[0].public_url);
    });

    await t.test('a scoped recipient-filter rejection does not reject other owners approved copies', async () => {
      await reset();
      const file = await source();
      const sent = await message(file);
      await run();
      await pool.query("UPDATE stored_files SET moderation_status='rejected',moderation_details=$2 WHERE id=$1",[
        file.id,{destinationFilterRejected:true,reason:'one destination preference'},
      ]);
      const copy = (await copies(bob))[0];
      assert.equal(copy.moderation_status,'approved');
      assert.equal((await personalizeReceivedMessages(pool,bob,[sent]))[0].file_url,copy.public_url);
    });

    await t.test('a recipient can read their copy after original bytes and source metadata are deleted', async () => {
      await reset();
      const file = await source();
      const sent = await message(file);
      await run();
      const copy = (await copies(bob))[0];
      await fs.unlink(path.join(uploadRoot,file.storage_path));
      await pool.query('DELETE FROM stored_files WHERE id=$1',[file.id]);
      assert.deepEqual(await fs.readFile(path.join(uploadRoot,copy.storage_path)),file.bytes);
      assert.equal((await retained(sent.id)).stored_file_id,copy.id);
      assert.equal((await personalizeReceivedMessages(pool,bob,[sent]))[0].file_url,copy.public_url);
    });

    await t.test('sender-account and group removal do not remove recipient-owned bytes or library rows', async () => {
      await reset();
      const file = await source();
      await message(file,{group,delivered:[bob]});
      await run();
      const copy = (await copies(bob))[0];
      await pool.query('DELETE FROM groups WHERE id=$1',[group]);
      await pool.query('DELETE FROM users WHERE id=$1',[alice]);
      assert.equal((await copies(bob)).length,1);
      assert.deepEqual(await fs.readFile(path.join(uploadRoot,copy.storage_path)),file.bytes);
    });

    await t.test('hidden, individually deleted and globally deleted receipts are not backfilled', async () => {
      await reset();
      const file = await source();
      const hidden = await message(file,{createdAt:'2001-01-01'});
      await pool.query("INSERT INTO conversation_user_state(user_id,kind,target_id,cleared_at) VALUES($1,'chat',$2,'2002-01-01')",[bob,alice]);
      const deleted = await message(file);
      await pool.query('INSERT INTO message_user_deletions VALUES($1,$2)',[deleted.id,bob]);
      const global = await message(file,{deleted:true});
      // Simulate old history predating the delivery-retention trigger. These
      // hidden messages must not receive a new retention authorization now.
      await pool.query('TRUNCATE received_message_media');
      await retainVisibleReceivedMessages(pool,bob,[hidden,deleted,global]);
      await run();
      assert.equal((await copies(bob)).length,0);
      assert.equal((await pool.query("SELECT 1 FROM received_message_media WHERE status='ready'")).rows.length,0);
    });

    await t.test('clearing a conversation while keeping files preserves an already delivered queued copy', async () => {
      await reset();
      const file = await source();
      const sent = await message(file);
      await pool.query("INSERT INTO conversation_user_state(user_id,kind,target_id,cleared_at) VALUES($1,'chat',$2,clock_timestamp())",[bob,alice]);
      await pool.query('INSERT INTO message_user_deletions VALUES($1,$2)',[sent.id,bob]);
      await run();
      assert.equal((await copies(bob)).length,1);
      assert.equal((await retained(sent.id)).status,'ready');
    });

    await t.test('retention yields to the owner lock and observes explicit cancellation during file deletion', async () => {
      await reset();
      const file = await source();
      const sent = await message(file);
      const clearing = await pool.connect();
      try {
        await clearing.query('BEGIN');
        await clearing.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))',[
          `personal-media-owner:${bob}`,
        ]);
        assert.equal(await service().runOnce(),0);
        assert.equal((await copies(bob)).length,0);
        await clearing.query("INSERT INTO conversation_user_state(user_id,kind,target_id,cleared_at) VALUES($1,'chat',$2,clock_timestamp())",[bob,alice]);
        await clearing.query("UPDATE received_message_media SET status='skipped' WHERE user_id=$1 AND status='queued'",[bob]);
        await clearing.query('COMMIT');
        await run();
        assert.equal((await retained(sent.id)).status,'skipped');
        assert.equal((await copies(bob)).length,0);
      } finally {
        await clearing.query('ROLLBACK');
        clearing.release();
      }
    });

    await t.test('late pre-deletion deliveries are skipped while post-deletion media is retained', async () => {
      for (const kind of ['chat','group']) {
        await reset();
        const file=await source();
        const lateId=id(++sequence);
        const sending=await pool.connect();
        try {
          await sending.query('BEGIN');
          await sending.query(`INSERT INTO messages(id,sender_id,recipient_id,group_id,file_url,
            delivery_summary,created_at) VALUES($1,$2,$3,$4,$5,$6,'2001-01-01')`,[
            lateId,alice,kind==='chat' ? bob : null,kind==='group' ? group : null,
            file.public_url,kind==='group' ? {deliveredTo:[{id:bob,name:'Bob'}]} : null,
          ]);
          // The delivery and its trigger queue are uncommitted when deletion
          // records the cutoff; a deletion ledger snapshot cannot see them.
          assert.equal(await retained(lateId),undefined);
          await pool.query(`INSERT INTO conversation_user_state(user_id,kind,target_id,cleared_at,
            media_deleted_at) VALUES($1,$2,$3,'2002-01-01','2002-01-01')`,[
            bob,kind,kind==='group' ? group : alice,
          ]);
          await sending.query('COMMIT');
          await run();
          assert.equal((await retained(lateId)).status,'skipped');
          assert.equal((await copies(bob)).length,0);
          const fresh=await message(file,{createdAt:'2003-01-01',
            ...(kind==='group' ? {group,delivered:[bob]} : {}),
          });
          // A later ordinary clear must preserve files received after the
          // previous explicit file-deletion cutoff.
          await pool.query("UPDATE conversation_user_state SET cleared_at='2004-01-01' WHERE user_id=$1",[bob]);
          await run();
          assert.equal((await retained(fresh.id)).status,'ready');
          assert.equal((await copies(bob)).length,1);
          assert.equal((await retained(lateId)).status,'skipped');
        } finally {
          await sending.query('ROLLBACK');
          sending.release();
        }
      }
    });

    await t.test('personal copy deletion leaves a tombstone that history loads cannot resurrect', async () => {
      await reset();
      const file = await source();
      const sent = await message(file);
      await run();
      const copy = (await copies(bob))[0];
      await pool.query('DELETE FROM stored_files WHERE id=$1',[copy.id]);
      await fs.unlink(path.join(uploadRoot,copy.storage_path));
      await retainVisibleReceivedMessages(pool,bob,[sent]);
      await run();
      assert.equal((await copies(bob)).length,0);
      assert.equal((await retained(sent.id)).stored_file_id,null);
    });

    await t.test('a failed source read remains retryable without creating a partial personal file', async () => {
      await reset();
      const file = await source();
      const sent = await message(file);
      await fs.unlink(path.join(uploadRoot,file.storage_path));
      await run();
      const failed = await retained(sent.id);
      assert.equal(failed.status,'queued');
      assert.ok(failed.attempt_count>=1);
      assert.ok(failed.last_error);
      assert.equal((await copies(bob)).length,0);
      await fs.writeFile(path.join(uploadRoot,file.storage_path),file.bytes);
      await pool.query("UPDATE received_message_media SET next_attempt_at=now()-interval '1 second' WHERE message_id=$1",[sent.id]);
      await run();
      assert.equal((await copies(bob)).length,1);
      assert.equal((await retained(sent.id)).status,'ready');
    });

    await t.test('released source bytes are restored from a verified encrypted Drive backup', async driveTest => {
      await reset();
      const personalDrive = require('../server/personal-drive');
      const { encryptBuffer } = require('../server/media-backup-crypto');
      const { wrapVaultKey } = require('../server/backup-vault-key');
      const previousKey = process.env.BACKUP_TOKEN_ENCRYPTION_KEY;
      process.env.BACKUP_TOKEN_ENCRYPTION_KEY='isolated-received-media-test-master-key-123456789';
      try {
        const file = await source();
        const sent = await message(file);
        const key=crypto.randomBytes(32);
        const associatedData=`owner:${alice}:file:${file.id}`;
        const envelope=encryptBuffer(file.bytes,key,associatedData);
        const metadata={algorithm:envelope.algorithm,nonce:envelope.nonce,tag:envelope.tag,associatedData};
        await pool.query(`INSERT INTO media_backup_items(user_id,stored_file_id,provider,status,remote_file_id,
          plaintext_sha256,encrypted_sha256,encryption_metadata) VALUES($1,$2,'google_drive','verified',
          'fixture-drive-payload',$3,$4,$5)`,[alice,file.id,sha256(file.bytes),sha256(envelope.ciphertext),metadata]);
        await pool.query('INSERT INTO user_backup_settings(user_id,encrypted_data_key) VALUES($1,$2)',[
          alice,wrapVaultKey(key,alice),
        ]);
        await pool.query("INSERT INTO cloud_backup_accounts VALUES($1,'connected','fixture-encrypted-token')",[alice]);
        await fs.unlink(path.join(uploadRoot,file.storage_path));
        driveTest.mock.method(personalDrive,'decryptRefreshToken',(token,userId)=>{
          assert.equal(token,'fixture-encrypted-token');assert.equal(userId,alice);return 'fixture-token';
        });
        let corrupt=true;
        driveTest.mock.method(personalDrive,'downloadAppDataFile',async(token,remoteId)=>{
          assert.equal(token,'fixture-token');assert.equal(remoteId,'fixture-drive-payload');
          return corrupt ? Buffer.from('corrupt download') : envelope.ciphertext;
        });
        await run();
        assert.equal((await copies(bob)).length,0);
        assert.match((await retained(sent.id)).last_error,/backup checksum mismatch/);
        corrupt=false;
        await pool.query("UPDATE received_message_media SET next_attempt_at=now()-interval '1 second' WHERE message_id=$1",[sent.id]);
        await run();
        const copy=(await copies(bob))[0];
        assert.ok(copy);
        assert.deepEqual(await fs.readFile(path.join(uploadRoot,copy.storage_path)),file.bytes);
        assert.equal((await retained(sent.id)).status,'ready');
      } finally {
        if (previousKey===undefined) delete process.env.BACKUP_TOKEN_ENCRYPTION_KEY;
        else process.env.BACKUP_TOKEN_ENCRYPTION_KEY=previousKey;
      }
    });

    await t.test('bytes that contradict a recorded content hash cannot be copied as approved content', async () => {
      await reset();
      const file = await source(alice,Buffer.from('changed bytes'),{hash:sha256(Buffer.from('approved bytes'))});
      await message(file);
      await run();
      assert.equal((await copies(bob)).length,0);
      assert.equal((await pool.query("SELECT 1 FROM received_message_media WHERE status='ready'")).rows.length,0);
    });

    await t.test('source paths cannot traverse or follow a symlink outside the upload directory', async () => {
      await reset();
      const outside = await fs.mkdtemp(path.join(os.tmpdir(),'received-media-outside-'));
      try {
        const secret = path.join(outside,'outside.png');
        await fs.writeFile(secret,'outside bytes');
        const traversal = await source(alice,Buffer.from('unused traversal'),{hash:null});
        await pool.query('UPDATE stored_files SET storage_path=$2 WHERE id=$1',[
          traversal.id,path.relative(uploadRoot,secret),
        ]);
        const linked = await source(carol,Buffer.from('unused symlink'),{hash:null});
        await fs.unlink(path.join(uploadRoot,linked.storage_path));
        await fs.symlink(secret,path.join(uploadRoot,linked.storage_path));
        const messages=[await message(traversal),await message(linked)];
        await run();
        assert.equal((await copies(bob)).length,0);
        for (const row of messages) {
          const queued = await retained(row.id);
          assert.equal(queued.status,'queued');
          assert.match(queued.last_error,/Invalid received media/);
        }
        assert.equal(await fs.readFile(secret,'utf8'),'outside bytes');
      } finally { await fs.rm(outside,{recursive:true,force:true}); }
    });

    await t.test('retaining an approved image does not enqueue another classification scan', async () => {
      await reset();
      const index = await fs.readFile(path.join(__dirname,'../server/index.js'),'utf8');
      const definition=index.match(/CREATE OR REPLACE FUNCTION enqueue_classification_shadow_job\(\)[\s\S]*?\$\$ LANGUAGE plpgsql/);
      const trigger=index.match(/CREATE TRIGGER stored_files_shadow_classification[\s\S]*?EXECUTE FUNCTION enqueue_classification_shadow_job\(\)/);
      const backfill=index.match(/INSERT INTO classification_shadow_jobs\(stored_file_id\)\s+SELECT id FROM stored_files[\s\S]*?ON CONFLICT\(stored_file_id\) DO NOTHING/);
      assert.ok(definition && trigger && backfill,'production classification SQL is available');
      await pool.query(definition[0]);
      await pool.query(trigger[0]);
      const file = await source();
      await pool.query('UPDATE stored_files SET moderation_details=$2 WHERE id=$1',[file.id,
        {classificationStats:{approved:true},test:true}]);
      await message(file);
      await run();
      assert.equal((await copies(bob)).length,1);
      await pool.query(backfill[0]);
      assert.deepEqual((await pool.query('SELECT stored_file_id FROM classification_shadow_jobs')).rows,
        [{stored_file_id:file.id}]);
    });

    await t.test('migration backfills visible historic messages once without reviving cleared history', async () => {
      await reset();
      const file = await source();
      const visible = await message(file,{sender:carol});
      const hidden = await message(file,{createdAt:'2001-01-01'});
      await pool.query("INSERT INTO conversation_user_state(user_id,kind,target_id,cleared_at) VALUES($1,'chat',$2,'2002-01-01')",[bob,alice]);
      await pool.query('TRUNCATE received_message_media');
      await migrateReceivedMedia(pool);
      await run();
      assert.equal((await retained(visible.id)).status,'ready');
      assert.notEqual((await retained(hidden.id))?.status,'ready');
      // Deleting a fixture mapping distinguishes a real one-time migration from
      // merely repeating INSERT ON CONFLICT on every server restart.
      await pool.query('DELETE FROM received_message_media WHERE message_id=$1',[visible.id]);
      const count = (await pool.query('SELECT COUNT(*)::int AS count FROM received_message_media')).rows[0].count;
      await migrateReceivedMedia(pool);
      assert.equal((await pool.query('SELECT COUNT(*)::int AS count FROM received_message_media')).rows[0].count,count);
      assert.equal((await copies(bob)).length,1);
    });
  } finally {
    if (pool) await pool.end();
    await admin.query(`DROP SCHEMA IF EXISTS ${schema} CASCADE`);
    await admin.end();
    await fs.rm(uploadRoot, { recursive: true, force: true });
  }
});
