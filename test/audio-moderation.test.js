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
  assert.match(workerSource, /language="he"/);
});

test('audio stays pending until its transcript passes harmful-text moderation', () => {
  const source = fs.readFileSync(path.join(root, 'server', 'index.js'), 'utf8');
  assert.match(source, /allowed\.dbType === 'audio'[\s\S]*pending: true/);
  assert.match(source,
    /INSERT INTO pending_scans[\s\S]*?requestPendingScanRetry\(\)/);
  assert.match(source,
    /function requestPendingScanRetry\(\)[\s\S]*?setImmediate\([\s\S]*?retryPendingScans\(\)/);
  assert.match(source,
    /finally \{[\s\S]*?retryPendingScans\.running = false;[\s\S]*?pendingScanRetryRequested/);
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

test('attachment menus identify the private recipient or group', () => {
  const source = fs.readFileSync(
    path.join(root, 'flutter_app', 'lib', 'main.dart'), 'utf8');
  assert.match(source, /שיתוף קובץ עם \$recipientName/);
  assert.match(source, /שיתוף קובץ בקבוצה \$groupName/);
});

test('attachment menus use the approved compact five-row grid', () => {
  const source = fs.readFileSync(
    path.join(root, 'flutter_app', 'lib', 'main.dart'), 'utf8');
  assert.match(source,
    /class _AttachGrid[\s\S]*?rowSizes = \[3, 2, 2, 1, 2\]/);
  assert.ok((source.match(/_AttachGrid\(/g) || []).length >= 3);
  assert.match(source,
    /כל הקבצים עוברים בדיקת בטיחות וסינון לפני השליחה/);
});

test('small chat images expose the three-dot message menu', () => {
  const source = fs.readFileSync(
    path.join(root, 'flutter_app', 'lib', 'main.dart'), 'utf8');
  assert.match(source, /class _SmallImageOptionsButton/);
  assert.match(source, /Icons\.more_vert/);
  assert.match(source, /_SmallImageOptionsButton\([\s\S]*onMessageOptions!/);
  assert.match(source, /_SmallImageOptionsButton\([\s\S]*_showMessageOptions/);
});
