'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const server = fs.readFileSync(
  path.join(__dirname, '..', 'server', 'index.js'), 'utf8');
const client = fs.readFileSync(
  path.join(__dirname, '..', 'flutter_app', 'lib', 'main.dart'), 'utf8');

test('HTTP group sends notify the sender so the conversation time refreshes', () => {
  const start = server.indexOf("app.post('/api/groups/:id/messages'");
  const end = server.indexOf("app.get('/api/groups/:id/messages'", start);
  const route = server.slice(start, end);
  assert.match(route, /relay\(senderId, 'group:message', payload\)/);
  assert.match(route,
    /relay\(recipient\.id, 'group:message', recipientPayload\)/);
});

test('group file bubbles display the persisted server timestamp', () => {
  const start = client.indexOf('Future<void> _applyGroupUploadResult');
  const end = client.indexOf('void _showGroupBlockedDialog', start);
  const uploadResult = client.slice(start, end);
  assert.match(uploadResult,
    /sendData\['createdAt'\] != null[\s\S]*?_formatTime\(sendData\['createdAt'\]\)/);
  assert.match(uploadResult,
    /'createdAt': sendData\['createdAt'\]\?\.toString\(\)/);
});
