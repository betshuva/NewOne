'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const { Client } = require('pg');
const { messageAfterConversationClear, personalMessageVisible } = require('../server/conversation-history');

test('the shared media deleter preserves other users, live references and recoverable backups', {
  skip: process.env.RUN_DB_TESTS !== '1',
}, async t => {
  const db = new Client({ connectionString:process.env.DATABASE_URL,
    ssl: process.env.DB_SSL === 'true' ? {rejectUnauthorized:process.env.DB_REJECT_UNAUTHORIZED!=='false'} : false });
  await db.connect();
  try {
    await db.query('SET search_path=pg_temp');
    await db.query(`CREATE TEMP TABLE stored_files(id uuid PRIMARY KEY,user_id uuid,public_url text,
        storage_path text,file_size bigint,original_name text);
      CREATE TEMP TABLE media_backup_items(stored_file_id uuid,provider text,remote_file_id text,status text,encryption_metadata jsonb);
      CREATE TEMP TABLE cloud_backup_accounts(user_id uuid,status text,encrypted_refresh_token text);
      CREATE TEMP TABLE messages(id uuid,sender_id uuid,recipient_id uuid,group_id uuid,
        file_url text,file_name text,file_size bigint,created_at timestamptz DEFAULT now(),
        deleted_for_everyone boolean DEFAULT false,deleted_for_sender boolean DEFAULT false);
      CREATE TEMP TABLE message_user_deletions(message_id uuid,user_id uuid);
      CREATE TEMP TABLE conversation_user_state(user_id uuid,kind text,target_id uuid,cleared_at timestamptz);
      CREATE TEMP TABLE received_message_media(message_id uuid,user_id uuid,source_file_id uuid,
        stored_file_id uuid,status text);
      CREATE TEMP TABLE group_members(group_id uuid,user_id uuid,status text,joined_at timestamptz);
      CREATE TEMP TABLE message_requests(file_url text);
      CREATE TEMP TABLE pending_scans(file_url text);
      CREATE TEMP TABLE users(profile_pic_url text);
      CREATE TEMP TABLE groups(profile_pic_url text);
      CREATE TEMP TABLE listings(image_url text);
      CREATE TEMP TABLE listing_images(url text);
      CREATE TEMP TABLE education_forms(file_url text);
      CREATE TEMP TABLE shared_gifs(stored_file_id uuid,status text);`);
    const owner='20000000-0000-4000-8000-000000000001', other='20000000-0000-4000-8000-000000000002';
    const file='20000000-0000-4000-8000-000000000003', url='/test-media';
    const removed=[], remote=[];
    let failRemote=false;
    const source=fs.readFileSync(path.join(__dirname,'../server/index.js'),'utf8');
    const start=source.indexOf('async function deleteOwnMedia(');
    const end=source.indexOf("app.delete('/api/media-library/:id'",start);
    const remove=vm.runInNewContext(`(${source.slice(start,end).trim()})`, {
      path,messageAfterConversationClear,personalMessageVisible,UPLOAD_ROOT:'/isolated-test-uploads',
      fs:{async unlink(filePath){removed.push(filePath);}},
      personalDrive:{decryptRefreshToken(token,userId){assert.equal(userId,owner);return token;},
        async deleteAppDataFile(token,remoteId){
          if(failRemote)throw new Error('Drive unavailable');
          remote.push(remoteId);
        }},
    });
    const pool={connect:async()=>({query:db.query.bind(db),release(){}})};
    const reset=async()=>{
      await db.query(`TRUNCATE stored_files,media_backup_items,cloud_backup_accounts,messages,message_user_deletions,conversation_user_state,received_message_media,group_members,message_requests,
        pending_scans,users,groups,listings,listing_images,education_forms,shared_gifs`);
      await db.query('INSERT INTO stored_files VALUES($1,$2,$3,$4,123,$5)',[file,owner,url,'image.png','image']);
      removed.length=0;remote.length=0;failRemote=false;
    };
    await t.test('another owner cannot delete a file or learn its references',async()=>{
      await reset();
      await assert.rejects(remove(pool,other,file),error=>error.status===404);
      assert.equal(removed.length,0);assert.equal(remote.length,0);
      assert.equal((await db.query('SELECT * FROM stored_files')).rows.length,1);
    });
    for (const [name,sql,args] of [
      ['recipient message','INSERT INTO messages(file_url,sender_id,recipient_id) VALUES($1,$2,$3)',[url,owner,other]],
      ['unaccepted contact request','INSERT INTO message_requests VALUES($1)',[url]],
      ['pending scan delivery','INSERT INTO pending_scans VALUES($1)',[url]],
      ['profile picture','INSERT INTO users VALUES($1)',[url]],
      ['group picture','INSERT INTO groups VALUES($1)',[url]],
      ['listing picture','INSERT INTO listings VALUES($1)',[url]],
      ['additional listing picture','INSERT INTO listing_images VALUES($1)',[url]],
      ['education form','INSERT INTO education_forms VALUES($1)',[url]],
      ['shared GIF',"INSERT INTO shared_gifs VALUES($1,'active')",[file]],
    ]) await t.test(`${name} is retained even if the owner cleared their chat`,async()=>{
      await reset();await db.query(sql,args);
      await assert.rejects(remove(pool,owner,file),error=>error.code==='MEDIA_IN_USE'&&error.referenceCount===1);
      assert.equal(removed.length,0);assert.equal(remote.length,0);
    });
    await t.test('an in-progress backup is preserved',async()=>{
      await reset();
      await db.query("INSERT INTO media_backup_items VALUES($1,'google_drive',NULL,'uploading',NULL)",[file]);
      await assert.rejects(remove(pool,owner,file),error=>error.code==='BACKUP_IN_PROGRESS');
      assert.equal(removed.length,0);
    });
    await t.test('a personally cleared self-message allows deletion without exposing a broken object',async()=>{
      await reset();
      await db.query('INSERT INTO messages(id,file_url,sender_id,recipient_id) VALUES($1,$2,$3,$3)',[file,url,owner]);
      await db.query('INSERT INTO message_user_deletions VALUES($1,$2)',[file,owner]);
      const result=await remove(pool,owner,file);
      assert.equal(result.deletedBytes,123);
      assert.equal((await db.query('SELECT file_url FROM messages')).rows[0].file_url,null);
    });
    await t.test('a self-message still visible to its owner blocks physical deletion',async()=>{
      await reset();
      await db.query('INSERT INTO messages(id,file_url,sender_id,recipient_id) VALUES($1,$2,$3,$3)',[file,url,owner]);
      await assert.rejects(remove(pool,owner,file),error=>error.code==='MEDIA_IN_USE');
      assert.equal(removed.length,0);
    });
    await t.test('a queued recipient copy protects its source while copying',async()=>{
      await reset();
      await db.query("INSERT INTO received_message_media(user_id,source_file_id,status) VALUES($1,$2,'queued')",[other,file]);
      await assert.rejects(remove(pool,owner,file),error=>error.code==='MEDIA_IN_USE');
      assert.equal(removed.length,0);
    });
    await t.test('a received copy is protected by its visible original message',async()=>{
      await reset();
      await db.query('INSERT INTO messages(id,file_url,sender_id,recipient_id) VALUES($1,$2,$3,$4)',[file,'/sender-original',other,owner]);
      await db.query("INSERT INTO received_message_media(message_id,user_id,stored_file_id,status) VALUES($1,$2,$1,'ready')",[file,owner]);
      await assert.rejects(remove(pool,owner,file),error=>error.code==='MEDIA_IN_USE');
      assert.equal(removed.length,0);
    });
    await t.test('clearing a received message deletes only its own copy and prevents resurrection',async()=>{
      await reset();
      await db.query('INSERT INTO messages(id,file_url,sender_id,recipient_id) VALUES($1,$2,$3,$4)',[file,'/sender-original',other,owner]);
      await db.query("INSERT INTO received_message_media(message_id,user_id,stored_file_id,status) VALUES($1,$2,$1,'ready')",[file,owner]);
      await db.query("INSERT INTO conversation_user_state VALUES($1,'chat',$2,clock_timestamp())",[owner,other]);
      const result=await remove(pool,owner,file);
      assert.equal(result.deletedBytes,123);
      assert.equal((await db.query('SELECT file_url FROM messages')).rows[0].file_url,'/sender-original');
      assert.deepEqual((await db.query('SELECT status,stored_file_id FROM received_message_media')).rows[0],
        {status:'skipped',stored_file_id:null});
    });
    await t.test('the same received copy stays while another group message still uses it',async()=>{
      await reset();
      const group='20000000-0000-4000-8000-000000000004';
      const secondMessage='20000000-0000-4000-8000-000000000005';
      await db.query('INSERT INTO messages(id,file_url,sender_id,recipient_id) VALUES($1,$2,$3,$4)',[file,'/first-original',other,owner]);
      await db.query('INSERT INTO messages(id,file_url,sender_id,group_id) VALUES($1,$2,$3,$4)',[secondMessage,'/second-original',other,group]);
      await db.query("INSERT INTO received_message_media(message_id,user_id,stored_file_id,status) VALUES($1,$2,$1,'ready'),($3,$2,$1,'ready')",[file,owner,secondMessage]);
      await db.query("INSERT INTO group_members VALUES($1,$2,'member','2000-01-01')",[group,owner]);
      await db.query('INSERT INTO message_user_deletions VALUES($1,$2)',[file,owner]);
      await assert.rejects(remove(pool,owner,file),error=>error.code==='MEDIA_IN_USE'&&error.referenceCount===1);
      await db.query('INSERT INTO message_user_deletions VALUES($1,$2)',[secondMessage,owner]);
      await remove(pool,owner,file);
      assert.equal(removed.length,1);
      assert.equal((await db.query("SELECT 1 FROM received_message_media WHERE status<>'skipped'")).rows.length,0);
    });
    await t.test('a disconnected Drive account preserves the local file and backup metadata',async()=>{
      await reset();
      await db.query("INSERT INTO media_backup_items VALUES($1,'google_drive','data','verified',$2)",[file,{manifestRemoteId:'manifest'}]);
      await assert.rejects(remove(pool,owner,file),error=>error.code==='BACKUP_RECONNECT_REQUIRED');
      assert.equal(removed.length,0);assert.equal(remote.length,0);
      assert.equal((await db.query('SELECT * FROM stored_files')).rows.length,1);
    });
    await t.test('an unused file deletes its encrypted data and manifest before the local file',async()=>{
      await reset();
      await db.query("INSERT INTO media_backup_items VALUES($1,'google_drive','data','verified',$2)",[file,{manifestRemoteId:'manifest'}]);
      await db.query("INSERT INTO cloud_backup_accounts VALUES($1,'connected','token')",[owner]);
      const result=await remove(pool,owner,file);
      assert.equal(result.deletedBytes,123);assert.equal(result.cloudDeleted,true);
      assert.deepEqual(remote,['data','manifest']);assert.deepEqual(removed,['/isolated-test-uploads/image.png']);
      assert.equal((await db.query('SELECT * FROM stored_files')).rows.length,0);
    });
    await t.test('a Drive failure leaves local bytes and metadata available for retry',async()=>{
      await reset();failRemote=true;
      await db.query("INSERT INTO media_backup_items VALUES($1,'google_drive','data','verified',NULL)",[file]);
      await db.query("INSERT INTO cloud_backup_accounts VALUES($1,'connected','token')",[owner]);
      await assert.rejects(remove(pool,owner,file),/Drive unavailable/);
      assert.equal(removed.length,0);
      assert.equal((await db.query('SELECT * FROM stored_files')).rows.length,1);
    });
  } finally {await db.end();}
});
