'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const { Client, Pool } = require('pg');
const { ensureSystemAuditSchema, beginOperation, recordAuditEvent, runWithAuditContext,
  getAuditContext, registerSystemAuditRoutes, readFilters, buildQuery, csvCell } = require('../server/system-audit');

const dbOptions = { skip:process.env.RUN_DB_TESTS !== '1' };

async function fixture(t) {
  const config = { connectionString:process.env.DATABASE_URL,
    ssl:process.env.DB_SSL === 'true' ? { rejectUnauthorized:process.env.DB_REJECT_UNAUTHORIZED !== 'false' } : false };
  const owner = new Client(config);
  await owner.connect();
  const schema = `system_audit_test_${randomUUID().replaceAll('-','')}`;
  await owner.query(`CREATE SCHEMA "${schema}"`);
  const pool = new Pool({ ...config,options:`-c search_path=${schema},public`,max:4 });
  t.after(async()=>{
    await pool.end();
    await owner.query(`DROP SCHEMA "${schema}" CASCADE`);
    await owner.end();
  });
  await pool.query(`CREATE TABLE users(id uuid PRIMARY KEY,name text,short_id integer);
    CREATE TABLE stored_files(id uuid PRIMARY KEY,user_id uuid,file_type text,moderation_status text,moderation_details jsonb);
    CREATE TABLE pending_scans(id integer PRIMARY KEY,user_id uuid,file_type text,retry_count integer DEFAULT 0);
    CREATE TABLE messages(id uuid PRIMARY KEY,sender_id uuid,type text,delivery_summary jsonb);
    CREATE TABLE message_status(message_id uuid,user_id uuid,status text,PRIMARY KEY(message_id,user_id));
    CREATE TABLE message_requests(id uuid PRIMARY KEY,sender_id uuid,type text,status text DEFAULT 'pending');
    CREATE TABLE filter_audit_events(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,kind text,
      scope_type text,scope_id uuid,message_id uuid,file_id uuid,details jsonb DEFAULT '{}'::jsonb);`);
  const userId = randomUUID();
  await pool.query('INSERT INTO users VALUES($1,$2,42)',[userId,'Audit User']);
  await ensureSystemAuditSchema(pool);
  const routes = {};
  const adminMiddleware = (_req,_res,next)=>next();
  registerSystemAuditRoutes({ get:(path,...handlers)=>{routes[path]=handlers;},delete(){} },{
    getPool:async()=>pool,adminMiddleware });
  const call = async(path,{query={},params={},user={id:userId}}={})=>{
    const response = { statusCode:200,headers:{},status(value){this.statusCode=value;return this;},
      set(key,value){this.headers[key]=value;return this;},
      json(value){this.body=value;return this;},send(value){this.body=value;return this;} };
    await routes[path].at(-1)({query,params,user},response);
    return response;
  };
  const start = (data={}) => beginOperation(pool,{action:'send_message',initiatorId:userId,
    executorType:'user',executorId:userId,source:'http',...data});
  const transaction = async(operation,callback)=>{
    const client=await pool.connect();
    try {
      await client.query('BEGIN');
      await client.query("SELECT set_config('app.audit_operation_id',$1,true),set_config('app.audit_parent_event_id',$2,true)",
        [operation.id,operation.root_event_id]);
      const result=await callback(client);
      await client.query('COMMIT');
      return result;
    } catch(error) {await client.query('ROLLBACK');throw error;}
    finally {client.release();}
  };
  return {pool,userId,start,transaction,call,routes,adminMiddleware};
}

test('async audit contexts remain isolated across concurrent operations',async()=>{
  const first = randomUUID(),second = randomUUID();
  const values = await Promise.all([first,second].map((operationId,index)=>runWithAuditContext({operationId},async()=>{
    await new Promise(resolve=>setTimeout(resolve,index?1:10));
    assert.ok(Object.isFrozen(getAuditContext()));
    return getAuditContext().operationId;
  })));
  assert.deepEqual(values,[first,second]);
  assert.equal(getAuditContext(),null);
});

