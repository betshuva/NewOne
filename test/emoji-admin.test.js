'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs/promises'),path=require('node:path'),vm=require('node:vm');
const express=require('express'),jwt=require('jsonwebtoken');
const {createEmojiAdmin,registerEmojiAdmin}=require('../server/emoji-admin');
const {createExpressionLibrary}=require('../server/expression-catalog');
let root,server,base,library,token,viewToken;const secret='isolated-emoji-admin-test';
test.before(async()=>{
 root=await fs.mkdtemp('/tmp/betshuva-emoji-test-');await fs.mkdir(path.join(root,'emojis'));await fs.mkdir(path.join(root,'stickers'));
 await fs.writeFile(path.join(root,'emoji-registry.json'),JSON.stringify({items:[1,2,99].map(id=>({id,file:id+'.png',label:'Synthetic '+id}))}));
 for(const id of [1,2,99])await fs.writeFile(path.join(root,'emojis',id+'.png'),'synthetic-image-'+id);
 await fs.writeFile(path.join(root,'catalog.json'),JSON.stringify({categories:[{id:'user-emojis',removedIds:[99]},{id:'user-stickers',labels:[],removedIds:[17]}],unrelated:'preserved'}));
 const source=await fs.readFile(path.join(__dirname,'../server/index.js'),'utf8');const a=source.indexOf('async function adminAuth('),b=source.indexOf('\n}\n',a)+2;
 const context=vm.createContext({JWT_SECRET:secret,verifySession:(t,s)=>jwt.verify(t,s,{algorithms:['HS256']}),sessionCurrent:(claims,user)=>claims.sessionVersion===user.session_version,
 getPool:async()=>({query:async(_sql,args)=>({rows:args[0]==='edit'?[{permission:'edit',session_version:0}]:args[0]==='view'?[{permission:'view',session_version:0}]:[]})}),requestAgeError:()=>null,accountModerationError:()=>null,requestAudit:(_req,_res,next)=>next()});
 vm.runInContext(source.slice(a,b),context);
 const app=express();app.use(express.json());registerEmojiAdmin(app,{root,adminAuth:context.adminAuth,origin:'https://betshuva.com'});
 server=app.listen(0,'127.0.0.1');await new Promise(resolve=>server.once('listening',resolve));base='http://127.0.0.1:'+server.address().port;
 token=jwt.sign({id:'edit',sessionVersion:0},secret);viewToken=jwt.sign({id:'view',sessionVersion:0},secret);library=createEmojiAdmin(root);
});
test.after(async()=>{if(server)await new Promise(resolve=>server.close(resolve));if(root&&root.startsWith('/tmp/betshuva-emoji-test-'))await fs.rm(root,{recursive:true,force:true});});
async function req(method,route='',body,credential=token,origin='https://betshuva.com'){
 const headers={'Content-Type':'application/json',Origin:origin};if(credential)headers.Authorization='Bearer '+credential;
 const r=await fetch(base+'/api/admin/emojis'+route,{method,headers,body:body?JSON.stringify(body):undefined});return {status:r.status,body:await r.json(),cache:r.headers.get('cache-control')};
}
test('missing, forged, non-admin and stale session rejected by existing adminAuth body',async()=>{
 for(const credential of [null,'forged',jwt.sign({id:'none',sessionVersion:0},secret),jwt.sign({id:'edit',sessionVersion:1},secret)])assert.ok([401,403].includes((await req('GET','',null,credential)).status));
});
test('view-only administrator cannot read edit gallery or mutate',async()=>{assert.equal((await req('GET','',null,viewToken)).status,403);assert.equal((await req('PUT','/1',{hidden:true,revision:'a'.repeat(64)},viewToken)).status,403);});
test('edit inventory includes all images and preserves pre-existing hidden state without paths',async()=>{const r=await req('GET');assert.equal(r.status,200);assert.equal(r.cache,'no-store');assert.equal(r.body.items.length,3);assert.equal(r.body.items.find(x=>x.id===99).hidden,true);assert.ok(!JSON.stringify(r.body).includes(root));});
test('cross-origin and missing-origin mutation rejected even with valid bearer',async()=>{const r=await library.inventory();for(const origin of ['https://evil.invalid','null',''])assert.equal((await req('PUT','/1',{hidden:true,revision:r.revision},token,origin)).status,403);});
test('invalid ID and unknown stable ID cannot mutate',async()=>{const r=await library.inventory();assert.equal((await req('PUT','/1x',{hidden:true,revision:r.revision})).status,400);assert.equal((await req('PUT','/6400',{hidden:true,revision:r.revision})).status,404);await assert.rejects(library.setHidden('../x',true,r.revision),{code:'INVALID_CHANGE'});});
test('hide changes actual picker catalog while old message artwork remains available',async()=>{const before=await fs.readFile(path.join(root,'emojis/1.png'));const r=await library.inventory();assert.equal((await req('PUT','/1',{hidden:true,revision:r.revision})).status,200);const picker=createExpressionLibrary(root);const catalog=await picker.catalog();assert.ok(!catalog.categories[0].items.some(x=>x.emojiId===1));assert.equal(await picker.emojiFile(1),path.join(root,'emojis/1.png'));assert.deepEqual(await fs.readFile(path.join(root,'emojis/1.png')),before);assert.equal((await library.inventory()).items.find(x=>x.id===99).hidden,true);});
test('stale revision rejected without overwriting choices',async()=>{assert.equal((await req('PUT','/2',{hidden:true,revision:'0'.repeat(64)})).status,409);assert.equal((await library.inventory()).items.find(x=>x.id===2).hidden,false);});
test('concurrent edits across service instances cannot lose updates',async()=>{const current=await library.inventory();const a=createEmojiAdmin(root),b=createEmojiAdmin(root);const r=await Promise.allSettled([a.setHidden(2,true,current.revision),b.setHidden(1,false,current.revision)]);assert.equal(r.filter(x=>x.status==='fulfilled').length,1);assert.ok(r.find(x=>x.status==='rejected').reason.status===409);});
test('restore returns the item to dynamic picker and retains unrelated metadata',async()=>{const r=await library.inventory();await library.setHidden(1,false,r.revision);const catalog=await createExpressionLibrary(root).catalog();assert.ok(catalog.categories[0].items.some(x=>x.emojiId===1));const raw=JSON.parse(await fs.readFile(path.join(root,'catalog.json'),'utf8'));assert.equal(raw.unrelated,'preserved');assert.deepEqual(raw.categories[1].removedIds,[17]);assert.ok(raw.categories[0].removedIds.includes(99));});
test('malformed registry traversal is rejected before touching any target',async()=>{const file=path.join(root,'emoji-registry.json'),original=await fs.readFile(file);try{await fs.writeFile(file,JSON.stringify({items:[{id:1,file:'../outside.png'}]}));await assert.rejects(library.inventory(),{code:'INVALID_REGISTRY'});}finally{await fs.writeFile(file,original);}});
test('an existing lock fails closed instead of guessing that a writer is dead',async()=>{const file=path.join(root,'.emoji-admin.lock');await fs.writeFile(file,'');try{const r=await library.inventory();await assert.rejects(library.setHidden(2,false,r.revision),{code:'EDIT_BUSY'});}finally{await fs.unlink(file);}});
test('symlink asset metadata is rejected without creating a real symlink',async()=>{const original=fs.lstat;fs.lstat=async file=>file===path.join(root,'emojis/1.png')?{isFile:()=>false,isSymbolicLink:()=>true}:original(file);try{await assert.rejects(library.inventory(),{code:'INVALID_ASSET'});}finally{fs.lstat=original;}});

test('published management page loads from the allowed directory with correct API and login links',async()=>{
 const {publicStatic}=require('../server/public-static');
 const app=express();app.use(publicStatic(path.join(__dirname,'..')));
 const web=app.listen(0,'127.0.0.1');await new Promise(resolve=>web.once('listening',resolve));
 try{const r=await fetch('http://127.0.0.1:'+web.address().port+'/expression-library/emoji-admin.html');assert.equal(r.status,200);const html=await r.text();assert.ok(html.includes("const api='/betshuva-app/api/admin/emojis';"));assert.ok(html.includes('href="/betshuva-app/admin.html"'));new vm.Script(html.match(/<script>([\s\S]*?)<\/script>/)[1]);}
 finally{await new Promise(resolve=>web.close(resolve));}
});