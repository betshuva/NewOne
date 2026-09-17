'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const fs = require('node:fs');
const vm = require('node:vm');
const { Client, Pool } = require('pg');
const policy = require('../server/content-filter-policy');
const audit = require('../server/filter-audit');
const history = require('../server/filter-media-history');
const { DEFAULT_CONTENT_FILTER: ALL } = policy;
const { FILTER_MEDIA_SCHEMA, imageAffectedByTightening, prepareFilterHistoryChange,
  lockFilterOwner, projectFilteredHistory, registerFilterHistoryRoutes } = history;
const opts = { skip: process.env.RUN_DB_TESTS !== '1' };
const male = { category: 'men', detectedCategories: ['men'], uncertain: false };

test('tightening identifies mixed and unknown images but ignores unrelated changes', () => {
  assert.equal(imageAffectedByTightening(ALL,{...ALL,men:false},male),true);
  assert.equal(imageAffectedByTightening(ALL,{...ALL,women:false},male),false);
  assert.equal(imageAffectedByTightening(ALL,{...ALL,text:false},male),false);
  assert.equal(imageAffectedByTightening({...ALL,men:false},{...ALL,men:false},male),false);
  assert.equal(imageAffectedByTightening(ALL,{...ALL,children:false},null),true);
  assert.equal(imageAffectedByTightening(ALL,{...ALL,women:false},{detectedCategories:['men','women']}),true);
});

async function fixture(t) {
  const config={connectionString:process.env.DATABASE_URL,
    ssl:process.env.DB_SSL==='true'?{rejectUnauthorized:process.env.DB_REJECT_UNAUTHORIZED!=='false'}:false};
  const owner=new Client(config);await owner.connect();
  const schema='filter_history_test_'+randomUUID().replaceAll('-','');
  await owner.query(`CREATE SCHEMA "${schema}"`);
  const pool=new Pool({...config,options:`-c search_path=${schema}`,max:4});
  t.after(async()=>{await pool.end();await owner.query(`DROP SCHEMA "${schema}" CASCADE`);await owner.end();});
  await pool.query(`CREATE TABLE users(id uuid PRIMARY KEY,name text,content_filter jsonb);
    CREATE TABLE groups(id uuid PRIMARY KEY,creator_id uuid,content_filter jsonb);
    CREATE TABLE user_contacts(owner_id uuid,contact_id uuid,filter_override jsonb,filter_choice_confirmed boolean);
    CREATE TABLE group_members(group_id uuid,user_id uuid,status text,role text,joined_at timestamptz DEFAULT '2000-01-01',filter_override jsonb);
    CREATE TABLE stored_files(id uuid PRIMARY KEY,user_id uuid,public_url text UNIQUE,file_type text,
      context_type text,context_id uuid,moderation_status text,moderation_details jsonb,content_purged_at timestamptz);
    CREATE TABLE messages(id uuid PRIMARY KEY,sender_id uuid,recipient_id uuid,group_id uuid,type text,
      body text,file_url text,delivery_summary jsonb,created_at timestamptz DEFAULT clock_timestamp(),
      deleted_for_everyone boolean DEFAULT false,deleted_for_sender boolean DEFAULT false);
    CREATE TABLE message_user_deletions(message_id uuid,user_id uuid,PRIMARY KEY(message_id,user_id));
    CREATE TABLE received_message_media(message_id uuid,user_id uuid,stored_file_id uuid,status text);
    CREATE TABLE conversation_user_state(user_id uuid,kind text,target_id uuid,cleared_at timestamptz);`);
  await pool.query(fs.readFileSync(require.resolve('../server/scoped-content-filter.sql'),'utf8'));
  await pool.query(FILTER_MEDIA_SCHEMA);
  const me=randomUUID(),sender=randomUUID(),other=randomUUID(),group=randomUUID();
  await pool.query('INSERT INTO users VALUES($1,$2,$3),($4,$5,$3),($6,$7,$3)',
    [me,'Reader',{...ALL,enforceGeneralFilter:true},sender,'Sender',other,'Other']);
  await pool.query('INSERT INTO user_contacts(owner_id,contact_id,filter_override) VALUES($1,$2,$3),($1,$4,$3)',[me,sender,ALL,other]);
  await pool.query('INSERT INTO groups VALUES($1,$2,$3)',[group,sender,ALL]);
  await pool.query("INSERT INTO group_members(group_id,user_id,status,role,filter_override) VALUES($1,$2,'member','member',$5),($1,$3,'member','admin',$5),($1,$4,'member','member',$5)",[group,me,sender,other,ALL]);
  await audit.initializeFilterAudit(pool);
  const image=async({from=sender,to=me,groupId=null,classification=male}={})=>{
    const id=randomUUID(),fileId=randomUUID(),url='/test/'+fileId;
    await pool.query('INSERT INTO stored_files VALUES($1,$2,$3,$4,$5,$6,$7,$8,NULL)',
      [fileId,from,url,'image',groupId?'group':'chat',groupId||to,'approved',{classification}]);
    await pool.query("INSERT INTO messages(id,sender_id,recipient_id,group_id,type,body,file_url) VALUES($1,$2,$3,$4,'image','photo',$5)",[id,from,groupId?null:to,groupId,url]);
    return {id,fileId,url};
  };
  const project=async(user=me)=>projectFilteredHistory(pool,user,(await pool.query('SELECT * FROM messages ORDER BY created_at')).rows);
  const save=async(next,action,scope={kind:'general'})=>{
    const db=await pool.connect();
    try {
      await db.query('BEGIN');await lockFilterOwner(db,me);
      const change=await prepareFilterHistoryChange(db,me,scope,next,action);
      if(scope.kind==='general') await db.query('UPDATE users SET content_filter=$1 WHERE id=$2',[next,me]);
      else if(scope.kind==='contact') await db.query('UPDATE user_contacts SET filter_override=$1 WHERE owner_id=$2 AND contact_id=$3',[next,me,scope.id]);
      else await db.query('UPDATE group_members SET filter_override=$1 WHERE user_id=$2 AND group_id=$3',[next,me,scope.id]);
      await db.query('COMMIT');return change;
    } catch(e){await db.query('ROLLBACK');throw e;}finally{db.release();}
  };
  return {pool,me,sender,other,group,image,project,save};
}

