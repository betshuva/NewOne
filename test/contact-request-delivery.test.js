'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const fs = require('node:fs');
const vm = require('node:vm');
const { Pool } = require('pg');
const requests = require('../server/contact-message-requests');
const friendship = require('../server/friendship-policy');
const policy = require('../server/content-filter-policy');
const filterPin = require('../server/filter-pin');
const { encryptedQueryValues, decryptMessageRows } = require('../server/message-at-rest');
const source = fs.readFileSync(require.resolve('../server/index.js'), 'utf8');
const opts = { skip: process.env.RUN_DB_TESTS !== '1' };
const all = { text: true, video: true, men: true, women: true, children: true, nonHumanImages: true };
const none = Object.fromEntries(Object.keys(all).map(k => [k, false]));
const types = ['text', 'sticker', 'image', 'video', 'audio', 'document'];

async function fixture(t) {
  process.env.MESSAGE_ENCRYPTION_KEY ||= 'test-message-encryption-key-at-least-32-bytes';
  const schema = 'request_' + randomUUID().replaceAll('-', '');
  const admin = new Pool({ connectionString: process.env.DATABASE_URL });
  await admin.query(`CREATE SCHEMA ${schema}`);
  const raw = new Pool({ connectionString: process.env.DATABASE_URL, options: `-c search_path=${schema},public` });
  const secured = query => async (sql, values) => decryptMessageRows(await query(sql, encryptedQueryValues(sql, values)));
  const db = { query: secured(raw.query.bind(raw)), async connect() {
    const client = await raw.connect(); return { query: secured(client.query.bind(client)), release: () => client.release() };
  } };
  t.after(async () => { await raw.end(); await admin.query(`DROP SCHEMA ${schema} CASCADE`); await admin.end(); });
  await db.query(`CREATE TABLE users(id uuid PRIMARY KEY,name text,content_filter jsonb,birth_date date DEFAULT '1990-01-01');
    CREATE TABLE listings(id uuid PRIMARY KEY,user_id uuid,status text,contact_count integer DEFAULT 0,expires_at timestamptz,contact_preferences jsonb);
    CREATE TABLE group_members(user_id uuid,group_id uuid,status text);
    CREATE TABLE user_contacts(owner_id uuid,contact_id uuid,filter_override jsonb,contact_source text DEFAULT 'unknown',filter_choice_confirmed boolean DEFAULT false,PRIMARY KEY(owner_id,contact_id));
    CREATE TABLE blocked_users(blocker_id uuid,blocked_id uuid);
    CREATE TABLE stored_files(id uuid DEFAULT gen_random_uuid(),public_url text UNIQUE,user_id uuid,file_type text,moderation_status text,moderation_details jsonb,content_purged_at timestamptz);
    CREATE TABLE message_requests(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),sender_id uuid REFERENCES users,recipient_id uuid REFERENCES users,body text,type text,file_url text,file_name text,created_at timestamptz DEFAULT now(),audit_operation_id uuid,audit_parent_event_id bigint);
    CREATE TABLE messages(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),sender_id uuid,recipient_id uuid,reply_to_id uuid,body text,type text,file_url text,file_name text,created_at timestamptz DEFAULT now(),audit_operation_id uuid,audit_parent_event_id bigint);
    CREATE TABLE message_status(message_id uuid,user_id uuid,status text,updated_at timestamptz,PRIMARY KEY(message_id,user_id));
    CREATE TABLE private_message_sends(user_id uuid,client_message_id text,request_hash text,result jsonb,PRIMARY KEY(user_id,client_message_id));`);
  await db.query(requests.REQUEST_SCHEMA);
  await db.query(filterPin.SCHEMA);
  await friendship.initializeFriendshipPolicy(db);
  const sender = randomUUID(), recipient = randomUUID();
  await db.query('INSERT INTO users(id,name,content_filter) VALUES($1,$2,$3),($4,$5,$6)', [sender,'sender',all,recipient,'recipient',none]);
  const notices = [], audits = [], errors = [];
  const getEffectiveRecipientFilter = vm.runInNewContext(source.slice(source.indexOf('async function getEffectiveRecipientFilter('), source.indexOf('async function buildGroupDeliveryPlan(')) + ';getEffectiveRecipientFilter', {...policy,...friendship});
  async function validateFile(db, senderId, url) {
    return (await db.query("SELECT 1 FROM stored_files WHERE user_id=$1 AND public_url=$2 AND moderation_status='approved' AND content_purged_at IS NULL", [senderId,url])).rows.length > 0;
  }
  const scope = {
    ...require('./helpers/system-audit-stubs'), ...requests, ...policy, ...friendship, ...filterPin, notifyFriendshipChange() {},
    getPool: async () => db, authWithDbCheck() {}, auth() {}, messageRateLimit() {},
    SYSTEM_USER_ID: 'guide', SAFE_INFORMATION_USER_ID: 'info', SCAN_BOT_ID: 'scan',
    normalizeBuiltinStickerId: id => id === 'sticker' ? id : null,
    moderateChatText: () => ({ blocked: false }), verifyMessageLinks: async () => {},
    teenContactAllowed: async () => true, getEffectiveRecipientFilter,
    getStoredImageClassification: async (client,url) => (await client.query('SELECT moderation_details FROM stored_files WHERE public_url=$1',[url])).rows[0]?.moderation_details?.classification,
    validateApprovedFile: validateFile, shortFilterReason: require('../server/guide-filter-notice').shortFilterReason,
    withPrivateMessageReceipt: require('../server/private-message-receipts').withPrivateMessageReceipt,
    registerGuideMessageSend() {}, sendGroupHttpMessage() {}, phoneSharingChoices: () => ({}), applyPhoneSharingChoices: async () => ({}), notifyPhoneSharingChange() {},
    recordAuditEvent: async (_db,event) => audits.push(event), onlineUsers: new Map([[recipient,'recipient-socket']]),
    io: { to: user => ({ emit: (event,payload) => notices.push({user,event,payload}) }) },
    relay: (user,event,payload) => notices.push({user,event,payload}), sendPush: (...data) => notices.push({event:'push',data}),
    recipientMediaMessage: async (_db,_user,message) => message,
    recordFilterDecision: async () => {}, notifyDestinationFilterBlock: async () => {},
    logActivity() {}, writeSenderFilteredMedia: async (client,_options,write) => write(client),
    console: { error: (...args) => errors.push(args), warn() {} },
  };
  const routes = {};
  const app = { post: (path,...handlers) => routes[path] = handlers.at(-1), delete: (path,...handlers) => routes['DELETE '+path] = handlers.at(-1) };
  vm.runInNewContext(source.slice(source.indexOf('async function sendPrivateHttpMessage('), source.indexOf("app.get('/api/message-requests',")), {...scope,app});
  vm.runInNewContext(source.slice(source.indexOf('async function recordContactRequestOutcome('), source.indexOf('// ── Messages: mark as read')), {...scope,app});
  let socketHandler;
  const socket = {user:{id:sender,name:'sender'},handshake:{address:'127.0.0.1'},on(_event,fn){socketHandler=fn;}, emit:(event,payload)=>notices.push({user:sender,event,payload})};
  vm.runInNewContext(source.slice(source.indexOf("  socket.on('chat:message',"),source.indexOf("  socket.on('chat:typing',")), {...scope,socket});
  async function call(path, body, requestId, user = sender) {
    const res = {code:200,set(){},status(code){this.code=code;return this;},json(body){this.body=body;return this;}};
    await routes[path]({ user:{id:user,name:user===sender?'sender':'recipient'}, headers:{authorization:'Bearer fixture-'+user}, body, params:{id:requestId} }, res);
    return res;
  }
  async function payload(type, suffix = '') {
    if (type === 'text') return {toUserId:recipient,text:'הודעה פרטית'+suffix};
    if (type === 'sticker') return {toUserId:recipient,stickerId:'sticker'};
    const fileUrl = '/test/'+type+suffix;
    await db.query("INSERT INTO stored_files(public_url,user_id,file_type,moderation_status,moderation_details) VALUES($1,$2,$3,'approved',$4) ON CONFLICT DO NOTHING",
      [fileUrl,sender,type,{ classification:{category:'nonHumanImages',detectedCategories:['nonHumanImages'],uncertain:false} }]);
    return {toUserId:recipient,fileUrl,fileName:type+suffix,fileType:type};
  }
  return {db,raw,sender,recipient,notices,audits,errors,call,payload,scope,socketHandler,
    accept: (id,filter=all) => call('/api/message-requests/:id/accept',{filter},id,recipient),
    decline: id => call('DELETE /api/message-requests/:id',{},id,recipient),
  };
}

