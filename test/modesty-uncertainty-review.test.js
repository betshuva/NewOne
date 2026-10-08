'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const {
  REVIEW_VERSION, MAX_IMAGE_REVIEWS, clearlyCompliant, uncertaintyReviewProvider,
  createImageReviewState,
  reserveImageReview, finishImageReview, reviewModestyUncertainty, stoppedImageResult,
} = require('../server/modesty-uncertainty-review');

const image = Buffer.from('full uncertainty review image');
const fileId = 'de063c73-7f9b-4a59-bd39-d8ca15c3d928';
const compliant = overrides => ({ available: true, status: 'completed',
  decision: 'modest', confidence: 0.96, violationClearlyVisible: false,
  visibleAreasDecision: 'compliant', uncertaintyReason: 'none',
  visibleEvidence: 'הכתפיים והחזה מכוסים בחולצה', ...overrides });
const uncertain = overrides => compliant({ decision: 'uncertain', confidence: 0.5,
  visibleAreasDecision: 'uncertain', uncertaintyReason: 'visible_area_ambiguous',
  ...overrides });
const violation = overrides => compliant({ decision: 'non_modest', confidence: 0.99,
  violationClearlyVisible: true, visibleAreasDecision: 'violation',
  visibleEvidence: 'כתף חשופה וקצה הבגד נראים בבירור', ...overrides });

function eligible(overrides = {}) {
  return { verifiedPeople: true, classification: { category: 'men', uncertain: false },
    googleSafeSearch: { available: true, blocked: false, uncertain: false },
    localSafety: { available: true, wouldBlock: false },
    useOpenAI: true, requireOpenAI: false,
    modestyVerification: compliant(), geminiModestyVerification: uncertain(),
    ...overrides };
}

function fixture({ reservation = { status: 'reserved', id: 'review-id' },
  result = compliant(), reserveError, finishError, acknowledged = true } = {}) {
  const calls = [], pool = {};
  const dependencies = {
    pool,
    reserveImageReview: async (receivedPool, args) => {
      assert.equal(receivedPool, pool);
      calls.push({ operation: 'reserve', args });
      if (reserveError) throw reserveError;
      return reservation;
    },
    finishImageReview: async (receivedPool, id, receivedResult) => {
      assert.equal(receivedPool, pool);
      calls.push({ operation: 'finish', id, result: receivedResult });
      if (finishError) throw finishError;
      return acknowledged;
    },
    recordProviderCheck: async args => calls.push({ operation: 'cached-check', args }),
  };
  const options = eligible({ tracking: { storedFileId: fileId, userId: 'viewer' },
    reviewVersion: 'moderation-version', reviewDependencies: dependencies,
    reviewProvider: async (provider, bytes, passedOptions) => {
      calls.push({ operation: 'provider', provider, bytes, options: passedOptions });
      return result;
    } });
  return { calls, pool, options, run: overrides =>
    reviewModestyUncertainty(image, { ...options, ...overrides }) };
}

test('review eligibility selects the sole required uncertain provider', () => {
  assert.equal(uncertaintyReviewProvider(eligible()), 'gemini');
  assert.equal(uncertaintyReviewProvider(eligible({ requireOpenAI: true })), 'gemini');
  assert.equal(uncertaintyReviewProvider(eligible({ requireOpenAI: true,
    geminiModestyVerification: compliant(), modestyVerification: uncertain() })), 'openai');
  assert.equal(uncertaintyReviewProvider(eligible({ requireOpenAI: true,
    modestyVerification: uncertain() })), null);
  assert.equal(uncertaintyReviewProvider(eligible({ requireOpenAI: false,
    geminiModestyVerification: compliant(), modestyVerification: uncertain() })), null);
  assert.equal(uncertaintyReviewProvider(eligible({ useOpenAI: false,
    modestyVerification: { available: false, status: 'disabled' } })), 'gemini');
});

