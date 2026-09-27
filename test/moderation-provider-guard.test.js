'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { credentialHash, guardModerationProvider } =
  require('../server/moderation-provider-guard');
const { classifyOpenAIPersonPresence } = require('../server/person-verification');
const { classifyOpenAIModesty } = require('../server/modesty-verification');
const { classifyGeminiModesty } = require('../server/gemini-modesty-verification');
const { scanGoogleSafeSearch, scanGoogleObjectLocalization, scanGoogleFaceDetection } =
  require('../server/google-vision');

// Provider usage logging must never contact an application database in these tests.
delete process.env.DATABASE_URL;

const videoBudget = { scanId: 'scan', leaseToken: 'lease', frameIndex: 0 };
const image = Buffer.from('test image');

function memoryLedger() {
  const reservations = [];
  const results = new Map();
  const suspensions = new Map();
  const ledger = {
    async reserveVideoScanOperation(_pool, args) {
      const key = `${args.scanId}:${args.frameIndex}:${args.provider}:${args.operation}`;
      if (results.has(key)) return { status: 'cached', result: results.get(key) };
      if (reservations.some(item => item.key === key))
        return { status: 'busy', reason: 'operation_in_progress' };
      const reservationId = String(reservations.length + 1);
      reservations.push({ ...args, key, reservationId });
      return { status: 'reserved', reservationId };
    },
    async finishVideoScanOperation(_pool, args) {
      const reservation = reservations.find(item => item.reservationId === args.reservationId);
      assert.ok(reservation);
      assert.equal(args.scanId, reservation.scanId);
      assert.equal(args.leaseToken, reservation.leaseToken);
      results.set(reservation.key, args.result);
      return { status: args.result.available ? 'completed' : 'stopped',
        reason: args.result.available ? undefined : 'provider_failed' };
    },
    async getProviderSuspension(_pool, provider, hash) {
      return suspensions.get(`${provider}:${hash}`) || null;
    },
    async suspendProvider(_pool, args) {
      suspensions.set(`${args.provider}:${args.credentialHash}`, args);
      return args;
    },
  };
  return { dependencies: { pool: {}, ledger }, reservations, results, suspensions };
}

function response(body, status = 200) {
  return { ok: status >= 200 && status < 300, status, json: async () => body };
}

test('all six video operations reserve before network and reuse persisted results', async () => {
  const state = memoryLedger();
  const cases = [
    [scanGoogleSafeSearch, 'google_vision', 'safe_search', {
      responses: [{ safeSearchAnnotation: { adult: 'VERY_UNLIKELY', racy: 'VERY_UNLIKELY' } }],
    }],
    [scanGoogleObjectLocalization, 'google_vision', 'object_localization', {
      responses: [{ localizedObjectAnnotations: [] }],
    }],
    [scanGoogleFaceDetection, 'google_vision', 'face_detection', {
      responses: [{ faceAnnotations: [] }],
    }],
    [classifyOpenAIPersonPresence, 'openai', 'person_presence', {
      output_text: '{"decision":"non_human","confidence":0.99}',
    }],
    [classifyOpenAIModesty, 'openai', 'modesty', {
      output_text: '{"decision":"modest","confidence":0.99}',
    }],
    [classifyGeminiModesty, 'gemini', 'modesty', {
      candidates: [{ content: { parts: [{ text: '{"decision":"modest","confidence":0.99}' }] } }],
    }],
  ];
  let requests = 0;
  for (const [classify, provider, operation, body] of cases) {
    const options = { apiKey: 'test-key', skipImagePreparation: true,
      tracking: { videoBudget }, providerGuardDependencies: state.dependencies,
      fetchImpl: async () => {
        requests += 1;
        assert.ok(state.reservations.some(item => item.provider === provider &&
          item.operation === operation));
        return response(body);
      } };
    const first = await classify(image, options);
    assert.equal(first.available, true, `${provider}:${operation}`);
    const cached = await classify(image, options);
    assert.deepEqual(cached, { ...first, cacheHit: true });
  }
  assert.equal(requests, 6);
  assert.equal(state.reservations.length, 6);
  assert.equal(state.results.size, 6);
});

test('budgeted Gemini malformed output stops after one request without format repair', async () => {
  const state = memoryLedger();
  let requests = 0;
  const result = await classifyGeminiModesty(image, {
    apiKey: 'gemini-test-key', skipImagePreparation: true,
    tracking: { videoBudget }, providerGuardDependencies: state.dependencies,
    fetchImpl: async () => {
      requests += 1;
      return response({ candidates: [{ content: { parts: [{ text: 'decision: modest' }] } }] });
    },
  });
  assert.equal(requests, 1);
  assert.equal(result.available, false);
  assert.equal(result.budgetStopped, true);
  assert.equal(state.reservations.length, 1);
  assert.equal(state.results.size, 1);
});

test('OpenAI credit exhaustion persists a hashed suspension across both moderation helpers', async () => {
  const state = memoryLedger();
  let requests = 0;
  const apiKey = 'never-store-this-key';
  const options = { apiKey, providerGuardDependencies: state.dependencies,
    fetchImpl: async () => {
      requests += 1;
      return response({ error: { code: 'credit_balance_exhausted', message: 'No credits' } }, 429);
    } };
  const failed = await classifyOpenAIModesty(image, options);
  assert.equal(failed.errorCode, 'credit_balance_exhausted');
  assert.equal(failed.providerSuspended, true);
  assert.equal(failed.status, 'stopped');
  const blocked = await classifyOpenAIPersonPresence(image, options);
  assert.equal(blocked.reasonCode, 'credit_balance_exhausted');
  assert.equal(blocked.available, false);
  assert.equal(requests, 1);
  const suspension = [...state.suspensions.values()][0];
  assert.match(suspension.credentialHash, /^[a-f0-9]{64}$/);
  assert.equal(suspension.credentialHash, credentialHash(apiKey));
  assert.equal(JSON.stringify(suspension).includes(apiKey), false);
  assert.equal(state.reservations.length, 0);
});

