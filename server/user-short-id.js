'use strict';

// PostgreSQL assigns existing and future accounts unique, non-reused numbers.
// UUIDs remain the identity used by authentication and relationships.
const SHORT_USER_ID_SCHEMA = `
  ALTER TABLE users ADD COLUMN IF NOT EXISTS short_id BIGINT GENERATED ALWAYS AS IDENTITY;
  CREATE UNIQUE INDEX IF NOT EXISTS users_short_id_unique ON users(short_id);
`;

async function shortenCapturedFileName(pool, userId, fileName) {
  const match = /^(betshuva-(?:photo|video|audio|screenshot)-\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}-\d{2}-ID-)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})((?:_\d+)?\.[a-z0-9]{1,10})$/i.exec(fileName);
  if (!match || match[2].toLowerCase() !== userId.toLowerCase()) return fileName;
  const result = await pool.query('SELECT short_id FROM users WHERE id=$1', [userId]);
  const shortId = String(result.rows[0]?.short_id ?? '');
  if (!/^[1-9][0-9]*$/.test(shortId)) throw new Error('Capture creator number unavailable');
  return `${match[1]}${shortId}${match[3]}`;
}

module.exports = { SHORT_USER_ID_SCHEMA, shortenCapturedFileName };
