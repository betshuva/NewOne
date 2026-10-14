'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const { constants } = require('node:fs');
const path = require('node:path');

const CHUNK_BYTES = 32 * 1024 * 1024;
const MIN_FILE_BYTES = 128 * 1024 * 1024;
const DEADLINE_MS = 180000;
const FREE_FLOOR_BYTES = 128 * 1024 * 1024;
const CHECKPOINT_TTL_MS = 24 * 60 * 60 * 1000;
const DRIVE_API = 'https://www.googleapis.com/drive/v3';

async function cleanupExpiredCheckpoints(root, excludedIdentity, currentTime, signal) {
  const cutoff = currentTime - CHECKPOINT_TTL_MS;
  let examined = 0;
  for await (const entry of await fs.opendir(root)) {
    if (++examined > 128 || signal.aborted) break;
    if (!entry.isDirectory() || !/^[a-f0-9]{64}$/.test(entry.name) || entry.name === excludedIdentity) continue;
    const directory = path.join(root, entry.name);
    try {
      const metadata = await readMetadata(directory);
      if (metadata?.version !== 1 || metadata.identity !== entry.name ||
          !Number.isSafeInteger(metadata.expectedBytes) || metadata.expectedBytes < 1 ||
          !/^[a-f0-9]{64}$/.test(metadata.expectedSha256 || '') ||
          !Number.isSafeInteger(metadata.offset) || metadata.offset < 0 || metadata.offset > metadata.expectedBytes ||
          !Number.isFinite(metadata.updatedAt) || metadata.updatedAt > cutoff) continue;
      const files = await fs.readdir(directory);
      if (files.some(name => name !== 'metadata.json' && name !== 'payload' &&
          !/^[a-f0-9-]{36}\.tmp$/.test(name))) continue;
      const [payload, saved] = await Promise.all([
        fs.lstat(path.join(directory, 'payload')), fs.lstat(path.join(directory, 'metadata.json')),
      ]);
      if (!payload.isFile() || payload.size > metadata.expectedBytes ||
          payload.mtimeMs > cutoff || saved.mtimeMs > cutoff) continue;
      await fs.rm(directory, { recursive: true, force: true });
    } catch {
      // An unfamiliar, active or damaged directory is never a cleanup target.
    }
  }
}

function downloadError(message, code) {
  return Object.assign(new Error(message), { code });
}

function inProgress() {
  return downloadError('Encrypted Drive download checkpoint retained', 'DRIVE_DOWNLOAD_IN_PROGRESS');
}

function abortable(operation, signal) {
  const pending = Promise.resolve(operation);
  if (signal.aborted) {
    pending.catch(() => {});
    return Promise.reject(signal.reason);
  }
  return new Promise((resolve, reject) => {
    const aborted = () => reject(signal.reason);
    signal.addEventListener('abort', aborted, { once: true });
    pending.then(resolve, reject).finally(() => {
      signal.removeEventListener('abort', aborted);
    });
  });
}

async function saveMetadata(directory, metadata) {
  const temporary = path.join(directory, `${crypto.randomUUID()}.tmp`);
  try {
    await fs.writeFile(temporary, JSON.stringify(metadata), { mode: 0o600, flag: 'wx' });
    await fs.rename(temporary, path.join(directory, 'metadata.json'));
  } finally {
    await fs.rm(temporary, { force: true }).catch(() => {});
  }
}

async function readMetadata(directory) {
  const file = path.join(directory, 'metadata.json');
  const info = await fs.lstat(file).catch(error => {
    if (error.code !== 'ENOENT') throw error;
    return null;
  });
  if (!info) return null;
  if (!info.isFile() || info.size > 4096)
    throw downloadError('Invalid encrypted download checkpoint', 'DRIVE_DOWNLOAD_INVALID_CHECKPOINT');
  return fs.readFile(file, 'utf8').then(JSON.parse).catch(error => {
    if (error instanceof SyntaxError) return null;
    throw error;
  });
}