test('filters validate identifiers, dates, cursors and export bounds',()=>{
  assert.equal(readFilters({userId:'42',limit:'999'}).limit,200);
  assert.throws(()=>readFilters({userId:'someone@example.com'}));
  assert.throws(()=>readFilters({action:"x' OR true"}));
  assert.throws(()=>readFilters({before:'not-json'}));
  assert.throws(()=>readFilters({from:'2026-09-24'}));
  assert.throws(()=>readFilters({}, {exportMode:true}));
  assert.throws(()=>readFilters({from:'2026-01-01T00:00:00Z',to:'2026-03-01T00:00:00Z'}, {exportMode:true}));
  assert.throws(()=>readFilters({from:'2026-09-24T00:00:00Z',to:'2026-09-23T00:00:00Z'}));
  const query = buildQuery(readFilters({userId:'42',action:'send_message'}));
  assert.match(query.text,/initiator_short_id=\$2/);
  assert.deepEqual(query.values,['send_message','42',51]);
});

test('CSV cells neutralize formulas, leading whitespace and quote breaks',()=>{
  for (const value of ['=HYPERLINK("secret")','+cmd','-cmd','@sum',' \t=cmd','\nordinary'])
    assert.ok(csvCell(value).startsWith('"\''));
  assert.equal(csvCell('ordinary, "name"'),'"ordinary, ""name"""');
  assert.equal(csvCell(null),'""');
});

test('admin middleware is mandatory and every route is protected',()=>{
  assert.throws(()=>registerSystemAuditRoutes({get(){}},{getPool(){}}));
  const routes=[];
  const admin=()=>{};
  registerSystemAuditRoutes({get:(...args)=>routes.push(args),delete:(...args)=>routes.push(args)},{getPool(){},adminMiddleware:admin});
  assert.equal(routes.length,10);
  assert.ok(routes.every(route=>route[1]===admin));
});

test('schema is idempotent, correlations are optional and start time is retained',dbOptions,async t=>{
  const f=await fixture(t);
  const before=(await f.pool.query('SELECT * FROM audit_metadata')).rows;
  await ensureSystemAuditSchema(f.pool);
  assert.deepEqual((await f.pool.query('SELECT * FROM audit_metadata')).rows,before);
  const columns=(await f.pool.query(`SELECT table_name,column_name FROM information_schema.columns
    WHERE table_schema=current_schema() AND column_name IN ('audit_operation_id','audit_parent_event_id')`)).rows;
  assert.equal(columns.length,10);
});

test('begin is atomic and preserves authenticated initiator separately from worker executor',dbOptions,async t=>{
  const f=await fixture(t);
  const operation=await f.start({executorType:'worker',executorId:'scan-worker'});
  assert.ok(operation.root_event_id);
  assert.equal(operation.event_count,'1');
  const saved=(await f.pool.query('SELECT * FROM audit_operations WHERE id=$1',[operation.id])).rows[0];
  assert.equal(saved.initiator_id,f.userId);
  assert.equal(saved.initiator_short_id,'42');
  assert.equal(saved.initiator_name,'Audit User');
  assert.equal(saved.event_count,'1');
  assert.equal(saved.root_event_id,operation.root_event_id);
  const first=(await f.pool.query('SELECT * FROM audit_events WHERE id=$1',[operation.root_event_id])).rows[0];
  assert.equal(first.executor_type,'worker');
  assert.equal(first.executor_id,'scan-worker');
  assert.equal(first.executor_name,null);
  await assert.rejects(f.start({id:operation.id}));
  assert.equal((await f.pool.query('SELECT count(*) FROM audit_events')).rows[0].count,'1');
});

test('operation and events roll back with caller transaction without nested BEGIN',dbOptions,async t=>{
  const f=await fixture(t);
  const client=await f.pool.connect();
  try {
    await client.query('BEGIN');
    const operation=await beginOperation(client,{action:'send_message',initiatorId:f.userId});
    await recordAuditEvent(client,{operationId:operation.id,parentEventId:operation.root_event_id,kind:'message_persisted'});
    await client.query('ROLLBACK');
  } finally {client.release();}
  assert.equal((await f.pool.query('SELECT count(*) FROM audit_operations')).rows[0].count,'0');
  assert.equal((await f.pool.query('SELECT count(*) FROM audit_events')).rows[0].count,'0');
});

