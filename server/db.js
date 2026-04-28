const sql = require('mssql');

const config = {
  server: process.env.DB_SERVER,
  database: process.env.DB_NAME,
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  port: parseInt(process.env.DB_PORT || '1433'),
  connectionTimeout: 30000,
  requestTimeout: 30000,
  pool: {
    max: 10,
    min: 0,
    idleTimeoutMillis: 30000,
  },
  options: {
    encrypt: process.env.DB_ENCRYPT === 'true',
    trustServerCertificate: process.env.DB_TRUST_CERT === 'true',
  },
};

let pool = null;

async function getPool() {
  if (pool && pool.connected) return pool;

  // Reset broken pool
  if (pool && !pool.connected) {
    try { await pool.close(); } catch (_) {}
    pool = null;
  }

  let lastErr;
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      pool = await sql.connect(config);
      pool.on('error', () => { pool = null; });
      return pool;
    } catch (e) {
      lastErr = e;
      if (attempt < 3) await new Promise(r => setTimeout(r, attempt * 2000));
    }
  }
  throw lastErr;
}

module.exports = { getPool, sql };
