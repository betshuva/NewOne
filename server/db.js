const { Pool } = require('pg');
const { decryptMessageRows, encryptedQueryValues } = require('./message-at-rest');

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

function protectQuery(target) {
  const original = target.query.bind(target);
  target.query = async (query, values) => {
    if (typeof query === 'string')
      return decryptMessageRows(await original(query, encryptedQueryValues(query, values)));
    if (query && typeof query === 'object') {
      const secured = { ...query,
        values: encryptedQueryValues(query.text, query.values) };
      return decryptMessageRows(await original(secured));
    }
    return decryptMessageRows(await original(query, values));
  };
  return target;
}

const protectedPool = {
  query: protectQuery({ query: pool.query.bind(pool) }).query,
  connect: async () => protectQuery(await pool.connect()),
};

async function getPool() {
  return protectedPool;
}

module.exports = { getPool };
