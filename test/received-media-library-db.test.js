'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { Client } = require('pg');
const { personalMessageVisible, messageAfterConversationClear } = require('../server/conversation-history');

test('received media appears once with its conversations and is retained until personal references are cleared', {
  skip: process.env.RUN_DB_TESTS !== '1',
}, async t => {
  const db = new Client({ connectionString: process.env.DATABASE_URL,
    ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' } : false });
  await db.connect();
  try {
    await db.query('SET search_path=pg_temp');
    await db.query(`CREATE TEMP TABLE stored_files(id uuid PRIMARY KEY,user_id uuid,original_name text,
        storage_path text,public_url text,mime_type text,file_type text,file_size bigint,
        moderation_status text,moderation_details jsonb,created_at timestamptz DEFAULT now(),
        released_at timestamptz,release_scheduled_at timestamptz,content_sha256 text,content_purged_at timestamptz);
      CREATE TEMP TABLE messages(id uuid PRIMARY KEY,sender_id uuid,recipient_id uuid,group_id uuid,
        file_url text,created_at timestamptz DEFAULT now(),deleted_for_everyone boolean DEFAULT false,
        deleted_for_sender boolean DEFAULT false);
      CREATE TEMP TABLE received_message_media(message_id uuid,user_id uuid,source_file_id uuid,
        stored_file_id uuid,status text);
      CREATE TEMP TABLE message_requests(file_url text);
      CREATE TEMP TABLE pending_scans(file_url text);
      CREATE TEMP TABLE message_user_deletions(message_id uuid,user_id uuid);
      CREATE TEMP TABLE conversation_user_state(user_id uuid,kind text,target_id uuid,cleared_at timestamptz);
      CREATE TEMP TABLE users(id uuid,name text,profile_pic_url text,created_at timestamptz);
      CREATE TEMP TABLE groups(id uuid,name text,profile_pic_url text,created_at timestamptz);
      CREATE TEMP TABLE group_members(group_id uuid,user_id uuid,status text,joined_at timestamptz);
      CREATE TEMP TABLE listings(id uuid,user_id uuid,title text,image_url text,created_at timestamptz);
      CREATE TEMP TABLE listing_images(listing_id uuid,url text);
      CREATE TEMP TABLE education_forms(id uuid,group_id uuid,created_by uuid,title text,file_url text,created_at timestamptz);
      CREATE TEMP TABLE shared_gifs(id uuid,creator_id uuid,stored_file_id uuid,status text,title text,created_at timestamptz);
      CREATE TEMP TABLE media_backup_items(stored_file_id uuid,user_id uuid,provider text,status text,
        verified_at timestamptz,restore_verified_at timestamptz,remote_file_id text,encryption_metadata jsonb);
      CREATE TEMP TABLE media_classification_appeals(stored_file_id uuid,user_id uuid,status text,created_at timestamptz);
      CREATE TEMP TABLE user_backup_settings(user_id uuid,enabled boolean);`);
    const id = n => `21000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
    const [owner, friend, group, copy, direct, inGroup, outsider] = [1,2,3,4,5,6,7].map(id);
    await db.query('INSERT INTO users(id,name) VALUES($1,$2),($3,$4)',[owner,'Owner',friend,'Friend']);
    await db.query('INSERT INTO groups(id,name) VALUES($1,$2)',[group,'Hikers']);
    await db.query("INSERT INTO group_members VALUES($1,$2,'member','2000-01-01')",[group,owner]);
    await db.query(`INSERT INTO stored_files(id,user_id,original_name,storage_path,public_url,
      mime_type,file_type,file_size,moderation_status,release_scheduled_at)
      VALUES($1,$2,'photo.png','received.png','/my-copy','image/png','image',123,'approved',now())`,[copy,owner]);
    await db.query(`INSERT INTO messages(id,sender_id,recipient_id,file_url)
      VALUES($1,$2,$3,'/friend-source')`,[direct,friend,owner]);
    await db.query(`INSERT INTO messages(id,sender_id,group_id,file_url)
      VALUES($1,$2,$3,'/group-source')`,[inGroup,friend,group]);
    await db.query(`INSERT INTO received_message_media(message_id,user_id,stored_file_id,status)
      VALUES($1,$3,$4,'ready'),($2,$3,$4,'ready')`,[direct,inGroup,owner,copy]);
    await db.query("INSERT INTO user_backup_settings VALUES($1,TRUE)",[owner]);
    await db.query(`INSERT INTO media_backup_items(stored_file_id,user_id,provider,status,verified_at,restore_verified_at)
      VALUES($1,$2,'google_drive','verified',now(),now())`,[copy,owner]);
    const source=fs.readFileSync(path.join(__dirname,'../server/index.js'),'utf8');
    let handler;
    const start=source.indexOf("app.get('/api/media-library', auth,");
    const end=source.indexOf('\nasync function loadStoredFileBytes',start);
    vm.runInNewContext(source.slice(start,end), {
      app:{get(_route,_auth,callback){handler=callback;}},auth(){},
      projectFilterMediaLibrary:async(_db,_user,rows)=>rows,
      getPool:async()=>db,personalMessageVisible,messageAfterConversationClear,console,
    });
    const library=async(userId=owner,query={})=>{
      let response, status=200;
      await handler({user:{id:userId},query},{set(){},status(code){status=code;return this;},json(value){response=value;}});
      assert.equal(status,200);
      return response;
    };
    const removed=[];
    const releaseStart=source.indexOf('async function runSafeReleaseQueue(');
    const releaseEnd=source.indexOf('\nasync function migrateMessageBodiesAtRest',releaseStart);
    const release=vm.runInNewContext(`${source.slice(releaseStart,releaseEnd)};runSafeReleaseQueue`,{
      projectFilterMediaLibrary:async(_db,_user,rows)=>rows,
      getPool:async()=>db,personalMessageVisible,path,UPLOAD_ROOT:'/isolated-received-media',
      fs:{async unlink(file){removed.push(file);}},logActivity(){},console,
    });

    await t.test('one owned item shows both private and group destinations with no foreign ownership leak',async()=>{
      const result=await library();
      assert.equal(result.total,1);assert.equal(result.items.length,1);
      assert.equal(result.items[0].url,'/my-copy');
      assert.equal(result.items[0].referenceCount,2);
      assert.equal(result.items[0].canDelete,false);
      assert.deepEqual(Array.from(result.items[0].destinations,d=>d.kind).sort(),['chat','group_chat']);
      assert.equal((await library(owner,{scope:'groups'})).items.length,1);
      assert.equal((await library(owner,{scope:'unassigned'})).items.length,0);
      assert.equal((await library(outsider)).items.length,0);
    });
    await t.test('clearing one conversation keeps the other destination and blocks automatic local release',async()=>{
      await db.query("INSERT INTO conversation_user_state VALUES($1,'chat',$2,clock_timestamp())",[owner,friend]);
      const result=await library();
      assert.equal(result.items[0].referenceCount,1);
      assert.deepEqual(Array.from(result.items[0].destinations,d=>d.kind),['group_chat']);
      await release();assert.equal(removed.length,0);
      assert.equal((await db.query('SELECT released_at FROM stored_files')).rows[0].released_at,null);
    });
    await t.test('a verified backup can release local bytes after all personal references are hidden',async()=>{
      await db.query('INSERT INTO message_user_deletions VALUES($1,$2)',[inGroup,owner]);
      const result=await library(owner,{scope:'unassigned'});
      assert.equal(result.items.length,1);assert.equal(result.items[0].canDelete,true);
      assert.equal(result.items[0].destinations.length,0);
      await release();assert.deepEqual(removed,['/isolated-received-media/received.png']);
      assert.ok((await db.query('SELECT released_at FROM stored_files')).rows[0].released_at);
      assert.equal((await db.query('SELECT * FROM messages')).rows.length,2);
      assert.equal((await db.query('SELECT * FROM media_backup_items')).rows.length,1);
    });
  } finally {await db.end();}
});
