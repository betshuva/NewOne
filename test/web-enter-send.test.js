'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const source = fs.readFileSync(
  path.join(__dirname, '..', 'flutter_app', 'lib', 'main.dart'), 'utf8');

test('web Enter sends non-empty private, Israel and group messages', () => {
  const keyboardHandler = source.slice(
    source.indexOf('KeyEventResult _handleMessageInputNavigation'),
    source.indexOf('Future<Map<String, String>?> _manualSharedContact'));
  assert.match(keyboardHandler, /kIsWeb/);
  assert.match(keyboardHandler, /event is KeyDownEvent/);
  assert.match(keyboardHandler, /LogicalKeyboardKey\.enter/);
  assert.match(keyboardHandler, /controller\.text\.trim\(\)\.isNotEmpty/);
  assert.match(keyboardHandler, /onWebEnter\?\.call\(\)/);
  assert.match(source, /onWebEnter: _send/g);
});

test('Shift+Enter remains available for a new line in both chat inputs', () => {
  assert.match(source, /!HardwareKeyboard\.instance\.isShiftPressed/);
  assert.ok((source.match(/textInputAction: TextInputAction\.newline/g) || [])
    .length >= 2);
  assert.ok((source.match(/maxLines: 4/g) || []).length >= 2);
});
