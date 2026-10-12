'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const fs = require('node:fs');
const { Pool } = require('pg');
const { DEFAULT_CONTENT_FILTER: ALL, contentAllowedByFilter } = require('../server/content-filter-policy');
const requests = require('../server/contact-message-requests');
const { FILTER_MEDIA_SCHEMA, projectFilteredHistory } = require('../server/filter-media-history');
const { encryptedQueryValues, decryptMessageRows } = require('../server/message-at-rest');

const dbOptions = { skip: process.env.RUN_DB_TESTS !== '1' };
const woman = Object.freeze({ inlineEmoji: true, category: 'women',
  detectedCategories: ['women'], uncertain: false,
  artworkVersion: 'fixture-art-v1', moderationVersion: 'fixture-scan-v1' });

test('scanned Unicode text respects visual categories without changing ordinary text', () => {
  assert.equal(contentAllowedByFilter({ ...ALL, women: false }, 'text', woman), false);
  assert.equal(contentAllowedByFilter({ ...ALL, men: false }, 'text', woman), true);
  assert.equal(contentAllowedByFilter({ ...ALL, women: false }, 'text', null), true);
  assert.equal(contentAllowedByFilter({ ...ALL, women: false }, 'text', { ...woman, inlineEmoji: false }), true);
  assert.equal(contentAllowedByFilter({ ...ALL, women: false }, 'text', { ...woman, inlineEmoji: 'true' }), true);
});

test('mixed and uncertain Unicode classifications require all affected permissions', () => {
  const mixed = { ...woman, detectedCategories: ['men', 'women', 'nonHumanImages'] };
  assert.equal(contentAllowedByFilter({ ...ALL, men: false }, 'text', mixed), false);
  assert.equal(contentAllowedByFilter(ALL, 'text', mixed), true);
  assert.equal(contentAllowedByFilter({ ...ALL, children: false }, 'text', {
    ...woman, category: null, detectedCategories: [], uncertain: true,
  }), false);
  assert.equal(contentAllowedByFilter({ ...ALL, women: false }, 'text', {
    ...woman, category: 'nonHumanImages', detectedCategories: ['nonHumanImages'],
  }), true);
});

test('Unicode captions require visual permissions for every message type', () => {
  const filter = { ...ALL, women: false, video: false };
  for (const type of ['text', 'sticker', 'audio', 'image', 'video', 'document'])
    assert.equal(contentAllowedByFilter(filter, type, woman), false);
  for (const type of ['sticker', 'audio']) assert.equal(contentAllowedByFilter(filter, type, null), true);
});

