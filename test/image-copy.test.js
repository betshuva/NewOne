'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const main = fs.readFileSync(
  path.join(__dirname, '..', 'flutter_app', 'lib', 'main.dart'), 'utf8');
const web = fs.readFileSync(
  path.join(__dirname, '..', 'flutter_app', 'lib', 'image_clipboard_web.dart'),
  'utf8');
const index = fs.readFileSync(
  path.join(__dirname, '..', 'flutter_app', 'web', 'index.html'), 'utf8');

test('private, group and full-screen image views offer image copy', () => {
  const labels = main.match(/Text\('העתק תמונה'\)/g) || [];
  assert.equal(labels.length, 2);
  assert.match(main, /tooltip: 'העתק תמונה'/);
  assert.match(main, /Future<void> _copyChatImage/);
  assert.match(main, /copyImageToClipboard\(_absoluteMediaUrl\(fileUrl\)\)/);
});

test('web image copy converts to PNG and reports clipboard permission errors', () => {
  assert.match(web, /@JS\('betshuvaCopyImage'\)/);
  assert.match(index, /window\.betshuvaCopyImage/);
  assert.match(index, /createImageBitmap/);
  assert.match(index, /'image\/png'/);
  assert.match(index, /new ClipboardItem/);
  assert.match(index, /navigator\.clipboard\.write/);
  assert.match(index, /הדפדפן חסם גישה ללוח/);
});