for (const transport of ['HTTP','Socket']) test(`${transport}: all six types wait without exposing content, then an allowed selection delivers once`, opts, async t => {
  const f = await fixture(t);
  for (const type of types) {
    const body = await f.payload(type);
    if (transport === 'HTTP') {
      const result = await f.call('/api/messages',body);
      assert.equal(result.code,200,JSON.stringify(result.body));assert.equal(result.body.requestPending,true);
    } else await f.socketHandler(body);
  }
  assert.deepEqual(f.errors,[]);
  assert.equal((await f.db.query('SELECT * FROM messages')).rows.length,0);
  assert.equal(f.notices.filter(n => n.event==='chat:message').length,0);
  const pending = (await f.db.query('SELECT * FROM message_requests')).rows;
  assert.equal(pending.length,6);
  assert.match((await f.raw.query("SELECT body FROM message_requests WHERE type='text'")).rows[0].body,/^enc:v1:/);
  const results = await Promise.all([f.accept(pending[0].id),f.accept(pending[0].id)]);
  assert.equal(results.filter(r=>r.code===200).length,1);
  assert.equal((await f.db.query('SELECT * FROM messages')).rows.length,6);
  assert.equal((await f.db.query('SELECT * FROM message_requests')).rows.length,0);
  assert.equal(f.notices.filter(n => n.event==='chat:message').length,6);
});

