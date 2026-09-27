"use strict";
const test=require('node:test'),assert=require('node:assert/strict'),{randomUUID}=require('node:crypto'),{Client}=require('pg');
const {readFilters,buildQuery,buildFirstStepQuery,buildFilterOptionsQuery,registerSystemAuditRoutes}=require('../server/system-audit');
const {COST_SQL,COST_FIELDS}=require('../server/audit-costs');
const {estimatedCost,priceSnapshot}=require('../server/provider-usage-log');
const {parseFx}=require('../server/audit-fx');
const dbOptions={skip:process.env.RUN_DB_TESTS!=='1'};
test('pricing discounts cached input, includes thinking once and never turns missing usage into zero',()=>{
 const price=priceSnapshot('openai','gpt-4.1-mini-2025-04-14','modesty');
 assert.equal(estimatedCost(price,{inputTokens:1000,cachedInputTokens:600,outputTokens:100},0,false),0.00038);
 assert.equal(estimatedCost(price,{},0,false,false),null);
 assert.equal(estimatedCost({},null,0,true,false),0);
 assert.equal(estimatedCost({unit:0.0015},{},1,false,false,'failed'),null);
 assert.equal(estimatedCost({input:1,output:2},{inputTokens:100,outputTokens:20,thoughtTokens:30},0,false),0.0002);
 assert.equal(estimatedCost({input:1,output:2},{inputTokens:100,cachedInputTokens:10},0,false),null);
});
test('FX parser and decimal filters reject invalid values',()=>{
 assert.equal(parseFx({exchangeRates:[{key:'USD',unit:1,currentExchangeRate:3.033,lastUpdate:'2026-09-25T00:00:00Z'}]}).rate,3.033);
 assert.throws(()=>parseFx({exchangeRates:[]}));
 assert.doesNotThrow(()=>readFilters({columnFilters:JSON.stringify({cost_ils:{min:'0.000001',max:'2.5'}})}));
 for(const v of ['-1','Infinity','1e2',"1;DROP TABLE users"])
  assert.throws(()=>readFilters({columnFilters:JSON.stringify({cost_ils:{min:v}})}),{status:400});
});
async function record(f,root,{cost=0.0001,provider='openai',usage=true,input=100,output=20,thought=0,cached=0,direct=true,cacheHit=false}={}){
 const request=randomUUID();await f.db.query(`INSERT INTO moderation_provider_calls(request_id,provider,model,operation,workflow,status,input_tokens,output_tokens,thought_tokens,total_tokens,usage_reported,cache_hit,estimated_cost_usd,audit_operation_id,cached_input_tokens,cost_basis)
 VALUES($1,$2,'test-model','modesty','test','completed',$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)`,[request,provider,input,output,thought,input+output+thought,usage,cacheHit,cost,direct?root.id:null,cached,{fxRate:3,fxDate:'2026-09-25'}]);
 return f.event(root.id,{executor_type:'provider',kind:'provider_call_finished',details:{providerCallId:request,provider,auditOnly:false}});
}
test('full-operation totals deduplicate links, include retries, remain independent of step filters and page size',dbOptions,async t=>{
 const f=await fixture(t),root=await f.operation();
 const a=await record(f,root,{cost:0.0001}),b=await record(f,root,{cost:0.0002,direct:false,thought:10});
 await f.event(root.id,{executor_type:'provider',details:a.details});
 await f.event(root.id,{kind:'scan_cache_used',executor_type:'system',details:{cacheHit:true}});
 const full=await f.call('/api/admin/audit/operations',{costs:'1',steps:'1',match:'items'});
 assert.equal(full.statusCode,200);let u=full.body.operations[0].operation_usage;
 assert.equal(u.total_tokens,250);assert.equal(u.input_tokens,200);assert.equal(u.output_tokens,50);assert.equal(u.cost_ils,0.0009);assert.equal(u.calls,2);
 const filtered=await f.call('/api/admin/audit/operations',{costs:'1',steps:'1',match:'items',columnFilters:JSON.stringify({event_id:{values:[a.id]}})});
 assert.equal(filtered.body.operations[0].operation_usage.total_tokens,250);
 assert.equal(filtered.body.operations[0].first_sub_event.usage.total_tokens,120);
 const steps=await f.call('/api/admin/audit/operations/:id/events',{costs:'1',steps:'1',limit:'1'},undefined,{id:root.id});
 assert.equal(steps.body.events[0].operation_usage.total_tokens,250);assert.ok(steps.body.nextCursor);
 const all=await f.call('/api/admin/audit/events',{costs:'1'});assert.equal(all.body.events.reduce((n,e)=>n+e.usage.total_tokens,0),250);
});
test('unknown usage and unknown price stay unknown while free local steps and unit-priced calls are distinct',dbOptions,async t=>{
 const f=await fixture(t),root=await f.operation(),local=await f.event(root.id);
 await record(f,root,{provider:'google_vision',cost:0.0015,usage:false});
 let r=await f.call('/api/admin/audit/operations',{costs:'1'});assert.equal(r.body.operations[0].operation_usage.total_tokens,0);assert.equal(r.body.operations[0].operation_usage.cost_ils,0.0045);
 await record(f,root,{cost:0,usage:false});
 r=await f.call('/api/admin/audit/operations',{costs:'1'});assert.equal(r.body.operations[0].operation_usage.cost_ils,null);assert.equal(r.body.operations[0].operation_usage.total_tokens,null);assert.equal(r.body.operations[0].operation_usage.known_cost_ils,0.0045);
 const missing=await f.operation();await f.event(missing.id,{executor_type:'provider',details:{providerCallId:randomUUID(),auditOnly:false}});
 r=await f.call('/api/admin/audit/events',{costs:'1'});assert.equal(r.body.events.find(e=>e.id===local.id).usage.cost_ils,0);assert.equal(r.body.events[0].usage.status,'partial');
});
test('all usage fields support sorting/filtering in both modes; decimal cursor preserves fractions',dbOptions,async t=>{
 const f=await fixture(t);
 for(const cost of [0.0001,0.0002,0.0003]){const root=await f.operation();await record(f,root,{cost});}
 for(const mode of ['operations','events'])for(const [key,[type]]of Object.entries(COST_FIELDS)){
  const r=await f.call('/api/admin/audit/'+mode,{costs:'1',steps:mode==='operations'?'1':undefined,sort:key,direction:'asc',limit:'1'});assert.equal(r.statusCode,200,mode+'.'+key);
  if(r.body.nextCursor){const next=await f.call('/api/admin/audit/'+mode,{costs:'1',sort:key,direction:'asc',limit:'1',before:r.body.nextCursor});assert.equal(next.statusCode,200,key+' cursor');}
  if(type==='text')assert.equal((await f.call('/api/admin/audit/filter-options',{mode,column:key,costs:'1'})).statusCode,200,key+' options');
 }
 const r=await f.call('/api/admin/audit/operations',{costs:'1',columnFilters:JSON.stringify({operation_cost_ils:{min:'0.0005',max:'0.0007'}})});
 assert.equal(r.statusCode,200);assert.equal(r.body.operations.length,1);assert.equal(r.body.operations[0].operation_usage.cost_ils,0.0006);
});
async function fixture(t) {
  const db=new Client({connectionString:process.env.DATABASE_URL,
    ssl:process.env.DB_SSL==='true'?{rejectUnauthorized:process.env.DB_REJECT_UNAUTHORIZED!=='false'}:false});
  await db.connect();
  const schema=`audit_column_test_${randomUUID().replaceAll('-','')}`;
  await db.query(`CREATE SCHEMA "${schema}"`);
  t.after(async()=>{await db.query(`DROP SCHEMA "${schema}" CASCADE`);await db.end();});
  await db.query(`SET search_path TO "${schema}";
    CREATE TABLE users(id uuid PRIMARY KEY,name text,short_id integer);
    CREATE TABLE audit_metadata(key text,created_at timestamptz DEFAULT now());
    INSERT INTO audit_metadata(key) VALUES('recording_started');
    CREATE TABLE audit_operations(id uuid PRIMARY KEY,created_at timestamptz DEFAULT now(),
      updated_at timestamptz DEFAULT now(),action text,category text,initiator_id uuid,
      initiator_name text,initiator_short_id text,target_type text,target_id uuid,source text,
      status text,status_source text,reason_code text,root_event_id bigint,event_count bigint DEFAULT 0,duration_ms bigint DEFAULT 0,
      media_type text,capture_kind text,recipient_type text,recipient_id uuid,recipient_name text,recipient_short_id text);
    CREATE TABLE audit_events(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,operation_id uuid,
      parent_event_id bigint,created_at timestamptz DEFAULT now(),kind text,executor_type text,
      executor_id text,executor_name text,source text,status text,operation_status text,reason_code text,
      target_type text,target_id uuid,attempt integer DEFAULT 1,details jsonb DEFAULT '{}'::jsonb);`);
  await db.query(require('./helpers/audit-dispatch-schema'));
  await db.query(require('../server/audit-dispatch').DISPATCH_SQL);
  const schemaSql=require('node:fs').readFileSync(require.resolve('../server/schema.sql'),'utf8');
  const journal=schemaSql.match(/CREATE TABLE IF NOT EXISTS moderation_provider_calls \([\s\S]*?\n\);/)[0].replace(/ REFERENCES \w+\(id\) ON DELETE SET NULL/g,'');
  await db.query(journal);await db.query(COST_SQL);
  const userId=randomUUID();
  await db.query('INSERT INTO users VALUES($1,$2,42)',[userId,'Admin']);
  const operation=async(data={})=>{
    const row={id:randomUUID(),created_at:'2026-09-24T10:00:00Z',action:'send_message',category:'messaging',
      source:'http',status:'completed',reason_code:null,initiator_id:null,initiator_name:null,
      initiator_short_id:null,event_count:'1',duration_ms:'0',target_type:null,target_id:null,...data};
    const columns=Object.keys(row);
    await db.query(`INSERT INTO audit_operations(${columns.join(',')}) VALUES(${columns.map((_,i)=>'$'+(i+1)).join(',')})`,Object.values(row));
    return row;
  };
  const event=async(operationId,data={})=>{
    const row={operation_id:operationId,created_at:'2026-09-24T10:00:00Z',kind:'scan_completed',
      executor_type:'worker',executor_id:'scanner',executor_name:null,source:'worker',status:'completed',
      reason_code:null,parent_event_id:null,attempt:1,...data};
    const columns=Object.keys(row);
    return (await db.query(`INSERT INTO audit_events(${columns.join(',')}) VALUES(${columns.map((_,i)=>'$'+(i+1)).join(',')}) RETURNING *`,Object.values(row))).rows[0];
  };
  const routes={},admin=(_req,_res,next)=>next();
  registerSystemAuditRoutes({get:(path,...handlers)=>{routes[path]=handlers;},delete(){}},{getPool:async()=>db,adminMiddleware:admin});
  const call=async(path,query={},user={id:userId},params={})=>{
    const response={statusCode:200,headers:{},status(value){this.statusCode=value;return this;},
      set(key,value){this.headers[key]=value;return this;},json(value){this.body=value;return this;},
      send(value){this.body=value;return this;}};
    await routes[path].at(-1)({query,user,params},response);
    return response;
  };
  const select=async(parsed)=>(await db.query(buildQuery(parsed))).rows;
  const options=async(parsed,column,search='')=>(await db.query(buildFilterOptionsQuery(parsed,column,search))).rows;
  return {db,userId,operation,event,call,select,options,routes,admin};
}
test('real journal writer snapshots pricing and audit linkage; paid usage survives a failed result',dbOptions,async t=>{
 const f=await fixture(t),root=await f.operation(),vm=require('node:vm'),fs=require('node:fs'),{createRequire}=require('node:module');
 const filename=require.resolve('../server/provider-usage-log'),localRequire=createRequire(filename),module={exports:{}};
 vm.runInNewContext(fs.readFileSync(filename,'utf8'),{module,process,console,require:name=>name==='./db'?{getPool:async()=>f.db}:name==='./system-audit'?{getAuditContext:()=>({operationId:root.id})}:name==='./audit-fx'?{currentFx:()=>({rate:3,date:'2026-09-25'}),refreshFx:async()=>{}}:name==='./system-audit-context'?{observeAudit:async(_db,e)=>f.event(root.id,{executor_type:e.executorType,kind:e.kind,details:e.details})}:localRequire(name)});
 await module.exports.recordProviderCall({provider:'openai',model:'gpt-4.1-mini',operation:'modesty',status:'failed',usageReported:true,usage:{inputTokens:1000,cachedInputTokens:600,outputTokens:100,totalTokens:1100}});
 const row=(await f.db.query('SELECT * FROM moderation_provider_calls')).rows[0];assert.equal(row.audit_operation_id,root.id);assert.equal(row.estimated_cost_usd,0.00038);assert.equal(row.cached_input_tokens,'600');assert.equal(row.cost_basis.fxRate,3);
 const r=await f.call('/api/admin/audit/operations',{costs:'1'});assert.equal(r.body.operations[0].operation_usage.cost_ils,0.00114);
});
test('GPT-5.6 cache-write, long-context and web tool pricing are accounted separately',()=>{
 const p=priceSnapshot('openai','gpt-5.6-luna','safe_information');
 assert.equal(estimatedCost(p,{inputTokens:100,outputTokens:0},0,false),null);
 assert.ok(Math.abs(estimatedCost(p,{inputTokens:1000,cachedInputTokens:200,cacheWriteTokens:400,outputTokens:100,webSearchCalls:1},0,false)-0.010304)<1e-12);
 assert.ok(Math.abs(estimatedCost(p,{inputTokens:300000,cacheWriteTokens:0,outputTokens:1000},0,false)-0.1218)<1e-12);
});

test('operation usage stays bounded with a large unrelated provider journal',dbOptions,async t=>{
 const f=await fixture(t),root=await f.operation();await record(f,root);
 await f.db.query(`INSERT INTO moderation_provider_calls(request_id,provider,model,operation,workflow,status) SELECT gen_random_uuid(),'openai','unrelated','modesty','test','completed' FROM generate_series(1,85000)`);
 await f.db.query('ANALYZE moderation_provider_calls');
 const start=performance.now();
 for(let i=0;i<20;i++)await f.db.query('SELECT system_audit_usage($1,NULL,3,\'2026-09-25\')',[root.id]);
 const ms=performance.now()-start;t.diagnostic('20 usage summaries against 85,000 unrelated calls: '+Math.round(ms)+'ms');assert.ok(ms<5000);
});