test('parent links cannot cross operations and explicit event status does not finish root',dbOptions,async t=>{
  const f=await fixture(t);
  const first=await f.start(),second=await f.start();
  await assert.rejects(recordAuditEvent(f.pool,{operationId:first.id,parentEventId:second.root_event_id,
    kind:'scan_completed'}),error=>error.code==='23503');
  await runWithAuditContext({operationId:first.id,parentEventId:first.root_event_id,executorType:'worker',executorId:'scanner'},()=>
    recordAuditEvent(f.pool,{kind:'scan_completed',status:'completed',attempt:2,
      details:{attempt:2,message:'secret',url:'https://secret',body:'secret',cacheHit:true}}));
  let row=(await f.pool.query('SELECT * FROM audit_operations WHERE id=$1',[first.id])).rows[0];
  assert.equal(row.status,'running');
  assert.equal(row.event_count,'2');
  const completed=await recordAuditEvent(f.pool,{operationId:first.id,parentEventId:first.root_event_id,
    kind:'operation_completed',status:'completed',operationStatus:'pending',reasonCode:'contact_approval'});
  row=(await f.pool.query('SELECT * FROM audit_operations WHERE id=$1',[first.id])).rows[0];
  assert.equal(row.status,'pending');
  assert.equal(row.reason_code,'contact_approval');
  assert.equal(completed.parent_event_id,first.root_event_id);
  const details=(await f.pool.query("SELECT details FROM audit_events WHERE kind='scan_completed'")).rows[0].details;
  assert.deepEqual(details,{attempt:2,cacheHit:true});
});

test('audit records reject ordinary mutations and survive actor deletion',dbOptions,async t=>{
  const f=await fixture(t);
  const operation=await f.start();
  for (const sql of ['UPDATE audit_events SET status=\'failed\'','DELETE FROM audit_events',
    'UPDATE audit_operations SET status=\'failed\'','DELETE FROM audit_operations',
    'TRUNCATE audit_events','TRUNCATE audit_operations CASCADE','DELETE FROM audit_metadata'])
    await assert.rejects(f.pool.query(sql),/append-only|maintained by events/);
  await f.pool.query('DELETE FROM users WHERE id=$1',[f.userId]);
  const retained=(await f.pool.query('SELECT * FROM audit_operations')).rows[0];
  assert.equal(retained.initiator_id,f.userId);
  assert.equal(retained.initiator_name,'Audit User');
  assert.equal(retained.root_event_id,operation.root_event_id);
});

test('tagged business rows produce atomic minimal events and legacy rows remain unlinked',dbOptions,async t=>{
  const f=await fixture(t);
  const operation=await f.start({action:'upload_file'});
  const file=randomUUID();
  await f.pool.query(`INSERT INTO stored_files(id,user_id,file_type,moderation_status)
    VALUES($1,$2,'video','pending')`,[randomUUID(),f.userId]);
  assert.equal((await f.pool.query('SELECT count(*) FROM audit_events')).rows[0].count,'1');
  await f.pool.query(`INSERT INTO stored_files(id,user_id,file_type,moderation_status,moderation_details,
    audit_operation_id,audit_parent_event_id) VALUES($1,$2,'video','pending',$3,$4,$5)`,
  [file,f.userId,JSON.stringify({reason:'private description',url:'https://private'}),operation.id,operation.root_event_id]);
  await f.transaction(operation,client=>client.query(`UPDATE stored_files SET moderation_status='approved',moderation_details=$2 WHERE id=$1`,
    [file,JSON.stringify({classification:{category:'men'},reason:'never copy this'})]));
  await f.pool.query('UPDATE stored_files SET user_id=user_id WHERE id=$1',[file]);
  const events=(await f.pool.query('SELECT * FROM audit_events WHERE operation_id=$1 ORDER BY id',[operation.id])).rows;
  assert.deepEqual(events.map(row=>row.kind),['operation_started','media_stored','media_moderation_changed']);
  assert.deepEqual(events[2].details,{fileType:'video',previousStatus:'pending',moderationStatus:'approved'});
  assert.equal(events[2].target_id,file);
  assert.equal(events[2].parent_event_id,operation.root_event_id);
  assert.ok(events.slice(1).every(row=>row.executor_type==='system' && row.source==='database_trigger'));
  assert.equal((await f.pool.query('SELECT status FROM audit_operations WHERE id=$1',[operation.id])).rows[0].status,'running');
});

