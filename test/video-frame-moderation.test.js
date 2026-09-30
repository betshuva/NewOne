const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { videoDetectedCategories } = require('../server/video-classification');
const { contentAllowedByFilter } = require('../server/content-filter-policy');

const root = path.join(__dirname, '..');
const server = fs.readFileSync(path.join(root, 'server', 'index.js'), 'utf8');
const flutter = fs.readFileSync(path.join(root, 'flutter_app', 'lib', 'main.dart'), 'utf8');
const analyzer = fs.readFileSync(
  path.join(root, 'video_moderation', 'app', 'analyzer.py'), 'utf8');

async function scanFrames(frames, overrides = {}, options = {}) {
  const source = server.slice(server.indexOf('async function scanVideo('),
    server.indexOf('function normalizeUploadFileName('));
  const context = {
    Buffer, Blob, FormData, AbortSignal, process: { env: {} }, console,
    VIDEO_MODERATION_URL: 'http://video.test', MAX_VIDEO_SECONDS: 5400,
    sourceBlob: require('../server/upload-file-source').sourceBlob,
    videoDetectedCategories,
    stoppedVideoResult: require('../server/video-scan-controller').stoppedVideoResult,
    fetch: async (_url, request) => {
      assert.equal(request.body.has('sample_interval_seconds'), false);
      return { ok: true, json: async () => ({
      duration_seconds: 1.69, sampled_frames: frames.length, decision: 'allowed',
      labels: { people: 0.99, man: 0.99, woman: 0.99, child: 0.99, landscape: 0.99 },
      findings: [{ label: 'woman', confidence: 0.99, timestamp_seconds: 0 }],
      frame_samples: frames.map((_, index) => ({ timestamp_seconds: index * 0.5,
        jpeg_base64: Buffer.alloc(40, index).toString('base64') })),
      ...overrides,
    }) }; },
    scanStaticImage: async (buffer, frameOptions) => {
      options.onFrame?.(buffer[0], frameOptions);
      return frames[buffer[0]];
    },
  };
  vm.createContext(context);
  const scan = vm.runInContext(`${source}\nscanVideo`, context);
  return JSON.parse(JSON.stringify(await scan(Buffer.from('video'), 'clip.mp4', 'video/mp4', options)));
}

const nonHuman = () => ({ blocked: false, pending: false, classification: {
  category: 'nonHumanImages', detectedCategories: ['nonHumanImages'], uncertain: false,
} });

test('verified nonhuman frames override preliminary video people guesses', async () => {
  const result = await scanFrames(Array.from({ length: 4 }, nonHuman));
  assert.equal(result.blocked, false);
  assert.equal(result.pending, false);
  assert.deepEqual(result.classification.detectedCategories, ['video', 'nonHumanImages']);
  assert.equal(result.classification.labels.people, 0.99);
  assert.equal(contentAllowedByFilter({ video: true, women: false }, 'video',
    result.classification), true);
  assert.equal(contentAllowedByFilter({ video: false }, 'video',
    result.classification), false);
});

test('all verified demographics contribute to video receiving filters', async () => {
  const result = await scanFrames([
    nonHuman(),
    { classification: { category: 'men', detectedCategories: ['men'] } },
    { classification: { category: 'women', detectedCategories: ['women', 'children'] } },
  ]);
  assert.deepEqual(result.classification.detectedCategories,
    ['video', 'nonHumanImages', 'men', 'women', 'children']);
  assert.equal(contentAllowedByFilter({ video: true, women: false }, 'video',
    result.classification), false);
});

test('unresolved and unsafe frames cannot become approved video', async () => {
  const pending = await scanFrames([nonHuman(), { pending: true,
    reason: 'Person review unavailable', classification: { uncertain: true } }]);
  assert.equal(pending.pending, true);
  assert.equal(pending.classification.uncertain, true);
  const blocked = await scanFrames([nonHuman(), { blocked: true,
    blockedBy: 'explicit_content', reason: 'Unsafe frame' }]);
  assert.equal(blocked.blocked, true);
  assert.equal(blocked.blockedBy, 'video_frame:explicit_content');
  const unsafeVideo = await scanFrames([nonHuman()], { decision: 'blocked' });
  assert.equal(unsafeVideo.blocked, true);
  assert.equal(unsafeVideo.blockedBy, 'video_safety');
});

