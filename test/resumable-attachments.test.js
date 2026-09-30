'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const http = require('node:http');
const { createResumableAttachments } = require('../server/resumable-attachments');

test('device upload resumes from committed chunks, stays owner scoped and finalizes once',async t=>{
  const root=await fs.mkdtemp(path.join(os.tmpdir(),'device-resume-'));
  let transfer=createResumableAttachments({root});
  const app=express();
  app.use(express.json());
  app.use((req,_res,next)=>{req.user={id:req.headers.authorization};next()});
  app.post('/sessions',(req,res)=>transfer.create(req,res));
  app.get('/sessions/:id',(req,res)=>transfer.status(req,res));
  app.put('/sessions/:id',(req,res)=>transfer.chunk(req,res));
  let scans=0;
  app.post('/complete',(req,res,next)=>transfer.prepare(req,res,next),async(req,res)=>{
    scans++;
    const content=await fs.readFile(req.file.path);
    res.json({hash:crypto.createHash('sha256').update(content).digest('hex'),field:req.body.groupId});
  });
  const server=app.listen(0,'127.0.0.1');
  await new Promise(resolve=>server.once('listening',resolve));
  const base=`http://127.0.0.1:${server.address().port}`;
  t.after(async()=>{await new Promise(resolve=>server.close(resolve));await fs.rm(root,{recursive:true,force:true})});
  const id=crypto.randomUUID(), bytes=crypto.randomBytes(10000);
  const request=(route,method='GET',body,user='owner',extra={})=>fetch(base+route,{method,
    headers:{Authorization:user,...(Buffer.isBuffer(body)?{'Content-Type':'application/octet-stream'}:body?{'Content-Type':'application/json'}:{}),...extra},
    body:body===undefined?undefined:Buffer.isBuffer(body)?body:JSON.stringify(body)});
  const meta={id,name:'movie.mp4',size:bytes.length,mime:'video/mp4',fields:{groupId:'group',clientUploadId:'original'}};
  assert.equal((await request('/sessions','POST',meta)).status,200);
  assert.equal((await request(`/sessions/${id}`,'GET',undefined,'outsider')).status,404);
  assert.equal((await request(`/sessions/${id}`,'PUT',bytes.subarray(0,4000),'owner',{'Upload-Offset':'0'})).status,200);
  // Same root, new service instance: acknowledged progress survives a process restart.
  transfer=createResumableAttachments({root});
  assert.equal((await(await request(`/sessions/${id}`)).json()).offset,4000);
  assert.equal((await request(`/sessions/${id}`,'PUT',bytes.subarray(0,4000),'owner',{'Upload-Offset':'0'})).status,409);
  assert.equal((await request('/complete','POST',{uploadSessionId:id})).status,409);
  // Abort halfway through a chunk. Only the previously committed 4,000 bytes count.
  await new Promise(resolve=>{
    const req=http.request(`${base}/sessions/${id}`,{method:'PUT',headers:{Authorization:'owner',
      'Content-Type':'application/octet-stream','Content-Length':'4000','Upload-Offset':'4000'}});
    req.on('error',()=>resolve());
    req.write(bytes.subarray(4000,5000));
    setTimeout(()=>req.destroy(),30);
  });
  await new Promise(resolve=>setTimeout(resolve,30));
  assert.equal((await(await request(`/sessions/${id}`)).json()).offset,4000);
  assert.equal((await request(`/sessions/${id}`,'PUT',bytes.subarray(4000),'owner',{'Upload-Offset':'4000'})).status,200);
  const first=await(await request('/complete','POST',{uploadSessionId:id})).json();
  assert.equal(first.hash,crypto.createHash('sha256').update(bytes).digest('hex'));
  assert.equal(first.field,'group');
  transfer=createResumableAttachments({root});
  assert.deepEqual(await(await request('/complete','POST',{uploadSessionId:id})).json(),first);
  assert.equal(scans,1);
  assert.equal((await(await request(`/sessions/${id}`)).json()).result.data.hash,first.hash);
});
