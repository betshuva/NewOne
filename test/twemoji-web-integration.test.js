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

test('the expression picker renders Twemoji while messages keep Unicode', () => {
  assert.match(source, /SvgPicture\.asset/);
  assert.match(source, /_chooseEmoji\(emoji\)/);
  assert.match(source, /emoji_allowlist\.json/);
  assert.match(source, /LicenseRegistry\.addLicense/);
  assert.match(source, /ATTRIBUTION\.txt/);
});

test('Twemoji categories wrap instead of being clipped horizontally', () => {
  const pickerStart = source.indexOf('Widget _buildTwemojiPicker()');
  const pickerEnd = source.indexOf(
    'Widget _buildRemoteExpressionPicker',
    pickerStart,
  );
  const picker = source.slice(pickerStart, pickerEnd);

  assert.match(picker, /Wrap\(/);
  assert.match(picker, /runSpacing: 6/);
  assert.doesNotMatch(picker, /scrollDirection: Axis\.horizontal/);
});
