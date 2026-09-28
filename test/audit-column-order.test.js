'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const {randomUUID}=require('node:crypto');
const {Client}=require('pg');
const {AUDIT_COLUMN_ORDER_SQL,COLUMN_IDS,registerAuditColumnOrderRoutes}=require('../server/audit-column-order');

function routes(db) {
  const handlers=new Map(),admin=(_req,_res,next)=>next();
  const app=Object.fromEntries(['get','put'].map(method=>[method,(path,middleware,handler)=>{
    assert.equal(middleware,admin);handlers.set(`${method} ${path}`,handler);
  }]));
  registerAuditColumnOrderRoutes(app,{getPool:async()=>db,adminMiddleware:admin});
  return async(method,{userId,mode,order,body,resource='column-order',query={}}={})=>{
    const res={statusCode:200,status(code){this.statusCode=code;return this;},
      set(key,value){this[key]=value;return this;},json(value){this.body=value;return this;}};
    await handlers.get(`${method} /api/admin/audit/${resource}${method==='put'?'/:mode':''}`)(
      {query,user:userId?{id:userId}:undefined,adminPerm:'view',params:{mode},body:body||{order}},res);
    assert.equal(res['Cache-Control'],'no-store');return res;
  };
}

test('column order routes require authentication and reject malformed orders before SQL',async()=>{
  const call=routes({query(){throw new Error('Unexpected database query');}}),userId=randomUUID();
  for(const method of ['get','put'])assert.equal((await call(method)).statusCode,401);
  for(const [mode,order]of [['__proto__',[]],['invalid',[]],['events',null],['events',{}],
    ['events',[]],['events',COLUMN_IDS.operations],['events',Array(13).fill('created_at')],
    ['events',[...COLUMN_IDS.events.slice(1),'DROP TABLE users']]])
    assert.equal((await call('put',{userId,mode,order})).statusCode,400);
});

test('column orders persist per account and view, update independently, and cascade on account deletion',{
  skip:process.env.RUN_DB_TESTS!=='1',
},async t=>{
  const db=new Client({connectionString:process.env.DATABASE_URL,
    ssl:process.env.DB_SSL==='true'?{rejectUnauthorized:process.env.DB_REJECT_UNAUTHORIZED!=='false'}:false});
  await db.connect();const schema=`column_order_test_${randomUUID().replaceAll('-','')}`;
  await db.query(`CREATE SCHEMA "${schema}"`);
  t.after(async()=>{await db.query(`DROP SCHEMA "${schema}" CASCADE`);await db.end();});
  await db.query(`SET search_path TO "${schema}"`);
  await db.query('CREATE TABLE users(id uuid PRIMARY KEY)');
  await db.query(AUDIT_COLUMN_ORDER_SQL);
  const first=randomUUID(),second=randomUUID();
  await db.query('INSERT INTO users VALUES($1),($2)',[first,second]);
  const call=routes(db),operations=COLUMN_IDS.operations.slice().reverse(),events=COLUMN_IDS.events.slice().reverse();
  assert.deepEqual((await call('get',{userId:first})).body,{orders:{},widths:{}});
  for(const [userId,mode,order]of [[first,'operations',operations],[first,'events',events],[second,'events',COLUMN_IDS.events]])
    assert.equal((await call('put',{userId,mode,order,body:{order,userId:second}})).statusCode,200);
  // A new route instance has no in-memory state and reads the stored account layout.
  assert.deepEqual((await routes(db)('get',{userId:first})).body,{orders:{operations,events},widths:{operations:{},events:{}}});
  assert.deepEqual((await call('get',{userId:second})).body,{orders:{events:COLUMN_IDS.events},widths:{events:{}}});
  await call('put',{userId:first,mode:'operations',order:COLUMN_IDS.operations});
  assert.deepEqual((await call('get',{userId:first})).body,{orders:{operations:COLUMN_IDS.operations,events},widths:{operations:{},events:{}}});
  await call('put',{userId:first,mode:'events',resource:'column-widths',body:{widths:{created_at:310},userId:second}});
  assert.deepEqual((await routes(db)('get',{userId:first})).body,{orders:{operations:COLUMN_IDS.operations,events},widths:{operations:{},events:{created_at:310}}});
  assert.deepEqual((await call('get',{userId:second})).body.widths,{events:{}});
  await call('put',{userId:first,mode:'events',order:COLUMN_IDS.events});
  assert.deepEqual((await call('get',{userId:first})).body.widths.events,{created_at:310});
  await call('put',{userId:first,mode:'events',resource:'column-widths',body:{widths:{}}});
  assert.deepEqual((await call('get',{userId:first})).body.widths.events,{});
  await db.query('DELETE FROM users WHERE id=$1',[first]);
  assert.deepEqual((await db.query('SELECT DISTINCT user_id FROM audit_column_orders')).rows,[{user_id:second}]);
});

