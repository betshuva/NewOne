'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const test = require('node:test');

const server = fs.readFileSync(require.resolve('../server/index'), 'utf8');
const audio = fs.readFileSync(require.resolve('../server/audio-moderation'), 'utf8');
const compose = fs.readFileSync(
  require.resolve('../docker-compose.shadow-classification.yml'), 'utf8');

test('shadow classification is queued persistently for classified images', () => {
  assert.match(server, /CREATE TABLE IF NOT EXISTS classification_shadow_jobs/);
  assert.match(server, /CREATE TRIGGER stored_files_shadow_classification/);
  assert.match(server, /ON CONFLICT\(stored_file_id\) DO NOTHING/);
});

test('shadow worker yields to urgent scanning and audio transcription', () => {
  assert.match(server, /isAudioTranscriptionBusy\(\) \|\| retryPendingScans\.running/);
  assert.match(server, /SELECT EXISTS\([\s\S]*?FROM pending_scans[\s\S]*?10 minutes/);
  assert.match(server, /os\.loadavg\(\)\[0\]/);
  assert.match(audio, /function isAudioTranscriptionBusy\(\)/);
});

test('shadow result is metadata only and explicitly marked shadow-only', () => {
  const worker = server.slice(server.indexOf('async function runClassificationShadowJob'),
    server.indexOf('runClassificationShadowJob.running = false;'));
  assert.match(worker, /mode: 'shadow_only'/);
  assert.match(worker, /\{classificationShadow\}/);
  assert.doesNotMatch(worker, /moderation_status|classificationStats|classification\}/);
});

test('OpenCV shadow service stays local and reports both independent checks', () => {
  assert.match(compose, /127\.0\.0\.1:5005:5000/);
  const app = fs.readFileSync(require.resolve('../shadow_classification/app.py'), 'utf8');
  assert.match(app, /HOGDescriptor_getDefaultPeopleDetector/);
  assert.match(app, /haarcascade_frontalface_default/);
  assert.match(app, /hogPersonDetected/);
  assert.match(app, /haarFaceDetected/);
});

test('admin statistics expose independent shadow accuracy', () => {
  assert.match(server, /shadowSummary\('hogPersonDetected', 'hogDurationMs'\)/);
  assert.match(server, /shadowSummary\('haarFaceDetected', 'haarDurationMs'\)/);
  assert.match(server, /recentShadowScans: recentResult\.rows\.map/);
  const app = fs.readFileSync(require.resolve('../flutter_app/lib/main.dart'), 'utf8');
  assert.match(app, /בדיקות ופעולות שבוצעו מאוחר יותר/);
  assert.match(app, /רענון תוצאות/);
});
