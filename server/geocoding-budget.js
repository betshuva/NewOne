'use strict';

// Shared by all server processes, survives restarts, and contains no user IDs
// or coordinates. A rolling 25-hour ceiling also covers provider day boundaries.
const SCHEMA = `CREATE TABLE IF NOT EXISTS geocoding_budget (
  bucket TIMESTAMPTZ PRIMARY KEY,
  requests INTEGER NOT NULL CHECK (requests > 0),
  last_request_at TIMESTAMPTZ NOT NULL
)`;
const MAX_REQUESTS = 2900;
const MIN_INTERVAL_MS = 300;

async function reserveGeocodingRequest(pool) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SELECT pg_advisory_xact_lock(719204, 1)');
    await client.query(`DELETE FROM geocoding_budget
      WHERE bucket < date_trunc('minute', clock_timestamp() - interval '25 hours')`);
    const { rows: [usage] } = await client.query(`SELECT
      COALESCE(SUM(requests), 0)::integer AS used,
      EXTRACT(EPOCH FROM (clock_timestamp() - MAX(last_request_at))) * 1000 AS elapsed_ms
      FROM geocoding_budget`);
    if (usage.used >= MAX_REQUESTS)
      throw Object.assign(new Error('GEOCODING_BUDGET_EXHAUSTED'), { code: 'GEOCODING_BUDGET_EXHAUSTED' });
    if (usage.elapsed_ms != null && Number(usage.elapsed_ms) < MIN_INTERVAL_MS)
      throw Object.assign(new Error('GEOCODING_RATE_LIMITED'), { code: 'GEOCODING_RATE_LIMITED' });
    await client.query(`INSERT INTO geocoding_budget (bucket, requests, last_request_at)
      VALUES (date_trunc('minute', clock_timestamp()), 1, clock_timestamp())
      ON CONFLICT (bucket) DO UPDATE SET requests=geocoding_budget.requests+1,
        last_request_at=EXCLUDED.last_request_at`);
    // Reserve before sending, including failed calls. Never refund a request
    // after a timeout: the provider might already have processed it.
    await client.query('COMMIT');
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    throw error;
  } finally { client.release(); }
}

module.exports = { SCHEMA, MAX_REQUESTS, reserveGeocodingRequest };