function cancelBody(response) {
  response.body?.cancel().catch(() => {});
}

async function writeChunk(response, handle, start, length, signal) {
  if (!response.body || typeof response.body.getReader !== 'function')
    throw downloadError('Missing Drive download body', 'DRIVE_DOWNLOAD_INVALID_RESPONSE');
  const reader = response.body.getReader();
  let received = 0;
  try {
    while (true) {
      const chunk = await abortable(reader.read(), signal);
      signal.throwIfAborted();
      if (chunk.done) break;
      const bytes = Buffer.from(chunk.value);
      if (bytes.length > length - received)
        throw downloadError('Drive download chunk exceeds size limit', 'DRIVE_DOWNLOAD_INVALID_RESPONSE');
      let written = 0;
      while (written < bytes.length) {
        signal.throwIfAborted();
        const result = await handle.write(bytes, written, bytes.length - written, start + received + written);
        if (result.bytesWritten === 0) throw new Error('Encrypted checkpoint write made no progress');
        written += result.bytesWritten;
      }
      received += bytes.length;
    }
    if (received !== length)
      throw downloadError('Incomplete Drive download chunk', 'DRIVE_DOWNLOAD_INVALID_RESPONSE');
  } catch (error) {
    reader.cancel().catch(() => {});
    throw error;
  } finally {
    reader.releaseLock();
  }
}

