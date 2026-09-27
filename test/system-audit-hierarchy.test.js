'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const {randomUUID}=require('node:crypto');
const {Client}=require('pg');
const {readFilters,buildQuery,buildFilterOptionsQuery,registerSystemAuditRoutes}=require('../server/system-audit');

const dbOptions={skip:process.env.RUN_DB_TESTS!=='1'};
const parse=(columnFilters={},extra={})=>readFilters({scope:'user',match:'chain',...extra,
  columnFilters:JSON.stringify(columnFilters)});

test('hierarchy query options are explicit, validated and default queries remain unchanged',()=>{
  assert.equal(readFilters({}).scope,undefined);
  assert.equal(readFilters({}).match,undefined);
  assert.deepEqual(readFilters({scope:'all',match:'root'}),{mode:'operations',columnFilters:{},scope:'all',match:'root',limit:50});
  for (const name of ['scope','match']) for (const value of ['',null,[],{},'unknown'])
    assert.throws(()=>readFilters({[name]:value}),{status:400});
  const normal=buildQuery(readFilters({}));
  assert.equal(normal.text,'SELECT o.* FROM audit_operations o ORDER BY o.created_at DESC,o.id DESC LIMIT $1');
  const user=buildQuery(parse());
  assert.match(user.text,/root_actor\.id=o\.root_event_id/);
  assert.match(user.text,/lower\(root_actor\.executor_id\)=o\.initiator_id::text/);
  assert.match(user.text,/executor_type IN \('user','admin','client'\)/);
  assert.match(user.text,/o\.action NOT IN \('report_message_read','register_device'\)/);
});

