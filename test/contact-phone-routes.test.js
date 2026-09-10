'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { initializePhonePrivacy } = require('../server/contact-phone-privacy');
const { registerContactPhoneRoutes, phoneSharingChoices, notifyPhoneSharingChange } = require('../server/contact-phone-routes');

const id = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const [me, other, unrelated] = [901, 902, 903].map(id);
const myPhone = '0500000901';
const otherPhone = '0500000902';

test('phone choices whitelist consent fields and socket events contain only counterpart IDs', () => {
  assert.deepEqual(phoneSharingChoices({ share_my_phone: true, request_phone: false,
    actor_id: other, phone_owner_id: unrelated, phone: otherPhone, phone_hash: 'synthetic' }),
  { share_my_phone: true, request_phone: false });
  const events = [];
  const io = { to: socket => ({ emit: (event, payload) => events.push({ socket, event, payload }) }) };
  const online = new Map([[me, 'me-socket'], [other, 'other-socket']]);
  notifyPhoneSharingChange(io, online, me, other, { phone: otherPhone, changes: { requested: false } });
  assert.equal(events.length, 0);
  notifyPhoneSharingChange(io, online, me, other, { phone: otherPhone,
    phone_hash: 'synthetic-hash', changes: { requested: true } });
  assert.deepEqual(events, [
    { socket: 'me-socket', event: 'contact:phone-sharing', payload: { userId: other } },
    { socket: 'other-socket', event: 'contact:phone-sharing', payload: { userId: me } },
  ]);
});