async function downloadCheckpointed({ client, fileId, maxBytes, checkpointRoot, ownerKey,
  expectedBytes, expectedSha256, fetchImpl = fetch, now = Date.now,
  timeoutSignal = milliseconds => AbortSignal.timeout(milliseconds), statfsImpl = fs.statfs }) {
  if (!client || typeof client.getRequestHeaders !== 'function' ||
      typeof fileId !== 'string' || !fileId || typeof ownerKey !== 'string' || !ownerKey ||
      typeof checkpointRoot !== 'string' || !checkpointRoot ||
      !Number.isSafeInteger(expectedBytes) || expectedBytes < 1 ||
      !Number.isSafeInteger(maxBytes) || maxBytes < expectedBytes ||
      typeof expectedSha256 !== 'string' || !/^[a-fA-F0-9]{64}$/.test(expectedSha256))
    throw downloadError('Invalid encrypted Drive download bounds', 'DRIVE_DOWNLOAD_INVALID_OPTIONS');

  const startedAt = now();
  const signal = timeoutSignal(DEADLINE_MS);
  const identity = crypto.createHash('sha256')
    .update(JSON.stringify([ownerKey, fileId, expectedBytes, expectedSha256.toLowerCase()]))
    .digest('hex');
  const directory = path.join(path.resolve(checkpointRoot), identity);
  await fs.mkdir(directory, { recursive: true, mode: 0o700 });
  const info = await fs.lstat(directory);
  if (!info.isDirectory())
    throw downloadError('Invalid encrypted download directory', 'DRIVE_DOWNLOAD_INVALID_CHECKPOINT');
  await fs.chmod(directory, 0o700);
  await cleanupExpiredCheckpoints(path.resolve(checkpointRoot), identity, now(), signal);

  let handle;
  let offset = 0;
  let initialOffset = 0;
  try {
    const saved = await readMetadata(directory);
    handle = await fs.open(path.join(directory, 'payload'),
      constants.O_CREAT | constants.O_RDWR | constants.O_NOFOLLOW, 0o600);
    await handle.chmod(0o600);
    const size = (await handle.stat()).size;
    const validSaved = saved?.version === 1 && saved.identity === identity &&
        saved.expectedBytes === expectedBytes && saved.expectedSha256 === expectedSha256.toLowerCase() &&
        Number.isSafeInteger(saved.offset) && saved.offset >= 0 && saved.offset <= expectedBytes &&
        (saved.offset === expectedBytes || saved.offset % CHUNK_BYTES === 0) && size >= saved.offset;
    if (validSaved) offset = saved.offset;
    initialOffset = offset;
    // A process interruption may leave bytes beyond the last durable checkpoint.
    await handle.truncate(offset);
    const metadata = () => ({ version: 1, identity, expectedBytes,
      expectedSha256: expectedSha256.toLowerCase(), offset, updatedAt: now() });
    if (!validSaved) await saveMetadata(directory, metadata());
    signal.throwIfAborted();
    const headers = new Headers(await abortable(client.getRequestHeaders(), signal));
    let previousChunkMs = 0;
    while (offset < expectedBytes) {
      signal.throwIfAborted();
      const remainingMs = DEADLINE_MS - (now() - startedAt);
      if (remainingMs <= 0) throw signal.reason || new DOMException('Drive download timed out', 'TimeoutError');
      if (offset > initialOffset && remainingMs <= Math.max(1000, previousChunkMs + 1000))
        throw inProgress();
      const length = Math.min(CHUNK_BYTES, expectedBytes - offset);
      const disk = await statfsImpl(directory, { bigint: true });
      if (BigInt(disk.bavail) * BigInt(disk.bsize) < BigInt(length + FREE_FLOOR_BYTES))
        throw downloadError('Insufficient encrypted download scratch space', 'DRIVE_DOWNLOAD_NO_SPACE');
      signal.throwIfAborted();
      const end = offset + length - 1;
      headers.set('Range', `bytes=${offset}-${end}`);
      const chunkStartedAt = now();
      const response = await abortable(fetchImpl(
        `${DRIVE_API}/files/${encodeURIComponent(fileId)}?alt=media`, { headers, signal }), signal);
      if (response.status !== 206) {
        cancelBody(response);
        throw downloadError(`Google appDataFolder partial download failed (${response.status})`,
          'DRIVE_DOWNLOAD_INVALID_RESPONSE');
      }
      const range = response.headers.get('content-range')?.match(/^bytes (\d+)-(\d+)\/(\d+)$/);
      const declared = response.headers.get('content-length');
      if (!range || Number(range[1]) !== offset || Number(range[2]) !== end ||
          Number(range[3]) !== expectedBytes || Number(range[3]) > maxBytes ||
          (declared !== null && (!/^\d+$/.test(declared) || Number(declared) !== length))) {
        cancelBody(response);
        throw downloadError('Invalid Drive download content range', 'DRIVE_DOWNLOAD_INVALID_RESPONSE');
      }
      await writeChunk(response, handle, offset, length, signal);
      await handle.sync();
      const nextOffset = offset + length;
      await saveMetadata(directory, { ...metadata(), offset: nextOffset });
      offset = nextOffset;
      previousChunkMs = now() - chunkStartedAt;
    }
    signal.throwIfAborted();
    const bytes = await abortable(handle.readFile(), signal);
    const downloadedHash = crypto.createHash('sha256').update(bytes).digest('hex');
    signal.throwIfAborted();
    if (now() - startedAt >= DEADLINE_MS) {
      if (offset > initialOffset) throw inProgress();
      throw new DOMException('Drive download timed out', 'TimeoutError');
    }
    if (bytes.length !== expectedBytes || downloadedHash !== expectedSha256.toLowerCase()) {
      await handle.close();
      handle = null;
      await fs.rm(directory, { recursive: true, force: true });
      throw downloadError('Encrypted Drive download checksum mismatch', 'DRIVE_DOWNLOAD_CHECKSUM_MISMATCH');
    }
    await handle.close();
    handle = null;
    await fs.rm(directory, { recursive: true, force: true });
    return bytes;
  } catch (error) {
    if (handle) await handle.truncate(offset).catch(() => {});
    if (signal.aborted && offset > initialOffset) throw inProgress();
    throw error;
  } finally {
    if (handle) await handle.close();
  }
}

module.exports = { downloadCheckpointed, CHUNK_BYTES, MIN_FILE_BYTES, DEADLINE_MS, FREE_FLOOR_BYTES };
