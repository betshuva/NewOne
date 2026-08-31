'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const root = path.join(__dirname, '..');

test('audio moderation is local, serialized and limited to two minutes', () => {
  const moduleSource = fs.readFileSync(
    path.join(root, 'server', 'audio-moderation.js'), 'utf8');
  const workerSource = fs.readFileSync(
    path.join(root, 'scripts', 'audio_transcription.py'), 'utf8');
  assert.match(moduleSource, /MAX_AUDIO_SECONDS = 120/);
  assert.match(moduleSource, /transcriptionQueue\.then\(task, task\)/);
  assert.match(moduleSource, /WHISPER_MODEL.*'small'/);
  assert.match(moduleSource, /compute_type is configured by the local worker|audio_transcription\.py/);
  assert.match(workerSource, /compute_type="int8"/);
  assert.match(workerSource, /device="cpu"/);
  assert.match(workerSource, /vad_filter=True/);
});

test('audio stays pending until its transcript passes harmful-text moderation', () => {
  const source = fs.readFileSync(path.join(root, 'server', 'index.js'), 'utf8');
  assert.match(source, /allowed\.dbType === 'audio'[\s\S]*pending: true/);
  assert.match(source, /row\.file_type === 'audio'[\s\S]*scanAudio\(buffer, row\.file_name\)/);
  assert.match(source, /moderateChatText\(transcript\)/);
  assert.match(source, /transcriptHash: transcriptDigest\(transcript\)/);
  assert.doesNotMatch(source, /audio:\s*\{[^}]*transcript[,}]/s);
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

test('voice recording stops automatically at the server duration limit', () => {
  const source = fs.readFileSync(
    path.join(root, 'flutter_app', 'lib', 'main.dart'), 'utf8');
  assert.equal((source.match(/_recordSeconds >= 120/g) || []).length, 2);
  assert.match(source, /ההקלטה נעצרה לאחר מגבלת שתי דקות/);
});
