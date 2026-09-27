'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const {randomUUID}=require('node:crypto');
const {Client}=require('pg');
const {ensureSystemAuditSchema,beginOperation,recordAuditEvent,readFilters,buildQuery,
  buildFilterOptionsQuery,registerSystemAuditRoutes}=require('../server/system-audit');
const {sanitizeAuditDetails,EVENT_KIND_LABELS}=require('../server/system-audit-catalog');

const dbOptions={skip:process.env.RUN_DB_TESTS!=='1'};
const contextColumns=['media_type','capture_kind','recipient_type','recipient_id','recipient_name','recipient_short_id'];
const filters=(columnFilters={},mode='operations',extra={})=>readFilters({scope:'user',match:'chain',
  ...extra,columnFilters:JSON.stringify(columnFilters)},{mode});

test('media context allows bounded explicit capture facts and never accepts client identity snapshots',()=>{
  const recipientId=randomUUID();
  assert.deepEqual(sanitizeAuditDetails({mediaType:'video',captureKind:'camera_video',recipientType:'user',recipientId,
    recipientName:'Untrusted name',recipientShortId:'123',fileName:'camera-20260924.mp4',url:'https://private'}),
  {recipientId,mediaType:'video',captureKind:'camera_video',recipientType:'user'});
  for (const value of ['camera',true,{},'camera_video ',null,'voice','unknown'])
    assert.deepEqual(sanitizeAuditDetails({mediaType:value,captureKind:value,recipientType:value}),{});
  for (const captureKind of ['camera_video','camera_image','microphone'])
    assert.equal(sanitizeAuditDetails({captureKind}).captureKind,captureKind);
  for (const kind of ['upload_context','blob_upload_started','blob_upload_finished'])
    assert.match(EVENT_KIND_LABELS[kind],/[\u0590-\u05ff]/);
});

test('recipient and media column predicates use root context in both modes and remain parameterized',()=>{
  const recipientId=randomUUID();
  for (const mode of ['operations','events']) {
    const query=buildQuery(filters({recipient_id:{values:[recipientId,null]},recipient_type:{values:['user']},
      media_type:{values:['video']},capture_kind:{values:['camera_video']}},mode));
    for (const column of ['recipient_id','recipient_type','media_type','capture_kind']) {
      assert.match(query.text,new RegExp('o\\.'+column+' = ANY'));
      assert.doesNotMatch(query.text,new RegExp('(?:e|chain_match)\\.'+column+' = ANY'));
    }
    assert.ok(!query.text.includes(recipientId));
    assert.throws(()=>filters({recipient_id:{values:['not-a-uuid']}},mode),{status:400});
    const options=buildFilterOptionsQuery(filters({recipient_id:{values:[]},recipient_type:{values:['group']}},mode),'recipient_id');
    assert.doesNotMatch(options.text,/WHERE FALSE/);
    assert.match(options.text,/o\.recipient_name/);
    assert.match(options.text,/o\.recipient_short_id/);
    assert.match(options.text,/o\.recipient_type = ANY/);
  }
});

async function fixture(t) {
  const url=new URL(process.env.DATABASE_URL);
  assert.match(url.pathname,/test/i,'Media audit DB tests require an explicitly named disposable test database');
  const db=new Client({connectionString:url.href,ssl:false});
  await db.connect();
  const schema=`audit_media_test_${randomUUID().replaceAll('-','')}`;
  await db.query(`CREATE SCHEMA "${schema}"`);
  t.after(async()=>{await db.query(`DROP SCHEMA "${schema}" CASCADE`);await db.end();});
  await db.query(`SET search_path TO "${schema}";
    CREATE TABLE users(id uuid PRIMARY KEY,name text,short_id integer);
    CREATE TABLE groups(id uuid PRIMARY KEY,name text);`);
  const actor=randomUUID(),recipient=randomUUID(),group=randomUUID();
  await db.query('INSERT INTO users VALUES($1,$2,42),($3,$4,123)',[actor,'Audit Actor',recipient,'Recipient Name']);
  await db.query('INSERT INTO groups VALUES($1,$2)',[group,'Recipient Group']);
  await ensureSystemAuditSchema(db);
  const start=()=>beginOperation(db,{action:'upload_file',initiatorId:actor,executorType:'user',executorId:actor,source:'http'});
  const context=(operation,details={})=>recordAuditEvent(db,{operationId:operation.id,parentEventId:operation.root_event_id,
    kind:'upload_context',status:'completed',details});
  const saved=async operation=>(await db.query('SELECT * FROM audit_operations WHERE id=$1',[operation.id])).rows[0];
  const rows=async parsed=>(await db.query(buildQuery(parsed))).rows;
  const options=async(parsed,column,search='')=>(await db.query(buildFilterOptionsQuery(parsed,column,search))).rows;
  const routes={};
  registerSystemAuditRoutes({get:(path,...handlers)=>{routes[path]=handlers;},delete(){}},
    {getPool:async()=>db,adminMiddleware:(_req,_res,next)=>next()});
  const call=async(path,query={},params={})=>{
    const res={statusCode:200,headers:{},status(code){this.statusCode=code;return this;},
      set(key,value){this.headers[key]=value;return this;},json(value){this.body=value;return this;},send(value){this.body=value;return this;}};
    await routes[path].at(-1)({query,params,user:{id:actor}},res);
    return res;
  };
  return {db,actor,recipient,group,start,context,saved,rows,options,call};
}

