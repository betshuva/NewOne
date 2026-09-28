'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const root = path.join(__dirname, '..');

test('audio processing is duration-only and cannot invoke speech recognition', () => {
  const audio = require('../server/audio-moderation');
  assert.equal(audio.MAX_AUDIO_BYTES, 150 * 1024 * 1024);
  assert.equal(audio.transcribeAudio, undefined);
  const worker = fs.readFileSync(path.join(root, 'scripts/audio_transcription.py'), 'utf8');
  assert.doesNotMatch(worker, /WhisperModel|model.transcribe/);
  const source = fs.readFileSync(path.join(root, 'server/index.js'), 'utf8');
  assert.doesNotMatch(source, /transcribeAudio|decryptAudioTranscript/);
  assert.match(source, /scanResult = approvedAudioResult\(audioDurationSeconds\)/);
});

test('delayed audio delivery handles private and group recipients separately', () => {
  const source = fs.readFileSync(path.join(root, 'server', 'index.js'), 'utf8');
  const queue = source.slice(
    source.indexOf('async function retryPendingScans'),
    source.indexOf('const GOVERNMENT_LOCALITIES_RESOURCE'));
  const privateDelivery = queue.slice(
    queue.indexOf('if (row.to_user_id) {'),
    queue.indexOf('if (row.group_id && pendingGroup) {'));
  const groupDelivery = queue.slice(queue.indexOf('if (row.group_id && pendingGroup) {'));
  assert.doesNotMatch(privateDelivery, /buildGroupDeliveryPlan/);
  assert.match(groupDelivery, /const deliveryPlan = await buildGroupDeliveryPlan/);
  assert.match(groupDelivery, /delivery_summary=\$1/);
});

test('voice recording has no timed stop and displays elapsed time', () => {
  const source = fs.readFileSync(
    path.join(root, 'flutter_app', 'lib', 'main.dart'), 'utf8');
  assert.doesNotMatch(source, /_recordSeconds >= 120/);
  assert.equal((source.match(/זמן הקלטה:/g) || []).length, 2);
});

test('private and group objects expose the shared menu and quick reactions', () => {
  const source = fs.readFileSync(path.join(root, 'flutter_app/lib/main.dart'), 'utf8');
  assert.equal((source.match(/actions: MessageActionBar\(/g) || []).length, 2);
});

function audioScanner(probeAudio) {
  const source = fs.readFileSync(path.join(root, 'server/index.js'), 'utf8');
  const functionSource = source.slice(source.indexOf('function approvedAudioResult('),
    source.indexOf('function accountModerationError('));
  return require('node:vm').runInNewContext(`${functionSource};scanAudio`, {
    probeAudio, console: { error() {} },
    transcribeAudio() { throw new Error('must not transcribe'); },
  });
}

test('queued audio passes duration checks without creating a transcript or provider call', async () => {
  const scan = audioScanner(async () => ({durationSeconds: 5, transcript: 'must be ignored'}));
  const result = await scan(Buffer.from('audio'), 'voice.mp3');
  assert.equal(result.blocked, false);assert.equal(result.pending, false);
  assert.equal(result.audio.transcription, 'disabled');
  assert.equal(result.audio.durationSeconds, 5);
  assert.equal(result.audio.transcriptEncrypted, undefined);
});

test('long audio is accepted while unreadable audio still waits for validation', async () => {
  const long = audioScanner(async () => ({ durationSeconds: 121 }));
  assert.equal((await long(Buffer.from('audio'), 'voice.mp3')).blocked, false);
  const unavailable = audioScanner(async () => { throw new Error('offline'); });
  assert.equal((await unavailable(Buffer.from('audio'), 'voice.mp3')).pending, true);
});
