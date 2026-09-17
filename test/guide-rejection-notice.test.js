'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const fs = require('node:fs');
const vm = require('node:vm');
const { notifyGuideRejectedSend } = require('../server/guide-rejection-notice');
const { shortFilterReason } = require('../server/guide-filter-notice');
const { personalMessageVisible } = require('../server/conversation-history');
const { encryptedQueryValues, decryptMessageRows } = require('../server/message-at-rest');

function request(extra = {}) {
  return { guideUserId: randomUUID(), userId: randomUUID(), targetType: 'chat',
    targetId: randomUUID(), fileId: randomUUID(), fileType: 'image', kind: 'moderation',
    reason: 'התוכן לא עבר בדיקת בטיחות', authorize: async () => true,
    relay: async () => {}, ...extra };
}
function mockPool({ failInsert = false } = {}) {
  const state = { queries: [], rows: [], releases: 0 };
  const client = { async query(sql, values) {
    state.queries.push({ sql, values });
    if (sql.startsWith('SELECT id FROM messages')) return { rows: state.rows };
    if (sql.startsWith('INSERT INTO messages')) {
      if (failInsert) throw Error('insert failed');
      const row = { id: randomUUID(), created_at: new Date(), values };
      state.rows.push(row); return { rows: [row] };
    }
    return { rows: [] };
  }, release() { state.releases++; } };
  return { state, pool: { connect: async () => client } };
}

test('rejection notice is one sender-only text, sanitized and delivered after commit', async () => {
  const f = mockPool(), delivered = [];
  const input = request({ pool: f.pool,
    reason: 'בדיקה\nhttps://private.test/secret /betshuva-app/uploads/secret.png\u202e נדחה',
    relay: async (...args) => { assert.equal(f.state.queries.at(-1).sql, 'COMMIT'); delivered.push(args); } });
  const result = await notifyGuideRejectedSend(input);
  assert.equal(result.duplicate, false);
  const inserted = f.state.queries.find(q => q.sql.startsWith('INSERT INTO messages'));
  assert.doesNotMatch(inserted.sql, /file_url|file_name|reply_to_id/);
  assert.deepEqual(inserted.values.slice(0, 2), [input.guideUserId, input.userId]);
  assert.match(inserted.values[2], /התמונה לא נשלחה.*בדיקת התוכן/);
  assert.doesNotMatch(inserted.values[2], /https:|uploads|secret|\u202e|\n/);
  assert.equal(delivered.length, 1);
  assert.equal(delivered[0][0], input.userId);
  assert.equal(delivered[0][1], 'chat:message');
  assert.equal(delivered[0][2].fileType, 'text');
  assert.equal('fileUrl' in delivered[0][2], false);
  assert.equal('fileName' in delivered[0][2], false);
  assert.equal('classification' in delivered[0][2], false);
  assert.equal(f.state.releases, 1);
});

test('repeat of same persisted rejection creates and relays no duplicate', async () => {
  const f = mockPool(); let relays = 0;
  const input = request({ pool: f.pool, relay: async () => { relays++; } });
  const first = await notifyGuideRejectedSend(input);
  const second = await notifyGuideRejectedSend(input);
  assert.equal(second.duplicate, true);
  assert.equal(first.noticeMessageId, second.noticeMessageId);
  assert.equal(f.state.rows.length, 1);
  assert.equal(relays, 1);
  assert.ok(f.state.queries.some(q => q.sql.includes('pg_advisory_xact_lock')));
});

test('authorization rejection and insertion failure roll back and release without delivering', async () => {
  for (const failInsert of [false, true]) {
    const f = mockPool({ failInsert });
    const input = request({ pool: f.pool, authorize: async () => failInsert,
      relay: async () => assert.fail('must not relay') });
    if (failInsert) await assert.rejects(notifyGuideRejectedSend(input), /insert failed/);
    else assert.equal(await notifyGuideRejectedSend(input), null);
    assert.equal(f.state.queries.at(-1).sql, 'ROLLBACK');
    assert.equal(f.state.releases, 1);
    assert.equal(f.state.rows.length, 0);
  }
});