test('later file updates never borrow original upload causality without explicit transaction context',dbOptions,async t=>{
  const f=await fixture(t);
  const original=await f.start({action:'upload_file'}),rescan=await f.start({action:'admin_action'});
  const file=randomUUID();
  await f.pool.query(`INSERT INTO stored_files(id,user_id,file_type,moderation_status,audit_operation_id,audit_parent_event_id)
    VALUES($1,$2,'video','pending',$3,$4)`,[file,f.userId,original.id,original.root_event_id]);
  await f.pool.query("UPDATE stored_files SET moderation_status='approved' WHERE id=$1",[file]);
  assert.equal((await f.pool.query("SELECT count(*) FROM audit_events WHERE kind='media_moderation_changed'")).rows[0].count,'0');
  await f.transaction(rescan,client=>client.query("UPDATE stored_files SET moderation_status='rejected' WHERE id=$1",[file]));
  const event=(await f.pool.query("SELECT * FROM audit_events WHERE kind='media_moderation_changed'")).rows[0];
  assert.equal(event.operation_id,rescan.id);
  assert.equal(event.parent_event_id,rescan.root_event_id);
  assert.equal(event.target_id,file);
  assert.equal((await f.pool.query('SELECT audit_operation_id FROM stored_files WHERE id=$1',[file])).rows[0].audit_operation_id,original.id);
  await f.pool.query("UPDATE stored_files SET moderation_status='approved' WHERE id=$1",[file]);
  assert.equal((await f.pool.query("SELECT count(*) FROM audit_events WHERE kind='media_moderation_changed'")).rows[0].count,'1');
});

test('queue removal is not called delivery and attempts only record increases',dbOptions,async t=>{
  const f=await fixture(t);
  const operation=await f.start({action:'upload_file'});
  await f.pool.query(`INSERT INTO pending_scans(id,user_id,file_type,audit_operation_id,audit_parent_event_id)
    VALUES(7,$1,'video',$2,$3)`,[f.userId,operation.id,operation.root_event_id]);
  await f.pool.query('UPDATE pending_scans SET retry_count=retry_count+1 WHERE id=7');
  await f.pool.query('UPDATE pending_scans SET retry_count=retry_count+1 WHERE id=7');
  await f.pool.query('UPDATE pending_scans SET retry_count=retry_count-1 WHERE id=7');
  await f.pool.query('DELETE FROM pending_scans WHERE id=7');
  const events=(await f.pool.query('SELECT * FROM audit_events WHERE operation_id=$1 ORDER BY id',[operation.id])).rows;
  assert.deepEqual(events.map(row=>row.kind),['operation_started','scan_queued','scan_attempt_started','scan_attempt_started','scan_queue_removed']);
  assert.equal(events[3].attempt,2);
  assert.equal(events[4].details.queueId,'7');
  assert.ok(events.every(row=>!row.kind.includes('delivered')));
});

test('queue cancellation settles pending roots but never overwrites a persisted scan outcome',dbOptions,async t=>{
  const f=await fixture(t);
  for(const finished of [false,true]) {
    const operation=await f.start({action:'upload_file',status:'pending'});
    const queueId=finished?2:1;
    await f.pool.query(`INSERT INTO pending_scans(id,user_id,file_type,audit_operation_id,audit_parent_event_id)
      VALUES($1,$2,'video',$3,$4)`,[queueId,f.userId,operation.id,operation.root_event_id]);
    if(finished) await recordAuditEvent(f.pool,{operationId:operation.id,parentEventId:operation.root_event_id,
      kind:'scan_workflow_finished',status:'completed',operationStatus:'completed',reasonCode:'queue_processed'});
    await f.pool.query('DELETE FROM pending_scans WHERE id=$1',[queueId]);
    await recordAuditEvent(f.pool,{operationId:operation.id,kind:'http_response',status:'pending',operationStatus:'pending'});
    const root=(await f.pool.query('SELECT * FROM audit_operations WHERE id=$1',[operation.id])).rows[0];
    assert.equal(root.status,finished?'completed':'cancelled');
    assert.equal(root.reason_code,finished?'queue_processed':'queue_removed_without_scan_outcome');
    const removal=(await f.pool.query("SELECT * FROM audit_events WHERE operation_id=$1 AND kind='scan_queue_removed'",[operation.id])).rows[0];
    assert.equal(removal.status,'observed');
    assert.equal(removal.reason_code,finished?'queue_entry_removed':'queue_removed_without_scan_outcome');
  }
});