test('unsafe, incomplete or missing prerequisite checks never start a review', async () => {
  for (const overrides of [
    { verifiedPeople: false }, { classification: null },
    { classification: { category: null, uncertain: false } },
    { classification: { category: 'men', uncertain: true } },
    { googleSafeSearch: null }, { googleSafeSearch: { available: false } },
    { googleSafeSearch: { available: true, blocked: true } },
    { googleSafeSearch: { available: true, uncertain: true } },
    { localSafety: null }, { localSafety: { available: false } },
    { localSafety: { available: true, wouldBlock: true } },
  ]) {
    const state = fixture();
    assert.equal(await state.run(overrides), null, JSON.stringify(overrides));
    assert.equal(state.calls.length, 0);
  }
});

test('unavailable, definite, unstructured and already clean results are ineligible', async () => {
  for (const review of [
    { available: false, status: 'error' },
    uncertain({ status: 'stopped' }), uncertain({ status: 'not_needed' }),
    uncertain({ available: false }), uncertain({ violationClearlyVisible: true }),
    uncertain({ visibleAreasDecision: 'violation' }),
    uncertain({ uncertaintyReason: 'unknown' }),
    uncertain({ visibleEvidence: '' }), uncertain({ visibleEvidence: '    ' }),
    uncertain({ visibleEvidence: {} }), uncertain({ visibleAreasDecision: undefined }),
    { available: true, decision: 'uncertain', reason: 'מחוץ לפריים בלבד' },
    violation(), compliant(),
  ]) {
    const state = fixture();
    assert.equal(await state.run({ geminiModestyVerification: review }), null,
      JSON.stringify(review));
    assert.equal(state.calls.length, 0);
  }
});

test('a required clean peer must be well-formed and confident', () => {
  for (const openai of [
    compliant({ confidence: 0.84 }), compliant({ status: 'error' }),
    compliant({ visibleAreasDecision: 'uncertain' }),
    compliant({ uncertaintyReason: 'visible_area_ambiguous' }),
    compliant({ visibleEvidence: '' }), compliant({ violationClearlyVisible: true }),
    { available: false, status: 'error' }, violation(),
  ]) {
    assert.equal(uncertaintyReviewProvider(eligible({ requireOpenAI: true,
      modestyVerification: openai })), null, JSON.stringify(openai));
  }
});

test('optional explicit violations cannot be overridden by a Gemini recheck', async () => {
  for (const review of [violation(), violation({ status: 'safety_blocked', confidence: 1 })]) {
    const state = fixture();
    assert.equal(await state.run({ modestyVerification: review }), null);
    assert.equal(state.calls.length, 0);
  }
});

test('approval requires coherent structured evidence and confidence of at least 0.85', () => {
  assert.equal(clearlyCompliant(compliant({ confidence: 0.85 })), true);
  assert.equal(clearlyCompliant(compliant({ uncertaintyReason: 'out_of_frame_only' })), true);
  for (const review of [
    compliant({ confidence: 0.849 }), compliant({ confidence: '0.99' }),
    compliant({ confidence: Infinity }), compliant({ confidence: NaN }),
    compliant({ available: false }), compliant({ available: undefined }),
    compliant({ status: 'error' }), compliant({ decision: 'uncertain' }),
    compliant({ violationClearlyVisible: true }),
    compliant({ violationClearlyVisible: undefined }),
    compliant({ visibleAreasDecision: 'uncertain' }),
    compliant({ uncertaintyReason: 'visible_area_ambiguous' }),
    compliant({ visibleEvidence: 'four' }), compliant({ visibleEvidence: {} }),
    { available: true, status: 'completed', decision: 'modest', confidence: 0.99 },
  ]) assert.equal(clearlyCompliant(review), false, JSON.stringify(review));
});

