'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const test = require('node:test');
const { OAuth2Client } = require('google-auth-library');
const drive = require('../server/personal-drive');

test('Drive quota uses total Google usage and handles full, unlimited and invalid accounts', async t => {
  const saved = [process.env.GOOGLE_DRIVE_OAUTH_CLIENT_ID, process.env.GOOGLE_DRIVE_OAUTH_CLIENT_SECRET];
  process.env.GOOGLE_DRIVE_OAUTH_CLIENT_ID = 'test-id';
  process.env.GOOGLE_DRIVE_OAUTH_CLIENT_SECRET = 'test-secret';
  t.after(() => {
    for (const [i, key] of ['GOOGLE_DRIVE_OAUTH_CLIENT_ID', 'GOOGLE_DRIVE_OAUTH_CLIENT_SECRET'].entries()) {
      if (saved[i] === undefined) delete process.env[key];
      else process.env[key] = saved[i];
    }
  });
  let quota;
  t.mock.method(OAuth2Client.prototype, 'request', async function(options) {
    assert.equal(this.credentials.refresh_token, 'owner-token');
    assert.equal(new URL(options.url).searchParams.get('fields'), 'storageQuota(limit,usage)');
    assert.equal(options.timeout, 10000);
    return { data: { storageQuota: quota } };
  });
  quota = { limit: '15000000000', usage: '12500000000', usageInDrive: '100' };
  assert.deepEqual(await drive.getStorageQuota('owner-token'), {
    limitBytes: '15000000000', usedBytes: '12500000000', freeBytes: '2500000000', unlimited: false,
  });
  quota = { limit: '10', usage: '11' };
  assert.equal((await drive.getStorageQuota('owner-token')).freeBytes, '0');
  quota = { limit: '0', usage: '0' };
  assert.equal((await drive.getStorageQuota('owner-token')).unlimited, false);
  quota = { usage: '9007199254740993' };
  assert.deepEqual(await drive.getStorageQuota('owner-token'), {
    limitBytes: null, usedBytes: '9007199254740993', freeBytes: null, unlimited: true,
  });
  for (quota of [{}, { limit: '100', usage: '-1' }, { limit: 'bad', usage: '0' }]) {
    await assert.rejects(drive.getStorageQuota('owner-token'), /Invalid Google storage quota/);
  }
});

test('storage route is authenticated, owner scoped, and never returns tokens or provider errors', async () => {
  const source = fs.readFileSync(require.resolve('../server/index'), 'utf8');
  const route = source.slice(source.indexOf("app.get('/api/backup/google/storage'"),
    source.indexOf("app.post('/api/backup/google/verify'"));
  let handler;
  let account;
  let fail = false;
  let quotaCalls = 0;
  const auth = () => {};
  vm.runInNewContext(route, {
    app: { get(url, middleware, callback) {
      assert.equal(middleware, auth);
      handler = callback;
    } }, auth,
    getPool: async () => ({ query: async (sql, args) => {
      assert.match(sql, /WHERE user_id=\$1 AND provider='google_drive'/);
      assert.deepEqual(Array.from(args), ['owner-a']);
      return { rows: account ? [account] : [] };
    } }),
    personalDrive: {
      decryptRefreshToken(value, owner) {
        assert.equal(value, 'encrypted-secret');
        assert.equal(owner, 'owner-a');
        return 'private-token';
      },
      async getStorageQuota(token) {
        assert.equal(token, 'private-token');
        quotaCalls++;
        if (fail) throw new Error('provider private-token error');
        return { freeBytes: '50', limitBytes: '100', usedBytes: '50', unlimited: false };
      },
    },
  });
  async function request() {
    const res = { code: 200, set(k, v) { assert.equal(v, 'no-store'); },
      status(code) { this.code = code; return this; }, json(data) { this.data = data; } };
    await handler({ user: { id: 'owner-a' }, query: { userId: 'other-user' } }, res);
    assert.doesNotMatch(JSON.stringify(res.data), /private-token|encrypted-secret|provider/);
    return res;
  }
  assert.equal((await request()).data.status, 'disconnected');
  account = { status: 'error' };
  assert.equal((await request()).data.status, 'reconnect_required');
  assert.equal(quotaCalls, 0);
  account = { status: 'connected', encrypted_refresh_token: 'encrypted-secret' };
  assert.equal((await request()).data.freeBytes, '50');
  fail = true;
  const failed = await request();
  assert.equal(failed.code, 502);
  assert.equal(failed.data.status, 'unavailable');
});
