'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { createRequire } = require('node:module');
const { moderationCheckSummary, CHECK_FINDINGS } = require('../server/moderation-check-summary');

test('semantic summaries preserve verdicts and frame context without provider prose or images', () => {
  const summary = moderationCheckSummary('openai', 'modesty', {
    available: true, decision: 'non_modest', confidence: 0.946, violationClearlyVisible: true,
    reason: 'private provider explanation', visibleEvidence: 'private evidence',
    image: 'base64-private-image', prompt: 'private prompt',
  }, { videoBudget: { frameIndex: 3, timestampSeconds: 1.23456 } });
  assert.deepEqual(summary, { checkType: 'modesty', checkOutcome: 'blocked', cacheHit: false,
    checkFindings: ['non_modest', 'visible_violation'], checkConfidencePct: 95,
    frameIndex: 3, frameTimestampMs: 1235 });
  assert.equal(JSON.stringify(summary).includes('private'), false);
});

test('missing results never become a passed check merely because transport completed', () => {
  for (const result of [null, {}, { status: 'completed' }, { available: true, status: 'completed' }])
    assert.equal(moderationCheckSummary('openai', 'modesty', result).checkOutcome, 'not_recorded');
  assert.equal(moderationCheckSummary('local', 'local_safety', { available: true }).checkOutcome, 'passed');
  assert.equal(moderationCheckSummary('local', 'local_classification',
    { available: true, classification: { uncertain: true } }).checkOutcome, 'uncertain');
});

test('skipped modesty has no invented modesty verdict, confidence, or detected person count', () => {
  const summary = moderationCheckSummary('openai', 'modesty', {
    required: false, available: true, status: 'not_needed', decision: 'modest', confidence: 1,
    personDetected: false, persons: [], findings: ['no_person_detected'],
  });
  assert.deepEqual(summary, { checkType: 'modesty', checkOutcome: 'skipped', cacheHit: false,
    checkFindings: ['no_person_detected'] });
});

test('findings are enum-only and metadata counts and timestamps have strict bounds', () => {
  const summary = moderationCheckSummary('google_vision', 'face_detection', {
    available: true, faceDetected: true, faceCount: 100000, confidence: 2,
    findings: ['untrusted free text', ...CHECK_FINDINGS, 'secret-key'],
  }, { videoBudget: { frameIndex: 90, timestampSeconds: Infinity } });
  assert.equal(summary.checkFaceCount, 1000);
  assert.equal(summary.checkConfidencePct, 100);
  assert.equal(summary.frameIndex, undefined);
  assert.equal(summary.frameTimestampMs, undefined);
  assert.ok(summary.checkFindings.length <= 16);
  assert.ok(summary.checkFindings.every(value => CHECK_FINDINGS.includes(value)));
  assert.deepEqual(moderationCheckSummary('provider', 'arbitrary_check', {}), {});
});

function providerFixture({ usageFailure = false } = {}) {
  const events = [], queries = [], cache = new Map();
  const pool = { query: async (sql, values) => {
    queries.push({ sql, values });
    if (usageFailure && /INSERT INTO moderation_provider_calls/.test(sql)) throw new Error('synthetic journal failure');
    return { rows: [], rowCount: 0 };
  } };
  const moduleNames = new Set(['provider-usage-log', 'moderation-provider-guard', 'moderation-check-summary',
    'google-vision', 'person-verification', 'modesty-verification', 'gemini-modesty-verification']);
  const load = name => {
    if (cache.has(name)) return cache.get(name).exports;
    const filename = require.resolve(`../server/${name}`);
    const actualRequire = createRequire(filename), module = { exports: {} };
    cache.set(name, module);
    const requireMock = request => {
      if (request === './db') return { getPool: async () => pool };
      if (request === './system-audit') return { getAuditContext: () => ({ operationId: '10000000-0000-4000-8000-000000000001' }) };
      if (request === './system-audit-context') return { observeAudit: async (db, event) => {
        assert.equal(db, pool);
        events.push(JSON.parse(JSON.stringify(event)));
      } };
      if (request.startsWith('./') && moduleNames.has(request.slice(2))) return load(request.slice(2));
      return actualRequire(request);
    };
    const context = { Buffer, performance, AbortSignal, console: { warn() {} },
      process: { env: { DATABASE_URL: 'synthetic test database' } } };
    vm.runInNewContext(`(function(require,module,exports){${fs.readFileSync(filename, 'utf8')}\n})`, context,
      { filename })(requireMock, module, module.exports);
    return module.exports;
  };
  const results = new Map();
  const ledger = {
    getProviderSuspension: async () => null,
    reserveVideoScanOperation: async (_db, args) => results.has(args.operation)
      ? { status: 'cached', result: results.get(args.operation) }
      : { status: 'reserved', reservationId: args.operation },
    finishVideoScanOperation: async (_db, args) => {
      results.set(args.reservationId, args.result);
      return { status: args.result.available ? 'completed' : 'stopped', reason: 'required_provider_unavailable' };
    },
    suspendProvider: async () => ({}),
  };
  const options = { apiKey: 'synthetic-key', skipImagePreparation: true,
    tracking: { userId: 'test-user', workflow: 'test', scanPreviewId: '20000000-0000-4000-8000-000000000002',
      videoBudget: { scanId: 'test-scan', leaseToken: 'test-lease', frameIndex: 2, timestampSeconds: 1.5 } },
    providerGuardDependencies: { pool, ledger } };
  const calls = () => queries.filter(query => /INSERT INTO moderation_provider_calls/.test(query.sql));
  return { events, queries, load, options, ledger, calls };
}