test('a provider suspension is scoped to its credential hash', async () => {
  const state = memoryLedger();
  await state.dependencies.ledger.suspendProvider({}, { provider: 'openai',
    credentialHash: credentialHash('old-key'), reason: 'credit_balance_exhausted' });
  let requests = 0;
  const result = await classifyOpenAIModesty(image, { apiKey: 'new-key',
    providerGuardDependencies: state.dependencies,
    fetchImpl: async () => {
      requests += 1;
      return response({ output_text: '{"decision":"modest","confidence":0.99}' });
    } });
  assert.equal(result.available, true);
  assert.equal(requests, 1);
  assert.equal(state.suspensions.size, 1);
});

test('database or suspension lookup failures stop OpenAI before network', async () => {
  for (const dependencies of [
    { getPool: async () => { throw new Error('database unavailable'); } },
    { pool: {}, ledger: { getProviderSuspension: async () => { throw new Error('missing table'); } } },
  ]) {
    let requests = 0;
    const result = await classifyOpenAIModesty(image, { apiKey: 'test-key',
      providerGuardDependencies: dependencies,
      fetchImpl: async () => { requests += 1; throw new Error('unexpected request'); } });
    assert.equal(result.budgetStopped, true);
    assert.equal(result.reasonCode, 'provider_guard_unavailable');
    assert.equal(requests, 0);
  }
});

test('budget reservation denial and errors never call the provider', async () => {
  for (const reservation of [
    { status: 'busy', reason: 'scan_lease_active' },
    { status: 'stopped', reason: 'budget_exhausted' },
    new Error('reservation unavailable'),
  ]) {
    let requests = 0;
    const result = await scanGoogleFaceDetection(image, { apiKey: 'test-key',
      tracking: { videoBudget }, providerGuardDependencies: { pool: {}, ledger: {
        reserveVideoScanOperation: async () => {
          if (reservation instanceof Error) throw reservation;
          return reservation;
        },
      } },
      fetchImpl: async () => { requests += 1; throw new Error('unexpected request'); } });
    assert.equal(result.status, 'stopped');
    assert.equal(result.budgetStopped, true);
    assert.equal(requests, 0);
  }
});

test('timed out and unknown failures retain their reservation and stopped result', async () => {
  for (const name of ['TimeoutError', 'TypeError']) {
    const state = memoryLedger();
    let requests = 0;
    const options = { apiKey: 'test-key', tracking: { videoBudget },
      providerGuardDependencies: state.dependencies,
      fetchImpl: async () => {
        requests += 1;
        const error = new Error('request failed');
        error.name = name;
        throw error;
      } };
    const result = await scanGoogleFaceDetection(image, options);
    assert.equal(result.budgetStopped, true);
    assert.equal(result.errorCode, name);
    assert.equal(result.retryable, false);
    assert.equal(state.reservations.length, 1);
    assert.equal(state.results.size, 1);
    await scanGoogleFaceDetection(image, options);
    assert.equal(requests, 1);
  }
});

test('lost completion acknowledgement fails closed and cannot start a duplicate request', async () => {
  const state = memoryLedger();
  state.dependencies.ledger.finishVideoScanOperation = async () => {
    throw new Error('connection lost after request');
  };
  let requests = 0;
  const options = { apiKey: 'test-key', tracking: { videoBudget },
    providerGuardDependencies: state.dependencies,
    fetchImpl: async () => {
      requests += 1;
      return response({ responses: [{ faceAnnotations: [] }] });
    } };
  const first = await scanGoogleFaceDetection(image, options);
  assert.equal(first.reasonCode, 'provider_guard_unavailable');
  assert.equal(first.available, false);
  const second = await scanGoogleFaceDetection(image, options);
  assert.equal(second.reasonCode, 'operation_in_progress');
  assert.equal(requests, 1);
});

test('runtime cancellation is forwarded but omitted from persisted responses', async () => {
  const state = memoryLedger();
  const controller = new AbortController();
  let requestSignal;
  const result = await scanGoogleFaceDetection(image, { apiKey: 'test-key',
    tracking: { videoBudget: { ...videoBudget, signal: controller.signal } },
    providerGuardDependencies: state.dependencies,
    fetchImpl: async (_url, options) => {
      requestSignal = options.signal;
      controller.abort();
      assert.equal(requestSignal.aborted, true);
      return response({ responses: [{ faceAnnotations: [] }] });
    } });
  assert.equal(result.available, true);
  assert.equal(state.reservations[0].signal, undefined);
  assert.equal(JSON.stringify([...state.results.values()]).includes('signal'), false);
  const another = memoryLedger();
  await guardModerationProvider({ provider: 'gemini', operation: 'modesty', apiKey: 'test-key',
    options: { tracking: { videoBudget }, providerGuardDependencies: another.dependencies },
    run: async () => ({ available: true, signal: controller.signal,
      nested: { signal: controller.signal } }),
  });
  assert.deepEqual([...another.results.values()][0], { available: true, nested: {} });
});

test('budgeted requests require a database even when a mock provider could succeed', async () => {
  let requests = 0;
  const result = await classifyGeminiModesty(image, { apiKey: 'test-key',
    skipImagePreparation: true, tracking: { videoBudget },
    fetchImpl: async () => { requests += 1; throw new Error('unexpected request'); } });
  assert.equal(result.budgetStopped, true);
  assert.equal(result.reasonCode, 'provider_guard_unavailable');
  assert.equal(requests, 0);
});
