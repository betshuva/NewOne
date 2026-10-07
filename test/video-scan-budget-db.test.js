'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createHash, randomUUID } = require('node:crypto');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const path = require('node:path');
const { Client, Pool } = require('pg');
const ledger = require('../server/video-scan-budget');

const dbOptions = { skip: process.env.RUN_DB_TESTS !== '1' || !process.env.VIDEO_SCAN_TEST_DATABASE_URL };
const hash = value => createHash('sha256').update(String(value)).digest('hex');
const frames = count => Array.from({ length: count }, (_, frameIndex) =>
  ({ frameIndex, sha256: hash(`frame-${frameIndex}`), timeSeconds: frameIndex * 2 }));
const success = { available: true, status: 'passed', blocked: false };
const execFileAsync = promisify(execFile);

async function fixture(t) {
  const url = new URL(process.env.VIDEO_SCAN_TEST_DATABASE_URL);
  assert.ok(['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname), 'Only a disposable local database is allowed');
  assert.match(url.pathname, /test/i, 'An explicitly named test database is required');
  const owner = new Client({ connectionString: url.href, ssl: false });
  await owner.connect();
  const schema = `video_budget_test_${randomUUID().replaceAll('-', '')}`;
  await owner.query(`CREATE SCHEMA "${schema}"`);
  const config = { connectionString: url.href, ssl: false, options: `-c search_path=${schema}`, max: 12 };
  const pool = new Pool(config), recoveredPool = new Pool(config);
  t.after(async () => {
    await pool.end();
    await recoveredPool.end();
    await owner.query(`DROP SCHEMA "${schema}" CASCADE`);
    await owner.end();
  });
  await ledger.ensureVideoScanBudgetSchema(pool);
  await ledger.ensureVideoScanBudgetSchema(pool);
  const identity = { userId: randomUUID(), contentSha256: hash(randomUUID()), scanVersion: 'test-v1',
    storedFileId: randomUUID(), providerPolicy: 'google_openai_gemini' };
  const acquire = overrides => ledger.acquireVideoScan(pool, { ...identity, ...overrides });
  const setup = async count => {
    const scan = await acquire();
    assert.equal(scan.status, 'acquired');
    const context = { scanId: scan.id, leaseToken: scan.leaseToken };
    assert.equal((await ledger.setVideoScanManifest(pool, context, frames(count))).status, 'ready');
    return context;
  };
  const reserve = (context, overrides = {}, db = pool) => ledger.reserveVideoScanOperation(db,
    { ...context, frameIndex: 0, provider: 'google_vision', operation: 'safe_search', ...overrides });
  const finish = (context, reservation, result = success, db = pool) => ledger.finishVideoScanOperation(db,
    { ...context, reservationId: reservation.reservationId, result });
  const expireLease = context => pool.query(`UPDATE video_scan_budgets SET lease_expires_at=clock_timestamp()-interval '1 second'
    WHERE id=$1`, [context.scanId]);
  return { pool, recoveredPool, config, identity, acquire, setup, reserve, finish, expireLease };
}

test('ledger rejects malformed identities and database failure never grants a reservation', async () => {
  await assert.rejects(ledger.acquireVideoScan({}, { userId: 'user', contentSha256: 'bad', scanVersion: 'v1' }), /SHA-256/);
  await assert.rejects(ledger.setVideoScanManifest({}, {}, frames(21)), /0 to 20/);
  await assert.rejects(ledger.setVideoScanManifest({}, {}, [{ sha256: hash('frame'), image: Buffer.from('image'), frameIndex: 1 }]), /contiguous/);
  await assert.rejects(ledger.getProviderSuspension({}, 'openai', 'plaintext-secret'), /SHA-256/);
  const pool = { connect: async () => { throw new Error('database down'); } };
  await assert.rejects(ledger.reserveVideoScanOperation(pool, {}), /database down/);
  await assert.rejects(ledger.acquireVideoScan({}, { userId: 'test', contentSha256: hash('video'),
    scanVersion: 'v1', providerPolicy: 'unchecked_policy' }), /Unknown video scan provider policy/);
});

test('optional OpenAI failures remain charged once while Gemini completes within original 6N cap', dbOptions, async t => {
  const f = await fixture(t);
  const acquired = await f.acquire({ providerPolicy: 'google_gemini_optional_openai' });
  const context = { scanId: acquired.id, leaseToken: acquired.leaseToken };
  const ready = await ledger.setVideoScanManifest(f.pool, context, frames(1));
  assert.deepEqual(ready.budget.limits, { total: 6, google_vision: 3, openai: 2, gemini: 2 });
  const openai = await f.reserve(context, { provider: 'openai', operation: 'person_presence' });
  const failure = { available: false, status: 'error', errorCode: 'credit_balance_exhausted' };
  assert.equal((await f.finish(context, openai, failure)).status, 'completed');
  assert.equal((await f.finish(context, openai, failure)).status, 'completed');
  const again = await f.reserve(context, { provider: 'openai', operation: 'person_presence' });
  assert.equal(again.status, 'cached');
  assert.deepEqual(again.result, failure);
  assert.equal(again.budget.used.total, 1);
  for (const [provider, operation] of [['google_vision', 'safe_search'],
    ['google_vision', 'object_localization'], ['google_vision', 'face_detection'],
    ['gemini', 'person_presence'], ['gemini', 'modesty']]) {
    const reservation = await f.reserve(context, { provider, operation });
    assert.equal(reservation.status, 'reserved');
    assert.equal((await f.finish(context, reservation)).status, 'completed');
  }
  const completed = await ledger.finishVideoScan(f.pool, context, { blocked: false });
  assert.equal(completed.status, 'completed');
  assert.deepEqual(completed.budget.used, { total: 6, google_vision: 3, openai: 1, gemini: 2 });
  assert.equal((await f.pool.query("SELECT count(*)::int AS n FROM video_scan_operations WHERE status='failed'")).rows[0].n, 1);
});

test('optional profile still stops required Gemini failure and refuses a seventh operation', dbOptions, async t => {
  const f = await fixture(t);
  for (const scenario of ['gemini_failure', 'global_cap']) {
    const acquired = await f.acquire({ contentSha256: hash(scenario), providerPolicy: 'google_gemini_optional_openai' });
    const context = { scanId: acquired.id, leaseToken: acquired.leaseToken };
    await ledger.setVideoScanManifest(f.pool, context, frames(1));
    if (scenario === 'gemini_failure') {
      const reservation = await f.reserve(context, { provider: 'gemini', operation: 'person_presence' });
      assert.equal((await f.finish(context, reservation, { available: false })).status, 'stopped');
      continue;
    }
    for (const [provider, operation] of [['google_vision', 'safe_search'],
      ['google_vision', 'object_localization'], ['google_vision', 'face_detection'],
      ['openai', 'person_presence'], ['gemini', 'person_presence'], ['gemini', 'modesty']]) {
      const reservation = await f.reserve(context, { provider, operation });
      await f.finish(context, reservation);
    }
    const extra = await f.reserve(context, { provider: 'openai', operation: 'modesty' });
    assert.equal(extra.reason, 'budget_exhausted');
    assert.equal(extra.budget.used.total, 6);
    await assert.rejects(f.pool.query('UPDATE video_scan_budgets SET total_used=7,openai_used=2 WHERE id=$1',
      [context.scanId]), { code: '23514' });
  }
});

test('optional profile reuses confirmed OpenAI failures after restart without resetting budget or deadline', dbOptions, async t => {
  const f = await fixture(t);
  const acquired = await f.acquire({ providerPolicy: 'google_gemini_optional_openai' });
  const context = { scanId: acquired.id, leaseToken: acquired.leaseToken };
  await ledger.setVideoScanManifest(f.pool, context, frames(1));
  const reserved = await f.reserve(context, { provider: 'openai', operation: 'modesty' });
  await f.finish(context, reserved, { available: false, status: 'timeout' });
  await f.expireLease(context);
  const recovered = await f.acquire({ providerPolicy: 'google_gemini_optional_openai' });
  assert.equal(recovered.status, 'acquired');
  assert.equal(recovered.budget.used.total, 1);
  assert.equal(+new Date(recovered.budget.deadlineAt), +new Date(acquired.budget.deadlineAt));
  const repeat = await f.reserve({ scanId: recovered.id, leaseToken: recovered.leaseToken },
    { provider: 'openai', operation: 'modesty' });
  assert.equal(repeat.status, 'cached');
  assert.equal(repeat.result.available, false);
});

test('zero-request OpenAI preflight stop may transition once to the optional policy without clearing suspension', dbOptions, async t => {
  const f = await fixture(t), old = await f.acquire();
  await ledger.stopVideoScan(f.pool, { scanId: old.id, leaseToken: old.leaseToken }, 'credit_balance_exhausted');
  await ledger.suspendProvider(f.pool, { provider: 'openai', credentialHash: hash('test-key') });
  const fresh = await f.acquire({ providerPolicy: 'google_gemini_optional_openai', scanVersion: 'optional-v1' });
  assert.equal(fresh.status, 'acquired');
  assert.equal(fresh.id, old.id);
  assert.equal(fresh.budget.used.total, 0);
  assert.equal(fresh.budget.providerPolicy, 'google_gemini_optional_openai');
  assert.ok(await ledger.getProviderSuspension(f.pool, 'openai', hash('test-key')));
});

test('OpenAI-free policy freezes exactly 5N calls with two distinct Gemini operations per frame', dbOptions, async t => {
  const f = await fixture(t);
  const acquired = await f.acquire({ providerPolicy: 'google_gemini' });
  const context = { scanId: acquired.id, leaseToken: acquired.leaseToken };
  const ready = await ledger.setVideoScanManifest(f.pool, context, frames(2));
  assert.equal(ready.budget.providerPolicy, 'google_gemini');
  assert.deepEqual(ready.budget.limits, { total: 10, google_vision: 6, openai: 0, gemini: 4 });
  const calls = [];
  for (const frameIndex of [0, 1]) {
    for (const [provider, operations] of Object.entries(ledger.VIDEO_SCAN_PROVIDER_POLICIES.google_gemini.operations)) {
      for (const operation of operations) calls.push({ frameIndex, provider, operation });
    }
  }
  assert.equal(calls.length, 10);
  const reservations = await Promise.all(calls.map(call => f.reserve(context, call)));
  assert.ok(reservations.every(result => result.status === 'reserved'));
  assert.equal(Math.max(...reservations.map(result => result.budget.used.total)), 10);
  await Promise.all(reservations.map(reservation => f.finish(context, reservation)));
  assert.equal((await f.reserve(context, { provider: 'gemini', operation: 'person_presence' })).status, 'cached');
  const finished = await ledger.finishVideoScan(f.pool, context, { approved: true });
  assert.equal(finished.status, 'completed');
  assert.deepEqual(finished.budget.used, finished.budget.limits);
  assert.equal((await f.acquire({ providerPolicy: 'google_gemini' })).status, 'completed');
  const changedBack = await f.acquire();
  assert.equal(changedBack.reason, 'scan_version_changed');
  assert.equal(changedBack.budget.used.total, 10);
});

test('provider policies reject disallowed operations in both the ledger and database', dbOptions, async t => {
  const f = await fixture(t);
  for (const [providerPolicy, provider, operation] of [
    ['google_gemini', 'openai', 'modesty'],
    ['google_openai_gemini', 'gemini', 'person_presence'],
  ]) {
    const acquired = await f.acquire({ contentSha256: hash(providerPolicy), providerPolicy });
    const context = { scanId: acquired.id, leaseToken: acquired.leaseToken };
    await ledger.setVideoScanManifest(f.pool, context, frames(1));
    await assert.rejects(f.pool.query(`INSERT INTO video_scan_operations
      (id,scan_id,frame_index,provider,operation,status,lease_token) VALUES($1,$2,0,$3,$4,'reserved',$5)`,
    [randomUUID(), acquired.id, provider, operation, acquired.leaseToken]), { code: '23514' });
    const refused = await f.reserve(context, { provider, operation });
    assert.equal(refused.reason, 'operation_not_allowed');
    assert.equal(refused.budget.used.total, 0);
  }
});

test('only an unstarted zero-cost credit stop can migrate once to the OpenAI-free policy', dbOptions, async t => {
  const f = await fixture(t), old = await f.acquire();
  const oldContext = { scanId: old.id, leaseToken: old.leaseToken };
  await ledger.stopVideoScan(f.pool, oldContext, 'credit_balance_exhausted');
  await f.pool.query("UPDATE video_scan_budgets SET deadline_at=clock_timestamp()-interval '1 day' WHERE id=$1", [old.id]);
  const legacy = await f.acquire({ providerPolicy: 'google_gemini', legacyUnsafe: true, scanVersion: 'new-policy-v1' });
  assert.equal(legacy.status, 'stopped');
  const reacquisitions = await Promise.all(Array.from({ length: 8 }, () =>
    f.acquire({ providerPolicy: 'google_gemini', scanVersion: 'new-policy-v1', storedFileId: randomUUID() })));
  assert.equal(reacquisitions.filter(result => result.status === 'acquired').length, 1);
  assert.equal(reacquisitions.filter(result => result.status === 'busy').length, 7);
  const resumed = reacquisitions.find(result => result.status === 'acquired');
  assert.equal(resumed.id, old.id);
  assert.notEqual(resumed.leaseToken, old.leaseToken);
  assert.equal(resumed.budget.providerPolicy, 'google_gemini');
  assert.equal(resumed.budget.scanVersion, 'new-policy-v1');
  assert.equal(resumed.budget.frameCount, null);
  assert.deepEqual(resumed.budget.used, { total: 0, google_vision: 0, openai: 0, gemini: 0 });
  assert.equal(+resumed.budget.deadlineAt - +resumed.budget.startedAt, ledger.VIDEO_SCAN_DEADLINE_MS);
  const stored = (await f.pool.query('SELECT * FROM video_scan_budgets WHERE id=$1', [old.id])).rows[0];
  assert.equal(stored.policy_history.length, 1);
  assert.equal(stored.policy_history[0].providerPolicy, 'google_openai_gemini');
  assert.equal(stored.policy_history[0].reason, 'credit_balance_exhausted');
  assert.equal(stored.result, null);
  const newContext = { scanId: resumed.id, leaseToken: resumed.leaseToken };
  assert.equal((await ledger.stopVideoScan(f.pool, oldContext, 'stale_worker')).status, 'busy');
  await ledger.stopVideoScan(f.pool, newContext, 'credit_balance_exhausted');
  assert.equal((await f.acquire({ providerPolicy: 'google_gemini', scanVersion: 'new-policy-v1' })).status, 'stopped');
});

test('policy switches never reopen sampled, spent, unknown, or differently stopped videos', dbOptions, async t => {
  const f = await fixture(t);
  for (const scenario of ['sampled', 'spent', 'operation_record', 'legacy', 'deadline', 'active_spent']) {
    const identity = { contentSha256: hash(scenario) };
    const acquired = await f.acquire(identity), context = { scanId: acquired.id, leaseToken: acquired.leaseToken };
    if (['sampled', 'spent', 'active_spent'].includes(scenario))
      await ledger.setVideoScanManifest(f.pool, context, frames(1));
    if (['spent', 'active_spent'].includes(scenario)) {
      const reservation = await f.reserve(context);
      await f.finish(context, reservation);
    }
    if (scenario === 'operation_record') await f.pool.query(`INSERT INTO video_scan_operations
      (id,scan_id,frame_index,provider,operation,status,lease_token) VALUES($1,$2,0,'google_vision','safe_search','failed',$3)`,
    [randomUUID(), acquired.id, acquired.leaseToken]);
    if (scenario === 'active_spent') await f.expireLease(context);
    else await ledger.stopVideoScan(f.pool, context,
      scenario === 'legacy' ? 'legacy_budget_unknown' : scenario === 'deadline' ? 'deadline_exceeded' : 'credit_balance_exhausted');
    const before = await ledger.getVideoScanBudget(f.pool, context);
    const refused = await f.acquire({ ...identity, providerPolicy: 'google_gemini', scanVersion: 'new-policy-v1' });
    assert.equal(refused.status, 'stopped', scenario);
    assert.equal(refused.id, acquired.id, scenario);
    assert.equal(refused.budget.providerPolicy, 'google_openai_gemini', scenario);
    assert.deepEqual(refused.budget.used, before.budget.used, scenario);
    assert.equal(+refused.budget.deadlineAt, +before.budget.deadlineAt, scenario);
    assert.deepEqual((await f.pool.query('SELECT policy_history FROM video_scan_budgets WHERE id=$1', [acquired.id])).rows[0].policy_history, []);
  }
});

test('schema migration preserves old-policy consumed counters and replaces only policy-sensitive checks', dbOptions, async t => {
  const f = await fixture(t), context = await f.setup(1);
  const reservation = await f.reserve(context);
  await f.finish(context, reservation);
  const before = await ledger.getVideoScanBudget(f.pool, context);
  await f.pool.query(`DROP TRIGGER video_scan_operation_policy ON video_scan_operations;
    ALTER TABLE video_scan_budgets DROP CONSTRAINT video_scan_budget_policy_check,
      DROP CONSTRAINT video_scan_budget_policy_caps,DROP COLUMN provider_policy,DROP COLUMN policy_history;
    ALTER TABLE video_scan_budgets ADD CHECK (frame_count IS NULL OR (total_used <= 6 * frame_count
      AND google_vision_used <= 3 * frame_count AND openai_used <= 2 * frame_count AND gemini_used <= frame_count));
    ALTER TABLE video_scan_operations DROP CONSTRAINT video_scan_operation_kind_check;
    ALTER TABLE video_scan_operations ADD CHECK ((provider='google_vision' AND operation IN ('safe_search','object_localization','face_detection'))
      OR (provider='openai' AND operation IN ('person_presence','modesty')) OR (provider='gemini' AND operation='modesty'));`);
  await ledger.ensureVideoScanBudgetSchema(f.pool);
  await ledger.ensureVideoScanBudgetSchema(f.pool);
  const after = await ledger.getVideoScanBudget(f.pool, context);
  assert.deepEqual(after, before);
  assert.equal((await f.pool.query('SELECT count(*) FROM video_scan_operations')).rows[0].count, '1');
  assert.equal((await f.reserve(context, { provider: 'openai', operation: 'modesty' })).status, 'reserved');
  const newScan = await f.acquire({ contentSha256: hash('new-profile-after-migration'), providerPolicy: 'google_gemini' });
  const newContext = { scanId: newScan.id, leaseToken: newScan.leaseToken };
  await ledger.setVideoScanManifest(f.pool, newContext, frames(1));
  assert.equal((await f.reserve(newContext, { provider: 'gemini', operation: 'person_presence' })).status, 'reserved');
  assert.equal((await f.reserve(newContext, { provider: 'gemini', operation: 'modesty' })).status, 'reserved');
  await assert.rejects(f.pool.query('UPDATE video_scan_budgets SET total_used=total_used+1,openai_used=openai_used+1 WHERE id=$1', [newScan.id]), { code: '23514' });
  await assert.rejects(f.pool.query('UPDATE video_scan_budgets SET total_used=100 WHERE id=$1', [context.scanId]), { code: '23514' });
});

test('concurrent duplicate acquisition shares one canonical identity without relying on a stored file', dbOptions, async t => {
  const f = await fixture(t);
  const results = await Promise.all(Array.from({ length: 24 }, (_, index) => f.acquire({ storedFileId: index % 2 ? null : randomUUID() })));
  assert.equal(results.filter(result => result.status === 'acquired').length, 1);
  assert.equal(results.filter(result => result.status === 'busy').length, 23);
  assert.equal(new Set(results.map(result => result.id)).size, 1);
  assert.equal(results[0].budget.frameCount, null);
  assert.equal(results[0].budget.limits, null);
  assert.equal((await f.acquire({ legacyUnsafe: true })).status, 'busy');
  assert.equal((await f.acquire({ scanVersion: 'new-version', storedFileId: null })).id, results[0].id);
  assert.equal((await f.acquire({ userId: randomUUID() })).status, 'acquired');
  const rows = await f.pool.query('SELECT * FROM video_scan_budgets');
  assert.equal(rows.rowCount, 2);
  assert.equal(rows.rows[0].deadline_at - rows.rows[0].started_at, ledger.VIDEO_SCAN_DEADLINE_MS);
});

test('manifest freezes count and frame hashes and excludes paths and image bytes', dbOptions, async t => {
  const f = await fixture(t), context = await f.setup(2);
  const initial = await ledger.getVideoScanBudget(f.pool, context);
  const same = await ledger.setVideoScanManifest(f.pool, context,
    frames(2).map(frame => ({ ...frame, path: '/private/file.jpg', bytes: Buffer.from('not persisted') })));
  assert.equal(same.status, 'ready');
  assert.equal(same.budget.manifestHash, initial.budget.manifestHash);
  assert.equal(JSON.stringify(same.budget.manifest).includes('private'), false);
  assert.deepEqual(same.budget.limits, { total: 12, google_vision: 6, openai: 4, gemini: 2 });
  const changed = frames(2);
  changed[1].sha256 = hash('changed');
  assert.equal((await ledger.setVideoScanManifest(f.pool, context, changed)).reason, 'frame_manifest_changed');
  assert.equal((await f.reserve(context)).status, 'stopped');
  assert.equal((await f.acquire({ storedFileId: randomUUID(), scanVersion: 'test-v2' })).reason, 'frame_manifest_changed');
});

test('zero frames has zero quota and a missing manifest cannot reserve', dbOptions, async t => {
  const f = await fixture(t), context = await f.setup(0);
  assert.equal((await ledger.getVideoScanBudget(f.pool, context)).budget.limits.total, 0);
  assert.equal((await f.reserve(context)).reason, 'frame_index_invalid');
  const scan = await f.acquire({ contentSha256: hash('other-video') });
  assert.equal((await f.reserve({ scanId: scan.id, leaseToken: scan.leaseToken })).reason, 'frame_manifest_missing');
});

test('concurrent reservations charge once and only successful results become reusable', dbOptions, async t => {
  const f = await fixture(t), context = await f.setup(3);
  const attempts = await Promise.all(Array.from({ length: 24 }, () => f.reserve(context)));
  assert.equal(attempts.filter(result => result.status === 'reserved').length, 1);
  assert.equal(attempts.filter(result => result.status === 'busy').length, 23);
  const operation = attempts.find(result => result.status === 'reserved');
  assert.equal((await f.finish(context, operation)).status, 'completed');
  const cached = await f.reserve(context);
  assert.equal(cached.status, 'cached');
  assert.deepEqual(cached.result, success);
  assert.equal(cached.budget.used.total, 1);
  assert.equal((await f.pool.query('SELECT count(*) FROM video_scan_operations')).rows[0].count, '1');
});

test('all provider caps permit the exact final allowed call and completion remains valid at 6N', dbOptions, async t => {
  const f = await fixture(t), context = await f.setup(3);
  const calls = [];
  for (let frameIndex = 0; frameIndex < 3; frameIndex++) {
    for (const [provider, operations] of Object.entries(ledger.PROVIDER_OPERATIONS)) {
      for (const operation of operations) calls.push({ frameIndex, provider, operation });
    }
  }
  const reservations = await Promise.all(calls.map(call => f.reserve(context, call)));
  assert.ok(reservations.every(result => result.status === 'reserved'));
  assert.equal(Math.max(...reservations.map(result => result.budget.used.total)), 18);
  const completions = await Promise.all(reservations.map(operation => f.finish(context, operation)));
  assert.ok(completions.every(result => result.status === 'completed'));
  const atCap = await ledger.getVideoScanBudget(f.pool, context);
  assert.deepEqual(atCap.budget.used, { total: 18, google_vision: 9, openai: 6, gemini: 3 });
  assert.equal((await f.reserve(context, calls.at(-1))).status, 'cached');
  const result = { approved: true, detectedCategories: ['video'] };
  assert.equal((await ledger.finishVideoScan(f.pool, context, result)).status, 'completed');
  const reused = await f.acquire({ storedFileId: null, legacyUnsafe: true });
  assert.equal(reused.status, 'completed');
  assert.deepEqual(reused.result, result);
  assert.equal(reused.budget.used.total, 18);
  assert.equal(reused.id, context.scanId);
  const policyChanged = await f.acquire({ scanVersion: 'v2' });
  assert.equal(policyChanged.status, 'stopped');
  assert.equal(policyChanged.reason, 'scan_version_changed');
  assert.equal(policyChanged.budget.used.total, 18);
});

test('provider caps are checked atomically before reservation independently of total capacity', dbOptions, async t => {
  const f = await fixture(t);
  for (const [provider, max] of [['google_vision', 3], ['openai', 2], ['gemini', 1]]) {
    const scan = await f.acquire({ contentSha256: hash(provider) });
    const context = { scanId: scan.id, leaseToken: scan.leaseToken };
    await ledger.setVideoScanManifest(f.pool, context, frames(1));
    await f.pool.query(`UPDATE video_scan_budgets SET total_used=$2,${provider}_used=$2 WHERE id=$1`, [scan.id, max]);
    const result = await f.reserve(context, { provider, operation: ledger.PROVIDER_OPERATIONS[provider][0] });
    assert.equal(result.reason, 'budget_exhausted');
    assert.equal(result.budget.used.total, max);
  }
  assert.equal((await f.pool.query('SELECT count(*) FROM video_scan_operations')).rows[0].count, '0');
});

test('fresh process and pool recover only completed work and never reset deadline or counters', dbOptions, async t => {
  const f = await fixture(t), context = await f.setup(2);
  const reservation = await f.reserve(context);
  await f.finish(context, reservation);
  const before = await ledger.getVideoScanBudget(f.pool, context);
  await f.expireLease(context);
  const childSource = `const {Pool}=require('pg');
    const {acquireVideoScan}=require('./server/video-scan-budget');
    const pool=new Pool(JSON.parse(process.argv[1]));
    acquireVideoScan(pool,JSON.parse(process.argv[2]))
      .then(result=>process.stdout.write(JSON.stringify(result)))
      .finally(()=>pool.end()).catch(error=>{console.error(error);process.exitCode=1;});`;
  const child = await execFileAsync(process.execPath, ['-e', childSource, JSON.stringify(f.config),
    JSON.stringify({ ...f.identity, storedFileId: randomUUID(), legacyUnsafe: true })],
  { cwd: path.join(__dirname, '..'), timeout: 10000 });
  const restart = JSON.parse(child.stdout);
  assert.equal(restart.status, 'acquired');
  assert.notEqual(restart.leaseToken, context.leaseToken);
  assert.equal(restart.id, context.scanId);
  assert.equal(+new Date(restart.budget.deadlineAt), +before.budget.deadlineAt);
  assert.equal(restart.budget.used.total, 1);
  const nextContext = { scanId: restart.id, leaseToken: restart.leaseToken };
  assert.equal((await f.reserve(nextContext, {}, f.recoveredPool)).status, 'cached');
  assert.equal((await f.reserve(context, { frameIndex: 1 })).reason, 'lease_lost');
  assert.equal((await ledger.renewVideoScanLease(f.pool, context)).reason, 'lease_lost');
  assert.equal((await ledger.renewVideoScanLease(f.recoveredPool, nextContext)).status, 'renewed');
});

test('unknown in-flight requests stop recovery and retain their consumed quota forever', dbOptions, async t => {
  const f = await fixture(t), context = await f.setup(1);
  const reservation = await f.reserve(context);
  await f.expireLease(context);
  const recovered = await ledger.acquireVideoScan(f.recoveredPool, f.identity);
  assert.equal(recovered.reason, 'operation_outcome_unknown');
  assert.equal(recovered.status, 'stopped');
  assert.equal(recovered.result.available, false);
  assert.equal(recovered.result.videoScanStopped, true);
  assert.equal((await f.finish(context, reservation)).status, 'stopped');
  assert.equal((await f.acquire({ scanVersion: 'v100', storedFileId: randomUUID() })).status, 'stopped');
  assert.equal((await ledger.getVideoScanBudget(f.pool, context)).budget.used.total, 1);
});

test('provider unavailability is terminal, bounded, cached as failure, and never refundable', dbOptions, async t => {
  const f = await fixture(t), context = await f.setup(1);
  const reservation = await f.reserve(context);
  const result = await f.finish(context, reservation, { available: false, status: 'timeout', reason: 'timeout' });
  assert.equal(result.status, 'stopped');
  assert.equal(result.reason, 'required_provider_unavailable');
  assert.equal((await f.reserve(context)).status, 'stopped');
  assert.equal((await ledger.finishVideoScan(f.pool, context, { approved: true })).status, 'stopped');
  assert.equal((await f.acquire({ contentSha256: f.identity.contentSha256, storedFileId: null })).budget.used.total, 1);
  const operation = (await f.pool.query('SELECT * FROM video_scan_operations')).rows[0];
  assert.equal(operation.status, 'failed');
  assert.equal(operation.result.status, 'timeout');
  await assert.rejects(ledger.finishVideoScanOperation(f.pool, { ...context, reservationId: reservation.reservationId,
    result: { available: true, text: 'x'.repeat(256 * 1024) } }), /too large/);
});

test('deadline is fixed from initial acquisition and completion after it cannot approve', dbOptions, async t => {
  const f = await fixture(t), context = await f.setup(1);
  const reservation = await f.reserve(context);
  await f.pool.query(`UPDATE video_scan_budgets SET deadline_at=clock_timestamp()-interval '1 second' WHERE id=$1`, [context.scanId]);
  const result = await f.finish(context, reservation);
  assert.equal(result.reason, 'deadline_exceeded');
  assert.equal((await f.acquire({ storedFileId: randomUUID() })).reason, 'deadline_exceeded');
  assert.equal((await ledger.renewVideoScanLease(f.pool, context)).status, 'stopped');
  assert.equal((await f.reserve(context, { operation: 'face_detection' })).status, 'stopped');
  assert.equal(result.budget.used.total, 1);
  assert.equal((await f.pool.query('SELECT status FROM video_scan_operations')).rows[0].status, 'completed');
});

test('deadline is re-read after row lock contention before allowing a provider call', dbOptions, async t => {
  const f = await fixture(t), context = await f.setup(1);
  const blocker = await f.pool.connect();
  try {
    await blocker.query('BEGIN');
    await blocker.query('SELECT id FROM video_scan_budgets WHERE id=$1 FOR UPDATE', [context.scanId]);
    const pending = f.reserve(context, {}, f.recoveredPool);
    await blocker.query(`UPDATE video_scan_budgets SET deadline_at=clock_timestamp()-interval '1 second' WHERE id=$1`, [context.scanId]);
    await blocker.query('COMMIT');
    assert.equal((await pending).reason, 'deadline_exceeded');
    assert.equal((await f.pool.query('SELECT count(*) FROM video_scan_operations')).rows[0].count, '0');
  } finally { await blocker.query('ROLLBACK'); blocker.release(); }
});

test('a deadline crossed inside the reservation transaction cannot grant or charge a call', dbOptions, async t => {
  const f = await fixture(t), context = await f.setup(1);
  const intercepted = { connect: async () => {
    const db = await f.pool.connect();
    return {
      query: async (sql, values) => {
        if (/SET total_used=total_used\+1/.test(sql))
          await db.query(`UPDATE video_scan_budgets SET deadline_at=clock_timestamp()-interval '1 second' WHERE id=$1`, [context.scanId]);
        return db.query(sql, values);
      },
      release: () => db.release(),
    };
  } };
  const result = await f.reserve(context, {}, intercepted);
  assert.equal(result.reason, 'deadline_exceeded');
  assert.equal(result.budget.used.total, 0);
  assert.equal((await f.pool.query('SELECT count(*) FROM video_scan_operations')).rows[0].count, '0');
});

test('whole-scan summaries support more than 256 KiB while retaining a separate result bound', dbOptions, async t => {
  const f = await fixture(t), context = await f.setup(20);
  const result = { blocked: true, frameResults: frames(20).map(frame => ({ ...frame, diagnostics: 'x'.repeat(16384) })) };
  assert.ok(Buffer.byteLength(JSON.stringify(result)) > 256 * 1024);
  const completed = await ledger.finishVideoScan(f.pool, context, result);
  assert.equal(completed.status, 'completed');
  assert.equal(completed.result.frameResults.length, 20);
  await assert.rejects(ledger.finishVideoScan(f.pool, context, { text: 'x'.repeat(2 * 1024 * 1024) }), /too large/);
});

test('invalid operations, legacy unknown usage, and changed scan versions cannot reset the quota', dbOptions, async t => {
  const f = await fixture(t), context = await f.setup(1);
  assert.equal((await f.reserve(context, { provider: 'google_vision', operation: 'retry' })).reason, 'operation_not_allowed');
  const legacy = await f.acquire({ contentSha256: hash('legacy'), legacyUnsafe: true });
  assert.equal(legacy.reason, 'legacy_budget_unknown');
  assert.equal((await f.acquire({ contentSha256: hash('legacy'), legacyUnsafe: false })).status, 'stopped');
  const scan = await f.acquire({ contentSha256: hash('version-change') });
  await f.expireLease({ scanId: scan.id });
  const changed = await f.acquire({ contentSha256: hash('version-change'), scanVersion: 'v2' });
  assert.equal(changed.reason, 'scan_version_changed');
  assert.equal(changed.id, scan.id);
});

test('credit exhaustion suspension persists across pools and only explicit clearance resets it', dbOptions, async t => {
  const f = await fixture(t), credentialHash = hash('synthetic test credential');
  assert.equal(await ledger.getProviderSuspension(f.pool, 'openai', credentialHash), null);
  const first = await ledger.suspendProvider(f.pool, { provider: 'openai', credentialHash });
  assert.equal(first.reason, 'credit_balance_exhausted');
  const repeated = await ledger.suspendProvider(f.recoveredPool, { provider: 'openai', credentialHash });
  assert.equal(+first.suspendedAt, +repeated.suspendedAt);
  assert.equal((await ledger.getProviderSuspension(f.recoveredPool, 'openai', credentialHash)).reason, 'credit_balance_exhausted');
  assert.equal(await ledger.getProviderSuspension(f.pool, 'openai', hash('another credential')), null);
  await assert.rejects(ledger.clearProviderSuspension(f.pool, { provider: 'openai', credentialHash }), /confirmation/);
  await ledger.clearProviderSuspension(f.pool, { provider: 'openai', credentialHash, actorId: f.identity.userId, confirmed: true });
  assert.equal(await ledger.getProviderSuspension(f.recoveredPool, 'openai', credentialHash), null);
  const context = await f.setup(1), reservation = await f.reserve(context);
  assert.equal((await f.finish(context, reservation, { available: false, errorCode: 'credit_balance_exhausted' })).reason, 'credit_balance_exhausted');
});

test('administrative clearance and audit records commit or roll back together in PostgreSQL', dbOptions, async t => {
  const f = await fixture(t);
  const { ensureSystemAuditSchema, beginOperation } = require('../server/system-audit');
  const { executeClearCommand } = require('../scripts/clear-moderation-provider-suspension');
  await f.pool.query(`CREATE TABLE users(id uuid PRIMARY KEY,name text,short_id integer);
    CREATE TABLE admin_permissions(user_id uuid PRIMARY KEY REFERENCES users(id),permission text);`);
  await f.pool.query('INSERT INTO users VALUES($1,$2,1)', [f.identity.userId, 'Test Administrator']);
  await f.pool.query("INSERT INTO admin_permissions VALUES($1,'edit')", [f.identity.userId]);
  await ensureSystemAuditSchema(f.pool);
  const apiKey = 'synthetic-test-credential', credentialHash = hash(apiKey);
  const options = { provider: 'openai', actor: f.identity.userId, reason: 'credits_restored', confirmed: false };
  await ledger.suspendProvider(f.pool, { provider: 'openai', credentialHash });
  assert.equal((await executeClearCommand({ pool: f.pool, options, apiKey })).status, 'suspended');
  assert.equal((await f.pool.query('SELECT count(*) FROM audit_operations')).rows[0].count, '0');
  options.confirmed = true;
  const cleared = await executeClearCommand({ pool: f.pool, options, apiKey });
  assert.equal(cleared.status, 'cleared');
  assert.equal(await ledger.getProviderSuspension(f.pool, 'openai', credentialHash), null);
  const audit = (await f.pool.query('SELECT * FROM audit_operations WHERE id=$1', [cleared.auditOperationId])).rows[0];
  assert.equal(audit.status, 'completed');
  assert.equal(audit.reason_code, 'credits_restored');
  assert.equal(audit.initiator_id, f.identity.userId);
  const events = (await f.pool.query('SELECT * FROM audit_events WHERE operation_id=$1 ORDER BY id', [audit.id])).rows;
  assert.equal(events.length, 2);
  assert.equal(events[1].kind, 'provider_suspension_cleared');
  assert.equal(events[1].details.provider, 'openai');
  assert.equal(events[1].details.affectedCount, 1);
  await ledger.suspendProvider(f.pool, { provider: 'openai', credentialHash });
  await assert.rejects(executeClearCommand({ pool: f.pool, options, apiKey,
    audit: { beginOperation, recordAuditEvent: async () => { throw new Error('synthetic audit failure'); } },
  }), /synthetic audit failure/);
  assert.equal((await ledger.getProviderSuspension(f.pool, 'openai', credentialHash)).reason, 'credit_balance_exhausted');
  assert.equal((await f.pool.query('SELECT count(*) FROM audit_operations')).rows[0].count, '1');
});
