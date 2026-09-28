'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const { once } = require('node:events');
const { Client, Pool } = require('pg');
const express = require('express');
const { MEDIA_PROGRESS_SCHEMA, registerMediaProgressRoutes } = require('../server/media-playback-progress');
const { CONVERSATION_SCHEMA } = require('../server/conversation-history');

test('audio progress persists by account/content, enforces access, and rejects stale writes',
  { skip: process.env.RUN_DB_TESTS !== '1' }, async t => {
    const owner = new Client({ connectionString: process.env.DATABASE_URL });
    await owner.connect();
    const schema = `audio_progress_${randomUUID().replaceAll('-', '')}`;
    await owner.query(`CREATE SCHEMA "${schema}"`);
    const db = new Pool({ connectionString: process.env.DATABASE_URL,
      options: `-c search_path=${schema}`, max: 3 });
    t.after(async () => { await db.end(); await owner.query(`DROP SCHEMA "${schema}" CASCADE`); await owner.end(); });
    await db.query(`CREATE TABLE users(id UUID PRIMARY KEY);
      CREATE TABLE stored_files(id UUID PRIMARY KEY,user_id UUID,public_url TEXT,file_type TEXT,
        content_sha256 TEXT,moderation_status TEXT,content_purged_at TIMESTAMPTZ,moderation_details JSONB);
      CREATE TABLE messages(id UUID PRIMARY KEY,sender_id UUID,recipient_id UUID,group_id UUID,
        file_url TEXT,deleted_for_everyone BOOLEAN DEFAULT FALSE,deleted_for_sender BOOLEAN DEFAULT FALSE,
        created_at TIMESTAMPTZ DEFAULT now());
      CREATE TABLE message_user_deletions(message_id UUID,user_id UUID);
      CREATE TABLE group_members(group_id UUID,user_id UUID,status TEXT,joined_at TIMESTAMPTZ);
      ${CONVERSATION_SCHEMA}; ${MEDIA_PROGRESS_SCHEMA}`);
    const user = randomUUID(), listener = randomUUID(), outsider = randomUUID(), group = randomUUID();
    for (const id of [user, listener, outsider]) await db.query('INSERT INTO users VALUES($1)', [id]);
    const url = name => `/betshuva-app/uploads/${name}.mp3`;
    for (const [name, hash, type, status] of [
      ['first', 'a', 'audio', 'approved'], ['copy', 'a', 'audio', 'approved'],
      ['second', 'b', 'audio', 'approved'], ['video', 'c', 'video', 'approved'],
      ['stopped', 'd', 'audio', 'stopped']]) {
      await db.query(`INSERT INTO stored_files VALUES($1,$2,$3,$4,$5,$6,NULL,$7)`,
        [randomUUID(), user, url(name), type, hash.repeat(64), status,
          JSON.stringify({ audio: { durationSeconds: 4009 } })]);
    }
    const messageId = randomUUID();
    await db.query(`INSERT INTO messages(id,sender_id,recipient_id,file_url) VALUES($1,$2,$3,$4)`,
      [messageId, user, listener, url('first')]);
    const app = express(); app.use(express.json());
    registerMediaProgressRoutes(app, { getPool: async () => db, auth(req, res, next) {
      const id = req.headers.authorization?.replace('Bearer ', '');
      if (![user, listener, outsider].includes(id)) return res.sendStatus(401);
      req.user = { id }; next();
    } });
    const server = app.listen(0, '127.0.0.1'); await once(server, 'listening');
    t.after(() => new Promise(resolve => { server.close(resolve); server.closeAllConnections(); }));
    async function call(who, file = 'first', body, mediaType = 'audio') {
      const response = await fetch(`http://127.0.0.1:${server.address().port}/api/${mediaType}-progress?fileUrl=${encodeURIComponent(url(file))}`, {
        method: body ? 'PUT' : 'GET', headers: { Authorization: `Bearer ${who}`, 'Content-Type': 'application/json' },
        ...(body ? { body: JSON.stringify(body) } : {}),
      });
      return { status: response.status, data: response.status === 401 ? null : await response.json() };
    }
    assert.deepEqual((await call(user, 'video', undefined, 'video')).data, { positionMs: 0, version: 0 });
    assert.equal((await call(user, 'video', { positionMs: 123000, version: 0 }, 'video')).status, 200);
    assert.equal((await call(user, 'video', undefined, 'video')).data.positionMs, 123000);
    assert.equal((await call(outsider, 'video', undefined, 'video')).status, 404);
    assert.equal((await call(user, 'first', undefined, 'video')).status, 404);
    assert.equal((await call('invalid')).status, 401);
    assert.equal((await call(outsider)).status, 404);
    assert.equal((await call(outsider, 'first', { positionMs: 100, version: 0, userId: user })).status, 404);
    for (const file of ['video', 'stopped', 'missing']) assert.equal((await call(user, file)).status, 404);
    assert.deepEqual((await call(user)).data, { positionMs: 0, version: 0 });
    assert.deepEqual((await call(user, 'first', { positionMs: 120000, version: 0, userId: listener })).data,
      { positionMs: 120000, version: 1 });
    assert.deepEqual((await call(user, 'copy')).data, { positionMs: 120000, version: 1 });
    assert.deepEqual((await call(listener)).data, { positionMs: 0, version: 0 });
    assert.deepEqual((await call(user, 'second')).data, { positionMs: 0, version: 0 });
    assert.equal((await call(user, 'first', { positionMs: 100, version: 0 })).status, 409);
    assert.equal((await call(user, 'first', { positionMs: 60000, version: 1 })).data.positionMs, 60000);
    assert.equal((await call(user, 'first', { positionMs: 5000000, version: 2 })).data.positionMs, 4009000);
    assert.equal((await call(user, 'first', { positionMs: 0, version: 3 })).data.positionMs, 0);
    for (const body of [{ positionMs: -1, version: 4 }, { positionMs: 1.2, version: 4 },
      { positionMs: 10, version: -1 }, { positionMs: '10', version: 4 }]) {
      assert.equal((await call(user, 'first', body)).status, 400);
    }
    // Two devices loading the same version: only one save can win.
    const competing = await Promise.all([1000, 2000].map(positionMs =>
      call(user, 'first', { positionMs, version: 4 })));
    assert.deepEqual(competing.map(r => r.status).sort(), [200, 409]);
    await db.query('INSERT INTO message_user_deletions VALUES($1,$2)', [messageId, listener]);
    assert.equal((await call(listener)).status, 404);
    await db.query(`INSERT INTO group_members VALUES($1,$2,'member',now()-INTERVAL '1 day')`, [group, listener]);
    await db.query(`INSERT INTO messages(id,sender_id,group_id,file_url) VALUES($1,$2,$3,$4)`,
      [randomUUID(), user, group, url('second')]);
    assert.equal((await call(listener, 'second')).status, 200);
    await db.query("UPDATE group_members SET status='left' WHERE user_id=$1", [listener]);
    assert.equal((await call(listener, 'second')).status, 404);
    await db.query('DELETE FROM users WHERE id=$1', [user]);
    assert.equal((await db.query('SELECT count(*) FROM media_playback_progress WHERE user_id=$1', [user])).rows[0].count, '0');
  });
