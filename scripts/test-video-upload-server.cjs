const express = require('express');
const os = require('node:os');
const path = require('node:path');
const fs = require('node:fs');
const { createResumableAttachments } = require('../server/resumable-attachments');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'browser-upload-'));
const transfer = createResumableAttachments({ root });
const app = express();
app.use((req,res,next)=>{
  res.set('Access-Control-Allow-Origin','*');
  res.set('Access-Control-Allow-Headers','Authorization, Content-Type, Upload-Offset');
  res.set('Access-Control-Allow-Methods','GET,POST,PUT,OPTIONS');
  if(req.method==='OPTIONS')return res.end();
  req.user={id:'browser-fixture'}; next();
});
app.use(express.json());
const accepted = new Map(), dropped = new Set();
let scans = 0;
app.post('/upload-sessions',transfer.create);
app.get('/upload-sessions/:id',transfer.status);
app.put('/upload-sessions/:id',(req,res)=>{
  const json=res.json.bind(res);
  res.json=data=>{
    if(res.statusCode===200){
      accepted.set(req.params.id,(accepted.get(req.params.id)||0)+Number(req.headers['content-length']));
      if(Number(req.headers['upload-offset'])>=4*1024*1024&&!dropped.has(req.params.id)){
        dropped.add(req.params.id);req.socket.destroy();return res;
      }
    }
    return json(data);
  };
  transfer.chunk(req,res);
});
app.post('/upload',transfer.prepare,(req,res)=>{
  scans++;
  res.json({size:req.file.size,name:req.file.originalname,disk:!!req.file.path,
    buffered:!!req.file.buffer,groupId:req.body.groupId,
    acceptedBytes:[...accepted.values()].reduce((a,b)=>a+b,0),scans,
    recoveredInterruptions:dropped.size});
});
const server=app.listen(18763,'127.0.0.1',()=>console.log('Resumable browser upload fixture on 18763'));
process.on('SIGTERM',()=>server.close(()=>{fs.rmSync(root,{recursive:true,force:true});process.exit(0)}));