test('a tracked image reserves once, reviews the full bytes blindly and persists before approval', async () => {
  const state = fixture();
  const signal = new AbortController().signal;
  const outcome = await state.run({ signal });
  assert.equal(outcome.resolution, 'approved');
  assert.equal(outcome.provider, 'gemini');
  assert.equal(outcome.attempted, true);
  assert.deepEqual(state.calls.map(call => call.operation), ['reserve', 'provider', 'finish']);
  assert.deepEqual(state.calls[0].args, { storedFileId: fileId,
    contentSha256: createHash('sha256').update(image).digest('hex'),
    reviewVersion: `moderation-version:${REVIEW_VERSION}`, provider: 'gemini' });
  assert.equal(state.calls[1].bytes, image);
  assert.deepEqual(state.calls[1].options, { tracking: state.options.tracking, signal });
  assert.equal(state.calls[1].options.modestyVerification, undefined);
  assert.equal(state.calls[1].options.geminiModestyVerification, undefined);
  assert.equal(state.calls[2].id, 'review-id');
});

test('dual-required review targets OpenAI while optional OpenAI uncertainty makes no request', async () => {
  const required = fixture();
  const result = await required.run({ requireOpenAI: true,
    geminiModestyVerification: compliant(), modestyVerification: uncertain() });
  assert.equal(result.provider, 'openai');
  assert.equal(result.resolution, 'approved');
  assert.equal(required.calls[0].args.provider, 'openai');
  assert.equal(required.calls[1].provider, 'openai');
  const optional = fixture();
  assert.equal(await optional.run({ geminiModestyVerification: compliant(),
    modestyVerification: uncertain() }), null);
  assert.equal(optional.calls.length, 0);
});

test('video frames delegate the bound and persistence to their provider ledger', async () => {
  const state = fixture();
  const tracking = { storedFileId: fileId, videoBudget: { scanId: 'scan',
    leaseToken: 'lease', frameIndex: 7 } };
  const outcome = await state.run({ tracking });
  assert.equal(outcome.resolution, 'approved');
  assert.deepEqual(state.calls.map(call => call.operation), ['provider']);
  assert.equal(state.calls[0].options.tracking, tracking);
});

test('unresolved, malformed and unavailable review results stay fail-closed', async () => {
  for (const [result, reason] of [
    [uncertain(), 'modesty_uncertain'],
    [compliant({ confidence: 0.84 }), 'modesty_uncertain'],
    [compliant({ visibleAreasDecision: 'uncertain' }), 'modesty_uncertain'],
    [{ available: true, status: 'completed', decision: 'modest', confidence: 0.99 }, 'modesty_uncertain'],
    [{ available: false, status: 'error' }, 'provider_error'],
    [{ available: false, status: 'stopped', reasonCode: 'budget_exhausted' }, 'budget_exhausted'],
    [undefined, 'provider_error'],
  ]) {
    const state = fixture({ result });
    if (result === undefined) state.options.reviewProvider = async () => undefined;
    const outcome = await state.run();
    assert.equal(outcome.resolution, 'unresolved', JSON.stringify(result));
    assert.equal(outcome.reasonCode, reason);
    assert.deepEqual(state.calls.map(call => call.operation),
      result === undefined ? ['reserve', 'finish'] : ['reserve', 'provider', 'finish']);
  }
});

test('review exceptions are persisted as errors without a second request', async () => {
  const state = fixture();
  let requests = 0;
  state.options.reviewProvider = async () => { requests++; throw new Error('timeout'); };
  const outcome = await state.run();
  assert.equal(requests, 1);
  assert.equal(outcome.resolution, 'unresolved');
  assert.equal(outcome.reasonCode, 'provider_error');
  assert.equal(outcome.result.errorCode, 'REQUEST_FAILED');
  assert.deepEqual(state.calls.map(call => call.operation), ['reserve', 'finish']);
});

test('clear review violations block; unsupported or weak violations remain unresolved', async () => {
  for (const [result, expected] of [
    [violation(), 'blocked'],
    [violation({ status: 'safety_blocked', confidence: 1 }), 'blocked'],
    [violation({ confidence: 0.84 }), 'unresolved'],
    [violation({ violationClearlyVisible: false }), 'unresolved'],
  ]) {
    const state = fixture({ result });
    assert.equal((await state.run()).resolution, expected);
  }
});

