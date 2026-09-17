'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { Client } = require('pg');
const { registerMediaRenameRoutes } = require('../server/media-rename');

const id = n => `88000000-0000-4000-8000-${String(n).padStart(12, '0')}`;

function route(db) {
  let handler;
  const auth = () => {};
  registerMediaRenameRoutes({ get(path, guard, callback) {
    assert.equal(path, '/api/media-library/resolve');
    assert.equal(guard, auth);
    handler = callback;
  } }, { auth, getPool: async () => db });
  return async (user, url) => {
    const result = { status: 200, headers: {} };
    await handler({ user: { id: user }, query: { url } }, {
      status(code) { result.status = code; return this; },
      set(key, value) { result.headers[key] = value; return this; },
      json(body) { result.body = body; return this; },
    });
    return result;
  };
}

test('resolver validates URLs before querying and registers authentication', async () => {
  const request = route({ query() { assert.fail('invalid request queried database'); } });
  for (const url of [null, '', [], 'file:///etc/passwd', '//other/file', '/a\nname', '/'+ 'x'.repeat(2048)]) {
    assert.equal((await request(id(1), url)).status, 400);
  }
});

test('resolver returns only owned files and accessible ready personal copies', {
  skip: process.env.RUN_DB_TESTS !== '1',
}, async t => {
  const db = new Client({ connectionString: process.env.DATABASE_URL,
    ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' } : false });
  await db.connect();
  try {
    await db.query('SET search_path=pg_temp');
    await db.query(`CREATE TEMP TABLE stored_files(id uuid PRIMARY KEY,user_id uuid,original_name text,
        public_url text,content_purged_at timestamptz);
      CREATE TEMP TABLE messages(id uuid PRIMARY KEY,sender_id uuid,recipient_id uuid,group_id uuid,
        file_url text,created_at timestamptz DEFAULT '2026-09-02',
        deleted_for_everyone boolean DEFAULT false,deleted_for_sender boolean DEFAULT false);
      CREATE TEMP TABLE received_message_media(message_id uuid,user_id uuid,stored_file_id uuid,status text);
      CREATE TEMP TABLE message_user_deletions(message_id uuid,user_id uuid);
      CREATE TEMP TABLE conversation_user_state(user_id uuid,kind text,target_id uuid,cleared_at timestamptz);
      CREATE TEMP TABLE group_members(group_id uuid,user_id uuid,status text,joined_at timestamptz);`);
    const owner=id(1),sender=id(2),stranger=id(3),group=id(4),copy=id(11),source=id(12),message=id(21);
    await db.query(`INSERT INTO stored_files VALUES($1,$2,'my renamed.JPG','/copy',NULL),
      ($3,$4,'sender original.JPG','/original',NULL)`, [copy,owner,source,sender]);
    await db.query(`INSERT INTO messages(id,sender_id,recipient_id,file_url) VALUES($1,$2,$3,'/original')`,
      [message,sender,owner]);
    await db.query(`INSERT INTO received_message_media VALUES($1,$2,$3,'ready')`, [message,owner,copy]);
    const request=route(db);
    await t.test('direct ownership and source alias return only the reader copy name', async () => {
      for (const url of ['/copy','/original']) {
        const result=await request(owner,url);
        assert.equal(result.status,200);
        assert.deepEqual(result.body,{item:{id:copy,name:'my renamed.JPG'}});
        assert.equal(result.headers['Cache-Control'],'no-store');
      }
      assert.equal((await request(stranger,'/original')).status,404);
      assert.equal((await request(stranger,'/copy')).status,404);
      assert.equal((await request(sender,'/original')).body.item.id,source);
    });
    await t.test('queued copies, invalid ownership and inaccessible private messages cannot resolve source', async () => {
      await db.query("UPDATE received_message_media SET status='queued'");
      assert.equal((await request(owner,'/original')).status,404);
      await db.query("UPDATE received_message_media SET status='ready'");
      await db.query('UPDATE stored_files SET user_id=$1 WHERE id=$2',[stranger,copy]);
      assert.equal((await request(owner,'/original')).status,404);
      await db.query('UPDATE stored_files SET user_id=$1 WHERE id=$2',[owner,copy]);
      await db.query('UPDATE messages SET recipient_id=$1',[stranger]);
      assert.equal((await request(owner,'/original')).status,404);
      await db.query('UPDATE messages SET recipient_id=$1',[owner]);
      await db.query('INSERT INTO message_user_deletions VALUES($1,$2)',[message,owner]);
      assert.equal((await request(owner,'/original')).status,404);
      assert.equal((await request(owner,'/copy')).status,200);
      await db.query('TRUNCATE message_user_deletions');
      await db.query("INSERT INTO conversation_user_state VALUES($1,'chat',$2,'2026-09-03')",[owner,sender]);
      assert.equal((await request(owner,'/original')).status,404);
      await db.query('TRUNCATE conversation_user_state');
    });
    await t.test('group source alias requires current membership and visible join date', async () => {
      await db.query('UPDATE messages SET group_id=$1,recipient_id=NULL',[group]);
      assert.equal((await request(owner,'/original')).status,404);
      await db.query("INSERT INTO group_members VALUES($1,$2,'member','2026-09-03')",[group,owner]);
      assert.equal((await request(owner,'/original')).status,404);
      await db.query("UPDATE group_members SET joined_at='2026-09-01'");
      assert.equal((await request(owner,'/original')).status,200);
      await db.query("UPDATE group_members SET status='left'");
      assert.equal((await request(owner,'/original')).status,404);
    });
  } finally { await db.end(); }
});