test('choice is mandatory and cancellation changes neither settings nor audit',opts,async t=>{
 const f=await fixture(t);await f.image();
 await assert.rejects(f.save({...ALL,men:false,enforceGeneralFilter:true}),e=>e.code==='EXISTING_MEDIA_CHOICE_REQUIRED'&&e.affectedCount===1);
 assert.equal((await f.pool.query('SELECT content_filter FROM users WHERE id=$1',[f.me])).rows[0].content_filter.men,true);
 assert.equal((await f.pool.query("SELECT * FROM filter_audit_events WHERE kind IN ('filter_changed','history_action')")).rows.length,0);
 assert.equal((await f.pool.query('SELECT * FROM user_message_filter_actions')).rows.length,0);
});

test('keep applies to exact existing sent and received IDs while newer images remain blocked',opts,async t=>{
 const f=await fixture(t),old=await f.image(),oldOwn=await f.image({from:f.me,to:f.sender});
 await f.save({...ALL,men:false,enforceGeneralFilter:true},'keep');
 const fresh=await f.image(),own=await f.image({from:f.me,to:f.sender});
 const rows=await f.project();
 assert.equal(rows.find(r=>r.id===old.id).file_url,old.url);
 assert.equal(rows.find(r=>r.id===old.id).filter_kept,true);
 assert.equal(rows.find(r=>r.id===fresh.id).filter_hidden,true);
 assert.equal(rows.find(r=>r.id===fresh.id).file_url,null);
 assert.equal(rows.find(r=>r.id===own.id).file_url,null);
 assert.equal(rows.find(r=>r.id===oldOwn.id).file_url,oldOwn.url);
 assert.equal(rows.find(r=>r.id===oldOwn.id).filter_kept,true);
 const events=(await f.pool.query("SELECT * FROM filter_audit_events WHERE kind='history_image_action'")).rows;
 assert.deepEqual(new Set(events.map(e=>e.message_id)),new Set([old.id,oldOwn.id]));
 assert.ok(events.every(e=>e.details.action==='keep'));
});

