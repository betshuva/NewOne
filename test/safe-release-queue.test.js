'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');
const { createVerificationLock } = require('../server/automatic-restore-queue');

function deferred() {
  let resolve, reject;
  const promise = new Promise((done, fail) => { resolve = done; reject = fail; });
  return { promise, resolve, reject };
}

const emptyBatch = () => ({ examined: 0, released: 0, failed: 0 });
const flush = () => new Promise(resolve => setImmediate(resolve));

function fixture({ releaseBatch = async () => emptyBatch(), poolFactory } = {}) {
  const source = fs.readFileSync(path.join(__dirname, '..', 'server', 'index.js'), 'utf8');
  const start = /(?:async )?function runSafeReleaseQueue\(\)/.exec(source)?.index;
  const end = source.indexOf('async function migrateMessageBodiesAtRest()', start);
  assert.ok(start !== undefined && end > start, 'load the real safe-release queue without starting the server');
  const pool = { fake: true };
  const withDriveVerification = createVerificationLock();
  const calls = [], errors = [], activities = [], timers = [];
  let poolCalls = 0;
  const context = vm.createContext({
    getPool: async () => {
      poolCalls++;
      return poolFactory ? poolFactory(poolCalls, pool) : pool;
    },
    releaseLocalMediaBatch: async options => {
      calls.push(options);
      assert.equal(options.pool, pool);
      assert.equal(options.uploadRoot, '/fake-uploads');
      return releaseBatch(options, calls.length);
    },
    UPLOAD_ROOT: '/fake-uploads',
    withDriveVerification,
    logActivity: (...args) => { activities.push(args); },
    console: { error: (...args) => { errors.push(args); } },
    setTimeout: (callback, delay) => { timers.push({ callback, delay }); },
  });
  vm.runInContext(source.slice(start, end), context, { filename: 'safe-release-queue-from-index.js' });
  return { run: context.runSafeReleaseQueue, withDriveVerification, calls, errors, activities, timers,
    get poolCalls() { return poolCalls; } };
}

test('concurrent safe-release callers both wait for the one active batch', async t => {
  const gate = deferred();
  t.after(() => gate.resolve(emptyBatch()));
  const f = fixture({ releaseBatch: () => gate.promise });
  let firstFinished = false, secondFinished = false;
  const first = Promise.resolve(f.run()).then(() => { firstFinished = true; });
  await flush();
  const second = Promise.resolve(f.run()).then(() => { secondFinished = true; });
  await flush();
  assert.equal(f.calls.length, 1);
  assert.equal(f.poolCalls, 1);
  assert.equal(firstFinished, false);
  assert.equal(secondFinished, false, 'a restore caller must wait for a release already in progress');
  gate.resolve(emptyBatch());
  await Promise.all([first, second]);
  assert.equal(firstFinished, true);
  assert.equal(secondFinished, true);
  await f.run();
  assert.equal(f.calls.length, 2, 'a later tick can start a fresh batch after completion');
});

test('a failed shared batch settles its callers and allows the next tick to retry', async t => {
  const gate = deferred();
  t.after(() => gate.resolve(emptyBatch()));
  const f = fixture({ releaseBatch: (_options, count) => count === 1 ? gate.promise : emptyBatch() });
  const first = f.run();
  await flush();
  let waitingCallerFinished = false;
  const second = Promise.resolve(f.run()).then(() => { waitingCallerFinished = true; });
  await flush();
  assert.equal(waitingCallerFinished, false);
  gate.reject(new Error('fake download failed'));
  await Promise.all([first, second]);
  assert.equal(f.errors.length, 1, 'one failed batch emits one error despite multiple callers');
  assert.match(f.errors[0].join(' '), /fake download failed/);
  await f.run();
  assert.equal(f.calls.length, 2);
});

test('a pool failure clears the safe-release state for a later attempt', async () => {
  const f = fixture({ poolFactory: (count, pool) => {
    if (count === 1) throw new Error('fake pool unavailable');
    return pool;
  } });
  await f.run();
  assert.equal(f.calls.length, 0);
  assert.equal(f.errors.length, 1);
  await f.run();
  assert.equal(f.calls.length, 1);
  assert.equal(f.poolCalls, 2);
});