test('column widths require authentication and validate column IDs and bounded integer widths',async()=>{
  const writes=[],call=routes({async query(sql,params){writes.push({sql,params});return {rows:[]};}}),userId=randomUUID();
  assert.equal((await call('put',{resource:'column-widths'})).statusCode,401);
  for(const [mode,widths]of [['invalid',{}],['__proto__',{}],['events',null],['events',[]],['events','bad'],
    ['events',{unknown:100}],['events',{expand:100}],['events',{created_at:47}],['events',{created_at:1201}],
    ['events',{created_at:100.5}],['events',{created_at:'100'}]])
    assert.equal((await call('put',{resource:'column-widths',userId,mode,body:{widths}})).statusCode,400);
  assert.equal(writes.length,0);
  for(const widths of [{created_at:48,details:1200},{}]){
    const result=await call('put',{resource:'column-widths',userId,mode:'events',body:{widths,userId:randomUUID()}});
    assert.equal(result.statusCode,200);assert.deepEqual(result.body,{mode:'events',widths});
    assert.equal(writes.at(-1).params[0],userId);assert.deepEqual(JSON.parse(writes.at(-1).params[3]),widths);
  }
});

test('older operation layouts gain the sub-action column without losing custom positions',async()=>{
  const call=routes({async query(){return {rows:[]};}}),userId=randomUUID();
  const legacy=COLUMN_IDS.operations.filter(key=>key!=='kind').reverse();
  const response=await call('put',{userId,mode:'operations',order:legacy});
  assert.equal(response.statusCode,200);
  const expected=legacy.slice();expected.splice(expected.indexOf('action')+1,0,'kind');
  assert.deepEqual(response.body.order,expected);
});

test('existing layouts gain the scanned image name immediately before the custom preview position',async()=>{
  const call=routes({async query(){return {rows:[]};}}),userId=randomUUID();
  for(const mode of ['operations','events']){
    const legacy=COLUMN_IDS[mode].filter(key=>key!=='scan_image').reverse();
    const response=await call('put',{userId,mode,order:legacy});
    assert.equal(response.statusCode,200);
    const expected=legacy.slice();expected.splice(expected.indexOf('preview'),0,'scan_image');
    assert.deepEqual(response.body.order,expected);
  }
});

test('legacy layouts gain explanation fields in both modes and their widths can be saved',async()=>{
  const writes=[],call=routes({async query(sql,params){writes.push(params);return {rows:[]};}}),userId=randomUUID();
  const added=['change_context','before_value','after_value','event_explanation'];
  for(const mode of ['operations','events']){
    const legacy=COLUMN_IDS[mode].filter(key=>!added.includes(key)).reverse();
    const result=await call('put',{userId,mode,order:legacy});assert.equal(result.statusCode,200);
    const expected=legacy.slice();expected.splice(expected.indexOf('kind')+1,0,...added);assert.deepEqual(result.body.order,expected);
    assert.deepEqual(result.body.order.filter(key=>!added.includes(key)),legacy);
    const widths=Object.fromEntries(added.map(key=>[key,260]));
    assert.equal((await call('put',{userId,mode,resource:'column-widths',body:{widths}})).statusCode,200);
    assert.deepEqual(JSON.parse(writes.at(-1)[3]),widths);
  }
});