test('invalid identities, callbacks or nonrejection states cannot connect', async () => {
  let connections = 0;
  const input = request({ pool: { connect: async () => { connections++; } } });
  for (const extra of [{ fileId: 'scan_invalid' }, { kind: 'pending' }, { kind: 'approved' },
    { authorize: null }, { fileType: 'text' }, { targetId: null }, { userId: input.guideUserId }]) {
    await assert.rejects(notifyGuideRejectedSend({ ...input, ...extra }), TypeError);
  }
  assert.equal(connections, 0);
});

const source = fs.readFileSync(require.resolve('../server/index.js'), 'utf8');
function section(start, end) {
  const from = source.indexOf(start), to = source.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, start);
  return source.slice(from, to);
}

test('real wrapper uses exact sender policy and refuses unowned safety notices', async () => {
  const input = request({ kind: 'sender_filter' });
  const calls = [];
  const file = { id: input.fileId, file_type: 'image', moderation_status: 'approved',
    moderation_details: { classification: { detectedCategories: ['men', 'women'] } } };
  let accessible = true;
  const pool = { async query(sql, values) {
    if (sql.includes('SELECT id,user_id,file_type')) return { rows: [file] };
    assert.match(sql, /SELECT 1 FROM stored_files sf/);
    assert.deepEqual([...values], [input.userId, file.id, calls.at(-1).kind]);
    assert.match(sql, /sf.user_id=\$1/);
    assert.match(sql, /\$3='sender_filter'/);
    return { rows: accessible ? [{}] : [] };
  } };
  const context = vm.createContext({ shortFilterReason, personalMessageVisible,
    SYSTEM_USER_ID: input.guideUserId, SYSTEM_USER_NAME: 'Guide', relay() {},
    console: { error() {} }, notifyGuideRejectedSend: async args => {
      calls.push(args); return { authorized: await args.authorize(pool) };
    } });
  vm.runInContext(section('async function notifyRejectedSend(', '\nasync function validateApprovedFile('), context);
  const result = await context.notifyRejectedSend(pool, { userId: input.userId,
    toUserId: input.targetId, fileId: file.id,
    error: { senderDecision: { policy: { men: true, women: false },
      classification: file.moderation_details.classification } } });
  assert.equal(result.authorized, true);
  assert.equal(calls[0].reason, 'תוכן הכולל נשים חסום');
  assert.equal('fileUrl' in calls[0], false);
  assert.equal(await context.notifyRejectedSend(pool, { userId: input.userId,
    fileId: file.id, kind: 'moderation' }), null, 'approved files cannot produce safety warning');
  file.moderation_status = 'rejected'; accessible = false;
  assert.equal((await context.notifyRejectedSend(pool, { userId: input.userId,
    fileId: file.id, kind: 'moderation' })).authorized, false);
});

