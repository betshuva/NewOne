'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const test = require('node:test');
const vm = require('node:vm');
const express = require('express');
const jwt = require('jsonwebtoken');
const { createApiRateLimit, verifiedSessionId } = require('../server/api-rate-limit');

const source = fs.readFileSync(require.resolve('../server/index.js'), 'utf8');
const secret = 'isolated-rate-limit-test-secret-never-used-by-the-application';
const ip = '192.0.2.20';

function section(startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start + startMarker.length);
  assert.ok(start >= 0 && end > start, `missing server section: ${startMarker}`);
  return source.slice(start, end);
}

function sign(id, options = {}) {
  return jwt.sign({ id }, secret, { expiresIn: '5m', ...options });
}

function response() {
  return {
    statusCode: 200,
    headers: {},
    body: undefined,
    passed: false,
    set(name, value) {
      if (typeof name === 'object') Object.assign(this.headers, name);
      else this.headers[name] = value;
      return this;
    },
    status(code) { this.statusCode = code; return this; },
    json(value) { this.body = JSON.parse(JSON.stringify(value)); return this; },
  };
}

function limiterHarness() {
  let now = 2_000_000_000_000;
  const cleanup = [];
  const context = {
    Date: { now: () => now },
    console: { warn() {} },
    clientIp: req => req.ip,
    setInterval(callback) {
      cleanup.push(callback);
      return { unref() {} };
    },
  };
  const createRateLimiter = vm.runInNewContext(
    `${section('function createRateLimiter(', 'const normalizedCredential =')};createRateLimiter`,
    context,
  );
  return {
    createRateLimiter,
    clientIp: context.clientIp,
    getSecret: () => secret,
    advance(ms) { now += ms; },
    cleanup() { cleanup.forEach(callback => callback()); },
  };
}

function invoke(middleware, { token, method = 'GET', path = '/users', address = ip,
  user, authorization } = {}) {
  const req = {
    method, path, ip: address, originalUrl: `/api${path}`,
    headers: authorization !== undefined ? { authorization }
      : token ? { authorization: `Bearer ${token}` } : {},
    ...(user ? { user } : {}),
  };
  const res = response();
  middleware(req, res, () => { res.passed = true; });
  return res;
}

function exhaust(middleware, options, count = 600) {
  let res;
  for (let i = 0; i < count; i++) {
    res = invoke(middleware, options);
    assert.equal(res.passed, true, `request ${i + 1} should fit the budget`);
  }
  assert.equal(res.headers['RateLimit-Remaining'], '0');
  return invoke(middleware, options);
}

test('verified users sharing an IP receive independent budgets, without authenticating the request', () => {
  const harness = limiterHarness();
  const api = createApiRateLimit(harness);
  const first = sign('account-first');
  const second = sign('account-second');
  assert.equal(exhaust(api, { token: first }).statusCode, 429);
  const res = invoke(api, { token: second });
  assert.equal(res.passed, true);
  assert.equal(res.headers['RateLimit-Remaining'], '599');
  assert.equal(invoke(api).headers['RateLimit-Remaining'], '599');

  const req = { method: 'GET', path: '/users', ip, headers: { authorization: `Bearer ${second}` } };
  api(req, response(), () => {});
  assert.equal(req.user, undefined, 'budget verification must not stand in for route authentication');
});

test('different sessions and IPs belonging to one account share a budget', () => {
  const api = createApiRateLimit(limiterHarness());
  const first = sign('same-account', { jwtid: 'first-session' });
  const second = sign('same-account', { jwtid: 'second-session' });
  assert.notEqual(first, second);
  assert.equal(exhaust(api, { token: first }).statusCode, 429);
  assert.equal(invoke(api, { token: second, address: '198.51.100.12' }).statusCode, 429);
});

test('forged, expired, proof and malformed sessions retain the anonymous IP limit', () => {
  const api = createApiRateLimit(limiterHarness());
  assert.equal(exhaust(api, {}).statusCode, 429);
  const rejected = [
    jwt.sign({ id: 'forged' }, 'untrusted-secret'),
    sign('expired', { expiresIn: -1 }),
    jwt.sign({ purpose: 'registration', method: 'phone', value: 'test' }, secret),
    jwt.sign({ id: 'proof-with-id', purpose: 'registration' }, secret),
    jwt.sign({ id: 'wrong-algorithm' }, secret, { algorithm: 'HS384' }),
    jwt.sign({ id: '' }, secret),
    jwt.sign({ id: '   ' }, secret),
    jwt.sign({ id: 42 }, secret),
    jwt.sign({ id: 'x'.repeat(129) }, secret),
    'not-a-token',
  ];
  for (const token of rejected) {
    assert.equal(verifiedSessionId({ headers: { authorization: `Bearer ${token}` } }, secret), null);
    for (const [method, path] of [['GET', '/registration-status'], ['PUT', '/profile/birth-date']]) {
      assert.equal(invoke(api, { token, method, path }).statusCode, 429,
        'unverified credentials must not gain the reserved account setup budget');
    }
  }
  assert.equal(invoke(api, { user: { id: 'untrusted-prepopulated-user' } }).statusCode, 429);
  assert.equal(invoke(api, { authorization: `Basic ${sign('account')}` }).statusCode, 429);
  assert.equal(invoke(api, { authorization: `Bearer ${sign('account')} extra` }).statusCode, 429);
  assert.equal(invoke(api, { address: '203.0.113.11' }).passed, true);
});