test('cached review reuses only validated evidence without another paid request', async () => {
  for (const [result, expected] of [[compliant(), 'approved'], [uncertain(), 'unresolved'],
    [{ available: false, status: 'error' }, 'unresolved'],
    [compliant({ confidence: 0.84 }), 'unresolved']]) {
    const state = fixture({ reservation: { status: 'cached', result } });
    const outcome = await state.run();
    assert.equal(outcome.resolution, expected);
    assert.equal(outcome.cacheHit, true);
    assert.equal(outcome.result.cacheHit, true);
    assert.deepEqual(state.calls.map(call => call.operation), ['reserve', 'cached-check']);
    assert.equal(state.calls[1].args.operation, 'modesty_uncertainty_review');
    assert.equal(state.calls[1].args.cacheHit, true);
  }
});

test('untracked multi-image requests share a three-review cap across distinct bytes', async () => {
  const state = createImageReviewState();
  let requests = 0;
  const options = eligible({ reviewState: state, tracking: { workflow: 'admin_test' },
    reviewProvider: async () => {
      requests++;
      // Unresolved and failed calls still consume the request's allowance.
      return requests === 1 ? uncertain() : requests === 2
        ? { available: false, status: 'error' } : compliant();
    } });
  const outcomes = [];
  for (let index = 0; index < MAX_IMAGE_REVIEWS + 1; index++)
    outcomes.push(await reviewModestyUncertainty(Buffer.from(`visual-${index}`), options));
  assert.equal(requests, MAX_IMAGE_REVIEWS);
  assert.equal(state.used, MAX_IMAGE_REVIEWS);
  assert.equal(state.entries.size, MAX_IMAGE_REVIEWS);
  assert.deepEqual(outcomes.map(outcome => outcome.resolution),
    ['unresolved', 'unresolved', 'approved', 'unresolved']);
  assert.equal(outcomes.at(-1).attempted, false);
  assert.equal(outcomes.at(-1).reasonCode, 'uncertainty_review_limit');
  assert.equal(createImageReviewState().used, 0);
});

test('untracked identical visuals reuse one review and audit the cache hit', async () => {
  const state = createImageReviewState(), checks = [];
  let requests = 0;
  const tracking = { workflow: 'admin_test', userId: 'administrator' };
  const options = eligible({ reviewState: state, tracking,
    reviewDependencies: { recordProviderCheck: async args => checks.push(args) },
    reviewProvider: async () => { requests++; return compliant(); } });
  const first = await reviewModestyUncertainty(image, options);
  const cached = await reviewModestyUncertainty(Buffer.from(image), options);
  assert.equal(first.resolution, 'approved');
  assert.equal(cached.resolution, 'approved');
  assert.equal(cached.cacheHit, true);
  assert.equal(cached.result.cacheHit, true);
  assert.equal(requests, 1);
  assert.equal(state.used, 1);
  assert.equal(checks.length, 1);
  assert.equal(checks[0].provider, 'gemini');
  assert.equal(checks[0].operation, 'modesty_uncertainty_review');
  assert.equal(checks[0].tracking, tracking);
  assert.equal(checks[0].cacheHit, true);
  assert.equal(checks[0].durationMs, 0);
});

test('untracked in-flight or cross-provider review outcomes cannot start another request', async () => {
  const state = createImageReviewState();
  let complete, requests = 0;
  const response = new Promise(resolve => { complete = resolve; });
  const options = eligible({ reviewState: state,
    reviewProvider: async () => { requests++; return response; } });
  const first = reviewModestyUncertainty(image, options);
  const same = await reviewModestyUncertainty(image, options);
  assert.equal(same.resolution, 'unresolved');
  assert.equal(same.attempted, false);
  assert.equal(same.reasonCode, 'operation_outcome_unknown');
  const differentProviderOptions = { ...options, requireOpenAI: true,
    modestyVerification: uncertain(), geminiModestyVerification: compliant() };
  const different = await reviewModestyUncertainty(image, differentProviderOptions);
  assert.equal(different.provider, 'openai');
  assert.equal(different.attempted, false);
  assert.equal(different.resolution, 'unresolved');
  assert.equal(different.reasonCode, 'uncertainty_review_limit');
  assert.equal(requests, 1);
  assert.equal(state.used, 1);
  complete(compliant());
  assert.equal((await first).resolution, 'approved');
  const afterCompletion = await reviewModestyUncertainty(image, differentProviderOptions);
  assert.equal(afterCompletion.resolution, 'unresolved');
  assert.equal(afterCompletion.reasonCode, 'uncertainty_review_limit');
  assert.equal(requests, 1);
});

