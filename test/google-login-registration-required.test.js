'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { accountAgeError, validateRegistrationAge } = require('../server/adult-access-policy');
const { normalizeContentFilter, NEW_ACCOUNT_CONTENT_FILTER } = require('../server/content-filter-policy');

const source = fs.readFileSync(require.resolve('../server/index.js'), 'utf8');
const routeStart = source.indexOf("app.post('/api/auth/google'");
const routeEnd = source.indexOf('// ── Users', routeStart);
const filterStart = source.indexOf('function requestedRegistrationFilter(');
const filterEnd = source.indexOf('async function getEffectiveRecipientFilter', filterStart);

function fixture({ existingByGoogle = null, existingByEmail = null, payload = {},
  tokeninfoFailure = false, databaseFailure = false } = {}) {
  const calls = { fetch: [], queries: [], sessions: [], provisioned: [], invites: [], broadcasts: [] };
  let handler;
  const context = {
    app: { post(_path, _limit, callback) { handler = callback; } },
    authRateLimit() {}, process: { env: { GOOGLE_CLIENT_ID: 'fixture-google-client' } },
    console: { log() {}, warn() {}, error() {} },
    normalizeContentFilter, NEW_ACCOUNT_CONTENT_FILTER, accountAgeError, validateRegistrationAge,
    JWT_SECRET: 'isolated-test-secret',
    fetch: async url => {
      calls.fetch.push(url);
      if (tokeninfoFailure) throw new Error('isolated Google service failure');
      return { json: async () => ({ sub: 'fixture-google-subject', aud: 'fixture-google-client',
        email_verified: true, email: 'verified@example.invalid', name: 'Verified Google User',
        picture: 'https://example.invalid/avatar', ...payload }) };
    },
    getPool: async () => ({ query: async (sql, values) => {
      calls.queries.push({ sql, values: values ? Array.from(values) : [] });
      if (databaseFailure) throw new Error('isolated database failure');
      if (sql.includes('SELECT * FROM users WHERE google_id'))
        return { rows: existingByGoogle ? [existingByGoogle] : [] };
      if (sql.includes('SELECT * FROM users WHERE lower(email)'))
        return { rows: existingByEmail ? [existingByEmail] : [] };
      if (sql.includes('INSERT INTO users')) return { rows: [{ id: 'created-user',
        name: 'Verified Google User', email: 'verified@example.invalid', birth_date: '1980-01-01',
        email_verified: true, google_id: 'fixture-google-subject', password_hash: 'must-not-return' }] };
      if (sql.includes('UPDATE users')) return { rows: [] };
      throw new Error('Unexpected SQL in isolated route fixture');
    } }),
    signSession: user => { calls.sessions.push(user.id); return 'isolated-session'; },
    provisionSystemConversation: async (_pool, id) => { calls.provisioned.push(id); },
    claimAppInvite: async (id, inviteId) => { calls.invites.push({ id, inviteId }); },
    logActivity() {},
  };
  vm.runInNewContext(source.slice(filterStart, filterEnd) + source.slice(routeStart, routeEnd), context);
  return { calls, invoke: async (body = { idToken: 'isolated-google-token' }) => {
    const res = { statusCode: 200, status(code) { this.statusCode = code; return this; },
      json(data) { this.data = JSON.parse(JSON.stringify(data)); } };
    const req = { body, ip: '127.0.0.1', app: { get(key) {
      assert.equal(key, 'io'); return { emit: (event, data) => calls.broadcasts.push({ event, data }) };
    } } };
    await handler(req, res);
    return { status: res.statusCode, data: res.data };
  } };
}

const adult = { id: 'existing-user', email: 'verified@example.invalid',
  google_id: 'fixture-google-subject', name: 'Existing User', phone: '0501234567',
  birth_date: '1980-01-01', password_hash: 'must-not-return' };
const completedRegistration = { idToken: 'isolated-google-token', acceptedTerms: true, ageConfirmed: true,
  contentFilterConfirmed: true, contentFilter: { ...NEW_ACCOUNT_CONTENT_FILTER, enforceGeneralFilter: true },
  gender: 'male', birthDate: '1980-01-01', inviteId: 'isolated-invite' };

test('verified unknown Google login returns the explicit registration branch without creating or authenticating an account', async () => {
  for (const declarations of [{}, { acceptedTerms: true }, { ageConfirmed: true }]) {
    const h = fixture();
    const result = await h.invoke({ idToken: 'isolated-google-token', ...declarations });
    assert.equal(result.status, 400);
    assert.equal(result.data.code, 'REGISTRATION_REQUIRED');
    assert.equal(result.data.token, undefined);
    assert.deepEqual(h.calls.queries.map(call => /^SELECT/.test(call.sql)), [true, true]);
    assert.deepEqual(h.calls.sessions, []);
    assert.deepEqual(h.calls.provisioned, []);
    assert.deepEqual(h.calls.invites, []);
    assert.deepEqual(h.calls.broadcasts, []);
  }
});

