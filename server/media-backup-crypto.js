'use strict';

const crypto = require('crypto');
const FORMAT_VERSION = 1;
const KEY_BYTES = 32;

function requireKey(key) {
  if (!Buffer.isBuffer(key) || key.length !== KEY_BYTES)
    throw new TypeError('backup key must be a 32-byte Buffer');
}

function encryptBuffer(plain, key, associatedData = '') {
  requireKey(key);
  if (!Buffer.isBuffer(plain)) throw new TypeError('plain must be a Buffer');
  const nonce = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, nonce);
  if (associatedData) cipher.setAAD(Buffer.from(String(associatedData), 'utf8'));
  const ciphertext = Buffer.concat([cipher.update(plain), cipher.final()]);
  return { version: FORMAT_VERSION, algorithm: 'AES-256-GCM',
    nonce: nonce.toString('base64'), tag: cipher.getAuthTag().toString('base64'), ciphertext };
}

function decryptBuffer(envelope, key, associatedData = '') {
  requireKey(key);
  if (envelope?.version !== FORMAT_VERSION || envelope?.algorithm !== 'AES-256-GCM' ||
      !Buffer.isBuffer(envelope?.ciphertext)) throw new TypeError('unsupported backup envelope');
  const decipher = crypto.createDecipheriv('aes-256-gcm', key,
    Buffer.from(envelope.nonce, 'base64'));
  if (associatedData) decipher.setAAD(Buffer.from(String(associatedData), 'utf8'));
  decipher.setAuthTag(Buffer.from(envelope.tag, 'base64'));
  return Buffer.concat([decipher.update(envelope.ciphertext), decipher.final()]);
}

function deriveKey(passphrase, salt = crypto.randomBytes(16)) {
  if (typeof passphrase !== 'string' || passphrase.length < 12)
    return Promise.reject(new TypeError('backup passphrase must contain at least 12 characters'));
  if (!Buffer.isBuffer(salt) || salt.length < 16)
    return Promise.reject(new TypeError('backup salt must contain at least 16 bytes'));
  return new Promise((resolve, reject) => {
    crypto.scrypt(passphrase, salt, KEY_BYTES,
      { N: 32768, r: 8, p: 1, maxmem: 64 * 1024 * 1024 },
      (error, key) => error ? reject(error) : resolve({ key, salt }));
  });
}

module.exports = { FORMAT_VERSION, decryptBuffer, deriveKey, encryptBuffer };