test('stopped scans remain failed after queue removal and a late pending response',dbOptions,async t=>{
  const f=await fixture(t);
  const operation=await f.start({action:'upload_file',status:'pending'}),file=randomUUID();
  await f.pool.query(`INSERT INTO stored_files(id,user_id,file_type,moderation_status,audit_operation_id,audit_parent_event_id)
    VALUES($1,$2,'video','pending',$3,$4)`,[file,f.userId,operation.id,operation.root_event_id]);
  await f.pool.query(`INSERT INTO pending_scans(id,user_id,file_type,audit_operation_id,audit_parent_event_id)
    VALUES(1,$1,'video',$2,$3)`,[f.userId,operation.id,operation.root_event_id]);
  const details={moderationStatus:'stopped',frameCount:2,providerCallsUsed:12,providerCallsLimit:12,
    googleVisionCallsUsed:6,googleVisionCallsLimit:6,openAICallsUsed:4,openAICallsLimit:4,
    geminiCallsUsed:2,geminiCallsLimit:2};
  await f.transaction(operation,async client=>{
    await client.query("UPDATE stored_files SET moderation_status='stopped',moderation_details=$2 WHERE id=$1",
      [file,{scanStopped:true,stopped:true,pending:false,blocked:false,reasonCode:'video_scan_budget_exhausted'}]);
    await recordAuditEvent(client,{operationId:operation.id,parentEventId:operation.root_event_id,
      kind:'scan_workflow_finished',status:'failed',operationStatus:'failed',reasonCode:'scan_stopped',details});
    await client.query('DELETE FROM pending_scans WHERE id=1');
  });
  await recordAuditEvent(f.pool,{operationId:operation.id,kind:'http_response',status:'pending',operationStatus:'pending'});
  const root=(await f.pool.query('SELECT * FROM audit_operations WHERE id=$1',[operation.id])).rows[0];
  assert.equal(root.status,'failed');
  assert.equal(root.status_source,'scan_workflow_finished');
  assert.equal(root.reason_code,'scan_stopped');
  const events=(await f.pool.query('SELECT * FROM audit_events WHERE operation_id=$1 ORDER BY id',[operation.id])).rows;
  const moderation=events.find(row=>row.kind==='media_moderation_changed');
  assert.equal(moderation.status,'failed');
  assert.equal(moderation.reason_code,'scan_stopped');
  assert.equal(moderation.details.moderationStatus,'stopped');
  assert.deepEqual(events.find(row=>row.kind==='scan_workflow_finished').details,details);
});

test('message and contact request triggers preserve persistence distinctions and counts',dbOptions,async t=>{
  const f=await fixture(t);
  const operation=await f.start();
  const message=randomUUID();
  await f.pool.query(`INSERT INTO messages(id,sender_id,type,audit_operation_id,audit_parent_event_id)
    VALUES($1,$2,'video',$3,$4)`,[message,f.userId,operation.id,operation.root_event_id]);
  await f.pool.query(`UPDATE messages SET delivery_summary=$2 WHERE id=$1`,[message,
    JSON.stringify({deliveredTo:[{id:randomUUID(),name:'private'}],blockedFor:[{id:randomUUID()},{id:randomUUID()}]})]);
  await f.pool.query(`INSERT INTO message_requests(id,sender_id,type,audit_operation_id,audit_parent_event_id)
    VALUES($1,$2,'video',$3,$4)`,[randomUUID(),f.userId,operation.id,operation.root_event_id]);
  await f.pool.query("UPDATE message_requests SET status='accepted'");
  const events=(await f.pool.query('SELECT * FROM audit_events WHERE operation_id=$1 ORDER BY id',[operation.id])).rows;
  assert.deepEqual(events.map(row=>row.kind),['operation_started','message_persisted','message_delivery_state_changed',
    'contact_request_pending','contact_request_status_changed']);
  assert.deepEqual(events[2].details,{messageType:'video',deliveredCount:1,blockedCount:2});
  assert.equal(events[3].status,'pending');
  assert.equal(events[4].details.nextStatus,'accepted');
});