const response = (body, status = 200) => ({ ok: status >= 200 && status < 300, status, json: async () => body });

test('each actual provider request records one semantic audit event and one accounting row', async () => {
  const cases = [
    ['google-vision', 'scanGoogleSafeSearch', { responses: [{ safeSearchAnnotation: {
      adult: 'VERY_LIKELY', racy: 'VERY_UNLIKELY', violence: 'POSSIBLE', medical: 'UNLIKELY', spoof: 'VERY_UNLIKELY',
    } }] }, 'blocked', 'adult_very_likely'],
    ['google-vision', 'scanGoogleObjectLocalization', { responses: [{ localizedObjectAnnotations: [
      { name: 'Person', score: 0.9 }, { name: 'Person', score: 0.95 },
    ] }] }, 'passed', 'person_detected'],
    ['google-vision', 'scanGoogleFaceDetection', { responses: [{ faceAnnotations: [{ detectionConfidence: 0.9 }] }] }, 'passed', 'faces_detected'],
    ['person-verification', 'classifyOpenAIPersonPresence', { output_text: JSON.stringify({
      decision: 'person', person_categories: ['women', 'children'], confidence: 0.9, reason: 'private reason',
    }) }, 'passed', 'women'],
    ['modesty-verification', 'classifyOpenAIModesty', { output_text: JSON.stringify({
      decision: 'non_modest', confidence: 0.9, violationClearlyVisible: true, visibleEvidence: 'private visible evidence',
    }) }, 'blocked', 'visible_violation'],
    ['gemini-modesty-verification', 'classifyGeminiModesty', { candidates: [{ content: { parts: [{
      text: '{"decision":"uncertain","confidence":0.6,"reason":"private reason"}',
    }] } }] }, 'uncertain', 'uncertain'],
  ];
  for (const [module, method, body, expectedOutcome, finding] of cases) {
    const f = providerFixture();
    const result = await f.load(module)[method](Buffer.from('synthetic-image'), {
      ...f.options, fetchImpl: async () => response(body),
    });
    assert.equal(result.available, true);
    assert.equal(f.calls().length, 1, method);
    assert.equal(f.events.length, 1, method);
    assert.equal(f.events[0].kind, 'provider_call_finished');
    assert.equal(f.events[0].details.providerCallId, f.calls()[0].values[0]);
    assert.equal(f.events[0].details.checkOutcome, expectedOutcome, method);
    assert.ok(f.events[0].details.checkFindings.includes(finding), method);
    assert.equal(f.events[0].details.frameIndex, 2);
    assert.equal(f.events[0].details.frameTimestampMs, 1500);
    assert.equal(f.events[0].details.auditOnly, false);
    assert.equal(f.events[0].details.scanPreviewId, f.options.tracking.scanPreviewId);
    assert.equal(JSON.stringify(f.events).includes('private'), false);
  }
});

test('malformed responses retain billed usage but record failed semantic results', async () => {
  for (const [module, method, body] of [
    ['modesty-verification', 'classifyOpenAIModesty', { output_text: 'not JSON', usage: { input_tokens: 20, output_tokens: 5, total_tokens: 25 } }],
    ['person-verification', 'classifyOpenAIPersonPresence', { output_text: 'not JSON', usage: { input_tokens: 20, output_tokens: 5, total_tokens: 25 } }],
    ['gemini-modesty-verification', 'classifyGeminiModesty', { candidates: [{ content: { parts: [{ text: 'not JSON' }] } }],
      usageMetadata: { promptTokenCount: 20, candidatesTokenCount: 5, totalTokenCount: 25 } }],
  ]) {
    const f = providerFixture();
    await f.load(module)[method](Buffer.from('synthetic-image'), { ...f.options, fetchImpl: async () => response(body) });
    assert.equal(f.calls().length, 1);
    assert.equal(f.calls()[0].values[12], 25);
    assert.equal(f.events.length, 1);
    assert.equal(f.events[0].details.checkOutcome, 'failed');
    assert.ok(f.events[0].details.checkFindings.includes('invalid_response'));
  }
});

