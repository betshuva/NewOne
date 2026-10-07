'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { REPORT_EMAIL, SCHEMA, reportEmail, createReportNotifier } = require('../server/report-notifications');

const report = { id: '11111111-1111-4111-8111-111111111111',
  reporter_id: '22222222-2222-4222-8222-222222222222',
  target_id: '33333333-3333-4333-8333-333333333333',
  target_type: 'message', reason: 'inappropriate', details: '<img src=x onerror=alert(1)>',
  notification_version: 1, notification_attempts: 1 };

test('report email goes only to the designated address and escapes user content', () => {
  const email = reportEmail({ ...report, to: 'attacker@example.com' });
  assert.equal(email.to, 'betshuva@betshuva.com');
  assert.ok(email.text.includes(report.id));
  assert.ok(email.text.includes(report.details));
  assert.ok(email.html.includes('&lt;img'));
  assert.ok(!email.html.includes('<img'));
  assert.equal(email.attachments, undefined);
  assert.equal(email.replyTo, undefined);
  assert.equal(email.messageId, reportEmail(report).messageId);
  assert.notEqual(email.messageId, reportEmail({ ...report, notification_version: 2 }).messageId);
});

function fixture(sendMail) {
  let claimed = false;
  const queries = [];
  const db = { query: async (sql, values) => {
    queries.push({ sql, values });
    if (sql.startsWith('WITH candidate') && !claimed) {
      claimed = true;
      return { rows: [{ ...report }] };
    }
    return { rows: [] };
  } };
  const run = createReportNotifier({ getPool: async () => db, sendMail });
  return { run, queries };
}

test('successful delivery acknowledges only the claimed report revision', async () => {
  const f = fixture(async email => {
    assert.equal(email.to, REPORT_EMAIL);
    return { accepted: [REPORT_EMAIL] };
  });
  assert.equal(await f.run(), 1);
  const ack = f.queries.find(q => q.sql.includes('notified_version=GREATEST'));
  assert.deepEqual(ack.values, [report.id, 1]);
  assert.equal(await f.run(), 0);
});

test('SMTP failure persists a retry without marking the report delivered', async () => {
  const f = fixture(async () => { throw Object.assign(new Error('secret response'), { code: 'ETIMEDOUT' }); });
  assert.equal(await f.run(), 0);
  assert.ok(!f.queries.some(q => q.sql.includes('notified_version=GREATEST')));
  const retry = f.queries.find(q => q.sql.includes('notification_error=$3'));
  assert.deepEqual(retry.values, [report.id, 1, 'ETIMEDOUT', 60]);
});

test('a resolved SMTP promise without recipient acceptance is retried', async () => {
  const f = fixture(async () => ({ accepted: [], rejected: [REPORT_EMAIL] }));
  assert.equal(await f.run(), 0);
  assert.equal(f.queries.find(q => q.sql.includes('notification_error=$3')).values[2], 'RECIPIENT_NOT_ACCEPTED');
});

test('overlapping worker ticks do not send the same report twice', async () => {
  let release, started;
  const sending = new Promise(resolve => { started = resolve; });
  const wait = new Promise(resolve => { release = resolve; });
  const f = fixture(async () => { started(); await wait; return { accepted: [REPORT_EMAIL] }; });
  const first = f.run();
  await sending;
  assert.equal(await f.run(), 0);
  release();
  assert.equal(await first, 1);
});

test('database errors release the worker so the next tick can recover', async () => {
  let calls = 0;
  const run = createReportNotifier({ getPool: async () => {
    if (calls++ === 0) throw new Error('temporary database outage');
    return { query: async () => ({ rows: [] }) };
  }, sendMail: async () => assert.fail('No report to send') });
  await assert.rejects(run(), /temporary database outage/);
  assert.equal(await run(), 0);
});

test('PostgreSQL queue survives SMTP failure and a newer report during delivery', {
  skip: process.env.RUN_DB_TESTS !== '1',
}, async t => {
  const { Client } = require('pg');
  const db = new Client({ connectionString: process.env.DATABASE_URL,
    connectionTimeoutMillis: 10000, ssl: process.env.DB_SSL === 'true'
      ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' } : false });
  await db.connect();
  try {
    await db.query('BEGIN');
    await db.query(`CREATE TEMP TABLE user_reports(id UUID PRIMARY KEY,reporter_id UUID,
      target_type TEXT,target_id UUID,reason TEXT,details TEXT,status TEXT DEFAULT 'pending',
      created_at TIMESTAMPTZ DEFAULT now()) ON COMMIT DROP`);
    await db.query('SET LOCAL search_path=pg_temp,public');
    await db.query(SCHEMA);
    await db.query(SCHEMA); // Repeated startup migration must be harmless.
    await db.query(`INSERT INTO user_reports(id,reporter_id,target_type,target_id,reason,details)
      VALUES($1,$2,$3,$4,$5,$6)`,
    [report.id,report.reporter_id,report.target_type,report.target_id,report.reason,report.details]);
    const failed = createReportNotifier({ getPool: async () => db,
      sendMail: async () => { throw Object.assign(new Error('temporary failure'), { code: 'ETIMEDOUT' }); } });
    assert.equal(await failed(), 0);
    let saved = (await db.query('SELECT * FROM user_reports')).rows[0];
    assert.equal(saved.notified_version, 0);
    assert.equal(saved.notification_error, 'ETIMEDOUT');
    await db.query("UPDATE user_reports SET notification_next_at=now()-interval '1 second'");
    let sent = 0;
    const worker = createReportNotifier({ getPool: async () => db, sendMail: async () => {
      if (sent++ === 0) {
        // A repeat report must remain queued while the older email is in flight.
        await db.query(`UPDATE user_reports SET notification_version=2,
          notification_next_at=now(),notification_attempts=0`);
      }
      return { accepted: [REPORT_EMAIL] };
    } });
    assert.equal(await worker(), 2);
    saved = (await db.query('SELECT * FROM user_reports')).rows[0];
    assert.equal(saved.notified_version, 2);
    assert.equal(saved.notification_error, null);
    assert.ok(saved.notification_sent_at);
    assert.equal(await worker(), 0);
  } finally { await db.query('ROLLBACK'); await db.end(); }
});