test('request removal cancels only unresolved roots and preserves explicit recipient acceptance',dbOptions,async t=>{
  const f=await fixture(t);
  for(const resolution of ['removed','accepted','declined']) {
    const operation=await f.start({status:'pending'}),request=randomUUID(),recipient=randomUUID();
    await f.pool.query(`INSERT INTO message_requests(id,sender_id,type,audit_operation_id,audit_parent_event_id)
      VALUES($1,$2,'text',$3,$4)`,[request,f.userId,operation.id,operation.root_event_id]);
    if(resolution==='accepted') await recordAuditEvent(f.pool,{operationId:operation.id,parentEventId:operation.root_event_id,
      kind:'message_request_accepted',executorType:'user',executorId:recipient,status:'completed',operationStatus:'completed'});
    if(resolution==='declined') await f.pool.query("UPDATE message_requests SET status='declined' WHERE id=$1",[request]);
    await f.pool.query('DELETE FROM message_requests WHERE id=$1',[request]);
    await recordAuditEvent(f.pool,{operationId:operation.id,kind:'http_response',status:'pending',operationStatus:'pending'});
    const row=(await f.pool.query('SELECT * FROM audit_operations WHERE id=$1',[operation.id])).rows[0];
    assert.equal(row.status,{removed:'cancelled',accepted:'completed',declined:'blocked'}[resolution]);
    const removal=(await f.pool.query("SELECT * FROM audit_events WHERE operation_id=$1 AND kind='contact_request_removed'",[operation.id])).rows[0];
    assert.equal(removal.status,'observed');
    assert.equal(removal.reason_code,resolution==='removed'?'request_removed_without_acceptance':'request_entry_removed');
    if(resolution==='accepted') {
      const accepted=(await f.pool.query("SELECT * FROM audit_events WHERE operation_id=$1 AND kind='message_request_accepted'",[operation.id])).rows[0];
      assert.equal(accepted.executor_id,recipient);
      assert.notEqual(accepted.executor_id,row.initiator_id);
    }
  }
});

test('message status evidence follows an explicit message link without claiming device acknowledgement',dbOptions,async t=>{
  const f=await fixture(t);
  const operation=await f.start();
  const message=randomUUID(),recipient=randomUUID();
  await f.pool.query(`INSERT INTO messages(id,sender_id,type,audit_operation_id,audit_parent_event_id)
    VALUES($1,$2,'text',$3,$4)`,[message,f.userId,operation.id,operation.root_event_id]);
  await f.pool.query("INSERT INTO message_status VALUES($1,$2,'sent')",[message,recipient]);
  await f.pool.query("UPDATE message_status SET status='delivered'");
  await f.pool.query("UPDATE message_status SET status='delivered'");
  const events=(await f.pool.query("SELECT * FROM audit_events WHERE kind='server_message_status_changed' ORDER BY id")).rows;
  assert.equal(events.length,2);
  assert.equal(events[1].operation_id,operation.id);
  assert.equal(events[1].parent_event_id,operation.root_event_id);
  assert.equal(events[1].target_id,message);
  assert.equal(events[1].status,'observed');
  assert.equal(events[1].reason_code,'server_state_not_device_ack');
  assert.deepEqual(events[1].details,{recipientId:recipient,previousStatus:'sent',nextStatus:'delivered'});
});

test('concurrent event appends preserve the projection count and root parent',dbOptions,async t=>{
  const f=await fixture(t);
  const operation=await f.start();
  await Promise.all(Array.from({length:8},(_,index)=>recordAuditEvent(f.pool,{operationId:operation.id,
    parentEventId:operation.root_event_id,kind:'worker_observation',attempt:index+1})));
  const saved=(await f.pool.query('SELECT * FROM audit_operations WHERE id=$1',[operation.id])).rows[0];
  assert.equal(saved.event_count,'9');
  assert.equal(saved.root_event_id,operation.root_event_id);
});

test('late HTTP results never replace an authoritative completed scan workflow',dbOptions,async t=>{
  const f=await fixture(t);
  for(const ordering of ['http_first','scan_first','concurrent']) {
    const operation=await f.start({action:'upload_file'});
    const http=()=>recordAuditEvent(f.pool,{operationId:operation.id,parentEventId:operation.root_event_id,
      kind:'http_response',status:'pending',operationStatus:'pending',reasonCode:'awaiting_scan'});
    const scan=()=>recordAuditEvent(f.pool,{operationId:operation.id,parentEventId:operation.root_event_id,
      kind:'scan_workflow_finished',status:'blocked',operationStatus:'blocked',reasonCode:'media_not_allowed'});
    if(ordering==='http_first') {await http();await scan();}
    else if(ordering==='scan_first') {await scan();await http();}
    else await Promise.all([scan(),http()]);
    const row=(await f.pool.query('SELECT * FROM audit_operations WHERE id=$1',[operation.id])).rows[0];
    assert.equal(row.status,'blocked',ordering);
    assert.equal(row.status_source,'scan_workflow_finished',ordering);
    assert.equal(row.reason_code,'media_not_allowed',ordering);
    assert.equal(row.event_count,'3');
  }
});

