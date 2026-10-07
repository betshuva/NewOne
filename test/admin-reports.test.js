'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { registerAdminReportRoutes } = require('../server/admin-reports');
const id = '11111111-1111-4111-8111-111111111111';
const actor = '22222222-2222-4222-8222-222222222222';
function fixture(db) {
  const routes = {};
  const middleware = () => {};
  const app = Object.fromEntries(['get','put'].map(method => [method, (path, auth, handler) => {
    assert.equal(auth, middleware); routes[method] = handler;
  }]));
  registerAdminReportRoutes(app, { getPool: async () => db, adminMiddleware: middleware });
  return async (method, overrides = {}) => {
    const response = { statusCode: 200, headers: {}, set(k,v){this.headers[k]=v;return this;},
      status(code){this.statusCode=code;return this;}, json(body){this.body=body;return this;} };
    await routes[method]({ query:{},params:{id},user:{id:actor},adminPerm:'edit',
      body:{status:'resolved',revision:'123'},...overrides }, response);
    return response;
  };
}

test('read-only admins cannot modify reports, even with a valid payload', async () => {
  const call=fixture({query:()=>assert.fail('must reject before database access')});
  assert.equal((await call('put',{adminPerm:'view'})).statusCode,403);
});
test('invalid identifiers, states and missing revisions fail before database access', async () => {
  const call=fixture({query:()=>assert.fail('unexpected query')});
  for(const override of [{params:{id:"' OR TRUE"}},{body:{status:'removed',revision:'1'}},
    {body:{status:'resolved'}},{query:{status:'unknown'}},{query:{offset:'-1'}}]) {
    assert.equal((await call(override.query?'get':'put',override)).statusCode,400);
  }
});
test('a stale review is rejected and a deleted report returns not found', async () => {
  for(const present of [true,false]) {
    const call=fixture({query:async sql=>({rows:sql.startsWith('SELECT')&&present?[{}]:[]})});
    const response=await call('put');assert.equal(response.statusCode,present?409:404);
  }
});
test('pagination is bounded and sensitive report responses cannot be cached',async()=>{
  const call=fixture({query:async(sql,args)=>{assert.deepEqual(args,['pending',100]);return{rows:Array.from({length:101},(_,i)=>({id:i}))};}});
  const response=await call('get',{query:{offset:'100'}});
  assert.equal(response.body.length,100);assert.equal(response.headers['X-Has-More'],'true');
  assert.equal(response.headers['Cache-Control'],'no-store');
});
test('database error details are not returned to the browser',async()=>{
  const call=fixture({query:async()=>{throw Error('private database details');}});
  for(const method of ['get','put']){const response=await call(method);assert.equal(response.statusCode,500);assert.ok(!JSON.stringify(response.body).includes('private'));}
});

test('PostgreSQL report review preserves newer submissions and concurrent administrator changes',{
  skip:process.env.RUN_DB_TESTS!=='1',
},async()=>{
  const {Client}=require('pg');
  const db=new Client({connectionString:process.env.DATABASE_URL,connectionTimeoutMillis:10000,
    ssl:process.env.DB_SSL==='true'?{rejectUnauthorized:process.env.DB_REJECT_UNAUTHORIZED!=='false'}:false});
  await db.connect();
  try{
    await db.query('BEGIN');
    await db.query(`CREATE TEMP TABLE users(id uuid PRIMARY KEY,name text,email text) ON COMMIT DROP;
      CREATE TEMP TABLE groups(id uuid PRIMARY KEY,name text,description text) ON COMMIT DROP;
      CREATE TEMP TABLE listings(id uuid PRIMARY KEY,title text,description text) ON COMMIT DROP;
      CREATE TEMP TABLE messages(id uuid PRIMARY KEY,body text,file_name text,sender_id uuid,deleted_for_everyone boolean) ON COMMIT DROP;
      CREATE TEMP TABLE user_reports(id uuid PRIMARY KEY,reporter_id uuid,target_type text,target_id uuid,
        reason text,details text,status text,created_at timestamptz DEFAULT now(),reviewed_at timestamptz,
        reviewed_by uuid,notification_version integer DEFAULT 1,notified_version integer DEFAULT 0,notification_sent_at timestamptz) ON COMMIT DROP;
      SET LOCAL search_path=pg_temp,public`);
    await db.query('INSERT INTO users VALUES($1,$2,$3)',[actor,'Synthetic tester','synthetic@example.invalid']);
    await db.query("INSERT INTO user_reports(id,reporter_id,target_type,target_id,reason,status) VALUES($1,$2,'user',$2,'spam','pending')",[id,actor]);
    const call=fixture(db);
    let listed=await call('get');assert.equal(listed.statusCode,200);assert.equal(listed.body[0].target_summary,'Synthetic tester');
    const revision=listed.body[0].revision;
    // xmin changes per transaction, so use subtransactions to model intervening writers
    // without touching any persistent table or committing synthetic data.
    await db.query('SAVEPOINT resubmission');
    await db.query("UPDATE user_reports SET details='new evidence',notification_version=2");
    await db.query('RELEASE SAVEPOINT resubmission');
    assert.equal((await call('put',{body:{status:'resolved',revision}})).statusCode,409);
    listed=await call('get');
    await db.query('SAVEPOINT review');
    const saved=await call('put',{body:{status:'reviewed',revision:listed.body[0].revision}});
    await db.query('RELEASE SAVEPOINT review');
    assert.equal(saved.statusCode,200);assert.equal(saved.body.reviewed_by,actor);
    assert.equal((await call('put',{body:{status:'dismissed',revision:listed.body[0].revision}})).statusCode,409);
    assert.equal((await db.query('SELECT status,details FROM user_reports')).rows[0].status,'reviewed');
    assert.equal((await call('get')).body.length,0);
    assert.equal((await call('get',{query:{status:'all'}})).body.length,1);
  }finally{await db.query('ROLLBACK');await db.end();}
});