test('hide persists per reader, restore requires access, and deleted images cannot be restored',opts,async t=>{
 const f=await fixture(t),image=await f.image();
 await f.save({...ALL,men:false,enforceGeneralFilter:true},'hide');
 assert.equal((await f.project())[0].file_url,null);
 assert.equal((await f.project(f.sender))[0].file_url,image.url);
 const routes={};const notify=[];
 registerFilterHistoryRoutes({post:(path,...handlers)=>routes[path]=handlers.at(-1)},
   {auth:()=>{},getPool:async()=>f.pool,notifyUser:(...args)=>notify.push(args)});
 const restore=async(user)=>{
   const res={statusCode:200,status(n){this.statusCode=n;return this;},json(data){this.data=data;return this;}};
   await routes['/api/messages/:messageId/filter-visibility']({params:{messageId:image.id},body:{action:'restore'},user:{id:user}},res);return res;
 };
 assert.equal((await restore(f.other)).statusCode,404);
 assert.equal((await restore(f.me)).statusCode,200);
 assert.equal((await f.project())[0].file_url,image.url);
 assert.equal(notify[0][0],f.me);
 await f.pool.query('INSERT INTO message_user_deletions VALUES($1,$2)',[image.id,f.me]);
 assert.equal((await restore(f.me)).statusCode,404);
});

test('delete affects only recipient ledger and cancels queued personal copies',opts,async t=>{
 const f=await fixture(t),image=await f.image();
 await f.pool.query("INSERT INTO received_message_media VALUES($1,$2,NULL,'queued')",[image.id,f.me]);
 await f.save({...ALL,men:false,enforceGeneralFilter:true},'delete');
 assert.equal((await f.project()).length,0);
 assert.equal((await f.project(f.sender))[0].file_url,image.url);
 assert.equal((await f.pool.query('SELECT status FROM received_message_media')).rows[0].status,'skipped');
 assert.equal((await f.pool.query('SELECT deleted_for_everyone FROM messages')).rows[0].deleted_for_everyone,false);
});

test('contact choice is scoped and enabling general enforcement prompts for affected overrides',opts,async t=>{
 const f=await fixture(t),a=await f.image(),b=await f.image({from:f.other});
 await f.save({...ALL,men:false},'hide',{kind:'contact',id:f.sender});
 let rows=await f.project();assert.equal(rows.find(r=>r.id===a.id).file_url,null);assert.equal(rows.find(r=>r.id===b.id).file_url,b.url);
 await f.pool.query('UPDATE users SET content_filter=$1 WHERE id=$2',[{...ALL,men:false,enforceGeneralFilter:false},f.me]);
 await assert.rejects(f.save({...ALL,men:false,enforceGeneralFilter:true}),e=>e.code==='EXISTING_MEDIA_CHOICE_REQUIRED'&&e.affectedCount===1);
});

test('group member selection leaves other members visible and excludes pre-join history',opts,async t=>{
 const f=await fixture(t),image=await f.image({groupId:f.group});
 await f.save({...ALL,men:false},'hide',{kind:'group_personal',id:f.group});
 assert.equal((await f.project())[0].file_url,null);
 assert.equal((await f.project(f.other))[0].file_url,image.url);
 await f.pool.query('UPDATE group_members SET joined_at=clock_timestamp() WHERE group_id=$1 AND user_id=$2',[f.group,f.me]);
 await f.pool.query('UPDATE group_members SET filter_override=$1 WHERE group_id=$2 AND user_id=$3',[ALL,f.group,f.me]);
 assert.equal((await f.save({...ALL,men:false},undefined,{kind:'group_personal',id:f.group})).affectedCount,0);
});

