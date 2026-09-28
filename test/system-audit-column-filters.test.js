'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const {randomUUID}=require('node:crypto');
const {Client}=require('pg');
const {readFilters,buildQuery,buildFilterOptionsQuery,registerSystemAuditRoutes}=require('../server/system-audit');
const {CHECK_TYPE_LABELS,CHECK_OUTCOME_LABELS}=require('../server/audit-check-presentation');

const dbOptions={skip:process.env.RUN_DB_TESTS!=='1'};
const filters=(columnFilters,mode='operations',extra={})=>readFilters({
  ...extra,columnFilters:JSON.stringify(columnFilters),
},{mode});

test('stopped-file column filters by the recorded file across every step without mixing duplicate filenames',dbOptions,async t=>{
  const f=await fixture(t),files=[randomUUID(),randomUUID()],roots=[];
  for(const id of files)await f.db.query("INSERT INTO stored_files(id,original_name) VALUES($1,'video.webm')",[id]);
  for(const [i,status]of ['failed','failed','completed'].entries()){
    const root=await f.operation({status,status_source:'scan_workflow_finished'});roots.push(root);
    await f.event(root.id,{kind:'upload_context',status:'completed'});
    await f.event(root.id,{kind:'scan_workflow_finished',status:'failed',target_type:'file',target_id:files[i%2]});
  }
  for(const mode of ['operations','events']){
    const selected=await f.select(filters({stopped_file:{values:[files[0]]}},mode,{sort:'stopped_file',direction:'asc'}));
    assert.equal(selected.length,mode==='operations'?1:2);
    assert.ok(selected.every(row=>(row.operation_id||row.id)===roots[0].id));
    const options=await f.options(filters({},mode),'stopped_file','video.webm');
    assert.equal(options.length,2);assert.ok(options.every(row=>row.label==='video.webm'));
    assert.deepEqual(options.map(row=>row.value).sort(),files.slice().sort());
    const blank=await f.select(filters({stopped_file:{values:[null]}},mode));
    assert.ok(blank.every(row=>(row.operation_id||row.id)===roots[2].id));
  }
});

test('problem-file column filters final blocked images and policy refusals, but not provider-only refusals',dbOptions,async t=>{
  const f=await fixture(t),file=randomUUID(),expected=[];
  await f.db.query("INSERT INTO stored_files(id,original_name) VALUES($1,'blocked.png')",[file]);
  for(const kind of ['media_moderation_changed','decision_blocked','provider_call_finished']){
    const root=await f.operation({status:'blocked',status_source:'http_response'});
    await f.event(root.id,{kind,status:'blocked',target_type:kind==='media_moderation_changed'?'file':null,
      target_id:kind==='media_moderation_changed'?file:null,details:{storedFileId:file}});
    if(kind!=='provider_call_finished')expected.push(root.id);
  }
  for(const mode of ['operations','events']){
    const selected=await f.select(filters({stopped_file:{values:[file]}},mode));
    assert.deepEqual(selected.map(row=>row.operation_id||row.id).sort(),expected.slice().sort());
    const options=await f.options(filters({},mode),'stopped_file','blocked.png');
    assert.equal(options.length,1);assert.equal(options[0].value,file);assert.equal(options[0].label,'blocked.png');
  }
});

test('recipient-blocked objects have blank problem-file evidence and filter values in both histories',dbOptions,async t=>{
  const {attachStoppedScanEvidence}=require('../server/audit-stopped-evidence');
  const f=await fixture(t),file=randomUUID(),root=await f.operation({action:'upload_file',status:'blocked',status_source:'http_response',media_type:'image'});
  await f.db.query("INSERT INTO stored_files(id,original_name,file_type,moderation_status,moderation_details) VALUES($1,'recipient.png','image','approved',$2)",
    [file,{destinationFilterRejected:true,reasonCode:'content_filter'}]);
  await f.event(root.id,{kind:'upload_context',target_type:'file',target_id:file});
  await f.event(root.id,{kind:'decision_blocked',status:'blocked',details:{storedFileId:file}});
  for(const mode of ['operations','events']){
    const selected=await f.select(filters({stopped_file:{values:[file]}},mode));
    assert.equal(selected.length,0);
    const blank=await f.select(filters({stopped_file:{values:[null]}},mode));
    assert.ok(blank.length>0);assert.ok(blank.every(row=>row.dispatch.object_status==='blocked_for_recipient'));
    await attachStoppedScanEvidence(f.db,blank,mode);
    assert.ok(blank.every(row=>row.stoppedEvidence===null));
    const options=await f.options(filters({},mode),'stopped_file','recipient.png');
    assert.equal(options.length,0);
  }
});

