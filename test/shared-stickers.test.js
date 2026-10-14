'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const sharp=require('sharp');
const {sharedStickerDetails,resizeSharedSticker,appendSharedStickers}=require('../server/shared-stickers');
test('shared stickers require an image, a name and explicit sharing rights',()=>{
  const details={sharedSticker:'true',rightsConfirmed:'true',sharedStickerTitle:'שלום',sharedStickerTags:'בית, שלום'};
  assert.deepEqual(sharedStickerDetails(details,'image'),{title:'שלום',tags:['בית','שלום']});
  for(const patch of [{rightsConfirmed:'false'},{sharedStickerTitle:''},{toUserId:'somebody'},{groupId:'group'}])
    assert.throws(()=>sharedStickerDetails({...details,...patch},'image'));
  assert.throws(()=>sharedStickerDetails(details,'video'));
  assert.equal(sharedStickerDetails({},'image'),null);
});
test('static stickers stay under 160 pixels without stretching or losing transparency',async()=>{
  for(const [width,height] of [[640,320],[100,50],[200,600]]){
    const source=await sharp({create:{width,height,channels:4,background:{r:40,g:120,b:200,alpha:.5}}}).png().toBuffer();
    const sticker=await resizeSharedSticker(source);const meta=await sharp(sticker.bytes).metadata();
    assert.ok(meta.width<=160&&meta.height<=160);
    assert.equal(meta.hasAlpha,true);assert.ok(Math.abs(meta.width-meta.height*width/height)<=1);
    assert.match(sticker.name,/^betshuva-shared-sticker-.*\.png$/);
  }
});
test('animated GIF stickers preserve frames, loop and timing at compact size',async()=>{
  const pixels=Buffer.alloc(320*200*3*4);
  for(let i=0;i<3;i++)for(let p=0;p<320*200;p++){pixels[(i*320*200+p)*4+i]=255;pixels[(i*320*200+p)*4+3]=255;}
  const source=await sharp(pixels,{raw:{width:320,height:600,channels:4,pageHeight:200}}).gif({loop:0,delay:[100,300,500]}).toBuffer();
  const result=await resizeSharedSticker(source);const meta=await sharp(result.bytes,{animated:true}).metadata();
  assert.equal(meta.pages,3);assert.equal(meta.width,160);assert.equal(meta.pageHeight,100);
  assert.deepEqual(meta.delay,[100,300,500]);assert.equal(meta.loop,0);assert.equal(result.mime,'image/gif');
});
test('only approved, available and active shared stickers enter the catalog', {skip:process.env.SHARED_STICKER_TEST_DB!=='1'},async()=>{
  require('dotenv').config({quiet:true});const {Client}=require('pg');const db=new Client({connectionString:process.env.DATABASE_URL});await db.connect();
  try{
    await db.query('SET search_path TO pg_temp,public');
    await db.query(`CREATE TEMP TABLE stored_files(id int,public_url text,original_name text,mime_type text,moderation_status text,moderation_details jsonb,content_purged_at timestamptz);
      CREATE TEMP TABLE shared_gifs(id int,stored_file_id int,title text,is_sticker boolean,status text,created_at timestamptz DEFAULT now());`);
    for(const [id,status,details,purged,active] of [[1,'approved',{},false,true],[2,'pending',{},false,true],[3,'rejected',{},false,true],[4,'approved',{},true,true],[5,'approved',{blocked:true},false,true],[6,'approved',{senderFilterRejected:true},false,true],[7,'approved',{},false,false]]){
      await db.query('INSERT INTO stored_files VALUES($1,$2,$3,$4,$5,$6,$7)',[id,'/uploads/'+id+'.gif','betshuva-shared-sticker-'+id+'.gif','image/gif',status,JSON.stringify(details),purged?new Date():null]);
      await db.query('INSERT INTO shared_gifs(id,stored_file_id,title,is_sticker,status) VALUES($1,$1,$2,true,$3)',[id,'מדבקה '+id,active?'active':'hidden']);
    }
    const original={categories:[{id:'user-stickers',items:[{id:'builtin'}]},{id:'user-emojis',items:[]}]};
    const catalog=await appendSharedStickers(db,original);
    assert.equal(catalog.categories[0].items.length,2);
    assert.equal(catalog.categories[0].items[0].sharedSticker.id,1);
    assert.equal(catalog.categories[0].items[0].animated,true);
    assert.equal(original.categories[0].items.length,1);
  }finally{await db.end();}
});
