'use strict';
const { initializePhonePrivacy, phoneFingerprint } = require('../server/contact-phone-privacy');

const test = require('node:test');
const assert = require('node:assert/strict');
const { executeGuideDataPlan } = require('../server/guide-user-data');

const request = (overrides = {}) => ({ kind: 'members', group_query: 'המטיילים',
  group_scope: 'named', contact_filter: 'all', fields: ['name', 'phone', 'city', 'role'],
  format: 'excel', admins_only: false, ...overrides });
const plan = (...requests) => ({ action: 'read', requests });
const noExport = { exportTables: async () => { assert.fail('this request must not save a file'); } };

test('invalid export plans and missing identity cannot reach queries or storage', async () => {
  const db = { query: async () => { assert.fail('unauthenticated or invalid request must not read data'); } };
  for (const input of [plan(request({ userId: 'other-user' })),
    plan(request({ fields: ['name', 'password_hash'] })), { action: 'unsupported', requests: [] }]) {
    const answer = await executeGuideDataPlan(db, 'requester', input, noExport);
    assert.equal(typeof answer, 'string');
  }
  assert.match(await executeGuideDataPlan(db, null, plan(request()), noExport), /יש להתחבר/);
});

test('read failure in one exported collection prevents saving a partial workbook', async () => {
  const db = { query: async sql => {
    if (sql.includes('FROM user_contacts c')) return { rows: [{ name: 'permitted contact' }] };
    throw Object.assign(new Error('secret database detail'), { code: 'EXPORT_TEST_FAILURE' });
  } };
  const answer = await executeGuideDataPlan(db, 'requester', plan(
    request({ kind: 'contacts', group_query: '', fields: ['name'] }), request(),
  ), noExport);
  assert.match(answer, /לא ניתן לטעון/);
  assert.doesNotMatch(answer, /secret database detail|permitted contact/);
});

test('an empty contact collection exports column headers and missing storage reports failure', async () => {
  const db = { query: async () => ({ rows: [] }) };
  const input = plan(request({ kind: 'contacts', group_query: '', fields: ['name', 'phone', 'city'] }));
  let calls = 0;
  const reply = { answer: 'saved empty table', file: { url: '/media/empty.xlsx' } };
  assert.equal(await executeGuideDataPlan(db, 'requester', input, { exportTables: async value => {
    calls++;
    assert.deepEqual(value.tables, [{ title: 'אנשי הקשר שלי',
      columns: ['שם', 'טלפון', 'עיר מגורים'], rows: [] }]);
    return reply;
  } }), reply);
  assert.equal(calls, 1);
  assert.match(await executeGuideDataPlan(db, 'requester', input), /אינה זמינה כרגע/);
});