test('split actor columns migrate old layouts and accept separate saved widths',async()=>{
  const call=routes({async query(){return {rows:[]};}}),userId=randomUUID();
  for(const [mode,added,anchor]of [['operations','executor_id','initiator_id'],['events','initiator_id','executor_id']]){
    const legacy=COLUMN_IDS[mode].filter(key=>key!==added).reverse();
    const result=await call('put',{userId,mode,order:legacy});assert.equal(result.statusCode,200);
    assert.deepEqual(result.body.order.filter(key=>key!==added),legacy);
    assert.equal(result.body.order.indexOf('executor_id'),result.body.order.indexOf('initiator_id')+1);
    assert.equal((await call('put',{userId,mode,resource:'column-widths',body:{widths:{initiator_id:230,executor_id:190}}})).statusCode,200);
  }
});

test('duration columns migrate beside the original total column and retain existing saved positions',async()=>{
 const call=routes({async query(){return {rows:[]};}}),userId=randomUUID();
 for(const mode of ['operations','events']){
  const legacy=COLUMN_IDS[mode].filter(key=>key!=='elapsed_ms'&&(mode!=='events'||key!=='duration_ms')).reverse();
  const result=await call('put',{userId,mode,order:legacy});assert.equal(result.statusCode,200);
  assert.deepEqual(result.body.order.filter(key=>legacy.includes(key)),legacy);
  assert.equal(result.body.order.indexOf('duration_ms'),result.body.order.indexOf('elapsed_ms')+1);
  assert.equal((await call('put',{userId,mode,resource:'column-widths',body:{widths:{elapsed_ms:140,duration_ms:200}}})).statusCode,200);
 }
});


test('pre-split layouts gain every separate value while retaining the order and widths of existing columns',async()=>{
 const writes=[],call=routes({async query(sql,params){writes.push(params);return {rows:[]};}}),userId=randomUUID();
 const legacy={operations:['expand','created_at','action','kind','change_context','before_value','after_value','event_explanation','check_type','check_outcome','initiator_id','executor_id','recipient_id','target_type','source','status','reason_code','event_count','elapsed_ms','duration_ms','details'],events:['created_at','kind','change_context','before_value','after_value','event_explanation','check_type','check_outcome','initiator_id','executor_id','recipient_id','source','status','target_type','reason_code','attempt','operation_id','elapsed_ms','duration_ms','details']};
 for(const mode of ['operations','events']){
  const order=legacy[mode].slice().reverse(),response=await call('put',{userId,mode,order});assert.equal(response.statusCode,200);
  assert.deepEqual(response.body.order.filter(key=>order.includes(key)),order);assert.deepEqual(response.body.order.slice().sort(),COLUMN_IDS[mode].slice().sort());
  const widths={action:280,initiator_id:270,initiator_identifier:150,operation_status:200,beforeWomen:180};
  assert.equal((await call('put',{userId,mode,resource:'column-widths',body:{widths}})).statusCode,200);assert.deepEqual(JSON.parse(writes.at(-1)[3]),widths);
  assert.equal((await call('put',{userId,mode,order:order.filter(key=>key!=='created_at')})).statusCode,400);
 }
});

