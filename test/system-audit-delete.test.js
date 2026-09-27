'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const {randomUUID}=require('node:crypto');
const {Client,Pool}=require('pg');
const {ensureSystemAuditSchema,beginOperation,recordAuditEvent,deleteAuditRecord,deleteAuditRecords,
  registerSystemAuditRoutes,buildQuery,readFilters}=require('../server/system-audit');

const dbOptions={skip:process.env.RUN_DB_TESTS!=='1'};
const deferred=()=>{let resolve;const promise=new Promise(done=>{resolve=done;});return {promise,resolve};};

async function fixture(t) {
  const url=new URL(process.env.DATABASE_URL);
  assert.match(url.pathname,/test/i,'Audit deletion tests require a disposable test database');
  const owner=new Client({connectionString:url.href,ssl:false});
  await owner.connect();
  const schema=`audit_delete_test_${randomUUID().replaceAll('-','')}`;
  await owner.query(`CREATE SCHEMA "${schema}"`);
  const pool=new Pool({connectionString:url.href,ssl:false,options:`-c search_path=${schema}`,max:8});
  t.after(async()=>{await pool.end();await owner.query(`DROP SCHEMA "${schema}" CASCADE`);await owner.end();});
  await pool.query(`CREATE TABLE users(id uuid PRIMARY KEY,name text,short_id integer);
    CREATE TABLE groups(id uuid PRIMARY KEY,name text);
    CREATE TABLE stored_files(id uuid PRIMARY KEY,user_id uuid,file_type text,moderation_status text,moderation_details jsonb);
    CREATE TABLE pending_scans(id integer PRIMARY KEY,user_id uuid,file_type text,retry_count integer DEFAULT 0);
    CREATE TABLE messages(id uuid PRIMARY KEY,sender_id uuid,type text,delivery_summary jsonb);`);
  const actor=randomUUID(),recipient=randomUUID();
  await pool.query('INSERT INTO users VALUES($1,$2,42),($3,$4,123)',[actor,'Delete Admin',recipient,'Recipient']);
  await ensureSystemAuditSchema(pool);
  const start=(data={},db=pool)=>beginOperation(db,{action:'upload_file',initiatorId:actor,
    executorType:'user',executorId:actor,source:'http',...data});
  const event=(operation,data={},db=pool)=>recordAuditEvent(db,{operationId:operation.id,
    parentEventId:operation.root_event_id,kind:'media_stored',...data});
  const events=async operation=>(await pool.query('SELECT * FROM audit_events WHERE operation_id=$1 ORDER BY id',[operation.id])).rows;
  const saved=async operation=>(await pool.query('SELECT * FROM audit_operations WHERE id=$1',[operation.id])).rows[0];
  const routes={};
  let requestPool=pool;
  const admin=(_req,_res,next)=>next();
  registerSystemAuditRoutes({get:(path,...handlers)=>{routes['GET '+path]=handlers;},
    delete:(path,...handlers)=>{routes['DELETE '+path]=handlers;}},
  {getPool:async()=>requestPool,adminMiddleware:admin});
  const call=async(path,{id,confirmId=id,user={id:actor},adminPerm='edit',body={confirmId}}={})=>{
    const response={statusCode:200,headers:{},status(value){this.statusCode=value;return this;},
      set(key,value){this.headers[key]=value;return this;},json(value){this.body=value;return this;}};
    await routes[path].at(-1)({params:{id},query:{},body,user,adminPerm},response);
    return response;
  };
  const remove=(mode,id,db=pool)=>deleteAuditRecord(db,{mode,id,actorId:actor});
  return {pool,schema,actor,recipient,start,event,events,saved,call,remove,routes,admin,
    usePool(value){requestPool=value;}};
}

function interceptPool(pool,callback) {
  return {connect:async()=>{
    const client=await pool.connect();
    return {query:async(text,values)=>callback(text,values,()=>client.query(text,values)),release:()=>client.release()};
  }};
}

async function waitForAdvisory(pool,pid) {
  for (let attempt=0;attempt<100;attempt++) {
    const row=(await pool.query('SELECT wait_event FROM pg_stat_activity WHERE pid=$1',[pid])).rows[0];
    if (row?.wait_event==='advisory') return;
    await new Promise(resolve=>setTimeout(resolve,10));
  }
  assert.fail('Expected operation advisory lock waiter');
}

