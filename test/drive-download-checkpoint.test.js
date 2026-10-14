'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');
const { downloadCheckpointed, CHUNK_BYTES, DEADLINE_MS, FREE_FLOOR_BYTES } =
  require('../server/drive-download-checkpoint');

const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const timeout = () => new DOMException('The operation was aborted due to timeout', 'TimeoutError');

async function temporaryRoot(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'drive-download-checkpoint-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  return root;
}

function options(root, bytes, extra = {}) {
  return { checkpointRoot: root, ownerKey: 'fixture-private-owner', fileId: 'remote/fixture-id',
    expectedBytes: bytes.length, expectedSha256: hash(bytes), maxBytes: bytes.length,
    client: { getRequestHeaders: async () => ({ Authorization: 'Bearer fixture-only' }) }, ...extra };
}

function clock() {
  let time = 0;
  const deadlines = [];
  const calls = [];
  return {
    calls,
    now: () => time,
    timeoutSignal(milliseconds) {
      calls.push(milliseconds);
      const controller = new AbortController();
      deadlines.push({ at: time + milliseconds, controller });
      return controller.signal;
    },
    advance(milliseconds) {
      time += milliseconds;
      for (const deadline of deadlines) {
        if (time >= deadline.at && !deadline.controller.signal.aborted)
          deadline.controller.abort(timeout());
      }
    },
  };
}

function rangeRequest(request) {
  const range = new Headers(request.headers).get('range').match(/^bytes=(\d+)-(\d+)$/);
  return { start: Number(range[1]), end: Number(range[2]), signal: request.signal };
}

function rangeResponse(bytes, start, end, overrides = {}) {
  const headers = { 'content-range': `bytes ${start}-${end}/${bytes.length}`,
    'content-length': String(end - start + 1), ...overrides.headers };
  return new Response(overrides.body ?? bytes.subarray(start, end + 1),
    { status: overrides.status ?? 206, headers });
}

async function savedCheckpoint(root) {
  const names = await fs.readdir(root);
  assert.equal(names.length, 1);
  assert.match(names[0], /^[a-f0-9]{64}$/);
  const directory = path.join(root, names[0]);
  const metadata = JSON.parse(await fs.readFile(path.join(directory, 'metadata.json'), 'utf8'));
  return { directory, metadata };
}

async function pauseAfterFirstChunk(input, bytes) {
  const time = clock();
  await assert.rejects(downloadCheckpointed({ ...input, now: time.now,
    timeoutSignal: time.timeoutSignal,
    async fetchImpl(_url, request) {
      const { start, end } = rangeRequest(request);
      assert.equal(start, 0);
      time.advance(DEADLINE_MS - 500);
      return rangeResponse(bytes, start, end);
    },
  }), { code: 'DRIVE_DOWNLOAD_IN_PROGRESS' });
  const state = await savedCheckpoint(input.checkpointRoot);
  assert.equal(state.metadata.offset, CHUNK_BYTES);
  return state;
}

test('serial ranges reconstruct exact encrypted bytes and clean their private checkpoint', async t => {
  const root = await temporaryRoot(t);
  const bytes = Buffer.alloc(CHUNK_BYTES * 2 + 17, 0x8b);
  const time = clock();
  const requests = [];
  const output = await downloadCheckpointed({ ...options(root, bytes), now: time.now,
    timeoutSignal: time.timeoutSignal,
    async fetchImpl(url, request) {
      const range = rangeRequest(request);
      requests.push(range);
      assert.equal(url, 'https://www.googleapis.com/drive/v3/files/remote%2Ffixture-id?alt=media');
      assert.equal(new Headers(request.headers).get('authorization'), 'Bearer fixture-only');
      const state = await savedCheckpoint(root);
      assert.equal((await fs.stat(state.directory)).mode & 0o777, 0o700);
      assert.equal((await fs.stat(path.join(state.directory, 'payload'))).mode & 0o777, 0o600);
      assert.equal((await fs.stat(path.join(state.directory, 'metadata.json'))).mode & 0o777, 0o600);
      return rangeResponse(bytes, range.start, range.end);
    },
  });
  assert.deepEqual(output, bytes);
  assert.deepEqual(requests.map(({ start, end }) => [start, end]),
    [[0, CHUNK_BYTES - 1], [CHUNK_BYTES, CHUNK_BYTES * 2 - 1], [CHUNK_BYTES * 2, bytes.length - 1]]);
  assert.ok(requests.every(request => request.signal === requests[0].signal));
  assert.deepEqual(time.calls, [180000]);
  assert.deepEqual(await fs.readdir(root), []);
});

