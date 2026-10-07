'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { reverseGeocodeGeoapify } = require('../server/geoapify-geocoding');
const apiKey = 'synthetic-test-key';
const response = results => ({ ok: true, json: async () => ({ results }) });

test('sends only coordinates and API parameters to the EU endpoint and retains credits', async () => {
  const address = await reverseGeocodeGeoapify(31.77, 35.21, {
    apiKey,
    fetchImpl: async (url, options) => {
      assert.equal(url.origin, 'https://api-eu.geoapify.com');
      assert.equal(url.pathname, '/v1/geocode/reverse');
      assert.deepEqual(Object.fromEntries(url.searchParams), {
        lat: '31.77', lon: '35.21', lang: 'he', format: 'json', limit: '1', apiKey,
      });
      assert.equal(options.redirect, 'error');
      assert.ok(options.signal instanceof AbortSignal);
      assert.deepEqual(options.headers, { Accept: 'application/json' });
      return response([{
        city: 'ירושלים', street: 'רחוב לדוגמה', housenumber: '12א', country: 'ישראל',
        datasource: { sourcename: 'openstreetmap', license: 'ODbL',
          attribution: '© OpenStreetMap contributors', url: 'https://www.openstreetmap.org/copyright' },
        privateUnexpectedField: 'must not escape',
      }]);
    },
  });
  assert.equal(address.houseNumber, '12א');
  assert.equal(address.city, 'ירושלים');
  assert.equal(address.attribution.license, 'ODbL');
  assert.equal(address.attribution.sourceUrl, 'https://www.openstreetmap.org/copyright');
  assert.ok(!('privateUnexpectedField' in address));
});

test('invalid inputs and missing key never cause a request', async () => {
  let calls = 0;
  const fetchImpl = async () => { calls++; };
  for (const value of [null, undefined, '', ' ', true, [], {}, NaN, Infinity, 91, '0x10'])
    await assert.rejects(reverseGeocodeGeoapify(value, 1, { apiKey, fetchImpl }),
      { code: 'GEOCODING_INVALID_LOCATION' });
  await assert.rejects(reverseGeocodeGeoapify(1, -181, { apiKey, fetchImpl }),
    { code: 'GEOCODING_INVALID_LOCATION' });
  await assert.rejects(reverseGeocodeGeoapify(0, 0, { apiKey: '', fetchImpl }),
    { code: 'GEOCODING_NOT_CONFIGURED' });
  assert.equal(calls, 0);
});

test('accepts valid zero/string coordinates without inventing a house number', async () => {
  const result = await reverseGeocodeGeoapify('0', '0', {
    apiKey, fetchImpl: async () => response([{ village: 'יישוב', country: 'ישראל' }]),
  });
  assert.equal(result.city, 'יישוב');
  assert.equal(result.houseNumber, null);
});

test('no result and country-only responses do not invent an address', async () => {
  for (const results of [[], [{ country: 'ישראל' }]])
    assert.equal(await reverseGeocodeGeoapify(1, 1, { apiKey,
      fetchImpl: async () => response(results) }), null);
});

test('provider errors expose fixed codes only, not credentials or coordinates', async () => {
  for (const [status, code] of [[401, 'GEOCODING_ACCESS_DENIED'],
    [403, 'GEOCODING_ACCESS_DENIED'], [429, 'GEOCODING_RATE_LIMITED'],
    [500, 'GEOCODING_UNAVAILABLE']]) {
    await assert.rejects(reverseGeocodeGeoapify(1, 1, { apiKey,
      fetchImpl: async () => ({ ok: false, status,
        json: async () => { throw new Error('response body must not be read'); } }),
    }), { message: code, code });
  }
  await assert.rejects(reverseGeocodeGeoapify(1, 1, { apiKey,
    fetchImpl: async url => { throw new Error(String(url)); },
  }), { message: 'GEOCODING_UNAVAILABLE', code: 'GEOCODING_UNAVAILABLE' });
});

test('malformed provider responses fail with a sanitized error', async () => {
  for (const body of [null, {}, { results: {} }, { results: [null] }])
    await assert.rejects(reverseGeocodeGeoapify(1, 1, { apiKey,
      fetchImpl: async () => ({ ok: true, json: async () => body }),
    }), { code: 'GEOCODING_INVALID_RESPONSE' });
  await assert.rejects(reverseGeocodeGeoapify(1, 1, { apiKey,
    fetchImpl: async () => ({ ok: true, json: async () => { throw Error(apiKey); } }),
  }), { code: 'GEOCODING_INVALID_RESPONSE' });
});

test('does not return unsafe source links', async () => {
  for (const url of ['javascript:alert(1)', 'https://user:secret@example.com', 'not a URL']) {
    const result = await reverseGeocodeGeoapify(1, 1, { apiKey,
      fetchImpl: async () => response([{ city: 'יישוב', datasource: { url } }]),
    });
    assert.equal(result.attribution.sourceUrl, null);
  }
});