test('accepting friendship delivers allowed items only; rejected video has durable precise reason', opts, async t => {
  const f=await fixture(t);
  const ids=[];for(const type of types) ids.push((await f.call('/api/messages',await f.payload(type))).body.id);
  const res=await f.accept(ids[0],{...all,video:false});assert.equal(res.code,200,JSON.stringify(res.body));
  assert.equal(res.body.messageIds.length,5);assert.equal(res.body.rejected.length,1);
  assert.match(res.body.rejected[0].reason,/סרטונים חסומים/);
  const left=(await f.db.query('SELECT * FROM message_requests')).rows;
  assert.equal(left.length,1);assert.equal(left[0].type,'video');assert.equal(left[0].status,'rejected');
  assert.equal(left[0].rejection_code,'recipient_content_filter');
  assert.equal((await f.db.query("SELECT * FROM messages WHERE type='video'")).rows.length,0);
  assert.equal(f.notices.some(n=>n.event==='chat:message'&&n.payload.fileType==='video'),false);
});

test('enforced general filter blocks people and video even when acceptance asks to allow them', opts, async t => {
  const f=await fixture(t);const first=await f.call('/api/messages',await f.payload('text'));
  for(const type of types.slice(1)) await f.call('/api/messages',await f.payload(type));
  await f.db.query('UPDATE users SET content_filter=$1 WHERE id=$2',[{...none,enforceGeneralFilter:true},f.recipient]);
  await f.db.query("UPDATE stored_files SET moderation_details=$1",[{classification:{category:'men',detectedCategories:['men']}}]);
  const res=await f.accept(first.body.id,all);assert.equal(res.code,200,JSON.stringify(res.body));
  assert.equal(res.body.messageIds.length,3);assert.equal(res.body.rejected.length,3);
  const sent=(await f.db.query('SELECT type FROM messages ORDER BY type')).rows.map(row=>row.type);
  assert.deepEqual(sent,['audio','sticker','text']);
});

test('declining friendship resolves every pending item, preserves reason and never sends', opts, async t => {
  const f=await fixture(t);const first=await f.call('/api/messages',await f.payload('text'));
  for(const type of types.slice(1)) await f.call('/api/messages',await f.payload(type));
  assert.equal((await f.decline(first.body.id)).code,200);
  const rows=(await f.db.query('SELECT * FROM message_requests')).rows;
  assert.equal(rows.length,6);assert.ok(rows.every(r=>r.status==='rejected'&&r.rejection_code==='contact_request_declined'));
  assert.equal((await f.db.query('SELECT * FROM messages')).rows.length,0);
  assert.equal((await f.accept(first.body.id)).code,404);
});

