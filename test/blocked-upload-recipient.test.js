const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');

const source = fs.readFileSync(
  path.join(__dirname, '../flutter_app/lib/main.dart'),
  'utf8',
);

test('only destination-filtered private uploads identify the recipient', () => {
  assert.match(source, /final String\? recipientName/);
  assert.match(source, /final bool destinationFilterRejected/);
  assert.match(source, /Text\('נמען: \$\{recipientName!\.trim\(\)\}'/);
  assert.match(source,
    /if \(destinationFilterRejected &&[\s\S]*?recipientName\?\.trim\(\)\.isNotEmpty == true\)/);
  assert.match(source,
    /recipientName: message\['forwardAllowed'\] == true[\s\S]*?isMe \? recipientName : senderName[\s\S]*?: null/);
  assert.match(
    source,
    /recipientName: widget\.recipient\['name'\][\s\S]*?\.toString\(\)/,
  );
});

test('only destination-filtered group uploads identify the group', () => {
  assert.match(
    source,
    /recipientName: uploadStatus ==[\s\S]*?'rejected_scan' &&[\s\S]*?msg\['forwardAllowed'\] ==\s*true[\s\S]*?'קבוצת \$\{widget\.group\['name'\]/,
  );
  assert.match(source,
    /destinationFilterRejected:[\s\S]*?msg\['forwardAllowed'\] == true/);
});