test('deletion routes use admin middleware, edit permission, strict identifiers and explicit confirmation',dbOptions,async t=>{
  const f=await fixture(t),operation=await f.start(),child=await f.event(operation);
  assert.equal(Object.keys(f.routes).length,10);
  assert.ok(Object.values(f.routes).every(handlers=>handlers[0]===f.admin));
  for (const adminPerm of [undefined,'view','read','EDIT',null]) {
    const request={id:operation.id,adminPerm};
    if (adminPerm===undefined) request.adminPerm='';
    const denied=await f.call('DELETE /api/admin/audit/operations/:id',request);
    assert.equal(denied.statusCode,403);
    assert.equal(denied.body.code,'AUDIT_DELETE_FORBIDDEN');
    assert.equal((await f.call('GET /api/admin/audit/catalog',request)).body.canDelete,false);
  }
  assert.equal((await f.call('GET /api/admin/audit/catalog')).body.canDelete,true);
  assert.equal((await f.call('DELETE /api/admin/audit/operations/:id',{id:operation.id,user:null})).statusCode,401);
  for (const body of [undefined,null,[],{}, {confirmId:1},{confirmId:randomUUID()}]) {
    const response=await f.call('DELETE /api/admin/audit/operations/:id',{id:operation.id,body:body===undefined?{}:body});
    assert.equal(response.statusCode,400);
    assert.equal(response.body.code,'AUDIT_DELETE_CONFIRMATION_REQUIRED');
  }
  for (const id of ['bad-id',"' OR true",''])
    assert.equal((await f.call('DELETE /api/admin/audit/operations/:id',{id})).statusCode,400);
  for (const id of ['0','-1','1.0','1e3','9223372036854775808',''])
    assert.equal((await f.call('DELETE /api/admin/audit/events/:id',{id})).statusCode,400);
  assert.equal((await f.call('DELETE /api/admin/audit/operations/:id',{id:randomUUID()})).statusCode,404);
  assert.equal((await f.call('DELETE /api/admin/audit/events/:id',{id:'9223372036854775807'})).statusCode,404);
  const root=await f.call('DELETE /api/admin/audit/events/:id',{id:operation.root_event_id});
  assert.equal(root.statusCode,409);
  assert.equal(root.body.code,'AUDIT_ROOT_EVENT');
  assert.deepEqual((await f.events(operation)).map(row=>row.id),[operation.root_event_id,child.id]);
  assert.equal((await f.pool.query('SELECT count(*) FROM audit_deleted_operations')).rows[0].count,'0');
});

test('whole-operation deletion removes exactly its audit rows and records a distinct transactional administrator action',dbOptions,async t=>{
  const f=await fixture(t),target=await f.start(),other=await f.start();
  const child=await f.event(target),grandchild=await f.event(target,{parentEventId:child.id,kind:'scan_queued'});
  await f.event(other);
  const untouched=await f.events(other),file=randomUUID(),message=randomUUID();
  await f.pool.query(`INSERT INTO stored_files(id,user_id,file_type,moderation_status,audit_operation_id,audit_parent_event_id)
    VALUES($1,$2,'video','pending',$3,$4)`,[file,f.actor,target.id,target.root_event_id]);
  await f.pool.query(`INSERT INTO pending_scans(id,user_id,file_type,audit_operation_id,audit_parent_event_id)
    VALUES(1,$1,'video',$2,$3)`,[f.actor,target.id,grandchild.id]);
  await f.pool.query(`INSERT INTO messages(id,sender_id,type,audit_operation_id,audit_parent_event_id)
    VALUES($1,$2,'video',$3,$4)`,[message,f.actor,target.id,child.id]);
  const businessBefore={};
  for (const table of ['stored_files','pending_scans','messages']) businessBefore[table]=(await f.pool.query(`SELECT * FROM ${table}`)).rows;
  const targetCount=(await f.events(target)).length;
  const response=await f.call('DELETE /api/admin/audit/operations/:id',{id:target.id});
  assert.equal(response.statusCode,200);
  assert.deepEqual(response.body,{deleted:true,operationId:target.id,deletedEvents:targetCount});
  assert.equal(await f.saved(target),undefined);
  assert.deepEqual(await f.events(target),[]);
  assert.deepEqual(await f.events(other),untouched);
  for (const table of Object.keys(businessBefore)) assert.deepEqual((await f.pool.query(`SELECT * FROM ${table}`)).rows,businessBefore[table]);
  assert.deepEqual((await f.pool.query('SELECT * FROM audit_deleted_operations')).rows,[{id:target.id}]);
  const deletion=(await f.pool.query("SELECT * FROM audit_operations WHERE action='audit_delete_operation'")).rows;
  assert.equal(deletion.length,1);
  assert.notEqual(deletion[0].id,target.id);
  assert.equal(deletion[0].initiator_id,f.actor);
  assert.equal(deletion[0].target_type,'audit_operation');
  assert.equal(deletion[0].target_id,target.id);
  const evidence=(await f.events(deletion[0]))[0];
  assert.equal(evidence.executor_type,'admin');
  assert.deepEqual(evidence.details,{affectedCount:targetCount,auditOperationId:target.id});
  assert.equal((await f.call('DELETE /api/admin/audit/operations/:id',{id:target.id})).statusCode,404);
});

