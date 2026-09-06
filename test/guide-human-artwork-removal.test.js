const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const client = fs.readFileSync(path.join(root, 'flutter_app/lib/main.dart'), 'utf8');
const pubspec = fs.readFileSync(path.join(root, 'flutter_app/pubspec.yaml'), 'utf8');

test('built-in guide screens no longer reference child artwork', () => {
  assert.doesNotMatch(client, /assets\/guide\/aviel-guide\.jpg/);
  assert.doesNotMatch(client, /assets\/stickers\/aviel-guide\//);
  assert.doesNotMatch(pubspec, /assets\/stickers\/aviel-guide\//);
  assert.doesNotMatch(client, /_buildAvielStickerPicker/);
});

test('child guide artwork is absent from the application source bundle', () => {
  assert.equal(fs.existsSync(path.join(
    root, 'flutter_app/assets/guide/aviel-guide.jpg')), false);
  assert.equal(fs.existsSync(path.join(
    root, 'flutter_app/assets/stickers/aviel-guide')), false);
});
