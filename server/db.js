const { Pool } = require('pg');
const { decryptMessageRows, encryptedQueryValues } = require('./message-at-rest');

const isBackgroundWorker = process.env.BACKUP_WORKER_ONLY === '1';
const configuredPoolSize = Number.parseInt(process.env.DB_POOL_MAX || '', 10);
const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: process.env.DB_SSL === 'true'
    ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' }
    : false,
  // Backup workers execute one claimed job at a time and need only a very
  // small pool. Keep the larger pool for interactive API traffic so a Drive
  // upload can never starve login and socket authentication.
  max: Number.isInteger(configuredPoolSize) && configuredPoolSize > 0
    ? configuredPoolSize : isBackgroundWorker ? 2 : 20,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 10000,
});

// An idle client emitting an error must not crash the process — pg recovers the pool on its own.
pool.on('error', (e) => console.error('pg pool error:', e.message));

function protectedQuery(original, query, values) {
  return (async () => {
    if (typeof query === 'string')
      return decryptMessageRows(await original(query, encryptedQueryValues(query, values)));
    if (query && typeof query === 'object') {
      const secured = { ...query,
        values: encryptedQueryValues(query.text, query.values) };
      return decryptMessageRows(await original(secured));
    }
    return decryptMessageRows(await original(query, values));
  })();
}

const protectedPool = {
  query: (query, values) => protectedQuery(pool.query.bind(pool), query, values),
  connect: async () => {
    const client = await pool.connect();
    // Never replace pg.Client.query itself: pg.Pool internally invokes it with
    // a callback when the client is returned to the pool. An async wrapper
    // would swallow that callback and permanently check the client out.
    return {
      query: (query, values) => protectedQuery(client.query.bind(client), query, values),
      release: client.release.bind(client),
    };
  },
};

async function getPool() {
  return protectedPool;
}

module.exports = { getPool };
