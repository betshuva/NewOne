const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const server = fs.readFileSync(path.join(root, 'server', 'index.js'), 'utf8');
const flutter = fs.readFileSync(path.join(root, 'flutter_app', 'lib', 'main.dart'), 'utf8');
const analyzer = fs.readFileSync(
  path.join(root, '..', 'video-moderation-server', 'app', 'analyzer.py'), 'utf8');

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