test('attachment retries and HTTP idempotency create one pending item; authorization is rechecked at acceptance', opts, async t => {
  const f=await fixture(t);const body=await f.payload('video');
  const results=await Promise.all([f.call('/api/messages',body),f.call('/api/messages',body)]);
  assert.equal(results[0].body.id,results[1].body.id);
  const text=await f.payload('text');text.clientMessageId='same-contact-send-12345';
  const a=await f.call('/api/messages',text),b=await f.call('/api/messages',text);assert.equal(a.body.id,b.body.id);
  await f.db.query('INSERT INTO blocked_users VALUES($1,$2)',[f.recipient,f.sender]);
  const res=await f.accept(a.body.id);assert.equal(res.code,200);assert.equal(res.body.messageIds.length,0);
  assert.ok(res.body.rejected.every(r=>r.code==='recipient_blocked_sender'));
});

test('removed media cannot be released on approval; other allowed items still send', opts, async t => {
  const f=await fixture(t);const video=await f.call('/api/messages',await f.payload('video'));
  await f.call('/api/messages',await f.payload('text'));
  await f.db.query('UPDATE stored_files SET content_purged_at=now()');
  const res=await f.accept(video.body.id);assert.equal(res.code,200);assert.equal(res.body.messageIds.length,1);
  assert.equal(res.body.rejected[0].code,'file_not_approved');
});

test('socket failures never fall back to unapproved raw delivery', opts, async t => {
  const f=await fixture(t);await f.db.query('INSERT INTO blocked_users VALUES($1,$2)',[f.recipient,f.sender]);
  await f.socketHandler(await f.payload('text'));
  assert.equal(f.notices.some(n=>n.event==='chat:message'),false);
  assert.equal(f.notices.find(n=>n.event==='message:rejected').payload.code,'RECIPIENT_BLOCKED_SENDER');
});


test('earlier conversation does not replace current contact approval',opts,async t=>{
 const f=await fixture(t);await f.db.query("INSERT INTO messages(sender_id,recipient_id,type,body) VALUES($1,$2,'text','old')",[f.sender,f.recipient]);
 const result=await f.call('/api/messages',await f.payload('text'));assert.equal(result.body.requestPending,true);
 assert.equal((await f.db.query('SELECT * FROM messages')).rows.length,1);
});

test('failed settlement rolls back both delivery and request resolution',opts,async t=>{
 const f=await fixture(t);for(const type of ['text','video'])await f.call('/api/messages',await f.payload(type));
 const client=await f.db.connect();try {
  await client.query('BEGIN');await requests.lockContactRequests(client,f.sender,f.recipient);
  await assert.rejects(()=>requests.settleContactRequests(client,{senderId:f.sender,recipientId:f.recipient,filter:all,
   validateFile:async()=>true,audit:async()=>{throw new Error('forced failure')}}),/forced failure/);
  await client.query('ROLLBACK');
 }finally{client.release()}
 assert.equal((await f.db.query('SELECT * FROM messages')).rows.length,0);
 assert.equal((await f.db.query("SELECT * FROM message_requests WHERE status='pending'")).rows.length,2);
});

test('marketplace HTTP inquiry is delivered without friendship; filtered reply cannot create friendship', opts, async t => {
  const f=await fixture(t);
  const listing=randomUUID();
  await f.db.query("INSERT INTO listings(id,user_id,status) VALUES($1,$2,'active')",[listing,f.recipient]);
  await f.db.query('UPDATE users SET content_filter=$1 WHERE id=$2',[all,f.recipient]);
  const inquiry=await f.call('/api/messages',{toUserId:f.recipient,text:'שלום, האם זמין?',listingId:listing});
  assert.equal(inquiry.code,200,JSON.stringify(f.errors));
  assert.equal(inquiry.body.requestPending,undefined);
  assert.equal((await f.db.query('SELECT * FROM messages')).rows.length,1);
  assert.equal((await f.db.query('SELECT * FROM user_contacts')).rows.length,0);
  await f.db.query('UPDATE users SET content_filter=$1 WHERE id=$2',[none,f.sender]);
  await f.db.query("INSERT INTO stored_files(public_url,user_id,file_type,moderation_status,moderation_details) VALUES('/test/seller-video',$1,'video','approved',$2)",
    [f.recipient,{classification:{detectedCategories:['nonHumanImages'],category:'nonHumanImages'}}]);
  const refused=await f.call('/api/messages',{toUserId:f.sender,fileUrl:'/test/seller-video',fileType:'video',fileName:'reply.mp4'},null,f.recipient);
  assert.equal(refused.code,403);
  assert.equal((await f.db.query('SELECT * FROM user_contacts')).rows.length,0);
  await f.db.query('UPDATE users SET content_filter=$1 WHERE id=$2',[all,f.sender]);
  const reply=await f.call('/api/messages',{toUserId:f.sender,text:'כן, זמין'},null,f.recipient);
  assert.equal(reply.code,200,JSON.stringify(f.errors));
  assert.equal((await f.db.query('SELECT * FROM user_contacts')).rows.length,2);
  assert.equal((await f.db.query('SELECT * FROM message_requests')).rows.length,0);
});

