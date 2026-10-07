'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const express = require('express');
const { registerLocationRoutes, CONSENT_VERSION, readGeoapifyKey } = require('../server/location-routes');

const address = { city: 'עיר לבדיקה', street: 'רחוב לבדיקה', houseNumber: null,
  country: 'ישראל', attribution: { provider: 'Geoapify', source: 'openaddresses' } };
const input = { latitude: 31.77, longitude: 35.21, geocodingConsent: CONSENT_VERSION };

async function fixture(t, overrides = {}) {
  const app = express();
  app.use(express.json());
  const calls = { key: 0, budget: 0, provider: 0, queries: [] };
  const pool = { query: async (...args) => { calls.queries.push(args); return { rows: [] }; } };
  registerLocationRoutes(app, {
    auth(req, res, next) {
      if (!req.get('authorization')) return res.sendStatus(401);
      req.user = { id: 'test-user', isTeen: req.get('authorization') === 'teen' };
      next();
    },
    getPool: async () => pool,
    readKey: async () => { calls.key++; return 'test-private-key'; },
    reserve: async () => { calls.budget++; },
    reverse: async (lat, lon, { apiKey }) => {
      assert.equal(apiKey, 'test-private-key');
      assert.equal(lat, input.latitude);
      assert.equal(lon, input.longitude);
      calls.provider++;
      return address;
    },
    ...overrides,
  });
  const server = app.listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  t.after(() => new Promise(resolve => { server.close(resolve); server.closeAllConnections(); }));
  return { calls, send: (route, body = input, authorization = 'adult') => fetch(
    `http://127.0.0.1:${server.address().port}${route}`, {
      method: 'PUT', headers: { 'Content-Type': 'application/json',
        ...(authorization ? { authorization } : {}) }, body: JSON.stringify(body),
    }) };
}

test('all location modes require authentication and fresh provider consent before touching key, budget or provider', async t => {
  const { calls, send } = await fixture(t);
  for (const route of ['/api/location', '/api/location/address', '/api/location/city']) {
    assert.equal((await send(route, input, '')).status, 401);
    assert.equal((await send(route, input, 'teen')).status, 403);
    for (const consent of [undefined, false, 'old-provider']) {
      const result = await send(route, { ...input, geocodingConsent: consent });
      assert.equal(result.status, 409);
      assert.equal((await result.json()).code, 'GEOCODING_CONSENT_REQUIRED');
    }
  }
  assert.deepEqual(calls, { key: 0, budget: 0, provider: 0, queries: [] });
});

test('invalid coordinates never reach the provider or budget', async t => {
  const { calls, send } = await fixture(t);
  for (const latitude of [null, '', true, [], {}, 'NaN', 91])
    assert.equal((await send('/api/location/address', { ...input, latitude })).status, 400);
  assert.equal(calls.provider, 0);
  assert.equal(calls.budget, 0);
});

test('one-time address resolution never writes the profile and preserves source and missing house number', async t => {
  const { calls, send } = await fixture(t);
  const result = await send('/api/location/address');
  assert.equal(result.status, 200);
  assert.equal(result.headers.get('cache-control'), 'no-store');
  const body = await result.json();
  assert.equal(body.house_number, '');
  assert.deepEqual(body.attribution, address.attribution);
  assert.equal(calls.provider, 1);
  assert.equal(calls.budget, 1);
  assert.deepEqual(calls.queries, []);
});

test('city mode saves city and credits, but never coordinates; precise mode saves both', async t => {
  const { calls, send } = await fixture(t);
  assert.equal((await send('/api/location/city')).status, 200);
  assert.doesNotMatch(calls.queries[0][0], /latitude|longitude/);
  assert.deepEqual(calls.queries[0][1], [address.city, address.country, 'test-user', address.attribution]);
  assert.equal((await send('/api/location')).status, 200);
  assert.deepEqual(calls.queries[1][1], [input.latitude, input.longitude, address.city,
    address.country, 'test-user', address.attribution]);
});

test('exhausted/unavailable budget fails closed before contacting provider', async t => {
  for (const code of ['GEOCODING_BUDGET_EXHAUSTED', 'GEOCODING_RATE_LIMITED', 'private-db-error']) {
    const { calls, send } = await fixture(t, { reserve: async () => {
      throw Object.assign(Error('private database information'), { code });
    } });
    const result = await send('/api/location/address');
    assert.equal(result.status, code === 'private-db-error' ? 503 : 429);
    assert.doesNotMatch(await result.text(), /private/);
    assert.equal(calls.provider, 0);
    assert.deepEqual(calls.queries, []);
  }
});

test('provider errors and empty results do not save partial location or expose errors', async t => {
  for (const reverse of [async () => null, async () => { throw Error('secret provider URL'); }]) {
    const { calls, send } = await fixture(t, { reverse });
    const result = await send('/api/location');
    assert.ok([404, 503].includes(result.status));
    assert.doesNotMatch(await result.text(), /secret/);
    assert.deepEqual(calls.queries, []);
  }
});

test('key loader rejects missing, public, malformed and symbolic-link files without revealing contents', async t => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'geoapify-key-test-'));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const file = path.join(dir, 'key');
  const reject = filename => assert.rejects(readGeoapifyKey(filename),
    { message: 'GEOCODING_NOT_CONFIGURED', code: 'GEOCODING_NOT_CONFIGURED' });
  await reject(file);
  await fs.writeFile(file, 'synthetic-key-123456789\n', { mode: 0o600 });
  assert.equal(await readGeoapifyKey(file), 'synthetic-key-123456789');
  await fs.chmod(file, 0o644);
  await reject(file);
  await fs.chmod(file, 0o600);
  const link = path.join(dir, 'link');
  await fs.symlink(file, link);
  await reject(link);
  await fs.writeFile(file, 'invalid key\n');
  await reject(file);
});