test('overall object status distinguishes global rejection, recipient refusal, sent and unfinished work',dbOptions,async t=>{
  const f=await fixture(t),sender=randomUUID(),recipient=randomUUID();
  await f.db.query('INSERT INTO users VALUES($1,$2,10),($3,$4,11)',[sender,'Sender',recipient,'Recipient']);
  const cases=[
    ['blocked','blocked','rejected',{},null],
    ['blocked_for_recipient','blocked','approved',{destinationFilterRejected:true,reasonCode:'content_filter'},null],
    ['blocked','blocked','approved',{senderFilterRejected:true,reasonCode:'sender_content_filter'},null],
    ['stopped','failed','stopped',{reasonCode:'scan_incomplete'},null],
    ['pending','pending','pending',{},null],
    ['unknown','completed','approved',{},null],
    ['sent','failed','approved',{},'user'],
    ['partial','completed','approved',{},'group'],
    ['blocked_for_recipient','completed','approved',{},'group_blocked'],
  ];
  const expected=new Map();
  for(const [status,operationStatus,moderationStatus,details,send]of cases){
    const file=randomUUID(),group=send?.startsWith('group')?randomUUID():null,url='test-object-'+file;
    if(group)await f.db.query('INSERT INTO groups VALUES($1,$2)',[group,'Group']);
    const root=await f.operation({action:'upload_file',status:operationStatus,media_type:'video',initiator_id:sender,recipient_type:group?'group':'user',recipient_id:group||recipient});
    await f.db.query('INSERT INTO stored_files(id,public_url,file_type,moderation_status,moderation_details) VALUES($1,$2,$3,$4,$5)',[file,url,'video',moderationStatus,details]);
    await f.event(root.id,{kind:'upload_context',target_type:'file',target_id:file});
    if(send){
      const message=randomUUID(),summary=group?{deliveredTo:send==='group'?[{id:recipient}]:[],blockedFor:[{id:randomUUID(),reason:'Recipient filter'}]}:null;
      await f.db.query('INSERT INTO messages(id,created_at,sender_id,recipient_id,group_id,type,file_url,delivery_summary) VALUES($1,now(),$2,$3,$4,$5,$6,$7)',[message,sender,group?null:recipient,group,'video',url,summary]);
      await f.event(root.id,{kind:'message_persisted',target_type:'message',target_id:message});
    }
    const dispatch=(await f.db.query('SELECT system_audit_dispatch($1) AS value',[root.id])).rows[0].value;
    assert.equal(dispatch.object_status,status);
    expected.set(root.id,status);
  }
  for(const mode of ['operations','events']){
    const selected=await f.select(filters({object_status:{values:['blocked_for_recipient']}},mode,{sort:'object_status',direction:'asc',costs:'1'}));
    assert.ok(selected.length>=2);assert.ok(selected.every(row=>row.dispatch.object_status==='blocked_for_recipient'));
    const options=await f.options(filters({},mode),'object_status');
    assert.equal(options.find(row=>row.value==='blocked_for_recipient').label,'נחסם למשתמש');
    assert.equal(options.find(row=>row.value==='sent').label,'נשלח');
  }
});

test('image name filters group checks of one frame and distinguish uploads with identical filenames',dbOptions,async t=>{
  const f=await fixture(t),root=await f.operation({status:'failed'}),files=[randomUUID(),randomUUID(),randomUUID()];
  for(const [i,id]of files.entries())await f.db.query('INSERT INTO stored_files(id,file_type,original_name) VALUES($1,$2,$3)',
    [id,i===2?'image':'video',i===2?'תמונה.png':'סרטון.webm']);
  const event=async(file,index,time,extra={})=>f.event(root.id,{kind:'provider_call_finished',details:{checkType:'modesty',checkOutcome:'passed',
    storedFileId:file,...(index==null?{}:{frameIndex:index,frameTimestampMs:time}),...extra}});
  const first=await event(files[0],0,0),second=await event(files[0],1,5005);
  const sameFrame=await event(files[0],1,5005,{provider:'gemini',checkOutcome:'blocked',cacheHit:true});
  const sameName=await event(files[1],1,5005),image=await event(files[2],null,null);
  await event('not-a-uuid',0,0);await f.event(root.id,{kind:'upload_context'});
  const key=files[0]+':frame:1:5005',selection={scan_image:{values:[key]}};
  assert.deepEqual((await f.select(filters(selection,'events'))).map(row=>row.id).sort(),[second.id,sameFrame.id].sort());
  assert.deepEqual((await f.select(filters(selection,'operations',{match:'items',steps:'1'}))).map(row=>row.id),[root.id]);
  for(const mode of ['operations','events']){
    const options=await f.options(filters({},mode,{match:'items',steps:'1'}),'scan_image','סרטון');
    assert.equal(options.length,3);
    assert.equal(options.find(row=>row.value===key).label,'סרטון.webm · תמונה 2 · שנייה 5.005');
    assert.ok(options.some(row=>row.value===files[1]+':frame:1:5005'));
    await f.select(filters({},mode,{sort:'scan_image',direction:'asc'}));
  }
  const rows=[first,second,sameFrame,sameName,image];
  await require('../server/audit-image-names').attachScanImageNames(f.db,rows);
  assert.equal(rows[0].scanImage.name,'סרטון.webm · תמונה 1 · שנייה 0');
  assert.equal(rows[1].scanImage.name,rows[2].scanImage.name);
  assert.notEqual(rows[1].scanImage.key,rows[3].scanImage.key);
  assert.equal(rows[4].scanImage.name,'תמונה.png');
  await f.db.query('DELETE FROM stored_files WHERE id=$1',[files[0]]);
  await require('../server/audit-image-names').attachScanImageNames(f.db,[second]);
  assert.equal(second.scanImage.key,key);
  assert.match(second.scanImage.name,/תמונה 2/);
});

test('scan status filters and sorting use each check outcome even when the operation failed',dbOptions,async t=>{
  const f=await fixture(t),root=await f.operation({status:'failed'});
  const passed=await f.event(root.id,{kind:'provider_call_finished',status:'observed',details:{checkType:'modesty',checkOutcome:'passed'}});
  const blocked=await f.event(root.id,{kind:'provider_call_finished',status:'observed',details:{checkType:'modesty',checkOutcome:'blocked'}});
  const unknown=await f.event(root.id,{kind:'provider_call_finished',status:'completed',details:{checkType:'modesty'}});
  const nonCheck=await f.event(root.id,{kind:'upload_context'});
  const running=await f.event(root.id,{kind:'storage_upload_started',status:'running'});
  const failed=await f.event(root.id,{kind:'scan_workflow_finished',status:'failed'});
  for(const [code,id]of [['passed',passed.id],['blocked',blocked.id],['not_recorded',unknown.id],['completed',nonCheck.id],['running',running.id],['failed',failed.id]]){
    const selection={scan_status:{values:[code]}};
    assert.deepEqual((await f.select(filters(selection,'events'))).map(row=>row.id),[id]);
    assert.deepEqual((await f.select(filters(selection,'operations',{match:'items',steps:'1'}))).map(row=>row.id),[root.id]);
  }
  for(const mode of ['operations','events']){
    const options=await f.options(filters({},mode,{match:'items',steps:'1'}),'scan_status');
    assert.equal(options.find(row=>row.value==='passed').label,CHECK_OUTCOME_LABELS.passed);
    assert.equal(options.find(row=>row.value==='blocked').label,CHECK_OUTCOME_LABELS.blocked);
    await f.select(filters({},mode,{sort:'scan_status',direction:'asc'}));
  }
});