for (const delayed of [false, true]) {
  for (const rejection of ['sender_filter', 'moderation', 'pending', 'approved']) {
    if (delayed && rejection === 'pending') continue;
    test(`${delayed ? 'delayed' : 'synchronous'} scan explains only real ${rejection} rejection`, async () => {
      const notices = [], responses = [];
      const scanResult = { blocked: rejection === 'moderation', pending: rejection === 'pending',
        reason: 'סיבת בדיקה', classification: { detectedCategories: ['men'] } };
      const pool = { query: async () => ({ rows: [{ id: 'file', blocked_content_expires_at: null }] }) };
      const scope = {
        pool, scanResult, scanBotUpload: false, reportImageScan: false, reused: null,
        req: { user: { id: 'sender' }, body: { toUserId: 'friend' } },
        res: { status() { return this; }, json(value) { responses.push(value); } },
        allowed: { dbType: 'image' }, file: { originalname: 'image.png', size: 5 },
        storedInsert: { rows: [{ id: 'file' }] }, url: '/private/image.png',
        row: { id: 'pending', stored_file_id: 'file', user_id: 'sender', to_user_id: 'friend',
          file_url: '/private/image.png', file_name: 'image.png', file_type: 'image' },
        SCAN_BOT_ID: 'bot', onlineUsers: new Map(), outcomePersisted: false,
        assertSenderMediaAllowed: async () => {
          if (rejection === 'sender_filter') throw Object.assign(Error('סינון אישי'), { code: 'SENDER_CONTENT_FILTERED' });
        },
        completePending: async (_, operation) => operation(pool),
        notifyRejectedSend: async (_, notice) => notices.push(notice),
        logActivity() {}, relay() {}, saveScanBotReport: async () => null,
      };
      let code;
      if (delayed) {
        code = section('        try {\n          await assertSenderMediaAllowed(pool, { userId: row.user_id,',
          '        // Re-evaluate the current policy after a delayed scan,');
        code = `for(let attempt=0;attempt<1;attempt++){${code}}`;
      } else {
        code = section('    if (!scanResult?.pending) {\n      try {\n        await assertSenderMediaAllowed(',
          '    if (!scanResult?.pending && groupFilter &&');
      }
      await vm.runInNewContext(`(async()=>{${code}})()`, scope);
      assert.equal(notices.length, ['sender_filter', 'moderation'].includes(rejection) ? 1 : 0);
      if (notices.length) {
        assert.equal(notices[0].userId, 'sender');
        assert.equal(notices[0].toUserId, 'friend');
        assert.equal(notices[0].kind, rejection);
      }
    });
  }
}

test('concurrent retries dedupe encrypted text in an isolated PostgreSQL schema', {
  skip: process.env.RUN_DB_TESTS !== '1',
}, async t => {
  const { Client, Pool } = require('pg');
  const config = { connectionString: process.env.DATABASE_URL, connectionTimeoutMillis: 5000,
    ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' } : false };
  const owner = new Client(config); await owner.connect();
  const schema = `rejection_notice_test_${randomUUID().replaceAll('-', '')}`;
  await owner.query(`CREATE SCHEMA "${schema}"`);
  const raw = new Pool({ ...config, options: `-c search_path=${schema},pg_catalog`, max: 5 });
  const oldKey = process.env.MESSAGE_ENCRYPTION_KEY;
  process.env.MESSAGE_ENCRYPTION_KEY = 'isolated-rejection-test-encryption-key-32';
  t.after(async () => {
    await raw.end(); await owner.query(`DROP SCHEMA "${schema}" CASCADE`); await owner.end();
    if (oldKey === undefined) delete process.env.MESSAGE_ENCRYPTION_KEY; else process.env.MESSAGE_ENCRYPTION_KEY = oldKey;
  });
  await raw.query(`CREATE TABLE messages(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    sender_id uuid,recipient_id uuid,group_id uuid,type text,body text,file_url text,file_name text,
    reply_to_id uuid,delivery_summary jsonb,created_at timestamptz)`);
  const pool = { connect: async () => {
    const client = await raw.connect();
    return { query: async (sql, args) => decryptMessageRows(await client.query(sql, encryptedQueryValues(sql, args))),
      release: () => client.release() };
  } };
  let relays = 0;
  const input = request({ pool, relay: async () => {
    relays++; assert.equal((await raw.query('SELECT count(*)::int n FROM messages')).rows[0].n, 1);
  } });
  const results = await Promise.all(Array.from({ length: 6 }, () => notifyGuideRejectedSend(input)));
  assert.equal(results.filter(r => !r.duplicate).length, 1);
  assert.equal(relays, 1);
  const rows = (await raw.query('SELECT * FROM messages')).rows;
  assert.equal(rows.length, 1); assert.match(rows[0].body, /^enc:v1:/);
  assert.equal(rows[0].recipient_id, input.userId);
  for (const key of ['file_url', 'file_name', 'reply_to_id']) assert.equal(rows[0][key], null);
  await notifyGuideRejectedSend({ ...input, reason: 'סיבה חדשה', relay: async () => { relays++; } });
  assert.equal((await raw.query('SELECT count(*)::int n FROM messages')).rows[0].n, 2);
});