test('a missing or corrupt cached review cannot be replaced by a paid request', async () => {
  for (const result of [null, undefined, 'invalid']) {
    const state = fixture({ reservation: { status: 'cached', result } });
    const outcome = await state.run();
    assert.equal(outcome.resolution, 'unresolved');
    assert.equal(outcome.reasonCode, 'operation_outcome_unknown');
    assert.equal(outcome.attempted, false);
    assert.deepEqual(state.calls.map(call => call.operation), ['reserve']);
  }
});

test('denial, restart with unknown outcome and storage errors never reach a provider', async () => {
  for (const reasonCode of ['uncertainty_review_limit', 'operation_outcome_unknown', 'source_unavailable']) {
    const state = fixture({ reservation: { status: 'stopped', reasonCode } });
    const outcome = await state.run();
    assert.equal(outcome.resolution, 'unresolved');
    assert.equal(outcome.attempted, false);
    assert.equal(outcome.reasonCode, reasonCode);
    assert.deepEqual(state.calls.map(call => call.operation), ['reserve']);
  }
  const failed = fixture({ reserveError: new Error('database unavailable') });
  assert.equal((await failed.run()).reasonCode, 'provider_guard_unavailable');
  assert.deepEqual(failed.calls.map(call => call.operation), ['reserve']);
  const poolFailed = fixture();
  const outcome = await poolFailed.run({ reviewDependencies: {
    getPool: async () => { throw new Error('pool unavailable'); },
  } });
  assert.equal(outcome.reasonCode, 'provider_guard_unavailable');
  assert.equal(poolFailed.calls.length, 0);
});

test('missing or unrecognized reservation acknowledgements cannot bypass the ledger', async () => {
  for (const reservation of [undefined, null, { status: 'busy' }, { status: 'unknown' }]) {
    const state = fixture();
    state.options.reviewDependencies.reserveImageReview = async () => reservation;
    const outcome = await state.run();
    assert.equal(outcome.resolution, 'unresolved');
    assert.equal(outcome.attempted, false);
    assert.equal(outcome.reasonCode, 'provider_guard_unavailable');
    assert.equal(state.calls.length, 0);
  }
});

test('an unconfirmed persistence result cannot approve or block the image', async () => {
  for (const result of [compliant(), violation()]) {
    for (const failure of [{ acknowledged: false }, { finishError: new Error('connection lost') }]) {
      const state = fixture({ result, ...failure });
      const outcome = await state.run();
      assert.equal(outcome.resolution, 'unresolved');
      assert.equal(outcome.reasonCode, 'provider_guard_unavailable');
      assert.deepEqual(state.calls.map(call => call.operation), ['reserve', 'provider', 'finish']);
    }
  }
});

test('disabled reviews and expired signals make no storage or provider requests', async t => {
  const previous = process.env.MODERATION_UNCERTAINTY_REVIEW_ENABLED;
  t.after(() => {
    if (previous === undefined) delete process.env.MODERATION_UNCERTAINTY_REVIEW_ENABLED;
    else process.env.MODERATION_UNCERTAINTY_REVIEW_ENABLED = previous;
  });
  process.env.MODERATION_UNCERTAINTY_REVIEW_ENABLED = ' FALSE ';
  const disabled = fixture();
  assert.equal((await disabled.run()).reasonCode, 'uncertainty_review_disabled');
  assert.equal(disabled.calls.length, 0);
  process.env.MODERATION_UNCERTAINTY_REVIEW_ENABLED = 'true';
  const abort = new AbortController();
  abort.abort();
  const expired = fixture();
  const outcome = await expired.run({ signal: abort.signal });
  assert.equal(outcome.reasonCode, 'deadline_exceeded');
  assert.equal(outcome.attempted, false);
  assert.equal(expired.calls.length, 0);
});

