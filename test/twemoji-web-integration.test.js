const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const root = path.join(__dirname, '..');
const appRoot = path.join(root, 'flutter_app');
const source = fs.readFileSync(path.join(appRoot, 'lib', 'main.dart'), 'utf8');
const allowlist = JSON.parse(
  fs.readFileSync(path.join(appRoot, 'assets', 'twemoji', 'emoji_allowlist.json')),
);

test('the approved Twemoji allowlist and every referenced SVG are bundled', () => {
  assert.equal(allowlist.length, 171);
  for (const item of allowlist) {
    assert.ok(item.emoji && item.category && item.label_he && item.twemoji_code);
    assert.ok(
      fs.existsSync(path.join(
        appRoot,
        'assets',
        'twemoji',
        'svg',
        `${item.twemoji_code}.svg`,
      )),
      `missing SVG for ${item.emoji}`,
    );
  }
});

test('the replacement picker exposes only the user-provided sticker catalog', () => {
  const picker = source.slice(source.indexOf('class _ExpressionPickerSheetState'), source.indexOf('class _RemoteExpressionGrid'));
  assert.doesNotMatch(picker, /TabBar|_buildTwemojiPicker|_legacyBuild|_buildAvielStickerPicker/);
  assert.match(picker, /user-stickers/);
  assert.match(picker, /assets\/stickers\/user-catalog\.json/);
  assert.match(source, /LicenseRegistry\.addLicense/);
});
