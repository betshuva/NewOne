const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const source = fs.readFileSync(
  path.join(__dirname, '..', 'flutter_app', 'lib', 'main.dart'),
  'utf8',
);

test('the web group form allows creating a group without invited members', () => {
  const start = source.indexOf('class _CreateGroupScreenState');
  const end = source.indexOf('class ConversationsScreen', start);
  assert.ok(start >= 0 && end > start);
  const form = source.slice(start, end);

  assert.doesNotMatch(form, /יש לבחור לפחות חבר אחד לקבוצה/);
  assert.match(form, /תיווצר קבוצה לעצמי/);
  assert.match(form, /צור קבוצה לעצמי/);
  assert.match(form, /'is_self': _selectedIds\.isEmpty/);
  assert.match(form, /final group = Map<String, dynamic>\.from\(decoded\)/);
  assert.match(form, /Future\.wait\(_selectedIds\.map\([\s\S]*?\/members/);
  // Invitations stay pending, so the server's active-member count is authoritative.
  assert.doesNotMatch(form, /group\['member_count'\]\s*=/);
  assert.match(form, /Navigator\.pop\(context, group\)/);
});
