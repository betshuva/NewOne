const test = require('node:test');
const assert = require('node:assert/strict');
const { Client } = require('pg');
const { chatHistoryWindow, chatHistoryQuery } = require('../server/chat-history-window');

test('history window validates dates and leaves backward pagination unchanged', () => {
  assert.equal(chatHistoryWindow({historySince: 'bad'}).extended, false);
  assert.equal(chatHistoryWindow({initialUnread: '1'}).initialUnread, true);
  assert.equal(chatHistoryWindow({before: '2026-09-27', initialUnread: '1'}).extended, false);
  const query = chatHistoryQuery('SELECT * FROM messages WHERE sender_id=$1', ['me'], '$1',
    chatHistoryWindow({historySince: '2026-09-27T00:00:00Z'}));
  assert.match(query.text, /created_at >= \$2/);
  assert.equal(query.values[1].toISOString(), '2026-09-27T00:00:00.000Z');
});

test('opening includes older unread messages, excludes hidden rows and retains the window after read',
  {skip: process.env.RUN_DB_TESTS !== '1'}, async () => {
    const client = new Client({connectionString: process.env.DATABASE_URL});
    await client.connect();
    try {
      await client.query('BEGIN');
      await client.query(`CREATE TEMP TABLE chat_history_fixture (
        id int, sender_id text, is_read int, created_at timestamptz, visible boolean) ON COMMIT DROP`);
      await client.query(`INSERT INTO chat_history_fixture
        SELECT n, CASE WHEN n=1 THEN 'me' ELSE 'friend' END,
          CASE WHEN n IN (1,5,23,119) THEN 0 ELSE 1 END,
          '2026-09-27T00:00:00Z'::timestamptz + n*interval '1 minute', n<>5
        FROM generate_series(1,120) n`);
      const base = 'SELECT id,sender_id,is_read,created_at FROM chat_history_fixture WHERE visible AND $1::text IS NOT NULL';
      const opening = await client.query(chatHistoryQuery(base, ['me'], '$1', chatHistoryWindow({initialUnread:'1'})));
      assert.equal(opening.rows.length, 98);
      assert.equal(opening.rows.at(-1).id, 23);
      assert.equal(opening.rows.some(r=>r.id===5 || r.id===1), false);
      await client.query('UPDATE chat_history_fixture SET is_read=1');
      const refreshed = await client.query(chatHistoryQuery(base, ['me'], '$1', chatHistoryWindow({
        historySince: opening.rows.at(-1).created_at.toISOString(),
      })));
      assert.deepEqual(refreshed.rows.map(r=>r.id), opening.rows.map(r=>r.id));
      const read = await client.query(chatHistoryQuery(base, ['me'], '$1', chatHistoryWindow({initialUnread:'1'})));
      assert.equal(read.rows.length, 50);
      assert.equal(read.rows[0].id, 120);
      const legacy = await client.query(chatHistoryQuery(base, ['me'], '$1', chatHistoryWindow()));
      assert.equal(legacy.rows.length, 50);
    } finally {
      await client.query('ROLLBACK');
      await client.end();
    }
  });
