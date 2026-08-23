const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const test = require('node:test');
const sharp = require('sharp');

const {
  MAX_INLINE_IMAGE_BYTES,
  evaluateSafeSearch,
  scanGoogleSafeSearch,
} = require('../server/google-vision');

function response(body, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
  };
}

test('SafeSearch does not block a weak POSSIBLE result by default', () => {
  const result = evaluateSafeSearch({
    adult: 'UNLIKELY',
    racy: 'POSSIBLE',
    violence: 'VERY_LIKELY',
    medical: 'UNLIKELY',
    spoof: 'VERY_UNLIKELY',
  });

  assert.equal(result.blocked, false);
  assert.deepEqual(result.blockedCategories, []);
  assert.equal(result.categories.violence, 'VERY_LIKELY');
});

test('SafeSearch lets racy LIKELY pass but blocks adult LIKELY', () => {
  const result = evaluateSafeSearch({
    adult: 'UNLIKELY', racy: 'LIKELY', violence: 'UNLIKELY',
    medical: 'UNLIKELY', spoof: 'UNLIKELY',
  });

  assert.equal(result.blocked, false);
  assert.deepEqual(result.blockedCategories, []);

  const adult = evaluateSafeSearch({ adult: 'LIKELY', racy: 'UNLIKELY' });
  assert.equal(adult.blocked, true);
  assert.deepEqual(adult.blockedCategories, ['adult']);
});

test('SafeSearch blocks racy only at VERY_LIKELY', () => {
  const result = evaluateSafeSearch({
    adult: 'UNLIKELY', racy: 'VERY_LIKELY', violence: 'UNLIKELY',
    medical: 'UNLIKELY', spoof: 'UNLIKELY',
  });

  assert.equal(result.blocked, true);
  assert.deepEqual(result.blockedCategories, ['racy']);
});

test('SafeSearch treats UNKNOWN in a moderation category as uncertain', () => {
  const result = evaluateSafeSearch({ adult: 'UNKNOWN', racy: 'UNLIKELY' });

  assert.equal(result.blocked, false);
  assert.equal(result.uncertain, true);
  assert.deepEqual(result.unknownCategories, ['adult']);
});

test('Google scan is explicitly unavailable when no server key is configured', async () => {
  const result = await scanGoogleSafeSearch(Buffer.from('image'), { apiKey: '' });

  assert.equal(result.configured, false);
  assert.equal(result.available, false);
  assert.equal(result.status, 'not_configured');
});

test('Google scan requests only SAFE_SEARCH_DETECTION and keeps the key out of the URL', async () => {
  let request;
  const result = await scanGoogleSafeSearch(Buffer.from('image'), {
    apiKey: 'server-key',
    fetchImpl: async (url, options) => {
      request = { url, options };
      return response({ responses: [{ safeSearchAnnotation: {
        adult: 'VERY_UNLIKELY', racy: 'UNLIKELY', violence: 'POSSIBLE',
        medical: 'UNLIKELY', spoof: 'VERY_UNLIKELY',
      } }] });
    },
  });

  assert.equal(result.available, true);
  assert.equal(result.blocked, false);
  assert.equal(result.status, 'passed');
  assert.doesNotMatch(request.url, /server-key/);
  assert.equal(request.options.headers['X-Goog-Api-Key'], 'server-key');
  const body = JSON.parse(request.options.body);
  assert.deepEqual(body.requests[0].features, [{ type: 'SAFE_SEARCH_DETECTION' }]);
});

test('per-image Google API errors fail closed instead of becoming an approval', async () => {
  const result = await scanGoogleSafeSearch(Buffer.from('image'), {
    apiKey: 'server-key',
    fetchImpl: async () => response({
      responses: [{ error: { code: 8, status: 'RESOURCE_EXHAUSTED', message: 'quota' } }],
    }),
  });

  assert.equal(result.configured, true);
  assert.equal(result.available, false);
  assert.equal(result.status, 'error');
  assert.equal(result.errorCode, 'RESOURCE_EXHAUSTED');
});

test('large uploads are converted for Google without modifying the original buffer', async () => {
  const pixels = crypto.randomBytes(2600 * 2600 * 3);
  const original = await sharp(pixels, { raw: { width: 2600, height: 2600, channels: 3 } })
    .jpeg({ quality: 100 })
    .toBuffer();
  assert.ok(original.length > MAX_INLINE_IMAGE_BYTES);
  const before = Buffer.from(original);
  let called = false;
  let sentBytes = 0;
  const result = await scanGoogleSafeSearch(original, {
    apiKey: 'server-key',
    fetchImpl: async (_url, options) => {
      called = true;
      const body = JSON.parse(options.body);
      sentBytes = Buffer.from(body.requests[0].image.content, 'base64').length;
      return response({ responses: [{ safeSearchAnnotation: {
        adult: 'UNLIKELY', racy: 'UNLIKELY', violence: 'UNLIKELY',
        medical: 'UNLIKELY', spoof: 'UNLIKELY',
      } }] });
    },
  });

  assert.equal(called, true);
  assert.equal(result.available, true);
  assert.equal(result.transformed, true);
  assert.ok(sentBytes <= MAX_INLINE_IMAGE_BYTES);
  assert.deepEqual(original, before);
});
