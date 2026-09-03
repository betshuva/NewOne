const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const server = fs.readFileSync(
  path.join(__dirname, '..', 'server', 'index.js'), 'utf8');

test('self contact requests are rejected on HTTP and socket paths', () => {
  assert.match(server,
    /String\(toUserId\) === String\(socket\.user\.id\)[\s\S]*SELF_MESSAGE_NOT_ALLOWED/);
  assert.match(server,
    /String\(toUserId\) === String\(senderId\)[\s\S]*SELF_MESSAGE_NOT_ALLOWED/);
});

test('self contact requests are excluded and blocked by the database', () => {
  assert.match(server, /DELETE FROM message_requests WHERE sender_id=recipient_id/);
  assert.match(server, /CHECK \(sender_id <> recipient_id\)/);
  assert.match(server, /WHERE mr\.recipient_id=\$1\s+AND mr\.sender_id<>mr\.recipient_id/);
});
