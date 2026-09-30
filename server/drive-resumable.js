'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');

const ROOT = path.join(__dirname, '..', '.transfer-state', 'drive');
const CHUNK_BYTES = 4 * 1024 * 1024; // Drive requires multiples of 256 KiB.
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

async function save(file, state) {
  await fs.mkdir(path.dirname(file), { recursive: true, mode: 0o700 });
  const tmp = `${file}.${crypto.randomUUID()}.tmp`;
  await fs.writeFile(tmp, JSON.stringify(state), { mode: 0o600 });
  await fs.rename(tmp, file);
}

async function uploadResumable({ client, ownerKey, metadata, bytes, mimeType,
    root = ROOT, fetchImpl = fetch, sleep = delay }) {
  const key = crypto.createHash('sha256').update(ownerKey).update(JSON.stringify(metadata))
    .update(crypto.createHash('sha256').update(bytes).digest()).digest('hex');
  const file = path.join(root, `${key}.json`);
  let state = await fs.readFile(file, 'utf8').then(JSON.parse).catch(e => {
    if (e.code !== 'ENOENT') throw e;
    return {};
  });
  if (state.result) return state.result;
  let offset = 0, probe = Boolean(state.url), failures = 0;
  async function request(url, options) {
    // Session URLs are credentials; accept only Google's upload host and never log them.
    const parsed = new URL(url);
    if (parsed.protocol !== 'https:' || parsed.hostname !== 'www.googleapis.com' ||
        !parsed.pathname.startsWith('/upload/drive/')) throw new Error('Invalid Drive upload session');
    const auth = new Headers(await client.getRequestHeaders());
    const headers = new Headers(options.headers);
    auth.forEach((value, name) => headers.set(name, value));
    return fetchImpl(url, { ...options, headers, redirect: 'manual', signal: AbortSignal.timeout(120000) });
  }
  while (true) {
    try {
      if (!state.url) {
        const response = await request('https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id,size,md5Checksum', {
          method: 'POST', headers: { 'Content-Type': 'application/json',
            'X-Upload-Content-Type': mimeType, 'X-Upload-Content-Length': String(bytes.length) },
          body: JSON.stringify(metadata),
        });
        if (!response.ok) throw responseError(response.status);
        const url = response.headers.get('location');
        if (!url) throw new Error('Drive did not return an upload session');
        state = { url, updated: Date.now() };
        await save(file, state);
        offset = 0; probe = false;
      }
      const end = Math.min(offset + CHUNK_BYTES, bytes.length);
      const response = await request(state.url, {
        method: 'PUT', headers: { 'Content-Type': mimeType,
          'Content-Length': String(probe ? 0 : end - offset),
          'Content-Range': probe || bytes.length === 0 ? `bytes */${bytes.length}`
            : `bytes ${offset}-${end - 1}/${bytes.length}` },
        body: probe ? undefined : bytes.subarray(offset, end),
      });
      if (response.status === 200 || response.status === 201) {
        const result = await response.json();
        if (!result.id || Number(result.size) !== bytes.length)
          throw new Error('Drive uploaded file size mismatch');
        state.result = result;
        state.updated = Date.now();
        await save(file, state);
        return result;
      }
      if ([404, 410].includes(response.status)) {
        state = {}; await save(file, state);
        throw responseError(503);
      }
      if (response.status !== 308) {
        if (response.status === 403) {
          const details = await response.json().catch(() => ({}));
          if (details.error?.errors?.some(e => ['rateLimitExceeded', 'userRateLimitExceeded'].includes(e.reason)))
            throw responseError(429);
        }
        throw responseError(response.status);
      }
      const range = response.headers.get('range');
      const match = range?.match(/^bytes=0-(\d+)$/);
      const next = match ? Number(match[1]) + 1 : 0;
      if (!Number.isSafeInteger(next) || next < 0 || next > bytes.length || (range && !match))
        throw new Error('Invalid Drive upload offset');
      if (!probe && next <= offset) throw responseError(503);
      if (probe && offset === bytes.length && next === offset) throw responseError(503);
      if (next > offset) failures = 0;
      offset = next;
      probe = offset === bytes.length;
    } catch (error) {
      if (error.permanent) throw error;
      if (++failures > 8) {
        error.code = 'UPLOAD_RETRYABLE';
        throw error;
      }
      probe = Boolean(state.url);
      await sleep(Math.min(30000, 1000 * 2 ** (failures - 1)));
    }
  }
}

function responseError(status) {
  const error = new Error(`Google resumable upload failed (${status})`);
  error.permanent = status >= 400 && status < 500 && ![408, 429].includes(status);
  return error;
}

module.exports = { uploadResumable, CHUNK_BYTES };
