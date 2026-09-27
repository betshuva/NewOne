'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { Client } = require('pg');

test('recovery skips live uploads, recovers interrupted scans, and does not queue twice', {
  skip: process.env.RUN_DB_TESTS !== '1',
}, async () => {
  const db = new Client({ connectionString: process.env.DATABASE_URL,
    ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' } : false });
  await db.connect();
  try {
    await db.query('SET search_path=pg_temp');
    await db.query(`CREATE TEMP TABLE stored_files(id uuid,user_id uuid,context_type text,
      context_id uuid,public_url text,original_name text,file_type text,mime_type text,
      moderation_status text,created_at timestamptz,audit_operation_id uuid,audit_parent_event_id bigint);
      CREATE TEMP TABLE pending_scans(id integer GENERATED ALWAYS AS IDENTITY,
        user_id uuid,to_user_id uuid,group_id uuid,file_url text,file_name text,file_type text,mime_type text,
        audit_operation_id uuid,audit_parent_event_id bigint);
      CREATE TEMP TABLE messages(file_url text);`);
    const id = n => `34000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
    for (const n of [1, 2, 3, 4]) await db.query(`INSERT INTO stored_files
      (id,user_id,context_type,context_id,public_url,original_name,file_type,mime_type,moderation_status,created_at) VALUES
      ($1,$2,'chat',$3,$4,'clip.mp4','video','video/mp4',$5,now()-interval '5 minutes')`,
    [id(n), id(10), id(11), `/uploads/${n}.mp4`, n === 4 ? 'approved' : 'pending']);
    await db.query("INSERT INTO messages VALUES('/uploads/3.mp4')");
    const activeUploadFileIds = new Set([id(1)]);
    let retries = 0;
    const source = fs.readFileSync(require.resolve('../server/index.js'), 'utf8');
    const start = source.indexOf('async function recoverOrphanedPendingScans(');
    const end = source.indexOf('\nconst GOVERNMENT_LOCALITIES_RESOURCE', start);
    const recover = vm.runInNewContext(`${source.slice(start, end)};recoverOrphanedPendingScans`, {
      activeUploadFileIds, requestPendingScanRetry() { retries++; }, console: { log() {} },
    });
    assert.equal(await recover(db), 1);
    assert.deepEqual((await db.query('SELECT file_url FROM pending_scans')).rows,
      [{ file_url: '/uploads/2.mp4' }]);
    assert.equal(await recover(db), 0);
    activeUploadFileIds.clear(); // The request is no longer running (e.g. after restart).
    assert.equal(await recover(db), 1);
    assert.equal(await recover(db), 0);
    assert.equal(retries, 2);
  } finally { await db.end(); }
});
