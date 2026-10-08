'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const ledger = require('../server/video-scan-budget');

const review = ledger.MODESTY_UNCERTAINTY_REVIEW_OPERATION;
const passed = { available: true, decision: 'modest', model: 'review-model' };

// Exercise the real reservation code without touching an application database.
// Connections serialize like the scan-row lock held by the SQL transaction.
function fixture({ policy = 'google_gemini', count = 4, used = {}, now,
  operations = [] } = {}) {
  const clock = now || new Date('2026-10-08T00:00:00Z');
  const row = { id: 'scan', status: 'active', provider_policy: policy,
    frame_count: count, manifest_hash: 'manifest', manifest: [], lease_token: 'lease',
    total_used: used.total || 0, google_vision_used: used.google_vision || 0,
    openai_used: used.openai || 0, gemini_used: used.gemini || 0,
    started_at: new Date('2026-10-08T00:00:00Z'),
    deadline_at: new Date('2026-10-08T00:05:00Z'),
    lease_expires_at: new Date('2026-10-08T00:00:30Z'), scan_version: 'test-v1' };
  const saved = operations.map(operation => ({ scan_id: row.id,
    lease_token: row.lease_token, frame_index: 0, ...operation }));
  let tail = Promise.resolve();
  const pool = {
    async connect() {
      const previous = tail;
      let unlock;
      tail = new Promise(resolve => { unlock = resolve; });
      await previous;
      return { release: unlock, async query(sql, args = []) {
        const q = sql.replace(/\s+/g, ' ').trim();
        const rows = value => ({ rows: value ? [value] : [], rowCount: value ? 1 : 0 });
        if (['BEGIN', 'COMMIT', 'ROLLBACK'].includes(q) || q.startsWith('SET LOCAL'))
          return rows();
        if (q.startsWith('SELECT * FROM video_scan_budgets')) return rows({ ...row });
        if (q === 'SELECT clock_timestamp() AS now') return rows({ now: clock });
        if (q.startsWith('SELECT count(*)::int AS used FROM video_scan_operations'))
          return rows({ used: saved.filter(item => item.scan_id === args[0] &&
            item.operation === args[1]).length });
        if (q.startsWith('SELECT provider,count(DISTINCT frame_index)::int AS used')) {
          const counts = ['gemini', 'openai'].map(provider => ({ provider,
            used: new Set(saved.filter(item => item.scan_id === args[0] &&
              item.provider === provider && item.operation === 'modesty')
              .map(item => item.frame_index)).size }));
          return { rows: counts.filter(item => item.used > 0) };
        }
        if (q.startsWith('SELECT * FROM video_scan_operations')) {
          const found = q.includes('WHERE id=$1')
            ? saved.find(item => item.id === args[0] && item.scan_id === args[1] &&
              item.lease_token === args[2])
            : saved.find(item => item.scan_id === args[0] && item.frame_index === args[1] &&
              (args.length === 3 ? item.operation === args[2]
                : item.provider === args[2] && item.operation === args[3]));
          return rows(found && { ...found });
        }
        if (q.startsWith('UPDATE video_scan_budgets SET total_used=total_used+1')) {
          if (clock >= row.deadline_at) return rows();
          row.total_used++;
          for (const provider of ['google_vision', 'openai', 'gemini'])
            if (q.includes(`${provider}_used=${provider}_used+1`)) row[`${provider}_used`]++;
          return rows({ ...row });
        }
        if (q.startsWith('INSERT INTO video_scan_operations')) {
          const [id, scanId, frameIndex, provider, operation, leaseToken] = args;
          saved.push({ id, scan_id: scanId, frame_index: frameIndex, provider,
            operation, lease_token: leaseToken, status: 'reserved' });
          return rows();
        }
        if (q.startsWith('UPDATE video_scan_operations SET status=')) {
          const item = saved.find(item => item.id === args[0]);
          item.status = args[1];
          item.result = JSON.parse(args[2]);
          return rows();
        }
        if (q.startsWith("UPDATE video_scan_budgets SET status='stopped'")) {
          Object.assign(row, { status: 'stopped', reason: args[1], result: JSON.parse(args[2]) });
          return rows({ ...row });
        }
        throw new Error(`Unexpected fixture query: ${q}`);
      } };
    },
  };
  const context = { scanId: row.id, leaseToken: row.lease_token };
  const reserve = (frameIndex = 0, provider = 'gemini', operation = review) =>
    ledger.reserveVideoScanOperation(pool, { ...context, frameIndex, provider, operation });
  const finish = (reservation, result = passed) => ledger.finishVideoScanOperation(pool,
    { ...context, reservationId: reservation.reservationId, result });
  return { pool, context, row, saved, reserve, finish };
}