test('a timeout during the next chunk preserves completed bytes and resumes after a restart', async t => {
  const root = await temporaryRoot(t);
  const bytes = Buffer.alloc(CHUNK_BYTES * 2 + 7, 0x31);
  const input = options(root, bytes);
  const time = clock();
  let reads = 0;
  await assert.rejects(downloadCheckpointed({ ...input, now: time.now,
    timeoutSignal: time.timeoutSignal,
    async fetchImpl(_url, request) {
      const { start, end } = rangeRequest(request);
      if (start === 0) {
        time.advance(1);
        return rangeResponse(bytes, start, end);
      }
      const body = new ReadableStream({
        pull(controller) {
          if (reads++ === 0) controller.enqueue(bytes.subarray(start, start + 13));
          else {
            time.advance(DEADLINE_MS - 1);
            controller.error(timeout());
          }
        },
      });
      return rangeResponse(bytes, start, end, { body });
    },
  }), { code: 'DRIVE_DOWNLOAD_IN_PROGRESS' });
  const state = await savedCheckpoint(root);
  assert.equal(state.metadata.offset, CHUNK_BYTES);
  assert.equal((await fs.stat(path.join(state.directory, 'payload'))).size, CHUNK_BYTES);
  assert.doesNotMatch(JSON.stringify(state.metadata), /fixture-private-owner|fixture-id|Bearer/);
  const restarted = clock();
  const offsets = [];
  const output = await downloadCheckpointed({ ...input, now: restarted.now,
    timeoutSignal: restarted.timeoutSignal,
    async fetchImpl(_url, request) {
      const { start, end } = rangeRequest(request);
      offsets.push(start);
      return rangeResponse(bytes, start, end);
    },
  });
  assert.deepEqual(offsets, [CHUNK_BYTES, CHUNK_BYTES * 2]);
  assert.deepEqual(output, bytes);
  assert.deepEqual(await fs.readdir(root), []);
});

test('an uncommitted disk tail is truncated before a resumed request', async t => {
  const root = await temporaryRoot(t);
  const bytes = Buffer.alloc(CHUNK_BYTES + 11, 0x9c);
  const input = options(root, bytes);
  const state = await pauseAfterFirstChunk(input, bytes);
  await fs.appendFile(path.join(state.directory, 'payload'), Buffer.from('unacknowledged tail'));
  const time = clock();
  const output = await downloadCheckpointed({ ...input, now: time.now,
    timeoutSignal: time.timeoutSignal,
    async fetchImpl(_url, request) {
      assert.equal((await fs.stat(path.join(state.directory, 'payload'))).size, CHUNK_BYTES);
      const { start, end } = rangeRequest(request);
      assert.equal(start, CHUNK_BYTES);
      return rangeResponse(bytes, start, end);
    },
  });
  assert.deepEqual(output, bytes);
});

test('malformed or mismatched metadata cannot reuse saved bytes from another download', async t => {
  for (const fault of ['invalid-json', 'identity', 'size', 'hash', 'offset', 'short-payload']) {
    await t.test(fault, async sub => {
      const root = await temporaryRoot(sub);
      const bytes = Buffer.from('fresh encrypted fixture');
      const input = options(root, bytes);
      const identity = hash(Buffer.from(JSON.stringify([input.ownerKey, input.fileId,
        input.expectedBytes, input.expectedSha256])));
      const directory = path.join(root, identity);
      await fs.mkdir(directory, { mode: 0o700 });
      const saved = { version: 1, identity, expectedBytes: bytes.length,
        expectedSha256: input.expectedSha256, offset: bytes.length };
      if (fault === 'identity') saved.identity = '0'.repeat(64);
      if (fault === 'size') saved.expectedBytes++;
      if (fault === 'hash') saved.expectedSha256 = '0'.repeat(64);
      if (fault === 'offset') saved.offset++;
      await fs.writeFile(path.join(directory, 'metadata.json'),
        fault === 'invalid-json' ? '{invalid' : JSON.stringify(saved), { mode: 0o600 });
      await fs.writeFile(path.join(directory, 'payload'),
        Buffer.alloc(fault === 'short-payload' ? bytes.length - 1 : bytes.length, 0xff), { mode: 0o600 });
      const time = clock();
      const output = await downloadCheckpointed({ ...input, now: time.now,
        timeoutSignal: time.timeoutSignal,
        async fetchImpl(_url, request) {
          const { start, end } = rangeRequest(request);
          assert.equal(start, 0);
          assert.equal((await fs.stat(path.join(directory, 'payload'))).size, 0);
          return rangeResponse(bytes, start, end);
        },
      });
      assert.deepEqual(output, bytes);
    });
  }
});

