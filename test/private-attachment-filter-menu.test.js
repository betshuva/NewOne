'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const source = fs.readFileSync(
  path.join(__dirname, '..', 'flutter_app', 'lib', 'main.dart'), 'utf8');

test('private attachment menu refreshes recipient policy before opening', () => {
  assert.match(source, /Future<void> _showAttachMenu\(\) async \{\s*await _loadRecipientReceivingFilter\(\)/);
});

test('recipient policy keeps every attachment visible with an allowed or blocked status', () => {
  assert.match(source, /allowed: _recipientAllowsImages/);
  assert.match(source, /allowed: _recipientAllowsVideo/);
  assert.match(source, /allowed: _recipientAllowsText/);
  assert.match(source, /'מותר לנמען'/);
  assert.match(source, /'חסום בסינון הנמען'/);
});

test('group attachment menu refreshes policy and marks every option', () => {
  assert.match(source,
    /Future<void> _showAttachMenu\(\) async \{\s*if \(!await _ensureCanSendToGroup\(\)\) return;\s*await _loadGroupReceivingFilter\(\)/);
  assert.match(source, /allowed: _groupAllowsImages/);
  assert.match(source, /allowed: _groupAllowsVideo/);
  assert.match(source, /allowed: _groupAllowsText/);
  assert.match(source, /'מותר • לפי סינון אישי'/);
  assert.match(source, /'חסום בסינון הקבוצה'/);
  assert.match(source, /if \(!await _groupAllowsFileType\(fileType\)\) return/);
});

test('upload actions recheck recipient policy and text composer is disabled', () => {
  assert.match(source, /final blockedByRecipient = switch \(fileType\)/);
  assert.match(source, /'video' => !_recipientAllowsVideo/);
  assert.match(source, /'image' => !_recipientAllowsImages/);
  assert.match(source, /'audio' \|\| 'document' => !_recipientAllowsText/);
  assert.match(source, /enabled: _recipientAllowsText/);
  assert.match(source, /onTap: _recipientAllowsText \? _send : null/);
});
