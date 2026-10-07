'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const { freezeVideoFrames, publicBudget, runBoundedVideoScan,
  stoppedVideoResult, videoProviderStop } = require('../server/video-scan-controller');
const { credentialHash } = require('../server/moderation-provider-guard');

const source = Buffer.from('controller test video bytes');
const tracking = { userId: 'test-user', storedFileId: 'test-file', workflow: 'retry', attempt: 3 };
const context = { scanId: 'test-scan', leaseToken: 'test-lease' };
const samples = [0, 1].map(index => ({ timestamp_seconds: index * 0.5,
  jpeg_base64: Buffer.alloc(40, index + 1).toString('base64') }));
const approved = { blocked: false, pending: false,
  classification: { category: 'video', uncertain: false } };

function fixture(overrides = {}, budgetOverrides = {}) {
  const calls = [];
  const budget = { frameCount: 2,
    limits: { total: 12, google_vision: 6, openai: 4, gemini: 2 },
    used: { total: 0, google_vision: 0, openai: 0, gemini: 0 },
    startedAt: new Date().toISOString(), deadlineAt: new Date(Date.now() + 60000).toISOString(),
    scanVersion: 'test-v1', providerPolicy: 'google_openai_gemini', manifest: [{ sha256: 'private-frame-hash' }],
    manifestHash: 'private-manifest-hash', leaseExpiresAt: 'private-lease',
    ...budgetOverrides };
  const pool = { query() { throw new Error('Unexpected database access'); },
    connect() { throw new Error('Unexpected database connection'); } };
  const defaults = {
    acquireVideoScan: async () => ({ status: 'acquired', id: context.scanId,
      leaseToken: context.leaseToken, budget }),
    getProviderSuspension: async () => null,
    setVideoScanManifest: async () => ({ status: 'ready', budget }),
    renewVideoScanLease: async () => ({ status: 'renewed', budget }),
    stopVideoScan: async (_pool, _context, reason, result) => ({ status: 'stopped', reason, result, budget }),
    finishVideoScan: async (_pool, _context, result) => ({ status: 'completed', result, budget }),
  };
  const ledger = Object.fromEntries(Object.entries(defaults).map(([method, fallback]) => [
    method, async (...args) => {
      assert.equal(args[0], pool);
      calls.push({ method, args: args.slice(1) });
      return (overrides[method] || fallback)(...args);
    },
  ]));
  const run = (scan, options = {}) => runBoundedVideoScan(source, 'test.mp4', 'video/mp4', {
    pool, ledger, scan, tracking, scanVersion: 'test-v1', openaiKey: 'test-only-key', ...options,
  });
  const callsFor = method => calls.filter(call => call.method === method);
  return { pool, ledger, budget, calls, callsFor, run };
}

function assertStopped(result, reason) {
  assert.equal(result.scanStopped, true);
  assert.equal(result.stopped, true);
  assert.equal(result.pending, false);
  assert.equal(result.blocked, false);
  assert.equal(result.retryable, false);
  assert.equal(result.reasonCode, reason);
  assert.equal(result.classification.category, 'video');
  assert.equal(result.classification.uncertain, true);
}

test('completed, busy and stopped acquisitions do not start the scanner', async () => {
  for (const status of ['completed', 'busy', 'stopped']) {
    const f = fixture({ acquireVideoScan: async () => ({ status,
      reason: 'budget_exhausted', result: approved, budget: f.budget }) });
    const result = await f.run(() => assert.fail('Scanner must not run'));
    assert.deepEqual(f.calls.map(call => call.method), ['acquireVideoScan']);
    if (status === 'completed') {
      assert.equal(result.cacheHit, true);
      assert.equal(result.pending, false);
      assert.deepEqual(result.classification, approved.classification);
    } else if (status === 'busy') {
      assert.equal(result.pending, true);
      assert.equal(result.blocked, false);
      assert.equal(result.scanStopped, undefined);
    } else assertStopped(result, 'budget_exhausted');
    assert.deepEqual(result.budget, publicBudget(f.budget));
  }
});