test('invalid ranges and body lengths never append to an existing completed checkpoint', async t => {
  const root = await temporaryRoot(t);
  const bytes = Buffer.alloc(CHUNK_BYTES + 9, 0x17);
  const input = options(root, bytes);
  const state = await pauseAfterFirstChunk(input, bytes);
  const faults = {
    'ignored range': { status: 200 },
    'permission denied': { status: 403 },
    'rate limited': { status: 429 },
    'missing range': { headers: { 'content-range': '' } },
    'wrong start': { headers: { 'content-range': `bytes ${CHUNK_BYTES + 1}-${bytes.length - 1}/${bytes.length}` } },
    'wrong end': { headers: { 'content-range': `bytes ${CHUNK_BYTES}-${bytes.length}/${bytes.length}` } },
    'changed total': { headers: { 'content-range': `bytes ${CHUNK_BYTES}-${bytes.length - 1}/${bytes.length + 1}` } },
    'wrong declared size': { headers: { 'content-length': '10' } },
    'extra body bytes': { body: Buffer.alloc(10), headers: { 'content-length': '9' } },
    'short body': { body: Buffer.alloc(8), headers: { 'content-length': '9' } },
  };
  for (const [name, fault] of Object.entries(faults)) {
    await t.test(name, async () => {
      const time = clock();
      await assert.rejects(downloadCheckpointed({ ...input, now: time.now,
        timeoutSignal: time.timeoutSignal,
        async fetchImpl(_url, request) {
          const { start, end } = rangeRequest(request);
          assert.equal(start, CHUNK_BYTES);
          return rangeResponse(bytes, start, end, fault);
        },
      }), { code: 'DRIVE_DOWNLOAD_INVALID_RESPONSE' });
      const after = await savedCheckpoint(root);
      assert.equal(after.metadata.offset, CHUNK_BYTES);
      assert.equal((await fs.stat(path.join(state.directory, 'payload'))).size, CHUNK_BYTES);
      assert.deepEqual(await fs.readFile(path.join(state.directory, 'payload')), bytes.subarray(0, CHUNK_BYTES));
    });
  }
});

test('multiple ranges share one three-minute budget and stop before an unsafe next range', async t => {
  const root = await temporaryRoot(t);
  const bytes = Buffer.alloc(CHUNK_BYTES * 3, 0x49);
  const time = clock();
  const signals = [];
  await assert.rejects(downloadCheckpointed({ ...options(root, bytes), now: time.now,
    timeoutSignal: time.timeoutSignal,
    async fetchImpl(_url, request) {
      const { start, end, signal } = rangeRequest(request);
      signals.push(signal);
      time.advance(60000);
      return rangeResponse(bytes, start, end);
    },
  }), { code: 'DRIVE_DOWNLOAD_IN_PROGRESS' });
  assert.deepEqual(time.calls, [180000]);
  assert.equal(time.now(), 120000);
  assert.equal(signals.length, 2);
  assert.equal(signals[0], signals[1]);
  assert.equal((await savedCheckpoint(root)).metadata.offset, CHUNK_BYTES * 2);
});

test('a timeout with no completed new chunk remains a failure and returns no partial bytes', async t => {
  const root = await temporaryRoot(t);
  const bytes = Buffer.from('encrypted fixture');
  const time = clock();
  await assert.rejects(downloadCheckpointed({ ...options(root, bytes), now: time.now,
    timeoutSignal: time.timeoutSignal,
    async fetchImpl() {
      time.advance(DEADLINE_MS);
      throw timeout();
    },
  }), { name: 'TimeoutError' });
  const state = await savedCheckpoint(root);
  assert.equal(state.metadata.offset, 0);
  assert.equal((await fs.stat(path.join(state.directory, 'payload'))).size, 0);
});

