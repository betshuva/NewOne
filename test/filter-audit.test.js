'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const {randomUUID}=require('node:crypto');
const {Client,Pool}=require('pg');
const {initializeFilterAudit,recordFilterEvent,registerFilterAuditRoutes,recordFilterDecision}=require('../server/filter-audit');
const {DEFAULT_CONTENT_FILTER:ALL}=require('../server/content-filter-policy');
const dbOptions={skip:process.env.RUN_DB_TESTS!=='1'};

async function fixture(t) {
  const config={connectionString:process.env.DATABASE_URL,
    ssl:process.env.DB_SSL==='true'?{rejectUnauthorized:process.env.DB_REJECT_UNAUTHORIZED!=='false'}:false};
  const owner=new Client(config);
  await owner.connect();
  const schema=`filter_audit_test_${randomUUID().replaceAll('-','')}`;
  await owner.query(`CREATE SCHEMA "${schema}"`);
  const pool=new Pool({...config,options:`-c search_path=${schema},public`,max:3});
  t.after(async()=>{await pool.end();await owner.query(`DROP SCHEMA "${schema}" CASCADE`);await owner.end();});
  await pool.query(`CREATE TABLE users(id uuid PRIMARY KEY,name text,content_filter jsonb);
    CREATE TABLE groups(id uuid PRIMARY KEY,creator_id uuid,content_filter jsonb);
    CREATE TABLE user_contacts(owner_id uuid,contact_id uuid,filter_override jsonb);
    CREATE TABLE group_members(group_id uuid,user_id uuid,status text,joined_at timestamptz DEFAULT now(),filter_override jsonb);
    CREATE TABLE stored_files(id uuid PRIMARY KEY,user_id uuid,public_url text UNIQUE,file_type text,
      context_type text,context_id uuid,moderation_status text,moderation_details jsonb);
    CREATE TABLE messages(id uuid PRIMARY KEY,sender_id uuid,recipient_id uuid,group_id uuid,type text,
      file_url text,delivery_summary jsonb,created_at timestamptz DEFAULT now(),
      deleted_for_everyone bool DEFAULT false,deleted_for_sender bool DEFAULT false);
    CREATE TABLE message_user_deletions(message_id uuid,user_id uuid);
    CREATE TABLE conversation_user_state(user_id uuid,kind text,target_id uuid,cleared_at timestamptz);`);
  await pool.query(fs.readFileSync(require.resolve('../server/scoped-content-filter.sql'),'utf8'));
  const sender=randomUUID(),receiver=randomUUID(),outsider=randomUUID();
  await pool.query('INSERT INTO users VALUES($1,$2,$3),($4,$5,$3),($6,$7,$3)',
    [sender,'Sender',JSON.stringify(ALL),receiver,'Receiver',outsider,'Outsider']);
  await pool.query('INSERT INTO user_contacts VALUES($1,$2,$3)',[receiver,sender,JSON.stringify(ALL)]);
  await initializeFilterAudit(pool);
  const events=async(kind)=> (await pool.query('SELECT * FROM filter_audit_events WHERE kind=$1 ORDER BY id',[kind])).rows;
  const routes={};
  const auth=(_req,_res,next)=>next();
  const adminAuth=auth;
  registerFilterAuditRoutes({get:(path,...handlers)=>{routes[path]=handlers;},
    post:(path,...handlers)=>{routes[path]=handlers;}},{auth,adminAuth,getPool:async()=>pool});
  const call=async(path,{body={},query={},userId=receiver}={})=>{
    const res={statusCode:200,headers:{},status(code){this.statusCode=code;return this;},
      set(key,value){this.headers[key]=value;return this;},json(value){this.body=value;return this;}};
    await routes[path].at(-1)({body,query,user:{id:userId}},res);
    return res;
  };
  const image=async({groupId=null,classification={category:'men',detectedCategories:['men'],uncertain:false}}={})=>{
    const id=randomUUID(),fileId=randomUUID(),url=`/test/${fileId}`;
    await pool.query('INSERT INTO stored_files VALUES($1,$2,$3,$4,$5,$6,$7,$8)',
      [fileId,sender,url,'image',groupId?'group':'chat',groupId||receiver,'approved',JSON.stringify({classification,rawOutput:'private scanner diagnostics'})]);
    await pool.query('INSERT INTO messages(id,sender_id,recipient_id,group_id,type,file_url) VALUES($1,$2,$3,$4,$5,$6)',
      [id,sender,groupId?null:receiver,groupId,'image',url]);
    return {id,fileId,url};
  };
  return {pool,sender,receiver,outsider,events,image,call,routes,auth,adminAuth};
}

