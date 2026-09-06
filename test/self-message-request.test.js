const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const server = fs.readFileSync(
  path.join(__dirname, '..', 'server', 'index.js'), 'utf8');

test('self conversations bypass contact requests on both transports', () => {
  assert.doesNotMatch(server, /SELF_MESSAGE_NOT_ALLOWED/);
  assert.match(server, /String\(toUserId\) !== String\(socket\.user\.id\) && !accepted.rows.length/);
  assert.match(server, /String\(toUserId\) !== String\(senderId\) && !accepted.rows.length/);
  assert.match(server, /name: 'הודעות לעצמי', is_self: true/);
  assert.match(server, /m.sender_id <> \$2 AND m.sender_id <> \$1/);
});

test('self contact requests are excluded and blocked by the database', () => {
  assert.match(server, /DELETE FROM message_requests WHERE sender_id=recipient_id/);
  assert.match(server, /CHECK \(sender_id <> recipient_id\)/);
  assert.match(server, /WHERE mr\.recipient_id=\$1\s+AND mr\.sender_id<>mr\.recipient_id/);
});
