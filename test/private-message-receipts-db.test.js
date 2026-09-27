'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { Pool } = require('pg');
const { withPrivateMessageReceipt } = require('../server/private-message-receipts');

test('private send retries are atomic, scoped and deduplicated across concurrent connections', {
  skip: process.env.RUN_DB_TESTS !== '1',
}, async () => {
  const schema = `qa_receipts_${process.pid}_${Date.now()}`;
  const config = { connectionString: process.env.DATABASE_URL,
    ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' } : false };
  const admin = new Pool(config);
  await admin.query(`CREATE SCHEMA ${schema}`);
  const pool = new Pool({ ...config, options: `-c search_path=${schema}`, max: 4 });
  try {
    await pool.query(`CREATE TABLE private_message_sends(user_id text,client_message_id text,
      request_hash text,result jsonb,PRIMARY KEY(user_id,client_message_id));
      CREATE TABLE sent(id integer GENERATED ALWAYS AS IDENTITY,text text);`);
    let effects = 0;
    let reject = false;
    const handler = withPrivateMessageReceipt({ getPool: async () => pool,
      sendMessage: async (req, res) => {
        const saved = await req.messagePool.query('INSERT INTO sent(text) VALUES($1) RETURNING id', [req.body.text]);
        req.messageEffects.push(() => { effects++; });
        return reject ? res.status(503).json({ error: 'temporary' })
          : res.json({ id: String(saved.rows[0].id), status: 'sent' });
      },
    });
    async function send(user = 'owner', text = 'hello', key = 'msg_unique_key_123456') {
      const res = { code: 200, status(code) { this.code = code; return this; },
        json(value) { this.value = value; return this; } };
      await handler({ user: { id: user }, body: { toUserId: 'peer', text, clientMessageId: key } }, res);
      return res;
    }
    const replies = await Promise.all(Array.from({ length: 8 }, () => send()));
    assert.ok(replies.every(r => r.code === 200 && r.value.id === replies[0].value.id));
    assert.equal(effects, 1);
    assert.equal((await pool.query('SELECT * FROM sent')).rowCount, 1);
    assert.equal((await send('owner', 'changed')).code, 409);
    assert.equal((await send('other')).code, 200);
    assert.equal((await pool.query('SELECT * FROM sent')).rowCount, 2);
    reject = true;
    assert.equal((await send('owner', 'failed', 'msg_another_key_12345')).code, 503);
    assert.equal((await pool.query('SELECT * FROM sent')).rowCount, 2);
    reject = false;
    assert.equal((await send('owner', 'failed', 'msg_another_key_12345')).code, 200);
    assert.equal((await pool.query('SELECT * FROM sent')).rowCount, 3);
  } finally {
    await pool.end(); await admin.query(`DROP SCHEMA ${schema} CASCADE`); await admin.end();
  }
});
