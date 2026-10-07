'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const policy = require('../server/adult-access-policy');
const source = fs.readFileSync(require.resolve('../server/index.js'), 'utf8');
const now = new Date('2026-10-04T12:00:00Z');

test('adult boundary uses the full birthday and rejects impossible/future dates', () => {
  assert.equal(policy.validateRegistrationAge('2008-10-04', now).age, 18);
  assert.equal(policy.validateRegistrationAge('2008-10-05', now).code, 'AGE_RESTRICTED');
  for (const birth of [null, '', 'tomorrow', '2008-02-30', '2027-01-01', '1800-01-01'])
    assert.ok(policy.validateRegistrationAge(birth, now).error, String(birth));
  assert.equal(policy.ageFromBirthDate('2008-02-29', new Date('2026-02-28Z')), 17);
  assert.equal(policy.ageFromBirthDate('2008-02-29', new Date('2026-03-01Z')), 18);
});

test('a database DATE in Israel does not shift the birthday one day early', () => {
  const { execFileSync } = require('node:child_process');
  const script = `const { ageFromBirthDate } = require(${JSON.stringify(require.resolve('../server/adult-access-policy'))});
    process.stdout.write(String(ageFromBirthDate(new Date(2008, 9, 5), new Date('2026-10-04T12:00:00Z'))));`;
  assert.equal(execFileSync(process.execPath, ['-e', script], {
    env: { ...process.env, TZ: 'Asia/Jerusalem' }, encoding: 'utf8',
  }), '17');
});

test('missing age permits only exact setup paths; known minors cannot replace their date', () => {
  const missing = { birth_date: null }, minor = { birth_date: '2015-01-01' };
  for (const path of ['/api/messages', '/api/upload', '/api/profile', '/api/calls/ice-servers'])
    assert.equal(policy.requestAgeError(missing, { method: 'GET', path }).code, 'BIRTH_DATE_REQUIRED');
  for (const [method, path] of [['PUT', '/api/profile/birth-date'], ['POST', '/api/link-phone']]) {
    assert.equal(policy.requestAgeError(missing, { method, path }), null);
    assert.equal(policy.requestAgeError(minor, { method, path }).code, 'AGE_RESTRICTED');
    assert.ok(policy.requestAgeError(missing, { method, path: path + '/bypass' }));
  }
  for (const user of [missing, minor]) {
    assert.equal(policy.requestAgeError(user, { method: 'DELETE', path: '/api/account' }), null);
    assert.ok(policy.requestAgeError(user, { method: 'GET', path: '/api/account' }));
  }
});

function section(start, end) {
  const a = source.indexOf(start), b = source.indexOf(end, a + start.length);
  assert.ok(a >= 0 && b > a, start);
  return source.slice(a, b);
}
function response() {
  return { statusCode: 200, status(code) { this.statusCode = code; return this; },
    json(body) { this.body = body; return this; } };
}
function contextFor(birthDate) {
  const user = { id: 'test', name: 'Test', phone: '0501234567', email: 'test@example.test',
    email_verified: true, gender: 'male', birth_date: birthDate, password_hash: 'hash' };
  const writes = [];
  const context = { ...policy, ...require('../server/session-security'),
    verifySession: () => ({ id: 'test' }), JWT_SECRET: 'adult-access-test',
    getPool: async () => ({ query: async (sql) => {
      if (!sql.trim().startsWith('SELECT')) writes.push(sql);
      return { rows: [user] };
    } }), accountModerationError: () => null, requestAudit: (_req, _res, next) => next(),
    console: { log() {}, warn() {}, error() {} }, logActivity() {},
    authRateLimit() {}, credentialRateLimit() {}, bcrypt: { compare: async () => true },
    provisionSystemConversation: async () => {}, process: { env: {} },
    fetch: async () => ({ json: async () => ({ sub: 'google-user', email: user.email,
      email_verified: true, aud: '862738339788-0o8jv308efqdhb0q21eo9ut74oqcff80.apps.googleusercontent.com' }) }),
  };
  return { context, writes, user };
}

for (const name of ['auth', 'authWithDbCheck', 'adminAuth']) {
  test(`${name} blocks old sessions for minors and unknown age`, async () => {
    const ends = { auth: '// Allows a saved session', authWithDbCheck: '// ── Socket.io', adminAuth: 'const DEFAULT_GOOGLE_PLAY_DESCRIPTION' };
    for (const birth of ['2015-01-01', null, '1990-01-01']) {
      const { context } = contextFor(birth); vm.createContext(context);
      vm.runInContext(section(`async function ${name}(`, ends[name]), context);
      const res = response(); let passed = false;
      await context[name]({ headers: { authorization: 'Bearer existing-token' }, method: 'GET', path: '/api/profile' }, res, () => { passed = true; });
      assert.equal(passed, birth === '1990-01-01');
      if (!passed) assert.equal(res.body.code, birth ? 'AGE_RESTRICTED' : 'BIRTH_DATE_REQUIRED');
    }
  });
}

test('socket handshake rejects missing and underage DOB before joining rooms', async () => {
  for (const birth of ['2015-01-01', null, '1990-01-01']) {
    const { context } = contextFor(birth); let middleware;
    context.io = { use(fn) { middleware = fn; } };
    vm.runInNewContext(section('io.use(async (socket, next)', 'async function claimExternalGroupInvites'), context);
    let error;
    await middleware({ handshake: { auth: { token: 'existing-token' } } }, value => { error = value; });
    assert.equal(!!error, birth !== '1990-01-01');
    if (error) assert.equal(error.data.code, birth ? 'AGE_RESTRICTED' : 'BIRTH_DATE_REQUIRED');
  }
});

for (const [route, end] of [
  ['/api/login', '// Resend verification'],
  ['/api/auth/google', '// ── Users'],
]) {
  test(`${route} denies an existing minor before issuing a token`, async () => {
    const { context, writes } = contextFor('2015-01-01'); let handler;
    context.app = { post(...args) { handler = args.at(-1); } };
    vm.runInNewContext(section(`app.post('${route}'`, end), context);
    const res = response();
    await handler({ body: { email: 'test@example.test', password: 'correct', idToken: 'mock-google-token' }, ip: '127.0.0.1' }, res);
    assert.equal(res.statusCode, 403);
    assert.equal(res.body.code, 'AGE_RESTRICTED');
    assert.equal(res.body.token, undefined);
    assert.deepEqual(writes, []);
  });
}

test('registration status returns a restriction rather than admission for an old minor', async () => {
  const { context } = contextFor('2015-01-01'); let handler;
  context.app = { get(_path, fn) { handler = fn; } };
  vm.runInNewContext(section("app.get('/api/registration-status'", '// Short-lived TURN'), context);
  const res = response();
  await handler({ headers: { authorization: 'Bearer existing-token' } }, res);
  assert.equal(res.statusCode, 403);
  assert.equal(res.body.code, 'AGE_RESTRICTED');
});
