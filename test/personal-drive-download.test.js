'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '..', 'server', 'personal-drive.js'), 'utf8');

function fixture(fetchImpl, checkpointDownload) {
  let now = 0;
  const timers = [], timeoutCalls = [], requests = [];
  const clock = {
    advance(milliseconds) {
      now += milliseconds;
      for (const timer of timers) {
        if (timer.deadline <= now && !timer.controller.signal.aborted)
          timer.controller.abort(new DOMException('The operation was aborted due to timeout', 'TimeoutError'));
      }
    },
  };
  class FakeOAuth2Client {
    setCredentials(value) { this.credentials = value; }
    async getRequestHeaders() {
      assert.equal(this.credentials.refresh_token, 'fake-refresh-token');
      return { Authorization: 'Bearer fake-access-token' };
    }
  }
  const module = { exports: {} };
  vm.runInNewContext(source, {
    module, Buffer, URLSearchParams,
    process: { env: {
      GOOGLE_DRIVE_OAUTH_CLIENT_ID: 'fake-client-id',
      GOOGLE_DRIVE_OAUTH_CLIENT_SECRET: 'fake-client-secret',
    } },
    require(name) {
      if (name === 'google-auth-library') return { OAuth2Client: FakeOAuth2Client };
      if (name === 'crypto') return require('node:crypto');
      if (name === './drive-download-checkpoint' && checkpointDownload)
        return { downloadCheckpointed: checkpointDownload };
      throw new Error(`Unexpected dependency: ${name}`);
    },
    AbortSignal: {
      timeout(milliseconds) {
        timeoutCalls.push(milliseconds);
        const controller = new AbortController();
        timers.push({ controller, deadline: now + milliseconds });
        return controller.signal;
      },
    },
    async fetch(url, options) {
      requests.push({ url, options });
      return fetchImpl(url, options, clock);
    },
  }, { filename: 'personal-drive.js' });
  return { download: module.exports.downloadAppDataFile, timeoutCalls, requests };
}

test('large files opt into checkpointed downloads with explicit ownership and checksum bounds', async () => {
  const opts = { checkpointRoot: '/fixture-only', ownerKey: 'owner',
    expectedBytes: 128 * 1024 * 1024, expectedSha256: 'a'.repeat(64) };
  let forwarded;
  const bytes = Buffer.from('checkpoint result');
  const f = fixture(() => assert.fail('opted-in download must use its checkpoint helper'),
    async input => { forwarded = input; return bytes; });
  assert.deepEqual(await f.download('fake-refresh-token', 'file', opts.expectedBytes + 1024, opts), bytes);
  assert.equal(forwarded.fileId, 'file');
  assert.equal(forwarded.maxBytes, opts.expectedBytes + 1024);
  for (const name of Object.keys(opts)) assert.equal(forwarded[name], opts[name]);
  assert.equal(forwarded.client.credentials.refresh_token, 'fake-refresh-token');
  assert.equal(f.requests.length, 0);
});

test('small files preserve the legacy download path even when checkpoint options are supplied', async () => {
  const bytes = Buffer.from('small manifest');
  const f = fixture(async () => response({ bytes }),
    () => assert.fail('small files must not create a checkpoint'));
  assert.deepEqual(await f.download('fake-refresh-token', 'file', 1024,
    { checkpointRoot: '/fixture-only', ownerKey: 'owner', expectedBytes: bytes.length,
      expectedSha256: 'a'.repeat(64) }), bytes);
  assert.deepEqual(f.timeoutCalls, [180000]);
  assert.equal(f.requests.length, 1);
});

function response({ bytes = Buffer.alloc(0), declared, status = 200, read } = {}) {
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: new Headers(declared === undefined ? {} : { 'content-length': String(declared) }),
    arrayBuffer: read || (async () => bytes),
  };
}

test('an active Drive response body can complete after two minutes and before three minutes', async () => {
  const chunks = [Buffer.from('first-'), Buffer.from('second-'), Buffer.from('third')];
  let progress = 0;
  const f = fixture(async (_url, { signal }, clock) => response({ read: async () => {
    for (const delay of [60000, 60000, 59999]) {
      clock.advance(delay);
      signal.throwIfAborted();
      progress++;
    }
    return Buffer.concat(chunks);
  } }));
  const downloaded = await f.download('fake-refresh-token', 'fake/id', 100);
  assert.deepEqual(downloaded, Buffer.concat(chunks));
  assert.equal(progress, 3);
  assert.deepEqual(f.timeoutCalls, [180000]);
  assert.equal(f.requests.length, 1);
  assert.equal(f.requests[0].url, 'https://www.googleapis.com/drive/v3/files/fake%2Fid?alt=media');
  assert.equal(f.requests[0].options.headers.Authorization, 'Bearer fake-access-token');
});

test('the total three-minute deadline still aborts an active response body without returning partial bytes', async () => {
  let progress = 0;
  const f = fixture(async (_url, { signal }, clock) => response({ read: async () => {
    for (let chunk = 0; chunk < 3; chunk++) {
      clock.advance(60000);
      signal.throwIfAborted();
      progress++;
    }
    return Buffer.from('incomplete');
  } }));
  await assert.rejects(f.download('fake-refresh-token', 'file-id', 100), { name: 'TimeoutError' });
  assert.equal(progress, 2);
  assert.deepEqual(f.timeoutCalls, [180000]);
  assert.equal(f.requests.length, 1);
});

test('the three-minute deadline also preserves a fetch timeout before response headers', async () => {
  const f = fixture(async (_url, { signal }, clock) => {
    clock.advance(180000);
    signal.throwIfAborted();
    assert.fail('timed-out fetch continued');
  });
  await assert.rejects(f.download('fake-refresh-token', 'file-id'), { name: 'TimeoutError' });
  assert.deepEqual(f.timeoutCalls, [180000]);
  assert.equal(f.requests.length, 1);
});

test('a declared oversized file is rejected before reading its body', async () => {
  let bodyRead = false;
  const f = fixture(async () => response({ declared: 9, read: async () => {
    bodyRead = true;
    return Buffer.alloc(9);
  } }));
  await assert.rejects(f.download('fake-refresh-token', 'file-id', 8), /file exceeds size limit/);
  assert.equal(bodyRead, false);
});

for (const declared of [undefined, 8]) {
  test(`actual size remains bounded when content-length is ${declared === undefined ? 'absent' : 'understated'}`, async () => {
    const f = fixture(async () => response({ bytes: Buffer.alloc(9), declared }));
    await assert.rejects(f.download('fake-refresh-token', 'file-id', 8), /file exceeds size limit/);
    assert.equal(f.requests.length, 1);
  });
}

test('a body exactly at the caller size ceiling is returned unchanged', async () => {
  const bytes = Buffer.from([0, 255, 13, 10, 128]);
  const f = fixture(async () => response({ bytes, declared: bytes.length }));
  assert.deepEqual(await f.download('fake-refresh-token', 'file-id', bytes.length), bytes);
});

for (const status of [403, 503]) {
  test(`HTTP ${status} remains an error and its response body is not downloaded`, async () => {
    let bodyRead = false;
    const f = fixture(async () => response({ status, read: async () => {
      bodyRead = true;
      return Buffer.from('upstream error');
    } }));
    await assert.rejects(f.download('fake-refresh-token', 'file-id'),
      new RegExp(`Google appDataFolder download failed \\(${status}\\)`));
    assert.equal(bodyRead, false);
    assert.equal(f.requests.length, 1);
  });
}
