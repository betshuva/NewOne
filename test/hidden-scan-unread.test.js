'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const server = fs.readFileSync(
  path.join(__dirname, '..', 'server', 'index.js'), 'utf8');
const client = fs.readFileSync(
  path.join(__dirname, '..', 'flutter_app', 'lib', 'main.dart'), 'utf8');

test('hidden scan-bot messages are excluded from unread server totals', () => {
  const start = server.indexOf("app.get('/api/messages/unread'");
  const end = server.indexOf("app.get('/api/groups/unread'", start);
  const route = server.slice(start, end);
  assert.match(route, /m\.sender_id <> \$2/);
  assert.match(route, /\[req\.user\.id, SCAN_BOT_ID\]/);
});

test('hidden scan-bot realtime messages do not increment the chat badge', () => {
  const start = client.indexOf("_socket!.on('chat:message'");
  const end = client.indexOf("_socket!.on('chat:typing'", start);
  const handler = client.slice(start, end);
  assert.match(handler, /fromId == kScanBotId/);
  assert.match(handler, /_unreadCounts\[fromId\]/);
});