test('missing video samples remain pending', async () => {
  const result = await scanFrames([], { sampled_frames: 1 });
  assert.equal(result.pending, true);
});

test('budgeted scans freeze frames before providers and carry a unique frame index', async () => {
  const seen = [];
  let frozen = false;
  const result = await scanFrames([nonHuman(), nonHuman()], {}, {
    tracking: { videoBudget: { scanId: 'scan', leaseToken: 'lease' } },
    async freezeFrames(samples, count) {
      assert.equal(samples.length, count);
      frozen = true;
    },
    onFrame(index, options) {
      assert.equal(frozen, true);
      assert.equal(options.tracking.videoBudget.frameIndex, index);
      seen.push(index);
    },
  });
  assert.equal(result.pending, false);
  assert.deepEqual(seen, [0, 1]);
});

test('a stopped required check halts new frame work and never becomes approved', async () => {
  let started = 0;
  const result = await scanFrames(Array.from({ length: 20 }, () => ({
    scanStopped: true, reasonCode: 'credit_balance_exhausted',
  })), {}, {
    tracking: { videoBudget: { scanId: 'scan', leaseToken: 'lease' } },
    freezeFrames: async () => null,
    onFrame() { started++; },
  });
  assert.equal(result.scanStopped, true);
  assert.equal(result.pending, false);
  assert.equal(result.reasonCode, 'credit_balance_exhausted');
  assert.ok(started <= 8, 'only initially in-flight frames may have started');
});

test('a changed manifest refuses all frame work', async () => {
  const result = await scanFrames([nonHuman()], {}, {
    freezeFrames: async () => require('../server/video-scan-controller')
      .stoppedVideoResult('frame_manifest_changed'),
    onFrame() { assert.fail('no provider may start for a changed manifest'); },
  });
  assert.equal(result.scanStopped, true);
});

test('uploaded videos allow ninety minutes while recording remains two minutes', () => {
  assert.match(server, /const MAX_VIDEO_SECONDS = 90 \* 60/);
  assert.match(server, /blockedBy: 'video_duration'/);
  assert.match(flutter, /const _maxVideoDuration = Duration\(minutes: 2\)/);
  assert.match(flutter, /ניתן לשלוח סרטון באורך של עד 90 דקות/);
  assert.match(flutter, /_maxUploadedVideoDuration = Duration\(minutes: 90\)/);
});

test('scheduled video samples use the full still-image moderation path', () => {
  assert.match(server, /await scanStaticImage\(imageBuffer/);
  assert.match(server, /video_frame:\$\{frameResult\.blockedBy/);
  assert.match(server, /fullyScannedFrames/);
  assert.match(analyzer, /sample_video/);
  assert.match(server, /videoFrameResult/);
  assert.match(server, /videoFrameSummary/);
  assert.match(flutter, /תמונות שנבדקו מתוך סרטונים/);
});


test('ninety-minute video is accepted while longer video is refused', async () => {
  const accepted = await scanFrames([nonHuman()], { duration_seconds: 5400 });
  assert.equal(accepted.blocked, false);
  assert.equal(accepted.pending, false);
  const refused = await scanFrames([nonHuman()], { duration_seconds: 5401 });
  assert.equal(refused.blocked, true);
  assert.equal(refused.blockedBy, 'video_duration');
});


test('more than twenty selected frames never reach a provider', async () => {
  let calls = 0;
  const result = await scanFrames(Array.from({length: 21}, nonHuman), {}, {
    onFrame() { calls++; },
  });
  assert.equal(calls, 0);
  assert.equal(result.pending, true);
});

test('first and last selected frames are checked before the interior', async () => {
  const order = [];
  await scanFrames(Array.from({length: 20}, nonHuman), {}, {
    onFrame(index) { order.push(index); },
  });
  assert.deepEqual(order.slice(0, 2), [0, 19]);
  assert.equal(new Set(order).size, 20);
});