test('audit initializer is idempotent and labels existing state as installation baseline',dbOptions,async t=>{
 const f=await fixture(t);
 const before=await f.events('filter_baseline');
 assert.equal(before.length,4);
 assert.ok(before.every(row=>row.details.source==='installation_baseline'));
 await initializeFilterAudit(f.pool);
 assert.equal((await f.events('filter_baseline')).length,4);
 assert.equal((await f.pool.query("SELECT * FROM filter_audit_metadata WHERE key='recording_started'")).rows.length,1);
});

test('policy changes and audit are atomic, preserve actor and avoid no-op history',dbOptions,async t=>{
 const f=await fixture(t),db=await f.pool.connect();
 try {
  await db.query('BEGIN');
  await db.query("SELECT set_config('app.actor_id',$1,true)",[f.receiver]);
  await db.query('UPDATE users SET content_filter=$1 WHERE id=$2',[{...ALL,men:false,enforceGeneralFilter:true},f.receiver]);
  let rows=(await db.query("SELECT * FROM filter_audit_events WHERE kind='filter_changed'")).rows;
  assert.equal(rows.length,1);assert.equal(rows[0].actor_id,f.receiver);
  assert.equal(rows[0].details.before.men,true);assert.equal(rows[0].details.after.men,false);
  await db.query('ROLLBACK');
  assert.equal((await f.events('filter_changed')).length,0);
  assert.equal((await f.pool.query('SELECT content_filter FROM users WHERE id=$1',[f.receiver])).rows[0].content_filter.men,true);
  await db.query('UPDATE users SET content_filter=content_filter WHERE id=$1',[f.receiver]);
  assert.equal((await f.events('filter_changed')).length,0);
 } finally {db.release();}
});

test('image persistence stores effective policy and immutable classification/revision snapshot',dbOptions,async t=>{
 const f=await fixture(t);
 await f.pool.query('UPDATE users SET content_filter=$1 WHERE id=$2',[{...ALL,men:false,enforceGeneralFilter:true},f.receiver]);
 const change=(await f.events('filter_changed'))[0];
 const image=await f.image();
 const persisted=(await f.events('delivery_persisted'))[0];
 assert.equal(persisted.user_id,f.receiver);assert.equal(persisted.message_id,image.id);assert.equal(persisted.file_id,image.fileId);
 assert.equal(persisted.details.policy.men,false);assert.equal(persisted.details.scopedFilter.men,true);
 assert.ok(persisted.details.revisionIds.includes(change.id));
 assert.equal(persisted.details.snapshotMoment,'persistence');assert.equal(persisted.details.provesDisplay,false);
 assert.deepEqual(persisted.details.classification,{category:'men',detectedCategories:['men'],uncertain:false});
 await f.pool.query('UPDATE users SET content_filter=$1 WHERE id=$2',[ALL,f.receiver]);
 await f.pool.query('UPDATE stored_files SET moderation_details=$1 WHERE id=$2',[{classification:{category:'women',detectedCategories:['women']}},image.fileId]);
 const original=(await f.events('delivery_persisted'))[0];
 assert.equal(original.details.policy.men,false);assert.equal(original.details.classification.category,'men');
 const scan=(await f.events('image_classified')).at(-1);
 assert.equal(scan.details.classification.category,'women');assert.equal(scan.details.rawOutput,undefined);
 await assert.rejects(f.pool.query('UPDATE filter_audit_events SET details=$1 WHERE id=$2',[{},persisted.id]),/append-only/);
 await assert.rejects(f.pool.query('DELETE FROM filter_audit_events WHERE id=$1',[persisted.id]),/append-only/);
});