test('setup checks and DOB saves stay reachable after general exhaustion and have separate limits', () => {
  const api = createApiRateLimit(limiterHarness());
  const token = sign('finishing-setup');
  assert.equal(exhaust(api, { token }).statusCode, 429);
  const status = { token, path: '/registration-status' };
  const save = { token, method: 'PUT', path: '/profile/birth-date' };
  const statusBlocked = exhaust(api, status, 60);
  assert.equal(statusBlocked.statusCode, 429);
  assert.equal(statusBlocked.headers['RateLimit-Limit'], '60');
  const saveBlocked = exhaust(api, save, 10);
  assert.equal(saveBlocked.statusCode, 429);
  assert.equal(saveBlocked.headers['RateLimit-Limit'], '10');
  assert.equal(invoke(api, { token: sign('another-account'), path: status.path }).passed, true);
  assert.equal(invoke(api, { token: sign('another-account'), method: save.method, path: save.path }).passed, true);
});

test('reserved setup budgets match exact paths and methods only', () => {
  const api = createApiRateLimit(limiterHarness());
  const token = sign('precise-routing');
  assert.equal(exhaust(api, { token }).statusCode, 429);
  for (const [method, path] of [
    ['POST', '/registration-status'],
    ['GET', '/profile/birth-date'],
    ['DELETE', '/profile/birth-date'],
    ['GET', '/registration-status/anything'],
    ['PUT', '/profile/birth-date/anything'],
    ['GET', '/registration-status-other'],
    ['PUT', '/profile/birth-date-other'],
  ]) assert.equal(invoke(api, { token, method, path }).statusCode, 429);
  assert.equal(invoke(api, { token, path: '/registration-status' }).passed, true);
  assert.equal(invoke(api, { token, method: 'PUT', path: '/profile/birth-date' }).passed, true);
});

test('429 responses expose a consistent retry deadline and the window resets', () => {
  const harness = limiterHarness();
  const api = createApiRateLimit(harness);
  const token = sign('retry-window');
  let res = exhaust(api, { token, method: 'PUT', path: '/profile/birth-date' }, 10);
  assert.equal(res.statusCode, 429);
  assert.deepEqual(res.body, {
    error: 'בוצעו יותר מדי בקשות. נסה שוב בעוד מספר דקות',
    code: 'RATE_LIMITED', retryAfterSeconds: 300,
  });
  assert.equal(res.headers['Retry-After'], '300');
  assert.equal(res.headers['RateLimit-Remaining'], '0');
  const reset = res.headers['RateLimit-Reset'];
  harness.advance(299_100);
  res = invoke(api, { token, method: 'PUT', path: '/profile/birth-date' });
  assert.equal(res.body.retryAfterSeconds, 1);
  assert.equal(res.headers['Retry-After'], '1');
  assert.equal(res.headers['RateLimit-Reset'], reset);
  harness.advance(900);
  harness.cleanup();
  res = invoke(api, { token, method: 'PUT', path: '/profile/birth-date' });
  assert.equal(res.passed, true);
  assert.equal(res.headers['RateLimit-Remaining'], '9');
  assert.equal(res.headers['Retry-After'], undefined);
});

test('underlying limiter bounds rotated identifiers and expires old buckets', () => {
  const harness = limiterHarness();
  const limiter = harness.createRateLimiter({
    max: 1, windowMs: 1000, maxBuckets: 2, message: 'limited', keyGenerator: req => req.ip,
  });
  assert.equal(invoke(limiter, { address: 'one' }).passed, true);
  assert.equal(invoke(limiter, { address: 'one' }).statusCode, 429);
  assert.equal(invoke(limiter, { address: 'two' }).passed, true);
  assert.equal(invoke(limiter, { address: 'three' }).passed, true);
  assert.equal(invoke(limiter, { address: 'one' }).passed, true,
    'oldest bucket is evicted once the configured capacity is reached');
  harness.advance(1000);
  harness.cleanup();
  assert.equal(invoke(limiter, { address: 'one' }).passed, true);
});

test('the real API mount uses verified account budgets and preserves independently limited support routes', () => {
  const harness = limiterHarness();
  let mounted;
  const context = {
    ...harness, createApiRateLimit, JWT_SECRET: secret,
    app: { use(path, handler) { assert.equal(path, '/api'); mounted = handler; } },
  };
  vm.runInNewContext(
    section('const apiRateLimit = createApiRateLimit(', 'const authRateLimit =') +
    section("app.use('/api', (req, res, next) => {", "app.get('/app',"),
    context,
  );
  const token = sign('mounted-account');
  assert.equal(exhaust(mounted, { token }).statusCode, 429);
  assert.equal(invoke(mounted, { token, path: '/registration-status' }).passed, true);
  assert.equal(invoke(mounted, { token, method: 'PUT', path: '/profile/birth-date' }).passed, true);
  assert.equal(invoke(mounted, { token, path: '/support-issues' }).passed, true);
  assert.equal(invoke(mounted, { token, path: '/support-issues/issue-id' }).passed, true);
  assert.equal(invoke(mounted, { token, path: '/support-issues-other' }).statusCode, 429);
});