test('merged step column accepts old layouts and widths without retaining a duplicate header',async()=>{
 const writes=[],call=routes({async query(sql,params){writes.push(params);return {rows:[]};}}),userId=randomUUID();
 const legacy=COLUMN_IDS.operations.slice().reverse();legacy.splice(legacy.indexOf('step_index'),0,'step_total');
 const result=await call('put',{userId,mode:'operations',order:legacy});assert.equal(result.statusCode,200);assert.deepEqual(result.body.order,COLUMN_IDS.operations.slice().reverse());
 assert.equal((await call('put',{userId,mode:'operations',order:[...legacy,'step_total']})).statusCode,400);
 assert.equal((await call('put',{userId,mode:'operations',resource:'column-widths',body:{widths:{step_index:150,step_total:100}}})).statusCode,200);
 assert.deepEqual(JSON.parse(writes.at(-1)[3]),{step_index:150,step_total:100});
 assert.equal((await call('put',{userId,mode:'events',resource:'column-widths',body:{widths:{step_total:100}}})).statusCode,400);
 assert.equal((await call('put',{userId,mode:'operations',resource:'column-widths',body:{widths:{step_total:20}}})).statusCode,400);
});

test('settings reject malformed formats and permutations before any SQL',async()=>{
 const call=routes({query(){throw Error('Unexpected SQL');}}),userId=randomUUID(),order=COLUMN_IDS.operations;
 for(const formats of [null,[],{unknown:{type:'text'}},{cost_ils:{type:'number',decimals:99,grouping:true}},{created_at:{type:'date',pattern:'<script>'}},{details:{type:'number',decimals:2,grouping:true}}])assert.equal((await call('put',{userId,mode:'operations',resource:'column-settings',body:{order,formats}})).statusCode,400);
 assert.equal((await call('put',{userId,mode:'operations',resource:'column-settings',body:{order:order.slice(1),formats:{}}})).statusCode,400);
});
test('settings save order and formats atomically per account/mode and preserve widths and old-tab writes',{skip:process.env.RUN_DB_TESTS!=='1'},async t=>{
 const db=new Client({connectionString:process.env.DATABASE_URL,ssl:false});await db.connect();const schema='settings_'+randomUUID().replaceAll('-','');await db.query(`CREATE SCHEMA "${schema}";SET search_path TO "${schema}";CREATE TABLE users(id uuid PRIMARY KEY)`);t.after(async()=>{await db.query(`DROP SCHEMA "${schema}" CASCADE`);await db.end();});await db.query(AUDIT_COLUMN_ORDER_SQL);
 const a=randomUUID(),b=randomUUID();await db.query('INSERT INTO users VALUES($1),($2)',[a,b]);const call=routes(db),order=COLUMN_IDS.operations.slice().reverse(),formats={cost_ils:{type:'currency',decimals:6,grouping:true,currency:'ILS'}};
 await call('put',{userId:a,mode:'operations',resource:'column-widths',body:{widths:{cost_ils:200}}});
 const saved=await call('put',{userId:a,mode:'operations',resource:'column-settings',body:{order,formats,userId:b}});assert.equal(saved.statusCode,200);
 assert.deepEqual((await call('get',{userId:a,query:{formats:'1'}})).body.formats,{operations:formats});
 let row=(await db.query('SELECT * FROM audit_column_orders WHERE user_id=$1',[a])).rows[0];assert.deepEqual(row.column_formats,formats);assert.deepEqual(row.column_order,order);assert.deepEqual(row.column_widths,{cost_ils:200});assert.equal((await db.query('SELECT * FROM audit_column_orders WHERE user_id=$1',[b])).rows.length,0);
 await call('put',{userId:a,mode:'operations',order:COLUMN_IDS.operations});await call('put',{userId:a,mode:'operations',resource:'column-widths',body:{widths:{cost_ils:250}}});row=(await db.query('SELECT * FROM audit_column_orders WHERE user_id=$1',[a])).rows[0];assert.deepEqual(row.column_formats,formats);
 await call('put',{userId:a,mode:'events',resource:'column-settings',body:{order:COLUMN_IDS.events,formats:{}}});
 await call('put',{userId:a,mode:'operations',resource:'column-settings',body:{order:COLUMN_IDS.operations,formats:{}}});row=(await db.query("SELECT * FROM audit_column_orders WHERE user_id=$1 AND mode='operations'",[a])).rows[0];assert.deepEqual(row.column_formats,{});assert.deepEqual(row.column_widths,{cost_ils:250});
});
