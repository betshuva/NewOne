'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  initializePhonePrivacy, phoneSelect, projectContactPhones,
  saveContactWithPhone, getPhoneSharingStatus, applyPhoneSharingChoices,
  rememberKnownContactPhones, normalizePhone, phoneFingerprint,
} = require('../server/contact-phone-privacy');

const id = value => `00000000-0000-4000-8000-${String(value).padStart(12, '0')}`;
const [me, other, third, teen, unknownAge, withoutPhone] = [801, 802, 803, 804, 805, 806].map(id);
const myPhone = '0500000801';
const otherPhone = '0500000802';

test('known phone fingerprints normalize exact numbers without accepting partial searches', () => {
  assert.equal(normalizePhone('+972 50-000-0802'), otherPhone);
  assert.equal(phoneFingerprint(otherPhone), phoneFingerprint('+972-50-000-0802'));
  assert.notEqual(phoneFingerprint(otherPhone), phoneFingerprint(myPhone));
  assert.equal(normalizePhone('802'), null);
  assert.equal(normalizePhone(null), null);
  assert.equal(phoneFingerprint(''), null);
  assert.throws(() => phoneSelect('$1; DELETE FROM users'), /Invalid phone projection/);
});

test('malformed IDs and ambiguous consent values fail before any database call', async () => {
  const db = { query: async () => assert.fail('invalid input reached database') };
  await assert.rejects(saveContactWithPhone(db, 'bad', other), { code: 'INVALID_USER_ID' });
  await assert.rejects(saveContactWithPhone(db, me, me), { code: 'PHONE_SELF_REQUEST' });
  await assert.rejects(saveContactWithPhone(db, me, other, { source: 'phone_import' }), { code: 'KNOWN_PHONE_REQUIRED' });
  await assert.rejects(saveContactWithPhone(db, me, other, { source: 'phone_import', knownPhone: '802' }), { code: 'KNOWN_PHONE_REQUIRED' });
  await assert.rejects(applyPhoneSharingChoices(db, me, other, { share_my_phone: 'true' }), { code: 'INVALID_PHONE_CHOICES' });
  await assert.rejects(applyPhoneSharingChoices(db, me, other, { phone_response: true }), { code: 'INVALID_PHONE_RESPONSE' });
  await assert.rejects(applyPhoneSharingChoices(db, me, other, { phone_response: 'approve', share_my_phone: false }), { code: 'CONFLICTING_PHONE_CHOICES' });
});