test('review support preserves every existing total and provider ceiling', () => {
  assert.equal(ledger.VIDEO_SCAN_MAX_UNCERTAINTY_REVIEWS, 3);
  assert.deepEqual(ledger.VIDEO_SCAN_PROVIDER_POLICIES.google_openai_gemini.limitsPerFrame,
    { total: 6, google_vision: 3, openai: 2, gemini: 1 });
  assert.deepEqual(ledger.VIDEO_SCAN_PROVIDER_POLICIES.google_gemini.limitsPerFrame,
    { total: 5, google_vision: 3, openai: 0, gemini: 2 });
  assert.deepEqual(ledger.VIDEO_SCAN_PROVIDER_POLICIES.google_gemini_optional_openai.limitsPerFrame,
    { total: 6, google_vision: 3, openai: 2, gemini: 2 });
});

test('a review reserves separately from modesty and repeats reuse only that review', async () => {
  const f = fixture({ used: { total: 1, gemini: 1 }, operations: [{ id: 'modesty',
    provider: 'gemini', operation: 'modesty', status: 'completed',
    result: { available: true, decision: 'uncertain' } }] });
  const reservation = await f.reserve();
  assert.equal(reservation.status, 'reserved');
  assert.equal(reservation.budget.used.total, 2);
  assert.equal(reservation.budget.used.gemini, 2);
  await f.finish(reservation);
  const reused = await f.reserve();
  assert.equal(reused.status, 'cached');
  assert.deepEqual(reused.result, passed);
  assert.equal(reused.budget.used.total, 2);
  assert.equal(f.saved.filter(item => item.operation === review).length, 1);
});

test('concurrent providers share at most three charged reviews per video', async () => {
  const f = fixture({ policy: 'google_gemini_optional_openai' });
  const results = await Promise.all([
    f.reserve(0, 'gemini'), f.reserve(1, 'openai'),
    f.reserve(2, 'gemini'), f.reserve(3, 'openai'),
  ]);
  assert.equal(results.filter(result => result.status === 'reserved').length, 3);
  assert.equal(results[3].reason, 'uncertainty_review_limit');
  assert.equal(f.row.total_used, 3);
  assert.equal(f.row.gemini_used, 2);
  assert.equal(f.row.openai_used, 1);
  assert.equal(f.saved.length, 3);
});

test('a frame cannot spend a second review by switching providers', async () => {
  const f = fixture({ policy: 'google_openai_gemini' });
  assert.equal((await f.reserve(0, 'openai')).status, 'reserved');
  const duplicate = await f.reserve(0, 'gemini');
  assert.equal(duplicate.reason, 'uncertainty_review_limit');
  assert.equal(f.row.total_used, 1);
  assert.equal(f.saved.length, 1);
});

test('in-flight duplicate review does not reserve another charged call', async () => {
  const f = fixture();
  const reservation = await f.reserve();
  const duplicate = await f.reserve();
  assert.equal(duplicate.status, 'busy');
  assert.equal(duplicate.reason, 'operation_in_flight');
  await f.finish(reservation);
  assert.equal((await f.reserve()).status, 'cached');
  assert.equal(f.row.total_used, 1);
});

test('failed optional OpenAI review remains charged and cannot retry', async () => {
  const f = fixture({ policy: 'google_gemini_optional_openai' });
  const reservation = await f.reserve(0, 'openai');
  const result = { available: false, errorCode: 'REQUEST_FAILED' };
  await f.finish(reservation, result);
  const duplicate = await f.reserve(0, 'openai');
  assert.equal(duplicate.status, 'cached');
  assert.deepEqual(duplicate.result, result);
  assert.equal(f.row.total_used, 1);
});

