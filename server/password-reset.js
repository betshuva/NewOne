'use strict';
const bcrypt = require('bcryptjs');

function validResetInput(token, password) {
  return typeof token === 'string' && /^[a-f0-9]{64}$/.test(token) &&
    typeof password === 'string' && password.length >= 6 &&
    Buffer.byteLength(password, 'utf8') <= 72;
}

async function resetPassword(pool, token, password) {
  if (!validResetInput(token, password)) return null;
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const candidate = await client.query(
      'SELECT user_id FROM password_reset_tokens WHERE token=$1 AND used=FALSE AND expires_at>now()', [token]);
    if (!candidate.rows.length) { await client.query('ROLLBACK'); return null; }
    const userId = candidate.rows[0].user_id;
    // Lock the account first: two different reset links must serialize too.
    const user = await client.query('SELECT id FROM users WHERE id=$1 FOR UPDATE', [userId]);
    const consumed = await client.query(
      `UPDATE password_reset_tokens SET used=TRUE
       WHERE token=$1 AND used=FALSE AND expires_at>clock_timestamp() RETURNING user_id`, [token]);
    if (!user.rows.length || !consumed.rows.length) {
      await client.query('ROLLBACK'); return null;
    }
    const hash = await bcrypt.hash(password, 10);
    await client.query(
      'UPDATE users SET password_hash=$1, session_version=session_version+1 WHERE id=$2', [hash, userId]);
    await client.query('UPDATE password_reset_tokens SET used=TRUE WHERE user_id=$1', [userId]);
    await client.query('COMMIT');
    return userId;
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    throw error;
  } finally { client.release(); }
}

module.exports = { validResetInput, resetPassword };
