const { Pool } = require('pg');

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: process.env.DB_SSL === 'true'
    ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' }
    : false,
  max: 10,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 30000,
});

// An idle client emitting an error must not crash the process — pg recovers the pool on its own.
pool.on('error', (e) => console.error('pg pool error:', e.message));

async function getPool() {
  return pool;
}

module.exports = { getPool };