test('sorting rejects SQL fragments and mismatched cursors',()=>{
  for(const query of [{sort:'status;DROP TABLE users',direction:'asc'},{sort:'status',direction:'bad'},{direction:'asc'}])
    assert.throws(()=>readFilters(query),{status:400});
  const before=Buffer.from(JSON.stringify({v:2,id:randomUUID(),sort:'source',direction:'asc',value:'http'})).toString('base64url');
  assert.throws(()=>readFilters({sort:'status',direction:'asc',before}),{status:400});
});

test('server sorting paginates ties and nulls in both directions for roots and children',dbOptions,async t=>{
  const f=await fixture(t),roots=[];
  for(const reason of ['a','b','a',null,null])roots.push(await f.operation({reason_code:reason}));
  for(const root of roots)await f.event(roots[0].id,{reason_code:root.reason_code});
  for(const mode of ['operations','events'])for(const direction of ['asc','desc']){
    const rows=[];let before;
    do{
      const response=await f.call(`/api/admin/audit/${mode}`,{sort:'reason_code',direction,limit:'2',...(before?{before}:{})});
      assert.equal(response.statusCode,200);rows.push(...response.body[mode]);before=response.body.nextCursor;
    }while(before);
    assert.equal(rows.length,5);assert.equal(new Set(rows.map(row=>row.id)).size,5);
    assert.deepEqual(rows.map(row=>row.reason_code),direction==='asc'?['a','a','b',null,null]:['b','a','a',null,null]);
  }
  const selected=await f.call('/api/admin/audit/operations/:id/events',{
    columnFilters:JSON.stringify({reason_code:{values:['a']}}),sort:'created_at',direction:'asc',limit:'1'},undefined,{id:roots[0].id});
  assert.equal(selected.statusCode,200);assert.equal(selected.body.events[0].reason_code,'a');assert.ok(selected.body.nextCursor);
  const next=await f.call('/api/admin/audit/operations/:id/events',{
    columnFilters:JSON.stringify({reason_code:{values:['a']}}),sort:'created_at',direction:'asc',limit:'1',before:selected.body.nextCursor},undefined,{id:roots[0].id});
  assert.equal(next.statusCode,200);assert.notEqual(next.body.events[0].id,selected.body.events[0].id);
  assert.equal(next.body.nextCursor,null);
  for(const [mode,columns]of [['operations',['created_at','action','initiator_id','recipient_id','check_type','check_outcome','event_count','duration_ms']],
    ['events',['created_at','kind','executor_id','recipient_id','check_type','check_outcome','attempt']]]){
    for(const sort of columns){
      const query={sort,direction:'asc',limit:'1',...(mode==='operations'?{match:'items'}:{})};
      const first=await f.call(`/api/admin/audit/${mode}`,query);
      assert.equal(first.statusCode,200,`${mode}.${sort}`);
      assert.ok(first.body.nextCursor);
      const second=await f.call(`/api/admin/audit/${mode}`,{...query,before:first.body.nextCursor});
      assert.equal(second.statusCode,200,`${mode}.${sort} cursor`);
      assert.notEqual(first.body[mode][0].id,second.body[mode][0].id);
    }
  }
});

test('item filtering excludes only matching children, not their entire operation',dbOptions,async t=>{
  const f=await fixture(t),root=await f.operation();
  await f.event(root.id,{details:{checkType:'modesty',checkOutcome:'blocked'}});
  const passed=await f.event(root.id,{details:{checkType:'modesty',checkOutcome:'passed'}});
  const columns={check_type:{values:['modesty']},check_outcome:{values:['blocked'],exclude:true}};
  assert.deepEqual((await f.select(filters(columns,'operations',{match:'items'}))).map(row=>row.id),[root.id]);
  assert.deepEqual((await f.select(filters(columns,'events'))).map(row=>row.id),[passed.id]);
});

test('audit column filters validate types, normalize IDs and preserve bigint precision',()=>{
  const id=randomUUID();
  const parsed=filters({initiator_id:{values:[id.toUpperCase(),id,null]},
    event_count:{min:'0',max:'9223372036854775807'},created_at:{from:'2026-09-24T03:00:00+03:00'}});
  assert.deepEqual(parsed.columnFilters.initiator_id,{values:[id,null],exclude:false});
  assert.equal(parsed.columnFilters.event_count.max,'9223372036854775807');
  assert.equal(parsed.columnFilters.created_at.from,'2026-09-24T00:00:00.000Z');
  assert.equal(filters({parent_event_id:{values:['9223372036854775807',null]}},'events')
    .columnFilters.parent_event_id.values[0],'9223372036854775807');
  assert.deepEqual(filters({executor_id:{values:['scan-worker',null],exclude:true}},'events')
    .columnFilters.executor_id,{values:['scan-worker',null],exclude:true});
});

test('audit column filters reject malformed, oversized, unknown and mode-mismatched input',()=>{
  for (const columnFilters of ['',null,{},'null','[]','{',JSON.stringify({status:{values:['x'.repeat(17000)]}})])
    assert.throws(()=>readFilters({columnFilters}),{status:400});
  for (const value of [
    {unknown:{values:['x']}},{attempt:{values:['x']}},{status:null},{status:[]},
    {status:{values:['x'],other:true}},{status:{values:['x'],exclude:'true'}},
    {status:{values:[1]}},{status:{values:Array(101).fill('x')}},{status:{values:['x'.repeat(201)]}},
    {status:{min:'0'}},{event_count:{values:['1']}},{event_count:{}},{event_count:{min:0}},
    {event_count:{min:'-1'}},{event_count:{min:'01'}},{event_count:{min:'1.5'}},
    {event_count:{max:'9223372036854775808'}},{event_count:{min:'2',max:'1'}},
    {created_at:{from:'2026-09-24'}},{created_at:{from:'2026-09-25T00:00:00Z',to:'2026-09-24T00:00:00Z'}},
    {initiator_id:{values:['invalid']}},JSON.parse('{"__proto__":{"values":["x"]}}'),
  ]) assert.throws(()=>filters(value),{status:400});
  assert.throws(()=>filters({action:{values:['x']}},'events'),{status:400});
  for (const value of ['0','-1','9223372036854775808','1.1'])
    assert.throws(()=>filters({parent_event_id:{values:[value]}},'events'),{status:400});
  assert.throws(()=>readFilters({}, {mode:'__proto__'}),{status:400});
  assert.throws(()=>readFilters({}, {mode:['events']}),{status:400});
});