test('acquired scans freeze actual frames and pass the lease and shared abort signal', async () => {
  const f = fixture();
  let scanOptions;
  const result = await f.run(async (buffer, fileName, mimeType, options) => {
    assert.equal(buffer, source);
    assert.equal(fileName, 'test.mp4');
    assert.equal(mimeType, 'video/mp4');
    scanOptions = options;
    assert.deepEqual(options.tracking, { ...tracking,
      videoBudget: { ...context, signal: options.signal } });
    assert.equal(options.signal.aborted, false);
    assert.equal(await options.freezeFrames(samples, 2), null);
    return approved;
  });
  assert.equal(result.pending, false);
  assert.equal(scanOptions.signal.aborted, true);
  assert.deepEqual(f.calls.map(call => call.method), ['acquireVideoScan',
    'getProviderSuspension', 'setVideoScanManifest', 'finishVideoScan']);
  assert.deepEqual(f.callsFor('setVideoScanManifest')[0].args, [context,
    samples.map((sample, frameIndex) => ({ frameIndex, timeSeconds: sample.timestamp_seconds,
      sha256: createHash('sha256').update(Buffer.from(sample.jpeg_base64, 'base64')).digest('hex') }))]);
});

test('cached stopped result links retained evidence without running any scanner or changing the result', async () => {
  const saved={status:'stopped',reason:'scan_incomplete',result:{frameResults:[{pending:true,timestampSeconds:4}]}};
  const f=fixture({acquireVideoScan:async()=>({...saved,budget:f.budget})});
  let linked=0;
  const result=await f.run(()=>assert.fail('No new scan allowed'),{
    attachCachedPreview:async state=>{assert.equal(state.result,saved.result);linked++;},
  });
  assert.equal(linked,1);
  assertStopped(result,'scan_incomplete');
  assert.deepEqual(result.frameResults,saved.result.frameResults);
  assert.deepEqual(f.calls.map(c=>c.method),['acquireVideoScan']);
  const unavailable=await f.run(()=>assert.fail('No scan fallback'),{
    attachCachedPreview:async()=>{throw Error('Preview unavailable');},
  });
  assertStopped(unavailable,'scan_incomplete');
});

test('frame validation rejects mismatched counts and invalid samples before ledger or paid work', async () => {
  const invalid = [[null, 0], [[], 0], [samples, 1], [samples, 2.5],
    [Array.from({ length: 21 }, () => samples[0]), 21],
    [[{ ...samples[0], jpeg_base64: 'short' }], 1],
    [[{ ...samples[0], timestamp_seconds: -1 }], 1],
    [[{ ...samples[0], timestamp_seconds: 'invalid' }], 1]];
  for (const [frames, count] of invalid) {
    const f = fixture();
    await assert.rejects(freezeVideoFrames(f.pool, context, frames, count, f.ledger),
      /invalid_frame_manifest/);
    assert.equal(f.calls.length, 0);
  }
  const f = fixture();
  let paidSteps = 0;
  const result = await f.run(async (_buffer, _name, _mime, options) => {
    await options.freezeFrames(samples, 1);
    paidSteps += 1;
    return approved;
  });
  assert.equal(paidSteps, 0);
  assert.equal(f.callsFor('setVideoScanManifest').length, 0);
  assert.equal(f.callsFor('finishVideoScan').length, 0);
  assertStopped(result, 'provider_guard_unavailable');
});

test('a changed persisted manifest stops before the scanner continues paid work', async () => {
  const f = fixture({ setVideoScanManifest: async () => ({ status: 'stopped',
    reason: 'frame_manifest_changed', budget: f.budget }) });
  let paidSteps = 0;
  const result = await f.run(async (_buffer, _name, _mime, options) => {
    const stopped = await options.freezeFrames(samples, samples.length);
    if (stopped) return stopped;
    paidSteps += 1;
    return approved;
  });
  assert.equal(paidSteps, 0);
  assertStopped(result, 'frame_manifest_changed');
  assert.equal(f.callsFor('finishVideoScan').length, 0);
});

test('a known provider suspension stops the scan before decoding or provider work', async () => {
  const f = fixture({ getProviderSuspension: async () => ({ reason: 'credit_balance_exhausted' }) });
  const result = await f.run(() => assert.fail('Suspended provider must prevent scanning'));
  assertStopped(result, 'credit_balance_exhausted');
  assert.deepEqual(f.callsFor('getProviderSuspension')[0].args,
    ['openai', credentialHash('test-only-key')]);
  assert.deepEqual(f.callsFor('stopVideoScan')[0].args, [context, 'credit_balance_exhausted']);
  assert.equal(f.callsFor('setVideoScanManifest').length, 0);
});

