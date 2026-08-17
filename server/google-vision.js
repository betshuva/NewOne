'use strict';

const sharp = require('sharp');

const GOOGLE_VISION_ENDPOINT = 'https://vision.googleapis.com/v1/images:annotate';
const MAX_INLINE_IMAGE_BYTES = 7 * 1024 * 1024;
const MAX_INPUT_PIXELS = 120_000_000;
const DEFAULT_TIMEOUT_MS = 15000;
const DEFAULT_BLOCK_THRESHOLD = 'POSSIBLE';
const MODERATION_CATEGORIES = ['adult', 'racy'];
const ALL_CATEGORIES = ['adult', 'racy', 'violence', 'medical', 'spoof'];
const LIKELIHOOD_RANK = Object.freeze({
  UNKNOWN: 0,
  VERY_UNLIKELY: 1,
  UNLIKELY: 2,
  POSSIBLE: 3,
  LIKELY: 4,
  VERY_LIKELY: 5,
});

function googleSafeSearchConfigured(apiKey = process.env.GOOGLE_VISION_API_KEY) {
  return typeof apiKey === 'string' && apiKey.trim().length > 0;
}

function normalizeBlockThreshold(value) {
  const normalized = String(value || '').trim().toUpperCase();
  return ['POSSIBLE', 'LIKELY', 'VERY_LIKELY'].includes(normalized)
    ? normalized
    : DEFAULT_BLOCK_THRESHOLD;
}

function normalizeCategories(annotation) {
  return Object.fromEntries(ALL_CATEGORIES.map(category => {
    const likelihood = String(annotation?.[category] || 'UNKNOWN').toUpperCase();
    return [category, Object.hasOwn(LIKELIHOOD_RANK, likelihood) ? likelihood : 'UNKNOWN'];
  }));
}

function evaluateSafeSearch(annotation, threshold = DEFAULT_BLOCK_THRESHOLD) {
  const categories = normalizeCategories(annotation);
  const normalizedThreshold = normalizeBlockThreshold(threshold);
  const thresholdRank = LIKELIHOOD_RANK[normalizedThreshold];
  const unknownCategories = MODERATION_CATEGORIES.filter(
    category => categories[category] === 'UNKNOWN',
  );
  const blockedCategories = MODERATION_CATEGORIES.filter(
    category => LIKELIHOOD_RANK[categories[category]] >= thresholdRank,
  );
  return {
    categories,
    threshold: normalizedThreshold,
    blocked: blockedCategories.length > 0,
    blockedCategories,
    uncertain: unknownCategories.length > 0,
    unknownCategories,
  };
}

function safeErrorMessage(error) {
  const message = String(error?.message || error || 'Google Vision request failed');
  return message.replace(/[\r\n]+/g, ' ').slice(0, 300);
}

async function prepareInlineImage(buffer) {
  if (buffer.length <= MAX_INLINE_IMAGE_BYTES) {
    return { buffer, transformed: false, inputBytes: buffer.length, sentBytes: buffer.length };
  }

  const convert = (width, quality) => sharp(buffer, {
    failOn: 'error',
    // Modern phone cameras commonly produce 48–108 MP files. This still caps
    // decompression work while allowing those accepted uploads to be resized.
    limitInputPixels: MAX_INPUT_PIXELS,
  })
    .rotate()
    .resize({ width, height: width, fit: 'inside', withoutEnlargement: true })
    .jpeg({ quality, chromaSubsampling: '4:2:0' })
    .toBuffer();

  try {
    let prepared = await convert(2048, 82);
    if (prepared.length > MAX_INLINE_IMAGE_BYTES) prepared = await convert(1600, 70);
    if (prepared.length > MAX_INLINE_IMAGE_BYTES) {
      const error = new Error('Prepared image is still too large for Google Vision');
      error.code = 'IMAGE_TOO_LARGE';
      throw error;
    }
    return {
      buffer: prepared,
      transformed: true,
      inputBytes: buffer.length,
      sentBytes: prepared.length,
    };
  } catch (error) {
    if (error.code !== 'IMAGE_TOO_LARGE') error.code = 'IMAGE_PREPARATION_FAILED';
    throw error;
  }
}

