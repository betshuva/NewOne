'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const source=fs.readFileSync(require('node:path').join(__dirname,'../server/index.js'),'utf8');
const scanSource=source.slice(source.indexOf('async function scanImage('),source.indexOf('async function scanDocument('));
const resultSource=source.slice(source.indexOf('function builtinExpressionResult()'),source.indexOf('// ── Firebase Cloud Messaging'));
test('library stickers bypass all image content providers even on rescans',async()=>{
 let providers=0;
 const scan=vm.runInNewContext(resultSource+scanSource+';scanImage',{
  isTrustedBuiltinExpression:async()=>true,
  isPotentiallyAnimatedImage:()=>{providers++;throw Error('must not inspect frames');},
  scanStaticImage:async()=>{providers++;throw Error('must not scan');},
 });
 const result=await scan(Buffer.from('fixture'));
 assert.equal(result.scanSkipped,true);assert.equal(result.pending,false);assert.equal(result.blocked,false);
 assert.equal(providers,0);
});
test('non-library images still reach normal moderation',async()=>{
 let providers=0;
 const scan=vm.runInNewContext(resultSource+scanSource+';scanImage',{
  isTrustedBuiltinExpression:async()=>false,
  isPotentiallyAnimatedImage:()=>false,
  scanStaticImage:async()=>{providers++;return {blocked:true};},
 });
 assert.equal((await scan(Buffer.from('other'))).blocked,true);assert.equal(providers,1);
});
test('upload identifies stickers independently of client flag and skips reports/cache',()=>{
 const upload=source.slice(source.indexOf("app.post('/api/upload'"),source.indexOf('// ── Groups: list mine'));
 assert.match(upload,/trustedBuiltinExpression = allowed.dbType === 'image' &&\s*await isTrustedBuiltinExpression\(file\)/);
 assert.match(upload,/reportImageScan = !trustedBuiltinExpression/);
 assert.match(upload,/cachedScanQuery = trustedBuiltinExpression \? \{ rows: \[\] \}/);
});
test('actual published sticker bytes are recognized without invoking a scanner',async()=>{
 const path=require('node:path');
 const root=path.join(__dirname,'..','expression-library');
 const catalog=JSON.parse(fs.readFileSync(path.join(root,'catalog.json'),'utf8'));
 const category=catalog.categories[0];
 const bytes=fs.readFileSync(path.join(root,category.path,`${category.prefix}-01.${category.extension}`));
 const hashSource=source.slice(source.indexOf('const EXPRESSION_PUBLIC_BASE ='),source.indexOf('// ── Firebase Cloud Messaging'));
 const scan=vm.runInNewContext(hashSource+scanSource+';scanImage',{
  fs:fs.promises,path,crypto:require('node:crypto'),BUILTIN_EXPRESSION_ROOT:root,
  isPotentiallyAnimatedImage:()=>{throw Error('unexpected image analysis');},
  scanStaticImage:()=>{throw Error('unexpected content scan');},
 });
 assert.equal((await scan(bytes)).scanSkipped,true);
});