test('optional OpenAI suspension does not prevent decoding, but required Gemini remains enforced', async t => {
  const previous = process.env.MODERATION_OPENAI_REQUIRED;
  process.env.MODERATION_OPENAI_REQUIRED = 'false';
  t.after(() => previous === undefined ? delete process.env.MODERATION_OPENAI_REQUIRED
    : process.env.MODERATION_OPENAI_REQUIRED = previous);
  const f = fixture({ getProviderSuspension: async (_pool, provider) =>
    provider === 'openai' ? { reason: 'credit_balance_exhausted' } : null },
  { providerPolicy: 'google_gemini_optional_openai' });
  let scans = 0;
  const result = await f.run(async () => { scans++; return approved; }, { geminiKey: 'gemini-test-key' });
  assert.equal(scans, 1);
  assert.notEqual(result.scanStopped, true);
  assert.deepEqual(f.callsFor('getProviderSuspension')[0].args, ['gemini', credentialHash('gemini-test-key')]);
  assert.equal(videoProviderStop({ providers: { openai: { budgetStopped: true,
    reasonCode: 'credit_balance_exhausted' }, gemini: { available: true } } }), null);
  assert.equal(videoProviderStop({ providers: { gemini: { budgetStopped: true,
    reasonCode: 'budget_exhausted' } } }), 'budget_exhausted');
  const missing = fixture({}, { providerPolicy: 'google_gemini_optional_openai' });
  assertStopped(await missing.run(() => assert.fail('Missing Gemini cannot scan'), { geminiKey: '' }),
    'provider_not_configured');
});

test('pending or missing scan outcomes become durable terminal stops', async () => {
  for (const partial of [undefined, { pending: true, blocked: false,
    frameResults: [{ timestampSeconds: 0, pending: true }] }]) {
    const f = fixture();
    const result = await f.run(async () => partial);
    assertStopped(result, 'scan_incomplete');
    assert.equal(f.callsFor('finishVideoScan').length, 0);
    assert.deepEqual(f.callsFor('stopVideoScan')[0].args, [context, 'scan_incomplete', partial]);
    assert.deepEqual(result.frameResults, partial?.frameResults);
  }
});

test('deadline returns a terminal result even if a local scanner ignores cancellation', async () => {
  const f = fixture({}, { deadlineAt: new Date(Date.now() + 25).toISOString() });
  // Keep the test alive while AbortSignal's unref'ed deadline timer runs.
  const keepAlive = setTimeout(() => {}, 1000);
  let scanSignal;
  try {
    const result = await f.run(async (_buffer, _name, _mime, options) => {
      scanSignal = options.signal;
      return new Promise(() => {});
    });
    assertStopped(result, 'deadline_exceeded');
    assert.equal(scanSignal.aborted, true);
    assert.equal(f.callsFor('finishVideoScan').length, 0);
    assert.equal(f.callsFor('stopVideoScan').length, 1);
  } finally { clearTimeout(keepAlive); }
});

test('a worker that lost its lease cannot persist a terminal stop for the new owner', async () => {
  for (const outcome of [approved, { pending: true }, 'throw']) {
    const busy = async () => ({ status: 'busy', reason: 'lease_lost' });
    const f = fixture({ finishVideoScan: busy, stopVideoScan: busy });
    const result = await f.run(async () => {
      if (outcome === 'throw') throw new Error('stale worker failed');
      return outcome;
    });
    assert.equal(result.pending, true);
    assert.equal(result.scanStopped, undefined);
  }
});

test('late suspension and error paths respect the authoritative new owner outcome', async () => {
  for (const status of ['completed', 'busy']) {
    for (const suspended of [true, false]) {
      const f = fixture({
        getProviderSuspension: async () => suspended ? { reason: 'credit_balance_exhausted' } : null,
        stopVideoScan: async () => ({ status, result: approved, budget: f.budget }),
      });
      const result = await f.run(async () => { throw new Error('stale scanner'); });
      assert.equal(result.scanStopped, undefined);
      assert.equal(result.pending, status === 'busy');
    }
  }
});