test('actual general PUT returns 409 without writing and preserves boolean response contract after keep',opts,async t=>{
 const f=await fixture(t);await f.image();
 const source=fs.readFileSync(require.resolve('../server/index.js'),'utf8');
 const start=source.indexOf("app.put('/api/filter-settings',");
 const end=source.indexOf("\napp.get('/api/contacts/:userId/filter-settings'",start);
 let handler;
 const context={...policy,...history,app:{put:(_path,...handlers)=>handler=handlers.at(-1)},
   authWithDbCheck:()=>{},getPool:async()=>f.pool,relay:()=>{},deleteOwnMedia:async()=>({}),console};
 vm.runInNewContext(source.slice(start,end),context);
 const call=async(body)=>{const res={statusCode:200,status(n){this.statusCode=n;return this;},json(data){this.data=data;return this;}};
   await handler({user:{id:f.me},body},res);return res;};
 const response=await call({...ALL,men:false,enforceGeneralFilter:true});assert.equal(response.statusCode,409);assert.equal(response.data.affectedCount,1);
 const saved=await call({...ALL,men:false,enforceGeneralFilter:true,existingMediaAction:'keep'});
 assert.equal(saved.statusCode,200);assert.equal(saved.data.men,false);assert.equal(saved.data.enforceGeneralFilter,true);
 assert.ok(Object.values(saved.data).every(v=>typeof v==='boolean'));
});


test('received library copies obey image decisions while ordinary clearing preserves allowed files',opts,async t=>{
 const f=await fixture(t),image=await f.image(),copy=randomUUID();
 await f.pool.query('INSERT INTO stored_files VALUES($1,$2,$3,$4,$5,NULL,$6,$7,NULL)',
   [copy,f.me,'/copy/'+copy,'image','received','approved',{classification:male}]);
 await f.pool.query("INSERT INTO received_message_media VALUES($1,$2,$3,'ready')",[image.id,f.me,copy]);
 const items=[{id:copy,file_type:'image',public_url:'/copy/'+copy}];
 let result=await history.projectFilterMediaLibrary(f.pool,f.me,items);
 assert.equal(result[0].public_url,items[0].public_url);
 await f.pool.query('INSERT INTO message_user_deletions VALUES($1,$2)',[image.id,f.me]);
 result=await history.projectFilterMediaLibrary(f.pool,f.me,items);
 assert.equal(result[0].public_url,items[0].public_url);
 await f.pool.query('DELETE FROM message_user_deletions');
 await f.save({...ALL,men:false,enforceGeneralFilter:true},'hide');
 result=await history.projectFilterMediaLibrary(f.pool,f.me,items);
 assert.equal(result[0].public_url,null);assert.equal(result[0].filter_hidden,true);
 await f.pool.query("UPDATE user_message_filter_actions SET action='keep'");
 result=await history.projectFilterMediaLibrary(f.pool,f.me,items);
 assert.equal(result[0].public_url,items[0].public_url);
});

test('grouped library copies retain visibility from any member and hide when every message is hidden',opts,async t=>{
 const f=await fixture(t),first=await f.image({from:f.me,to:f.sender}),second=await f.image({from:f.me,to:f.other});
 const items=[{id:first.fileId,duplicate_ids:[first.fileId,second.fileId],file_type:'image',public_url:first.url}];
 await f.save({...ALL,men:false,enforceGeneralFilter:true},'hide');
 let result=await history.projectFilterMediaLibrary(f.pool,f.me,items);
 assert.equal(result[0].filter_hidden,true);assert.equal(result[0].public_url,null);
 await f.pool.query("UPDATE user_message_filter_actions SET action='keep' WHERE user_id=$1 AND message_id=$2",[f.me,second.id]);
 result=await history.projectFilterMediaLibrary(f.pool,f.me,items);
 assert.equal(result[0].filter_hidden,false);assert.equal(result[0].public_url,first.url);
 assert.equal(result[0].filter_source_message_id,second.id);
 await f.pool.query("UPDATE user_message_filter_actions SET action='hide' WHERE user_id=$1",[f.me]);
 result=await history.projectFilterMediaLibrary(f.pool,f.me,items);
 assert.equal(result[0].public_url,null);
});