test('deleting one event preserves descendants, clears only direct parent references and rebuilds actual outcome and counts',dbOptions,async t=>{
  const f=await fixture(t),operation=await f.start(),other=await f.start();
  const started=await f.event(operation,{kind:'scan_attempt_started',operationStatus:'pending',reasonCode:'scan_pending'});
  const done=await f.event(operation,{kind:'scan_workflow_finished',operationStatus:'completed',reasonCode:'scan_approved',parentEventId:started.id});
  const child=await f.event(operation,{kind:'http_response',operationStatus:'pending',reasonCode:'http_202',parentEventId:done.id});
  const grandchild=await f.event(operation,{kind:'provider_call_finished',parentEventId:child.id});
  await f.event(other,{operationStatus:'failed'});
  const otherBefore=await f.events(other),rootBefore=(await f.events(operation))[0];
  const response=await f.call('DELETE /api/admin/audit/events/:id',{id:done.id});
  assert.deepEqual(response.body,{deleted:true,operationId:operation.id,deletedEvents:1});
  const rows=await f.events(operation);
  assert.deepEqual(rows[0],rootBefore);
  assert.equal(rows.find(row=>row.id===child.id).parent_event_id,null);
  assert.deepEqual(rows.find(row=>row.id===grandchild.id),grandchild);
  assert.ok(!rows.some(row=>row.id===done.id));
  assert.deepEqual(await f.events(other),otherBefore);
  const saved=await f.saved(operation);
  assert.equal(saved.event_count,'4');
  assert.equal(saved.status,'pending');
  assert.equal(saved.status_source,'http_response');
  assert.equal(saved.reason_code,'http_202');
  assert.equal(saved.root_event_id,operation.root_event_id);
  assert.deepEqual((await f.pool.query('SELECT * FROM audit_deleted_events')).rows,[{id:done.id,operation_id:operation.id}]);
  const deletion=(await f.pool.query("SELECT * FROM audit_operations WHERE action='audit_delete_event'")).rows[0];
  assert.equal((await f.events(deletion))[0].details.auditEventId,done.id);
  assert.equal((await f.call('DELETE /api/admin/audit/events/:id',{id:done.id})).statusCode,404);
});

test('projection rebuild preserves scan authority and derives latest timestamp and duration only from remaining evidence',dbOptions,async t=>{
  const f=await fixture(t),operation=await f.start();
  const scan=await f.event(operation,{kind:'scan_workflow_finished',operationStatus:'blocked',reasonCode:'policy_blocked'});
  const response=await f.event(operation,{kind:'http_response',operationStatus:'completed',reasonCode:'http_200'});
  const last=await f.event(operation,{kind:'provider_call_finished'});
  await f.remove('event',last.id);
  let row=await f.saved(operation);
  assert.equal(row.status,'blocked');
  assert.equal(row.status_source,'scan_workflow_finished');
  assert.equal(row.reason_code,'policy_blocked');
  assert.equal(row.updated_at.toISOString(),response.created_at.toISOString());
  assert.equal(BigInt(row.duration_ms),BigInt(response.created_at-operation.created_at));
  await f.remove('event',response.id);
  row=await f.saved(operation);
  assert.equal(row.updated_at.toISOString(),scan.created_at.toISOString());
  assert.equal(row.event_count,'2');
  const events=(await f.pool.query(buildQuery(readFilters({}, {mode:'events'})))).rows;
  assert.ok(events.every(event=>event.root_event_id));
  assert.equal(events.find(event=>event.id===scan.id).root_event_id,operation.root_event_id);
});

