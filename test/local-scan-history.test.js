'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { moderationCheckSummary } = require('../server/moderation-check-summary');
const { sanitizeAuditDetails } = require('../server/system-audit-catalog');
const source = fs.readFileSync(require.resolve('../server/index.js'), 'utf8');
const fileId = '00000000-0000-4000-8000-000000000100';
const previewId = '00000000-0000-4000-8000-000000000101';

function load(name, endMarker, context) {
  const start = source.indexOf(`async function ${name}(`);
  const end = source.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start);
  return vm.runInNewContext(`${source.slice(start, end)};${name}`, { console, ...context });
}

test('local image stages share the exact scanned preview and video frame context', async () => {
  const checks = [], image = Buffer.from('same scanned frame');
  let saves = 0;
  const tracking = { storedFileId: fileId, videoBudget: { frameIndex: 2, timestampSeconds: 1.25 } };
  const scan = load('scanStaticImage', '// Increment whenever moderation models', {
    process: { env: {} }, MODERATION_CACHE_VERSION: 'test',
    cachedScanPreviews: require('../server/cached-scan-previews'),
    openAIModerationEnabled: () => true,
    openAIModerationRequired: () => true,
    moderationProviderPolicy: () => 'google_openai_gemini',
    disabledModerationProviderResult: () => assert.fail('OpenAI is enabled in this fixture'),
    getAuditContext: () => ({ operationId: 'audit' }), getPool: async () => 'pool',
    async saveAuditScanPreview(pool, args) {
      assert.equal(pool, 'pool'); assert.equal(args.buffer, image);
      assert.equal(args.storedFileId, fileId); saves++; return previewId;
    },
    recordProviderCheck: async event => checks.push(event),
    classifyClip: async () => ({}),
    classifyImageContent: async () => ({ category: 'nonHumanImages', detectedCategories: ['nonHumanImages'] }),
    classifyLocalSafety: async () => ({ available: true, wouldBlock: false }),
    googleSafeSearchConfigured: () => true, normalizeBlockThreshold: () => 'LIKELY',
    scanGoogleSafeSearch: async (_bytes, options) => {
      assert.equal(options.tracking.scanPreviewId, previewId);
      return { available: true, blocked: false };
    },
    verifyPersonClassification: async (_bytes, classification, options) => {
      assert.equal(options.tracking.scanPreviewId, previewId);
      return { classification, verification: { providers: {} } };
    },
    videoProviderStop: () => null,
    imageClassificationOutcome: result => ({ ...result, blocked: false }),
  });
  const result = await scan(image, { tracking });
  assert.equal(result.blocked, false);
  assert.equal(saves, 1);
  assert.equal(tracking.scanPreviewId, undefined, 'caller tracking remains unmodified');
  assert.deepEqual(checks.map(event => event.operation), ['local_explicit_content',
    'local_classification', 'local_safety', 'modesty', 'modesty']);
  for (const event of checks) {
    assert.equal(event.tracking.scanPreviewId, previewId);
    const summary = moderationCheckSummary(event.provider, event.operation, event.result, event.tracking);
    assert.equal(summary.frameIndex, 2);
    assert.equal(summary.frameTimestampMs, 1250);
    if (event.operation === 'modesty') {
      assert.equal(summary.checkOutcome, 'skipped');
      assert.ok(!summary.checkFindings.includes('modest'));
    }
  }
});

test('animated image frames retain source tracking for their individual previews', async () => {
  const frames = [Buffer.from('frame one'), Buffer.from('frame two')];
  const options = { tracking: { storedFileId: fileId, userId: 'user' } };
  const seen = [];
  const scan = load('scanImage', 'async function scanDocument', {
    isTrustedBuiltinExpression: async () => false,
    isPotentiallyAnimatedImage: () => true,
    sharp: (_bytes, args) => args.pages ? {
      png() { return this; }, toBuffer: async () => frames[args.page],
    } : { metadata: async () => ({ pages: frames.length }) },
    scanStaticImage: async (bytes, context) => {
      seen.push(bytes);
      assert.equal(context, options);
      assert.equal(context.tracking.scanPreviewId, undefined);
      return { blocked: false };
    },
  });
  const result = await scan(Buffer.from('animated image'), options);
  assert.equal(result.blocked, false);
  assert.equal(result.framesScanned, 2);
  assert.deepEqual(seen, frames);
});

test('unavailable document scans record failure without changing the original outcome', async () => {
  const events = [];
  const scanDocument = load('scanDocument', 'const mailer =', {
    BLOCKED_WORDS: [], scanImage() {},
    scanDocumentContent: async () => { throw new Error('decode failed'); },
    recordProviderCheck: async event => events.push(event),
  });
  await assert.rejects(scanDocument(Buffer.from('document'), 'application/pdf'), /decode failed/);
  assert.equal(moderationCheckSummary('local', events[0].operation, events[0].result).checkOutcome, 'failed');
});