test('actual group-wide save asks only the acting member and records settings plus notice atomically',opts,async t=>{
 const f=await fixture(t);await f.image({groupId:f.group});
 await f.pool.query("UPDATE group_members SET role='admin' WHERE user_id=$1",[f.me]);
 // Fixture's message identifier default mirrors the real messages table.
 await f.pool.query('ALTER TABLE messages ALTER COLUMN id SET DEFAULT gen_random_uuid()');
 const source=fs.readFileSync(require.resolve('../server/index.js'),'utf8');
 const start=source.indexOf("app.put('/api/groups/:id/filter-settings',");
 const end=source.indexOf("app.put('/api/groups/:id/personal-filter',",start);
 let handler;
 const context={...policy,...history,app:{put:(_path,...handlers)=>handler=handlers.at(-1)},
   auth:()=>{},getPool:async()=>f.pool,relay:()=>{},deleteOwnMedia:async()=>({}),console,
   getGroupContentFilter:async(db,groupId)=>{
     const r=(await db.query('SELECT u.content_filter AS general,g.content_filter FROM groups g JOIN users u ON u.id=g.creator_id WHERE g.id=$1',[groupId])).rows[0];
     return policy.resolveScopedContentFilter(r.general,r.content_filter);
   }};
 vm.runInNewContext(source.slice(start,end),context);
 const call=async(body)=>{const res={statusCode:200,status(n){this.statusCode=n;return this;},json(data){this.data=data;return this;}};
   await handler({user:{id:f.me},params:{id:f.group},body},res);return res;};
 let res=await call({filter:{...ALL,men:false}});assert.equal(res.statusCode,409);
 assert.equal((await f.pool.query('SELECT content_filter FROM groups')).rows[0].content_filter.men,true);
 res=await call({filter:{...ALL,men:false},existingMediaAction:'hide'});assert.equal(res.statusCode,200);
 assert.equal(res.data.filter.men,false);
 assert.equal((await f.pool.query('SELECT * FROM user_message_filter_actions')).rows[0].user_id,f.me);
 assert.equal((await f.pool.query("SELECT * FROM messages WHERE type='text'")).rows.length,1);
});


test('in-flight group delivery denied by the persisted group policy stays hidden on history reload',opts,async t=>{
 const f=await fixture(t),image=await f.image({groupId:f.group});
 await f.pool.query('UPDATE groups SET content_filter=$1 WHERE id=$2',[{...ALL,men:false},f.group]);
 await f.pool.query('UPDATE messages SET delivery_summary=$1 WHERE id=$2',
   [{deliveredTo:[{id:f.me}],blockedFor:[]},image.id]);
 await f.pool.query('UPDATE groups SET content_filter=$1 WHERE id=$2',[ALL,f.group]);
 const rows=await f.project();assert.equal(rows[0].file_url,null);assert.equal(rows[0].filter_hidden,true);
});


test('approved retained copy remains available after sender source removal, and keeps its classification',opts,async t=>{
 const f=await fixture(t),image=await f.image(),copy=randomUUID();
 await f.pool.query('INSERT INTO stored_files VALUES($1,$2,$3,$4,$5,NULL,$6,$7,NULL)',
   [copy,f.me,'/copy/'+copy,'image','received','approved',{classification:male}]);
 await f.pool.query("INSERT INTO received_message_media VALUES($1,$2,$3,'ready')",[image.id,f.me,copy]);
 await f.pool.query('DELETE FROM stored_files WHERE id=$1',[image.fileId]);
 assert.equal((await f.project())[0].filter_hidden,false);
 await f.pool.query('UPDATE users SET content_filter=$1 WHERE id=$2',[{...ALL,men:false,enforceGeneralFilter:true},f.me]);
 assert.equal((await f.project())[0].filter_hidden,true);
});