test('separate delivery and preference transactions serialize exact policy snapshots',dbOptions,async t=>{
 const f=await fixture(t),change=await f.pool.connect(),delivery=await f.pool.connect();
 const firstId=randomUUID(),secondId=randomUUID(),fileId=randomUUID(),url=`/test/${fileId}`;
 await f.pool.query('INSERT INTO stored_files VALUES($1,$2,$3,$4,$5,$6,$7,$8)',
  [fileId,f.sender,url,'image','chat',f.receiver,'approved',{classification:{category:'men',detectedCategories:['men']}}]);
 const waitForLock=async client=>{
  const pid=client.processID;
  for(let attempt=0;attempt<100;attempt++) {
   const row=(await f.pool.query('SELECT wait_event_type FROM pg_stat_activity WHERE pid=$1',[pid])).rows[0];
   if(row?.wait_event_type==='Lock') return;
   await new Promise(resolve=>setTimeout(resolve,10));
  }
  assert.fail('Expected transaction to wait on the viewer policy lock');
 };
 const insert=id=>delivery.query('INSERT INTO messages(id,sender_id,recipient_id,type,file_url) VALUES($1,$2,$3,$4,$5)',
  [id,f.sender,f.receiver,'image',url]);
 try {
  await change.query('BEGIN');
  await change.query('SELECT id FROM users WHERE id=$1 FOR UPDATE',[f.receiver]);
  await change.query('UPDATE users SET content_filter=$1 WHERE id=$2',[{...ALL,men:false,enforceGeneralFilter:true},f.receiver]);
  await delivery.query('BEGIN');
  const pendingInsert=insert(firstId);
  await waitForLock(delivery);
  await change.query('COMMIT');
  await pendingInsert;await delivery.query('COMMIT');
  let rows=await f.events('delivery_persisted');
  assert.equal(rows[0].details.policy.men,false);
  assert.ok(rows[0].details.revisionIds.includes((await f.events('filter_changed'))[0].id));

  await delivery.query('BEGIN');await insert(secondId);
  await change.query('BEGIN');
  const pendingUpdate=change.query('UPDATE users SET content_filter=$1 WHERE id=$2',[ALL,f.receiver]);
  await waitForLock(change);
  await delivery.query('COMMIT');await pendingUpdate;await change.query('COMMIT');
  rows=await f.events('delivery_persisted');
  assert.equal(rows[1].details.policy.men,false);
  assert.equal((await f.pool.query('SELECT content_filter FROM users WHERE id=$1',[f.receiver])).rows[0].content_filter.men,true);
 } finally {
  await change.query('ROLLBACK');await delivery.query('ROLLBACK');change.release();delivery.release();
 }
});

test('group delivery auditing follows persisted recipient outcome and includes member policy',dbOptions,async t=>{
 const f=await fixture(t),groupId=randomUUID();
 await f.pool.query('INSERT INTO groups VALUES($1,$2,$3)',[groupId,f.sender,ALL]);
 await f.pool.query("INSERT INTO group_members(group_id,user_id,status,filter_override) VALUES($1,$2,'member',$4),($1,$3,'member',$5)",
  [groupId,f.receiver,f.outsider,ALL,{...ALL,men:false}]);
 const image=await f.image({groupId});
 assert.equal((await f.events('delivery_persisted')).length,0);
 await f.pool.query('UPDATE messages SET delivery_summary=$1 WHERE id=$2',
  [{deliveredTo:[{id:f.receiver}],blockedFor:[{id:f.outsider}]},image.id]);
 const delivered=await f.events('delivery_persisted'),blocked=await f.events('delivery_blocked_persisted');
 assert.equal(delivered.length,1);assert.equal(delivered[0].user_id,f.receiver);
 assert.equal(blocked.length,1);assert.equal(blocked[0].user_id,f.outsider);assert.equal(blocked[0].details.policy.men,false);
 await f.pool.query('UPDATE groups SET content_filter=$1 WHERE id=$2',[{...ALL,women:false},groupId]);
 const changes=await f.events('filter_changed');
 assert.equal(changes.length,3);assert.ok(changes.every(row=>row.details.level==='group'));
});

test('group persistence snapshots immutable group gate independently from recipient permission',dbOptions,async t=>{
 const f=await fixture(t),groupId=randomUUID();
 await f.pool.query('INSERT INTO groups VALUES($1,$2,$3)',[groupId,f.sender,ALL]);
 await f.pool.query("INSERT INTO group_members(group_id,user_id,status,filter_override) VALUES($1,$2,'member',$3)",
  [groupId,f.receiver,ALL]);
 const first=await f.image({groupId});
 const summary={deliveredTo:[{id:f.receiver}],blockedFor:[]};
 await f.pool.query('UPDATE messages SET delivery_summary=$1 WHERE id=$2',[summary,first.id]);
 assert.equal((await f.events('delivery_persisted'))[0].details.groupPolicy.men,true);
 await f.pool.query('UPDATE groups SET content_filter=$1 WHERE id=$2',[{...ALL,men:false},groupId]);
 const second=await f.image({groupId});
 // Simulate a plan checked before the group restriction was committed.
 await f.pool.query('UPDATE messages SET delivery_summary=$1 WHERE id=$2',[summary,second.id]);
 let rows=await f.events('delivery_persisted');
 assert.equal(rows[1].details.policy.men,true);
 assert.equal(rows[1].details.groupPolicy.men,false);
 const groupChange=(await f.events('filter_changed')).find(row=>row.user_id===f.sender);
 assert.ok(rows[1].details.groupPolicyRevisionIds.includes(groupChange.id));
 await f.pool.query('UPDATE groups SET content_filter=$1 WHERE id=$2',[ALL,groupId]);
 rows=await f.events('delivery_persisted');
 assert.equal(rows[0].details.groupPolicy.men,true);
 assert.equal(rows[1].details.groupPolicy.men,false);
});