test('reviews cannot exceed total or provider ceilings or reopen an expired scan', async () => {
  for (const settings of [
    { count: 1, used: { total: 5, google_vision: 3, gemini: 2 } },
    { count: 1, used: { total: 2, gemini: 2 } },
    { count: 1, policy: 'google_openai_gemini', used: { total: 1, gemini: 1 } },
  ]) {
    const f = fixture(settings);
    const before = f.row.total_used;
    assert.equal((await f.reserve()).reason, 'budget_exhausted');
    assert.equal(f.row.total_used, before);
    assert.equal(f.saved.length, 0);
  }
  const expired = fixture({ now: new Date('2026-10-08T00:06:00Z') });
  assert.equal((await expired.reserve()).reason, 'deadline_exceeded');
  assert.equal(expired.row.total_used, 0);
  assert.equal(expired.saved.length, 0);
});

test('OpenAI-free policies refuse OpenAI reviews before spending any quota', async () => {
  const f = fixture({ policy: 'google_gemini' });
  assert.equal((await f.reserve(0, 'openai')).reason, 'operation_not_allowed');
  assert.equal(f.row.total_used, 0);
  assert.equal(f.saved.length, 0);
});

test('a review cannot consume the first modesty call reserved for another frame', async () => {
  const f = fixture({ count: 2, used: { total: 3, gemini: 3 }, operations: [
    { id: 'base', provider: 'gemini', operation: 'modesty', status: 'completed',
      result: { available: true, decision: 'uncertain' } },
    { id: 'presence-0', provider: 'gemini', operation: 'person_presence', status: 'completed' },
    { id: 'presence-1', frame_index: 1, provider: 'gemini', operation: 'person_presence', status: 'completed' },
  ] });
  assert.equal((await f.reserve()).reason, 'budget_exhausted');
  assert.equal(f.row.gemini_used, 3);
  assert.equal(f.saved.filter(item => item.operation === review).length, 0);
});

test('reviews preserve required Gemini and OpenAI first-call floors within the global cap', async () => {
  const f = fixture({ policy: 'google_openai_gemini', count: 2,
    used: { total: 10, google_vision: 6, gemini: 1, openai: 3 },
    operations: [
      { id: 'gemini-base', provider: 'gemini', operation: 'modesty', status: 'completed' },
      { id: 'openai-base', provider: 'openai', operation: 'modesty', status: 'completed' },
    ] });
  assert.equal((await f.reserve(0, 'openai')).reason, 'budget_exhausted');
  assert.equal(f.row.total_used, 10);
});

test('a review uses spare quota after all required base modesty calls are charged', async () => {
  const f = fixture({ count: 2, used: { total: 2, gemini: 2 }, operations: [
    { id: 'base-0', provider: 'gemini', operation: 'modesty', status: 'completed' },
    { id: 'base-1', frame_index: 1, provider: 'gemini', operation: 'modesty', status: 'reserved' },
  ] });
  const reservation = await f.reserve();
  assert.equal(reservation.status, 'reserved');
  assert.equal(reservation.budget.used.gemini, 3);
});

test('schema upgrade adds the separate operation and frame uniqueness without changing counters', async () => {
  const queries = [];
  await ledger.ensureVideoScanBudgetSchema({ query: async sql => queries.push(sql) });
  assert.match(queries[0], /provider='openai' AND operation IN \([^)]*modesty_uncertainty_review/);
  assert.match(queries[0], /provider='gemini' AND operation IN \([^)]*modesty_uncertainty_review/);
  assert.match(queries[1], /pg_get_constraintdef\(oid\) NOT LIKE '%modesty_uncertainty_review%'/);
  assert.match(queries[1], /CREATE UNIQUE INDEX IF NOT EXISTS video_scan_one_uncertainty_review_per_frame/);
  assert.doesNotMatch(queries.join('\n'), /UPDATE video_scan_budgets|UPDATE video_scan_operations/);
});