test('streaming size bounds and remaining disk headroom are enforced before a commit', async t => {
  await t.test('caller ceiling is checked before any authorization or download', async sub => {
    const root = await temporaryRoot(sub);
    const bytes = Buffer.alloc(8);
    await assert.rejects(downloadCheckpointed({ ...options(root, bytes, { maxBytes: 7 }),
      fetchImpl: () => assert.fail('oversized request must not download'),
      client: { getRequestHeaders: () => assert.fail('oversized request must not authorize') },
    }), { code: 'DRIVE_DOWNLOAD_INVALID_OPTIONS' });
    assert.deepEqual(await fs.readdir(root), []);
  });
  await t.test('scratch space retains a 128 MiB free floor', async sub => {
    const root = await temporaryRoot(sub);
    const bytes = Buffer.alloc(8);
    const time = clock();
    await assert.rejects(downloadCheckpointed({ ...options(root, bytes), now: time.now,
      timeoutSignal: time.timeoutSignal,
      statfsImpl: async () => ({ bavail: BigInt(FREE_FLOOR_BYTES + bytes.length - 1), bsize: 1n }),
      fetchImpl: () => assert.fail('insufficient scratch space must not download'),
    }), { code: 'DRIVE_DOWNLOAD_NO_SPACE' });
    assert.equal((await savedCheckpoint(root)).metadata.offset, 0);
  });
  await t.test('undeclared extra stream bytes are canceled and never persisted', async sub => {
    const root = await temporaryRoot(sub);
    const bytes = Buffer.alloc(8);
    const time = clock();
    let canceled = false;
    const body = new ReadableStream({
      start(controller) { controller.enqueue(Buffer.alloc(9)); },
      cancel() { canceled = true; },
    });
    await assert.rejects(downloadCheckpointed({ ...options(root, bytes), now: time.now,
      timeoutSignal: time.timeoutSignal,
      fetchImpl: async () => new Response(body, { status: 206,
        headers: { 'content-range': 'bytes 0-7/8' } }),
    }), { code: 'DRIVE_DOWNLOAD_INVALID_RESPONSE' });
    assert.equal(canceled, true);
    const state = await savedCheckpoint(root);
    assert.equal((await fs.stat(path.join(state.directory, 'payload'))).size, 0);
  });
});

test('completed ciphertext with an unexpected SHA is discarded and never returned', async t => {
  const root = await temporaryRoot(t);
  const bytes = Buffer.from('tampered encrypted bytes');
  const time = clock();
  await assert.rejects(downloadCheckpointed({ ...options(root, bytes, { expectedSha256: '0'.repeat(64) }),
    now: time.now, timeoutSignal: time.timeoutSignal,
    fetchImpl: async (_url, request) => {
      const { start, end } = rangeRequest(request);
      return rangeResponse(bytes, start, end);
    },
  }), { code: 'DRIVE_DOWNLOAD_CHECKSUM_MISMATCH' });
  assert.deepEqual(await fs.readdir(root), []);
});

test('a deadline reached during final hashing retains the complete ciphertext for the next call', async t => {
  const root = await temporaryRoot(t);
  const bytes = Buffer.from('complete encrypted fixture');
  const time = clock();
  const source = await fs.readFile(path.join(__dirname, '..', 'server', 'drive-download-checkpoint.js'), 'utf8');
  const module = { exports: {} };
  let digests = 0;
  vm.runInNewContext(source, { module, Buffer, Headers, AbortSignal, DOMException, fetch,
    require(name) {
      if (name !== 'node:crypto') return require(name);
      return { ...crypto, createHash(algorithm) {
        const real = crypto.createHash(algorithm);
        const wrapped = {
          update(value) { real.update(value); return wrapped; },
          digest(encoding) {
            const result = real.digest(encoding);
            if (++digests === 2) time.advance(DEADLINE_MS);
            return result;
          },
        };
        return wrapped;
      } };
    },
  }, { filename: 'drive-download-checkpoint.js' });
  const input = options(root, bytes);
  await assert.rejects(module.exports.downloadCheckpointed({ ...input,
    now: time.now, timeoutSignal: time.timeoutSignal,
    fetchImpl: async (_url, request) => {
      const { start, end } = rangeRequest(request);
      return rangeResponse(bytes, start, end);
    },
  }), { code: 'DRIVE_DOWNLOAD_IN_PROGRESS' });
  assert.equal((await savedCheckpoint(root)).metadata.offset, bytes.length);
  const restarted = clock();
  assert.deepEqual(await downloadCheckpointed({ ...input, now: restarted.now,
    timeoutSignal: restarted.timeoutSignal,
    fetchImpl: () => assert.fail('a completed checkpoint does not repeat its remote download'),
  }), bytes);
  assert.deepEqual(await fs.readdir(root), []);
});