test('media context migration is idempotent and never invents missing historical capture or recipients',dbOptions,async t=>{
  const f=await fixture(t),operation=await f.start();
  await recordAuditEvent(f.db,{operationId:operation.id,kind:'media_stored',details:{fileType:'video'}});
  await ensureSystemAuditSchema(f.db);
  const row=await f.saved(operation);
  for (const column of contextColumns) assert.equal(row[column],null,column);
  assert.equal(row.action,'upload_file');
  assert.equal(row.event_count,'2');
});

test('upload context snapshots authoritative recipient identity once without changing primary action or outcome',dbOptions,async t=>{
  const f=await fixture(t),operation=await f.start();
  const evidence=await f.context(operation,{mediaType:'video',captureKind:'camera_video',recipientType:'user',
    recipientId:f.recipient,recipientName:'Forged name',recipientShortId:'999'});
  assert.equal(evidence.details.recipientName,undefined);
  let row=await f.saved(operation);
  assert.deepEqual(contextColumns.map(column=>row[column]),['video','camera_video','user',f.recipient,'Recipient Name','123']);
  assert.equal(row.action,'upload_file');
  assert.equal(row.status,'running');
  await f.db.query('UPDATE users SET name=$2,short_id=124 WHERE id=$1',[f.recipient,'Changed Name']);
  await f.context(operation,{mediaType:'audio',captureKind:'microphone',recipientType:'group',recipientId:f.group});
  row=await f.saved(operation);
  assert.deepEqual(contextColumns.map(column=>row[column]),['video','camera_video','user',f.recipient,'Recipient Name','123']);
  await f.db.query('DELETE FROM users WHERE id=$1',[f.recipient]);
  assert.equal((await f.saved(operation)).recipient_name,'Recipient Name');
  await assert.rejects(f.db.query('UPDATE audit_operations SET recipient_name=$2 WHERE id=$1',[operation.id,'Forged name']),/maintained by events/);
  await assert.rejects(f.db.query('UPDATE audit_events SET details=$2 WHERE id=$1',[evidence.id,{}]),/append-only/);
});

test('group context permits absent short IDs and invalid or inconsistent facts remain unknown',dbOptions,async t=>{
  const f=await fixture(t),groupOperation=await f.start();
  await f.context(groupOperation,{mediaType:'image',captureKind:'camera_image',recipientType:'group',recipientId:f.group});
  const groupRow=await f.saved(groupOperation);
  assert.deepEqual(contextColumns.map(column=>groupRow[column]),['image','camera_image','group',f.group,'Recipient Group',null]);
  for (const details of [
    {mediaType:'video',captureKind:'microphone',recipientType:'user',recipientId:'not-a-uuid'},
    {mediaType:'video',captureKind:'camera_image',recipientType:'group',recipientId:randomUUID()},
    {mediaType:'video',fileName:'betshuva_video_ID123_20260924_123456.mp4'},
  ]) {
    const operation=await f.start();
    await f.context(operation,details);
    const row=await f.saved(operation);
    assert.equal(row.media_type,'video');
    for (const column of contextColumns.slice(1)) assert.equal(row[column],null,column);
  }
  const audio=await f.start();
  await f.context(audio,{mediaType:'audio',captureKind:'microphone'});
  assert.equal((await f.saved(audio)).capture_kind,'microphone');
});