test('a successful last request at the exact cap can complete with persisted results', async () => {
  const persisted = { ...approved, persistedResult: true };
  const f = fixture({ finishVideoScan: async () => ({ status: 'completed',
    result: persisted, budget: f.budget }) }, {
    used: { total: 12, google_vision: 6, openai: 4, gemini: 2 },
  });
  const result = await f.run(async () => approved);
  assert.deepEqual(result, { ...persisted, budget: publicBudget(f.budget) });
  assert.deepEqual(result.budget.used, result.budget.limits);
  assert.equal(f.callsFor('stopVideoScan').length, 0);
  assert.deepEqual(f.callsFor('finishVideoScan')[0].args, [context, approved]);
});

test('a refused completion cannot turn an apparently approved partial result into approval', async () => {
  const f = fixture({ finishVideoScan: async () => ({ status: 'stopped',
    reason: 'operation_outcome_unknown', budget: f.budget }) });
  assertStopped(await f.run(async () => approved), 'operation_outcome_unknown');
});

test('provider stop detection preserves reason precedence and nested provider failures', async () => {
  assert.equal(videoProviderStop(null, undefined, false, {}), null);
  assert.equal(videoProviderStop({ available: false, status: 'error' }), null);
  for (const flag of ['budgetStopped', 'scanStopped', 'videoScanStopped']) {
    assert.equal(videoProviderStop({ [flag]: true }), 'required_provider_unavailable');
    assert.equal(videoProviderStop({ [flag]: true, reason: 'fallback', errorCode: 'error_code',
      reasonCode: 'budget_exhausted' }), 'budget_exhausted');
    assert.equal(videoProviderStop({ [flag]: true, reason: 'fallback', errorCode: 'error_code' }), 'error_code');
    assert.equal(videoProviderStop({ [flag]: true, reason: 'fallback' }), 'fallback');
  }
  const partial = { ...approved, providers: { review: { providers: {
    gemini: { videoScanStopped: true, reasonCode: 'provider_not_configured' },
  } } } };
  assert.equal(videoProviderStop(approved, partial), 'provider_not_configured');
  const f = fixture();
  assertStopped(await f.run(async () => partial), 'provider_not_configured');
  assert.equal(f.callsFor('finishVideoScan').length, 0);
});

test('ledger failures fail closed at acquisition, suspension, manifest and final persistence', async () => {
  for (const method of ['acquireVideoScan', 'getProviderSuspension', 'setVideoScanManifest',
    'finishVideoScan', 'stopVideoScan']) {
    const f = fixture({ [method]: async () => { throw new Error('Database unavailable'); } });
    let scans = 0;
    let paidSteps = 0;
    const result = await f.run(async (_buffer, _name, _mime, options) => {
      scans += 1;
      await options.freezeFrames(samples, 2);
      paidSteps += 1;
      return method === 'stopVideoScan' ? { pending: true } : approved;
    });
    assertStopped(result, 'provider_guard_unavailable');
    if (['acquireVideoScan', 'getProviderSuspension'].includes(method)) assert.equal(scans, 0);
    if (method === 'setVideoScanManifest') assert.equal(paidSteps, 0);
    assert.equal(f.callsFor('finishVideoScan').length, method === 'finishVideoScan' ? 1 : 0);
  }
});

test('an already expired deadline stops before the scanner without waiting for timers', async () => {
  const f = fixture({}, { deadlineAt: new Date(Date.now() - 1000).toISOString() });
  assertStopped(await f.run(() => assert.fail('Expired scan must not run')), 'deadline_exceeded');
  assert.equal(f.callsFor('finishVideoScan').length, 0);
});

test('legacy safety and changed versions are delegated without resetting canonical identity', async () => {
  for (const [legacyUnsafe, scanVersion, reason] of [
    [true, 'test-v1', 'legacy_budget_unknown'],
    [false, 'test-v2', 'scan_version_changed'],
  ]) {
    const f = fixture({ acquireVideoScan: async () => ({ status: 'stopped', reason, budget: f.budget }) });
    const result = await f.run(() => assert.fail('Ledger stop must not be reset'), { legacyUnsafe, scanVersion });
    assertStopped(result, reason);
    assert.deepEqual(f.callsFor('acquireVideoScan')[0].args, [{
      userId: tracking.userId, storedFileId: tracking.storedFileId,
      contentSha256: createHash('sha256').update(source).digest('hex'), scanVersion, legacyUnsafe,
      providerPolicy: 'google_openai_gemini',
    }]);
    assert.deepEqual(f.calls.map(call => call.method), ['acquireVideoScan']);
  }
});

