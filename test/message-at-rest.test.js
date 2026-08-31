'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

process.env.MESSAGE_ENCRYPTION_KEY ||= 'test-message-encryption-key-that-is-at-least-32-bytes';
const { PREFIX, decryptMessageRows, decryptMessageText, encryptMessageText,
  encryptedQueryValues } = require('../server/message-at-rest');

test('message bodies use authenticated AES encryption at rest', () => {
  const encrypted = encryptMessageText('הודעה לבדיקה');
  assert.ok(encrypted.startsWith(PREFIX));
  assert.doesNotMatch(encrypted, /הודעה/);
  assert.equal(decryptMessageText(encrypted), 'הודעה לבדיקה');
  const tampered = `${encrypted.slice(0, -2)}AA`;
  assert.throws(() => decryptMessageText(tampered));
});

test('message insert and edit parameters are encrypted before database writes', () => {
  const insert = encryptedQueryValues(
    'INSERT INTO messages(sender_id,recipient_id,type,body) VALUES($1,$2,$3,$4)',
    ['a', 'b', 'text', 'פוגעני']);
  assert.ok(insert[3].startsWith(PREFIX));
  assert.equal(decryptMessageText(insert[3]), 'פוגעני');
  const update = encryptedQueryValues('UPDATE messages SET body=$1 WHERE id=$2', ['חדש', 'id']);
  assert.ok(update[0].startsWith(PREFIX));
});

test('database message fields are decrypted only after query completion', () => {
  const body = encryptMessageText('שלום');
  const result = decryptMessageRows({ rows: [{ body, reply_body: body,
    last_message: body, unrelated: body }] });
  assert.equal(result.rows[0].body, 'שלום');
  assert.equal(result.rows[0].reply_body, 'שלום');
  assert.equal(result.rows[0].last_message, 'שלום');
  assert.equal(result.rows[0].unrelated, body);
});