test('existing Google identity still signs in before any new registration declarations are considered', async () => {
  const h = fixture({ existingByGoogle: adult });
  const result = await h.invoke({ idToken: 'isolated-google-token', contentFilter: 'invalid', gender: 'invalid' });
  assert.equal(result.status, 200);
  assert.equal(result.data.token, 'isolated-session');
  assert.equal(result.data.user.id, adult.id);
  assert.equal(result.data.user.password_hash, undefined);
  assert.equal(result.data.code, undefined);
  assert.equal(h.calls.queries.length, 1);
  assert.deepEqual(h.calls.sessions, [adult.id]);
  assert.deepEqual(h.calls.provisioned, []);
  assert.deepEqual(h.calls.invites, []);
});

test('verified email match retains its existing link-and-login behavior without creating a duplicate', async () => {
  const h = fixture({ existingByEmail: { ...adult, google_id: null } });
  const result = await h.invoke();
  assert.equal(result.status, 200);
  assert.equal(result.data.user.id, adult.id);
  assert.equal(result.data.code, undefined);
  assert.equal(h.calls.queries.length, 3);
  assert.match(h.calls.queries[2].sql, /^UPDATE users/);
  assert.deepEqual(h.calls.queries[2].values,
    ['fixture-google-subject', 'https://example.invalid/avatar', adult.id]);
  assert.ok(!h.calls.queries.some(call => call.sql.includes('INSERT')));
  assert.deepEqual(h.calls.sessions, [adult.id]);
});

test('missing, expired, untrusted or unverified Google credentials cannot select registration', async () => {
  const missing = fixture();
  const missingResponse = await missing.invoke({});
  assert.equal(missingResponse.status, 400);
  assert.equal(missingResponse.data.code, undefined);
  assert.equal(missing.calls.fetch.length, 0);
  assert.equal(missing.calls.queries.length, 0);
  for (const payload of [{ sub: null }, { error_description: 'Expired Google credential' },
    { aud: 'foreign-client' }, { email_verified: false }]) {
    const h = fixture({ payload });
    const result = await h.invoke();
    assert.equal(result.status, 401);
    assert.equal(result.data.code, undefined);
    assert.equal(h.calls.queries.length, 0);
    assert.deepEqual(h.calls.sessions, []);
  }
});

test('restricted existing accounts remain age errors rather than becoming new registration', async () => {
  for (const match of ['existingByGoogle', 'existingByEmail']) {
    const h = fixture({ [match]: { ...adult, birth_date: '2015-01-01' } });
    const result = await h.invoke(completedRegistration);
    assert.equal(result.status, 403);
    assert.equal(result.data.code, 'AGE_RESTRICTED');
    assert.deepEqual(h.calls.sessions, []);
    assert.ok(h.calls.queries.every(call => call.sql.startsWith('SELECT')));
  }
});

test('terms and age confirmation do not bypass registration filter, gender or birth-date validation', async () => {
  for (const changes of [{ contentFilterConfirmed: false }, { contentFilter: {} },
    { contentFilter: { ...NEW_ACCOUNT_CONTENT_FILTER, enforceGeneralFilter: 'true' } },
    { gender: 'invalid' }, { birthDate: 'invalid' }, { birthDate: '2015-01-01' }]) {
    const h = fixture();
    const result = await h.invoke({ ...completedRegistration, ...changes });
    assert.equal(result.status, 400);
    assert.notEqual(result.data.code, 'REGISTRATION_REQUIRED');
    assert.equal(result.data.token, undefined);
    assert.ok(h.calls.queries.every(call => call.sql.startsWith('SELECT')));
    assert.deepEqual(h.calls.sessions, []);
    assert.deepEqual(h.calls.provisioned, []);
  }
});

test('completed new registration keeps verified Google identity, declarations, filtering and invite behavior', async () => {
  const h = fixture();
  const result = await h.invoke({ ...completedRegistration,
    email: 'untrusted@example.invalid', name: 'Untrusted request name' });
  assert.equal(result.status, 200);
  assert.equal(result.data.token, 'isolated-session');
  assert.equal(result.data.user.password_hash, undefined);
  const inserted = h.calls.queries.filter(call => call.sql.includes('INSERT INTO users'));
  assert.equal(inserted.length, 1);
  assert.deepEqual(inserted[0].values.slice(0, 6), ['Verified Google User', 'verified@example.invalid',
    'fixture-google-subject', 'https://example.invalid/avatar', 'male', '1980-01-01']);
  assert.equal(JSON.parse(inserted[0].values[6]).enforceGeneralFilter, true);
  assert.equal(JSON.parse(inserted[0].values[6]).women, false);
  assert.match(inserted[0].sql, /terms_accepted_at, terms_version, age_confirmed/);
  assert.deepEqual(h.calls.sessions, ['created-user']);
  assert.deepEqual(h.calls.provisioned, ['created-user']);
  assert.deepEqual(h.calls.invites, [{ id: 'created-user', inviteId: 'isolated-invite' }]);
  assert.equal(h.calls.broadcasts.length, 1);
  assert.equal(h.calls.broadcasts[0].event, 'users:new');
});

test('Google or database service errors are not treated as unknown-account registration', async () => {
  for (const options of [{ tokeninfoFailure: true }, { databaseFailure: true }]) {
    const h = fixture(options);
    const result = await h.invoke();
    assert.equal(result.status, 500);
    assert.equal(result.data.code, undefined);
    assert.deepEqual(h.calls.sessions, []);
    assert.deepEqual(h.calls.provisioned, []);
  }
});
