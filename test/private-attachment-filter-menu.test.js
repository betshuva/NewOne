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

test('private and group menus pass policy to the shared capture choices', () => {
  assert.match(source, /imagesAllowed: _recipientAllowsImages/);
  assert.match(source, /videoAllowed: _recipientAllowsVideo/);
  assert.match(source, /textAllowed: _recipientAllowsText/);
  assert.match(source, /imagesAllowed: _groupAllowsImages/);
  assert.match(source, /videoAllowed: _groupAllowsVideo/);
  assert.match(source, /textAllowed: _groupAllowsText/);
  assert.match(source, /'חסום בסינון הנמען'/);
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