test('deleting context evidence clears unsupported fields but never re-looks up changed recipient snapshots',dbOptions,async t=>{
  const f=await fixture(t),operation=await f.start();
  const details={mediaType:'video',captureKind:'camera_video',recipientType:'user',recipientId:f.recipient};
  const first=await f.event(operation,{kind:'upload_context',details});
  const duplicate=await f.event(operation,{kind:'upload_context',details});
  await f.pool.query('UPDATE users SET name=$2,short_id=999 WHERE id=$1',[f.recipient,'Changed recipient']);
  await f.remove('event',first.id);
  let row=await f.saved(operation);
  assert.equal(row.recipient_name,'Recipient');
  assert.equal(row.recipient_short_id,'123');
  assert.equal(row.capture_kind,'camera_video');
  await f.remove('event',duplicate.id);
  row=await f.saved(operation);
  for (const column of ['media_type','capture_kind','recipient_type','recipient_id','recipient_name','recipient_short_id'])
    assert.equal(row[column],null,column);
});

test('late events and business writes survive only explicitly deleted operation IDs; unknown IDs still fail',dbOptions,async t=>{
  const f=await fixture(t),operation=await f.start();
  await f.remove('operation',operation.id);
  assert.equal(await f.event(operation),undefined);
  const file=randomUUID();
  await f.pool.query(`INSERT INTO stored_files(id,user_id,file_type,moderation_status,audit_operation_id,audit_parent_event_id)
    VALUES($1,$2,'video','pending',$3,$4)`,[file,f.actor,operation.id,operation.root_event_id]);
  await f.pool.query(`INSERT INTO pending_scans(id,user_id,file_type,audit_operation_id,audit_parent_event_id)
    VALUES(1,$1,'video',$2,$3)`,[f.actor,operation.id,operation.root_event_id]);
  await f.pool.query('UPDATE pending_scans SET retry_count=1 WHERE id=1');
  await f.pool.query('DELETE FROM pending_scans WHERE id=1');
  assert.equal((await f.pool.query('SELECT count(*) FROM stored_files WHERE id=$1',[file])).rows[0].count,'1');
  assert.deepEqual(await f.events(operation),[]);
  await assert.rejects(f.start({id:operation.id}),/cannot be recreated/);
  await assert.rejects(recordAuditEvent(f.pool,{operationId:randomUUID(),kind:'media_stored'}),{code:'23503'});
  await assert.rejects(f.pool.query(`INSERT INTO stored_files(id,file_type,moderation_status,audit_operation_id)
    VALUES($1,'video','pending',$2)`,[randomUUID(),randomUUID()]),{code:'23503'});
});

test('stale same-operation parents are normalized while wrong-operation or unknown parents still fail',dbOptions,async t=>{
  const f=await fixture(t),operation=await f.start(),other=await f.start(),parent=await f.event(operation);
  await f.remove('event',parent.id);
  const later=await f.event(operation,{parentEventId:parent.id});
  assert.equal(later.parent_event_id,null);
  await assert.rejects(f.event(other,{parentEventId:parent.id}),{code:'23503'});
  await assert.rejects(f.event(operation,{parentEventId:'9223372036854775807'}),{code:'23503'});
  const file=randomUUID();
  await f.pool.query(`INSERT INTO stored_files(id,file_type,moderation_status,audit_operation_id,audit_parent_event_id)
    VALUES($1,'video','pending',$2,$3)`,[file,operation.id,parent.id]);
  const persisted=(await f.events(operation)).at(-1);
  assert.equal(persisted.parent_event_id,null);
  assert.equal((await f.pool.query('SELECT audit_parent_event_id FROM stored_files WHERE id=$1',[file])).rows[0].audit_parent_event_id,parent.id);
});