test('registered phone routes enforce directed consent against isolated PostgreSQL fixtures', {
  skip: process.env.RUN_DB_TESTS !== '1',
}, async t => {
  const { Client } = require('pg');
  const db = new Client({
    connectionString: process.env.DATABASE_URL,
    connectionTimeoutMillis: 10000,
    ssl: process.env.DB_SSL === 'true'
      ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' } : false,
  });
  await db.connect();
  const events = [];
  const lifecycle = [];
  let savepointSequence = 0;
  // Exercise the real Pool transaction branch with savepoints inside the outer
  // fixture transaction, so even successful route commits remain reversible.
  const pool = {
    totalCount: 1,
    query: (...args) => db.query(...args),
    connect: async () => {
      const savepoint = `phone_route_${++savepointSequence}`;
      return {
        query: async (sql, params) => {
          if (sql === 'BEGIN') return db.query(`SAVEPOINT ${savepoint}`);
          if (sql === 'COMMIT') {
            const result = await db.query(`RELEASE SAVEPOINT ${savepoint}`);
            lifecycle.push('commit');
            return result;
          }
          if (sql === 'ROLLBACK') {
            const result = await db.query(`ROLLBACK TO SAVEPOINT ${savepoint}`);
            await db.query(`RELEASE SAVEPOINT ${savepoint}`);
            lifecycle.push('rollback');
            return result;
          }
          return db.query(sql, params);
        },
        release: () => {},
      };
    },
  };
  const handlers = new Map();
  const app = Object.fromEntries(['get', 'put'].map(method => [method,
    (path, ...middleware) => handlers.set(`${method} ${path}`, middleware.at(-1))]));
  const io = { to: socket => ({ emit: (event, payload) => events.push({ socket, event, payload }) }) };
  const online = new Map([[me, 'me-socket'], [other, 'other-socket'], [unrelated, 'unrelated-socket']]);
  registerContactPhoneRoutes(app, {
    auth: (_req, _res, next) => next(),
    rateLimit: (_req, _res, next) => next(),
    getPool: async () => pool,
    notify: (actor, target, status) => {
      assert.equal(lifecycle.at(-1), 'commit', 'a mutation must commit before notification');
      lifecycle.push('notify');
      notifyPhoneSharingChange(io, online, actor, target, status);
    },
  });
  const invoke = async (method, path, actor = me, target = other, body = {}) => {
    const output = { status: 200, headers: {} };
    const res = {
      status: status => { output.status = status; return res; },
      set: (name, value) => { output.headers[name] = value; return res; },
      json: body => { output.body = body; return res; },
    };
    const handler = handlers.get(`${method} ${path}`);
    assert.equal(typeof handler, 'function', `missing registered route ${path}`);
    await handler({ user: { id: actor }, params: { userId: target }, body }, res);
    return output;
  };
  const getStatus = (actor = me, target = other) => invoke('get', '/api/contacts/:userId/phone-sharing', actor, target);
  const update = (actor, target, body) => invoke('put', '/api/contacts/:userId/phone-sharing', actor, target, body);
  const reset = async () => {
    await db.query('TRUNCATE user_contacts,blocked_users,contact_phone_permissions');
    await db.query(`UPDATE users SET phone=CASE id WHEN $1 THEN $3 WHEN $2 THEN $4 ELSE phone END,
      birth_date='1990-01-01'`, [me, other, myPhone, otherPhone]);
    events.length = 0;
    lifecycle.length = 0;
  };
  try {
    await db.query('BEGIN');
    await db.query(`CREATE TEMP TABLE users(id UUID PRIMARY KEY,name TEXT,profile_pic_url TEXT,
        phone TEXT,birth_date DATE,gender TEXT,email_verified BOOLEAN,phone_verified BOOLEAN);
      CREATE TEMP TABLE user_contacts(owner_id UUID,contact_id UUID,PRIMARY KEY(owner_id,contact_id));
      CREATE TEMP TABLE blocked_users(blocker_id UUID,blocked_id UUID);
      SET LOCAL search_path=pg_temp,public;`);
    await initializePhonePrivacy(db);
    await db.query(`INSERT INTO users(id,name,phone,birth_date,gender,email_verified,phone_verified)
      VALUES($1,'מבקש בדיקה',$4,'1990-01-01','male',TRUE,FALSE),
      ($2,'בעל מספר בדיקה',$5,'1990-01-01','male',TRUE,FALSE),
      ($3,'משתמש בלתי קשור','0500000903','1990-01-01','male',TRUE,FALSE)`,
    [me, other, unrelated, myPhone, otherPhone]);

    await t.test('reading and submitting empty choices cannot create consent', async () => {
      await reset();
      await db.query('INSERT INTO user_contacts(owner_id,contact_id) VALUES($1,$2)', [me, other]);
      const read = await getStatus();
      assert.equal(read.status, 200);
      assert.equal(read.headers['Cache-Control'], 'no-store');
      assert.equal(read.body.phone, null);
      assert.equal(read.body.phone_visibility, 'hidden');
      const empty = await update(me, other, {});
      assert.equal(empty.status, 200);
      assert.equal(empty.body.phone, null);
      assert.equal(empty.body.share_my_phone, false);
      const rows = await db.query('SELECT * FROM contact_phone_permissions');
      assert.equal(rows.rows.length, 0);
      assert.equal(events.length, 0);
    });

    await t.test('pending requests and their notifications disclose metadata only and are idempotent', async () => {
      await reset();
      const requested = await update(me, other, { request_phone: true });
      assert.equal(requested.status, 200);
      assert.equal(requested.body.request_state, 'pending');
      assert.equal(requested.body.phone, null);
      assert.deepEqual(lifecycle, ['commit', 'notify']);
      assert.equal(events.length, 2);
      const pending = await invoke('get', '/api/phone-sharing/requests', other);
      assert.equal(pending.status, 200);
      assert.equal(pending.headers['Cache-Control'], 'no-store');
      assert.equal(pending.body.length, 1);
      assert.equal(pending.body[0].user_id, me);
      assert.deepEqual(Object.keys(pending.body[0]).sort(),
        ['user_id', 'name', 'profile_pic_url', 'requested_at', 'updated_at'].sort());
      assert.doesNotMatch(JSON.stringify({ pending: pending.body, events }), /050000090[12]|phone_hash/);
      const again = await update(me, other, { request_phone: true });
      assert.equal(again.body.changes.requested, false);
      assert.equal(events.length, 2);
      assert.deepEqual((await invoke('get', '/api/phone-sharing/requests', me)).body, []);
    });

    await t.test('only the authenticated number owner can approve, regardless of forged actor fields', async () => {
      await reset();
      await update(me, other, { request_phone: true });
      const attackerApproval = await update(me, other, { phone_response: 'approve', actor_id: other,
        phone_owner_id: other, viewer_id: me });
      assert.equal(attackerApproval.status, 409);
      assert.equal((await getStatus()).body.phone, null);
      const approved = await update(other, me, { phone_response: 'approve', actor_id: unrelated,
        userId: unrelated, viewer_id: unrelated, phone_owner_id: unrelated, phone: '0509999999' });
      assert.equal(approved.status, 200);
      assert.equal(approved.body.share_my_phone, true);
      assert.equal(approved.body.phone, null, 'consent cannot also disclose the requester phone');
      assert.equal((await getStatus()).body.phone, otherPhone);
      assert.equal((await getStatus(unrelated, other)).body.phone, null);
      const permissions = await db.query('SELECT phone_owner_id,viewer_id,state FROM contact_phone_permissions');
      assert.deepEqual(permissions.rows, [{ phone_owner_id: other, viewer_id: me, state: 'approved' }]);
      const grants = await invoke('get', '/api/phone-sharing/grants', other);
      assert.equal(grants.body[0].user_id, me);
      assert.doesNotMatch(JSON.stringify(grants.body), /050000090[12]|phone_hash/);
      assert.deepEqual((await invoke('get', '/api/phone-sharing/requests', other)).body, []);
    });

    await t.test('revoke masks the phone immediately and invalid decisions emit no notifications', async () => {
      await reset();
      await update(other, me, { share_my_phone: true });
      assert.equal((await getStatus()).body.phone, otherPhone);
      const revoked = await update(other, me, { share_my_phone: false });
      assert.equal(revoked.status, 200);
      assert.equal(revoked.body.changes.revoked, true);
      assert.equal((await getStatus()).body.phone, null);
      assert.deepEqual((await invoke('get', '/api/phone-sharing/grants', other)).body, []);
      const eventCount = events.length;
      const invalid = await update(other, me, { share_my_phone: 'true' });
      assert.equal(invalid.status, 400);
      assert.equal(events.length, eventCount);
      const cooldown = await update(me, other, { request_phone: true, share_my_phone: true });
      assert.equal(cooldown.status, 429);
      assert.equal(events.length, eventCount);
      assert.equal((await getStatus(other, me)).body.phone, null, 'rejected compound choice grants nothing');
    });

    await t.test('pending lists omit stale-number, blocked and age-restricted requests', async () => {
      await reset();
      await update(me, other, { request_phone: true });
      await db.query("UPDATE users SET phone='0509999902' WHERE id=$1", [other]);
      assert.deepEqual((await invoke('get', '/api/phone-sharing/requests', other)).body, []);
      await db.query('UPDATE users SET phone=$2 WHERE id=$1', [other, otherPhone]);
      await db.query('INSERT INTO blocked_users VALUES($1,$2)', [other, me]);
      assert.deepEqual((await invoke('get', '/api/phone-sharing/requests', other)).body, []);
      await db.query('TRUNCATE blocked_users');
      await db.query("UPDATE users SET birth_date=CURRENT_DATE-INTERVAL '17 years' WHERE id=$1", [me]);
      assert.deepEqual((await invoke('get', '/api/phone-sharing/requests', other)).body, []);
    });
  } finally {
    await db.query('ROLLBACK');
    await db.end();
  }
});