test('an HTTP projection waiting on a scan transaction keeps the committed scan outcome',dbOptions,async t=>{
  const f=await fixture(t);
  const operation=await f.start({action:'upload_file'});
  const client=await f.pool.connect();
  let waiting;
  try {
    await client.query('BEGIN');
    await recordAuditEvent(client,{operationId:operation.id,kind:'scan_workflow_finished',status:'completed',operationStatus:'completed'});
    waiting=recordAuditEvent(f.pool,{operationId:operation.id,kind:'http_response',status:'pending',operationStatus:'pending'});
    await new Promise(resolve=>setTimeout(resolve,20));
    await client.query('COMMIT');
    await waiting;
  } catch(error) {await client.query('ROLLBACK');throw error;}
  finally {client.release();}
  const row=(await f.pool.query('SELECT * FROM audit_operations WHERE id=$1',[operation.id])).rows[0];
  assert.equal(row.status,'completed');
  assert.equal(row.status_source,'scan_workflow_finished');
});

test('tagged insert rolls back when its audit parent belongs to another operation',dbOptions,async t=>{
  const f=await fixture(t);
  const first=await f.start(),second=await f.start();
  await assert.rejects(f.pool.query(`INSERT INTO messages(id,sender_id,type,audit_operation_id,audit_parent_event_id)
    VALUES($1,$2,'text',$3,$4)`,[randomUUID(),f.userId,first.id,second.root_event_id]),error=>error.code==='23503');
  assert.equal((await f.pool.query('SELECT count(*) FROM messages')).rows[0].count,'0');
  assert.equal((await f.pool.query('SELECT count(*) FROM audit_events')).rows[0].count,'2');
});

test('filter forwarding uses explicit columns or transaction context with boolean snapshots only',dbOptions,async t=>{
  const f=await fixture(t);
  const operation=await f.start({action:'filter_change'});
  const details={before:{men:true,video:true,body:'secret'},after:{men:false,video:false},
    body:'private message',url:'https://private',reasonCode:'policy_change'};
  await f.pool.query(`INSERT INTO filter_audit_events(kind,details) VALUES('filter_baseline',$1)`,[details]);
  assert.equal((await f.pool.query('SELECT count(*) FROM audit_events')).rows[0].count,'1');
  const client=await f.pool.connect();
  try {
    await client.query('BEGIN');
    await client.query("SELECT set_config('app.audit_operation_id',$1,true),set_config('app.audit_parent_event_id',$2,true)",
      [operation.id,operation.root_event_id]);
    await client.query(`INSERT INTO filter_audit_events(kind,scope_type,details) VALUES('filter_changed','general',$1)`,[details]);
    await client.query('COMMIT');
  } finally {client.release();}
  await f.pool.query(`INSERT INTO filter_audit_events(kind,audit_operation_id,audit_parent_event_id,details)
    VALUES('decision_blocked',$1,$2,$3)`,[operation.id,operation.root_event_id,details]);
  const events=(await f.pool.query("SELECT * FROM audit_events WHERE source='filter_db' ORDER BY id")).rows;
  assert.equal(events.length,2);
  assert.equal(events[0].operation_id,operation.id);
  assert.equal(events[0].parent_event_id,operation.root_event_id);
  assert.deepEqual(events[0].details,{reasonCode:'policy_change',beforeMen:true,afterMen:false,beforeVideo:true,afterVideo:false});
  assert.equal(events[1].status,'blocked');
});

test('operation/event keyset pagination is stable and filters use snapshot short IDs',dbOptions,async t=>{
  const f=await fixture(t);
  const ids=[];
  for(let index=0;index<5;index++) ids.push((await f.start()).id);
  const first=await f.call('/api/admin/audit/operations',{query:{limit:'2',userId:'42'}});
  assert.equal(first.statusCode,200);
  assert.equal(first.body.operations.length,2);
  assert.ok(first.body.nextCursor);
  const inserted=await f.start();
  const second=await f.call('/api/admin/audit/operations',{query:{limit:'2',userId:'42',before:first.body.nextCursor}});
  const third=await f.call('/api/admin/audit/operations',{query:{limit:'2',userId:'42',before:second.body.nextCursor}});
  const read=[...first.body.operations,...second.body.operations,...third.body.operations].map(row=>row.id);
  assert.equal(new Set(read).size,5);
  assert.ok(!read.includes(inserted.id));
  assert.deepEqual(new Set(read),new Set(ids));
  assert.equal(third.body.nextCursor,null);
  const events=await f.call('/api/admin/audit/operations/:id/events',{params:{id:ids[0]}});
  assert.equal(events.body.events.length,1);
  assert.equal(events.body.events[0].operation_id,ids[0]);
  assert.equal((await f.call('/api/admin/audit/operations/:id/events',{params:{id:randomUUID()}})).statusCode,404);
});

