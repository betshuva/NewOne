const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');

const source = fs.readFileSync(
  path.join(__dirname, '../flutter_app/lib/main.dart'),
  'utf8',
);

test('blocked private uploads identify the recipient by name', () => {
  assert.match(source, /final String\? recipientName/);
  assert.match(source, /Text\('נמען: \$\{recipientName!\.trim\(\)\}'/);
  assert.match(source, /recipientName: isMe \? recipientName : senderName/);
  assert.match(
    source,
    /recipientName: widget\.recipient\['name'\][\s\S]*?\.toString\(\)/,
  );
});

test('blocked group uploads identify the destination group', () => {
  assert.match(
    source,
    /recipientName: uploadStatus ==[\s\S]*?'rejected_scan'[\s\S]*?'קבוצת \$\{widget\.group\['name'\]/,
  );
});
