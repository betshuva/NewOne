'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { Client } = require('pg');
const { personalMessageVisible, messageAfterConversationClear } = require('../server/conversation-history');

const id = n => `22000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const [owner, friend, sameNameFriend, stranger, emptyOwner, group, privateGroup] = [1,2,3,4,5,6,7].map(id);

function routes(db) {
  const source = fs.readFileSync(path.join(__dirname, '../server/index.js'), 'utf8');
  const start = source.indexOf("app.get('/api/media-library/catalog', auth,");
  const end = source.indexOf('\nasync function loadStoredFileBytes', start);
  assert.ok(start > 0 && end > start);
  const callbacks = new Map();
  const auth = () => {};
  vm.runInNewContext(source.slice(start, end), {
    app: { get(route, guard, callback) { assert.equal(guard, auth); callbacks.set(route, callback); } },
    auth, getPool: async () => db, personalMessageVisible, messageAfterConversationClear, console,
  });
  return async (route = '/api/media-library', userId = owner, query = {}) => {
    let status = 200, body;
    const headers = {};
    await callbacks.get(route)({ user: { id: userId }, query }, {
      status(code) { status = code; return this; },
      set(name, value) { headers[name] = value; return this; },
      json(value) { body = JSON.parse(JSON.stringify(value)); },
    });
    return { status, body, headers };
  };
}

test('media catalog validates exact destinations and deletion filters before touching the database', async () => {
  const request = routes({ query() { assert.fail('invalid query reached the database'); } });
  for (const query of [
    { destinationKind: 'chat' }, { destinationId: friend },
    { destinationKind: 'user', destinationId: friend },
    { destinationKind: 'group', destinationId: "' OR true --" },
    { deletable: 'yes' }, { dateFrom: '2026-09-10', dateTo: '2026-09-01' },
    { minSize: '200', maxSize: '100' },
  ]) assert.equal((await request('/api/media-library', owner, query)).status, 400);
});

test('media catalog and pages aggregate unique owned files without leaking inaccessible destinations', {
  skip: process.env.RUN_DB_TESTS !== '1',
}, async t => {
  const db = new Client({ connectionString: process.env.DATABASE_URL,
    ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' } : false });
  await db.connect();
  try {
    // No public fallback: every table used by the route is isolated on this connection.
    await db.query('SET search_path=pg_temp');
    await db.query(`CREATE TEMP TABLE stored_files(id uuid PRIMARY KEY,user_id uuid,original_name text,
        storage_path text,public_url text,mime_type text,file_type text,file_size bigint,
        moderation_status text,moderation_details jsonb,created_at timestamptz DEFAULT '2026-09-01',
        released_at timestamptz);
      CREATE TEMP TABLE messages(id uuid PRIMARY KEY,sender_id uuid,recipient_id uuid,group_id uuid,
        file_url text,created_at timestamptz DEFAULT '2026-09-02',deleted_for_everyone boolean DEFAULT false,
        deleted_for_sender boolean DEFAULT false);
      CREATE TEMP TABLE received_message_media(message_id uuid,user_id uuid,source_file_id uuid,
        stored_file_id uuid,status text);
      CREATE TEMP TABLE message_user_deletions(message_id uuid,user_id uuid);
      CREATE TEMP TABLE conversation_user_state(user_id uuid,kind text,target_id uuid,cleared_at timestamptz);
      CREATE TEMP TABLE message_requests(file_url text);
      CREATE TEMP TABLE pending_scans(file_url text);
      CREATE TEMP TABLE users(id uuid,name text,profile_pic_url text,created_at timestamptz);
      CREATE TEMP TABLE groups(id uuid,name text,profile_pic_url text,created_at timestamptz);
      CREATE TEMP TABLE group_members(group_id uuid,user_id uuid,status text,joined_at timestamptz);
      CREATE TEMP TABLE listings(id uuid,user_id uuid,title text,image_url text,created_at timestamptz);
      CREATE TEMP TABLE listing_images(listing_id uuid,url text);
      CREATE TEMP TABLE education_forms(id uuid,group_id uuid,created_by uuid,title text,file_url text,created_at timestamptz);
      CREATE TEMP TABLE shared_gifs(id uuid,creator_id uuid,stored_file_id uuid,status text,title text,created_at timestamptz);
      CREATE TEMP TABLE media_backup_items(stored_file_id uuid,user_id uuid,provider text,status text,
        verified_at timestamptz,restore_verified_at timestamptz,remote_file_id text,encryption_metadata jsonb);
      CREATE TEMP TABLE media_classification_appeals(stored_file_id uuid,user_id uuid,status text,created_at timestamptz);`);
    const request = routes(db);
    const catalog = async (userId = owner) => {
      const result = await request('/api/media-library/catalog', userId);
      assert.equal(result.status, 200);
      assert.equal(result.headers['Cache-Control'], 'no-store');
      return result.body;
    };
    const library = async (query = {}, userId = owner) => {
      const result = await request('/api/media-library', userId, query);
      assert.equal(result.status, 200);
      assert.equal(result.headers['Cache-Control'], 'no-store');
      return result.body;
    };
    const reset = async () => {
      await db.query(`TRUNCATE stored_files,messages,received_message_media,message_user_deletions,
        conversation_user_state,message_requests,pending_scans,users,groups,group_members,
        listings,listing_images,education_forms,shared_gifs,media_backup_items,media_classification_appeals`);
      await db.query('INSERT INTO users(id,name) VALUES($1,$2),($3,$4),($5,$4),($6,$7)',
        [owner,'Owner',friend,'Same Name',sameNameFriend,stranger,'Hidden User']);
      await db.query('INSERT INTO groups(id,name) VALUES($1,$2),($3,$4)', [group,'Hikers',privateGroup,'Hidden Group']);
      await db.query("INSERT INTO group_members VALUES($1,$2,'member','2026-09-01')", [group,owner]);
    };
    const addFile = async (n, type = 'image', size = 100, userId = owner) => {
      await db.query(`INSERT INTO stored_files(id,user_id,original_name,public_url,file_type,file_size,moderation_status)
        VALUES($1,$2,$3,$4,$5,$6,'approved')`,[id(n),userId,`file-${n}.${type}`,`/catalog-${n}`,type,size]);
      return id(n);
    };
    const addMessage = async (n, file, sender, recipient, groupId = null, receivedFile = null) => {
      await db.query(`INSERT INTO messages(id,sender_id,recipient_id,group_id,file_url)
        VALUES($1,$2,$3,$4,$5)`,[id(n),sender,recipient,groupId,`/catalog-${file}`]);
      if (receivedFile) await db.query(`INSERT INTO received_message_media(message_id,user_id,stored_file_id,status)
        VALUES($1,$2,$3,'ready')`,[id(n),owner,id(receivedFile)]);
    };

    await t.test('summary and type totals cover every page; exhausted pages preserve counts and bytes', async () => {
      await reset();
      for (let n = 100; n < 145; n++) await addFile(n, n < 141 ? 'image' : 'document', n);
      await addFile(999, 'video', 99999, stranger);
      const result = await catalog();
      assert.equal(result.summary.totalCount, 45);
      assert.equal(result.summary.totalBytes, 5490);
      assert.deepEqual(result.summary.byType.image, { count: 41, bytes: 4920 });
      assert.deepEqual(result.summary.byType.document, { count: 4, bytes: 570 });
      assert.deepEqual(result.summary.byType.video, { count: 0, bytes: 0 });
      assert.equal(result.summary.deletableCount, 45);
      const first = await library();
      const second = await library({ offset: '40' });
      assert.equal(first.total, 45); assert.equal(first.totalBytes, 5490);
      assert.equal(first.items.length, 40); assert.equal(second.items.length, 5);
      assert.equal(new Set([...first.items, ...second.items].map(file => file.id)).size,45);
      assert.deepEqual(await library({ offset: '90' }), { total: 45, totalBytes: 5490, items: [] });
      assert.deepEqual(await library({ type: 'audio' }), { total: 0, totalBytes: 0, items: [] });
      assert.equal((await library({ type: 'document', minSize: '143', maxSize: '144' })).totalBytes,287);
      const empty = await catalog(emptyOwner);
      assert.equal(empty.summary.totalCount,0); assert.equal(empty.summary.totalBytes,0);
      assert.deepEqual(empty.destinations,[]);
    });

    await t.test('one deduplicated received file is counted once per destination across repeated delivery', async () => {
      await reset(); await addFile(100);
      await addMessage(200,900,friend,owner,null,100);
      await addMessage(201,901,friend,owner,null,100);
      await addMessage(202,902,friend,null,group,100);
      await addMessage(203,903,sameNameFriend,owner,null,100);
      const result = await catalog();
      assert.equal(result.summary.totalCount,1);
      assert.deepEqual(result.destinations.map(d=>[d.kind,d.id,d.count,d.bytes]),
        [['chat',friend,1,100],['chat',sameNameFriend,1,100],['group',group,1,100]]);
      assert.equal((await library({ destinationKind:'chat',destinationId:friend })).total,1);
      assert.equal((await library({ destinationKind:'group',destinationId:group })).total,1);
      // UUID filters distinguish contacts that have identical display names.
      await addFile(101, 'document', 250);
      await addMessage(204,101,sameNameFriend,owner);
      assert.equal((await library({ destinationKind:'chat',destinationId:friend })).total,1);
      assert.equal((await library({ destinationKind:'chat',destinationId:sameNameFriend })).total,2);
      assert.equal((await library({ destinationKind:'chat',destinationId:stranger })).total,0);
    });

    await t.test('facets and exact filters hide personal clears, deletion, pre-join history and inaccessible groups', async () => {
      await reset(); await addFile(100);
      await addMessage(200,900,friend,owner,null,100);
      await addMessage(201,901,friend,null,group,100);
      await addMessage(202,100,stranger,sameNameFriend);
      await addMessage(203,100,stranger,null,privateGroup);
      let result=await catalog();
      assert.deepEqual(result.destinations.map(d=>d.id).sort(),[friend,group].sort());
      assert.equal((await library({ destinationKind:'group',destinationId:privateGroup })).total,0);
      await db.query("INSERT INTO conversation_user_state VALUES($1,'chat',$2,'2026-09-03')",[owner,friend]);
      result=await catalog(); assert.deepEqual(result.destinations.map(d=>d.id),[group]);
      assert.equal((await library({ destinationKind:'chat',destinationId:friend })).total,0);
      await db.query("UPDATE messages SET created_at='2026-08-31' WHERE id=$1",[id(201)]);
      assert.deepEqual((await catalog()).destinations,[]);
      await db.query("UPDATE messages SET created_at='2026-09-02' WHERE id=$1",[id(201)]);
      await db.query('INSERT INTO message_user_deletions VALUES($1,$2)',[id(201),owner]);
      assert.deepEqual((await catalog()).destinations,[]);
      assert.equal((await library({ destinationKind:'group',destinationId:group })).total,0);
      await db.query('TRUNCATE message_user_deletions');
      await db.query("UPDATE group_members SET status='left'");
      assert.deepEqual((await catalog()).destinations,[]);
    });

    await t.test('group profile and group messages for the same file count as one group file', async () => {
      await reset(); await addFile(100);
      await addMessage(200,100,owner,null,group);
      await db.query('UPDATE groups SET profile_pic_url=$1 WHERE id=$2',['/catalog-100',group]);
      const result = await catalog();
      assert.deepEqual(result.destinations,[{kind:'group',id:group,label:'Hikers',count:1,bytes:100}]);
      assert.equal((await library({ destinationKind:'group',destinationId:group })).total,1);
    });

    await t.test('delete eligibility and byte totals include pending work and exclude active backups', async () => {
      await reset();
      for (let n=100;n<106;n++) await addFile(n,'document',n);
      await db.query("INSERT INTO message_requests VALUES('/catalog-100')");
      await db.query("INSERT INTO pending_scans VALUES('/catalog-101')");
      await db.query("INSERT INTO received_message_media(source_file_id,status) VALUES($1,'queued')",[id(102)]);
      await db.query(`INSERT INTO media_backup_items(stored_file_id,user_id,provider,status)
        VALUES($1,$3,'google_drive','uploading'),($2,$3,'google_drive','verified')`,[id(103),id(104),owner]);
      await db.query("UPDATE stored_files SET released_at=now() WHERE id=$1",[id(104)]);
      const result=await catalog();
      assert.equal(result.summary.deletableCount,2); assert.equal(result.summary.deletableBytes,209);
      assert.equal(result.summary.backedUpCount,1); assert.equal(result.summary.releasedCount,1);
      const free=await library({deletable:'true'}), busy=await library({deletable:'false'});
      assert.equal(free.total,2); assert.equal(free.totalBytes,209);
      assert.ok(free.items.every(file=>file.canDelete));
      assert.equal(busy.total,4); assert.ok(busy.items.every(file=>!file.canDelete));
    });

    await t.test('backed-up filtering includes only verified backups, with matching catalog counts', async () => {
      await reset();
      const statuses=['queued','uploading','uploaded','failed','verified'];
      for (let index=0;index<statuses.length;index++) {
        await addFile(100+index,'document',100+index);
        await db.query(`INSERT INTO media_backup_items(stored_file_id,user_id,provider,status)
          VALUES($1,$2,'google_drive',$3)`,[id(100+index),owner,statuses[index]]);
      }
      await addFile(105,'document',105);
      const all=await library(), backedUp=await library({backup:'backed_up'});
      assert.equal(all.total,6);
      assert.equal(backedUp.total,1); assert.equal(backedUp.totalBytes,104);
      assert.deepEqual(backedUp.items.map(file=>file.id),[id(104)]);
      assert.equal(backedUp.items[0].backupStatus,'verified');
      assert.equal((await catalog()).summary.backedUpCount,1);
    });

    await t.test('hidden self messages are deletable while another reader still protects a source file', async () => {
      await reset(); await addFile(100);
      await addMessage(200,100,owner,owner);
      assert.equal((await catalog()).summary.deletableCount,0);
      await db.query('INSERT INTO message_user_deletions VALUES($1,$2)',[id(200),owner]);
      assert.equal((await catalog()).summary.deletableCount,1);
      assert.equal((await library()).items[0].canDelete,true);
      await addMessage(201,100,owner,friend);
      await db.query("INSERT INTO conversation_user_state VALUES($1,'chat',$2,'2026-09-03')",[owner,friend]);
      assert.equal((await catalog()).summary.deletableCount,0);
      assert.deepEqual((await catalog()).destinations,[]);
    });
  } finally { await db.end(); }
});