test('already blocked own images prompt once on unchanged save, and explicit hide replaces keep',opts,async t=>{
 const f=await fixture(t),image=await f.image({from:f.me,to:f.sender});
 const blocked={...ALL,men:false,enforceGeneralFilter:true};
 await f.pool.query('UPDATE users SET content_filter=$1 WHERE id=$2',[blocked,f.me]);
 assert.equal((await f.project())[0].file_url,null);
 await assert.rejects(f.save(blocked),e=>e.code==='EXISTING_MEDIA_CHOICE_REQUIRED'&&e.affectedCount===1);
 assert.equal((await f.save(blocked,'keep')).affectedCount,1);
 assert.equal((await f.save(blocked)).affectedCount,0);
 assert.equal((await f.project())[0].file_url,image.url);
 assert.equal((await f.save(blocked,'hide')).affectedCount,1);
 assert.equal((await f.project())[0].file_url,null);
 assert.equal((await f.project(f.sender))[0].file_url,image.url);
 assert.equal((await f.save(blocked)).affectedCount,0);
});

test('contact actions include own messages to that contact and never change recipient history',opts,async t=>{
 const f=await fixture(t),own=await f.image({from:f.me,to:f.sender}),other=await f.image({from:f.me,to:f.other});
 const incoming=await f.image();
 const change=await f.save({...ALL,men:false},'delete',{kind:'contact',id:f.sender});
 assert.equal(change.affectedCount,2);assert.deepEqual(change.fileIds,[own.fileId]);
 const mine=await f.project();assert.equal(mine.some(r=>r.id===own.id),false);assert.equal(mine.some(r=>r.id===incoming.id),false);
 assert.equal(mine.find(r=>r.id===other.id).file_url,other.url);
 assert.equal((await f.project(f.sender)).find(r=>r.id===own.id).file_url,own.url);
 assert.equal((await f.pool.query('SELECT deleted_for_everyone FROM messages WHERE id=$1',[own.id])).rows[0].deleted_for_everyone,false);
 const ids=[];const result=await history.finishFilterHistoryChange(f.pool,f.me,change,async(_pool,user,id)=>{
   assert.equal(user,f.me);ids.push(id);throw Object.assign(new Error('still shared'),{code:'MEDIA_IN_USE'});
 });
 assert.deepEqual(ids,[own.fileId]);assert.equal(result.retainedSharedFiles,1);
});

test('own group images obey personal member choices without changing another member',opts,async t=>{
 const f=await fixture(t),own=await f.image({from:f.me,groupId:f.group});
 const change=await f.save({...ALL,men:false},'hide',{kind:'group_personal',id:f.group});
 assert.equal(change.affectedCount,1);
 assert.equal((await f.project())[0].file_url,null);
 assert.equal((await f.project(f.other))[0].file_url,own.url);
});

test('own hidden image restore uses contact counterpart and still rejects unsafe files',opts,async t=>{
 const f=await fixture(t),image=await f.image({from:f.me,to:f.sender});
 await f.save({...ALL,men:false,enforceGeneralFilter:true},'hide');
 const routes={},notifications=[];
 registerFilterHistoryRoutes({post:(path,...handlers)=>routes[path]=handlers.at(-1)},
   {auth:()=>{},getPool:async()=>f.pool,notifyUser:(...args)=>notifications.push(args)});
 const restore=async()=>{const res={statusCode:200,status(n){this.statusCode=n;return this;},json(data){this.data=data;return this;}};
   await routes['/api/messages/:messageId/filter-visibility']({params:{messageId:image.id},body:{action:'restore'},user:{id:f.me}},res);return res;};
 assert.equal((await restore()).statusCode,200);
 assert.equal(notifications[0][2].targetId,f.sender);
 assert.equal((await f.project())[0].file_url,image.url);
 const event=(await f.pool.query("SELECT scope_id FROM filter_audit_events WHERE kind='history_restored'")).rows[0];
 assert.equal(event.scope_id,f.sender);
 await f.pool.query("UPDATE stored_files SET moderation_status='rejected' WHERE id=$1",[image.fileId]);
 assert.equal((await restore()).statusCode,404);
 assert.equal((await f.project())[0].file_url,null);
});