test('locked friendship approval keeps inherited filtering and delivers permitted text', opts, async t => {
 const f=await fixture(t);
 const first=await f.call('/api/messages',await f.payload('text'));
 await f.db.query('INSERT INTO filter_pin_settings(user_id,pin_hash,recovery_email) VALUES($1,$2,$3)',[f.recipient,'unused-test-hash','test@example.test']);
 const res=await f.call('/api/message-requests/:id/accept',{},first.body.id,f.recipient);
 assert.equal(res.code,200,JSON.stringify(res.body));
 const contact=(await f.db.query('SELECT filter_override,filter_choice_confirmed FROM user_contacts WHERE owner_id=$1 AND contact_id=$2',[f.recipient,f.sender])).rows[0];
 assert.equal(contact.filter_override,null);assert.equal(contact.filter_choice_confirmed,true);
 assert.equal(res.body.messageIds.length,1);
});
test('a locked approval cannot change filtering or consume the pending request', opts, async t => {
 const f=await fixture(t);
 const first=await f.call('/api/messages',await f.payload('text'));
 await f.db.query('INSERT INTO filter_pin_settings(user_id,pin_hash,recovery_email) VALUES($1,$2,$3)',[f.recipient,'unused-test-hash','test@example.test']);
 const res=await f.accept(first.body.id,all);
 assert.equal(res.code,423);assert.equal(res.body.code,'FILTER_PIN_LOCKED');
 assert.equal((await f.db.query('SELECT status FROM message_requests WHERE id=$1',[first.body.id])).rows[0].status,'pending');
 assert.equal((await f.db.query('SELECT count(*)::int AS n FROM user_contacts WHERE owner_id=$1',[f.recipient])).rows[0].n,0);
 const allowed=await f.accept(first.body.id,policy.normalizeContentFilter(none));
 assert.equal(allowed.code,200,JSON.stringify(allowed.body));
});
test('locked friendship approval preserves an existing private override', opts, async t => {
 const f=await fixture(t);
 const first=await f.call('/api/messages',await f.payload('text'));
 const override={...none,men:true};
 await f.db.query('INSERT INTO user_contacts(owner_id,contact_id,filter_override) VALUES($1,$2,$3)',[f.recipient,f.sender,override]);
 await f.db.query('INSERT INTO filter_pin_settings(user_id,pin_hash,recovery_email) VALUES($1,$2,$3)',[f.recipient,'unused-test-hash','test@example.test']);
 const res=await f.accept(first.body.id,policy.normalizeContentFilter(override));
 assert.equal(res.code,200,JSON.stringify(res.body));
 assert.deepEqual((await f.db.query('SELECT filter_override FROM user_contacts WHERE owner_id=$1 AND contact_id=$2',[f.recipient,f.sender])).rows[0].filter_override,override);
});
test('opening the code permits choosing a different filter during approval', opts, async t => {
 const f=await fixture(t);
 const first=await f.call('/api/messages',await f.payload('text'));
 await f.db.query('INSERT INTO filter_pin_settings(user_id,pin_hash,recovery_email) VALUES($1,$2,$3)',[f.recipient,'unused-test-hash','test@example.test']);
 const key=filterPin.sessionKey({headers:{authorization:'Bearer fixture-'+f.recipient}});
 await f.db.query("INSERT INTO filter_pin_grants(user_id,session_key,generation,expires_at,screen_scope) VALUES($1,$2,1,'infinity',$3)",[f.recipient,key,'a'.repeat(32)]);
 const res=await f.accept(first.body.id,all);
 assert.equal(res.code,200,JSON.stringify(res.body));
 assert.deepEqual((await f.db.query('SELECT filter_override FROM user_contacts WHERE owner_id=$1 AND contact_id=$2',[f.recipient,f.sender])).rows[0].filter_override,all);
});