test('column predicates remain parameterized and empty selections have explicit semantics',()=>{
  const attack="x') OR TRUE; --";
  const query=buildQuery(filters({reason_code:{values:[attack,null],exclude:true},
    duration_ms:{min:'9007199254740993'}},'operations',{action:'send_message'}));
  assert.ok(!query.text.includes(attack));
  assert.match(query.text,/o\.reason_code <> ALL\(\$2::text\[\]\) AND o\.reason_code IS NOT NULL/);
  assert.deepEqual(query.values,['send_message',[attack],'9007199254740993',51]);
  assert.match(buildQuery(filters({status:{values:[]}})).text,/WHERE FALSE/);
  assert.doesNotMatch(buildQuery(filters({status:{values:[],exclude:true}})).text,/WHERE/);
});

test('filter options remove only their own column and never include a cursor or page limit',()=>{
  const parsed=filters({status:{values:[]},action:{values:['send_message']}},'operations',{
    source:'http',limit:'1',before:Buffer.from(JSON.stringify({v:1,id:randomUUID(),
      createdAt:'2026-09-24T00:00:00Z'})).toString('base64url'),
  });
  const query=buildFilterOptionsQuery(parsed,'status','a%_\\b');
  assert.doesNotMatch(query.text,/FALSE|o\.created_at,o\.id/);
  assert.match(query.text,/o\.action = ANY/);
  assert.match(query.text,/LIMIT 101/);
  assert.deepEqual(query.values.slice(0,2),['http',['send_message']]);
  assert.equal(JSON.parse(query.values[2]).completed,'הושלם');
  assert.equal(query.values.at(-1),'%a\\%\\_\\\\b%');
  for (const column of ['created_at','event_count','duration_ms','missing','__proto__'])
    assert.throws(()=>buildFilterOptionsQuery(parsed,column),{status:400});
  assert.throws(()=>buildFilterOptionsQuery(parsed,'status','x'.repeat(101)),{status:400});
  assert.throws(()=>buildFilterOptionsQuery(parsed,'status',[]),{status:400});
  assert.throws(()=>buildFilterOptionsQuery(parsed,['status']),{status:400});
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
  await db.query(schemaSql.match(/CREATE TABLE IF NOT EXISTS moderation_provider_calls \([\s\S]*?\n\);/)[0].replace(/ REFERENCES \w+\(id\) ON DELETE SET NULL/g,''));
  await db.query(require('../server/audit-costs').COST_SQL);
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

test('column inclusion and exclusion handle blank values, intersections and root-only targets',dbOptions,async t=>{
  const f=await fixture(t);
  const blank=await f.operation(),blocked=await f.operation({reason_code:'policy',status:'blocked'});
  const done=await f.operation({reason_code:'done'}),empty=await f.operation({reason_code:''});
  const ids=async(values,exclude=false)=>(await f.select(filters({reason_code:{values,exclude}}))).map(row=>row.id).sort();
  assert.deepEqual(await ids([null]),[blank.id]);
  assert.deepEqual(await ids(['policy',null]),[blank.id,blocked.id].sort());
  assert.deepEqual(await ids(['policy'],true),[blank.id,done.id,empty.id].sort());
  assert.deepEqual(await ids(['policy',null],true),[done.id,empty.id].sort());
  assert.deepEqual(await ids([null],true),[blocked.id,done.id,empty.id].sort());
  assert.deepEqual(await ids([]),[]);
  assert.equal((await ids([],true)).length,4);
  assert.deepEqual((await f.select(filters({reason_code:{values:['policy',null]},status:{values:['completed']}})))
    .map(row=>row.id),[blank.id]);
  const targetId=randomUUID();
  await f.event(blank.id,{target_type:'file',target_id:targetId});
  assert.deepEqual((await f.select(readFilters({targetId}))).map(row=>row.id),[blank.id]);
  assert.deepEqual(await f.select(filters({target_id:{values:[targetId]}})),[]);
});

test('column date and numeric ranges retain exact bounds, including values above JS safe integer',dbOptions,async t=>{
  const f=await fixture(t);
  const wanted=await f.operation({created_at:'2026-09-24T10:00:00.123Z',event_count:'9007199254740993',duration_ms:'200'});
  await f.operation({created_at:'2026-09-24T10:00:00.124Z',event_count:'9007199254740994',duration_ms:'201'});
  await f.operation({created_at:'2026-09-24T10:00:00.122Z',event_count:'9007199254740992',duration_ms:'199'});
  assert.deepEqual((await f.select(filters({created_at:{from:'2026-09-24T10:00:00.123Z',to:'2026-09-24T10:00:00.124Z'},
    event_count:{min:'9007199254740993',max:'9007199254740993'},duration_ms:{min:'200',max:'200'}}))).map(row=>row.id),[wanted.id]);
});

test('event filters preserve service executors, parent IDs, operation IDs and independent status',dbOptions,async t=>{
  const f=await fixture(t),operation=await f.operation({status:'blocked'});
  const root=await f.event(operation.id,{executor_id:null});
  const wanted=await f.event(operation.id,{executor_id:'scan-worker',parent_event_id:root.id,attempt:2});
  await f.event(operation.id,{executor_id:'scan-worker',parent_event_id:root.id,attempt:3,status:'blocked'});
  const parsed=filters({operation_id:{values:[operation.id]},parent_event_id:{values:[root.id]},
    executor_id:{values:['scan-worker']},status:{values:['completed']},attempt:{min:'2',max:'2'}},'events');
  const selected=await f.select(parsed);assert.deepEqual(selected.map(row=>row.id),[wanted.id]);assert.equal(selected[0].status,'completed');assert.equal(selected[0].current_operation_status,'blocked');
  assert.deepEqual(await f.options(filters({},'events'),'parent_event_id'),[
    {value:null,label:'(ריק)'},{value:root.id,label:root.id},
  ]);
});

test('facet options search the full matching dataset, retain other filters, and deduplicate identity snapshots',dbOptions,async t=>{
  const f=await fixture(t),actor=randomUUID();
  await f.operation({initiator_id:actor,initiator_name:'First Name',initiator_short_id:'71',source:'web'});
  await f.operation({initiator_id:actor,initiator_name:'Updated Name',initiator_short_id:'71',source:'web',status:'pending'});
  await f.operation({initiator_id:randomUUID(),initiator_name:'Outside',source:'android'});
  const parsed=filters({source:{values:['web']},initiator_id:{values:[]}},'operations',{limit:'1'});
  const rows=await f.options(parsed,'initiator_id');
  assert.equal(rows.length,1);
  assert.equal(rows[0].value,actor);
  assert.ok(rows[0].label.includes(actor) && rows[0].label.includes('71'));
  assert.equal((await f.options(parsed,'initiator_id','first name'))[0].value,actor);
  assert.equal((await f.options(parsed,'initiator_id','71'))[0].value,actor);
  assert.deepEqual(await f.options(parsed,'status'),[]);
  assert.equal((await f.options(filters({source:{values:['web']}},'operations',{status:'completed'}),'status')).length,1);
});

test('facet literal search escapes wildcard characters and searches executor names and IDs',dbOptions,async t=>{
  const f=await fixture(t),operation=await f.operation();
  await f.event(operation.id,{executor_id:'worker-1',executor_name:'literal %_\\ name'});
  await f.event(operation.id,{executor_id:'worker-2',executor_name:'literal anything name'});
  assert.deepEqual(await f.options(filters({},'events'),'executor_id','%_\\'),[
    {value:'worker-1',label:'literal %_\\ name / worker-1'},
  ]);
  assert.equal((await f.options(filters({},'events'),'executor_id','WORKER-2'))[0].value,'worker-2');
});

test('facets search localized action, status and event labels while retaining code fallback',dbOptions,async t=>{
  const f=await fixture(t),operation=await f.operation();
  await f.operation({action:'unlisted_action',status:'unlisted_status'});
  await f.event(operation.id,{kind:'operation_started'});
  await f.event(operation.id,{kind:'unlisted_kind'});
  assert.deepEqual(await f.options(filters({}),'action','שליחת הודעה'),[
    {value:'send_message',label:'שליחת הודעה'},
  ]);
  assert.deepEqual(await f.options(filters({}),'status','הושלם'),[
    {value:'completed',label:'הושלם'},
  ]);
  assert.deepEqual(await f.options(filters({},'events'),'kind','הפעולה החלה'),[
    {value:'operation_started',label:'הפעולה החלה'},
  ]);
  assert.equal((await f.options(filters({}),'action','SEND_MESSAGE'))[0].value,'send_message');
  assert.deepEqual(await f.options(filters({},'events'),'kind','unlisted'),[
    {value:'unlisted_kind',label:'unlisted_kind'},
  ]);
});

test('options endpoint is admin protected, bounded, ignores cursors and returns input failures',dbOptions,async t=>{
  const f=await fixture(t);
  assert.equal(f.routes['/api/admin/audit/filter-options'][0],f.admin);
  const unauthorized=await f.call('/api/admin/audit/filter-options',{column:'status'},null);
  assert.equal(unauthorized.statusCode,401);
  await f.db.query(`INSERT INTO audit_operations(id,action,source,status)
    SELECT md5('source-'||n)::uuid,'send_message','source-'||lpad(n::text,3,'0'),'completed'
    FROM generate_series(1,105) n`);
  const result=await f.call('/api/admin/audit/filter-options',{column:'source',limit:'1',before:'invalid-cursor'});
  assert.equal(result.statusCode,200);
  assert.equal(result.headers['Cache-Control'],'no-store');
  assert.equal(result.body.options.length,100);
  assert.equal(result.body.hasMore,true);
  const searched=await f.call('/api/admin/audit/filter-options',{column:'source',search:'source-105'});
  assert.deepEqual(searched.body,{options:[{value:'source-105',label:'source-105'}],hasMore:false});
  for (const query of [{column:'created_at'},{column:'status',mode:'invalid'},
    {column:'status',search:[]},{column:'status',columnFilters:'[]'}])
    assert.equal((await f.call('/api/admin/audit/filter-options',query)).statusCode,400);
});

test('list pagination and CSV export apply identical column filters',dbOptions,async t=>{
  const f=await fixture(t);
  const wanted=await f.operation({reason_code:'selected'});
  const second=await f.operation({reason_code:'selected'});
  await f.operation({reason_code:'other'});
  const query={from:'2026-09-24T00:00:00Z',to:'2026-09-25T00:00:00Z',
    columnFilters:JSON.stringify({reason_code:{values:['selected']}})};
  const page1=await f.call('/api/admin/audit/operations',{...query,limit:'1'});
  assert.ok(page1.body.nextCursor);
  const page2=await f.call('/api/admin/audit/operations',{...query,limit:'1',before:page1.body.nextCursor});
  assert.equal(page2.body.nextCursor,null);
  assert.deepEqual([...page1.body.operations,...page2.body.operations].map(row=>row.id).sort(),[wanted.id,second.id].sort());
  const exported=await f.call('/api/admin/audit/export.csv',{...query,mode:'operations'});
  assert.equal(exported.statusCode,200);
  assert.equal(exported.headers['X-Audit-Export-Count'],'2');
  const ids=exported.body.split('\r\n').slice(1,-1).map(line=>line.split(',')[0].replaceAll('"',''));
  assert.deepEqual(ids.sort(),[wanted.id,second.id].sort());
});

test('check filters intersect on the same event and operation exclusions apply to the whole chain',dbOptions,async t=>{
  const f=await fixture(t);
  const mixed=await f.operation(),clean=await f.operation(),blocked=await f.operation();
  const legacy=await f.operation(),unrelated=await f.operation();
  const check=(root,checkType,checkOutcome)=>f.event(root.id,{kind:'provider_call_finished',source:'provider_usage',
    details:{checkType,...(checkOutcome?{checkOutcome}:{})}});
  const mixedPassed=await check(mixed,'safe_search','passed');
  const mixedBlocked=await check(mixed,'modesty','blocked');
  const cleanPassed=await check(clean,'safe_search','passed');
  const blockedCheck=await check(blocked,'safe_search','blocked');
  const legacyCheck=await f.event(legacy.id,{kind:'provider_call_finished',status:'completed',
    details:{provider:'google_vision',operation:'safe_search'}});
  const unrelatedEvent=await f.event(unrelated.id,{kind:'message_persisted',status:'completed'});
  const ids=async(columns,mode='operations',extra={})=>(await f.select(filters(columns,mode,extra))).map(row=>row.id).sort();
  const selected={check_type:{values:['safe_search']},check_outcome:{values:['blocked']}};
  assert.deepEqual(await ids(selected,'events'),[blockedCheck.id]);
  assert.deepEqual(await ids({check_type:{values:['safe_search']},check_outcome:{values:['passed']}},'events'),
    [mixedPassed.id,cleanPassed.id].sort());
  assert.deepEqual(await ids({check_outcome:{values:['not_recorded']}},'events'),[legacyCheck.id]);
  assert.deepEqual(await ids({check_outcome:{values:['blocked'],exclude:true}},'events'),
    [mixedPassed.id,cleanPassed.id,legacyCheck.id,unrelatedEvent.id].sort());
  for(const extra of [{},{match:'chain'}]) {
    assert.deepEqual(await ids(selected,'operations',extra),[blocked.id]);
    assert.deepEqual(await ids({check_type:{values:['safe_search']},check_outcome:{values:['passed']}},'operations',extra),
      [mixed.id,clean.id].sort());
    assert.deepEqual(await ids({check_type:{values:['safe_search']},check_outcome:{values:['blocked'],exclude:true}},'operations',extra),
      [clean.id,legacy.id].sort());
    assert.deepEqual(await ids({check_type:{values:['modesty'],exclude:true}},'operations',extra),
      [clean.id,blocked.id,legacy.id,unrelated.id].sort());
    assert.deepEqual(await ids({check_outcome:{values:['not_recorded']}},'operations',extra),[legacy.id]);
  }
  assert.notEqual(mixedBlocked.id,blockedCheck.id);
});

test('check facets localize values and apply the other check column on the same event',dbOptions,async t=>{
  const f=await fixture(t),root=await f.operation(),outside=await f.operation();
  await f.event(root.id,{kind:'provider_call_finished',details:{checkType:'safe_search',checkOutcome:'passed'}});
  await f.event(root.id,{kind:'provider_call_finished',details:{checkType:'modesty',checkOutcome:'blocked'}});
  await f.event(root.id,{kind:'provider_call_finished',details:{operation:'safe_search'}});
  await f.event(root.id,{kind:'provider_call_finished',details:{checkType:'face_detection',checkOutcome:'passed'}});
  await f.event(outside.id,{kind:'provider_call_finished',details:{checkType:'face_detection',checkOutcome:'failed'}});
  for(const [mode,extra] of [['events',{}],['operations',{}],['operations',{match:'chain'}]]) {
    const selected=filters({check_type:{values:['modesty']},check_outcome:{values:['passed']}},mode,extra);
    assert.deepEqual(await f.options(selected,'check_type'),[
      {value:'face_detection',label:CHECK_TYPE_LABELS.face_detection},
      {value:'safe_search',label:CHECK_TYPE_LABELS.safe_search},
    ]);
    assert.deepEqual(await f.options(selected,'check_type','וספירת'),[
      {value:'face_detection',label:CHECK_TYPE_LABELS.face_detection},
    ]);
    const safeSearch=filters({check_type:{values:['safe_search']},check_outcome:{values:['blocked']}},mode,extra);
    assert.deepEqual(await f.options(safeSearch,'check_outcome'),[
      {value:'not_recorded',label:CHECK_OUTCOME_LABELS.not_recorded},
      {value:'passed',label:CHECK_OUTCOME_LABELS.passed},
    ]);
    assert.deepEqual(await f.options(safeSearch,'check_outcome','לא תועדה'),[
      {value:'not_recorded',label:CHECK_OUTCOME_LABELS.not_recorded},
    ]);
  }
  const response=await f.call('/api/admin/audit/filter-options',{mode:'events',column:'check_type',
    columnFilters:JSON.stringify({check_outcome:{values:['blocked']}})});
  assert.equal(response.statusCode,200);
  assert.deepEqual(response.body,{options:[{value:'modesty',label:CHECK_TYPE_LABELS.modesty}],hasMore:false});
});

test('event APIs and CSV expose localized check evidence without inventing legacy outcomes',dbOptions,async t=>{
  const f=await fixture(t),root=await f.operation();
  const face=await f.event(root.id,{kind:'provider_call_finished',executor_type:'provider',executor_id:'google_vision',
    details:{checkType:'face_detection',checkOutcome:'passed',checkFindings:['faces_detected'],
      checkFaceCount:2,checkConfidencePct:98,cacheHit:true,frameIndex:1,frameTimestampMs:500}});
  const legacy=await f.event(root.id,{kind:'provider_call_finished',status:'completed',
    details:{provider:'openai',operation:'modesty'}});
  const ordinary=await f.event(root.id,{kind:'message_persisted',status:'completed'});
  const query={from:'2026-09-24T00:00:00Z',to:'2026-09-25T00:00:00Z'};
  for(const [route,params] of [['/api/admin/audit/events',{}],['/api/admin/audit/operations/:id/events',{id:root.id}]]) {
    const response=await f.call(route,query,{id:f.userId},params);
    assert.equal(response.statusCode,200);
    const rows=new Map(response.body.events.map(row=>[row.id,row]));
    assert.equal(rows.get(face.id).checkLabel,CHECK_TYPE_LABELS.face_detection);
    assert.equal(rows.get(face.id).check_outcome,'passed');
    assert.match(rows.get(face.id).checkResultLabel,/מספר פנים: 2/);
    assert.match(rows.get(face.id).checkResultLabel,/רמת ביטחון: 98%/);
    assert.match(rows.get(face.id).checkResultLabel,/מתוצאה שמורה/);
    assert.equal(rows.get(legacy.id).check_outcome,'not_recorded');
    assert.equal(rows.get(legacy.id).checkResultLabel,'תוצאה לא תועדה');
    assert.equal(rows.get(ordinary.id).checkLabel,undefined);
  }
  const selected={...query,columnFilters:JSON.stringify({check_type:{values:['face_detection']},
    check_outcome:{values:['passed']}})};
  const exported=await f.call('/api/admin/audit/export.csv',{...selected,mode:'events'});
  assert.equal(exported.statusCode,200);
  assert.equal(exported.headers['X-Audit-Export-Count'],'1');
  const lines=exported.body.split('\r\n');
  assert.match(lines[0],/"check_type","check_outcome","checkLabel","checkResultLabel"$/);
  assert.ok(lines[1].startsWith(`"${face.id}",`));
  assert.ok(lines[1].includes(CHECK_TYPE_LABELS.face_detection));
  assert.ok(lines[1].includes('מספר פנים: 2'));
  assert.ok(lines[1].includes('רמת ביטחון: 98%'));
  assert.equal(lines.length,3);
  const roots=await f.call('/api/admin/audit/operations',{...selected,match:'chain'});
  assert.equal(roots.statusCode,200);
  assert.deepEqual(roots.body.operations.map(row=>row.id),[root.id]);
  assert.equal(roots.body.operations[0].checkResultLabel,undefined);
});

test('displayed action facets and filters distinguish captures from uploads using parent context',dbOptions,async t=>{
 const f=await fixture(t),cases=[
  ['capture:camera_video','צילום וידאו',{action:'upload_file',media_type:'video',capture_kind:'camera_video'}],
  ['capture:camera_image','צילום תמונה',{action:'upload_file',media_type:'image',capture_kind:'camera_image'}],
  ['capture:microphone','הקלטת קול',{action:'upload_file',media_type:'audio',capture_kind:'microphone'}],
  ['media:video','העלאת וידאו',{action:'upload_file',media_type:'video',capture_kind:'picker'}],
  ['media:image','העלאת תמונה',{action:'upload_file',media_type:'image'}],
  ['media:audio','העלאת קובץ קול',{action:'upload_file',media_type:'audio'}],
  ['media:document','העלאת מסמך',{action:'upload_file',media_type:'document'}],
  ['upload_file','העלאת קובץ',{action:'upload_file'}],
  ['upload_file','העלאת קובץ',{action:'upload_file',capture_kind:'camera_video'}],
  ['media:image','העלאת תמונה',{action:'upload_file',media_type:'image',capture_kind:'camera_video'}],
  ['send_message','שליחת הודעה',{action:'send_message',media_type:'video',capture_kind:'camera_video'}],
  [null,'(ריק)',{action:null}],
 ];
 const records=[];
 for(const [code,label,fields]of cases){const root=await f.operation(fields),event=await f.event(root.id,{kind:'upload_context'});records.push({code,label,root,event});}
 for(const mode of ['operations','events']){
  const extra=mode==='operations'?{steps:'1',match:'items'}:{};
  const options=await f.options(filters({},mode,extra),'display_action');
  assert.deepEqual(Object.fromEntries(options.map(o=>[o.value,o.label])),Object.fromEntries(records.map(r=>[r.code,r.label])));
  const matches=async(values,exclude=false)=>f.select(filters({display_action:{values,exclude}},mode,extra));
  for(const {code}of records){assert.deepEqual((await matches([code])).map(row=>String(row.id)).sort(),records.filter(r=>r.code===code).map(r=>String(mode==='operations'?r.root.id:r.event.id)).sort());}
  const codes=['capture:camera_video','media:video'];
  for(const exclude of [false,true])assert.equal((await matches(codes,exclude)).length,records.filter(r=>codes.includes(r.code)!==exclude).length);
  assert.equal((await matches([],false)).length,0);assert.equal((await matches([],true)).length,records.length);
  assert.deepEqual(await f.options(filters({},mode,extra),'display_action','צילום וידאו'),[{value:'capture:camera_video',label:'צילום וידאו'}]);
  assert.equal((await f.options(filters({display_action:{values:['capture:camera_video']}},mode,extra),'display_action')).length,options.length);
  assert.deepEqual(await f.options(filters({},mode,extra),'display_action',"%' OR TRUE --"),[]);
 }
 // Legacy raw upload filters still include every upload; no recorded action is rewritten.
 assert.equal((await f.select(filters({action:{values:['upload_file']}}))).length,10);
 const selected=await f.call('/api/admin/audit/operations',{steps:'1',match:'items',columnFilters:JSON.stringify({display_action:{values:['capture:camera_video']}})});
 assert.equal(selected.statusCode,200);assert.equal(selected.body.operations.length,1);assert.equal(selected.body.operations[0].first_sub_event.id,records[0].event.id);
 // Derived sort keys paginate consistently for both views and both directions.
 for(const mode of ['operations','events'])for(const direction of ['asc','desc']){
  const ids=[];let before;
  do{const response=await f.call(`/api/admin/audit/${mode}`,{sort:'display_action',direction,limit:'2',...(before?{before}:{})});assert.equal(response.statusCode,200);ids.push(...response.body[mode].map(row=>String(row.id)));before=response.body.nextCursor;}while(before);
  assert.equal(ids.length,records.length);assert.equal(new Set(ids).size,records.length);
 }
});

test('all separate data fields filter and sort server-side with scalar values and localized facets',dbOptions,async t=>{
 const f=await fixture(t),parentId=randomUUID();
 const op=await f.operation({action:'upload_file',media_type:'video',capture_kind:'camera_video',initiator_short_id:'10',recipient_short_id:'5',status:'failed',status_source:'scan_workflow_finished',reason_code:'scan_stopped',event_count:'3',duration_ms:'27000'});
 const opening=await f.event(op.id,{kind:'operation_started'});await f.db.query('UPDATE audit_operations SET root_event_id=$1 WHERE id=$2',[opening.id,op.id]);
 const details={provider:'gemini',frameIndex:3,frameTimestampMs:1500,cacheHit:true,checkPersonCount:2,checkFaceCount:1,checkConfidencePct:97,httpStatus:200,affectedCount:6,previousStatus:'pending',nextStatus:'completed',beforeWomen:true,afterWomen:false,beforeEnforceGeneralFilter:false,afterEnforceGeneralFilter:true};
 const first=await f.event(op.id,{created_at:'2026-09-24T10:00:01.500Z',kind:'http_response',status:'completed',reason_code:'http_200',executor_type:'system',executor_id:'api',parent_event_id:opening.id,attempt:2,details:JSON.stringify(details)});
 const terminal=await f.event(op.id,{created_at:'2026-09-24T10:00:27Z',kind:'scan_workflow_finished',status:'failed',operation_status:'failed',reason_code:'scan_incomplete',details:JSON.stringify({providerCallsUsed:29,providerCallsLimit:36})});
 const other=await f.operation({id:parentId,initiator_short_id:'11',recipient_short_id:'6'});await f.event(other.id,{executor_type:'worker',executor_id:'other',details:JSON.stringify({frameIndex:'bad',frameTimestampMs:'999999999999999999999999',checkPersonCount:-1,checkFaceCount:null,cacheHit:'false'})});
 const scalar={operation_status:'failed',initiator_identifier:'10',recipient_identifier:'5',operation_id:op.id,step_total:'2',step_index:'1',executor_identifier:'api',executor_type:'system',event_id:first.id,parent_event_id:opening.id,attempt:'2',step_reason:'http_200',step_reason_code:'http_200',before_value:'pending',after_value:'completed',change_context:'הגדרות סינון',event_explanation:'http_response',elapsed_ms:'1500',provider:'gemini',frame_index:'4',frame_timestamp:'1500',cache_hit:'true',person_count:'2',face_count:'1',confidence:'97',http_status:'200',affected_count:'6',beforeWomen:'true',afterWomen:'false',beforeEnforceGeneralFilter:'false',afterEnforceGeneralFilter:'true'};
 const {FIELDS}=require('../server/audit-field-filters');
 for(const mode of ['operations','events']){
  const extra=mode==='operations'?{steps:'1',match:'items'}:{};
  for(const [column,expected]of Object.entries(scalar)){
   const type=FIELDS[column][0],filter=type==='number'?{min:String(expected),max:String(expected)}:{values:[String(expected)]};
   const selected=await f.select(filters({[column]:filter},mode,extra));
   assert.ok(selected.some(row=>String(row.id)===String(mode==='operations'?op.id:first.id)),`${mode}/${column} inclusion`);
   if(!['step_total','step_index'].includes(column))assert.ok(!selected.some(row=>mode==='operations'?row.id===other.id:row.operation_id===other.id),`${mode}/${column} excludes other`);
  }
  const opReason=mode==='operations'?'scan_incomplete':'scan_stopped';
  for(const field of ['operation_reason','operation_reason_code'])assert.ok((await f.select(filters({[field]:{values:[opReason]}},mode,extra))).length);
  assert.ok((await f.options(filters({},mode,extra),'step_reason','השרת השיב בהצלחה')).some(row=>row.value==='http_200'));
  assert.ok((await f.options(filters({},mode,extra),'beforeWomen')).some(row=>row.value==='true'&&row.label==='מותר'));
  assert.ok((await f.options(filters({},mode,extra),'provider')).some(row=>row.value==='gemini'&&row.label==='Gemini'));
  for(const [column,[type]]of Object.entries(FIELDS)){
   // Execute every virtual expression, including blanks and invalid legacy metadata.
   const sorted=await f.select(filters({},mode,{...extra,sort:column,direction:'asc'}));assert.ok(sorted.length,`${mode}/${column} sort`);
   if(type!=='number'&&type!=='decimal')assert.ok((await f.options(filters({},mode,extra),column)).length,`${mode}/${column} options`);
  }
 }
 for(const [column,value]of [['provider_calls_used','29'],['provider_calls_limit','36']]){
  const result=await f.call('/api/admin/audit/operations',{steps:'1',match:'items',columnFilters:JSON.stringify({[column]:{min:value,max:value},kind:{values:['http_response']}})});
  assert.equal(result.statusCode,200);assert.equal(result.body.operations[0].first_sub_event.id,first.id);assert.equal(result.body.operations.length,1);
  const events=await f.select(filters({[column]:{min:value,max:value}},'events'));assert.deepEqual(events.map(row=>row.id),[terminal.id]);
 }
 // Ordinals are measured before filtering and do not reset to 1.
 const index=await f.call('/api/admin/audit/operations',{steps:'1',match:'items',columnFilters:JSON.stringify({step_index:{min:'2',max:'2'}})});
 assert.equal(index.statusCode,200);assert.equal(index.body.operations[0].first_sub_event.sub_event_index,'2');
 // A filter and a sort may both carry parameters; cursor bounds must still use the requested page size.
 const sorted=await f.call('/api/admin/audit/operations',{steps:'1',match:'items',sort:'step_reason',direction:'asc',limit:'1',columnFilters:JSON.stringify({executor_type:{values:['system']}})});
 assert.equal(sorted.statusCode,200);assert.equal(sorted.body.operations.length,1);
 await f.event(op.id,{created_at:'2026-09-24T10:00:28Z',details:JSON.stringify({affectedCount:1})});
 await f.db.query(`UPDATE audit_events SET details=details||'{"affectedCount":3}'::jsonb WHERE operation_id=$1`,[other.id]);
 const ordered=await f.call('/api/admin/audit/operations',{steps:'1',match:'items',sort:'affected_count',direction:'asc'});
 assert.equal(ordered.statusCode,200);assert.deepEqual(ordered.body.operations.map(row=>row.id),[other.id,op.id]);
 const sameStep=await f.select(filters({provider:{values:['gemini']},executor_identifier:{values:['other']}},'operations',{steps:'1',match:'items'}));assert.equal(sameStep.length,0);
});
