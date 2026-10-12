'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createUnicodeEmojiModerator } = require('../server/unicode-emoji-moderation');

const approved = category => ({ blocked: false,
  classification: { category, detectedCategories: [category], uncertain: false } });
const glyph = (code, knownApproved = false) => ({ code, emoji: code, knownApproved });
function fixture({ emojis = [glyph('unknown')], results = [approved('nonHumanImages')],
  loadArtwork = async () => Buffer.from('synthetic canonical image'), ...settings } = {}) {
  const scans = [], checks = [];
  const moderator = createUnicodeEmojiModerator({ extractEmoji: () => emojis,
    loadArtwork, scanImage: async (bytes, options) => {
      scans.push({ bytes, options });
      return results[Math.min(scans.length - 1, results.length - 1)];
    }, moderationVersion: 'test-policy-v1', artworkVersion: 'fixture-art-v1',
    recordCheck: async event => checks.push(event), ...settings });
  return { ...moderator, scans, checks };
}

test('ordinary text and previously approved catalog symbols do not invoke providers', async () => {
  for (const emojis of [[], [glyph('known', true)]]) {
    const f = fixture({ emojis });
    assert.equal(await f.inspect('original text'), null);
    assert.equal(f.scans.length, 0);
  }
});

test('unknown symbols are scanned as artwork and their aggregate preserves all categories', async () => {
  const f = fixture({ emojis: [glyph('landscape'), glyph('woman')],
    results: [approved('nonHumanImages'), approved('women')] });
  const text = 'unchanged 👩🌄';
  const result = await f.inspect(text, { userId: 'sender' });
  assert.equal(text, 'unchanged 👩🌄');
  assert.equal(result.inlineEmoji, true);
  assert.deepEqual(result.detectedCategories, ['nonHumanImages', 'women']);
  assert.equal(result.uncertain, false);
  assert.equal(result.moderationVersion, 'test-policy-v1');
  assert.match(result.artworkHash, /^[a-f0-9]{64}$/);
  assert.equal(f.scans[0].options.tracking.workflow, 'unicode_emoji');
});

test('approved classification cache is independent of user and receiving policy', async () => {
  const f = fixture();
  const first = await f.inspect('a', { userId: 'first' });
  const second = await f.inspect('b', { userId: 'second' });
  assert.deepEqual(second, first);
  assert.equal(f.scans.length, 1);
  assert.equal(f.checks[0].cacheHit, true);
  assert.equal(f.checks[0].tracking.userId, 'second');
  assert.equal(f.checks[0].result.blocked, false);
});

test('cache expiry and bounded eviction require a fresh scan', async () => {
  let time = 1;
  const emojis = [glyph('first')];
  const f = fixture({ emojis, now: () => time, cacheTtlMs: 10, cacheLimit: 1 });
  await f.inspect('a'); time = 12; await f.inspect('a');
  emojis.splice(0, 1, glyph('second')); await f.inspect('b');
  emojis.splice(0, 1, glyph('first')); await f.inspect('a');
  assert.equal(f.scans.length, 4);
});

test('concurrent callers share one provider scan without sharing their policy decisions', async () => {
  let finish;
  const waiting = new Promise(resolve => { finish = resolve; });
  const f = fixture({ scanImage: async () => { await waiting; return approved('women'); } });
  const first = f.inspect('a', { userId: 'first' });
  const second = f.inspect('b', { userId: 'second' });
  finish();
  const results = await Promise.all([first, second]);
  assert.deepEqual(results[0], results[1]);
  assert.equal(f.checks.length, 1);
  assert.equal(f.checks[0].tracking.userId, 'second');
});

test('blocked symbols are rejected and may reuse an exact artwork decision', async () => {
  const f = fixture({ results: [{ blocked: true, blockedBy: 'unsafe_content' }] });
  for (let attempt = 0; attempt < 2; attempt++)
    await assert.rejects(f.inspect('unsafe'), error =>
      error.status === 422 && error.code === 'EMOJI_CONTENT_BLOCKED');
  assert.equal(f.scans.length, 1);
});

test('pending, stopped, uncertain and malformed scans never approve or enter the long cache', async () => {
  for (const result of [null, {}, { classification: { category: 'nonHumanImages' } },
    { ...approved('nonHumanImages'), pending: true },
    { ...approved('nonHumanImages'), scanStopped: true },
    { ...approved('people'), classification: { category: 'people', uncertain: true } },
    approved('unexpected')]) {
    const f = fixture({ results: [result] });
    for (let attempt = 0; attempt < 2; attempt++)
      await assert.rejects(f.inspect('x'), error =>
        error.status === 503 && error.code === 'EMOJI_SCAN_PENDING');
    assert.equal(f.scans.length, 2);
  }
});

test('artwork failures leave text unsent and do not expose internal provider errors', async () => {
  for (const code of ['UNSUPPORTED_EMOJI', 'EMOJI_ARTWORK_UNAVAILABLE', undefined]) {
    const f = fixture({ loadArtwork: async () => {
      throw Object.assign(new Error('private upstream error details'), { code });
    } });
    await assert.rejects(f.inspect('x'), error => {
      assert(!error.message.includes('private'));
      return error.code === (code === 'UNSUPPORTED_EMOJI'
        ? 'UNSUPPORTED_EMOJI' : 'EMOJI_SCAN_PENDING');
    });
    assert.equal(f.scans.length, 0);
  }
});

test('too many unfamiliar symbols are rejected before any expensive scan', async () => {
  const f = fixture({ emojis: [glyph('1'), glyph('2'), glyph('3')], maxUnfamiliarEmoji: 2 });
  await assert.rejects(f.inspect('x'), error => error.code === 'EMOJI_SCAN_LIMIT');
  assert.equal(f.scans.length, 0);
});
