'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const { Client } = require('pg');
const { SCHEMA,retainScanPreview,attachCachedScanPreview } = require('../server/cached-scan-previews');

test('cached decisions retain their exact frame after upload deletion, with owner and hash isolation', {
  skip:process.env.RUN_DB_TESTS !== '1',
}, async () => {
  const db = new Client({ connectionString:process.env.DATABASE_URL });
  await db.connect();
  try {
    await db.query(`SET search_path=pg_temp;
      CREATE TEMP TABLE users(id uuid PRIMARY KEY);
      CREATE TEMP TABLE video_scan_budgets(id uuid PRIMARY KEY,user_id text,content_sha256 text,manifest jsonb);
      CREATE TEMP TABLE stored_files(id uuid PRIMARY KEY,user_id uuid,content_sha256 text,content_purged_at timestamptz);
      CREATE TEMP TABLE audit_scan_previews(id uuid PRIMARY KEY,stored_file_id uuid REFERENCES stored_files(id) ON DELETE CASCADE,
        content_sha256 text,thumbnail bytea,image bytea,width int,height int,UNIQUE(stored_file_id,content_sha256));`);
    await db.query(SCHEMA.replace('CREATE TABLE IF NOT EXISTS','CREATE TEMP TABLE'));
    const user=randomUUID(),scan=randomUUID(),oldFile=randomUUID(),newFile=randomUUID(),preview=randomUUID();
    const manifest=[{frameIndex:0,sha256:'frame-hash',timeSeconds:4.25}];
    await db.query('INSERT INTO users VALUES($1)',[user]);
    await db.query('INSERT INTO video_scan_budgets VALUES($1,$2,$3,$4)',[scan,user,'video-hash',JSON.stringify(manifest)]);
    for(const id of [oldFile,newFile]) await db.query("INSERT INTO stored_files VALUES($1,$2,'video-hash',NULL)",[id,user]);
    await db.query("INSERT INTO audit_scan_previews VALUES($1,$2,'frame-hash',$3,$4,100,80)",[preview,oldFile,Buffer.from('thumb'),Buffer.from('original scanned frame')]);
    await retainScanPreview(db,preview,{scanId:scan,frameIndex:0});
    await retainScanPreview(db,preview,{scanId:scan,frameIndex:0});
    await db.query('DELETE FROM stored_files WHERE id=$1',[oldFile]);
    assert.equal((await db.query('SELECT count(*) FROM audit_scan_previews')).rows[0].count,'0');
    const state={id:scan,budget:{manifest},result:{frameResults:[{pending:true,timestampSeconds:4.25}]}};
    const records=[];
    const copy=(tracking={userId:user,storedFileId:newFile})=>attachCachedScanPreview(db,state,tracking,async event=>records.push(event));
    await copy({userId:randomUUID(),storedFileId:newFile});
    assert.equal(records.length,0);
    await db.query("UPDATE stored_files SET content_sha256='different' WHERE id=$1",[newFile]);
    await copy(); assert.equal(records.length,0);
    await db.query("UPDATE stored_files SET content_sha256='video-hash' WHERE id=$1",[newFile]);
    await copy(); await copy();
    assert.equal((await db.query('SELECT count(*) FROM audit_scan_previews')).rows[0].count,'1');
    assert.deepEqual((await db.query('SELECT image FROM audit_scan_previews')).rows[0].image,Buffer.from('original scanned frame'));
    assert.equal(records[0].tracking.videoBudget.timestampSeconds,4.25);
    assert.equal(records[0].provider,'cache');
    assert.equal(records[0].result.pending,true);
    await db.query('DELETE FROM users WHERE id=$1',[user]);
    assert.equal((await db.query('SELECT count(*) FROM cached_scan_previews')).rows[0].count,'0');
  } finally { await db.end(); }
});