test('a completed full release batch schedules one follow-up drain for all waiting callers', async t => {
  const gate = deferred();
  t.after(() => gate.resolve(emptyBatch()));
  const f = fixture({ releaseBatch: (_options, count) => count === 1 ? gate.promise : emptyBatch() });
  const first = f.run();
  await flush();
  const second = f.run();
  gate.resolve({ examined: 10, released: 8, failed: 2 });
  await Promise.all([first, second]);
  assert.equal(f.calls.length, 1);
  assert.equal(f.timers.length, 1);
  assert.equal(f.timers[0].delay, 200);
  await f.timers[0].callback();
  assert.equal(f.calls.length, 2);
});

test('safe release retains its existing success and retention reporting callbacks', async () => {
  const f = fixture({ releaseBatch: async ({ onReleased, onError }) => {
    onReleased({ id: 'fake-file', user_id: 'fake-user' }, 123);
    onError('fake-retained-file', new Error('checksum mismatch'));
    return { examined: 2, released: 1, failed: 1 };
  } });
  await f.run();
  assert.deepEqual(JSON.parse(JSON.stringify(f.activities)), [[
    'fake-user', 'safe_local_media_release', { storedFileId: 'fake-file', bytes: 123 }, null,
  ]]);
  assert.deepEqual(f.errors, [['safe release retained:', 'fake-retained-file', 'checksum mismatch']]);
  assert.equal(f.timers.length, 0);
});

test('the shared verification lock runs only one cloud verification at a time', async t => {
  const gate = deferred();
  t.after(() => gate.resolve());
  const withVerification = createVerificationLock();
  const order = [];
  let active = 0, maximumActive = 0;
  const first = withVerification(async () => {
    active++;
    maximumActive = Math.max(maximumActive, active);
    order.push('restore started');
    await gate.promise;
    order.push('restore completed');
    active--;
    return 'restored';
  });
  await flush();
  const second = withVerification(async () => {
    active++;
    maximumActive = Math.max(maximumActive, active);
    order.push('release started');
    active--;
    return 'released';
  });
  await flush();
  assert.deepEqual(order, ['restore started']);
  assert.equal(maximumActive, 1);
  gate.resolve();
  assert.deepEqual(await Promise.all([first, second]), ['restored', 'released']);
  assert.deepEqual(order, ['restore started', 'restore completed', 'release started']);
  assert.equal(maximumActive, 1);
});

test('a failed verification releases the shared lock and preserves the next queued result', async t => {
  const gate = deferred();
  t.after(() => gate.resolve());
  const withVerification = createVerificationLock();
  const failure = new Error('fake first download timed out');
  const first = withVerification(async () => { await gate.promise; throw failure; });
  const rejected = assert.rejects(first, error => error === failure);
  let nextStarted = false;
  const second = withVerification(async () => { nextStarted = true; return 'next verified'; });
  await flush();
  assert.equal(nextStarted, false);
  gate.resolve();
  await rejected;
  assert.equal(await second, 'next verified');
  assert.equal(await withVerification(async () => 'later verified'), 'later verified');
});

test('a scheduled full-batch drain waits when restore verification holds the shared lock', async t => {
  const gate = deferred();
  t.after(() => gate.resolve());
  const f = fixture({ releaseBatch: (_options, count) =>
    count === 1 ? { examined: 10, released: 10, failed: 0 } : emptyBatch() });
  await f.run();
  assert.equal(f.timers.length, 1);
  let restoreStarted = false;
  const restore = f.withDriveVerification(async () => {
    restoreStarted = true;
    await gate.promise;
  });
  await flush();
  assert.equal(restoreStarted, true);
  let drainFinished = false;
  const drain = Promise.resolve(f.timers[0].callback()).then(() => { drainFinished = true; });
  await flush();
  assert.equal(f.calls.length, 1, 'release download must not begin during restore download');
  assert.equal(drainFinished, false);
  gate.resolve();
  await Promise.all([restore, drain]);
  assert.equal(f.calls.length, 2);
  assert.equal(drainFinished, true);
});
