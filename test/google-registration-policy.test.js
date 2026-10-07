'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const express = require('express');
const { googleRegistrationRequired } = require('../server/registration-policy');
const source = fs.readFileSync(require.resolve('../server/index.js'), 'utf8');

test('retired signup routes reject even complete legacy input without database access', async t => {
  const app = express();
  app.use(express.json());
  const start = source.indexOf("app.post('/api/register'");
  const end = source.indexOf('// ── Login', start);
  vm.runInNewContext(source.slice(start, end), {
    app, authRateLimit: (_req, _res, next) => next(), googleRegistrationRequired,
  });
  const server = app.listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  t.after(() => new Promise(resolve => { server.close(resolve); server.closeAllConnections(); }));
  for (const path of ['/api/register', '/api/registration/send-code', '/api/registration/verify-code']) {
    const response = await fetch(`http://127.0.0.1:${server.address().port}${path}`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ acceptedTerms: true, ageConfirmed: true, method: 'email',
        email: 'test@example.invalid', password: 'synthetic-test-password', code: '123456' }),
    });
    assert.equal(response.status, 409);
    assert.equal((await response.json()).code, 'GOOGLE_REGISTRATION_REQUIRED');
  }
});

function smsFixture(existing, authenticated = false) {
  let handler, sent = 0;
  const context = {
    app: { post(_path, _limit, _otpLimit, callback) { handler = callback; } },
    authRateLimit() {}, otpRateLimit() {},
    normalizeIsraeliMobile: x => x, isValidIsraeliMobile: () => true,
    getPool: async () => ({ query: async sql => ({ rows:
      sql.includes('session_version') ? [{ session_version: 0 }] : existing ? [{}] : [] }) }),
    verifySession: () => ({ id: 'existing', session_version: 0 }),
    sessionCurrent: () => authenticated, JWT_SECRET: 'test', googleRegistrationRequired,
    crypto: { randomInt: () => 123456 }, otpStore: new Map(),
    parseBirthDate: () => null, requestedRegistrationFilter: () => null,
    sendEmail: async () => { sent++; },
  };
  const start = source.indexOf("app.post('/api/send-otp'");
  vm.runInNewContext(source.slice(start, source.indexOf('// ── Verify OTP', start)), context);
  return { invoke: async () => {
    const res = { code: 200, status(code) { this.code = code; return this; }, json(body) { this.body = body; } };
    await handler({ body: { phone: '0501234567' }, headers: authenticated ? { authorization: 'Bearer synthetic' } : {} }, res);
    return { status: res.code, code: res.body.code, sent };
  } };
}

test('unknown phone cannot send registration SMS; existing and authenticated linking still work', async () => {
  assert.deepEqual(await smsFixture(false).invoke(), { status: 409, code: 'GOOGLE_REGISTRATION_REQUIRED', sent: 0 });
  assert.deepEqual(await smsFixture(true).invoke(), { status: 200, code: undefined, sent: 1 });
  assert.deepEqual(await smsFixture(false, true).invoke(), { status: 200, code: undefined, sent: 1 });
});