test('PostgreSQL Excel exports use authorized current rows and raw spreadsheet cells', {
  skip: process.env.RUN_DB_TESTS !== '1',
}, async t => {
  const { Client } = require('pg');
  const db = new Client({ connectionString: process.env.DATABASE_URL,
    ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' } : false });
  const id = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
  const [me, saved, shared, hidden, outsider, pending, removed, teen, blocked] =
    [7101, 7102, 7103, 7104, 7105, 7106, 7107, 7108, 7109].map(id);
  const [alpha, beta, privateGroup] = [7201, 7202, 7203].map(id);
  await db.connect();
  try {
    await db.query('BEGIN');
    await db.query(`CREATE TEMP TABLE users(id uuid PRIMARY KEY,name text,phone text,city text,gender text,
        birth_date date,email_verified boolean DEFAULT false,phone_verified boolean DEFAULT false);
      CREATE TEMP TABLE groups(id uuid PRIMARY KEY,name text);
      CREATE TEMP TABLE group_members(group_id uuid,user_id uuid,status text,role text);
      CREATE TEMP TABLE user_contacts(owner_id uuid,contact_id uuid);
      CREATE TEMP TABLE blocked_users(blocker_id uuid,blocked_id uuid);
      CREATE TEMP TABLE messages(id uuid,sender_id uuid,recipient_id uuid,group_id uuid,
        deleted_for_everyone boolean DEFAULT false,deleted_for_sender boolean DEFAULT false);
      CREATE TEMP TABLE message_user_deletions(message_id uuid,user_id uuid);`);
    await db.query('SET LOCAL search_path TO pg_temp');
    await initializePhonePrivacy(db);
    for (const [user, name, phone, city, birth] of [
      [me, 'המבקש', '0500000001', 'עיר המבקש', '1990-01-01'],
      [saved, 'שם | שמור', '0500000002', 'ירושלים', '1990-01-01'],
      [shared, 'משותף', '0500000003', 'חיפה', '1990-01-01'],
      [hidden, 'שם | שמור', '0500000004', 'עיר מוסתרת', '1990-01-01'],
      [outsider, 'חבר פרטי', '0500000005', 'עיר פרטית', '1990-01-01'],
      [pending, 'ממתין', null, null, '1990-01-01'],
      [removed, 'הוסר', null, null, '1990-01-01'],
      [teen, 'נוער', '0500000008', 'מגורים ישנים של נוער', '2015-01-01'],
      [blocked, 'חסום', '0500000009', 'עיר חסומה', '1990-01-01'],
    ]) await db.query('INSERT INTO users(id,name,phone,city,birth_date) VALUES($1,$2,$3,$4,$5)',
      [user, name, phone, city, birth]);
    await db.query('UPDATE users SET phone_verified=true WHERE id=$1', [shared]);
    await db.query('INSERT INTO groups VALUES($1,$2),($3,$4),($5,$6)',
      [alpha, 'המטיילים', beta, 'המטיילים בצפון', privateGroup, 'קבוצה פרטית']);
    for (const user of [me, saved, shared, hidden, teen, blocked]) {
      await db.query("INSERT INTO group_members VALUES($1,$2,'member',$3)",
        [alpha, user, user === me ? 'admin' : 'member']);
    }
    for (const user of [me, shared]) {
      await db.query("INSERT INTO group_members VALUES($1,$2,'member','member')", [beta, user]);
    }
    await db.query("INSERT INTO group_members VALUES($1,$2,'member','admin'),($3,$4,'pending','member'),($3,$5,'removed','member')",
      [privateGroup, outsider, alpha, pending, removed]);
    await db.query('INSERT INTO user_contacts VALUES($1,$2),($3,$1)', [me, saved, shared]);
    await db.query('INSERT INTO blocked_users VALUES($1,$2)', [blocked, me]);

    const exported = async (input, user = me, pool = db) => {
      let captured;
      let calls = 0;
      const expectedReply = { answer: 'server-created file', file: { url: '/media/authorized.xlsx' } };
      const reply = await executeGuideDataPlan(pool, user, input, { exportTables: async value => {
        calls++;
        captured = value;
        return expectedReply;
      } });
      assert.equal(calls, 1);
      assert.equal(reply, expectedReply);
      return captured;
    };

    await t.test('named group workbook receives real fields with phone/city redaction and literal pipes', async () => {
      const value = await exported(plan(request({ fields: ['phone', 'name', 'city', 'role'] })));
      const table = value.tables[0];
      assert.deepEqual(table.columns, ['טלפון', 'שם', 'עיר מגורים', 'תפקיד']);
      assert.equal(table.rows.length, 6);
      assert.ok(table.rows.some(row => JSON.stringify(row) === JSON.stringify(['לא זמין להצגה', 'שם | שמור', 'ירושלים', 'חבר/ה'])));
      assert.ok(table.rows.some(row => JSON.stringify(row) === JSON.stringify(['לא זמין להצגה', 'שם | שמור', 'לא זמין להצגה', 'חבר/ה'])));
      assert.ok(table.rows.some(row => JSON.stringify(row) === JSON.stringify(['לא זמין להצגה', 'משותף', 'חיפה', 'חבר/ה'])));
      assert.ok(table.rows.some(row => row[1] === 'נוער' && row[0] === 'לא זמין להצגה' && row[2] === 'לא זמין להצגה'));
      assert.doesNotMatch(JSON.stringify(value), /0500000004|0500000008|0500000009|עיר מוסתרת|מגורים ישנים|עיר חסומה|&#124;|ממתין|הוסר|חבר פרטי/);
    });

    await t.test('exports reveal only verified known or currently approved phones and honor revocation', async () => {
      await db.query('UPDATE user_contacts SET known_phone_hash=$1 WHERE owner_id=$2 AND contact_id=$3',
        [phoneFingerprint('0500000002'), me, saved]);
      await db.query(`INSERT INTO contact_phone_permissions(phone_owner_id,viewer_id,state,phone_hash)
        VALUES($1,$2,'approved',$3)`, [shared, me, phoneFingerprint('0500000003')]);
      const value = await exported(plan(request({ fields: ['name', 'phone', 'city'] })));
      const rows = value.tables[0].rows;
      assert.ok(rows.some(row => row[0] === 'שם | שמור' && row[1] === '0500000002'));
      assert.ok(rows.some(row => row[0] === 'משותף' && row[1] === '0500000003'));
      await db.query('UPDATE user_contacts SET known_phone_hash=NULL');
      await db.query("UPDATE contact_phone_permissions SET state='revoked'");
      const revoked = await exported(plan(request({ fields: ['name', 'phone', 'city'] })));
      assert.doesNotMatch(JSON.stringify(revoked), /0500000002|0500000003/);
      assert.match(JSON.stringify(revoked), /ירושלים|חיפה/);
    });

    await t.test('all-group noncontact export deduplicates user IDs and names only mutual active groups', async () => {
      const value = await exported(plan(request({ group_query: '', group_scope: 'all', contact_filter: 'not_saved',
        fields: ['name', 'groups', 'phone', 'city'] })));
      const rows = value.tables[0].rows;
      assert.equal(rows.length, 3);
      assert.equal(rows.filter(row => row[0] === 'משותף').length, 1);
      assert.deepEqual(rows.find(row => row[0] === 'משותף'),
        ['משותף', 'המטיילים, המטיילים בצפון', 'לא זמין להצגה', 'חיפה']);
      assert.equal(rows.filter(row => row[0] === 'שם | שמור').length, 1);
      assert.doesNotMatch(JSON.stringify(value), /קבוצה פרטית|חבר פרטי|המבקש|חסום|ממתין|הוסר|0500000002|0500000004|עיר מוסתרת/);
    });

    await t.test('contacts and own groups create one workbook with two authorized sheets', async () => {
      const value = await exported(plan(
        request({ kind: 'contacts', group_query: '', fields: ['name', 'phone', 'city'] }),
        request({ kind: 'groups', group_query: '', fields: ['name'] }),
      ));
      assert.equal(value.tables.length, 2);
      assert.deepEqual(value.tables[0].rows, [['שם | שמור', 'לא זמין להצגה', 'ירושלים']]);
      assert.deepEqual(value.tables[1].rows.map(row => row[0]), ['המטיילים', 'המטיילים בצפון']);
      assert.doesNotMatch(JSON.stringify(value), /קבוצה פרטית|חבר פרטי/);
    });

    await t.test('ambiguous or missing group, outsiders, pending, removed and teen requesters cannot create files', async () => {
      for (const [user, group] of [[me, 'מטיילים'], [me, ''], [me, 'קבוצה פרטית'],
        [outsider, 'המטיילים'], [pending, alpha], [removed, 'המטיילים'], [teen, 'המטיילים']]) {
        const answer = await executeGuideDataPlan(db, user, plan(request({ group_query: group })), noExport);
        assert.equal(typeof answer, 'string');
        assert.doesNotMatch(answer, /0500000002|שם \| שמור/);
      }
    });

    await t.test('mixed authorized and unauthorized exports never save a partial file in either order', async () => {
      const allowed = request({ kind: 'contacts', group_query: '', fields: ['name'] });
      const denied = request({ group_query: 'קבוצה פרטית' });
      for (const requests of [[allowed, denied], [denied, allowed]]) {
        const answer = await executeGuideDataPlan(db, me, plan(...requests), noExport);
        assert.match(answer, /לא נמצאה קבוצה תואמת/);
        assert.doesNotMatch(answer, /שם \| שמור|0500000002/);
      }
    });

    await t.test('revoked membership is checked again after resolving the group name before any save', async () => {
      const pool = { query: async (sql, values) => {
        const result = await db.query(sql, values);
        if (sql.includes('g.id,g.name') && sql.includes('FROM groups g')) {
          await db.query("UPDATE group_members SET status='removed' WHERE group_id=$1 AND user_id=$2", [alpha, me]);
        }
        return result;
      } };
      const answer = await executeGuideDataPlan(pool, me, plan(request()), noExport);
      assert.match(answer, /לא נמצאה קבוצה תואמת/);
      assert.doesNotMatch(answer, /שם \| שמור|0500000002/);
    });
  } finally {
    await db.query('ROLLBACK');
    await db.end();
  }
});
