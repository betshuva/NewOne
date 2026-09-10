'use strict';
const { initializePhonePrivacy, phoneFingerprint } = require('../server/contact-phone-privacy');

const test = require('node:test');
const assert = require('node:assert/strict');
const { guidePhoneSelect, guideCitySelect } = require('../server/guide-phone-visibility');

test('PostgreSQL separates explicit phone access from existing city visibility', {
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
  const id = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
  const [me, other, teen, noBirthDate, groupId] = [501, 502, 503, 504, 601].map(id);
  const phone = '0500000502';
  const queryPhone = async (viewer = me, target = other) => {
    const result = await db.query(`SELECT ${guidePhoneSelect} FROM users u WHERE u.id=$2`, [viewer, target]);
    return result.rows[0]?.phone;
  };
  const city = 'ירושלים';
  const queryCity = async (viewer = me, target = other) => {
    const result = await db.query(`SELECT ${guideCitySelect} FROM users u WHERE u.id=$2`, [viewer, target]);
    assert.deepEqual(Object.keys(result.rows[0]), ['city']);
    return result.rows[0].city;
  };
  const reset = async () => {
    await db.query(`TRUNCATE user_contacts,blocked_users,messages,message_user_deletions,group_members,contact_phone_permissions;
      UPDATE users SET birth_date='1990-01-01',name='משתמש בדיקה',gender='male',
        phone_verified=FALSE,email_verified=FALSE,city='${city}';
      UPDATE users SET birth_date=CURRENT_DATE-INTERVAL '15 years' WHERE id='${teen}';
      UPDATE users SET birth_date=NULL WHERE id='${noBirthDate}';
      UPDATE users SET phone='${phone}' WHERE id='${other}'`);
  };
  try {
    await db.query('BEGIN');
    // Every table referenced by the projection is shadowed by a temporary table.
    // Fixtures never read or modify application records, and always roll back.
    // No precise-location fields exist in the fixtures: city retrieval must
    // succeed without reading a street address or coordinates.
    await db.query(`CREATE TEMP TABLE users(id uuid PRIMARY KEY,name text,phone text,email text,city text,
        gender text,birth_date date,email_verified boolean,phone_verified boolean);
      CREATE TEMP TABLE user_contacts(owner_id uuid,contact_id uuid);
      CREATE TEMP TABLE blocked_users(blocker_id uuid,blocked_id uuid);
      CREATE TEMP TABLE group_members(group_id uuid,user_id uuid,status text);
      CREATE TEMP TABLE messages(id uuid,sender_id uuid,recipient_id uuid,group_id uuid,
        deleted_for_everyone boolean DEFAULT FALSE,deleted_for_sender boolean DEFAULT FALSE);
      CREATE TEMP TABLE message_user_deletions(message_id uuid,user_id uuid);`);
    await db.query('SET LOCAL search_path TO pg_temp');
    await initializePhonePrivacy(db);
    await db.query(`INSERT INTO users(id,phone) VALUES($1,'0500000501'),($2,$5),
      ($3,'0500000503'),($4,'0500000504')`, [me, other, teen, noBirthDate, phone]);

    await t.test('own phone is visible; unrelated accounts and group membership do not grant phones', async () => {
      await reset();
      assert.equal(await queryPhone(me, me), '0500000501');
      assert.equal(await queryPhone(), null);
      await db.query("INSERT INTO group_members VALUES($1,$2,'member'),($1,$3,'member')", [groupId, me, other]);
      assert.equal(await queryPhone(), null);
    });

    await t.test('saved contacts and source labels alone never reveal another phone', async () => {
      await reset();
      await db.query('INSERT INTO user_contacts(owner_id,contact_id) VALUES($1,$2),($2,$1),($3,$2),($1,$3)', [me, other, teen]);
      for (const source of ['unknown','in_app','email_import','phone_import','phone_manual']) {
        await db.query('UPDATE user_contacts SET contact_source=$1', [source]);
        assert.equal(await queryPhone(), null);
        assert.equal(await queryPhone(teen), null);
        assert.equal(await queryPhone(me, teen), null);
      }
    });

    await t.test('email or phone verification, adult directory and private messages grant no phone access', async () => {
      await reset();
      for (const method of ['email_verified','phone_verified']) {
        await db.query(`UPDATE users SET ${method}=TRUE WHERE id=$1`, [other]);
        assert.equal(await queryPhone(), null);
        assert.equal(await queryPhone(teen), null);
      }
      await db.query('INSERT INTO messages(id,sender_id,recipient_id) VALUES($1,$2,$3)', [id(701), me, other]);
      assert.equal(await queryPhone(), null);
      await db.query('UPDATE messages SET sender_id=$1,recipient_id=$2', [other, me]);
      assert.equal(await queryPhone(), null);
      await db.query('INSERT INTO user_contacts(owner_id,contact_id) VALUES($1,$2)', [me, other]);
      assert.equal(await queryPhone(), null);
    });

    await t.test('system accounts are not exposed by directory membership', async () => {
      await reset();
      for (const target of [id(1), id(2), '5256aa61-3180-414c-bbf6-a036e8c16248']) {
        await db.query(`INSERT INTO users(id,name,phone,gender,birth_date,email_verified,phone_verified)
          VALUES($1,'מערכת',$2,'male','1990-01-01',TRUE,TRUE)`, [target, phone]);
        assert.equal(await queryPhone(me, target), null);
      }
    });

    await t.test('only the requester exact previously known number is visible; a number change invalidates it', async () => {
      await reset();
      await db.query(`INSERT INTO user_contacts(owner_id,contact_id,contact_source,known_phone_hash)
        VALUES($1,$2,'phone_import',$3)`, [me, other, phoneFingerprint(phone)]);
      assert.equal(await queryPhone(), phone);
      assert.equal(await queryPhone(teen), null, 'another viewer cannot inherit the known number');
      assert.equal(await queryPhone(other, me), null, 'knowing a number is directed');
      await db.query('UPDATE users SET phone=$1 WHERE id=$2', ['+972-50-000-0502', other]);
      assert.equal(await queryPhone(), '+972-50-000-0502', 'formatting changes preserve the same normalized number');
      await db.query('UPDATE users SET phone=$1 WHERE id=$2', ['0509999502', other]);
      assert.equal(await queryPhone(), null, 'a new number is not granted by an old fingerprint');
    });

    await t.test('permission requires approval, the correct direction, current phone and adult participants', async () => {
      await reset();
      await db.query(`INSERT INTO contact_phone_permissions(phone_owner_id,viewer_id,state,phone_hash)
        VALUES($1,$2,'pending',$3)`, [other, me, phoneFingerprint(phone)]);
      assert.equal(await queryPhone(), null);
      await db.query("UPDATE contact_phone_permissions SET state='approved'");
      assert.equal(await queryPhone(), phone);
      assert.equal(await queryPhone(other, me), null);
      assert.equal(await queryPhone(teen), null);
      await db.query('UPDATE users SET phone=$1 WHERE id=$2', ['0509999502', other]);
      assert.equal(await queryPhone(), null);
      await db.query('UPDATE users SET phone=$1 WHERE id=$2', [phone, other]);
      for (const state of ['declined','revoked','pending']) {
        await db.query('UPDATE contact_phone_permissions SET state=$1', [state]);
        assert.equal(await queryPhone(), null);
      }
      await db.query("UPDATE contact_phone_permissions SET state='approved'");
      for (const birth of [null, '2015-01-01']) {
        await db.query('UPDATE users SET birth_date=$1 WHERE id=$2', [birth, other]);
        assert.equal(await queryPhone(), null);
      }
      await db.query("UPDATE users SET birth_date='1990-01-01' WHERE id=$1", [other]);
      await db.query('UPDATE users SET birth_date=NULL WHERE id=$1', [me]);
      assert.equal(await queryPhone(), null);
    });

    await t.test('blocking either way overrides both known-phone and approval grants immediately', async () => {
      await reset();
      await db.query(`INSERT INTO user_contacts(owner_id,contact_id,known_phone_hash)
        VALUES($1,$2,$3)`, [me, other, phoneFingerprint(phone)]);
      await db.query(`INSERT INTO contact_phone_permissions(phone_owner_id,viewer_id,state,phone_hash)
        VALUES($1,$2,'approved',$3)`, [other, me, phoneFingerprint(phone)]);
      assert.equal(await queryPhone(), phone);
      await db.query('INSERT INTO blocked_users VALUES($1,$2)', [me, other]);
      assert.equal(await queryPhone(), null);
      await db.query('UPDATE blocked_users SET blocker_id=$1,blocked_id=$2', [other, me]);
      assert.equal(await queryPhone(), null);
      await db.query('TRUNCATE blocked_users');
      await db.query('UPDATE user_contacts SET known_phone_hash=NULL');
      await db.query("UPDATE contact_phone_permissions SET state='revoked'");
      assert.equal(await queryPhone(), null);
    });

    await t.test('guide recipient API applies phone permission without changing the available contact names', async () => {
      await reset();
      await db.query('INSERT INTO user_contacts(owner_id,contact_id) VALUES($1,$2)', [me, other]);
      const routes = {};
      require('../server/guide-message-send').registerGuideMessageSend({
        get(path, ...handlers) { routes[path] = handlers.at(-1); }, post() {},
      }, { auth() {}, rateLimit() {}, getPool: async () => db,
        systemUserId: id(1), safeInformationUserId: id(2), scanBotId: id(3),
        sendMessage: async () => assert.fail('reading recipients cannot send messages'),
      });
      const recipients = async () => {
        const res = { code: 200, value: null,
          status(code) { this.code = code; return this; },
          json(value) { this.value = value; return this; },
        };
        await routes['/api/guide-message-recipients']({ user: { id: me } }, res);
        assert.equal(res.code, 200);
        return res.value;
      };
      const hidden = await recipients();
      assert.equal(hidden.length, 1);
      assert.equal(hidden[0].id, other);
      assert.equal(hidden[0].phone, null);
      await db.query(`INSERT INTO contact_phone_permissions(phone_owner_id,viewer_id,state,phone_hash)
        VALUES($1,$2,'approved',$3)`, [other, me, phoneFingerprint(phone)]);
      assert.equal((await recipients())[0].phone, phone);
      await db.query("UPDATE contact_phone_permissions SET state='revoked'");
      assert.equal((await recipients())[0].phone, null);
      await db.query('INSERT INTO blocked_users VALUES($1,$2)', [other, me]);
      assert.deepEqual(await recipients(), []);
    });

    await t.test('city requires the requester\'s access and group membership alone grants none', async () => {
      await reset();
      assert.equal(await queryCity(me, me), city);
      assert.equal(await queryCity(), null);
      await db.query("INSERT INTO group_members VALUES($1,$2,'member'),($1,$3,'member')", [groupId, me, other]);
      await db.query('INSERT INTO user_contacts VALUES($1,$2)', [other, me]);
      assert.equal(await queryCity(), null, 'another person saving the requester does not grant city access');
      await db.query('INSERT INTO user_contacts VALUES($1,$2),($3,$2),($1,$3),($1,$4)', [me, other, teen, noBirthDate]);
      assert.equal(await queryCity(), city);
      assert.equal(await queryCity(teen), city, 'saved adult city remains visible to teen requester');
      assert.equal(await queryCity(me, teen), null, 'stale teen city remains hidden even for saved contacts');
      assert.equal(await queryCity(me, noBirthDate), null, 'unknown age cannot expose stale location data');
      await db.query("UPDATE users SET city='  תל אביב  ' WHERE id=$1", [other]);
      assert.equal(await queryCity(), 'תל אביב');
      await db.query("UPDATE users SET city='   ' WHERE id=$1", [other]);
      assert.equal(await queryCity(), null, 'blank city is unavailable');
    });

    await t.test('adult directory grants city only for verified and complete adult accounts', async () => {
      await reset();
      await db.query('UPDATE users SET email_verified=TRUE WHERE id=$1', [other]);
      assert.equal(await queryCity(), city);
      assert.equal(await queryCity(teen), null);
      assert.equal(await queryCity(noBirthDate), null);
      await db.query('UPDATE users SET email_verified=FALSE,phone_verified=TRUE WHERE id=$1', [other]);
      assert.equal(await queryCity(), city);
      await db.query("UPDATE users SET birth_date=CURRENT_DATE-INTERVAL '17 years' WHERE id=$1", [other]);
      assert.equal(await queryCity(), null);
      await db.query('UPDATE users SET birth_date=NULL WHERE id=$1', [other]);
      assert.equal(await queryCity(), null);
      await db.query("UPDATE users SET birth_date=CURRENT_DATE-INTERVAL '18 years' WHERE id=$1", [other]);
      assert.equal(await queryCity(), city);
      await db.query("UPDATE users SET name='משתמש',gender=NULL WHERE id=$1", [other]);
      assert.equal(await queryCity(), null);
      for (const target of [id(1), id(2), '5256aa61-3180-414c-bbf6-a036e8c16248']) {
        await db.query('UPDATE users SET phone_verified=TRUE WHERE id=$1', [target]);
        assert.equal(await queryCity(me, target), null);
      }
    });

    await t.test('city access through a private conversation respects individual and global deletions', async () => {
      await reset();
      const messageId = id(703);
      await db.query('INSERT INTO messages(id,sender_id,recipient_id) VALUES($1,$2,$3)', [messageId, me, other]);
      assert.equal(await queryCity(), city);
      await db.query('UPDATE messages SET deleted_for_sender=TRUE');
      assert.equal(await queryCity(), null);
      await db.query('UPDATE messages SET sender_id=$1,recipient_id=$2', [other, me]);
      assert.equal(await queryCity(), city);
      await db.query('INSERT INTO message_user_deletions VALUES($1,$2)', [messageId, me]);
      assert.equal(await queryCity(), null);
      await db.query('UPDATE message_user_deletions SET user_id=$1', [other]);
      assert.equal(await queryCity(), city);
      await db.query('UPDATE messages SET deleted_for_everyone=TRUE');
      assert.equal(await queryCity(), null);
      await db.query('UPDATE messages SET deleted_for_everyone=FALSE,group_id=$1', [groupId]);
      assert.equal(await queryCity(), null);
    });

    await t.test('blocking either way hides city despite contacts, conversations and directory visibility', async () => {
      await reset();
      await db.query('INSERT INTO user_contacts VALUES($1,$2)', [me, other]);
      await db.query('INSERT INTO messages(id,sender_id,recipient_id) VALUES($1,$2,$3)', [id(704), me, other]);
      await db.query('UPDATE users SET phone_verified=TRUE WHERE id=$1', [other]);
      assert.equal(await queryCity(), city);
      await db.query('INSERT INTO blocked_users VALUES($1,$2)', [me, other]);
      assert.equal(await queryCity(), null);
      await db.query('UPDATE blocked_users SET blocker_id=$1,blocked_id=$2', [other, me]);
      assert.equal(await queryCity(), null);
      await db.query('TRUNCATE blocked_users,user_contacts,messages');
      await db.query('UPDATE users SET phone_verified=FALSE WHERE id=$1', [other]);
      assert.equal(await queryCity(), null);
    });
  } finally {
    await db.query('ROLLBACK');
    await db.end();
  }
});
