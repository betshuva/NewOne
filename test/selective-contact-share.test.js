const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');

const source = fs.readFileSync(
  path.join(__dirname, '../flutter_app/lib/main.dart'),
  'utf8',
);

test('my contact dialog lets the sender select each shared field', () => {
  const start = source.indexOf('Future<Map<String, String>?> _confirmMyContactShare');
  const end = source.indexOf('Future<Map<String, String>?> _pickGroupSharedContact');
  const dialog = source.slice(start, end);

  assert.match(dialog, /var shareName = contact\['name'\]!\.isNotEmpty/);
  assert.match(dialog, /var sharePhone = contact\['phone'\]!\.isNotEmpty/);
  assert.match(dialog, /var shareEmail = contact\['email'\]!\.isNotEmpty/);
  assert.equal((dialog.match(/CheckboxListTile\(/g) || []).length, 3);
  assert.match(dialog, /final hasSelection = shareName \|\| sharePhone \|\| shareEmail/);
  assert.match(dialog, /onPressed: !hasSelection[\s\S]*?\? null/);
});

test('only selected contact fields are encoded for sending', () => {
  assert.match(source, /if \(shareName\) 'name': contact\['name'\]!/);
  assert.match(source, /if \(sharePhone\) 'phone': contact\['phone'\]!/);
  assert.match(source, /if \(shareEmail\) 'email': contact\['email'\]!/);
  assert.match(source, /return selectedContact/);
});

test('received contact card tolerates omitted fields', () => {
  assert.match(source, /contact\['name'\]\?\.toString\(\) \?\? 'איש קשר'/);
  assert.match(source, /if \(phone\.isNotEmpty\) Text\(phone/);
  assert.match(source, /if \(email\.isNotEmpty\)/);
});

test('shared app friends open in the desktop chat pane without replacing mobile navigation', () => {
  assert.match(
    source,
    /NotificationListener<_OpenSharedContactChatNotification>[\s\S]*?if \(!isDesktop\) return false;[\s\S]*?_desktopRecipient = _users\.firstWhere/,
  );
  assert.match(
    source,
    /openNotification\.dispatch\(context\);[\s\S]*?if \(openNotification\.handledInDesktopPane\) return;[\s\S]*?Navigator\.of\(context\)\.push/,
  );
});
