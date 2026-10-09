const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs/promises');
const path=require('node:path');
const vm=require('node:vm');
const sharp=require('sharp');
const root=path.resolve(__dirname,'..');
test('published catalog keeps choices 001–048 and preserves all removed artwork for history',async()=>{
 const server=await fs.readFile(path.join(root,'server/index.js'),'utf8');
 const start=server.indexOf('async function getExpressionCatalog()');
 const end=server.indexOf('async function isTrustedBuiltinExpression',start);
 const get=vm.runInNewContext(server.slice(start,end)+'; getExpressionCatalog',{fs,path,EXPRESSION_CATALOG_PATH:path.join(root,'expression-library/catalog.json'),BUILTIN_EXPRESSION_ROOT:path.join(root,'expression-library'),EXPRESSION_PUBLIC_BASE:'/betshuva-app/expression-library'});
 const catalog=await get();assert.equal(catalog.version,3);assert.equal(catalog.categories.length,1);
 const category=catalog.categories[0];assert.equal(category.id,'user-stickers');assert.equal(category.items.length,48);
 assert.equal(new Set(category.items.map(x=>x.url)).size,48);
 assert.equal(new Set(category.items.map(x=>x.coloredUrl)).size,48);
 const availableIds=Array.from({length:48},(_,i)=>i+1);
 for(let index=0;index<availableIds.length;index++) {
  const id=availableIds[index];
  const name=`sticker-${String(id).padStart(2,'0')}.png`;
  const item=category.items[index];
  assert.equal(item.id,`user-stickers-${id}`);
  assert.equal(item.url,`/betshuva-app/expression-library/user-20260907/${name}`);
  assert.equal(item.coloredUrl,`/betshuva-app/expression-library/user-20261008-color/${name}`);
  const m=await sharp(path.join(root,item.coloredUrl.replace('/betshuva-app/',''))).metadata();
  assert.equal(m.format,'png');assert.ok(m.width>100&&m.height>100);
  assert.equal(m.hasAlpha,true);
 }
 for(const item of category.items){const file=path.join(root,item.url.replace('/betshuva-app/',''));const m=await sharp(file).metadata();assert.equal(m.format,'png');assert.ok(m.width>100&&m.height>100);}
 const fallback=JSON.parse(await fs.readFile(path.join(root,'flutter_app/assets/stickers/user-catalog.json')));
 assert.equal(fallback.categories[0].labels.length,150);
 assert.equal(fallback.categories[0].path,'user-20260907');
 assert.equal(fallback.categories[0].coloredPath,'user-20261008-color');
 assert.deepEqual(fallback.categories[0].removedIds,Array.from({length:102},(_,i)=>i+49));
 for(const id of fallback.categories[0].removedIds){
  const name=`sticker-${String(id).padStart(2,'0')}.png`;
  for(const folder of ['user-20260907','user-20261008-color']){
   const m=await sharp(path.join(root,'expression-library',folder,name)).metadata();
   assert.equal(m.format,'png');assert.ok(m.width>100&&m.height>100);
  }
 }
 assert.deepEqual(fallback,JSON.parse(await fs.readFile(path.join(root,'expression-library/catalog.json'))));
});
// Composer insertion and explicit text sending are exercised in
// flutter_app/test/inline_emoji_chat_test.dart.
