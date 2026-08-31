'use strict';

const crypto = require('crypto');

const PREFIX = 'enc:v1:';

function encryptionKey() {
  const secret = String(process.env.MESSAGE_ENCRYPTION_KEY ||
    process.env.BACKUP_TOKEN_ENCRYPTION_KEY || process.env.JWT_SECRET || '');
  if (secret.length < 32) throw new Error('Message encryption key is not configured securely');
  return crypto.hkdfSync('sha256', Buffer.from(secret),
    Buffer.from('betshuva-message-storage-v1'), Buffer.from('message-body'), 32);
}

function encryptMessageText(value) {
  if (value === null || value === undefined || typeof value !== 'string' || value.startsWith(PREFIX))
    return value;
  const nonce = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', encryptionKey(), nonce);
  cipher.setAAD(Buffer.from('message-body-v1'));
  const ciphertext = Buffer.concat([cipher.update(value, 'utf8'), cipher.final()]);
  return `${PREFIX}${nonce.toString('base64')}:${cipher.getAuthTag().toString('base64')}:${ciphertext.toString('base64')}`;
}

function decryptMessageText(value) {
  if (typeof value !== 'string' || !value.startsWith(PREFIX)) return value;
  const parts = value.slice(PREFIX.length).split(':');
  if (parts.length !== 3) throw new Error('Invalid encrypted message envelope');
  const decipher = crypto.createDecipheriv('aes-256-gcm', encryptionKey(),
    Buffer.from(parts[0], 'base64'));
  decipher.setAAD(Buffer.from('message-body-v1'));
  decipher.setAuthTag(Buffer.from(parts[1], 'base64'));
  return Buffer.concat([decipher.update(Buffer.from(parts[2], 'base64')), decipher.final()])
    .toString('utf8');
}

const DECRYPTED_RESULT_FIELDS = new Set(['body', 'reply_body', 'last_message']);

function decryptMessageRows(result) {
  if (!result?.rows) return result;
  for (const row of result.rows) {
    for (const field of DECRYPTED_RESULT_FIELDS) {
      if (Object.prototype.hasOwnProperty.call(row, field))
        row[field] = decryptMessageText(row[field]);
    }
  }
  return result;
}

function encryptedQueryValues(text, values) {
  if (typeof text !== 'string' || !Array.isArray(values) || !values.length)
    return values;
  const indexes = new Set();
  const insert = text.match(/INSERT\s+INTO\s+(?:messages|message_requests)\s*\(([^)]+)\)\s*VALUES\s*\(([^)]+)\)/i);
  if (insert) {
    const columns = insert[1].split(',').map(value => value.trim().replace(/"/g, '').toLowerCase());
    const expressions = insert[2].split(',').map(value => value.trim());
    columns.forEach((column, index) => {
      if (column !== 'body') return;
      const placeholder = expressions[index]?.match(/^\$(\d+)$/);
      if (placeholder) indexes.add(Number(placeholder[1]) - 1);
    });
  }
  if (/UPDATE\s+(?:messages|message_requests)\s+SET/i.test(text)) {
    for (const match of text.matchAll(/\bbody\s*=\s*\$(\d+)/gi))
      indexes.add(Number(match[1]) - 1);
  }
  if (!indexes.size) return values;
  const encrypted = [...values];
  for (const index of indexes) encrypted[index] = encryptMessageText(encrypted[index]);
  return encrypted;
}

module.exports = { PREFIX, decryptMessageRows, decryptMessageText,
  encryptMessageText, encryptedQueryValues };
