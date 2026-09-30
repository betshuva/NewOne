'use strict';
const { createReadStream, openAsBlob } = require('node:fs');
const fs = require('node:fs/promises');
const { createHash } = require('node:crypto');

async function sourceHash(source) {
  const hash = createHash('sha256');
  if (Buffer.isBuffer(source)) hash.update(source);
  else for await (const chunk of createReadStream(source.path)) hash.update(chunk);
  return hash.digest('hex');
}

async function sourceBlob(source, type) {
  return Buffer.isBuffer(source) ? new Blob([source], { type })
    : openAsBlob(source.path, { type });
}

async function uploadHeader(file) {
  if (file.buffer) return file.buffer.subarray(0, 16);
  const handle = await fs.open(file.path, 'r');
  try {
    const header = Buffer.alloc(16);
    const { bytesRead } = await handle.read(header, 0, header.length, 0);
    return header.subarray(0, bytesRead);
  } finally { await handle.close(); }
}

module.exports = { sourceHash, sourceBlob, uploadHeader };