test('PostgreSQL contact phone access follows exact knowledge and directed owner consent', {
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
  const reset = async () => {
    await db.query('TRUNCATE user_contacts,blocked_users,contact_phone_permissions');
    await db.query(`UPDATE users SET birth_date='1990-01-01',name='משתמש בדיקה',gender='male',email_verified=TRUE;
      UPDATE users SET phone='${myPhone}' WHERE id='${me}';
      UPDATE users SET phone='${otherPhone}' WHERE id='${other}';
      UPDATE users SET birth_date=CURRENT_DATE-INTERVAL '15 years' WHERE id='${teen}';
      UPDATE users SET birth_date=NULL WHERE id='${unknownAge}'`);
  };
  const status = (viewer = me, target = other) => getPhoneSharingStatus(db, viewer, target);
  const selectedPhone = async (viewer = me, target = other) => {
    const result = await db.query(`SELECT ${phoneSelect()} FROM users u WHERE u.id=$2`, [viewer, target]);
    return result.rows[0]?.phone;
  };
  const assertVisibility = async (expected, viewer = me, target = other) => {
    assert.equal((await status(viewer, target)).phone, expected);
    assert.equal(await selectedPhone(viewer, target), expected, 'SQL projection and application policy must agree');
  };
  try {
    await db.query('BEGIN');
    // Every relation used by the policy shadows the application table. The
    // initializer only alters these temporary fixtures, which always roll back.
    await db.query(`CREATE TEMP TABLE users(id UUID PRIMARY KEY,phone TEXT,birth_date DATE,
        name TEXT,gender TEXT,email_verified BOOLEAN DEFAULT TRUE,phone_verified BOOLEAN DEFAULT FALSE);
      CREATE TEMP TABLE user_contacts(owner_id UUID,contact_id UUID,PRIMARY KEY(owner_id,contact_id));
      CREATE TEMP TABLE blocked_users(blocker_id UUID,blocked_id UUID);
      CREATE TEMP TABLE contact_phone_permissions(
        phone_owner_id UUID REFERENCES users(id),viewer_id UUID REFERENCES users(id),
        state TEXT NOT NULL CHECK(state IN ('pending','approved','declined','revoked')),
        phone_hash TEXT,requested_at TIMESTAMPTZ,updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        PRIMARY KEY(phone_owner_id,viewer_id),CHECK(phone_owner_id<>viewer_id));`);
    await db.query('SET LOCAL search_path=pg_temp,public');
    await initializePhonePrivacy(db);
    await db.query(`INSERT INTO users(id,phone) VALUES
      ($1,$7),($2,$8),($3,'0500000803'),($4,'0500000804'),($5,'0500000805'),($6,NULL)`,
    [me, other, third, teen, unknownAge, withoutPhone, myPhone, otherPhone]);

    await t.test('legacy, app and email-only contacts never imply knowledge of a phone', async () => {
      await reset();
      await db.query('INSERT INTO user_contacts(owner_id,contact_id) VALUES($1,$2),($2,$1)', [me, other]);
      assert.equal((await status()).contact_source, 'unknown');
      await assertVisibility(null);
      await saveContactWithPhone(db, me, other, { source: 'in_app' });
      await assertVisibility(null);
      await db.query("UPDATE user_contacts SET contact_source='phone_import'");
      await assertVisibility(null, me, other);
      const results = await projectContactPhones(db, me, [{ id: other, phone: otherPhone, email: 'synthetic@example.test' }]);
      assert.equal(results[0].phone, null, 'email match input cannot expose the matched phone');
      assert.equal(results[0].phone_visibility, 'hidden');
      await assertVisibility(myPhone, me, me);
    });

    await t.test('only server-checked complete supplied phone grants a one-way known contact', async () => {
      await reset();
      await assert.rejects(saveContactWithPhone(db, me, other,
        { source: 'phone_import', knownPhone: myPhone }), { code: 'PHONE_DOES_NOT_MATCH' });
      await assertVisibility(null);
      const saved = await saveContactWithPhone(db, me, other,
        { source: 'phone_import', knownPhone: '+972-50-000-0802' });
      assert.equal(saved.phone_visibility, 'known');
      assert.equal(saved.contact_source, 'phone_import');
      await assertVisibility(otherPhone);
      await assertVisibility(null, other, me);
      await saveContactWithPhone(db, me, other, { source: 'in_app' });
      await assertVisibility(otherPhone, me, other);
      await assertVisibility(null, third, other);
    });

    await t.test('contact save retains verification and placeholder eligibility rules', async () => {
      await reset();
      await db.query('UPDATE users SET email_verified=FALSE,phone_verified=FALSE WHERE id=$1', [other]);
      await assert.rejects(saveContactWithPhone(db, me, other), { code: 'USER_NOT_FOUND' });
      await db.query("UPDATE users SET email_verified=TRUE,name='משתמש',gender=NULL WHERE id=$1", [other]);
      await assert.rejects(saveContactWithPhone(db, me, other), { code: 'USER_NOT_FOUND' });
      await assertVisibility(null);
    });

    await t.test('bulk exact phone matching masks email-only results and uses one database query', async () => {
      await reset();
      let queries = 0;
      const counted = { query: (...args) => { queries++; return db.query(...args); } };
      const result = await projectContactPhones(counted, me,
        [{ id: other, phone: otherPhone }, { id: third, phone: '0500000803' }],
        { knownPhones: ['+972 50 000 0802'] });
      assert.equal(queries, 1);
      assert.equal(result[0].phone, otherPhone);
      assert.equal(result[0].phone_visibility, 'known');
      assert.equal(result[1].phone, null);
      await assertVisibility(null, me, other, 'match response alone does not persist knowledge');
    });

    await t.test('bulk supplied phones upgrade only the viewer\'s matching existing contacts', async () => {
      await reset();
      await db.query(`INSERT INTO user_contacts(owner_id,contact_id,contact_source)
        VALUES($1,$2,'in_app'),($1,$3,'email_import'),($3,$2,'unknown')`, [me, other, third]);
      let queries = 0;
      const counted = { query: (...args) => { queries++; return db.query(...args); } };
      assert.equal(await rememberKnownContactPhones(counted, me,
        ['+972-50-000-0802', otherPhone, '803', '0509999803', '0500000804']), 1);
      assert.equal(queries, 1, 'all supplied phones are remembered in one update');
      assert.equal((await status()).contact_source, 'phone_import');
      await assertVisibility(otherPhone, me, other);
      await assertVisibility(null, me, third, 'email-only or unmatched saved contacts remain hidden');
      await assertVisibility(null, third, other, 'another viewer\'s row is not upgraded');
      assert.equal((await status(me, third)).contact_source, 'email_import');
      const contacts = await db.query('SELECT owner_id,contact_id FROM user_contacts');
      assert.equal(contacts.rows.length, 3, 'a matching phone never creates an unsaved contact');
      assert.equal(await rememberKnownContactPhones(db, me, [otherPhone]), 0, 'repeat imports are idempotent');
      assert.equal(await rememberKnownContactPhones(db, me, [otherPhone], { source: 'phone_manual' }), 1);
      assert.equal((await status()).contact_source, 'phone_manual');
    });

    await t.test('bulk remembrance honors both block directions and caps caller-supplied phones', async () => {
      await reset();
      await db.query('INSERT INTO user_contacts(owner_id,contact_id) VALUES($1,$2)', [me, other]);
      await db.query('INSERT INTO blocked_users VALUES($1,$2)', [other, me]);
      assert.equal(await rememberKnownContactPhones(db, me, [otherPhone]), 0);
      await db.query('UPDATE blocked_users SET blocker_id=$1,blocked_id=$2', [me, other]);
      assert.equal(await rememberKnownContactPhones(db, me, [otherPhone]), 0);
      await db.query('TRUNCATE blocked_users');
      assert.equal(await rememberKnownContactPhones(db, me, [...Array(2000).fill('802'), otherPhone]), 0);
      await assertVisibility(null);
      assert.equal(await rememberKnownContactPhones(db, me, [otherPhone]), 1);
      await assertVisibility(otherPhone);
    });

    await t.test('a request exposes no phone until its owner approves, independently in each direction', async () => {
      await reset();
      const requested = await applyPhoneSharingChoices(db, me, other, { request_phone: true, share_my_phone: false });
      assert.equal(requested.changes.requested, true);
      assert.equal(requested.request_state, 'pending');
      await assertVisibility(null);
      assert.equal((await status(other, me)).incoming_request, true);
      const again = await applyPhoneSharingChoices(db, me, other, { request_phone: true });
      assert.equal(again.changes.requested, false);
      await assert.rejects(applyPhoneSharingChoices(db, me, other, { phone_response: 'approve' }), { code: 'PHONE_REQUEST_NOT_PENDING' });
      const response = await applyPhoneSharingChoices(db, other, me, { phone_response: 'approve', request_phone: true });
      assert.equal(response.changes.responded, true);
      assert.equal(response.changes.requested, true);
      await assertVisibility(otherPhone, me, other);
      await assertVisibility(null, other, me);
      await applyPhoneSharingChoices(db, me, other, { phone_response: 'approve' });
      await assertVisibility(myPhone, other, me);
      const approvedAgain = await applyPhoneSharingChoices(db, me, other, { phone_response: 'approve' });
      assert.equal(approvedAgain.changes.shared, false);
    });

    await t.test('friend/filter choices may share your own number and request the other without reciprocal consent', async () => {
      await reset();
      await saveContactWithPhone(db, me, other);
      const result = await applyPhoneSharingChoices(db, me, other, { share_my_phone: true, request_phone: true });
      assert.equal(result.share_my_phone, true);
      assert.equal(result.incoming_request, false);
      assert.equal(result.request_state, 'pending');
      await assertVisibility(myPhone, other, me);
      await assertVisibility(null, me, other);
      await applyPhoneSharingChoices(db, other, me, { phone_response: 'decline' });
      await assertVisibility(null, me, other);
      await assertVisibility(myPhone, other, me);
      assert.equal((await status()).request_state, 'declined');
    });

    await t.test('declined requests cool down, repeat decisions are idempotent, and validation precedes every choice', async () => {
      await reset();
      await applyPhoneSharingChoices(db, me, other, { request_phone: true });
      await applyPhoneSharingChoices(db, other, me, { phone_response: 'decline' });
      const again = await applyPhoneSharingChoices(db, other, me, { phone_response: 'decline' });
      assert.equal(again.changes.responded, false);
      await assert.rejects(applyPhoneSharingChoices(db, me, other,
        { request_phone: true, share_my_phone: true }), { code: 'PHONE_REQUEST_COOLDOWN' });
      await assertVisibility(null, other, me, 'failed combined choice must not partially share the actor phone');
      await db.query("UPDATE contact_phone_permissions SET updated_at=now()-INTERVAL '25 hours'");
      assert.equal((await applyPhoneSharingChoices(db, me, other, { request_phone: true })).changes.requested, true);
    });

    await t.test('changed numbers invalidate known and approved rights until fresh proof or approval', async () => {
      await reset();
      await saveContactWithPhone(db, me, other, { source: 'phone_manual', knownPhone: otherPhone });
      await applyPhoneSharingChoices(db, other, third, { share_my_phone: true });
      await assertVisibility(otherPhone, me, other);
      await assertVisibility(otherPhone, third, other);
      await db.query("UPDATE users SET phone='0509999802' WHERE id=$1", [other]);
      await assertVisibility(null, me, other);
      await assertVisibility(null, third, other);
      assert.equal((await status(third, other)).request_state, 'none');
      await applyPhoneSharingChoices(db, other, third, { share_my_phone: true });
      await assertVisibility('0509999802', third, other);
      await assertVisibility(null, me, other);
    });

    await t.test('either direction of blocking masks known and granted phones; revocation works while blocked', async () => {
      await reset();
      await saveContactWithPhone(db, me, other, { source: 'phone_import', knownPhone: otherPhone });
      await applyPhoneSharingChoices(db, me, other, { share_my_phone: true });
      await db.query('INSERT INTO blocked_users VALUES($1,$2)', [me, other]);
      await assertVisibility(null, me, other);
      await assertVisibility(null, other, me);
      await assert.rejects(applyPhoneSharingChoices(db, other, me, { share_my_phone: true }), { code: 'PHONE_SHARING_UNAVAILABLE' });
      await db.query('UPDATE blocked_users SET blocker_id=$1,blocked_id=$2', [other, me]);
      await assertVisibility(null, me, other);
      const projected = await projectContactPhones(db, me, [{ id: other, phone: otherPhone }], { knownPhones: [otherPhone] });
      assert.equal(projected[0].phone, null);
      assert.equal((await applyPhoneSharingChoices(db, me, other, { share_my_phone: false })).changes.revoked, true);
      await db.query('TRUNCATE blocked_users');
      await assertVisibility(null, other, me);
      await assertVisibility(otherPhone, me, other);
    });

    await t.test('new grants and requests require both adults, while genuinely known numbers remain known', async () => {
      await reset();
      for (const young of [teen, unknownAge]) {
        await assert.rejects(applyPhoneSharingChoices(db, me, young, { share_my_phone: true }), { code: 'ADULTS_ONLY' });
        await assert.rejects(applyPhoneSharingChoices(db, young, me, { request_phone: true }), { code: 'ADULTS_ONLY' });
        assert.equal((await status(me, young)).can_share_my_phone, false);
      }
      await saveContactWithPhone(db, teen, other, { source: 'phone_manual', knownPhone: otherPhone });
      await assertVisibility(otherPhone, teen, other);
      assert.equal((await status(me, withoutPhone)).phone_visibility, 'unavailable');
      assert.equal((await status(me, withoutPhone)).can_request_phone, false);
      const noOwnPhone = await status(withoutPhone, me);
      assert.equal(noOwnPhone.my_phone_available, false);
      assert.equal(noOwnPhone.share_unavailable_reason, 'missing_phone');
      assert.equal((await status(teen, me)).share_unavailable_reason, 'age_restricted');
      await assert.rejects(applyPhoneSharingChoices(db, withoutPhone, me, { share_my_phone: true }), { code: 'PHONE_REQUIRED' });
    });
  } finally {
    await db.query('ROLLBACK');
    await db.end();
  }
});
