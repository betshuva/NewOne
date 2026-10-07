'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { normalizePhone, normalizedPhoneSql, phoneFingerprint, projectContactPhones,
  getPhoneSharingStatus, phoneSelect } = require('../server/contact-phone-privacy');

const id = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const [viewerId, targetId] = [951, 952].map(id);
const localPhone = '0501234567';
const phoneForms = [localPhone, '050 123-4567', '+972 50-123-4567',
  '972501234567', '00972 50-123-4567'];
const normalizationCases = [
  ...phoneForms.map(value => [value, localPhone]),
  ['0044 7700 900123', '447700900123'],
  ['97212345', '97212345'],
  ['501234567', '501234567'],
  ['050123', null], ['00', null], ['', null], [null, null],
  ['1234567890123456', null],
];

test('phone discovery normalizes international dialing prefixes and preserves exact fingerprints', () => {
  for (const [value, expected] of normalizationCases)
    assert.equal(normalizePhone(value), expected, String(value));
  for (const value of phoneForms)
    assert.equal(phoneFingerprint(value), phoneFingerprint(localPhone), value);
  assert.notEqual(phoneFingerprint('050123456'), phoneFingerprint(localPhone));
  assert.notEqual(phoneFingerprint('0501234568'), phoneFingerprint(localPhone));
});

function projectionDb(overrides = {}) {
  const row = { id: targetId, phone: '00972 50-123-4567', viewer_phone: '0507654321',
    target_adult: true, viewer_adult: true, contact_source: 'in_app', blocked: false,
    ...overrides };
  return { query: async sql => {
    assert.match(sql, /^SELECT /, 'phone projection must remain read-only');
    return { rows: [row] };
  } };
}

test('discovery discloses only the exact supplied phone without persisting knowledge', async () => {
  const db = projectionDb();
  for (const supplied of phoneForms) {
    const [result] = await projectContactPhones(db, viewerId,
      [{ id: targetId, saved: false }], { knownPhones: [supplied] });
    assert.equal(result.phone_visibility, 'known');
    assert.equal(result.phone, '00972 50-123-4567');
    assert.equal(result.saved, false);
  }
  for (const supplied of ['050123', '050123456', '0501234568']) {
    const [result] = await projectContactPhones(db, viewerId,
      [{ id: targetId }], { knownPhones: [supplied] });
    assert.equal(result.phone, null);
  }
  assert.equal((await getPhoneSharingStatus(db, viewerId, targetId)).phone, null);
});

test('canonical phone knowledge and directed consent still respect blocks, age and number changes', async () => {
  const currentHash = phoneFingerprint(localPhone);
  const known = await getPhoneSharingStatus(projectionDb({ known_phone_hash: currentHash }), viewerId, targetId);
  assert.equal(known.phone_visibility, 'known');
  const shared = await getPhoneSharingStatus(projectionDb({ request_state: 'approved',
    requested_phone_hash: currentHash }), viewerId, targetId);
  assert.equal(shared.phone_visibility, 'shared');
  assert.equal(shared.share_my_phone, false, 'the opposite direction has no grant');
  for (const overrides of [
    { blocked: true }, { target_adult: false }, { viewer_adult: false },
    { phone: '0501234568' }, { request_state: 'revoked' },
  ]) {
    const db = projectionDb({ request_state: 'approved', requested_phone_hash: currentHash, ...overrides });
    assert.equal((await getPhoneSharingStatus(db, viewerId, targetId)).phone, null);
  }
  const [blockedKnown] = await projectContactPhones(projectionDb({ blocked: true,
    known_phone_hash: currentHash }), viewerId, [{ id: targetId }], { knownPhones: [localPhone] });
  assert.equal(blockedKnown.phone, null, 'a block also masks supplied and remembered knowledge');
});

const source = fs.readFileSync(require.resolve('../server/index.js'), 'utf8');
function routeHandler(method, route, pool) {
  const start = source.indexOf(`app.${method}('${route}',`);
  const end = source.indexOf('\n});', start);
  assert.ok(start >= 0 && end > start);
  let handler;
  const remembered = [];
  const context = vm.createContext({
    app: { [method]: (_path, ...handlers) => { handler = handlers.at(-1); } },
    authWithDbCheck() {}, searchRateLimit() {}, getPool: async () => pool,
    normalizePhone, normalizedPhoneSql,
    projectContactProfiles: projectContactPhones,
    rememberKnownContactPhones: async (_pool, owner, phones, options) => {
      remembered.push({ owner, phones: [...phones], source: options.source });
    },
    SCAN_BOT_ID: id(991), SYSTEM_USER_ID: id(992), GOOGLE_PLAY_REVIEWER_ID: id(993),
  });
  vm.runInContext(source.slice(start, end + '\n});'.length), context);
  return { remembered, async invoke(q) {
    const output = { status: 200, headers: {} };
    const res = {
      status: code => { output.status = code; return res; },
      set: (name, value) => { output.headers[name] = value; return res; },
      json: body => { output.body = body; return res; },
    };
    await handler({ user: { id: viewerId }, query: { q },
      body: { phones: [q], emails: [], source: 'phone_manual' } }, res);
    assert.equal(output.status, 200, JSON.stringify(output.body));
    return output;
  } };
}