test('owned originals and unsent library images obey current policy, exact keeps, and moderation',opts,async t=>{
 const f=await fixture(t),image=await f.image({from:f.me,to:f.sender}),unsent=randomUUID();
 await f.pool.query('INSERT INTO stored_files VALUES($1,$2,$3,$4,$5,NULL,$6,$7,NULL)',
   [unsent,f.me,'/unsent/'+unsent,'image','general','approved',{classification:male}]);
 const items=[{id:image.fileId,file_type:'image',public_url:image.url},
   {id:unsent,file_type:'image',public_url:'/unsent/'+unsent}];
 let rows=await history.projectFilterMediaLibrary(f.pool,f.me,items);
 assert.equal(rows[0].public_url,image.url);assert.equal(rows[1].public_url,items[1].public_url);
 await f.save({...ALL,men:false,enforceGeneralFilter:true},'keep');
 rows=await history.projectFilterMediaLibrary(f.pool,f.me,items);
 assert.equal(rows[0].public_url,image.url);assert.equal(rows[1].public_url,null);
 await f.save({...ALL,men:false,enforceGeneralFilter:true},'hide');
 rows=await history.projectFilterMediaLibrary(f.pool,f.me,items);assert.ok(rows.every(r=>r.public_url===null));
 await f.pool.query('UPDATE users SET content_filter=$1 WHERE id=$2',[ALL,f.me]);
 await f.pool.query("UPDATE stored_files SET moderation_status='pending' WHERE id=$1",[unsent]);
 rows=await history.projectFilterMediaLibrary(f.pool,f.me,items);assert.equal(rows[1].public_url,null);
});

test('own library originals survive ordinary conversation clearing but never filter deletion',opts,async t=>{
 const f=await fixture(t),image=await f.image({from:f.me,to:f.sender});
 const items=[{id:image.fileId,file_type:'image',public_url:image.url}];
 await f.pool.query('INSERT INTO message_user_deletions VALUES($1,$2)',[image.id,f.me]);
 let rows=await history.projectFilterMediaLibrary(f.pool,f.me,items);assert.equal(rows[0].public_url,image.url);
 await f.pool.query("INSERT INTO user_message_filter_actions(user_id,message_id,action) VALUES($1,$2,'delete')",[f.me,image.id]);
 rows=await history.projectFilterMediaLibrary(f.pool,f.me,items);assert.equal(rows[0].public_url,null);
});

test('synthetic own scans never reveal pending media and apply contact policy after approval',opts,async t=>{
 const f=await fixture(t),image=await f.image({from:f.me,to:f.sender});
 const input=[{id:'scan_'+image.fileId,sender_id:f.me,recipient_id:f.sender,type:'image',file_url:image.url,blocked_preview_url:'/blocked/private'}];
 await f.pool.query("UPDATE stored_files SET moderation_status='pending' WHERE id=$1",[image.fileId]);
 let rows=await history.projectOwnScans(f.pool,f.me,input,{contextType:'chat',contextId:f.sender});
 assert.equal(rows[0].file_url,null);assert.equal(rows[0].blocked_preview_url,null);assert.equal(rows[0].hidden_reason,'moderation');
 await f.pool.query("UPDATE stored_files SET moderation_status='approved' WHERE id=$1",[image.fileId]);
 await f.pool.query('UPDATE user_contacts SET filter_override=$1 WHERE owner_id=$2 AND contact_id=$3',[{...ALL,men:false},f.me,f.sender]);
 rows=await history.projectOwnScans(f.pool,f.me,input,{contextType:'chat',contextId:f.sender});
 assert.equal(rows[0].file_url,null);assert.equal(rows[0].hidden_reason,'content_filter');
 rows=await history.projectOwnScans(f.pool,f.me,input,{contextType:'chat',contextId:f.other});
 assert.equal(rows[0].file_url,image.url);
});