async function fixture(t) {
  const config = { connectionString: process.env.DATABASE_URL,
    ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' } : false };
  const owner = new Pool(config);
  const schema = 'unicode_persistence_' + randomUUID().replaceAll('-', '');
  await owner.query(`CREATE SCHEMA "${schema}"`);
  const raw = new Pool({ ...config, options: `-c search_path=${schema},public`, max: 4 });
  t.after(async () => {
    await raw.end();
    await owner.query(`DROP SCHEMA "${schema}" CASCADE`);
    await owner.end();
  });
  process.env.MESSAGE_ENCRYPTION_KEY ||= 'isolated-unicode-fixture-encryption-key-32bytes';
  const securedQuery = query => async (sql, values) =>
    decryptMessageRows(await query(sql, encryptedQueryValues(sql, values)));
  const db = { query: securedQuery(raw.query.bind(raw)), async connect() {
    const client = await raw.connect();
    return { query: securedQuery(client.query.bind(client)), release: () => client.release() };
  } };
  await db.query(`CREATE TABLE users(id uuid PRIMARY KEY,name text,content_filter jsonb);
    CREATE TABLE groups(id uuid PRIMARY KEY,creator_id uuid,content_filter jsonb);
    CREATE TABLE group_members(group_id uuid,user_id uuid,status text,role text,
      joined_at timestamptz DEFAULT '2000-01-01',filter_override jsonb,pending_since timestamptz);
    CREATE TABLE user_contacts(owner_id uuid,contact_id uuid,filter_override jsonb,PRIMARY KEY(owner_id,contact_id));
    CREATE TABLE blocked_users(blocker_id uuid,blocked_id uuid);
    CREATE TABLE listing_conversations(buyer_id uuid,seller_id uuid,inquiry_sent boolean);
    CREATE TABLE stored_files(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),user_id uuid,public_url text,
      file_type text,moderation_status text,moderation_details jsonb,content_purged_at timestamptz);
    CREATE TABLE message_requests(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),sender_id uuid,recipient_id uuid,
      body text,type text,file_url text,file_name text,created_at timestamptz DEFAULT clock_timestamp(),
      audit_operation_id uuid,audit_parent_event_id bigint);
    CREATE TABLE messages(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),sender_id uuid,recipient_id uuid,group_id uuid,
      body text,type text,file_url text,file_name text,delivery_summary jsonb,created_at timestamptz DEFAULT clock_timestamp(),
      audit_operation_id uuid,audit_parent_event_id bigint,deleted_for_everyone boolean DEFAULT false,
      deleted_for_sender boolean DEFAULT false);
    CREATE TABLE message_user_deletions(message_id uuid,user_id uuid);
    CREATE TABLE received_message_media(message_id uuid,user_id uuid,stored_file_id uuid,status text);
    CREATE TABLE conversation_user_state(user_id uuid,kind text,target_id uuid,cleared_at timestamptz);
    CREATE TABLE filter_audit_events(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      message_id uuid,user_id uuid,kind text,details jsonb);`);
  await db.query(fs.readFileSync(require.resolve('../server/scoped-content-filter.sql'), 'utf8'));
  await db.query(FILTER_MEDIA_SCHEMA);
  // Repeat the migration to verify that existing installations remain valid.
  await db.query(requests.REQUEST_SCHEMA);
  await db.query(requests.REQUEST_SCHEMA);
  const sender = randomUUID(), recipient = randomUUID(), group = randomUUID();
  await db.query('INSERT INTO users VALUES($1,$2,$3),($4,$5,$3)',
    [sender, 'sender', ALL, recipient, 'recipient']);
  await db.query('INSERT INTO groups VALUES($1,$2,$3)', [group, sender, ALL]);
  await db.query(`INSERT INTO group_members(group_id,user_id,status,role,filter_override)
    VALUES($1,$2,'member','admin',$4),($1,$3,'member','member',$4)`, [group, sender, recipient, ALL]);
  const enqueue = async (classification = woman, extra = {}) => requests.queueContactRequest(db, {
    senderId: sender, recipientId: recipient, body: 'שלום 👩🏽‍🔧', type: 'text',
    emojiClassification: classification, ...extra,
  });
  const accept = async (filter = ALL, { failAudit = false, validateFile = async () => true } = {}) => {
    const client = await db.connect();
    try {
      await client.query('BEGIN');
      await requests.lockContactRequests(client, sender, recipient);
      const result = await requests.settleContactRequests(client, { senderId: sender,
        recipientId: recipient, filter, validateFile,
        audit: async () => { if (failAudit) throw new Error('fixture audit failure'); } });
      await client.query('COMMIT');
      return result;
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally { client.release(); }
  };
  const message = async ({ from = sender, to = recipient, groupId = null,
    classification = woman, deliverySummary = {}, type = 'text', fileUrl = null } = {}) => {
    const row = await db.query(`INSERT INTO messages(sender_id,recipient_id,group_id,body,type,delivery_summary,file_url)
      VALUES($1,$2,$3,$4,$5,$6,$7) RETURNING *`, [from, groupId ? null : to, groupId, 'שלום 👩🏽‍🔧', type,
      { ...deliverySummary, ...(classification ? { inlineEmojiClassification: classification } : {}) }, fileUrl]);
    return row.rows[0];
  };
  const file = async ({ type = 'image', classification = { category: 'nonHumanImages',
    detectedCategories: ['nonHumanImages'], uncertain: false }, status = 'approved' } = {}) => {
    const url = '/fixture/' + randomUUID();
    await db.query(`INSERT INTO stored_files(user_id,public_url,file_type,moderation_status,moderation_details)
      VALUES($1,$2,$3,$4,$5)`, [sender, url, type, status, { classification }]);
    return url;
  };
  const project = async (viewer, rows, groupId = null) => projectFilteredHistory(db, viewer, rows, { groupId });
  return { db, raw, sender, recipient, group, enqueue, accept, message, file, project };
}

test('pending Unicode text is encrypted and retains only server classification metadata', dbOptions, async t => {
  const f = await fixture(t);
  const operationId = randomUUID();
  await f.enqueue(woman, { operationId, parentEventId: 17 });
  const stored = (await f.raw.query('SELECT * FROM message_requests')).rows[0];
  assert.match(stored.body, /^enc:v1:/);
  assert.deepEqual(stored.emoji_classification, woman);
  assert.equal(stored.type, 'text');
  assert.equal(stored.audit_operation_id, operationId);
  assert.equal(stored.audit_parent_event_id, '17');
  assert.equal((await f.db.query('SELECT * FROM messages')).rows.length, 0);
});

test('acceptance rejects a previously scanned Unicode message under the selected visual filter', dbOptions, async t => {
  const f = await fixture(t);
  await f.enqueue();
  const result = await f.accept({ ...ALL, women: false });
  assert.equal(result.sent.length, 0);
  assert.equal(result.rejected.length, 1);
  assert.equal(result.rejected[0].code, 'recipient_content_filter');
  assert.match(result.rejected[0].reason, /נשים/);
  assert.equal((await f.db.query('SELECT * FROM messages')).rows.length, 0);
  assert.equal((await f.db.query('SELECT status FROM message_requests')).rows[0].status, 'rejected');
});

test('acceptance preserves text and classification in message metadata and delivers once', dbOptions, async t => {
  const f = await fixture(t);
  await f.enqueue();
  const result = await f.accept();
  assert.equal(result.sent.length, 1);
  assert.equal(result.sent[0].body, 'שלום 👩🏽‍🔧');
  assert.equal(result.sent[0].type, 'text');
  assert.deepEqual(result.sent[0].classification, woman);
  assert.deepEqual(result.sent[0].delivery_summary.inlineEmojiClassification, woman);
  assert.match((await f.raw.query('SELECT body FROM messages')).rows[0].body, /^enc:v1:/);
  assert.equal((await f.db.query('SELECT * FROM message_requests')).rows.length, 0);
  assert.equal((await f.accept()).sent.length, 0);
});

test('failed acceptance rolls back both message metadata and request removal', dbOptions, async t => {
  const f = await fixture(t);
  await f.enqueue();
  await assert.rejects(f.accept(ALL, { failAudit: true }), /fixture audit failure/);
  assert.equal((await f.db.query('SELECT * FROM messages')).rows.length, 0);
  const pending = (await f.db.query('SELECT * FROM message_requests')).rows[0];
  assert.equal(pending.status, 'pending');
  assert.deepEqual(pending.emoji_classification, woman);
});

test('legacy text and approved files keep their original classification and acceptance paths', dbOptions, async t => {
  const f = await fixture(t);
  await f.enqueue(null, { body: 'שלום רגיל' });
  await f.db.query(`INSERT INTO stored_files(user_id,public_url,file_type,moderation_status,moderation_details)
    VALUES($1,'/fixture.png','image','approved',$2)`, [f.sender,
    { classification: { category: 'nonHumanImages', detectedCategories: ['nonHumanImages'] } }]);
  await f.enqueue(woman, { type: 'image', body: null, fileUrl: '/fixture.png', fileName: 'fixture.png' });
  const pending = (await f.db.query('SELECT * FROM message_requests')).rows;
  assert.ok(pending.every(row => row.emoji_classification === null));
  const result = await f.accept({ ...ALL, women: false });
  assert.equal(result.sent.length, 2);
  assert.ok(result.sent.every(row => !row.classification));
  assert.deepEqual(new Set(result.sent.map(row => row.type)), new Set(['text', 'image']));
});

test('private history rechecks changed scoped filters and redacts incoming Unicode while preserving outbound text', dbOptions, async t => {
  const f = await fixture(t);
  const incoming = await f.message();
  const outgoing = await f.message({ from: f.recipient, to: f.sender });
  const legacy = await f.message({ classification: null });
  assert.equal((await f.project(f.recipient, [incoming]))[0].body, incoming.body);
  await f.db.query('INSERT INTO user_contacts VALUES($1,$2,$3)',
    [f.recipient, f.sender, { ...ALL, women: false }]);
  const rows = await f.project(f.recipient, [incoming, outgoing, legacy]);
  assert.equal(rows[0].body, null);
  assert.equal(rows[0].text, null);
  assert.equal(rows[0].filter_hidden, true);
  assert.equal(rows[0].hidden_reason, 'content_filter');
  assert.equal(rows[1].body, outgoing.body);
  assert.equal(rows[1].filter_hidden, false);
  assert.equal(rows[2].body, legacy.body);
  await f.db.query('UPDATE user_contacts SET filter_override=$1 WHERE owner_id=$2', [ALL, f.recipient]);
  assert.equal((await f.project(f.recipient, [incoming]))[0].body, incoming.body);
});

test('self history applies the current general filter to scanned Unicode', dbOptions, async t => {
  const f = await fixture(t);
  const self = await f.message({ from: f.sender, to: f.sender });
  await f.db.query('UPDATE users SET content_filter=$1 WHERE id=$2', [{ ...ALL, women: false }, f.sender]);
  const row = (await f.project(f.sender, [self]))[0];
  assert.equal(row.type, 'text');
  assert.equal(row.body, null);
  assert.equal(row.filter_hidden, true);
});

test('outbound private Unicode remains visible under the sender general viewing preference', dbOptions, async t => {
  const f = await fixture(t);
  const msg = await f.message();
  await f.db.query('UPDATE users SET content_filter=$1 WHERE id=$2',
    [{ ...ALL, women: false, enforceGeneralFilter: true }, f.sender]);
  const row = (await f.project(f.sender, [msg]))[0];
  assert.equal(row.body, msg.body);
  assert.equal(row.filter_hidden, false);
});

test('a later group join uses current group policy rather than an absent delivery snapshot', dbOptions, async t => {
  const f = await fixture(t);
  await f.db.query(`UPDATE group_members SET status='pending',pending_since=now() WHERE user_id=$1`, [f.recipient]);
  const msg = await f.message({ groupId: f.group, deliverySummary: { deliveredCount: 0 } });
  await f.db.query(`UPDATE group_members SET status='member',joined_at=pending_since WHERE user_id=$1`, [f.recipient]);
  await f.db.query('UPDATE groups SET content_filter=$1 WHERE id=$2', [{ ...ALL, women: false }, f.group]);
  const row = (await f.project(f.recipient, [msg], f.group))[0];
  assert.equal(row.body, null);
  assert.equal(row.filter_hidden, true);
  assert.equal(row.type, 'text');
  await f.db.query('UPDATE groups SET content_filter=$1 WHERE id=$2', [ALL, f.group]);
  assert.equal((await f.project(f.recipient, [msg], f.group))[0].body, msg.body);
});

test('current member and enforced creator filters both apply to group Unicode history', dbOptions, async t => {
  const f = await fixture(t);
  const msg = await f.message({ groupId: f.group });
  await f.db.query('UPDATE group_members SET filter_override=$1 WHERE user_id=$2',
    [{ ...ALL, women: false }, f.recipient]);
  assert.equal((await f.project(f.recipient, [msg], f.group))[0].body, null);
  await f.db.query('UPDATE group_members SET filter_override=$1 WHERE user_id=$2', [ALL, f.recipient]);
  await f.db.query('UPDATE users SET content_filter=$1 WHERE id=$2',
    [{ ...ALL, women: false, enforceGeneralFilter: true }, f.sender]);
  assert.equal((await f.project(f.recipient, [msg], f.group))[0].body, null);
});

test('group authors retain the existing personal history filtering semantics', dbOptions, async t => {
  const f = await fixture(t);
  const msg = await f.message({ groupId: f.group });
  await f.db.query('UPDATE group_members SET filter_override=$1 WHERE user_id=$2',
    [{ ...ALL, women: false }, f.sender]);
  assert.equal((await f.project(f.sender, [msg], f.group))[0].body, null);
  assert.equal((await f.project(f.recipient, [msg], f.group))[0].body, msg.body);
});

test('metadata is authoritative over client presentation and personal deletions remain effective', dbOptions, async t => {
  const f = await fixture(t);
  const msg = await f.message();
  await f.db.query('UPDATE users SET content_filter=$1 WHERE id=$2', [{ ...ALL, women: false, enforceGeneralFilter: true }, f.recipient]);
  const altered = { ...msg, classification: { inlineEmoji: true, category: 'nonHumanImages' } };
  assert.equal((await f.project(f.recipient, [altered]))[0].body, null);
  await f.db.query('INSERT INTO message_user_deletions VALUES($1,$2)', [msg.id, f.recipient]);
  assert.deepEqual(await f.project(f.recipient, [msg]), []);
});

test('pending attachment captions are encrypted and both file and emoji categories gate acceptance', dbOptions, async t => {
  const f = await fixture(t);
  const man = { category: 'men', detectedCategories: ['men'], uncertain: false };
  for (const [index, filter] of [{ ...ALL, women: false }, { ...ALL, men: false }].entries()) {
    const fileUrl = await f.file({ classification: man });
    await f.enqueue(woman, { type: 'image', fileUrl, fileName: `caption-${index}.png` });
    const pending = (await f.raw.query('SELECT * FROM message_requests WHERE file_url=$1', [fileUrl])).rows[0];
    assert.match(pending.body, /^enc:v1:/);
    assert.deepEqual(pending.emoji_classification, woman);
    const result = await f.accept(filter);
    assert.equal(result.sent.length, 0);
    assert.equal(result.rejected.length, 1);
    assert.equal(result.rejected[0].code, 'recipient_content_filter');
  }
  assert.equal((await f.db.query('SELECT * FROM messages')).rows.length, 0);
});

test('accepted attachment retains caption metadata without replacing the file classification', dbOptions, async t => {
  const f = await fixture(t);
  const man = { category: 'men', detectedCategories: ['men'], uncertain: false };
  const fileUrl = await f.file({ type: 'video', classification: man });
  await f.enqueue(woman, { type: 'video', fileUrl, fileName: 'caption.mp4' });
  let validations = 0;
  const result = await f.accept(ALL, { validateFile: async () => { validations++; return true; } });
  assert.equal(validations, 1);
  assert.equal(result.sent.length, 1);
  const msg = result.sent[0];
  assert.equal(msg.body, 'שלום 👩🏽‍🔧');
  assert.equal(msg.file_url, fileUrl);
  assert.equal(msg.classification.category, 'men');
  assert.deepEqual(msg.classification.detectedCategories, ['men', 'women']);
  assert.deepEqual(msg.delivery_summary.inlineEmojiClassification, woman);
  assert.deepEqual((await f.db.query('SELECT moderation_details FROM stored_files WHERE public_url=$1', [fileUrl]))
    .rows[0].moderation_details.classification, man);
  assert.match((await f.raw.query('SELECT body FROM messages')).rows[0].body, /^enc:v1:/);
  assert.equal((await f.accept()).sent.length, 0);
});

test('attachment dedup completes a scan placeholder once and rejects conflicting captions without data loss', dbOptions, async t => {
  const f = await fixture(t);
  const fileUrl = await f.file();
  const first = await f.enqueue(null, { type: 'image', fileUrl, fileName: 'fixture.png', body: 'fixture.png' });
  const completed = await f.enqueue(woman, { type: 'image', fileUrl, fileName: 'fixture.png' });
  assert.equal(completed.id, first.id);
  assert.equal((await f.enqueue(woman, { type: 'image', fileUrl, fileName: 'fixture.png' })).id, first.id);
  // A delayed background scan retry carries only the file-name placeholder.
  // It must reuse, rather than overwrite or conflict with, the real caption.
  assert.equal((await f.enqueue(null, { type: 'image', fileUrl, fileName: 'fixture.png', body: 'fixture.png' })).id, first.id);
  await assert.rejects(f.enqueue(woman, { type: 'image', fileUrl, fileName: 'fixture.png', body: 'כיתוב אחר 👩🏽‍🔧' }),
    error => error.status === 409 && error.code === 'CONTACT_REQUEST_CONTENT_CONFLICT');
  const rows = (await f.db.query('SELECT * FROM message_requests')).rows;
  assert.equal(rows.length, 1);
  assert.equal(rows[0].body, 'שלום 👩🏽‍🔧');
  assert.deepEqual(rows[0].emoji_classification, woman);
  assert.match((await f.raw.query('SELECT body FROM message_requests')).rows[0].body, /^enc:v1:/);
  assert.equal((await f.accept({ ...ALL, women: false })).sent.length, 0);
});

test('caption approval cannot bypass pending file moderation or current sender access', dbOptions, async t => {
  const f = await fixture(t);
  for (const status of ['pending', 'rejected']) {
    const fileUrl = await f.file({ status });
    await f.enqueue(woman, { type: 'image', fileUrl });
    const result = await f.accept();
    assert.equal(result.sent.length, 0);
    assert.equal(result.rejected[0].code, 'file_not_approved');
  }
  const fileUrl = await f.file();
  await f.enqueue(woman, { type: 'image', fileUrl });
  const result = await f.accept(ALL, { validateFile: async () => false });
  assert.equal(result.sent.length, 0);
  assert.equal(result.rejected[0].code, 'file_access_denied');
  assert.equal((await f.db.query('SELECT * FROM messages')).rows.length, 0);
});

test('a caption scan cannot supply the missing classification of an approved attachment', dbOptions, async t => {
  const f = await fixture(t);
  for (const type of ['image', 'video']) {
    const fileUrl = await f.file({ type, classification: null });
    await f.enqueue(woman, { type, fileUrl });
    const result = await f.accept({ ...ALL, men: false });
    assert.equal(result.sent.length, 0);
    assert.equal(result.rejected[0].code, 'recipient_content_filter');
    await f.enqueue(woman, { type, fileUrl });
    const allowed = await f.accept(ALL);
    assert.equal(allowed.sent.length, 1);
    assert.equal(allowed.sent[0].classification.category, 'people');
    assert.equal(allowed.sent[0].classification.uncertain, true);
  }
});

test('private attachment history checks both caption and file categories after reloading authoritative metadata', dbOptions, async t => {
  const f = await fixture(t);
  const rows = [];
  for (const type of ['image', 'video', 'document', 'audio']) {
    const fileUrl = await f.file({ type, classification: { category: 'men', detectedCategories: ['men'] } });
    rows.push(await f.message({ type, fileUrl }));
  }
  for (const category of ['women', 'men']) {
    await f.db.query('UPDATE users SET content_filter=$1 WHERE id=$2',
      [{ ...ALL, [category]: false, enforceGeneralFilter: true }, f.recipient]);
    const projected = await f.project(f.recipient, rows.map(row => ({ ...row,
      classification: { category: 'nonHumanImages' }, thumbnail_url: '/stale-thumb' })));
    assert.equal(projected.length, rows.length);
    for (const row of projected) {
      assert.equal(row.body, null, row.type);
      assert.equal(row.file_url, null, row.type);
      assert.equal(row.thumbnail_url, null, row.type);
      assert.equal(row.filter_hidden, true, row.type);
    }
  }
  await f.db.query('UPDATE users SET content_filter=$1 WHERE id=$2', [ALL, f.recipient]);
  const allowed = await f.project(f.recipient, rows);
  assert.ok(allowed.every(row => row.body && row.file_url));
});

test('image keep preserves personal history but never bypasses a current group caption gate', dbOptions, async t => {
  const f = await fixture(t);
  const fileUrl = await f.file();
  const personal = await f.message({ type: 'image', fileUrl });
  const group = await f.message({ type: 'image', fileUrl, groupId: f.group,
    deliverySummary: { deliveredCount: 0 } });
  await f.db.query(`INSERT INTO user_message_filter_actions(user_id,message_id,action)
    VALUES($1,$2,'keep'),($1,$3,'keep')`, [f.recipient, personal.id, group.id]);
  await f.db.query('UPDATE users SET content_filter=$1 WHERE id=$2',
    [{ ...ALL, women: false, enforceGeneralFilter: true }, f.recipient]);
  assert.equal((await f.project(f.recipient, [personal]))[0].file_url, fileUrl);
  assert.equal((await f.project(f.recipient, [group], f.group))[0].file_url, fileUrl);
  await f.db.query('UPDATE groups SET content_filter=$1 WHERE id=$2', [{ ...ALL, women: false }, f.group]);
  const hidden = (await f.project(f.recipient, [group], f.group))[0];
  assert.equal(hidden.body, null);
  assert.equal(hidden.file_url, null);
  assert.equal(hidden.filter_hidden, true);
  assert.equal(hidden.filter_kept, false);
  await f.db.query('UPDATE groups SET content_filter=$1 WHERE id=$2', [ALL, f.group]);
  assert.equal((await f.project(f.recipient, [group], f.group))[0].file_url, fileUrl);
});

test('plain replies hide quoted visual emoji when the source is filtered, then restore it when allowed', dbOptions, async t => {
  const f = await fixture(t);
  const source = await f.message();
  const reply = await f.message({ classification: null });
  const item = { ...reply, body: 'תגובה רגילה', reply_to_id: source.id, reply_body: source.body };
  await f.db.query('UPDATE users SET content_filter=$1 WHERE id=$2',
    [{ ...ALL, women: false, enforceGeneralFilter: true }, f.recipient]);
  const hidden = (await f.project(f.recipient, [item]))[0];
  assert.equal(hidden.body, item.body);
  assert.equal(hidden.reply_body, null);
  await f.db.query('UPDATE users SET content_filter=$1 WHERE id=$2', [ALL, f.recipient]);
  assert.equal((await f.project(f.recipient, [item]))[0].reply_body, source.body);
});

test('quoted visual emoji cannot reveal a deleted or inaccessible private source', dbOptions, async t => {
  const f = await fixture(t);
  const reply = await f.message({ classification: null });
  const deleted = await f.message();
  const unrelated = await f.message({ to: randomUUID() });
  await f.db.query('UPDATE messages SET deleted_for_everyone=true WHERE id=$1', [deleted.id]);
  for (const source of [deleted, unrelated]) {
    const item = { ...reply, body: 'תגובה רגילה', replyToId: source.id, replyBody: source.body };
    const projected = (await f.project(f.recipient, [item]))[0];
    assert.equal(projected.body, item.body);
    assert.equal(projected.replyBody, null);
  }
});

test('quoted group visual emoji respects the current group policy', dbOptions, async t => {
  const f = await fixture(t);
  const source = await f.message({ groupId: f.group });
  const reply = await f.message({ groupId: f.group, classification: null });
  await f.db.query('UPDATE groups SET content_filter=$1 WHERE id=$2', [{ ...ALL, women: false }, f.group]);
  const projected = (await f.project(f.recipient,
    [{ ...reply, body: 'תגובה רגילה', reply_to_id: source.id, reply_body: source.body }], f.group))[0];
  assert.equal(projected.body, 'תגובה רגילה');
  assert.equal(projected.reply_body, null);
});
