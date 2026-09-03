const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const source = fs.readFileSync(
  path.join(__dirname, '..', 'flutter_app', 'lib', 'main.dart'), 'utf8');

test('phone contact sharing supports live name, phone and email search', () => {
  const start = source.indexOf('Future<Map<String, String>?> _pickPhoneContact');
  const end = source.indexOf('Future<Map<String, String>?> _pickAppFriend', start);
  const picker = source.slice(start, end);
  assert.match(picker, /חיפוש איש קשר/);
  assert.match(picker, /contact\.displayName/);
  assert.match(picker, /contact\.phones\.map/);
  assert.match(picker, /contact\.emails\.map/);
  assert.match(picker, /לא נמצאו אנשי קשר/);
});