test('retained received copy can be restored after original removal without allowing rejected originals',opts,async t=>{
 const f=await fixture(t),image=await f.image(),copy=randomUUID();
 await f.pool.query('INSERT INTO stored_files VALUES($1,$2,$3,$4,$5,NULL,$6,$7,NULL)',
   [copy,f.me,'/copy/'+copy,'image','received','approved',{classification:male}]);
 await f.pool.query("INSERT INTO received_message_media VALUES($1,$2,$3,'ready')",[image.id,f.me,copy]);
 await f.save({...ALL,men:false,enforceGeneralFilter:true},'hide');
 const routes={};registerFilterHistoryRoutes({post:(path,...handlers)=>routes[path]=handlers.at(-1)},
   {auth:()=>{},getPool:async()=>f.pool,notifyUser:()=>{}});
 const restore=async()=>{const res={statusCode:200,status(n){this.statusCode=n;return this;},json(data){this.data=data;return this;}};
   await routes['/api/messages/:messageId/filter-visibility']({params:{messageId:image.id},body:{action:'restore'},user:{id:f.me}},res);return res;};
 await f.pool.query("UPDATE stored_files SET moderation_status='rejected' WHERE id=$1",[image.fileId]);
 assert.equal((await restore()).statusCode,404);
 await f.pool.query('DELETE FROM stored_files WHERE id=$1',[image.fileId]);
 assert.equal((await restore()).statusCode,200);
 assert.equal((await f.project())[0].filter_hidden,false);
});

test('hidden history, own scans and library retain the true moderation state without media URLs',opts,async t=>{
 const f=await fixture(t),image=await f.image({from:f.me,to:f.sender});
 const scan={id:'scan_'+image.fileId,sender_id:f.me,recipient_id:f.sender,type:'image',
   file_url:image.url,file_name:'photo.png',message_status:'pending_scan'};
 const library={id:image.fileId,file_type:'image',public_url:image.url};
 for (const state of [
   {status:'pending',reason:'הסריקה טרם הושלמה',purged:null},
   {status:'rejected',reason:'התמונה לא אושרה בבדיקת הבטיחות',purged:null},
   {status:'approved',reason:null,purged:'2026-09-17T12:00:00.000Z'},
 ]) {
   await f.pool.query(`UPDATE stored_files SET moderation_status=$1,
     moderation_details=$2,content_purged_at=$3 WHERE id=$4`,
   [state.status,{classification:male,reason:state.reason},state.purged,image.fileId]);
   const [message]=await f.project();
   const [own]=await history.projectOwnScans(f.pool,f.me,[scan],{contextType:'chat',contextId:f.sender});
   const [item]=await history.projectFilterMediaLibrary(f.pool,f.me,[library]);
   for (const row of [message,own,item]) {
     assert.equal(row.filter_hidden,true);
     assert.equal(row.hidden_reason,'moderation');
     assert.equal(row.moderation_status,state.status);
     assert.equal(row.scan_reason,state.reason);
     assert.equal(row.content_purged_at?.toISOString() || null,state.purged);
     assert.equal(row.file_url,null);
   }
   assert.equal(own.file_name,null);
   assert.equal(item.public_url,null);
 }
 // A completed scan does not mean the user's selected content filter blocked it.
 await f.pool.query(`UPDATE stored_files SET moderation_status='approved',
   moderation_details=$1,content_purged_at=NULL WHERE id=$2`,[{classification:male},image.fileId]);
 assert.equal((await f.project())[0].filter_hidden,false);
 assert.equal((await history.projectOwnScans(f.pool,f.me,[scan]))[0].filter_hidden,false);
 await f.pool.query('UPDATE users SET content_filter=$1 WHERE id=$2',
   [{...ALL,men:false,enforceGeneralFilter:true},f.me]);
 const [filtered]=await f.project();
 assert.equal(filtered.hidden_reason,'content_filter');
 assert.equal(filtered.moderation_status,'approved');
 const [filteredLibrary]=await history.projectFilterMediaLibrary(f.pool,f.me,[library]);
 assert.equal(filteredLibrary.hidden_reason,'content_filter');
 assert.equal(filteredLibrary.moderation_status,'approved');
});
