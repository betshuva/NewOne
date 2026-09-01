const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');

const source = fs.readFileSync(
  path.join(__dirname, '../flutter_app/lib/main.dart'),
  'utf8',
);

test('private and group recording submissions reject duplicate stop taps', () => {
  assert.equal(
    (source.match(/bool _voiceSubmissionInProgress = false/g) || []).length,
    2,
  );
  assert.equal(
    (source.match(/if \(_voiceSubmissionInProgress\) return/g) || []).length,
    2,
  );
  assert.equal(
    (source.match(/_voiceSubmissionInProgress = true/g) || []).length,
    2,
  );
  assert.equal(
    (source.match(/_voiceSubmissionInProgress = false/g) || []).length,
    4,
  );
});

test('voice uploads and pending scans have explicit progress labels', () => {
  assert.match(source, /fileType == 'audio'\) &&[\s\S]*?!isClipboardPaste/);
  assert.match(source, /widget\.fileType == 'audio'[\s\S]*?'ההקלטה'/);
  assert.ok(
    (source.match(/ההקלטה ממתינה לסריקה/g) || []).length >= 2,
    'private and group chats should both explain the pending scan',
  );
});
