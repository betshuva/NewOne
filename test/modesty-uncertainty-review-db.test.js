'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createHash, randomUUID } = require('node:crypto');
const { Client, Pool } = require('pg');
const review = require('../server/modesty-uncertainty-review');

const dbOptions = { skip: process.env.RUN_DB_TESTS !== '1' || !process.env.VIDEO_SCAN_TEST_DATABASE_URL };
const digest = value => createHash('sha256').update(String(value)).digest('hex');
const compliant = { available: true, status: 'completed', decision: 'modest', confidence: 0.97,
  violationClearlyVisible: false, visibleAreasDecision: 'compliant',
  uncertaintyReason: 'none', visibleEvidence: 'Visible clothing is compliant', model: 'review-model' };

async function fixture(t) {
  const url = new URL(process.env.VIDEO_SCAN_TEST_DATABASE_URL);
  assert.ok(['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname), 'Only a disposable local database is allowed');
  assert.match(url.pathname, /test/i, 'An explicitly named test database is required');
  const owner = new Client({ connectionString: url.href, ssl: false });
  await owner.connect();
  const schema = `image_review_test_${randomUUID().replaceAll('-', '')}`;
  await owner.query(`CREATE SCHEMA "${schema}"`);
  const config = { connectionString: url.href, ssl: false, options: `-c search_path=${schema}`, max: 12 };
  const pool = new Pool(config), recoveredPool = new Pool(config);
  t.after(async () => {
    await pool.end();
    await recoveredPool.end();
    await owner.query(`DROP SCHEMA "${schema}" CASCADE`);
    await owner.end();
  });
  await pool.query('CREATE TABLE stored_files (id uuid PRIMARY KEY)');
  await pool.query(review.SCHEMA);
  await pool.query(review.SCHEMA);
  const storedFileId = randomUUID();
  await pool.query('INSERT INTO stored_files(id) VALUES($1)', [storedFileId]);
  const identity = { storedFileId, contentSha256: digest('image'),
    reviewVersion: 'test-v1', provider: 'gemini' };
  const reserve = (overrides = {}, db = pool) => review.reserveImageReview(db, { ...identity, ...overrides });
  const count = async () => (await pool.query('SELECT count(*)::integer AS n FROM image_modesty_uncertainty_reviews')).rows[0].n;
  return { pool, recoveredPool, identity, reserve, count };
}

test('concurrent image reviews reserve exactly once and reuse the result after reconnect', dbOptions, async t => {
  const f = await fixture(t);
  const reservations = await Promise.all(Array.from({ length: 24 }, () => f.reserve()));
  const granted = reservations.filter(result => result.status === 'reserved');
  assert.equal(granted.length, 1);
  assert.ok(reservations.filter(result => result.status !== 'reserved')
    .every(result => result.reasonCode === 'operation_outcome_unknown'));
  assert.equal(await f.count(), 1);
  assert.equal(await review.finishImageReview(f.pool, granted[0].id, compliant), true);
  const recovered = await f.reserve({}, f.recoveredPool);
  assert.equal(recovered.status, 'cached');
  assert.deepEqual(recovered.result, compliant);
  assert.equal(await f.count(), 1);
});

test('failed image reviews stay charged after reconnect and completion cannot be overwritten', dbOptions, async t => {
  const f = await fixture(t);
  const reservation = await f.reserve();
  const failure = { available: false, status: 'error', errorCode: 'REQUEST_FAILED' };
  assert.equal(await review.finishImageReview(f.pool, reservation.id, failure), true);
  assert.equal(await review.finishImageReview(f.pool, reservation.id, compliant), false);
  const recovered = await f.reserve({}, f.recoveredPool);
  assert.equal(recovered.status, 'cached');
  assert.deepEqual(recovered.result, failure);
  assert.equal(await f.count(), 1);
});

test('changing image review provider cannot pay for a second attempt of the same content', dbOptions, async t => {
  const f = await fixture(t);
  const reservation = await f.reserve();
  await review.finishImageReview(f.pool, reservation.id, compliant);
  const duplicate = await f.reserve({ provider: 'openai' });
  assert.equal(duplicate.reasonCode, 'uncertainty_review_limit');
  assert.equal(await f.count(), 1);
});

test('image pages and policy versions share three stored-file slots under concurrent locks', dbOptions, async t => {
  const f = await fixture(t);
  const reservations = await Promise.all(Array.from({ length: 9 }, (_, index) =>
    f.reserve({ contentSha256: digest(`page-${index}`), reviewVersion: `version-${index}`,
      provider: index % 2 ? 'openai' : 'gemini' })));
  assert.equal(reservations.filter(result => result.status === 'reserved').length, 3);
  assert.ok(reservations.filter(result => result.status !== 'reserved')
    .every(result => result.reasonCode === 'uncertainty_review_limit'));
  assert.equal(await f.count(), 3);
});

test('missing stored files cannot reserve and deleting a synthetic file removes its own ledger', dbOptions, async t => {
  const f = await fixture(t);
  assert.equal((await f.reserve({ storedFileId: randomUUID() })).reasonCode, 'source_unavailable');
  assert.equal(await f.count(), 0);
  assert.equal((await f.reserve()).status, 'reserved');
  await f.pool.query('DELETE FROM stored_files WHERE id=$1', [f.identity.storedFileId]);
  assert.equal(await f.count(), 0);
});

test('wrapper cache reuse across reconnect does not repeat the image provider call', dbOptions, async t => {
  const f = await fixture(t);
  let requests = 0;
  const options = { verifiedPeople: true,
    classification: { category: 'women', uncertain: false },
    googleSafeSearch: { available: true, blocked: false, uncertain: false },
    localSafety: { available: true, wouldBlock: false }, requireOpenAI: false,
    geminiModestyVerification: { ...compliant, decision: 'uncertain',
      visibleAreasDecision: 'uncertain', uncertaintyReason: 'visible_area_ambiguous' },
    tracking: { storedFileId: f.identity.storedFileId },
    reviewDependencies: { pool: f.pool },
    reviewProvider: async () => { requests++; return compliant; } };
  const first = await review.reviewModestyUncertainty(Buffer.from('test image'), options);
  assert.equal(first.resolution, 'approved');
  const recovered = await review.reviewModestyUncertainty(Buffer.from('test image'),
    { ...options, reviewDependencies: { pool: f.recoveredPool } });
  assert.equal(recovered.resolution, 'approved');
  assert.equal(recovered.cacheHit, true);
  assert.equal(requests, 1);
  assert.equal(await f.count(), 1);
});
