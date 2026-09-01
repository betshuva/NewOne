const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');

const source = fs.readFileSync(
  path.join(__dirname, '../flutter_app/lib/main.dart'),
  'utf8',
);

test('explicit audio type wins over the ambiguous webm extension', () => {
  const start = source.indexOf('String? _normalizeIncomingFileType');
  const end = source.indexOf('// ── Local notifications setup', start);
  const normalizer = source.slice(start, end);
  const audioGuard = normalizer.indexOf("t == 'audio'");
  const videoExtensionCheck = normalizer.indexOf('_hasVideoExtension(fileUrl)');

  assert.ok(audioGuard >= 0, 'audio type guard is missing');
  assert.ok(videoExtensionCheck >= 0, 'video extension fallback is missing');
  assert.ok(
    audioGuard < videoExtensionCheck,
    'audio type must be checked before .webm is treated as video',
  );
  assert.match(normalizer, /if \(t == 'audio' \|\| t\.startsWith\('audio\/'\)\)[\s\S]*?return 'audio'/);
});

test('audio and real video still use their dedicated players', () => {
  assert.match(source, /if \(isAudioFile\)[\s\S]*?VoiceMessagePlayer\(/);
  assert.match(source, /else if \(isVideoFile\)[\s\S]*?NativeWebVideoPlayer\(/);
  assert.match(source, /_voiceFileName = 'voice_message\.webm'/);
});

test('voice player animates while loading and supports retry', () => {
  assert.match(source, /with SingleTickerProviderStateMixin/);
  assert.match(source, /AnimationController _loadingController/);
  assert.match(source, /animation: _loadingController/);
  assert.match(source, /onPressed: _loading[\s\S]*?_loadFailed[\s\S]*?_prepareSource/);
  assert.match(source, /טוען הקלטה\.\.\./);
  assert.match(source, /הטעינה נכשלה — לחצו לניסיון חוזר/);
});
