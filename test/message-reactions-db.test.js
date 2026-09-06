'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { Client } = require('pg');
const express = require('express');
const { registerMessageReactions } = require('../server/message-reactions');
const { contentAllowedByFilter } = require('../server/content-filter-policy');

// Explicit opt-in; every table is TEMP and the transaction is rolled back.
test('reactions enforce membership, visibility and per-user ownership in PostgreSQL', {
  skip: process.env.RUN_DB_TESTS !== '1',
}, async t => {
  const db = new Client({ connectionString: process.env.DATABASE_URL,
    ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' } : false });
  await db.connect();
  let server;
  try {
    await db.query('BEGIN');
    await db.query(`
      CREATE TEMP TABLE users(id uuid PRIMARY KEY,content_filter jsonb);
      CREATE TEMP TABLE messages(id uuid PRIMARY KEY,sender_id uuid,recipient_id uuid,group_id uuid,type text,
        file_url text,deleted_for_everyone boolean DEFAULT false,deleted_for_sender boolean DEFAULT false);
      CREATE TEMP TABLE groups(id uuid PRIMARY KEY,creator_id uuid,content_filter jsonb);
      CREATE TEMP TABLE group_members(group_id uuid,user_id uuid,status text,filter_override jsonb);
      CREATE TEMP TABLE stored_files(public_url text,moderation_details jsonb);
      CREATE TEMP TABLE message_user_deletions(message_id uuid,user_id uuid);
      CREATE TEMP TABLE blocked_users(blocker_id uuid,blocked_id uuid);
      CREATE TEMP TABLE message_reactions(message_id uuid,user_id uuid,emoji text,updated_at timestamptz DEFAULT now(),PRIMARY KEY(message_id,user_id));
    `);
    const sql = require('node:fs').readFileSync(require.resolve('../server/scoped-content-filter.sql'), 'utf8');
    await db.query(sql.replace('FUNCTION betshuva_effective_filter', 'FUNCTION pg_temp.betshuva_effective_filter'));
    const query = db.query.bind(db);
    db.query = (sql, values) => query(sql.replaceAll('betshuva_effective_filter(', 'pg_temp.betshuva_effective_filter('), values);
    const id = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
    const [a,b,outsider,privateId,groupId,groupMessage,selfId] = [1,2,3,4,5,6,7].map(id);
    for (const user of [a,b,outsider]) await db.query('INSERT INTO users VALUES($1,$2)', [user, JSON.stringify({text:true,nonHumanImages:false,men:false,women:false,children:false})]);
    await db.query('INSERT INTO messages(id,sender_id,recipient_id,type) VALUES($1,$2,$3,\'text\'),($4,$2,$2,\'text\')', [privateId,a,b,selfId]);
    await db.query('INSERT INTO groups(id,creator_id) VALUES($1,$2)', [groupId,a]);
    await db.query("INSERT INTO group_members(group_id,user_id,status) VALUES($1,$2,'member'),($1,$3,'member')", [groupId,a,b]);
    await db.query("INSERT INTO messages(id,sender_id,group_id,type) VALUES($1,$2,$3,'text')", [groupMessage,a,groupId]);
    const app = express(); app.use(express.json());
    registerMessageReactions(app, { auth: (req,res,next) => {
      const user = req.headers['x-test-user'];
      if (!user) return res.sendStatus(401);
      req.user = {id:user}; next();
    }, rateLimit: (req,res,next) => next(), getPool: async () => db, contentAllowedByFilter });
    server = app.listen(0, '127.0.0.1');
    await new Promise(resolve => server.once('listening', resolve));
    const request = async (message, user, emoji, method = emoji === undefined ? 'GET' : 'PUT') => {
      const response = await fetch(`http://127.0.0.1:${server.address().port}/api/messages/${message}/reactions`, {
        method, headers: {'Content-Type':'application/json', ...(user ? {'x-test-user':user} : {})},
        ...(method === 'PUT' ? {body:JSON.stringify({emoji})} : {}),
      });
      return {status: response.status, body: response.status === 200 ? await response.json() : null};
    };
    await t.test('authentication and private participants', async () => {
      assert.equal((await request(privateId,null)).status,401);
      assert.equal((await request(privateId,outsider,'👍')).status,404);
      assert.equal((await request(privateId,a,'bad')).status,400);
      assert.equal((await request('bad',a)).status,400);
    });
    await t.test('one reaction per user, replace and remove only your own', async () => {
      assert.equal((await request(privateId,a,'👍')).status,200);
      const both = await request(privateId,b,'👍');
      assert.deepEqual(both.body,[{emoji:'👍',count:2,mine:true}]);
      await request(privateId,a,'❤️');
      await request(privateId,a,null);
      assert.deepEqual((await request(privateId,a)).body,[{emoji:'👍',count:1,mine:false}]);
    });
    await t.test('self conversation remains private', async () => {
      assert.equal((await request(selfId,a,'🙏')).status,200);
      assert.equal((await request(selfId,b)).status,404);
    });
    await t.test('deleted and blocked messages cannot be reacted to', async () => {
      await db.query('INSERT INTO message_user_deletions VALUES($1,$2)', [privateId,b]);
      assert.equal((await request(privateId,b,'👍')).status,404);
      await db.query('DELETE FROM message_user_deletions');
      await db.query('INSERT INTO blocked_users VALUES($1,$2)', [b,a]);
      assert.equal((await request(privateId,b)).status,404);
      await db.query('DELETE FROM blocked_users');
      await db.query('UPDATE messages SET deleted_for_everyone=true WHERE id=$1',[privateId]);
      assert.equal((await request(privateId,a)).status,404);
    });
    await t.test('former members and content-filtered group messages are inaccessible', async () => {
      assert.equal((await request(groupMessage,b,'👍')).status,200);
      await db.query("UPDATE group_members SET status='left' WHERE user_id=$1",[b]);
      assert.equal((await request(groupMessage,b)).status,404);
      await db.query("UPDATE group_members SET status='member' WHERE user_id=$1",[b]);
      await db.query("UPDATE messages SET type='image',file_url='/image' WHERE id=$1",[groupMessage]);
      await db.query(`INSERT INTO stored_files VALUES('/image','{"classification":{"category":"women","detectedCategories":["women"]}}')`);
      assert.equal((await request(groupMessage,b)).status,404);
      assert.equal((await request(groupMessage,a)).status,200);
    });
  } finally {
    if (server) await new Promise(resolve => server.close(resolve));
    await db.query('ROLLBACK');
    await db.end();
  }
});
