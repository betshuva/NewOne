'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { Pool } = require('pg');
const { SCHEMA, MAX_REQUESTS, reserveGeocodingRequest } = require('../server/geocoding-budget');

// Uses a private temporary schema, never the application's actual budget.
test('persistent PostgreSQL budget: parallel reservations, expiry, restart, exhaustion',
  { skip: !process.env.TEST_DATABASE_URL }, async t => {
    const pool = new Pool({ connectionString: process.env.TEST_DATABASE_URL });
    const schema = `test_geocoding_${process.pid}_${Date.now()}`;
    await pool.query(`CREATE SCHEMA ${schema}`);
    t.after(async () => { await pool.query(`DROP SCHEMA ${schema} CASCADE`); await pool.end(); });
    const isolated = { connect: async () => {
      const client = await pool.connect();
      await client.query(`SET search_path TO ${schema}`);
      return client;
    } };
    const client = await isolated.connect();
    try {
      await client.query(SCHEMA);
      const attempts = await Promise.allSettled(Array.from({ length: 8 }, () => reserveGeocodingRequest(isolated)));
      assert.equal(attempts.filter(x => x.status === 'fulfilled').length, 1);
      for (const result of attempts.filter(x => x.status === 'rejected'))
        assert.equal(result.reason.code, 'GEOCODING_RATE_LIMITED');
      assert.equal((await client.query('SELECT SUM(requests)::integer AS count FROM geocoding_budget')).rows[0].count, 1);
      await client.query('DELETE FROM geocoding_budget');
      await client.query(`INSERT INTO geocoding_budget VALUES
        (date_trunc('minute', now() - interval '1 hour'), $1, now() - interval '1 hour')`, [MAX_REQUESTS]);
      // A fresh module instance still sees the database count (process restart).
      delete require.cache[require.resolve('../server/geocoding-budget')];
      await assert.rejects(require('../server/geocoding-budget').reserveGeocodingRequest(isolated),
        { code: 'GEOCODING_BUDGET_EXHAUSTED' });
      await client.query(`UPDATE geocoding_budget SET bucket=bucket-interval '26 hours'`);
      await reserveGeocodingRequest(isolated);
      const rows = (await client.query('SELECT requests FROM geocoding_budget')).rows;
      assert.deepEqual(rows, [{ requests: 1 }]);
    } finally { client.release(); }
  });