test('chain positive predicates share one evidence row and exclusions apply across the whole chain',()=>{
  const attack="x') OR TRUE --";
  const query=buildQuery(parse({action:{values:['scan_completed']},status:{values:['failed'],exclude:true},
    reason_code:{values:[attack,null]},source:{values:['scan_worker']}},{targetType:'file',targetId:randomUUID()}));
  assert.ok(!query.text.includes(attack));
  assert.match(query.text,/NOT EXISTS\(SELECT 1 FROM \(SELECT o\.action/);
  assert.match(query.text,/chain_excluded\.status = ANY/);
  assert.match(query.text,/chain_match\.action = ANY/);
  assert.match(query.text,/chain_match\.source = ANY/);
  assert.match(query.text,/chain_match\.target_type=/);
  assert.match(query.text,/chain_match\.target_id=/);
  assert.match(query.text,/linked\.id IS DISTINCT FROM o\.root_event_id/);
  assert.ok(query.text.indexOf('LIMIT $')<query.text.indexOf('CROSS JOIN LATERAL'));
});

test('hierarchy facet SQL omits only its own filter and uses child-kind labels',()=>{
  const parsed=parse({action:{values:[]},source:{values:['scan_worker']},status:{values:['failed'],exclude:true}});
  const options=buildFilterOptionsQuery(parsed,'action');
  assert.doesNotMatch(options.text,/FALSE/);
  assert.match(options.text,/chain_option\.source = ANY/);
  assert.match(options.text,/chain_excluded\.status = ANY/);
  assert.match(options.text,/CROSS JOIN LATERAL/);
  assert.ok(JSON.parse(options.values.at(-1)).operation_started);
  const identity=buildFilterOptionsQuery(parsed,'initiator_id');
  assert.match(identity.text,/WHERE FALSE AND/);
  assert.doesNotMatch(identity.text,/chain_option/);
});

async function fixture(t) {
  const db=new Client({connectionString:process.env.DATABASE_URL,
    ssl:process.env.DB_SSL==='true'?{rejectUnauthorized:process.env.DB_REJECT_UNAUTHORIZED!=='false'}:false});
  await db.connect();
  const schema=`audit_hierarchy_test_${randomUUID().replaceAll('-','')}`;
  await db.query(`CREATE SCHEMA "${schema}"`);
  t.after(async()=>{await db.query(`DROP SCHEMA "${schema}" CASCADE`);await db.end();});
  await db.query(`SET search_path TO "${schema}";
    CREATE TABLE users(id uuid PRIMARY KEY,name text,short_id integer);
    CREATE TABLE audit_metadata(key text,created_at timestamptz DEFAULT now());
    INSERT INTO audit_metadata(key) VALUES('recording_started');
    CREATE TABLE audit_operations(id uuid PRIMARY KEY,created_at timestamptz DEFAULT now(),updated_at timestamptz DEFAULT now(),
      action text,category text,initiator_id uuid,initiator_name text,initiator_short_id text,target_type text,target_id uuid,
      source text,status text,status_source text,reason_code text,root_event_id bigint,event_count bigint DEFAULT 0,duration_ms bigint DEFAULT 0,
      media_type text,capture_kind text,recipient_type text,recipient_id uuid,recipient_name text,recipient_short_id text);
    CREATE TABLE audit_events(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,operation_id uuid,parent_event_id bigint,
      created_at timestamptz DEFAULT now(),kind text,executor_type text,executor_id text,executor_name text,source text,status text,
      operation_status text,reason_code text,target_type text,target_id uuid,attempt integer DEFAULT 1,details jsonb DEFAULT '{}'::jsonb);
    CREATE INDEX ON audit_events(operation_id,id);`);
  const actor=randomUUID();
  await db.query('INSERT INTO users VALUES($1,$2,42)',[actor,'Test Admin']);
  const event=async(operation,data={})=>{
    const row={operation_id:operation.id,created_at:'2026-09-24T10:00:01Z',kind:'media_stored',executor_type:'system',
      executor_id:'api',source:'storage',status:'completed',...data};
    const columns=Object.keys(row);
    return (await db.query(`INSERT INTO audit_events(${columns.join(',')}) VALUES(${columns.map((_,i)=>'$'+(i+1)).join(',')}) RETURNING *`,Object.values(row))).rows[0];
  };
  const operation=async(data={},root={})=>{
    const row={id:randomUUID(),created_at:'2026-09-24T10:00:00Z',action:'upload_file',category:'media',initiator_id:actor,
      initiator_name:'Test Admin',initiator_short_id:'42',source:'http',status:'completed',event_count:'1',duration_ms:'150',...data};
    const columns=Object.keys(row);
    await db.query(`INSERT INTO audit_operations(${columns.join(',')}) VALUES(${columns.map((_,i)=>'$'+(i+1)).join(',')})`,Object.values(row));
    const first=await event(row,{created_at:row.created_at,kind:'operation_started',executor_type:'user',executor_id:actor,
      source:row.source,status:'running',...root});
    await db.query('UPDATE audit_operations SET root_event_id=$2 WHERE id=$1',[row.id,first.id]);
    return {...row,root_event_id:first.id};
  };
  const select=async(filters=parse())=>(await db.query(buildQuery(filters))).rows;
  const options=async(filters,column,search='')=>(await db.query(buildFilterOptionsQuery(filters,column,search))).rows;
  const routes={};
  registerSystemAuditRoutes({get:(path,...handlers)=>{routes[path]=handlers;},delete(){}},
    {getPool:async()=>db,adminMiddleware:(_req,_res,next)=>next()});
  const call=async(path,query={},params={})=>{
    const res={statusCode:200,headers:{},status(code){this.statusCode=code;return this;},
      set(key,value){this.headers[key]=value;return this;},json(value){this.body=value;return this;},send(value){this.body=value;return this;}};
    await routes[path].at(-1)({query,params,user:{id:actor}},res);
    return res;
  };
  return {db,actor,operation,event,select,options,call};
}

test('user scope requires the exact initiating actor and removes known automatic telemetry only',dbOptions,async t=>{
  const f=await fixture(t);
  const user=await f.operation(),admin=await f.operation({}, {executor_type:'admin'}),client=await f.operation({}, {executor_type:'client',executor_id:f.actor.toUpperCase()});
  for (const executor_type of ['system','worker','unknown','provider']) await f.operation({}, {executor_type});
  await f.operation({}, {executor_id:randomUUID()});
  await f.operation({initiator_id:null});
  await f.operation({action:'report_message_read'});
  await f.operation({action:'register_device'});
  const mismatched=await f.operation();
  await f.db.query('UPDATE audit_operations SET root_event_id=$2 WHERE id=$1',[mismatched.id,user.root_event_id]);
  const ids=(await f.select()).map(row=>row.id).sort();
  assert.deepEqual(ids,[user.id,admin.id,client.id].sort());
  assert.equal((await f.select(readFilters({}))).length,12);
  assert.equal((await f.select(readFilters({}, {mode:'events'}))).length,12);
});

test('chain positive filters require all conditions on one root or one explicitly correlated child',dbOptions,async t=>{
  const f=await fixture(t),wanted=await f.operation(),split=await f.operation(),root=await f.operation({action:'scan_completed',source:'scanner',status:'failed'});
  await f.event(wanted,{kind:'scan_completed',source:'scanner',status:'failed'});
  await f.event(split,{kind:'scan_completed',source:'storage',status:'completed'});
  await f.event(split,{kind:'media_stored',source:'scanner',status:'failed'});
  const constraints={action:{values:['scan_completed']},source:{values:['scanner']},status:{values:['failed']}};
  assert.deepEqual((await f.select(parse(constraints))).map(row=>row.id).sort(),[wanted.id,root.id].sort());
  assert.deepEqual((await f.select(parse({}, {action:'scan_completed',source:'scanner',status:'failed'}))).map(row=>row.id),[root.id]);
  assert.deepEqual((await f.select(parse(constraints,{action:'upload_file'}))).map(row=>row.id),[wanted.id]);
  assert.deepEqual((await f.select(parse({action:{values:['operation_started']}}))).map(row=>row.id),[]);
  assert.deepEqual((await f.select(parse({action:{values:[]}}))).map(row=>row.id),[]);
  assert.equal((await f.select(parse({action:{values:[],exclude:true}}))).length,3);
});

test('chain target type and ID cannot be assembled from separate children or root and child',dbOptions,async t=>{
  const f=await fixture(t),target=randomUUID();
  const wanted=await f.operation(),split=await f.operation({target_type:'file'}),foreign=await f.operation();
  await f.event(wanted,{target_type:'file',target_id:target});
  await f.event(split,{target_type:'message',target_id:target});
  await f.event(split,{target_type:'file',target_id:randomUUID()});
  await f.event(foreign,{target_type:'file',target_id:target,source:'other'});
  assert.deepEqual((await f.select(parse({}, {targetType:'file',targetId:target,source:'storage'}))).map(row=>row.id),[wanted.id]);
  assert.deepEqual((await f.select(parse({target_type:{values:['file']},target_id:{values:[target]},source:{values:['storage']}}))).map(row=>row.id),[wanted.id]);
});

test('chain exclusions cannot be neutralized by another child, and NULL has explicit semantics',dbOptions,async t=>{
  const f=await fixture(t),safe=await f.operation({reason_code:'allowed'}),failed=await f.operation({reason_code:'allowed'}),blank=await f.operation();
  await f.event(safe,{reason_code:'allowed'});
  await f.event(failed,{status:'failed',reason_code:'blocked'});
  await f.event(failed,{status:'completed',reason_code:'allowed'});
  await f.event(blank,{reason_code:'allowed'});
  assert.deepEqual((await f.select(parse({status:{values:['failed'],exclude:true}}))).map(row=>row.id).sort(),[safe.id,blank.id].sort());
  assert.deepEqual((await f.select(parse({reason_code:{values:['blocked',null],exclude:true}}))).map(row=>row.id),[safe.id]);
  assert.deepEqual((await f.select(parse({reason_code:{values:[null]}}))).map(row=>row.id),[blank.id]);
  assert.deepEqual((await f.select(parse({reason_code:{values:['blocked'],exclude:true}}))).map(row=>row.id).sort(),[safe.id,blank.id].sort());
  assert.deepEqual((await f.select(parse({reason_code:{values:[null],exclude:true}}))).map(row=>row.id).sort(),[safe.id,failed.id].sort());
});

test('date, identity and numerical constraints remain tied to the primary operation',dbOptions,async t=>{
  const f=await fixture(t),wanted=await f.operation(),outside=await f.operation({created_at:'2026-09-23T10:00:00Z',event_count:'10'});
  await f.event(wanted,{created_at:'2026-09-25T11:00:00Z'});
  await f.event(outside,{created_at:'2026-09-24T10:00:00Z'});
  assert.deepEqual((await f.select(parse({created_at:{from:'2026-09-24T00:00:00Z',to:'2026-09-25T00:00:00Z'},
    initiator_id:{values:[f.actor]},event_count:{max:'1'},duration_ms:{min:'150',max:'150'}}))).map(row=>row.id),[wanted.id]);
  assert.deepEqual((await f.select(parse({}, {from:'2026-09-24T00:00:00Z',to:'2026-09-25T00:00:00Z',userId:'42'}))).map(row=>row.id),[wanted.id]);
});

test('summary counts real children only and reports latest recorded evidence without invented progress',dbOptions,async t=>{
  const f=await fixture(t),operation=await f.operation({event_count:'999'}),empty=await f.operation();
  await f.event(operation,{kind:'scan_queued',status:'pending'});
  await f.event(operation,{kind:'scan_attempt_started',status:'running'});
  await f.event(operation,{kind:'operation_started',status:'observed'});
  const last=await f.event(operation,{kind:'scan_workflow_finished',status:'completed',created_at:'2026-09-24T10:00:02Z'});
  const rows=await f.select(),found=rows.find(row=>row.id===operation.id),none=rows.find(row=>row.id===empty.id);
  assert.equal(found.sub_event_count,'4');
  assert.equal(found.latest_event_kind,last.kind);
  assert.equal(found.latest_event_status,'completed');
  assert.equal(found.latest_event_at.toISOString(),'2026-09-24T10:00:02.000Z');
  assert.equal(none.sub_event_count,'0');
  assert.equal(none.latest_event_kind,null);
  assert.equal(Object.hasOwn(found,'expected_step_count'),false);
  assert.equal(Object.hasOwn(found,'active_step_count'),false);
});

test('hierarchy facets list only compatible matching evidence and preserve root context and exclusions',dbOptions,async t=>{
  const f=await fixture(t),wanted=await f.operation(),other=await f.operation(),automatic=await f.operation({action:'register_device'});
  await f.event(wanted,{kind:'scan_completed',source:'scanner',status:'failed'});
  await f.event(wanted,{kind:'media_stored',source:'storage',status:'completed'});
  await f.event(other,{kind:'decision_blocked',source:'scanner',status:'blocked'});
  await f.event(automatic,{kind:'device_registered',source:'scanner',status:'failed'});
  const constraints=parse({action:{values:[]},source:{values:['scanner']},status:{values:['failed']}});
  assert.deepEqual((await f.options(constraints,'action')).map(row=>row.value),['scan_completed']);
  assert.deepEqual((await f.options(parse({action:{values:['scan_completed']}}),'source')).map(row=>row.value),['scanner']);
  assert.equal((await f.options(parse({action:{values:['scan_completed']}}),'initiator_id'))[0].value,f.actor);
  assert.deepEqual((await f.options(parse({source:{values:['scanner']},status:{values:['failed'],exclude:true}}),'action'))
    .map(row=>row.value),['decision_blocked']);
  assert.deepEqual((await f.options(parse({source:{values:['scanner']},status:{values:['failed']}},{action:'upload_file'}),'action'))
    .map(row=>row.value),['scan_completed']);
  assert.deepEqual((await f.options(parse({action:{values:['media_stored']}}),'reason_code')).map(row=>row.value),[null]);
});

test('operation pagination, CSV and child pagination retain hierarchy scope without modifying evidence',dbOptions,async t=>{
  const f=await fixture(t),first=await f.operation(),second=await f.operation(),automatic=await f.operation({action:'register_device'});
  for (const operation of [first,second,automatic]) await f.event(operation,{kind:'scan_completed',source:'scanner'});
  const query={scope:'user',match:'chain',action:'upload_file',columnFilters:JSON.stringify({action:{values:['scan_completed']}}),
    from:'2026-09-24T00:00:00Z',to:'2026-09-25T00:00:00Z'};
  const page1=await f.call('/api/admin/audit/operations',{...query,limit:'1'});
  assert.equal(page1.statusCode,200);
  assert.ok(page1.body.nextCursor);
  const page2=await f.call('/api/admin/audit/operations',{...query,limit:'1',before:page1.body.nextCursor});
  assert.equal(page2.body.nextCursor,null);
  assert.deepEqual([...page1.body.operations,...page2.body.operations].map(row=>row.id).sort(),[first.id,second.id].sort());
  const exported=await f.call('/api/admin/audit/export.csv',{...query,mode:'operations'});
  assert.equal(exported.statusCode,200);
  assert.equal(exported.headers['X-Audit-Export-Count'],'2');
  assert.ok(exported.body.includes('"sub_event_count","latest_event_kind","latest_event_status","latest_event_at"'));
  assert.ok(exported.body.includes(first.id));
  assert.ok(!exported.body.includes(automatic.id));
  const child1=await f.call('/api/admin/audit/operations/:id/events',{limit:'1'},{id:first.id});
  const child2=await f.call('/api/admin/audit/operations/:id/events',{limit:'1',before:child1.body.nextCursor},{id:first.id});
  assert.ok(BigInt(child1.body.events[0].id)>BigInt(child2.body.events[0].id));
  assert.equal(child2.body.events[0].id,first.root_event_id);
});

test('step view separates action and kind, ranks before filters and pagination, and embeds the first matching step',dbOptions,async t=>{
  const f=await fixture(t),root=await f.operation({action:'upload_file'}),empty=await f.operation({action:'send_message'});
  const second=await f.event(root,{kind:'scan_queued',created_at:'2026-09-24T10:00:02Z',status:'pending'});
  const first=await f.event(root,{kind:'media_stored',created_at:'2026-09-24T10:00:01Z'});
  const third=await f.event(root,{kind:'provider_call_finished',created_at:'2026-09-24T10:00:03Z',details:{checkType:'modesty',checkOutcome:'passed'}});
  const operations='/api/admin/audit/operations',children='/api/admin/audit/operations/:id/events';
  const base={scope:'user',match:'items',steps:'1'};
  const response=await f.call(operations,base);assert.equal(response.statusCode,200);
  const group=response.body.operations.find(row=>row.id===root.id);
  assert.equal(group.first_sub_event.id,first.id);assert.equal(group.first_sub_event.sub_event_index,'1');
  assert.equal(group.first_sub_event.sub_event_total,'3');assert.equal(group.sub_event_count,'3');
  assert.equal(response.body.operations.find(row=>row.id===empty.id).first_sub_event,null);
  const filters=JSON.stringify({action:{values:['upload_file']},kind:{values:['scan_queued']}});
  const filtered=await f.call(operations,{...base,columnFilters:filters});
  assert.equal(filtered.statusCode,200);assert.equal(filtered.body.operations.length,1);
  assert.equal(filtered.body.operations[0].first_sub_event.id,second.id);
  assert.equal(filtered.body.operations[0].first_sub_event.sub_event_index,'2');
  assert.equal(filtered.body.operations[0].first_sub_event.sub_event_total,'3');
  const wrong=await f.call(operations,{...base,columnFilters:JSON.stringify({action:{values:['scan_queued']}})});
  assert.deepEqual(wrong.body.operations,[]);
  const options=await f.options(readFilters({...base,columnFilters:filters}),'kind');
  assert.deepEqual(options.map(row=>row.value),['media_stored','provider_call_finished','scan_queued']);
  const checked=await f.call(operations,{...base,columnFilters:JSON.stringify({check_type:{values:['modesty']}})});
  assert.equal(checked.body.operations[0].first_sub_event.id,third.id);
  assert.equal(checked.body.operations[0].first_sub_event.check_type,'modesty');
  const paging={steps:'1',sort:'created_at',direction:'asc',limit:'1'};
  const page1=await f.call(children,paging,{id:root.id});assert.equal(page1.statusCode,200);
  assert.equal(page1.body.events[0].id,first.id);
  const page2=await f.call(children,{...paging,before:page1.body.nextCursor},{id:root.id});
  assert.equal(page2.body.events[0].id,second.id);assert.equal(page2.body.events[0].sub_event_index,'2');
  const page3=await f.call(children,{...paging,before:page2.body.nextCursor},{id:root.id});
  assert.equal(page3.body.events[0].id,third.id);assert.equal(page3.body.events[0].sub_event_index,'3');assert.equal(page3.body.nextCursor,null);
  const subset=await f.call(children,{...paging,columnFilters:JSON.stringify({kind:{values:['scan_queued']}})},{id:root.id});
  assert.equal(subset.body.events[0].sub_event_index,'2');assert.equal(subset.body.events[0].sub_event_total,'3');
  const sorted=await f.call(operations,{...base,sort:'kind',direction:'asc'});assert.equal(sorted.statusCode,200);
});

test('collapsed outcomes retain current scan evidence across filters and duplicate terminal records without reusing older attempts',dbOptions,async t=>{
  const f=await fixture(t),op=await f.operation({status:'failed',status_source:'scan_workflow_finished',reason_code:'scan_stopped'});
  const first=await f.event(op,{kind:'upload_context',status:'completed'});
  await f.event(op,{kind:'scan_attempt_started',status:'running'});
  const detailed=await f.event(op,{kind:'scan_workflow_finished',status:'failed',operation_status:'failed',reason_code:'scan_incomplete',details:{providerCallsUsed:29,providerCallsLimit:36,secret:'must not be exposed'}});
  const generic=await f.event(op,{kind:'scan_workflow_finished',status:'failed',operation_status:'failed',reason_code:'scan_stopped'});
  await f.event(op,{kind:'scan_queue_removed',status:'completed'});
  const read=async extra=>{
    const result=await f.call('/api/admin/audit/operations',{steps:'1',...extra});assert.equal(result.statusCode,200);return result.body.operations.find(row=>row.id===op.id);
  };
  let row=await read({columnFilters:JSON.stringify({kind:{values:['upload_context']}})});
  assert.equal(row.first_sub_event.id,first.id);assert.equal(row.first_sub_event.status,'completed');assert.equal(row.status,'failed');
  assert.equal(row.outcome_event.id,generic.id);assert.equal(row.scan_summary.id,detailed.id);assert.equal(row.scan_summary.reason_code,'scan_incomplete');
  assert.deepEqual(row.scan_summary.details,{providerCallsUsed:29,providerCallsLimit:36});
  // A new attempt invalidates older counts, even before an updated aggregate is observed.
  await f.event(op,{kind:'scan_attempt_started',status:'running'});
  row=await read();assert.equal(row.scan_summary,null);
  const retried=await f.event(op,{kind:'scan_workflow_finished',status:'failed',operation_status:'failed',reason_code:'scan_stopped'});
  row=await read();assert.equal(row.outcome_event.id,retried.id);assert.equal(row.scan_summary,null);
  // A later successful completion supersedes the earlier failed attempt.
  await f.event(op,{kind:'scan_workflow_finished',status:'completed',operation_status:'completed',reason_code:'queue_processed'});
  await f.db.query("UPDATE audit_operations SET status='completed',reason_code='queue_processed' WHERE id=$1",[op.id]);
  row=await read();assert.equal(row.status,'completed');assert.equal(row.scan_summary,null);assert.equal(row.outcome_event.status,'completed');
  const empty=await f.operation({status:'pending',status_source:'operation_started'});
  const result=await f.call('/api/admin/audit/operations',{steps:'1'});assert.equal(result.body.operations.find(row=>row.id===empty.id).scan_summary,null);
});

test('initiator and executor filters, facets and sorting retain their separate identities',dbOptions,async t=>{
 const f=await fixture(t),root=await f.operation(),other=await f.operation({initiator_id:randomUUID()});
 const api=await f.event(root,{kind:'upload_context',executor_type:'system',executor_id:'api',executor_name:null});
 const worker=await f.event(root,{kind:'scan_workflow_finished',executor_type:'worker',executor_id:'pending_scans',executor_name:'Scanner'});
 await f.event(other,{executor_type:'system',executor_id:'api'});
 const base={steps:'1',match:'items',columnFilters:JSON.stringify({initiator_id:{values:[f.actor]},executor_id:{values:['api']}})};
 const result=await f.call('/api/admin/audit/operations',base);assert.equal(result.statusCode,200);assert.equal(result.body.operations.length,1);
 assert.equal(result.body.operations[0].id,root.id);assert.equal(result.body.operations[0].first_sub_event.id,api.id);
 const child=await f.call('/api/admin/audit/operations/:id/events',{...base,sort:'initiator_id',direction:'asc'},{id:root.id});
 assert.equal(child.statusCode,200);assert.deepEqual(child.body.events.map(e=>e.id),[api.id]);assert.equal(child.body.events[0].initiator_id,f.actor);
 const options=await f.options(readFilters(base),'executor_id');assert.deepEqual(options.map(o=>o.value),['api','pending_scans']);
 const initiators=await f.options(readFilters(base,{mode:'events'}),'initiator_id');assert.ok(initiators.some(o=>o.value===f.actor));
 const sorted=await f.call('/api/admin/audit/operations',{steps:'1',sort:'executor_id',direction:'asc',limit:'1'});assert.equal(sorted.statusCode,200);assert.ok(sorted.body.nextCursor);
 const next=await f.call('/api/admin/audit/operations',{steps:'1',sort:'executor_id',direction:'asc',limit:'1',before:sorted.body.nextCursor});assert.equal(next.statusCode,200);assert.notEqual(next.body.operations[0].id,sorted.body.operations[0].id);
});

test('event elapsed context and total duration come from the whole operation, independent of child filters',dbOptions,async t=>{
 const f=await fixture(t),root=await f.operation({duration_ms:'155000'});
 const first=await f.event(root,{kind:'upload_context',created_at:'2026-09-24T10:00:01Z'});
 await f.event(root,{kind:'scan_workflow_finished',created_at:'2026-09-24T10:02:35Z'});
 const result=await f.call('/api/admin/audit/operations/:id/events',{steps:'1',columnFilters:JSON.stringify({kind:{values:['upload_context']},duration_ms:{min:'150000',max:'160000'}}),sort:'duration_ms',direction:'asc'},{id:root.id});
 assert.equal(result.statusCode,200);assert.equal(result.body.events.length,1);
 assert.equal(result.body.events[0].id,first.id);assert.equal(String(result.body.events[0].operation_duration_ms),'155000');
 assert.equal(new Date(result.body.events[0].operation_created_at).toISOString(),'2026-09-24T10:00:00.000Z');
 const excluded=await f.call('/api/admin/audit/events',{columnFilters:JSON.stringify({duration_ms:{max:'154999'}})});assert.equal(excluded.statusCode,200);assert.equal(excluded.body.events.length,0);
});