async function scanGoogleSafeSearch(buffer, options = {}) {
  const apiKey = String(options.apiKey ?? process.env.GOOGLE_VISION_API_KEY ?? '').trim();
  const threshold = normalizeBlockThreshold(
    options.threshold ?? process.env.GOOGLE_SAFESEARCH_BLOCK_THRESHOLD,
  );
  const configured = googleSafeSearchConfigured(apiKey);
  const startedAt = performance.now();
  const baseResult = {
    provider: 'google-cloud-vision',
    configured,
    available: false,
    enforced: configured,
    threshold,
    categories: null,
    blocked: false,
    blockedCategories: [],
    uncertain: false,
    durationMs: 0,
  };

  if (!configured) {
    return { ...baseResult, status: 'not_configured' };
  }

  if (!Buffer.isBuffer(buffer) || buffer.length === 0) {
    return {
      ...baseResult,
      status: 'error',
      errorCode: 'INVALID_IMAGE',
      error: 'Image buffer is empty',
      durationMs: Math.round(performance.now() - startedAt),
    };
  }

  const fetchImpl = options.fetchImpl || globalThis.fetch;
  const timeoutMs = Number(options.timeoutMs ?? process.env.GOOGLE_VISION_TIMEOUT_MS) ||
    DEFAULT_TIMEOUT_MS;

  try {
    // REST embeds bytes as base64. A derived JPEG is created in memory when
    // necessary so 7–10 MiB uploads fit the 10 MiB JSON limit. The stored and
    // delivered original is never modified.
    const prepared = await prepareInlineImage(buffer);
    const response = await fetchImpl(GOOGLE_VISION_ENDPOINT, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        'X-Goog-Api-Key': apiKey,
      },
      body: JSON.stringify({
        requests: [{
          image: { content: prepared.buffer.toString('base64') },
          features: [{ type: 'SAFE_SEARCH_DETECTION' }],
        }],
      }),
      signal: AbortSignal.timeout(Math.max(1000, Math.min(timeoutMs, 60000))),
    });
    const data = await response.json().catch(() => ({}));
    const annotationResponse = data.responses?.[0];
    const apiError = data.error || annotationResponse?.error;
    if (!response.ok || apiError) {
      const error = new Error(apiError?.message || `Google Vision HTTP ${response.status}`);
      error.code = apiError?.status || apiError?.code || `HTTP_${response.status}`;
      throw error;
    }
    if (!annotationResponse?.safeSearchAnnotation) {
      const error = new Error('Google Vision returned no SafeSearch annotation');
      error.code = 'MISSING_ANNOTATION';
      throw error;
    }

    const evaluation = evaluateSafeSearch(annotationResponse.safeSearchAnnotation, threshold);
    return {
      ...baseResult,
      ...evaluation,
      available: true,
      inputBytes: prepared.inputBytes,
      sentBytes: prepared.sentBytes,
      transformed: prepared.transformed,
      status: evaluation.uncertain ? 'review' : evaluation.blocked ? 'blocked' : 'passed',
      durationMs: Math.round(performance.now() - startedAt),
    };
  } catch (error) {
    const errorCode = String(error?.code || error?.name || 'REQUEST_FAILED');
    return {
      ...baseResult,
      status: 'error',
      errorCode,
      error: safeErrorMessage(error),
      retryable: !['IMAGE_TOO_LARGE', 'IMAGE_PREPARATION_FAILED'].includes(errorCode),
      durationMs: Math.round(performance.now() - startedAt),
    };
  }
}

module.exports = {
  ALL_CATEGORIES,
  LIKELIHOOD_RANK,
  MAX_INLINE_IMAGE_BYTES,
  MAX_INPUT_PIXELS,
  evaluateSafeSearch,
  googleSafeSearchConfigured,
  normalizeBlockThreshold,
  prepareInlineImage,
  scanGoogleSafeSearch,
};