function sqlFixture({ fileExists = true, existing, used = 0, insertError } = {}) {
  const queries = [];
  let released = false;
  const client = { async query(sql, args) {
    queries.push({ sql, args });
    if (sql.startsWith('SELECT id FROM stored_files')) return { rows: fileExists ? [{ id: fileId }] : [] };
    if (sql.startsWith('SELECT provider,status,result')) return { rows: existing ? [existing] : [] };
    if (sql.startsWith('SELECT count(*)')) return { rows: [{ used }] };
    if (sql.startsWith('INSERT INTO image_modesty_uncertainty_reviews') && insertError) throw insertError;
    return { rows: [] };
  }, release() { released = true; } };
  const pool = { connect: async () => client };
  const args = { storedFileId: fileId, contentSha256: createHash('sha256').update(image).digest('hex'),
    reviewVersion: REVIEW_VERSION, provider: 'gemini' };
  return { pool, args, queries, released: () => released,
    run: () => reserveImageReview(pool, args) };
}

test('image reservation locks its stored file before lookup and commits exactly one reservation', async () => {
  const state = sqlFixture();
  const reservation = await state.run();
  assert.equal(reservation.status, 'reserved');
  assert.match(reservation.id, /^[a-f0-9-]{36}$/);
  assert.equal(state.queries[0].sql, 'BEGIN');
  assert.match(state.queries[1].sql, /FOR UPDATE/);
  assert.equal(state.queries[1].args[0], fileId);
  assert.match(state.queries[2].sql, /content_sha256=\$2 AND review_version=\$3/);
  const insert = state.queries.find(query => query.sql.startsWith('INSERT'));
  assert.deepEqual(insert.args.slice(1), [fileId, state.args.contentSha256, REVIEW_VERSION, 'gemini']);
  assert.equal(state.queries.at(-1).sql, 'COMMIT');
  assert.equal(state.released(), true);
});

test('reservation cache survives restart without new insert or count increment', async () => {
  const stored = compliant();
  const state = sqlFixture({ existing: { provider: 'gemini', status: 'completed', result: stored } });
  const result = await state.run();
  assert.deepEqual(result, { status: 'cached', result: stored });
  assert.equal(state.queries.some(query => query.sql.startsWith('INSERT')), false);
  assert.equal(state.queries.some(query => query.sql.startsWith('SELECT count')), false);
  assert.equal(state.queries.at(-1).sql, 'COMMIT');
  assert.equal(state.released(), true);
});

test('concurrent image reservations use their row lock to reserve only once', async () => {
  // Emulate the row lock to exercise concurrent query ordering without a real DB.
  let locked = false, stored, inserts = 0, releases = 0;
  const waiting = [];
  const acquire = async () => {
    if (locked) await new Promise(resolve => waiting.push(resolve));
    else locked = true;
  };
  const unlock = () => {
    if (waiting.length) waiting.shift()();
    else locked = false;
  };
  const pool = { connect: async () => {
    let ownsLock = false;
    return {
      async query(sql, args) {
        if (sql.startsWith('SELECT id FROM stored_files')) {
          assert.match(sql, /FOR UPDATE/);
          await acquire();
          ownsLock = true;
          return { rows: [{ id: fileId }] };
        }
        if (sql.startsWith('SELECT provider,status,result')) {
          assert.equal(ownsLock, true);
          return { rows: stored ? [stored] : [] };
        }
        if (sql.startsWith('SELECT count(*)')) return { rows: [{ used: inserts }] };
        if (sql.startsWith('INSERT INTO image_modesty_uncertainty_reviews')) {
          assert.equal(ownsLock, true);
          assert.equal(stored, undefined);
          stored = { provider: args[4], status: 'reserved' };
          inserts++;
        }
        if ((sql === 'COMMIT' || sql === 'ROLLBACK') && ownsLock) {
          ownsLock = false;
          unlock();
        }
        return { rows: [] };
      },
      release() {
        assert.equal(ownsLock, false);
        releases++;
      },
    };
  } };
  const args = { storedFileId: fileId, contentSha256: createHash('sha256').update(image).digest('hex'),
    reviewVersion: REVIEW_VERSION, provider: 'gemini' };
  const results = await Promise.all([reserveImageReview(pool, args), reserveImageReview(pool, args)]);
  assert.deepEqual(results.map(result => result.status).sort(), ['reserved', 'stopped']);
  assert.equal(results.find(result => result.status === 'stopped').reasonCode, 'operation_outcome_unknown');
  assert.equal(inserts, 1);
  assert.equal(releases, 2);
});

