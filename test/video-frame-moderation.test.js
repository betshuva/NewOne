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
  path.join(root, '..', 'video-moderation-server', 'app', 'analyzer.py'), 'utf8');

async function scanFrames(frames, overrides = {}) {
  const source = server.slice(server.indexOf('async function scanVideo('),
    server.indexOf('function normalizeUploadFileName('));
  const context = {
    Buffer, Blob, FormData, AbortSignal, process: { env: {} }, console,
    VIDEO_MODERATION_URL: 'http://video.test', MAX_VIDEO_SECONDS: 30,
    videoDetectedCategories,
    fetch: async () => ({ ok: true, json: async () => ({
      duration_seconds: 1.69, sampled_frames: frames.length, decision: 'allowed',
      labels: { people: 0.99, man: 0.99, woman: 0.99, child: 0.99, landscape: 0.99 },
      findings: [{ label: 'woman', confidence: 0.99, timestamp_seconds: 0 }],
      frame_samples: frames.map((_, index) => ({ timestamp_seconds: index * 0.5,
        jpeg_base64: Buffer.alloc(40, index).toString('base64') })),
      ...overrides,
    }) }),
    scanStaticImage: async buffer => frames[buffer[0]],
  };
  vm.createContext(context);
  const scan = vm.runInContext(`${source}\nscanVideo`, context);
  return JSON.parse(JSON.stringify(await scan(Buffer.from('video'), 'clip.mp4', 'video/mp4')));
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

test('videos are limited to thirty seconds in the UI and authoritative server scan', () => {
  assert.match(server, /const MAX_VIDEO_SECONDS = 30/);
  assert.match(server, /blockedBy: 'video_duration'/);
  assert.match(flutter, /const _maxVideoDuration = Duration\(seconds: 30\)/);
  assert.match(flutter, /ניתן לשלוח סרטון באורך של עד 30 שניות/);
  assert.match(analyzer, /MAX_VIDEO_SECONDS.*30/);
});

test('video samples and scene changes use the full still-image moderation path', () => {
  assert.match(server, /await scanStaticImage\(imageBuffer/);
  assert.match(server, /video_frame:\$\{frameResult\.blockedBy/);
  assert.match(server, /fullyScannedFrames/);
  assert.match(analyzer, /SCENE_CHANGE_THRESHOLD/);
  assert.match(analyzer, /reason = "interval" if scheduled else "scene_change"/);
  assert.match(server, /videoFrameResult/);
  assert.match(server, /videoFrameSummary/);
  assert.match(flutter, /תמונות שנבדקו מתוך סרטונים/);
});
