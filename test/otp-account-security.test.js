'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { consumeOtp } = require('../server/otp-security');
const { signSession } = require('../server/session-security');
const source = fs.readFileSync(require.resolve('../server/index.js'), 'utf8');

function fixture({ existingPhone = false, existingEmail = false } = {}) {
  let handler;
  const writes = [];
  const phone = '0501234567';
  const otpStore = new Map([[phone, { code: '123456', expires: Date.now() + 60000,
    email: 'claimed@example.test', name: 'Test user', acceptedTerms: true,
    ageConfirmed: true, gender: 'male', birthDate: '1990-01-01' }]]);
  const user = { id: 'test-user', email: 'claimed@example.test', session_version: 0 };
  const pool = { async query(sql, values) {
    if (/SELECT.*FROM users WHERE phone=/s.test(sql)) return { rows: existingPhone ? [user] : [] };
    if (/SELECT.*FROM users WHERE lower\(email\)/s.test(sql)) return { rows: existingEmail ? [user] : [] };
    writes.push({ sql, values }); return { rows: [user] };
  } };
  const start = source.indexOf("app.post('/api/verify-otp'");
  const end = source.indexOf('// ── Link Phone', start);
  vm.runInNewContext(source.slice(start, end), {
    app: { post(_path, _limit, _credentials, callback) { handler = callback; } },
    authRateLimit() {}, credentialRateLimit() {}, otpStore, consumeOtp,
    getPool: async () => pool, signSession, JWT_SECRET: 'isolated-test-key',
    validateRegistrationAge: () => ({ birthDate: '1990-01-01' }),
    NEW_ACCOUNT_CONTENT_FILTER: {}, provisionSystemConversation: async () => {}, logActivity() {},
  });
  const invoke = async () => {
    const res = { code: 200, status(code) { this.code = code; return this; }, json(value) { this.body = value; } };
    await handler({ body: { phone, code: '123456' }, app: { get: () => ({ emit() {} }) } }, res);
    return res;
  };
  return { invoke, writes };
}

test('SMS possession never links or logs into a different email account', async () => {
  const f = fixture({ existingEmail: true });
  const res = await f.invoke();
  assert.equal(res.code, 409);
  assert.equal(res.body.token, undefined);
  assert.deepEqual(f.writes, []);
});

test('SMS login verifies only the phone and concurrent replay cannot issue a second session', async () => {
  const f = fixture({ existingPhone: true });
  const results = await Promise.all([f.invoke(), f.invoke()]);
  assert.deepEqual(results.map(r => r.code).sort(), [200, 400]);
  assert.equal(f.writes.length, 1);
  assert.match(f.writes[0].sql, /SET phone_verified=TRUE/);
  assert.doesNotMatch(f.writes[0].sql, /email_verified/);
});

test('new SMS accounts have no predictable password and do not verify the claimed email', async () => {
  const f = fixture();
  assert.equal((await f.invoke()).code, 200);
  const insert = f.writes.find(item => item.sql.includes('INSERT INTO users'));
  assert.equal(insert.values[3], null);
  assert.match(insert.sql, /TRUE, FALSE, now\(\)/);
});