test('Express strips the /api mount prefix before choosing the reserved setup budget', async t => {
  const app = express();
  const harness = limiterHarness();
  let mounted;
  vm.runInNewContext(
    section('const apiRateLimit = createApiRateLimit(', 'const authRateLimit =') +
    section("app.use('/api', (req, res, next) => {", "app.get('/app',"),
    { ...harness, createApiRateLimit, JWT_SECRET: secret,
      app: { use(path, handler) { mounted = handler; app.use(path, handler); } } },
  );
  app.use('/api', (req, res) => res.json({ path: req.path, authenticatedByLimiter: !!req.user }));
  const token = sign('express-mounted-account');
  assert.equal(exhaust(mounted, { token }).statusCode, 429);
  const server = http.createServer(app);
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  t.after(() => new Promise((resolve, reject) => {
    server.closeAllConnections();
    server.close(error => error ? reject(error) : resolve());
  }));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const headers = { Authorization: `Bearer ${token}`, Connection: 'close' };
  for (const [method, path] of [['GET', '/registration-status'], ['PUT', '/profile/birth-date']]) {
    const res = await fetch(`${origin}/api${path}?source=test`, { method, headers });
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { path, authenticatedByLimiter: false });
  }
  const blocked = await fetch(`${origin}/api/users`, { headers });
  assert.equal(blocked.status, 429);
  assert.equal(blocked.headers.get('Retry-After'), '300');
  assert.equal((await blocked.json()).code, 'RATE_LIMITED');
});

function registrationHandler(getPool) {
  let handler;
  vm.runInNewContext(section("app.get('/api/registration-status',", '// Short-lived TURN REST credentials.'), {
    app: { get(path, callback) { assert.equal(path, '/api/registration-status'); handler = callback; } },
    jwt, JWT_SECRET: secret, getPool,
  });
  return handler;
}

async function checkRegistration(handler, token = sign('status-account')) {
  const res = response();
  await handler({ headers: token ? { authorization: `Bearer ${token}` } : {} }, res);
  return res;
}

test('registration status returns explicit DOB presence without writing account data', async () => {
  for (const birthDate of [null, '2003-09-10']) {
    const queries = [];
    const handler = registrationHandler(async () => ({
      async query(sql, values) {
        queries.push({ sql, values: Array.from(values) });
        return { rows: [{ name: 'Test account', gender: 'male', phone: 'test',
          email_verified: true, phone_verified: false, birth_date: birthDate }] };
      },
    }));
    const res = await checkRegistration(handler);
    assert.equal(res.statusCode, 200);
    assert.deepEqual(res.body, { phoneMissing: false, verificationRequired: false,
      birthDateMissing: birthDate == null, registrationIncomplete: false });
    assert.equal(queries.length, 1);
    assert.match(queries[0].sql, /^SELECT\b/);
    assert.doesNotMatch(queries[0].sql, /\b(?:UPDATE|INSERT|DELETE)\b/i);
    assert.deepEqual(queries[0].values, ['status-account']);
  }
});

test('registration status reports pool and query outages as retryable 503, not an invalid session', async () => {
  for (const getPool of [
    async () => { throw new Error('unavailable pool'); },
    async () => ({ query: async () => { throw new Error('query temporarily failed'); } }),
  ]) {
    const res = await checkRegistration(registrationHandler(getPool));
    assert.equal(res.statusCode, 503);
    assert.equal(res.body.code, 'REGISTRATION_STATUS_UNAVAILABLE');
    assert.equal(res.body.birthDateMissing, undefined);
    assert.doesNotMatch(JSON.stringify(res.body), /unavailable pool|query temporarily failed/);
  }
});

test('registration status rejects invalid sessions before touching the database', async () => {
  let calls = 0;
  const handler = registrationHandler(async () => { calls++; throw new Error('must not query'); });
  for (const token of [
    null, 'malformed', jwt.sign({ id: 'forged' }, 'other-secret'),
    sign('expired', { expiresIn: -1 }),
    jwt.sign({ purpose: 'registration', method: 'phone', value: 'test' }, secret),
    jwt.sign({ purpose: 'registration', id: 'proof-id' }, secret),
  ]) assert.equal((await checkRegistration(handler, token)).statusCode, 401);
  assert.equal(calls, 0);
});

test('registration status still rejects a valid token whose account no longer exists', async () => {
  const handler = registrationHandler(async () => ({ query: async () => ({ rows: [] }) }));
  assert.equal((await checkRegistration(handler)).statusCode, 401);
});
