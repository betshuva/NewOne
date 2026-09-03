const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const source = fs.readFileSync(
  path.join(__dirname, '..', 'flutter_app', 'lib', 'main.dart'), 'utf8');

test('blocked images hide Israel artwork while other warnings keep it', () => {
  assert.match(source,
    /showBlockedArtwork: fileType != 'image'/);
  assert.match(source,
    /showBlockedArtwork:\s*uploadFileType != 'image'/);
  assert.match(source,
    /if \(!isImageFile\)[\s\S]*?_SystemContentWarningArtwork/);
  assert.match(source,
    /uploadFileType != 'image'\)[\s\S]*?_SystemContentWarningArtwork/);
  assert.match(source,
    /else if \(uploadStatus ==\s*'blocked_content'\)\s*const SizedBox\.shrink\(\)/);
  assert.match(source,
    /class _DocumentModerationCard[\s\S]*?_SystemContentWarningArtwork/);
});
