'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const { Client } = require('pg');
const { CONVERSATION_SCHEMA, messageAfterConversationClear, registerConversationHistory } = require('../server/conversation-history');

const id = n => `10000000-0000-4000-8000-${String(n).padStart(12, '0')}`;

test('personal conversation cleanup is isolated, persistent and protects stored media', {
  skip: process.env.RUN_DB_TESTS !== '1',
}, async t => {
  const db = new Client({ connectionString: process.env.DATABASE_URL,
    ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' } : false });
  await db.connect();
  let server;
  try {
    // A missing fixture must fail instead of falling through to a real table.
    await db.query('SET search_path=pg_temp');
    await db.query(`CREATE TEMP TABLE users(id uuid PRIMARY KEY);
      CREATE TEMP TABLE user_contacts(owner_id uuid,contact_id uuid);
      CREATE TEMP TABLE messages(id uuid PRIMARY KEY,sender_id uuid,recipient_id uuid,group_id uuid,
        type text,body text,file_url text,created_at timestamptz DEFAULT now(),
        deleted_for_everyone boolean DEFAULT false,deleted_for_sender boolean DEFAULT false);
      CREATE TEMP TABLE group_members(group_id uuid,user_id uuid,status text,joined_at timestamptz,
        PRIMARY KEY(group_id,user_id));
      CREATE TEMP TABLE message_requests(sender_id uuid,recipient_id uuid,file_url text,created_at timestamptz DEFAULT now());
      CREATE TEMP TABLE message_user_deletions(message_id uuid,user_id uuid,PRIMARY KEY(message_id,user_id));
      CREATE TEMP TABLE stored_files(id uuid PRIMARY KEY,user_id uuid,context_type text,context_id uuid,
        public_url text,created_at timestamptz DEFAULT now());
      CREATE TEMP TABLE received_message_media(message_id uuid,user_id uuid,stored_file_id uuid,status text);`);
    await db.query(CONVERSATION_SCHEMA.replace('CREATE TABLE', 'CREATE TEMP TABLE'));
    const [me,friend,outsider,group,privateMessage,groupMessage,ownFile,foreignFile,unusedFile,failedFile] =
      [1,2,3,4,5,6,7,8,9,10].map(id);
    await db.query('INSERT INTO users VALUES($1),($2),($3)', [me,friend,outsider]);
    await db.query('INSERT INTO user_contacts VALUES($1,$2)', [me,friend]);
    await db.query("INSERT INTO group_members VALUES($1,$2,'member','2000-01-01'),($1,$3,'member','2000-01-01')", [group,me,friend]);
    await db.query("INSERT INTO messages(id,sender_id,recipient_id,type,body,file_url) VALUES($1,$2,$3,'image','private','/owned')", [privateMessage,me,friend]);
    await db.query("INSERT INTO messages(id,sender_id,group_id,type,body) VALUES($1,$2,$3,'text','group')", [groupMessage,friend,group]);
    await db.query("INSERT INTO stored_files(id,user_id,context_type,context_id,public_url) VALUES($1,$2,'chat',$3,'/owned'),($4,$3,'chat',$2,'/foreign'),($5,$2,'chat',$3,'/unused'),($6,$2,'chat',$3,'/failed')",
      [ownFile,me,friend,foreignFile,unusedFile,failedFile]);
    const calls = [], events = [];
    const pool = { query: db.query.bind(db), connect: async () => ({ query: db.query.bind(db), release() {} }) };
    const app = express(); app.use(express.json());
    registerConversationHistory(app, { getPool: async () => pool,
      auth(req,res,next) {
        if (!req.headers['x-user']) return res.sendStatus(401);
        req.user = { id: req.headers['x-user'], isTeen: req.headers['x-teen'] === 'true' }; next();
      }, rateLimit(req,res,next) { next(); },
      async deleteOwnMedia(_pool,userId,fileId) {
        calls.push({userId,fileId});
        if (fileId === ownFile) throw Object.assign(new Error('in use'), {code:'MEDIA_IN_USE'});
        if (fileId === failedFile) throw Object.assign(new Error('Drive disconnected'), {code:'BACKUP_RECONNECT_REQUIRED'});
        return { deletedBytes: 123 };
      }, notifyUser(userId,event,payload) { events.push({userId,event,payload}); },
    });
    server = app.listen(0, '127.0.0.1');
    await new Promise(resolve => server.once('listening', resolve));
    const request = async (kind,target,user=me,body={},action='clear',teen=false) => {
      const response = await fetch(`http://127.0.0.1:${server.address().port}/api/conversations/${kind}/${target}/${action}`, {
        method:'POST', headers:{'Content-Type':'application/json', ...(user ? {'x-user':user} : {}), ...(teen ? {'x-teen':'true'} : {})},
        body:JSON.stringify(body),
      });
      return {status:response.status,body:response.status===401 ? null : await response.json()};
    };
    const visible = async (messageId,user) => (await db.query(`SELECT m.id FROM messages m
      WHERE m.id=$1 AND m.deleted_for_everyone=FALSE AND NOT EXISTS
        (SELECT 1 FROM message_user_deletions d WHERE d.message_id=m.id AND d.user_id=$2)
        AND ${messageAfterConversationClear('m', '$2')}`, [messageId,user])).rows.length > 0;
    const hidden = async (kind,target) => (await db.query(`SELECT cs.hidden AND NOT EXISTS (
      SELECT 1 FROM messages m WHERE m.deleted_for_everyone=FALSE
        AND NOT EXISTS (SELECT 1 FROM message_user_deletions d WHERE d.message_id=m.id AND d.user_id=$1)
        AND ${messageAfterConversationClear('m', '$1')}
        AND CASE WHEN $2='group' THEN m.group_id=$3 ELSE m.group_id IS NULL AND
          ((m.sender_id=$1 AND m.recipient_id=$3) OR (m.sender_id=$3 AND m.recipient_id=$1)) END
      ) AS hidden FROM conversation_user_state cs WHERE cs.user_id=$1 AND cs.kind=$2 AND cs.target_id=$3`, [me,kind,target])).rows[0]?.hidden || false;

    await t.test('authentication, target validation, strict options and membership are enforced before writes', async () => {
      assert.equal((await request('chat',friend,null)).status,401);
      assert.equal((await request('other',friend)).status,400);
      assert.equal((await request('chat','invalid')).status,400);
      assert.equal((await request('chat',friend,me,{deleteMedia:'true'})).status,400);
      assert.equal((await request('chat',outsider)).status,404);
      assert.equal((await request('group',group,outsider)).status,403);
      assert.equal((await request('group',group,me,{},'clear',true)).status,403);
      assert.equal((await db.query('SELECT * FROM conversation_user_state')).rows.length,0);
    });
    await t.test('clear defaults to preserving files, contacts, group membership and the recipient copy', async () => {
      const response = await request('chat',friend);
      assert.equal(response.status,200);
      assert.equal(response.body.hidden,false);
      assert.equal(response.body.clearedMessages,1);
      assert.ok(Number.isFinite(Date.parse(response.body.clearedAt)));
      assert.deepEqual(response.body.media,{requested:false,deleted:0,skipped:0,failed:0,deletedBytes:0});
      assert.equal(await visible(privateMessage,me),false);
      assert.equal(await visible(privateMessage,friend),true);
      assert.equal((await db.query('SELECT body,file_url FROM messages WHERE id=$1',[privateMessage])).rows[0].body,'private');
      assert.equal((await db.query('SELECT * FROM user_contacts')).rows.length,1);
      assert.equal((await db.query('SELECT * FROM group_members')).rows.length,2);
      assert.equal(calls.length,0);
      assert.equal(events.at(-1).userId,me);
      assert.equal(events.at(-1).event,'conversation:changed');
    });
    await t.test('delete hides only the personal row and a new message makes it visible again', async () => {
      assert.equal((await request('chat',friend,me,{deleteConversation:true})).body.clearedMessages,0);
      assert.equal(await hidden('chat',friend),true);
      await db.query("INSERT INTO messages(id,sender_id,recipient_id,body) VALUES($1,$2,$3,'new')", [id(11),friend,me]);
      assert.equal(await hidden('chat',friend),false);
      assert.equal(await visible(id(11),me),true);
      assert.equal(await visible(privateMessage,me),false);
    });
    await t.test('explicit reopen restores the row without restoring cleared history', async () => {
      await request('chat',friend,me,{deleteConversation:true});
      assert.equal(await hidden('chat',friend),true);
      assert.equal((await request('chat',friend,me,{},'open')).body.hidden,false);
      assert.equal(await hidden('chat',friend),false);
      assert.equal(await visible(privateMessage,me),false);
      assert.equal(await visible(id(11),me),false);
    });
    await t.test('group clear changes neither another member history nor current membership', async () => {
      const response=await request('group',group,me,{deleteConversation:true});
      assert.equal(response.body.clearedMessages,1);
      assert.equal(await visible(groupMessage,me),false);
      assert.equal(await visible(groupMessage,friend),true);
      assert.equal(await hidden('group',group),true);
      assert.equal((await db.query('SELECT status FROM group_members WHERE user_id=$1',[me])).rows[0].status,'member');
      await db.query("UPDATE group_members SET status='pending' WHERE user_id=$1",[me]);
      assert.equal((await request('group',group)).status,403);
      assert.equal((await request('group',group,me,{},'open')).status,403);
    });
    await t.test('optional cleanup selects only owned files and reports retained/failed copies without undoing history', async () => {
      const response=await request('chat',friend,me,{deleteMedia:true});
      assert.deepEqual(response.body.media,{requested:true,deleted:1,skipped:1,failed:1,deletedBytes:123});
      assert.deepEqual(calls.map(call=>call.fileId).sort(),[ownFile,unusedFile,failedFile].sort());
      assert.ok(calls.every(call=>call.userId===me));
      assert.equal(await visible(privateMessage,me),false);
      assert.equal(await visible(privateMessage,friend),true);
    });
    await t.test('future messages outside the returned cutoff survive cleanup', async () => {
      await db.query("INSERT INTO messages(id,sender_id,recipient_id,created_at) VALUES($1,$2,$3,now()+interval '1 minute')",[id(12),friend,me]);
      await request('chat',friend,me,{deleteConversation:true});
      assert.equal(await visible(id(12),me),true);
      assert.equal(await hidden('chat',friend),false);
    });
    await t.test('older sends that commit after the clear snapshot do not return to history or reopen the conversation', async () => {
      await db.query('DELETE FROM messages WHERE id=$1',[id(12)]);
      const response=await request('chat',friend,me,{deleteConversation:true});
      await db.query('INSERT INTO messages(id,sender_id,recipient_id,created_at) VALUES($1,$2,$3,$4)',
        [id(13),friend,me,response.body.clearedAt]);
      assert.equal((await db.query('SELECT * FROM message_user_deletions WHERE message_id=$1',[id(13)])).rows.length,0);
      assert.equal(await visible(id(13),me),false);
      assert.equal(await visible(id(13),friend),true);
      assert.equal(await hidden('chat',friend),true);
    });
    await t.test('optional cleanup includes an owned received copy even when the message uses the sender URL',async()=>{
      const receivedFile=id(20), receivedMessage=id(21);
      await db.query("INSERT INTO stored_files(id,user_id,context_type,public_url) VALUES($1,$2,'received','/my-independent-copy')",[receivedFile,me]);
      await db.query("INSERT INTO messages(id,sender_id,recipient_id,file_url) VALUES($1,$2,$3,'/friend-original')",[receivedMessage,friend,me]);
      await db.query("INSERT INTO received_message_media VALUES($1,$2,$3,'ready')",[receivedMessage,me,receivedFile]);
      calls.length=0;
      const response=await request('chat',friend,me,{deleteMedia:true});
      assert.equal(response.status,200);
      assert.equal(calls.filter(call=>call.fileId===receivedFile&&call.userId===me).length,1);
      assert.equal(await visible(receivedMessage,me),false);
      assert.equal(await visible(receivedMessage,friend),true);
      assert.equal((await db.query('SELECT file_url FROM messages WHERE id=$1',[receivedMessage])).rows[0].file_url,'/friend-original');
    });
    await t.test('normal clear preserves pending personal saves while media deletion cancels only the cleared scope',async()=>{
      const queuedDirect=id(30), queuedGroup=id(31), futureDirect=id(32);
      await db.query(`INSERT INTO messages(id,sender_id,recipient_id,file_url)
        VALUES($1,$2,$3,'/pending-friend-source')`,[queuedDirect,friend,me]);
      await db.query(`INSERT INTO messages(id,sender_id,group_id,file_url)
        VALUES($1,$2,$3,'/pending-group-source')`,[queuedGroup,friend,group]);
      await db.query(`INSERT INTO messages(id,sender_id,recipient_id,file_url,created_at)
        VALUES($1,$2,$3,'/future-friend-source',now()+interval '1 minute')`,[futureDirect,friend,me]);
      await db.query(`INSERT INTO received_message_media(message_id,user_id,status)
        VALUES($1,$4,'queued'),($2,$4,'queued'),($3,$4,'queued'),($1,$5,'queued')`,
      [queuedDirect,queuedGroup,futureDirect,me,friend]);
      assert.equal((await request('chat',friend,me)).status,200);
      assert.equal((await db.query(`SELECT status FROM received_message_media
        WHERE message_id=$1 AND user_id=$2`,[queuedDirect,me])).rows[0].status,'queued');
      assert.equal((await request('chat',friend,me,{deleteMedia:true})).status,200);
      const jobs=(await db.query(`SELECT message_id,user_id,status FROM received_message_media
        WHERE message_id=ANY($1::uuid[])`,[[queuedDirect,queuedGroup,futureDirect]])).rows;
      assert.equal(jobs.find(row=>row.message_id===queuedDirect&&row.user_id===me).status,'skipped');
      assert.ok(jobs.filter(row=>row.message_id!==queuedDirect||row.user_id!==me)
        .every(row=>row.status==='queued'));
      await db.query("UPDATE group_members SET status='member' WHERE user_id=$1",[me]);
      assert.equal((await request('group',group,me,{deleteMedia:true})).status,200);
      assert.equal((await db.query(`SELECT status FROM received_message_media
        WHERE message_id=$1 AND user_id=$2`,[queuedGroup,me])).rows[0].status,'skipped');
      assert.equal((await db.query(`SELECT status FROM received_message_media
        WHERE message_id=$1 AND user_id=$2`,[futureDirect,me])).rows[0].status,'queued');
    });
    await t.test('media deletion cutoff survives later keep-files clears and covers an older send committed afterward',async()=>{
      const response=await request('chat',friend,me,{deleteMedia:true});
      assert.equal(response.status,200);
      const state=async()=>(await db.query(`SELECT media_deleted_at,cleared_at
        FROM conversation_user_state WHERE user_id=$1 AND kind='chat' AND target_id=$2`,[me,friend])).rows[0];
      const deletionCutoff=(await state()).media_deleted_at.toISOString();
      assert.equal(deletionCutoff,response.body.clearedAt);
      const lateMessage=id(40);
      await db.query(`INSERT INTO messages(id,sender_id,recipient_id,file_url,created_at)
        VALUES($1,$2,$3,'/late-original',$4)`,[lateMessage,friend,me,deletionCutoff]);
      await db.query("INSERT INTO received_message_media(message_id,user_id,status) VALUES($1,$2,'queued')",[lateMessage,me]);
      assert.equal((await request('chat',friend,me)).status,200);
      assert.equal((await state()).media_deleted_at.toISOString(),deletionCutoff);
      const cancelled=(await db.query(`SELECT 1 FROM messages m
        JOIN conversation_user_state cs ON cs.user_id=$2 AND cs.kind='chat'
          AND cs.target_id=m.sender_id
        WHERE m.id=$1 AND m.created_at<=cs.media_deleted_at`,[lateMessage,me])).rows;
      assert.equal(cancelled.length,1);
      assert.equal((await db.query(`SELECT status FROM received_message_media
        WHERE message_id=$1 AND user_id=$2`,[lateMessage,me])).rows[0].status,'queued');
    });
  } finally {
    if (server) await new Promise(resolve=>server.close(resolve));
    await db.end();
  }
});
