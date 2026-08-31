const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const source = fs.readFileSync(
  path.join(__dirname, '..', 'flutter_app', 'lib', 'main.dart'),
  'utf8',
);

test('the conversations header exposes direct group creation', () => {
  const start = source.indexOf('class _ConversationsScreenState');
  const end = source.indexOf('class GroupsScreen', start);
  assert.ok(start >= 0 && end > start);
  const conversations = source.slice(start, end);

  assert.match(conversations, /Icons\.group_add_outlined/);
  assert.match(conversations, /tooltip: 'יצירת קבוצה חדשה'/);
  assert.match(conversations, /onPressed: _createGroup/);
  assert.match(conversations, /CreateGroupScreen\(token: widget\.token\)/);
});