test('duration rejection completes a zero-frame manifest without provider work', async () => {
  const f = fixture();
  const rejected = { blocked: true, pending: false, blockedBy: 'video_duration' };
  const result = await f.run(async () => rejected);
  assert.equal(result.blocked, true);
  assert.equal(result.pending, false);
  assert.deepEqual(f.callsFor('setVideoScanManifest')[0].args, [context, []]);
  assert.deepEqual(f.callsFor('finishVideoScan')[0].args, [context, rejected]);
});

test('public stopped results override approval fields and omit internal budget metadata', () => {
  const f = fixture();
  const result = stoppedVideoResult('budget_exhausted', f.budget, {
    ...approved, blocked: true, retryable: true, frameResults: [{ pending: false }],
  });
  assertStopped(result, 'budget_exhausted');
  assert.deepEqual(result.frameResults, [{ pending: false }]);
  assert.deepEqual(Object.keys(result.budget).sort(),
    ['frameCount', 'limits', 'used', 'startedAt', 'deadlineAt', 'scanVersion', 'providerPolicy'].sort());
  assert.equal(publicBudget(undefined), undefined);
  assert.deepEqual(stoppedVideoResult('budget_exhausted', undefined,
    { budget: f.budget }).budget, publicBudget(f.budget));
});

test('OpenAI-free scans preflight Gemini only and freeze the selected provider policy', async t => {
  const original = process.env.MODERATION_OPENAI_ENABLED;
  process.env.MODERATION_OPENAI_ENABLED = 'false';
  t.after(() => {
    if (original === undefined) delete process.env.MODERATION_OPENAI_ENABLED;
    else process.env.MODERATION_OPENAI_ENABLED = original;
  });
  const f = fixture({ getProviderSuspension: async (_pool, provider) => {
    assert.equal(provider, 'gemini');
    return null;
  } }, { providerPolicy: 'google_gemini', limits: { total: 10, google_vision: 6, openai: 0, gemini: 4 } });
  const result = await f.run(async () => approved, { geminiKey: 'gemini-test-key' });
  assert.equal(result.pending, false);
  assert.equal(result.scanStopped, undefined);
  assert.equal(result.budget.providerPolicy, 'google_gemini');
  assert.equal(result.budget.limits.openai, 0);
  assert.equal(f.callsFor('acquireVideoScan')[0].args[0].providerPolicy, 'google_gemini');
  assert.deepEqual(f.callsFor('getProviderSuspension')[0].args, ['gemini', credentialHash('gemini-test-key')]);
});

test('OpenAI-free scans with missing Gemini configuration stop before decoding or spending', async t => {
  const original = process.env.MODERATION_OPENAI_ENABLED;
  process.env.MODERATION_OPENAI_ENABLED = 'false';
  t.after(() => {
    if (original === undefined) delete process.env.MODERATION_OPENAI_ENABLED;
    else process.env.MODERATION_OPENAI_ENABLED = original;
  });
  const f = fixture({}, { providerPolicy: 'google_gemini' });
  const result = await f.run(() => assert.fail('Missing Gemini key must stop scanning'), { geminiKey: ' ' });
  assertStopped(result, 'provider_not_configured');
  assert.equal(f.callsFor('getProviderSuspension').length, 0);
  assert.equal(f.callsFor('setVideoScanManifest').length, 0);
  assert.equal(f.callsFor('finishVideoScan').length, 0);
});

test('an acquired old-policy ledger cannot silently change its active provider set', async t => {
  const original = process.env.MODERATION_OPENAI_ENABLED;
  process.env.MODERATION_OPENAI_ENABLED = 'false';
  t.after(() => {
    if (original === undefined) delete process.env.MODERATION_OPENAI_ENABLED;
    else process.env.MODERATION_OPENAI_ENABLED = original;
  });
  const f = fixture();
  const result = await f.run(() => assert.fail('Old ledger must not use a new policy'), { geminiKey: 'test-only' });
  assertStopped(result, 'scan_version_changed');
  assert.equal(f.callsFor('getProviderSuspension').length, 0);
});
