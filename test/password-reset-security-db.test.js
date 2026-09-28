'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { Pool, Client } = require('pg');
const bcrypt = require('bcryptjs');
const { resetPassword } = require('../server/password-reset');

test('concurrent reset links are single-use and failed password writes roll back', {
  skip: process.env.RUN_DB_TESTS !== '1',
}, async t => {
  const schema = 'security_reset_' + crypto.randomBytes(8).toString('hex');
  const options = { connectionString: process.env.DATABASE_URL,
    ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: true } : false };
  const owner = new Client(options); await owner.connect();
  let pool;
  t.after(async () => {
    if (pool) await pool.end();
    await owner.query(`DROP SCHEMA IF EXISTS "${schema}" CASCADE`);
    await owner.end();
  });
  await owner.query(`CREATE SCHEMA "${schema}"`);
  pool = new Pool({ ...options, options: `-c search_path=${schema}` });
  await pool.query(`CREATE TABLE users(id text PRIMARY KEY,password_hash text,session_version integer NOT NULL DEFAULT 0);
    CREATE TABLE password_reset_tokens(token text PRIMARY KEY,user_id text REFERENCES users(id),used boolean DEFAULT false,expires_at timestamptz);
    INSERT INTO users(id) VALUES('test-user');`);
  const first = 'a'.repeat(64), second = 'b'.repeat(64);
  const insert = async () => {
    await pool.query('DELETE FROM password_reset_tokens');
    await pool.query(`INSERT INTO password_reset_tokens(token,user_id,expires_at)
      VALUES($1,'test-user',now()+interval '1 hour'),($2,'test-user',now()+interval '1 hour')`, [first, second]);
  };
  for (const tokens of [[first, first], [first, second]]) {
    await insert();
    const before = (await pool.query('SELECT session_version FROM users')).rows[0].session_version;
    const results = await Promise.all(tokens.map(token => resetPassword(pool, token, 'test password')));
    assert.equal(results.filter(Boolean).length, 1);
    const user = (await pool.query('SELECT * FROM users')).rows[0];
    assert.equal(user.session_version, before + 1);
    assert.ok(await bcrypt.compare('test password', user.password_hash));
    assert.equal((await pool.query('SELECT * FROM password_reset_tokens WHERE used=FALSE')).rowCount, 0);
    assert.equal(await resetPassword(pool, first, 'another password'), null);
  }
  await insert();
  await pool.query(`CREATE FUNCTION reject_password() RETURNS trigger LANGUAGE plpgsql AS
    $$ BEGIN RAISE EXCEPTION 'isolated simulated write failure'; END $$;
    CREATE TRIGGER reject_password BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION reject_password();`);
  await assert.rejects(resetPassword(pool, first, 'test password'));
  assert.equal((await pool.query('SELECT used FROM password_reset_tokens WHERE token=$1', [first])).rows[0].used, false);
});