test('ordinary writes and broad mistakes remain blocked including after pooled deletion transactions',dbOptions,async t=>{
  const f=await fixture(t),operation=await f.start(),other=await f.start(),parent=await f.event(operation);
  const child=await f.event(operation,{parentEventId:parent.id});
  await f.remove('event',parent.id);
  for (const table of ['audit_events','audit_operations','audit_metadata','audit_deleted_events','audit_deleted_operations']) {
    await assert.rejects(f.pool.query(`TRUNCATE ${table} CASCADE`),/append-only/);
  }
  await assert.rejects(f.pool.query('DELETE FROM audit_events WHERE id=$1',[child.id]),/append-only/);
  await assert.rejects(f.pool.query('UPDATE audit_operations SET status=$2 WHERE id=$1',[operation.id,'failed']),/maintained by events/);
  await assert.rejects(f.pool.query('DELETE FROM audit_deleted_events WHERE id=$1',[parent.id]),/append-only/);
  const client=await f.pool.connect();
  try {
    for (const [sql,values] of [
      ['DELETE FROM audit_events WHERE operation_id=$1',[operation.id]],
      ['DELETE FROM audit_operations WHERE id=$1',[other.id]],
      ['UPDATE audit_events SET status=$2 WHERE id=$1',[child.id,'failed']],
      ['UPDATE audit_operations SET initiator_name=$2 WHERE id=$1',[operation.id,'Forged']],
    ]) {
      await client.query('BEGIN');
      await client.query(`SELECT set_config('app.audit_delete_mode','event',true),
        set_config('app.audit_delete_operation',$1,true),set_config('app.audit_delete_event',$2,true)`,[operation.id,child.id]);
      await assert.rejects(client.query(sql,values),/append-only|maintained by events/);
      await client.query('ROLLBACK');
    }
  } finally {client.release();}
  assert.ok(await f.saved(other));
  assert.equal((await f.saved(operation)).initiator_name,'Delete Admin');
});

test('failure to record deletion evidence rolls back deletion, tombstones, parent rewrites and projection',dbOptions,async t=>{
  const f=await fixture(t);
  for (const mode of ['operation','event']) {
    const operation=await f.start(),parent=await f.event(operation);
    await f.event(operation,{parentEventId:parent.id});
    const before=await f.events(operation),rootBefore=await f.saved(operation);
    f.usePool(interceptPool(f.pool,async(text,_values,next)=>{
      if (text.includes('INSERT INTO audit_operations')) throw new Error('Injected administration evidence failure');
      return next();
    }));
    const response=await f.call(`DELETE /api/admin/audit/${mode==='operation'?'operations':'events'}/:id`,
      {id:mode==='operation'?operation.id:parent.id});
    assert.equal(response.statusCode,503);
    assert.equal(response.body.code,'AUDIT_UNAVAILABLE');
    assert.deepEqual(await f.events(operation),before);
    assert.deepEqual(await f.saved(operation),rootBefore);
    assert.equal((await f.pool.query('SELECT count(*) FROM audit_deleted_operations WHERE id=$1',[operation.id])).rows[0].count,'0');
    assert.equal((await f.pool.query('SELECT count(*) FROM audit_deleted_events WHERE operation_id=$1',[operation.id])).rows[0].count,'0');
  }
});

test('an existing event writer completes before whole-operation deletion and its committed event is included',dbOptions,async t=>{
  const f=await fixture(t),operation=await f.start(),writer=await f.pool.connect();
  let deletionClient;
  const entered=deferred();
  const observedPool={connect:async()=>{
    deletionClient=await f.pool.connect();entered.resolve();return deletionClient;
  }};
  try {
    await writer.query('BEGIN');
    await f.event(operation,{},writer);
    const deletion=f.remove('operation',operation.id,observedPool);
    await entered.promise;
    await waitForAdvisory(f.pool,deletionClient.processID);
    await writer.query('COMMIT');
    const result=await deletion;
    assert.equal(result.deletedEvents,2);
    assert.deepEqual(await f.events(operation),[]);
  } finally {await writer.query('ROLLBACK');writer.release();}
});

test('a late business writer waits for operation deletion and then continues without resurrecting audit rows',dbOptions,async t=>{
  const f=await fixture(t),operation=await f.start(),marked=deferred(),resume=deferred();
  const paused=interceptPool(f.pool,async(text,_values,next)=>{
    const result=await next();
    if (text.startsWith('INSERT INTO audit_deleted_operations')) {marked.resolve();await resume.promise;}
    return result;
  });
  const writer=await f.pool.connect();
  try {
    const deletion=f.remove('operation',operation.id,paused);
    await marked.promise;
    const file=randomUUID();
    const write=writer.query(`INSERT INTO stored_files(id,file_type,moderation_status,audit_operation_id,audit_parent_event_id)
      VALUES($1,'video','pending',$2,$3)`,[file,operation.id,operation.root_event_id]);
    await waitForAdvisory(f.pool,writer.processID);
    resume.resolve();
    await deletion;
    await write;
    assert.equal((await f.pool.query('SELECT count(*) FROM stored_files WHERE id=$1',[file])).rows[0].count,'1');
    assert.deepEqual(await f.events(operation),[]);
  } finally {resume.resolve();writer.release();}
});

