'use strict';
const fs = require('node:fs/promises');
const { constants } = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { coordinate, reverseGeocodeGeoapify } = require('./geoapify-geocoding');
const { reserveGeocodingRequest } = require('./geocoding-budget');

const CONSENT_VERSION = 'geoapify-v1';
const KEY_FILE = path.join(os.homedir(), '.config/newone/geoapify/api-key');

async function readGeoapifyKey(filename = KEY_FILE) {
  let handle;
  try {
    handle = await fs.open(filename, constants.O_RDONLY | constants.O_NOFOLLOW);
    const stat = await handle.stat();
    if (!stat.isFile() || stat.size > 513 || (stat.mode & 0o077) ||
        stat.uid !== process.getuid()) throw Error();
    const key = (await handle.readFile('utf8')).trim();
    if (!/^[A-Za-z0-9_-]{16,512}$/.test(key)) throw Error();
    return key;
  } catch {
    throw Object.assign(new Error('GEOCODING_NOT_CONFIGURED'), { code: 'GEOCODING_NOT_CONFIGURED' });
  } finally { await handle?.close(); }
}

function locationError(res, error) {
  if (error.code === 'GEOCODING_BUDGET_EXHAUSTED')
    return res.status(429).json({ code: error.code,
      error: 'מכסת זיהוי הכתובות הזמינה נוצלה. אפשר להזין כתובת ידנית או לנסות מאוחר יותר' });
  if (error.code === 'GEOCODING_RATE_LIMITED') {
    res.set('Retry-After', '2');
    return res.status(429).json({ code: error.code,
      error: 'שירות הכתובות עמוס כרגע. נסו שוב בעוד רגע או הזינו כתובת ידנית' });
  }
  // Do not echo database errors, provider URLs, coordinates or key material.
  return res.status(503).json({ code: 'GEOCODING_UNAVAILABLE',
    error: 'לא ניתן לזהות את הכתובת כרגע. אפשר להזין אותה ידנית' });
}

function registerLocationRoutes(app, { auth, getPool, rateLimit = (_req, _res, next) => next(),
  readKey = readGeoapifyKey, reserve = reserveGeocodingRequest,
  reverse = reverseGeocodeGeoapify } = {}) {
  for (const mode of ['address', 'city', 'precise']) {
    const route = mode === 'precise' ? '/api/location' : `/api/location/${mode}`;
    app.put(route, auth, rateLimit, async (req, res) => {
      res.set('Cache-Control', 'no-store');
      if (req.user.isTeen)
        return res.status(403).json({ code: 'TEEN_LOCATION_DISABLED', error: 'שיתוף מיקום אינו זמין בחשבון נוער' });
      // Old builds must not silently send GPS to a newly introduced provider.
      if (req.body?.geocodingConsent !== CONSENT_VERSION)
        return res.status(409).json({ code: 'GEOCODING_CONSENT_REQUIRED',
          error: 'יש לרענן את האתר או לעדכן את האפליקציה ולאשר את שירות זיהוי הכתובות' });
      const latitude = coordinate(req.body?.latitude, 90);
      const longitude = coordinate(req.body?.longitude, 180);
      if (latitude === null || longitude === null)
        return res.status(400).json({ error: 'מיקום לא תקין' });
      try {
        const apiKey = await readKey();
        const pool = await getPool();
        await reserve(pool);
        const address = await reverse(latitude, longitude, { apiKey });
        if (!address || (mode === 'city' && !address.city))
          return res.status(404).json({ error: 'לא נמצאה כתובת מתאימה. אפשר להזין אותה ידנית' });
        const { city, street, houseNumber, country, attribution } = address;
        if (mode === 'city') {
          await pool.query(`UPDATE users SET city=$1, country=COALESCE($2, country),
            location_attribution=$4 WHERE id=$3`,
          [city, country || null, req.user.id, attribution]);
        } else if (mode === 'precise') {
          await pool.query(`UPDATE users SET latitude=$1, longitude=$2,
            city=$3, country=$4, location_updated_at=now(), location_attribution=$6 WHERE id=$5`,
          [latitude, longitude, city || null, country || null, req.user.id, attribution]);
        }
        res.json({ ok: true, city: city || '', street: street || '',
          house_number: houseNumber || '', country: country || '', attribution });
      } catch (error) { locationError(res, error); }
    });
  }
}

module.exports = { CONSENT_VERSION, registerLocationRoutes, readGeoapifyKey };
