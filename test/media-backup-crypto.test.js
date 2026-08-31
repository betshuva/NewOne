'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { decryptBuffer, deriveKey, encryptBuffer } = require('../server/media-backup-crypto');

test('personal backup encryption round-trips without storing the passphrase', async () => {
  const { key, salt } = await deriveKey('correct horse battery staple');
  const plain = Buffer.from('private media bytes');
  const envelope = encryptBuffer(plain, key, 'user/file-id');
  assert.deepEqual(decryptBuffer(envelope, key, 'user/file-id'), plain);
  assert.equal(salt.length, 16);
  assert.equal(JSON.stringify(envelope).includes('correct horse'), false);
});

test('personal backup encryption rejects tampering and wrong context', async () => {
  const { key } = await deriveKey('another sufficiently long password');
  const envelope = encryptBuffer(Buffer.from('photo'), key, 'owner-a/file-a');
  assert.throws(() => decryptBuffer(envelope, key, 'owner-b/file-a'));
  envelope.ciphertext[0] ^= 1;
  assert.throws(() => decryptBuffer(envelope, key, 'owner-a/file-a'));
});