test('a concurrent stale-parent event waits for deletion and records surviving work with a NULL parent',dbOptions,async t=>{
  const f=await fixture(t),operation=await f.start(),parent=await f.event(operation),marked=deferred(),resume=deferred();
  const paused=interceptPool(f.pool,async(text,_values,next)=>{
    const result=await next();
    if (text.startsWith('INSERT INTO audit_deleted_events')) {marked.resolve();await resume.promise;}
    return result;
  });
  const writer=await f.pool.connect();
  try {
    const deletion=f.remove('event',parent.id,paused);
    await marked.promise;
    const write=f.event(operation,{parentEventId:parent.id,kind:'scan_workflow_finished',operationStatus:'completed'},writer);
    await waitForAdvisory(f.pool,writer.processID);
    resume.resolve();
    await deletion;
    const event=await write;
    assert.equal(event.parent_event_id,null);
    assert.equal((await f.saved(operation)).event_count,'2');
    assert.equal((await f.saved(operation)).status,'completed');
  } finally {resume.resolve();writer.release();}
});

test('selected bulk deletion is atomic, guards roots, and permits only confirmed editor requests',dbOptions,async t=>{
 const f=await fixture(t),first=await f.start(),second=await f.start(),keep=await f.start();
 const a=await f.event(first),b=await f.event(second);
 const body={scope:'selected',operations:[],events:[a.id,b.id],confirm:'DELETE_SELECTED_AUDIT'};
 for(const adminPerm of ['view',''])assert.equal((await f.call('DELETE /api/admin/audit/records',{adminPerm,body})).statusCode,403);
 assert.equal((await f.call('GET /api/admin/audit/deletion-preview',{adminPerm:'view'})).statusCode,403);
 for(const invalid of [{...body,confirm:''},{...body,events:['bad']},{...body,events:[],operations:[]},{...body,events:Array(201).fill(a.id)}])
  assert.equal((await f.call('DELETE /api/admin/audit/records',{body:invalid})).statusCode,400);
 const failed=await f.call('DELETE /api/admin/audit/records',{body:{...body,events:[a.id,second.root_event_id]}});
 assert.equal(failed.statusCode,409);assert.ok((await f.events(first)).some(row=>row.id===a.id));
 const result=await f.call('DELETE /api/admin/audit/records',{body});assert.equal(result.statusCode,200);assert.equal(result.body.deletedEvents,2);
 assert.equal((await f.events(first)).length,1);assert.equal((await f.events(second)).length,1);assert.ok(await f.saved(keep));
 assert.equal((await f.pool.query("SELECT count(*) FROM audit_operations WHERE action='audit_delete_records'")).rows[0].count,'1');
});

test('delete-all uses a fixed boundary, preserves later operations and business data, and completes across batches',dbOptions,async t=>{
 const f=await fixture(t),roots=[];
 for(let i=0;i<103;i++)roots.push(await f.start());
 const preview=(await f.call('GET /api/admin/audit/deletion-preview')).body;
 assert.equal(preview.operations,'103');
 const later=await f.start(),file=randomUUID();
 await f.pool.query('INSERT INTO stored_files(id,user_id,file_type) VALUES($1,$2,$3)',[file,f.actor,'image']);
 const body={scope:'all',through:preview.through,confirm:'DELETE_ALL_AUDIT'};
 const first=await f.call('DELETE /api/admin/audit/records',{body});assert.equal(first.statusCode,200);assert.equal(first.body.deletedOperations,100);assert.equal(first.body.remaining,'3');
 const second=await f.call('DELETE /api/admin/audit/records',{body});assert.equal(second.statusCode,200);assert.equal(second.body.deletedOperations,3);assert.equal(second.body.remaining,'0');
 assert.ok(await f.saved(later));assert.equal((await f.pool.query('SELECT count(*) FROM stored_files')).rows[0].count,'1');
 const retry=await f.call('DELETE /api/admin/audit/records',{body});assert.equal(retry.body.deletedOperations,0);assert.equal(retry.body.remaining,'0');
 assert.equal((await f.pool.query("SELECT count(*) FROM audit_operations WHERE action='audit_delete_records'")).rows[0].count,'2');
});