test('media context projection and evidence roll back together',dbOptions,async t=>{
  const f=await fixture(t),operation=await f.start();
  await f.db.query('BEGIN');
  await f.context(operation,{mediaType:'video',captureKind:'camera_video',recipientType:'user',recipientId:f.recipient});
  assert.equal((await f.saved(operation)).media_type,'video');
  await f.db.query('ROLLBACK');
  const row=await f.saved(operation);
  assert.equal(row.event_count,'1');
  for (const column of contextColumns) assert.equal(row[column],null,column);
});

test('recipient filters and facets preserve intended-recipient semantics across child chains and flat events',dbOptions,async t=>{
  const f=await fixture(t),direct=await f.start(),group=await f.start(),unknown=await f.start();
  await f.context(direct,{mediaType:'video',captureKind:'camera_video',recipientType:'user',recipientId:f.recipient});
  await f.context(group,{mediaType:'image',recipientType:'group',recipientId:f.group});
  for (const operation of [direct,group,unknown]) await recordAuditEvent(f.db,{operationId:operation.id,
    parentEventId:operation.root_event_id,kind:'blob_upload_finished',targetType:'user',targetId:f.recipient});
  for (const mode of ['operations','events']) {
    const selected=await f.rows(filters({recipient_id:{values:[f.recipient]}},mode));
    assert.ok(selected.length);
    assert.ok(selected.every(row=>(row.operation_id || row.id)===direct.id));
    assert.ok(selected.every(row=>row.recipient_name==='Recipient Name' && row.capture_kind==='camera_video'));
    const blank=await f.rows(filters({recipient_id:{values:[null]}},mode));
    assert.ok(blank.length);
    assert.ok(blank.every(row=>(row.operation_id || row.id)===unknown.id));
    const facet=await f.options(filters({recipient_id:{values:[]},recipient_type:{values:['user']}},mode),'recipient_id','Recipient Name');
    assert.equal(facet.length,1);
    assert.equal(facet[0].value,f.recipient);
    assert.match(facet[0].label,/Recipient Name \/ ID 123/);
    assert.equal((await f.options(filters({},mode),'recipient_type','קבוצה'))[0].value,'group');
    assert.equal((await f.options(filters({},mode),'capture_kind','צילום וידאו'))[0].value,'camera_video');
  }
  const chain=await f.rows(filters({recipient_id:{values:[f.recipient]},action:{values:['blob_upload_finished']}}));
  assert.deepEqual(chain.map(row=>row.id),[direct.id]);
  assert.deepEqual((await f.rows(filters({recipient_id:{values:[f.recipient],exclude:true}}))).map(row=>row.id).sort(),
    [group.id,unknown.id].sort());
  const response=await f.call('/api/admin/audit/operations/:id/events',{}, {id:direct.id});
  assert.equal(response.statusCode,200);
  assert.equal(response.body.events.length,3);
  assert.ok(response.body.events.every(row=>row.recipient_id===f.recipient));
});

test('CSV includes media and recipient snapshots with identical predicates and spreadsheet escaping',dbOptions,async t=>{
  const f=await fixture(t),operation=await f.start();
  await f.db.query('UPDATE users SET name=$2 WHERE id=$1',[f.recipient,'=RecipientFormula']);
  await f.context(operation,{mediaType:'video',captureKind:'camera_video',recipientType:'user',recipientId:f.recipient});
  for (const mode of ['operations','events']) {
    const response=await f.call('/api/admin/audit/export.csv',{mode,scope:'user',match:'chain',
      from:new Date(Date.now()-86400000).toISOString(),to:new Date(Date.now()+86400000).toISOString(),
      columnFilters:JSON.stringify({recipient_id:{values:[f.recipient]}})});
    assert.equal(response.statusCode,200);
    for (const column of contextColumns) assert.ok(response.body.split('\r\n')[0].includes('"'+column+'"'));
    assert.match(response.body,/"camera_video"/);
    assert.match(response.body,/"'=RecipientFormula"/);
    assert.equal(response.headers['X-Audit-Export-Count'],mode==='operations'?'1':'2');
  }
});
