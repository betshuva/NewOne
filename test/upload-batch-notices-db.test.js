'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const express=require('express');
const {Pool}=require('pg');
const {SCHEMA,registerUploadBatchNotices}=require('../server/upload-batch-notices');

test('upload notices persist idempotently and remain private to owner and conversation',
  {skip:process.env.RUN_DB_TESTS!=='1'},async t=>{
    const pool=new Pool({connectionString:process.env.DATABASE_URL,
      ssl:process.env.DB_SSL==='true'?{rejectUnauthorized:process.env.DB_REJECT_UNAUTHORIZED!=='false'}:false});
    const db=await pool.connect();
    t.after(async()=>{await db.query('ROLLBACK');db.release();await pool.end()});
    await db.query('BEGIN');
    await db.query('SET LOCAL search_path TO pg_temp');
    await db.query('CREATE TEMP TABLE users(id UUID PRIMARY KEY)');
    const owner='11111111-1111-1111-1111-111111111111',other='22222222-2222-2222-2222-222222222222';
    await db.query('INSERT INTO users VALUES($1),($2)',[owner,other]);
    await db.query(SCHEMA);
    const app=express();app.use(express.json());
    registerUploadBatchNotices(app,{auth:(req,res,next)=>{req.user={id:req.headers.authorization};next()},getPool:async()=>db});
    const server=app.listen(0,'127.0.0.1');
    await new Promise(r=>server.once('listening',r));
    t.after(()=>new Promise(r=>server.close(r)));
    const base=`http://127.0.0.1:${server.address().port}/api/upload-batch-notices`;
    const notice={id:'batch_notice_1',kind:'group',target:'group',text:'מעלה 3 קבצים',createdAt:new Date().toISOString()};
    const post=data=>fetch(base,{method:'POST',headers:{Authorization:owner,'Content-Type':'application/json'},body:JSON.stringify(data)});
    for(let i=0;i<2;i++)assert.equal((await post(notice)).status,201);
    assert.equal((await post({...notice,text:'מעלה 101 קבצים'})).status,400);
    assert.equal((await post({...notice,id:'summary',text:'סוף תור ההעלאה: 1 מתוך 3 הושלמו, 2 נכשלו'})).status,201);
    assert.equal((await post({...notice,id:'summary-all',text:'סוף תור ההעלאה: 0 מתוך 3 הושלמו, 3 נכשלו'})).status,201);
    assert.equal((await post({...notice,id:'bad-summary',text:'סוף תור ההעלאה: 2 מתוך 3 הושלמו, 2 נכשלו'})).status,400);
    assert.equal((await post({...notice,id:'bad-large',text:'סוף תור ההעלאה: 1 מתוך 101 הושלמו, 100 נכשלו'})).status,400);
    const read=(who,target='group')=>fetch(`${base}?kind=group&target=${target}`,{headers:{Authorization:who}}).then(r=>r.json());
    const rows=await read(owner);assert.equal(rows.length,3);assert.equal(rows[0].isUploadBatchNotice,true);
    assert.deepEqual(await read(other),[]);assert.deepEqual(await read(owner,'elsewhere'),[]);
  });
