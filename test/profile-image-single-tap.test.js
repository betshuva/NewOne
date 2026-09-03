'use strict';

const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');

const source = fs.readFileSync(
  path.join(__dirname, '..', 'flutter_app', 'lib', 'main.dart'), 'utf8');

test('profile photos expand with one tap while emoji avatars do not', () => {
  const start = source.indexOf('class UserAvatar extends StatelessWidget');
  const end = source.indexOf('class AvatarPickerSheet', start);
  const avatar = source.slice(start, end);

  assert.match(avatar,
    /onTap: picUrl != null && !_isEmojiAvatar\(picUrl\)[\s\S]*?_showExpandedImage\(context\)/);
  assert.doesNotMatch(avatar, /onDoubleTap:/);
  assert.match(avatar, /if \(picUrl == null \|\| _isEmojiAvatar\(picUrl\)\) return/);
});
