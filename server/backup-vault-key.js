'use strict';

const crypto = require('crypto');

function masterKey() {
  const value = String(process.env.BACKUP_TOKEN_ENCRYPTION_KEY || '');
  if (value.length < 32) throw new Error('Backup master key is not configured securely');
  return crypto.hkdfSync('sha256', Buffer.from(value),
    Buffer.from('betshuva-media-vault-v1'), Buffer.from('per-user-data-key'), 32);
}

function createVaultKey() {
  return crypto.randomBytes(32);
}

function wrapVaultKey(key, userId) {
  if (!Buffer.isBuffer(key) || key.length !== 32)
    throw new TypeError('vault key must be a 32-byte Buffer');
  const nonce = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', masterKey(), nonce);
  cipher.setAAD(Buffer.from(`user:${userId}:vault:v1`));
  const encrypted = Buffer.concat([cipher.update(key), cipher.final()]);
  return JSON.stringify({ v: 1, n: nonce.toString('base64'),
    t: cipher.getAuthTag().toString('base64'), c: encrypted.toString('base64') });
}

function unwrapVaultKey(value, userId) {
  const envelope = JSON.parse(value);
  if (envelope.v !== 1) throw new Error('Unsupported vault key envelope');
  const decipher = crypto.createDecipheriv('aes-256-gcm', masterKey(),
    Buffer.from(envelope.n, 'base64'));
  decipher.setAAD(Buffer.from(`user:${userId}:vault:v1`));
  decipher.setAuthTag(Buffer.from(envelope.t, 'base64'));
  const key = Buffer.concat([
    decipher.update(Buffer.from(envelope.c, 'base64')), decipher.final()]);
  if (key.length !== 32) throw new Error('Invalid vault key');
  return key;
}

module.exports = { createVaultKey, unwrapVaultKey, wrapVaultKey };
