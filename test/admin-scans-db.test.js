'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),crypto=require('node:crypto'),{Pool,Client}=require('pg');
const scans=require('../server/admin-scans'),ledger=require('../server/video-scan-budget');
test('scan cache deletion preserves media, removes old budgets and allows a fresh bounded scan',{skip:process.env.RUN_DB_TESTS!=='1'},async t=>{
 const name='scan_reset_'+crypto.randomBytes(8).toString('hex'),db=new Client({connectionString:process.env.DATABASE_URL});await db.connect();await db.query(`CREATE SCHEMA "${name}"`);
 const pool=new Pool({connectionString:process.env.DATABASE_URL,options:'-c search_path='+name,max:5});
 t.after(async()=>{await pool.end();await db.query(`DROP SCHEMA "${name}" CASCADE`);await db.end();});
 await pool.query(`CREATE TABLE users(id uuid PRIMARY KEY,name text,short_id integer);
 CREATE TABLE stored_files(id uuid PRIMARY KEY,user_id uuid,content_sha256 text,file_type text,public_url text,
  moderation_status text,moderation_details jsonb,original_name text,created_at timestamptz DEFAULT now(),file_size bigint,
  context_type text,content_purged_at timestamptz);
 CREATE TABLE pending_scans(file_url text);
 CREATE TABLE audit_scan_previews(stored_file_id uuid);
 CREATE TABLE messages(id uuid,file_url text);`);
 await ledger.ensureVideoScanBudgetSchema(pool);await pool.query(scans.SCHEMA);
 const owner=crypto.randomUUID(),other=crypto.randomUUID();await pool.query('INSERT INTO users VALUES($1,$2,1),($3,$4,2)',[owner,'שם משתמש',other,'משתמש שני']);
 const hash=crypto.randomBytes(32).toString('hex'),first=crypto.randomUUID(),copy=crypto.randomUUID();
 await pool.query(`INSERT INTO stored_files(id,user_id,content_sha256,file_type,public_url,moderation_status,moderation_details,original_name,file_size)
 VALUES($1,$2,$3,'video','/source','stopped','{"reason":"original decision"}','clip.mp4',10),
 ($4,$5,$3,'video','/copy','approved','{"reason":"original decision"}','copy.mp4',10)`,[first,owner,hash,copy,other]);
 await pool.query("INSERT INTO messages VALUES($1,'/source')",[crypto.randomUUID()]);
 await pool.query("UPDATE stored_files SET created_at=CASE WHEN id=$1 THEN '2026-01-01'::timestamptz ELSE '2026-02-01'::timestamptz END",[first]);
 assert.deepEqual((await scans.listScans(pool,{})).items.map(row=>row.id),[copy,first]);
 assert.deepEqual((await scans.listScans(pool,{order:'asc'})).items.map(row=>row.id),[first,copy]);
 const ownerResults=await scans.listScans(pool,{search:'שם משתמש'});
 assert.equal(ownerResults.items.length,1);assert.equal(ownerResults.items[0].user_number,1);
 const cf=columns=>({columnFilters:JSON.stringify(columns)});
 const filtered=await scans.listScans(pool,cf({user:{values:[owner],exclude:false},status:{values:['stopped'],exclude:false},date:{from:'2026-01-01T00:00:00Z',to:'2026-02-01T00:00:00Z'}}));
 assert.deepEqual(filtered.items.map(row=>row.id),[first]);
 assert.deepEqual((await scans.listScans(pool,cf({status:{values:['stopped'],exclude:true}}))).items.map(row=>row.id),[copy]);
 assert.equal((await scans.listScans(pool,cf({name:{values:[],exclude:false}}))).items.length,0);
 assert.deepEqual((await scans.listScans(pool,{sort:'name',order:'asc'})).items.map(row=>row.id),[first,copy]);
 assert.deepEqual((await scans.listScans(pool,{sort:'name',order:'desc'})).items.map(row=>row.id),[copy,first]);
 const options=await scans.filterOptions(pool,{column:'user',...cf({user:{values:[owner],exclude:false},status:{values:['approved'],exclude:false}})});
 assert.deepEqual(options.options,[{value:other,label:'משתמש שני · 2'}]);
 assert.equal((await scans.filterOptions(pool,{column:'status',optionSearch:'נעצרה'})).options[0].value,'stopped');
 for(const query of [{sort:'name; DROP TABLE users'},cf({unknown:{values:[],exclude:true}}),{columnFilters:'{'},cf({date:{from:'invalid'}}),cf({date:{from:'2026-03-01T00:00:00Z',to:'2026-02-01T00:00:00Z'}})])await assert.rejects(scans.listScans(pool,query),{status:400});
 const acquired=await ledger.acquireVideoScan(pool,{userId:owner,contentSha256:hash,storedFileId:first,scanVersion:'fixture',providerPolicy:'google_gemini'});
 const context={scanId:acquired.id,leaseToken:acquired.leaseToken};
 await assert.rejects(scans.resetScan(pool,first,owner),{status:409});
 await ledger.stopVideoScan(pool,context,'scan_incomplete');
 await pool.query("INSERT INTO pending_scans VALUES('/source')");await assert.rejects(scans.resetScan(pool,first,owner),{status:409});await pool.query('DELETE FROM pending_scans');
 const before=(await pool.query('SELECT id,moderation_status,moderation_details,public_url FROM stored_files ORDER BY id')).rows;
 const result=await scans.resetScan(pool,first,owner);assert.equal(result.affectedFiles,2);
 assert.deepEqual((await pool.query('SELECT id,moderation_status,moderation_details,public_url FROM stored_files ORDER BY id')).rows,before);
 assert.equal((await pool.query('SELECT * FROM messages')).rowCount,1);
 assert.equal((await pool.query('SELECT * FROM video_scan_budgets')).rowCount,0);
 assert.equal((await pool.query('SELECT previous_budgets FROM moderation_scan_resets')).rows[0].previous_budgets[0].id,acquired.id);
 assert.equal((await scans.listScans(pool,{})).items.length,0);
 assert.equal((await scans.resetScan(pool,first,owner)).alreadyDeleted,true);
 const fresh=await ledger.acquireVideoScan(pool,{userId:owner,contentSha256:hash,storedFileId:crypto.randomUUID(),scanVersion:'fixture',providerPolicy:'google_gemini'});
 assert.equal(fresh.status,'acquired');assert.notEqual(fresh.id,acquired.id);
 const image=crypto.randomUUID(),imageHash=crypto.randomBytes(32).toString('hex');
 await pool.query(`INSERT INTO stored_files(id,user_id,content_sha256,file_type,public_url,moderation_status,moderation_details,original_name,file_size)
 VALUES($1,$2,$3,'image','/image','rejected','{}','photo.jpg',5)`,[image,owner,imageHash]);
 assert.equal((await scans.listScans(pool,{search:'שם משתמש',type:'image',order:'asc'})).items[0].id,image);
 assert.equal((await scans.resetScan(pool,image,owner)).affectedFiles,1);
 // Server-side filters must find records outside the first displayed page.
 for(let i=0;i<60;i++)await pool.query(`INSERT INTO stored_files(id,user_id,file_type,original_name,moderation_status,created_at)
 VALUES($1,$2,'image',$3,'approved',$4)`,[crypto.randomUUID(),owner,i===0?'outside-first-page.jpg':'fixture-'+i+'.jpg',new Date(Date.UTC(2026,0,1,0,i))]);
 assert.equal((await scans.listScans(pool,{})).hasMore,true);
 assert.equal((await scans.listScans(pool,cf({name:{values:['outside-first-page.jpg'],exclude:false}}))).items[0].original_name,'outside-first-page.jpg');
 assert.equal((await scans.filterOptions(pool,{column:'name',optionSearch:'outside-first-page'})).options[0].value,'outside-first-page.jpg');
 await pool.query("INSERT INTO stored_files(id,file_type,moderation_status) VALUES($1,'image','approved')",[crypto.randomUUID()]);
 assert.equal((await scans.listScans(pool,cf({user:{values:[null],exclude:false}}))).items.length,1);
 assert.equal((await scans.listScans(pool,cf({user:{values:[null],exclude:true}}))).items.length,50);
 await assert.rejects(scans.listScans(pool,{order:'drop table'}),{status:400});
 await assert.rejects(scans.resetScan(pool,'not-uuid',owner),{status:400});
});