test('PostgreSQL read-only fixtures verify phone discovery queries and phone privacy projection', {
  skip: process.env.RUN_PHONE_SEARCH_DB_TESTS !== '1',
}, async t => {
  const { Client } = require('pg');
  const db = new Client({ connectionString: process.env.DATABASE_URL, connectionTimeoutMillis: 10000,
    ssl: process.env.DB_SSL === 'true'
      ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' } : false });
  const user = (userId, overrides = {}) => ({ id: userId, name: 'חבר בדיקה', gender: 'male',
    email: userId === viewerId ? 'viewer@example.test' : 'friend@example.test',
    phone: userId === viewerId ? '0507654321' : localPhone,
    birth_date: '1990-01-01', email_verified: true, phone_verified: false, ...overrides });
  const fixtures = { users: [user(viewerId), user(targetId)], contacts: [], blocks: [], permissions: [] };
  const pool = { query: async (sql, values) => {
    assert.match(sql, /^SELECT /, 'all discovery fixture queries must be read-only');
    const offset = values.length;
    const prefix = `WITH users AS (SELECT * FROM jsonb_to_recordset($${offset + 1}::jsonb)
        AS fixture(id uuid,name text,gender text,email text,phone text,birth_date date,
          email_verified boolean,phone_verified boolean,profile_pic_url text,city text)),
      user_contacts AS (SELECT * FROM jsonb_to_recordset($${offset + 2}::jsonb)
        AS fixture(owner_id uuid,contact_id uuid,contact_source text,known_phone_hash text)),
      blocked_users AS (SELECT * FROM jsonb_to_recordset($${offset + 3}::jsonb)
        AS fixture(blocker_id uuid,blocked_id uuid)),
      contact_phone_permissions AS (SELECT * FROM jsonb_to_recordset($${offset + 4}::jsonb)
        AS fixture(phone_owner_id uuid,viewer_id uuid,state text,phone_hash text)) `;
    return db.query(prefix + sql, [...values, ...Object.values(fixtures).map(value => JSON.stringify(value))]);
  } };
  await db.connect();
  try {
    await db.query('BEGIN READ ONLY');
    await t.test('SQL and JavaScript agree for every supported dialing form', async () => {
      for (const [value, expected] of normalizationCases) {
        const result = await db.query(`SELECT ${normalizedPhoneSql('$1::text')} AS normalized`, [value]);
        assert.equal(result.rows[0].normalized, expected, String(value));
      }
    });
    for (const [method, route] of [['get', '/api/users/search'], ['post', '/api/contacts/match']]) {
      await t.test(`${method.toUpperCase()} ${route} matches complete phone forms and rejects partial numbers`, async () => {
        const api = routeHandler(method, route, pool);
        for (const storedPhone of phoneForms) {
          fixtures.users[1].phone = storedPhone;
          for (const query of phoneForms) {
            const result = await api.invoke(query);
            assert.equal(result.headers['Cache-Control'], 'no-store');
            assert.equal(result.body.length, 1, `${storedPhone} / ${query}`);
            assert.equal(result.body[0].id, targetId);
            assert.equal(result.body[0].phone_visibility, 'known');
            assert.equal(result.body[0].saved, false);
          }
          for (const query of ['050123', '05012345', '050123456', '0501234568'])
            assert.deepEqual(Array.from((await api.invoke(query)).body), []);
        }
        assert.deepEqual(fixtures.contacts, [], 'discovery never adds an unsaved contact');
        if (method === 'get') assert.deepEqual(api.remembered, []);
      });
    }
    const search = routeHandler('get', '/api/users/search', pool);
    await t.test('search preserves saved status, age restrictions, verification and both block directions', async () => {
      fixtures.users[1].phone = '+972 50-123-4567';
      fixtures.contacts = [{ owner_id: viewerId, contact_id: targetId, contact_source: 'in_app' }];
      assert.equal((await search.invoke(localPhone)).body[0].saved, true);
      fixtures.contacts = [];
      for (const change of [{ birth_date: '2990-01-01' }, { birth_date: null },
        { email_verified: false }, { name: 'משתמש', gender: null }]) {
        fixtures.users[1] = user(targetId, change);
        assert.deepEqual(Array.from((await search.invoke(localPhone)).body), []);
      }
      fixtures.users[1] = user(targetId);
      fixtures.users[0].birth_date = null;
      assert.deepEqual(Array.from((await search.invoke(localPhone)).body), []);
      fixtures.users[0] = user(viewerId);
      fixtures.blocks = [{ blocker_id: viewerId, blocked_id: targetId }];
      assert.deepEqual(Array.from((await search.invoke(localPhone)).body), []);
      fixtures.blocks = [{ blocker_id: targetId, blocked_id: viewerId }];
      const reverseBlocked = (await search.invoke(localPhone)).body;
      assert.equal(reverseBlocked[0].phone, null);
      assert.equal(reverseBlocked[0].phone_visibility, 'hidden');
      fixtures.blocks = [];
    });
    await t.test('SQL phone permission projection shares only the current number in the approved direction', async () => {
      fixtures.users[1].phone = '00972 50-123-4567';
      fixtures.permissions = [{ phone_owner_id: targetId, viewer_id: viewerId,
        state: 'approved', phone_hash: phoneFingerprint(localPhone) }];
      const selected = async () => (await pool.query(`SELECT ${phoneSelect()} FROM users u WHERE u.id=$2`,
        [viewerId, targetId])).rows[0].phone;
      assert.equal(await selected(), fixtures.users[1].phone);
      fixtures.blocks = [{ blocker_id: targetId, blocked_id: viewerId }];
      assert.equal(await selected(), null);
      fixtures.blocks = [];
      fixtures.users[1].phone = '0501234568';
      assert.equal(await selected(), null);
    });
  } finally {
    await db.query('ROLLBACK');
    await db.end();
  }
});
