'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const server = fs.readFileSync(path.join(root, 'server', 'index.js'), 'utf8');
const app = fs.readFileSync(path.join(root, 'flutter_app', 'lib', 'main.dart'), 'utf8');

test('new transcripts are never created or exposed; old blocked data keeps its retention policy', () => {
  assert.doesNotMatch(server, /transcriptEncrypted:\s*transcript|decryptAudioTranscript|audio_transcript:|audioTranscript:/);
  assert.match(server, /blocked_content_expires_at=now\(\)\+interval '2 minutes'/);
  assert.match(server, /moderation_details #- '\{audio,transcriptEncrypted\}'/);
  assert.match(server, /await fs\.unlink\(absolutePath\)/);
  assert.match(server, /sf\.user_id=\$1[^]*moderation_status IN \('pending','rejected','stopped'\)/);
  assert.doesNotMatch(server, /console\.log\([^\n]*transcriptEncrypted/);
});

test('moderation keeps metadata history and supports deliberate admin actions', () => {
  assert.match(server, /CREATE TABLE IF NOT EXISTS moderation_incidents/);
  assert.match(server, /CREATE TABLE IF NOT EXISTS moderation_actions/);
  assert.match(server, /\['warn','suspend','block','unblock'\]/);
  assert.match(server, /ACCOUNT_BLOCKED/);
  assert.match(server, /ACCOUNT_SUSPENDED/);
  assert.match(app, /text: 'בטיחות'/);
  assert.match(app, /חסימה לצמיתות/);
});

test('voice messages do not expose transcript controls or transcription notices', () => {
  assert.doesNotMatch(app, /תמלול|מתמלל|תומלל|audioTranscript|audio_transcript/);
  assert.match(app, /הקלטה קולית/);
});