test('Gemini format repair records each actual call and preserves their separate outcomes', async () => {
  const f = providerFixture();
  let calls = 0;
  const options = { ...f.options, tracking: { workflow: 'test' }, fetchImpl: async () => response({
    candidates: [{ content: { parts: [{ text: ++calls === 1 ? 'invalid' : '{"decision":"modest","confidence":1}' }] } }],
  }) };
  await f.load('gemini-modesty-verification').classifyGeminiModesty(Buffer.from('synthetic-image'), options);
  assert.equal(f.calls().length, 2);
  assert.equal(f.events.length, 2);
  assert.deepEqual(f.events.map(event => event.details.checkOutcome), ['failed', 'passed']);
  assert.deepEqual(f.events.map(event => event.details.checkType), ['modesty', 'modesty_format_repair']);
});

test('malformed Gemini envelopes retain exactly one failed accounting and audit result', async () => {
  for (const video of [false, true]) {
    for (const body of [null, [], 'invalid envelope',
      { candidates: [{ content: { parts: {} } }],
        usageMetadata: { promptTokenCount: 20, candidatesTokenCount: 5, totalTokenCount: 25 } },
      { candidates: [{ content: { parts: [null, { text: 42 }] } }] }]) {
      const f = providerFixture();
      let requests = 0;
      const result = await f.load('gemini-modesty-verification').classifyGeminiModesty(Buffer.from('synthetic-image'), {
        ...f.options, tracking: video ? f.options.tracking : { workflow: 'test' },
        fetchImpl: async () => { requests++; return response(body); },
      });
      assert.equal(requests, 1);
      assert.equal(result.available, false);
      assert.equal(result.errorCode, 'INVALID_RESPONSE');
      assert.equal(f.calls().length, 1);
      assert.equal(f.calls()[0].values[12], body?.usageMetadata ? 25 : 0);
      assert.equal(f.events.length, 1);
      assert.equal(f.events[0].kind, 'provider_call_finished');
      assert.equal(f.events[0].details.auditOnly, false);
      assert.equal(f.events[0].details.checkOutcome, 'failed');
      assert.ok(f.events[0].details.checkFindings.includes('invalid_response'));
    }
  }
});

test('cached verdicts and guard refusals create audit-only events without additional accounting rows', async () => {
  const f = providerFixture(), classify = f.load('modesty-verification').classifyOpenAIModesty;
  const options = { ...f.options, fetchImpl: async () => response({ output_text: '{"decision":"uncertain","confidence":0.5}' }) };
  await classify(Buffer.from('synthetic-image'), options);
  await classify(Buffer.from('synthetic-image'), options);
  assert.equal(f.calls().length, 1);
  assert.equal(f.events.length, 2);
  assert.equal(f.events[1].kind, 'scan_cache_used');
  assert.equal(f.events[1].details.checkOutcome, 'uncertain');
  assert.equal(f.events[1].details.cacheHit, true);
  assert.equal(f.events[1].details.auditOnly, true);
  const stopped = providerFixture();
  stopped.ledger.getProviderSuspension = async () => ({ reason: 'credit_balance_exhausted' });
  await stopped.load('modesty-verification').classifyOpenAIModesty(Buffer.from('synthetic-image'), {
    ...stopped.options, fetchImpl: async () => { throw new Error('HTTP must not run'); },
  });
  assert.equal(stopped.calls().length, 0);
  assert.equal(stopped.events.length, 1);
  assert.equal(stopped.events[0].kind, 'moderation_check_finished');
  assert.equal(stopped.events[0].details.checkOutcome, 'stopped');
  assert.ok(stopped.events[0].details.checkFindings.includes('credit_balance_exhausted'));
});

test('not configured and local diagnostic checks are explicitly audit-only', async () => {
  const f = providerFixture();
  await f.load('google-vision').scanGoogleSafeSearch(Buffer.from('synthetic-image'), { apiKey: '' });
  assert.equal(f.events[0].details.checkOutcome, 'skipped');
  await f.load('provider-usage-log').recordProviderCheck({ provider: 'local', operation: 'local_safety',
    result: { available: true, wouldBlock: true, findings: ['comparison_only'] } });
  assert.equal(f.events[1].details.checkOutcome, 'blocked');
  assert.equal(f.events[1].executorType, 'system');
  assert.equal(f.events[1].source, 'local_moderation');
  assert.equal(f.events[1].details.auditOnly, true);
  assert.equal(f.calls().length, 0);
});

test('an accounting insert failure still attempts one semantic audit event', async () => {
  const f = providerFixture({ usageFailure: true });
  await f.load('modesty-verification').classifyOpenAIModesty(Buffer.from('synthetic-image'), {
    ...f.options, fetchImpl: async () => response({ output_text: '{"decision":"modest","confidence":1}' }),
  });
  assert.equal(f.calls().length, 1);
  assert.equal(f.calls()[0].values[15], false);
  assert.equal(f.events.length, 1);
  assert.equal(f.events[0].details.checkOutcome, 'passed');
});
