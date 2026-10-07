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

test('recordings stay private until sealed, repair encoder headers, enforce quota and cancel', async t => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'recording-stage-'));
  const transfer = createResumableAttachments({ root });
  const reservations = new Map();
  transfer.setQuotaHooks({
    reserve: async (owner, id, bytes) => {
      if (bytes > 20000) throw Object.assign(new Error('quota'), { status: 413 });
      reservations.set(id, { owner, bytes });
    },
    release: async (owner, id) => { if (reservations.get(id)?.owner === owner) reservations.delete(id); },
  });
  const app = express();
  app.use(express.json());
  app.use((req, _res, next) => { req.user = { id: req.headers.authorization }; next(); });
  app.post('/sessions', transfer.create);
  app.put('/sessions/:id', transfer.chunk);
  app.patch('/sessions/:id', transfer.chunk);
  app.post('/sessions/:id/seal', transfer.seal);
  app.delete('/sessions/:id', transfer.cancel);
  app.get('/sessions/:id', transfer.status);
  let delivered = 0;
  app.post('/complete', transfer.prepare, async (req, res) => {
    delivered++;
    res.json({ bytes: (await fs.readFile(req.file.path)).toString('base64'), target: req.body.toUserId });
  });
  const server = app.listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  t.after(async () => { await new Promise(resolve => server.close(resolve)); await fs.rm(root, { recursive: true, force: true }); });
  const request = (route, method = 'GET', body, owner = 'owner', offset = 0) => fetch(base + route, {
    method, headers: { Authorization: owner, 'Upload-Offset': String(offset),
      ...(body ? { 'Content-Type': Buffer.isBuffer(body) ? 'application/octet-stream' : 'application/json' } : {}) },
    body: body === undefined ? undefined : Buffer.isBuffer(body) ? body : JSON.stringify(body),
  });
  const id = crypto.randomUUID();
  assert.equal((await request('/sessions', 'POST', { id, name: 'voice.wav', mime: 'audio/wav', size: 0, recording: true })).status, 200);
  const first = Buffer.alloc(8000, 1), tail = Buffer.alloc(1000, 2);
  assert.equal((await request(`/sessions/${id}`, 'PUT', first)).status, 200);
  assert.equal(reservations.get(id).bytes, first.length);
  assert.equal((await request('/complete', 'POST', { uploadSessionId: id })).status, 409);
  assert.equal(delivered, 0);
  assert.equal((await request(`/sessions/${id}`, 'PATCH', Buffer.from('RIFF'), 'outsider')).status, 404);
  assert.equal((await request(`/sessions/${id}`, 'DELETE', undefined, 'outsider')).status, 200);
  assert.equal(reservations.get(id).bytes, first.length);
  assert.equal((await request(`/sessions/${id}`)).status, 200);
  assert.equal((await request(`/sessions/${id}`, 'PUT', Buffer.alloc(13000), 'owner', 8000)).status, 413);
  assert.equal((await (await request(`/sessions/${id}`)).json()).offset, 8000);
  assert.equal((await request(`/sessions/${id}`, 'PUT', tail, 'owner', 8000)).status, 200);
  const expected = Buffer.concat([first, tail]); expected.write('RIFF');
  const final = { size: expected.length, name: 'voice.wav', mime: 'audio/wav', fields: { toUserId: 'self' },
    sha256: crypto.createHash('sha256').update(expected).digest('hex') };
  assert.equal((await request(`/sessions/${id}/seal`, 'POST', final)).status, 409);
  assert.equal((await request(`/sessions/${id}`, 'PATCH', Buffer.from('RIFF'))).status, 200);
  assert.equal((await request(`/sessions/${id}/seal`, 'POST', final)).status, 200);
  assert.equal((await request(`/sessions/${id}/seal`, 'POST', final)).status, 200);
  assert.equal((await request(`/sessions/${id}`, 'PATCH', Buffer.from('WRNG'))).status, 409);
  assert.equal(delivered, 0);
  const receipt = await (await request('/complete', 'POST', { uploadSessionId: id })).json();
  assert.equal(receipt.bytes, expected.toString('base64'));
  assert.equal(receipt.target, 'self');
  assert.equal(reservations.has(id), false);
  await request(`/sessions/${id}`, 'DELETE');
  assert.deepEqual(await (await request('/complete', 'POST', { uploadSessionId: id })).json(), receipt);
  assert.equal(delivered, 1);
  const cancelled = crypto.randomUUID();
  await request('/sessions', 'POST', { id: cancelled, name: 'video.mp4', mime: 'video/mp4', size: 0, recording: true });
  await request(`/sessions/${cancelled}`, 'PUT', first);
  assert.equal((await request(`/sessions/${cancelled}`, 'DELETE')).status, 200);
  assert.equal(reservations.has(cancelled), false);
  assert.equal((await request(`/sessions/${cancelled}`)).status, 404);
  assert.equal((await request('/complete', 'POST', { uploadSessionId: cancelled })).status, 404);
  assert.equal(delivered, 1);
});