test('operation target filters find explicit child evidence with both predicates on the same event',dbOptions,async t=>{
  const f=await fixture(t);
  const matching=await f.start({action:'upload_file'}),unrelated=await f.start({action:'upload_file'});
  const file=randomUUID();
  for(let index=0;index<2;index++) await recordAuditEvent(f.pool,{operationId:matching.id,
    parentEventId:matching.root_event_id,kind:'media_stored',targetType:'file',targetId:file});
  await recordAuditEvent(f.pool,{operationId:unrelated.id,kind:'message_persisted',targetType:'message',targetId:file});
  await recordAuditEvent(f.pool,{operationId:unrelated.id,kind:'media_stored',targetType:'file',targetId:randomUUID()});
  const result=await f.call('/api/admin/audit/operations',{query:{targetType:'file',targetId:file}});
  assert.deepEqual(result.body.operations.map(row=>row.id),[matching.id]);
  const flat=await f.call('/api/admin/audit/events',{query:{targetType:'file',targetId:file}});
  assert.equal(flat.body.events.length,2);
  assert.ok(flat.body.events.every(row=>row.operation_id===matching.id));
});

test('to timestamp is exclusive for operation and flat event filters',dbOptions,async t=>{
  const f=await fixture(t);
  const operation=await f.start();
  const before=await f.call('/api/admin/audit/operations',{query:{to:operation.created_at.toISOString()}});
  assert.equal(before.body.operations.length,0);
  const first=(await f.pool.query('SELECT created_at FROM audit_events WHERE id=$1',[operation.root_event_id])).rows[0];
  const events=await f.call('/api/admin/audit/events',{query:{to:first.created_at.toISOString()}});
  assert.equal(events.body.events.length,0);
});

test('routes reject missing authentication and malformed filters without leaking errors',dbOptions,async t=>{
  const f=await fixture(t);
  assert.equal((await f.call('/api/admin/audit/events',{user:null})).statusCode,401);
  assert.equal((await f.call('/api/admin/audit/operations',{query:{targetId:'invalid'}})).statusCode,400);
  assert.equal((await f.call('/api/admin/audit/events',{query:{before:'invalid'}})).statusCode,400);
  const catalog=await f.call('/api/admin/audit/catalog');
  assert.ok(catalog.body.recordingStartedAt);
  assert.ok(Array.isArray(catalog.body.coverage));
  assert.ok(catalog.body.actions.some(row=>row.action==='audit_export'));
  assert.deepEqual(catalog.body.defaultColumnFilters,{display_action:{values:['media:video','media:image'],exclude:false}});
  assert.equal(catalog.headers['Cache-Control'],'no-store');
});

test('CSV export requires bounded dates, uses safe cells and records export action',dbOptions,async t=>{
  const f=await fixture(t);
  await f.pool.query('UPDATE users SET name=$1 WHERE id=$2',['=formula',f.userId]);
  await f.start();
  assert.equal((await f.call('/api/admin/audit/export.csv')).statusCode,400);
  const from=new Date(Date.now()-3600000).toISOString(),to=new Date(Date.now()+3600000).toISOString();
  const response=await f.call('/api/admin/audit/export.csv',{query:{from,to}});
  assert.equal(response.statusCode,200);
  assert.match(response.body,/"'=formula"/);
  assert.equal(response.headers['X-Audit-Export-Truncated'],'false');
  assert.equal(response.headers['X-Audit-Export-Count'],'1');
  const exported=(await f.pool.query("SELECT * FROM audit_operations WHERE action='audit_export'")).rows;
  assert.equal(exported.length,1);
  assert.equal(exported[0].initiator_id,f.userId);
  assert.equal(exported[0].status,'completed');
});