test('reserved, missing cached result and changed provider cannot run again after restart', async () => {
  for (const [existing, reason] of [
    [{ provider: 'gemini', status: 'reserved' }, 'operation_outcome_unknown'],
    [{ provider: 'gemini', status: 'completed', result: null }, 'operation_outcome_unknown'],
    [{ provider: 'openai', status: 'completed', result: compliant() }, 'uncertainty_review_limit'],
  ]) {
    const state = sqlFixture({ existing });
    assert.deepEqual(await state.run(), { status: 'stopped', reasonCode: reason });
    assert.equal(state.queries.some(query => query.sql.startsWith('INSERT')), false);
    assert.equal(state.released(), true);
  }
});

test('image review cap applies across pages/content hashes and always releases the transaction', async () => {
  const state = sqlFixture({ used: MAX_IMAGE_REVIEWS });
  assert.deepEqual(await state.run(), { status: 'stopped', reasonCode: 'uncertainty_review_limit' });
  assert.equal(state.queries.some(query => query.sql.startsWith('INSERT')), false);
  assert.equal(state.queries.at(-1).sql, 'COMMIT');
  assert.equal(state.released(), true);
  const missing = sqlFixture({ fileExists: false });
  assert.equal((await missing.run()).reasonCode, 'source_unavailable');
  assert.equal(missing.queries.at(-1).sql, 'ROLLBACK');
  assert.equal(missing.released(), true);
  const failed = sqlFixture({ insertError: new Error('write failed') });
  await assert.rejects(failed.run(), /write failed/);
  assert.equal(failed.queries.at(-1).sql, 'ROLLBACK');
  assert.equal(failed.released(), true);
});

test('finish persists a serializable result only when the reservation is still open', async () => {
  const queries = [];
  const result = compliant({ signal: new AbortController().signal,
    nested: { signal: new AbortController().signal, evidence: 'retained' } });
  const pool = { query: async (sql, args) => {
    queries.push({ sql, args });
    return { rows: [{ id: 'reservation' }] };
  } };
  assert.equal(await finishImageReview(pool, 'reservation', result), true);
  const persisted = JSON.parse(queries[0].args[0]);
  assert.equal(persisted.signal, undefined);
  assert.deepEqual(persisted.nested, { evidence: 'retained' });
  assert.equal(queries[0].args[1], 'reservation');
  assert.match(queries[0].sql, /status='reserved' RETURNING id/);
  assert.equal(await finishImageReview({ query: async () => ({ rows: [] }) }, 'reservation', result), false);
});

test('stopped image results cannot preserve an old approval or retry flag', () => {
  const stopped = stoppedImageResult('modesty_uncertain', { blocked: true, pending: true,
    retryable: true, classification: { category: 'men', uncertain: false },
    originalEvidence: 'preserved' });
  assert.equal(stopped.blocked, false);
  assert.equal(stopped.pending, false);
  assert.equal(stopped.retryable, false);
  assert.equal(stopped.stopped, true);
  assert.equal(stopped.scanStopped, true);
  assert.equal(stopped.classification.uncertain, true);
  assert.equal(stopped.classification.category, 'men');
  assert.equal(stopped.originalEvidence, 'preserved');
});
