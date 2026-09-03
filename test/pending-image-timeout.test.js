'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const test = require('node:test');

const server = fs.readFileSync(require.resolve('../server/index'), 'utf8');
const app = fs.readFileSync(require.resolve('../flutter_app/lib/main.dart'), 'utf8');

test('pending image scans expire automatically without affecting other file types', () => {
  const cleanup = server.slice(
    server.indexOf('async function cancelExpiredPendingImageScans'),
    server.indexOf('function requestPendingScanRetry'));
  assert.match(cleanup, /file_type='image'/);
  assert.match(cleanup, /interval '3 minutes'/);
  assert.match(cleanup, /moderation_status='pending'/);
  assert.match(cleanup, /'scan:cancelled'/);
  assert.match(cleanup, /pending_image_scan_expired/);
  assert.doesNotMatch(cleanup, /file_type='audio'|file_type='video'/);
  assert.match(server, /setInterval\(cancelExpiredPendingImageScans, 15 \* 1000\)/);
});

test('private and group chats remove automatically cancelled scan cards', () => {
  assert.equal((app.match(/on\('scan:cancelled'/g) || []).length, 2);
  assert.equal((app.match(/off\('scan:cancelled'/g) || []).length, 2);
  assert.match(app, /message\['status'\] == 'pending_scan'[\s\S]*?הסריקה בוטלה אוטומטית/);
});
