'use strict';

// Invoked only after authentication, provider consent and budget reservation.
const ENDPOINT = 'https://api-eu.geoapify.com/v1/geocode/reverse';
const TIMEOUT_MS = 8000;

function failure(code) {
  // Fetch errors can contain the request URL (coordinates and API key).
  // Only these fixed error codes may escape this adapter.
  return Object.assign(new Error(code), { code });
}

function coordinate(value, bound) {
  if (typeof value !== 'number' && typeof value !== 'string') return null;
  if (typeof value === 'string' && !/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)$/.test(value.trim()))
    return null;
  const number = Number(value);
  return Number.isFinite(number) && Math.abs(number) <= bound ? number : null;
}

function component(value) {
  return typeof value === 'string' && value.trim() && value.length <= 500
    ? value.trim() : null;
}

function sourceUrl(value) {
  if (typeof value !== 'string' || value.length > 2000) return null;
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && !url.username && !url.password ? url.href : null;
  } catch { return null; }
}

async function reverseGeocodeGeoapify(latitude, longitude, {
  apiKey = process.env.GEOAPIFY_API_KEY,
  fetchImpl = globalThis.fetch,
} = {}) {
  const lat = coordinate(latitude, 90);
  const lon = coordinate(longitude, 180);
  if (lat === null || lon === null) throw failure('GEOCODING_INVALID_LOCATION');
  if (typeof apiKey !== 'string' || !apiKey.trim())
    throw failure('GEOCODING_NOT_CONFIGURED');

  const url = new URL(ENDPOINT);
  url.search = new URLSearchParams({
    lat: String(lat), lon: String(lon), lang: 'he', format: 'json', limit: '1',
    apiKey: apiKey.trim(),
  }).toString();

  let response;
  try {
    response = await fetchImpl(url, {
      method: 'GET', redirect: 'error', signal: AbortSignal.timeout(TIMEOUT_MS),
      headers: { Accept: 'application/json' },
    });
  } catch { throw failure('GEOCODING_UNAVAILABLE'); }
  if (!response.ok) {
    if (response.status === 429) throw failure('GEOCODING_RATE_LIMITED');
    if (response.status === 401 || response.status === 403)
      throw failure('GEOCODING_ACCESS_DENIED');
    throw failure('GEOCODING_UNAVAILABLE');
  }

  let body;
  try { body = await response.json(); }
  catch { throw failure('GEOCODING_INVALID_RESPONSE'); }
  if (!body || !Array.isArray(body.results)) throw failure('GEOCODING_INVALID_RESPONSE');
  if (!body.results.length) return null;
  const result = body.results[0];
  if (!result || typeof result !== 'object' || Array.isArray(result))
    throw failure('GEOCODING_INVALID_RESPONSE');
  const city = component(result.city) || component(result.town) || component(result.village);
  const street = component(result.street);
  if (!city && !street) return null;

  return {
    city, street, houseNumber: component(result.housenumber),
    country: component(result.country),
    // Retain the returned source credits with any stored/reused address.
    // UI consumers must render labels as text and show linked attribution.
    attribution: {
      provider: 'Geoapify', providerUrl: 'https://www.geoapify.com/',
      source: component(result.datasource?.sourcename),
      license: component(result.datasource?.license),
      sourceUrl: sourceUrl(result.datasource?.url),
      attribution: component(result.datasource?.attribution),
    },
  };
}

module.exports = { reverseGeocodeGeoapify, coordinate };
