'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),express=require('express');
const {registerAdminScanRoutes}=require('../server/admin-scans');
test('scan deletion requires edit permission and explicit confirmation; preview tickets grant no API session',async t=>{
 const app=express();app.use(express.json());let queries=0;
 registerAdminScanRoutes(app,{getPool:async()=>({query:async()=>{queries++;return{rows:[],rowCount:1};}}),secret:'test-secret',uploadRoot:'/tmp',
  adminMiddleware:(req,res,next)=>{if(!req.headers.authorization)return res.status(401).end();req.user={id:'00000000-0000-4000-8000-000000000001',sessionVersion:0};req.adminPerm=req.headers.authorization;next();}});
 const server=app.listen(0,'127.0.0.1');await new Promise(r=>server.once('listening',r));t.after(()=>server.close());const base=`http://127.0.0.1:${server.address().port}/api/admin/scan-results/00000000-0000-4000-8000-000000000002`;
 assert.equal((await fetch(base,{method:'DELETE'})).status,401);
 assert.equal((await fetch(base,{method:'DELETE',headers:{Authorization:'view','Content-Type':'application/json'},body:JSON.stringify({confirm:'DELETE_SCAN_CACHE'})})).status,403);
 assert.equal((await fetch(base,{method:'DELETE',headers:{Authorization:'edit','Content-Type':'application/json'},body:'{}'})).status,400);assert.equal(queries,0);
 const ticket=await (await fetch(base+'/preview-ticket',{method:'POST',headers:{Authorization:'view'}})).json();
 const token=new URL(ticket.url,'http://local/').searchParams.get('ticket');assert.throws(()=>require('../server/session-security').verifySession(token,'test-secret'));
 assert.equal((await fetch(base+'/preview?ticket=invalid')).status,401);
 assert.equal((await fetch(base.replace(/2$/,'3')+'/preview?ticket='+token)).status,401);
});
