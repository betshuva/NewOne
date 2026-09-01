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

test('recipient policy hides attachment choices that can never be delivered', () => {
  assert.match(source, /if \(_recipientAllowsImages\) \.\.\.\[/);
  assert.match(source, /if \(_recipientAllowsVideo\) \.\.\.\[/);
  assert.match(source, /if \(_recipientAllowsText\)\s+_AttachOption\(\s*icon: Icons\.picture_as_pdf_outlined/);
  assert.match(source, /if \(_recipientAllowsText\) \.\.\.\[\s*_AttachOption\(\s*icon: Icons\.contact_phone_outlined/);
});

test('upload actions recheck recipient policy and text composer is disabled', () => {
  assert.match(source, /final blockedByRecipient = switch \(fileType\)/);
  assert.match(source, /'video' => !_recipientAllowsVideo/);
  assert.match(source, /'image' => !_recipientAllowsImages/);
  assert.match(source, /'document' => !_recipientAllowsText/);
  assert.match(source, /enabled: _recipientAllowsText/);
  assert.match(source, /onTap: _recipientAllowsText \? _send : null/);
});