test('display telemetry validates real access, deduplicates and labels client claims',dbOptions,async t=>{
 const f=await fixture(t),image=await f.image();
 let response=await f.call('/api/filter-display-events',{userId:f.outsider,body:{messageId:image.id,event:'displayed'}});
 assert.equal(response.statusCode,404);
 response=await f.call('/api/filter-display-events',{body:{messageId:randomUUID(),event:'hidden'}});
 assert.equal(response.statusCode,404);
 response=await f.call('/api/filter-display-events',{body:{messageId:image.id,event:'displayed',clientTime:'2026-09-16T22:31:54Z',policyRevision:'17'}});
 assert.equal(response.statusCode,201);assert.equal(response.body.recorded,true);
 let rows=await f.events('client_displayed');
 assert.equal(rows.length,1);assert.equal(rows[0].details.source,'client_report');assert.equal(rows[0].details.provesDisplay,false);
 assert.equal(rows[0].details.reportedPolicyRevision,'17');
 response=await f.call('/api/filter-display-events',{body:{messageId:image.id,event:'displayed',policyRevision:'17'}});
 assert.equal(response.statusCode,202);assert.equal(response.body.reason,'duplicate');
 response=await f.call('/api/filter-display-events',{body:{messageId:image.id,event:'hidden',policyRevision:'18'}});
 assert.equal(response.statusCode,201);
 await f.pool.query('INSERT INTO message_user_deletions VALUES($1,$2)',[image.id,f.receiver]);
 response=await f.call('/api/filter-display-events',{body:{messageId:image.id,event:'displayed',policyRevision:'19'}});
 assert.equal(response.statusCode,404);
 assert.equal((await f.events('client_displayed')).length,1);
});

test('display dedup observes real server policy and restoration changes without a client revision',dbOptions,async t=>{
 const f=await fixture(t),image=await f.image();
 const send=()=>f.call('/api/filter-display-events',{body:{messageId:image.id,event:'displayed'}});
 assert.equal((await send()).statusCode,201);
 assert.equal((await send()).body.reason,'duplicate');
 await recordFilterEvent(f.pool,{kind:'history_image_action',userId:f.receiver,messageId:image.id,details:{action:'hide'}});
 assert.equal((await send()).statusCode,201);
 await recordFilterEvent(f.pool,{kind:'history_restored',userId:f.receiver,messageId:image.id,details:{action:'restore'}});
 assert.equal((await send()).statusCode,201);
 await f.pool.query('UPDATE users SET content_filter=$1 WHERE id=$2',[{...ALL,women:false,enforceGeneralFilter:true},f.receiver]);
 assert.equal((await send()).statusCode,201);
 const fileTimeline=await f.call('/api/admin/filter-timeline',{query:{userId:f.receiver,fileId:image.fileId}});
 assert.ok(fileTimeline.body.events.some(row=>row.kind==='history_image_action'));
 assert.ok(fileTimeline.body.events.some(row=>row.kind==='history_restored'));
 assert.ok(fileTimeline.body.events.some(row=>row.kind==='filter_changed'));
});

test('blocked decision captures the checked policy without copying file URLs or model diagnostics',dbOptions,async t=>{
 const f=await fixture(t),image=await f.image();
 const checkedPolicy={...ALL,men:false};
 const row=await recordFilterDecision(f.pool,{userId:f.receiver,actorId:f.sender,scopeType:'contact',scopeId:f.sender,
  messageType:'image',fileUrl:image.url,policy:checkedPolicy,source:'direct_http_send',
  classification:{category:'men',detectedCategories:['men'],rawOutput:'private diagnostics'}});
 assert.equal(row.file_id,image.fileId);assert.equal(row.kind,'decision_blocked');
 assert.deepEqual(row.details.policy,checkedPolicy);assert.equal(row.details.snapshotMoment,'decision');
 assert.equal(row.details.classification.rawOutput,undefined);assert.equal(row.details.fileUrl,undefined);
 const noText=await recordFilterDecision(f.pool,{messageType:'text'});assert.equal(noText,null);
});

