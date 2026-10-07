'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { randomUUID, createHash } = require('node:crypto');
const { once } = require('node:events');
const { Client, Pool } = require('pg');
const express = require('express');
const { CONVERSATION_SCHEMA } = require('../server/conversation-history');
const { registerChatListingImage } = require('../server/chat-listing-image');

test('message image source enforces real private/group history, current filtering and personal copy ownership',
  { skip: process.env.RUN_DB_TESTS !== '1' }, async t => {
    const owner = new Client({ connectionString: process.env.DATABASE_URL });
    await owner.connect();
    const schema = `chat_listing_${randomUUID().replaceAll('-', '')}`;
    await owner.query(`CREATE SCHEMA "${schema}"`);
    const db = new Pool({ connectionString: process.env.DATABASE_URL,
      options: `-c search_path=${schema}`, max: 3 });
    t.after(async () => {
      try {
        await db.end();
        await owner.query(`DROP SCHEMA "${schema}" CASCADE`);
        assert.equal((await owner.query('SELECT count(*)::int AS n FROM pg_namespace WHERE nspname=$1',
          [schema])).rows[0].n, 0, 'isolated test schema is removed');
        t.diagnostic(`Isolated schema ${schema} removed and verified`);
      } finally { await owner.end(); }
    });
    await db.query(`CREATE TABLE users(id UUID PRIMARY KEY,content_filter JSONB);
      CREATE TABLE groups(id UUID PRIMARY KEY,creator_id UUID,content_filter JSONB);
      CREATE TABLE stored_files(id UUID PRIMARY KEY,user_id UUID,public_url TEXT,storage_path TEXT,
        original_name TEXT,mime_type TEXT,file_type TEXT,file_size BIGINT,content_sha256 TEXT,
        moderation_status TEXT,moderation_details JSONB,content_purged_at TIMESTAMPTZ,
        context_type TEXT,context_id UUID);
      CREATE TABLE messages(id UUID PRIMARY KEY,sender_id UUID,recipient_id UUID,group_id UUID,
        type TEXT,file_url TEXT,file_name TEXT,created_at TIMESTAMPTZ DEFAULT now(),
        deleted_for_everyone BOOLEAN DEFAULT FALSE,deleted_for_sender BOOLEAN DEFAULT FALSE);
      CREATE TABLE message_requests(id UUID PRIMARY KEY,sender_id UUID,recipient_id UUID,
        type TEXT,file_url TEXT,file_name TEXT,status TEXT,created_at TIMESTAMPTZ DEFAULT now());
      CREATE TABLE message_user_deletions(message_id UUID,user_id UUID);
      CREATE TABLE group_members(group_id UUID,user_id UUID,status TEXT,joined_at TIMESTAMPTZ,filter_override JSONB);
      CREATE TABLE user_contacts(owner_id UUID,contact_id UUID,filter_override JSONB);
      CREATE TABLE user_message_filter_actions(user_id UUID,message_id UUID,action TEXT);
      CREATE TABLE filter_audit_events(id SERIAL,kind TEXT,user_id UUID,message_id UUID,details JSONB);
      CREATE TABLE received_message_media(message_id UUID,user_id UUID,source_file_id UUID,stored_file_id UUID,status TEXT,last_error TEXT);
      CREATE TABLE deleted_media_sources(public_url TEXT);
      CREATE FUNCTION betshuva_effective_filter(base JSONB,scoped JSONB) RETURNS JSONB
        LANGUAGE SQL AS $$ SELECT COALESCE(base,'{}'::jsonb)||COALESCE(scoped,'{}'::jsonb) $$;
      ${CONVERSATION_SCHEMA}`);
    const sender = randomUUID(), reader = randomUUID(), outsider = randomUUID(), group = randomUUID();
    for (const user of [sender, reader, outsider]) await db.query('INSERT INTO users VALUES($1,$2)',
      [user, { men: true, women: true, children: true, nonHumanImages: true }]);
    const image = Buffer.from('approved source image');
    const hash = createHash('sha256').update(image).digest('hex');
    const reads = [];
    let duringRead = null;
    async function file(userId, changes = {}) {
      const id = randomUUID(), url = `/betshuva-app/uploads/${id}.png`;
      await db.query(`INSERT INTO stored_files(id,user_id,public_url,storage_path,original_name,mime_type,
        file_type,file_size,content_sha256,moderation_status,moderation_details,content_purged_at)
        VALUES($1,$2,$3,$4,$5,'image/png','image',$6,$7,$8,$9,$10)`,
        [id, userId, url, `${id}.png`, 'צילום.png', image.length, hash,
          changes.status || 'approved', { classification: { category: changes.category || 'nonHumanImages',
            detectedCategories: [changes.category || 'nonHumanImages'], uncertain: false } }, changes.purgedAt || null]);
      return { id, url };
    }
    async function message(source, changes = {}) {
      const id = randomUUID();
      await db.query(`INSERT INTO messages(id,sender_id,recipient_id,group_id,type,file_url,file_name,created_at)
        VALUES($1,$2,$3,$4,'image',$5,'צילום.png',COALESCE($6,now()))`,
      [id, sender, changes.groupId ? null : reader, changes.groupId || null, source.url, changes.createdAt || null]);
      return id;
    }
    const app = express();
    registerChatListingImage(app, { getPool: async () => db, uploadRoot: '/private/uploads',
      auth(req, res, next) {
        const id = req.headers.authorization?.replace('Bearer ', '');
        if (![sender, reader, outsider].includes(id)) return res.sendStatus(401);
        req.user = { id }; next();
      }, rateLimit(req, res, next) { next(); },
      readImage: async (database, root, source) => {
        reads.push(source.id);
        if (duringRead) await duringRead(source);
        return image;
      },
      logger: { warn() {} },
    });
    const server = app.listen(0, '127.0.0.1'); await once(server, 'listening');
    t.after(() => new Promise(resolve => { server.close(resolve); server.closeAllConnections(); }));
    async function call(user, id) {
      const response = await fetch(`http://127.0.0.1:${server.address().port}/api/messages/${id}/listing-image-source`,
        { headers: { Authorization: `Bearer ${user}` } });
      const body = Buffer.from(await response.arrayBuffer());
      return { status: response.status, body, error: response.status === 200 ? null : JSON.parse(body.toString()) };
    }
    const source = await file(sender), privateMessage = await message(source);
    for (const user of [sender, reader]) {
      const response = await call(user, privateMessage);
      assert.equal(response.status, 200, JSON.stringify(response.error)); assert.deepEqual(response.body, image);
    }
    assert.equal((await call(outsider, privateMessage)).status, 404);
    await db.query('UPDATE messages SET deleted_for_sender=TRUE WHERE id=$1', [privateMessage]);
    assert.equal((await call(sender, privateMessage)).status, 404);
    assert.equal((await call(reader, privateMessage)).status, 200);
    await db.query('INSERT INTO message_user_deletions VALUES($1,$2)', [privateMessage, reader]);
    assert.equal((await call(reader, privateMessage)).status, 404);
    await db.query('DELETE FROM message_user_deletions');
    await db.query('UPDATE messages SET deleted_for_everyone=TRUE WHERE id=$1', [privateMessage]);
    assert.equal((await call(reader, privateMessage)).status, 404);

    await db.query('INSERT INTO groups VALUES($1,$2,NULL)', [group, sender]);
    await db.query("INSERT INTO group_members VALUES($1,$2,'member',now()-INTERVAL '1 hour',NULL)", [group, reader]);
    const groupMessage = await message(source, { groupId: group });
    assert.equal((await call(reader, groupMessage)).status, 200);
    const oldGroupMessage = await message(source, { groupId: group, createdAt: new Date(Date.now() - 2 * 60 * 60 * 1000) });
    assert.equal((await call(reader, oldGroupMessage)).status, 404);
    assert.equal((await call(outsider, groupMessage)).status, 404);
    await db.query("UPDATE group_members SET status='left' WHERE user_id=$1", [reader]);
    assert.equal((await call(reader, groupMessage)).status, 404);
    await db.query("UPDATE group_members SET status='member' WHERE user_id=$1", [reader]);
    await db.query(`INSERT INTO conversation_user_state(user_id,kind,target_id,cleared_at)
      VALUES($1,'group',$2,clock_timestamp())`, [reader, group]);
    assert.equal((await call(reader, groupMessage)).status, 404);

    const humanSource = await file(sender, { category: 'men' }), humanMessage = await message(humanSource);
    assert.equal((await call(reader, humanMessage)).status, 200);
    await db.query('UPDATE users SET content_filter=$2 WHERE id=$1',
      [reader, { men: false, women: false, children: false }]);
    assert.equal((await call(reader, humanMessage)).status, 404);
    await db.query("INSERT INTO user_message_filter_actions VALUES($1,$2,'keep')", [reader, humanMessage]);
    assert.equal((await call(reader, humanMessage)).status, 200);
    await db.query("UPDATE user_message_filter_actions SET action='hide' WHERE message_id=$1", [humanMessage]);
    assert.equal((await call(reader, humanMessage)).status, 404);
    await db.query("UPDATE user_message_filter_actions SET action='delete' WHERE message_id=$1", [humanMessage]);
    assert.equal((await call(reader, humanMessage)).status, 404);

    const copySource = await file(sender), copiedMessage = await message(copySource), ownCopy = await file(reader);
    await db.query(`INSERT INTO received_message_media(message_id,user_id,source_file_id,stored_file_id,status)
      VALUES($1,$2,$3,$4,'ready')`, [copiedMessage, reader, copySource.id, ownCopy.id]);
    await db.query('UPDATE stored_files SET content_purged_at=now() WHERE id=$1', [copySource.id]);
    assert.equal((await call(reader, copiedMessage)).status, 200); assert.equal(reads.at(-1), ownCopy.id);
    for (const status of ['pending', 'stopped', 'rejected']) {
      await db.query('UPDATE stored_files SET moderation_status=$2 WHERE id=$1', [copySource.id, status]);
      assert.equal((await call(reader, copiedMessage)).status, 404);
    }
    await db.query("UPDATE stored_files SET moderation_status='approved' WHERE id=$1", [copySource.id]);
    const foreignCopy = await file(outsider);
    await db.query('UPDATE received_message_media SET stored_file_id=$2 WHERE message_id=$1', [copiedMessage, foreignCopy.id]);
    assert.equal((await call(reader, copiedMessage)).status, 404);
    // No import step changes a source context or creates any marketplace row.
    assert.equal((await db.query('SELECT count(*)::int AS n FROM stored_files')).rows[0].n, 5);

    async function request(source, changes = {}) {
      const id = changes.id || randomUUID();
      await db.query(`INSERT INTO message_requests(id,sender_id,recipient_id,type,file_url,file_name,status,created_at)
        VALUES($1,$2,$3,$4,$5,'צילום.png',$6,COALESCE($7,now()))`,
      [id, changes.senderId || sender, changes.recipientId || reader, changes.type || 'image',
        source.url, changes.status || 'pending', changes.createdAt || null]);
      return { id, sourceId: `request_${id}` };
    }
    const requestFile = await file(sender);
    await db.query("UPDATE stored_files SET context_type='chat',context_id=$2 WHERE id=$1", [requestFile.id, reader]);
    const pendingRequest = await request(requestFile);

    await t.test('pending and recipient-rejected requests are readable only by the upload owner without delivery changes', async () => {
      const before = (await db.query('SELECT * FROM message_requests WHERE id=$1', [pendingRequest.id])).rows[0];
      const sourceBefore = (await db.query('SELECT * FROM stored_files WHERE id=$1', [requestFile.id])).rows[0];
      assert.equal((await call(sender, pendingRequest.sourceId)).status, 200);
      assert.equal(reads.at(-1), requestFile.id);
      assert.equal((await call(reader, pendingRequest.sourceId)).status, 404);
      assert.equal((await call(outsider, pendingRequest.sourceId)).status, 404);
      assert.deepEqual((await db.query('SELECT * FROM message_requests WHERE id=$1', [pendingRequest.id])).rows[0], before);
      assert.deepEqual((await db.query('SELECT * FROM stored_files WHERE id=$1', [requestFile.id])).rows[0], sourceBefore);
      await db.query("UPDATE message_requests SET status='rejected' WHERE id=$1", [pendingRequest.id]);
      assert.equal((await call(sender, pendingRequest.sourceId)).status, 200);
      assert.equal((await db.query('SELECT status FROM message_requests WHERE id=$1', [pendingRequest.id])).rows[0].status, 'rejected');
      await db.query("UPDATE message_requests SET status='pending' WHERE id=$1", [pendingRequest.id]);
    });
    await t.test('request namespace cannot resolve raw ids, scan ids, foreign uploads or a promoted request', async () => {
      assert.equal((await call(sender, pendingRequest.id)).status, 404);
      assert.equal((await call(sender, `scan_${requestFile.id}`)).status, 400);
      assert.equal((await call(sender, `request_${requestFile.id}`)).status, 404);
      const foreignRequest = await request(foreignCopy);
      const readsBefore = reads.length;
      assert.equal((await call(sender, foreignRequest.sourceId)).status, 404);
      assert.equal(reads.length, readsBefore);
      for (const type of ['text', 'video']) {
        const wrongType = await request(requestFile, { type });
        assert.equal((await call(sender, wrongType.sourceId)).status, 404);
      }
      // Once the request becomes a canonical message, callers must explicitly
      // use its canonical id and satisfy that route's unchanged entitlement.
      const canonical = await message(requestFile);
      const promoted = await request(requestFile, { id: canonical });
      await db.query("UPDATE message_requests SET status='accepted' WHERE id=$1", [promoted.id]);
      assert.equal((await call(sender, promoted.sourceId)).status, 404);
      assert.equal((await call(sender, canonical)).status, 200);
    });
    await t.test('history cutoff and personal deletion revoke the owner request source', async () => {
      await db.query(`INSERT INTO conversation_user_state(user_id,kind,target_id,cleared_at)
        VALUES($1,'chat',$2,clock_timestamp())`, [sender, reader]);
      assert.equal((await call(sender, pendingRequest.sourceId)).status, 404);
      const freshRequest = await request(requestFile, { createdAt: new Date(Date.now() + 1000) });
      assert.equal((await call(sender, freshRequest.sourceId)).status, 200);
      await db.query("DELETE FROM conversation_user_state WHERE user_id=$1 AND kind='chat' AND target_id=$2", [sender, reader]);
      await db.query('INSERT INTO message_user_deletions VALUES($1,$2)', [pendingRequest.id, sender]);
      assert.equal((await call(sender, pendingRequest.sourceId)).status, 404);
      await db.query('DELETE FROM message_user_deletions WHERE message_id=$1 AND user_id=$2', [pendingRequest.id, sender]);
      assert.equal((await call(sender, pendingRequest.sourceId)).status, 200);
    });
    await t.test('outgoing request uses existing owner viewing filter rather than recipient or contact overrides', async () => {
      const humanRequest = await request(humanSource);
      await db.query('INSERT INTO user_contacts VALUES($1,$2,$3)', [sender, reader, { men: false }]);
      assert.equal((await call(sender, humanRequest.sourceId)).status, 200);
      await db.query('UPDATE users SET content_filter=$2 WHERE id=$1',
        [sender, { men: false, women: false, children: false, nonHumanImages: true }]);
      const readsBefore = reads.length;
      assert.equal((await call(sender, humanRequest.sourceId)).status, 404);
      assert.equal(reads.length, readsBefore);
      // Non-human images remain visible under the application's existing policy.
      assert.equal((await call(sender, pendingRequest.sourceId)).status, 200);
      await db.query('UPDATE users SET content_filter=$2 WHERE id=$1',
        [sender, { men: true, women: true, children: true, nonHumanImages: true }]);
      await db.query('DELETE FROM user_contacts WHERE owner_id=$1 AND contact_id=$2', [sender, reader]);
    });
    for (const status of ['pending', 'rejected', 'stopped']) {
      await t.test(`global ${status} moderation cannot use contact approval as a safety bypass`, async () => {
        await db.query('UPDATE stored_files SET moderation_status=$2 WHERE id=$1', [requestFile.id, status]);
        const readsBefore = reads.length;
        assert.equal((await call(sender, pendingRequest.sourceId)).status, 404);
        assert.equal(reads.length, readsBefore);
        await db.query("UPDATE stored_files SET moderation_status='approved' WHERE id=$1", [requestFile.id]);
      });
    }
    for (const flag of ['blocked', 'pending', 'scanStopped']) {
      await t.test(`approved request with ${flag} safety flag cannot expose bytes`, async () => {
        await db.query('UPDATE stored_files SET moderation_details=moderation_details||$2::jsonb WHERE id=$1',
          [requestFile.id, { [flag]: true }]);
        const readsBefore = reads.length;
        assert.equal((await call(sender, pendingRequest.sourceId)).status, 404);
        assert.equal(reads.length, readsBefore);
        await db.query('UPDATE stored_files SET moderation_details=moderation_details-$2 WHERE id=$1', [requestFile.id, flag]);
      });
    }
    await t.test('purged and deleted originals cannot fall back to an unrelated approved copy', async () => {
      await db.query(`INSERT INTO received_message_media(message_id,user_id,source_file_id,stored_file_id,status)
        VALUES($1,$2,$3,$4,'ready')`, [pendingRequest.id, sender, requestFile.id, ownCopy.id]);
      await db.query('UPDATE stored_files SET content_purged_at=now() WHERE id=$1', [requestFile.id]);
      assert.equal((await call(sender, pendingRequest.sourceId)).status, 404);
      await db.query('UPDATE stored_files SET content_purged_at=NULL WHERE id=$1', [requestFile.id]);
      await db.query('INSERT INTO deleted_media_sources VALUES($1)', [requestFile.url]);
      assert.equal((await call(sender, pendingRequest.sourceId)).status, 404);
      await db.query('DELETE FROM deleted_media_sources WHERE public_url=$1', [requestFile.url]);
      assert.equal((await call(sender, pendingRequest.sourceId)).status, 200);
      assert.equal(reads.at(-1), requestFile.id);
    });
    await t.test('image type, MIME, declared size and SHA guards apply equally to contact request sources', async () => {
      for (const [column, value] of [['file_type', 'video'], ['mime_type', 'image/svg+xml'], ['file_size', 0]]) {
        await db.query(`UPDATE stored_files SET ${column}=$2 WHERE id=$1`, [requestFile.id, value]);
        assert.equal((await call(sender, pendingRequest.sourceId)).status, 404);
        await db.query("UPDATE stored_files SET file_type='image',mime_type='image/png',file_size=$2 WHERE id=$1",
          [requestFile.id, image.length]);
      }
      await db.query('UPDATE stored_files SET file_size=$2 WHERE id=$1', [requestFile.id, 10 * 1024 * 1024 + 1]);
      assert.equal((await call(sender, pendingRequest.sourceId)).status, 413);
      await db.query('UPDATE stored_files SET file_size=$2 WHERE id=$1', [requestFile.id, image.length + 1]);
      assert.equal((await call(sender, pendingRequest.sourceId)).status, 503);
      await db.query('UPDATE stored_files SET file_size=$2,content_sha256=$3 WHERE id=$1',
        [requestFile.id, image.length, '0'.repeat(64)]);
      assert.equal((await call(sender, pendingRequest.sourceId)).status, 503);
      await db.query('UPDATE stored_files SET content_sha256=$2 WHERE id=$1', [requestFile.id, hash]);
    });
    const races = [
      ['request disappears', async id => db.query('DELETE FROM message_requests WHERE id=$1', [id])],
      ['request is accepted', async id => db.query("UPDATE message_requests SET status='accepted' WHERE id=$1", [id])],
      ['owner viewing filter changes', async () => db.query('UPDATE users SET content_filter=$2 WHERE id=$1',
        [sender, { men: false, women: false, children: false, nonHumanImages: false }])],
      ['source owner changes', async () => db.query('UPDATE stored_files SET user_id=$2 WHERE id=$1', [requestFile.id, outsider])],
      ['source safety scan rejects', async () => db.query("UPDATE stored_files SET moderation_status='rejected' WHERE id=$1", [requestFile.id])],
      ['source SHA changes', async () => db.query('UPDATE stored_files SET content_sha256=$2 WHERE id=$1', [requestFile.id, '0'.repeat(64)])],
      ['chat history is cleared', async () => db.query(`INSERT INTO conversation_user_state(user_id,kind,target_id,cleared_at)
        VALUES($1,'chat',$2,clock_timestamp())`, [sender, reader])],
    ];
    for (const [name, revoke] of races) {
      await t.test(`slow source restoration rechecks entitlement when ${name}`, async () => {
        const candidate = await request(name === 'owner viewing filter changes' ? humanSource : requestFile);
        duringRead = async () => { await revoke(candidate.id); };
        try { assert.equal((await call(sender, candidate.sourceId)).status, 404); }
        finally {
          duringRead = null;
          await db.query("UPDATE stored_files SET user_id=$2,moderation_status='approved',content_sha256=$3 WHERE id=$1",
            [requestFile.id, sender, hash]);
          await db.query('UPDATE users SET content_filter=$2 WHERE id=$1',
            [sender, { men: true, women: true, children: true, nonHumanImages: true }]);
          await db.query("DELETE FROM conversation_user_state WHERE user_id=$1 AND kind='chat' AND target_id=$2", [sender, reader]);
        }
      });
    }
    assert.equal((await db.query('SELECT count(*)::int AS n FROM filter_audit_events')).rows[0].n, 0);
  });
