'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(require.resolve('../server/index.js'), 'utf8');
const start = source.indexOf("app.post('/api/registration/verify-google'");
const end = source.indexOf("app.post('/api/auth/google'", start);

function fixture({ existing = false, payload = {} } = {}) {
  let handler;
  const queries = [];
  vm.runInNewContext(source.slice(start, end), {
    app: { post(_path, _limit, callback) { handler = callback; } },
    authRateLimit() {}, process: { env: { GOOGLE_CLIENT_ID: 'test-client' } },
    fetch: async () => ({ json: async () => ({ sub: 'google-subject',
      aud: 'test-client', email_verified: true, email: 'Aviv@example.invalid',
      name: 'Test User', ...payload }) }),
    getPool: async () => ({ query: async (sql, values) => {
      queries.push({ sql, values: Array.from(values) });
      return { rows: existing ? [{ id: 'existing-user' }] : [] };
    } }),
  });
  return async (body = { idToken: 'synthetic' }) => {
    const res = { statusCode: 200, status(code) { this.statusCode = code; return this; },
      json(data) { this.data = JSON.parse(JSON.stringify(data)); } };
    await handler({ body }, res);
    return { status: res.statusCode, data: res.data, queries };
  };
}

test('authenticated existing Google account selects login without registration details or writes', async () => {
  const result = await fixture({ existing: true })();
  assert.equal(result.status, 200);
  assert.equal(result.data.existingAccount, true);
  assert.equal(result.data.name, 'Test User'); // Compatibility with older clients.
  assert.equal(result.queries.length, 1);
  assert.match(result.queries[0].sql, /^SELECT id .*google_id = \$1 OR lower\(email\) = lower\(\$2\)/);
  assert.deepEqual(result.queries[0].values, ['google-subject', 'Aviv@example.invalid']);
});

test('unknown or deleted Google account continues new registration without creating an account yet', async () => {
  const result = await fixture()();
  assert.equal(result.status, 200);
  assert.equal(result.data.existingAccount, undefined);
  assert.equal(result.data.email, 'Aviv@example.invalid');
  assert.equal(result.queries.length, 1);
});

test('untrusted or unverified Google identity cannot probe whether an account exists', async () => {
  for (const payload of [{ aud: 'other-client' }, { email_verified: false }, { sub: null }]) {
    const result = await fixture({ existing: true, payload })();
    assert.equal(result.status, 401);
    assert.equal(result.queries.length, 0);
    assert.equal(result.data.existingAccount, undefined);
  }
  const missing = await fixture()({});
  assert.equal(missing.status, 400);
  assert.equal(missing.queries.length, 0);
});