test('group reports require active membership and messages after joining',dbOptions,async t=>{
 const f=await fixture(t),groupId=randomUUID();
 await f.pool.query('INSERT INTO groups VALUES($1,$2,$3)',[groupId,f.sender,ALL]);
 await f.pool.query("INSERT INTO group_members(group_id,user_id,status,joined_at) VALUES($1,$2,'member',clock_timestamp()-interval '1 hour')",[groupId,f.receiver]);
 const image=await f.image({groupId});
 let response=await f.call('/api/filter-display-events',{body:{messageId:image.id,event:'displayed'}});
 assert.equal(response.statusCode,201);
 await f.pool.query("UPDATE group_members SET joined_at=clock_timestamp()+interval '1 hour'");
 response=await f.call('/api/filter-display-events',{body:{messageId:image.id,event:'hidden'}});
 assert.equal(response.statusCode,404);
 await f.pool.query("UPDATE group_members SET joined_at=clock_timestamp()-interval '1 hour',status='pending'");
 response=await f.call('/api/filter-display-events',{body:{messageId:image.id,event:'hidden'}});
 assert.equal(response.statusCode,404);
});

test('display reports have a daily bound independent of supplied revision',dbOptions,async t=>{
 const f=await fixture(t),image=await f.image();
 await f.pool.query("INSERT INTO filter_audit_events(kind,user_id,details) SELECT 'client_displayed',$1,jsonb_build_object('fixture',n) FROM generate_series(1,200) n",[f.receiver]);
 const response=await f.call('/api/filter-display-events',{body:{messageId:image.id,event:'displayed',policyRevision:'invented-new-revision'}});
 assert.equal(response.statusCode,202);assert.equal(response.body.reason,'daily_limit');
 assert.equal((await f.events('client_displayed')).length,200);
});

test('admin timeline paginates without duplicates and only installs under admin middleware',dbOptions,async t=>{
 const f=await fixture(t),image=await f.image();
 assert.equal(f.routes['/api/admin/filter-timeline'][0],f.adminAuth);
 const first=await f.call('/api/admin/filter-timeline',{query:{userId:f.receiver,limit:'2'}});
 assert.equal(first.statusCode,200);assert.equal(first.body.events.length,2);assert.ok(first.body.recordingStartedAt);
 assert.equal(first.headers['Cache-Control'],'no-store');assert.ok(first.body.nextCursor);
 const second=await f.call('/api/admin/filter-timeline',{query:{userId:f.receiver,limit:'2',before:first.body.nextCursor}});
 assert.ok(second.body.events.every(row=>!first.body.events.some(other=>other.id===row.id)));
 const byFile=await f.call('/api/admin/filter-timeline',{query:{fileId:image.fileId}});
 assert.ok(byFile.body.events.some(row=>row.file_id===image.fileId));
 assert.ok(byFile.body.events.some(row=>row.kind==='filter_baseline' && row.user_id===f.receiver));
 const byMessage=await f.call('/api/admin/filter-timeline',{query:{messageId:image.id}});
 assert.ok(byMessage.body.events.some(row=>row.kind==='image_classified'));
});

test('malformed timeline and display inputs fail before database access',async()=>{
 const routes={};let calls=0;
 registerFilterAuditRoutes({get:(path,...handlers)=>routes[path]=handlers,post:(path,...handlers)=>routes[path]=handlers},
  {auth:()=>{},adminAuth:()=>{},getPool:async()=>{calls++;throw new Error('unexpected database access');}});
 for(const [path,input] of [
  ['/api/admin/filter-timeline',{query:{before:'9223372036854775808'}}],
  ['/api/admin/filter-timeline',{query:{userId:['00000000-0000-0000-0000-000000000000']}}],
  ['/api/filter-display-events',{body:{messageId:randomUUID(),event:'allowed'}}],
  ['/api/filter-display-events',{body:{messageId:randomUUID(),event:'displayed',clientTime:{}}}],
  ['/api/filter-display-events',{body:{messageId:randomUUID(),event:'displayed',policyRevision:'x'.repeat(101)}}],
 ]) {
  const res={status(code){this.code=code;return this;},json(value){this.body=value;return this;}};
  await routes[path].at(-1)(input,res);assert.equal(res.code,400);
 }
 assert.equal(calls,0);
 await assert.rejects(recordFilterEvent({}, {kind:'bad kind'}),/Invalid/);
 await assert.rejects(recordFilterEvent({}, {kind:'decision_blocked',details:{value:'a'.repeat(33000)}}),/limit/);
});