test('TTL cleanup removes only recognized old ciphertext checkpoints inside the dedicated root', async t => {
  const root = await temporaryRoot(t);
  const bytes = Buffer.from('fresh ciphertext');
  const oldTime = Date.now() - 25 * 60 * 60 * 1000;
  const keepNames = [];
  async function seed(label, { extraFile = false, freshPayload = false } = {}) {
    const identity = hash(Buffer.from(label));
    const directory = path.join(root, identity);
    await fs.mkdir(directory, { mode: 0o700 });
    await fs.writeFile(path.join(directory, 'metadata.json'), JSON.stringify({
      version: 1, identity, expectedBytes: bytes.length, expectedSha256: hash(bytes),
      offset: 0, updatedAt: oldTime,
    }), { mode: 0o600 });
    await fs.writeFile(path.join(directory, 'payload'), Buffer.alloc(0), { mode: 0o600 });
    await fs.utimes(path.join(directory, 'metadata.json'), oldTime / 1000, oldTime / 1000);
    if (!freshPayload) await fs.utimes(path.join(directory, 'payload'), oldTime / 1000, oldTime / 1000);
    if (extraFile) await fs.writeFile(path.join(directory, 'keep-user-data.txt'), 'untouched');
    return identity;
  }
  const stale = await seed('recognized stale checkpoint');
  keepNames.push(await seed('unrecognized content', { extraFile: true }));
  keepNames.push(await seed('active checkpoint', { freshPayload: true }));
  await fs.mkdir(path.join(root, 'other-user-data'));
  await fs.writeFile(path.join(root, 'other-user-data', 'keep.txt'), 'untouched');
  keepNames.push('other-user-data');
  assert.deepEqual(await downloadCheckpointed({ ...options(root, bytes),
    fetchImpl: async (_url, request) => {
      const { start, end } = rangeRequest(request);
      return rangeResponse(bytes, start, end);
    },
  }), bytes);
  await assert.rejects(fs.stat(path.join(root, stale)), { code: 'ENOENT' });
  assert.deepEqual((await fs.readdir(root)).sort(), keepNames.sort());
  assert.equal(await fs.readFile(path.join(root, 'other-user-data', 'keep.txt'), 'utf8'), 'untouched');
});

test('a real HTTP stream is aborted at the shared deadline without saving its unfinished range', async t => {
  const root = await temporaryRoot(t);
  const bytes = Buffer.alloc(8, 0x41);
  const controller = new AbortController();
  const server = http.createServer((req, res) => {
    assert.equal(req.headers.range, 'bytes=0-7');
    res.writeHead(206, { 'content-range': 'bytes 0-7/8', 'content-length': '8' });
    res.write(bytes.subarray(0, 1));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => {
    server.closeAllConnections();
    return new Promise(resolve => server.close(resolve));
  });
  let deadline;
  t.after(() => clearTimeout(deadline));
  await assert.rejects(downloadCheckpointed({ ...options(root, bytes),
    timeoutSignal(milliseconds) {
      assert.equal(milliseconds, 180000);
      return controller.signal;
    },
    async fetchImpl(_url, request) {
      const response = await fetch(`http://127.0.0.1:${server.address().port}`, request);
      // A short test timer represents the expiration of the production deadline.
      deadline = setTimeout(() => controller.abort(timeout()), 20);
      return response;
    },
  }), { name: 'TimeoutError' });
  const state = await savedCheckpoint(root);
  assert.equal(state.metadata.offset, 0);
  assert.equal((await fs.stat(path.join(state.directory, 'payload'))).size, 0);
});
