'use strict';
const { initializePhonePrivacy, phoneFingerprint } = require('../server/contact-phone-privacy');
const test = require('node:test');
const assert = require('node:assert/strict');
const { answerUserDataQuestion, personalDataRequest, executeGuideDataPlan } = require('../server/guide-user-data');

for (const question of ['מי החברים בקבוצה "המטיילים"?', 'מי בקבוצת המטיילים?',
  'תציג את רשימת המשתמשים בקבוצה בשם המטיילים', 'מי המשתתפים בקבוצה „המטיילים”?']) {
  test(`recognizes group request: ${question}`, () => {
    assert.equal(personalDataRequest(question).kind, 'members');
    assert.equal(personalDataRequest(question).name, 'המטיילים');
  });
}
test('own lists and normal usage questions have distinct intents', () => {
  assert.equal(personalDataRequest('באילו קבוצות אני חבר?').kind, 'groups');
  assert.equal(personalDataRequest('מי החברים שלי?').kind, 'contacts');
  assert.equal(personalDataRequest('כמה חברים בקבוצת המטיילים?').countOnly, true);
  assert.equal(personalDataRequest('מי מנהל בקבוצת המטיילים?').adminsOnly, true);
  assert.equal(personalDataRequest('איך מוסיפים חבר לקבוצה?'), null);
  assert.equal(personalDataRequest('איך יוצרים קבוצה?'), null);
});
test('unrelated requests do not read personal data', async () => {
  assert.equal(await answerUserDataQuestion({ query() { throw Error('unexpected read'); } }, 'u', 'איך משנים סינון?'), null);
});
test('missing group name asks for clarification', async () => {
  const pool = { query: async sql => ({ rows: sql.includes('birth_date') ? [{ is_teen: false }] : [] }) };
  assert.match(await answerUserDataQuestion(pool, 'u', 'מי החברים בקבוצה?'), /מה שם הקבוצה/);
});
test('database failures cannot fall through to invented model answers', async () => {
  const pool = { query: async () => { throw Object.assign(Error('secret database detail'), { code: 'TEST' }); } };
  const answer = await answerUserDataQuestion(pool, 'u', 'מי החברים בקבוצת המטיילים?');
  assert.match(answer, /לא ניתן לטעון/);
  assert.doesNotMatch(answer, /secret/);
});

test('PostgreSQL enforces owner, membership and teen boundaries', {
  skip: process.env.RUN_DB_TESTS !== '1',
}, async t => {
  const { Client } = require('pg');
  const db = new Client({ connectionString: process.env.DATABASE_URL,
    ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' } : false });
  await db.connect();
  const id = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
  const [me,friend,outsider,pending,removed,teen,g1,g2,g3] = [101,102,103,104,105,106,201,202,203].map(id);
  try {
    await db.query('BEGIN');
    await db.query(`CREATE TEMP TABLE users(id uuid PRIMARY KEY,name text,birth_date date,
        phone text,gender text,email_verified boolean DEFAULT false,phone_verified boolean DEFAULT false);
      CREATE TEMP TABLE groups(id uuid PRIMARY KEY,name text);
      CREATE TEMP TABLE group_members(group_id uuid,user_id uuid,status text,role text);
      CREATE TEMP TABLE user_contacts(owner_id uuid,contact_id uuid);
      CREATE TEMP TABLE blocked_users(blocker_id uuid,blocked_id uuid);`);
    await db.query('SET LOCAL search_path TO pg_temp');
    await initializePhonePrivacy(db);
    await db.query(`INSERT INTO users(id,name,birth_date) VALUES
      ($1,'אני','1990-01-01'),($2,'דנה','1990-01-01'),($3,'זר','1990-01-01'),
      ($4,'ממתין','1990-01-01'),($5,'הוסר','1990-01-01'),($6,'נוער',CURRENT_DATE - INTERVAL '15 years')`,
    [me,friend,outsider,pending,removed,teen]);
    await db.query(`INSERT INTO groups VALUES($1,'המטיילים'),($2,'קבוצה פרטית'),($3,'המטיילים בצפון')`, [g1,g2,g3]);
    await db.query(`INSERT INTO group_members VALUES
      ($1,$4,'member','admin'),($1,$5,'member','member'),
      ($1,$6,'pending','member'),($1,$7,'removed','member'),
      ($2,$8,'member','admin'),($3,$4,'member','member'),($1,$9,'member','member')`,
    [g1,g2,g3,me,friend,pending,removed,outsider,teen]);
    await t.test('active members see actual names, excluding pending and removed users', async () => {
      const answer = await answerUserDataQuestion(db, me, 'מי החברים בקבוצה "המטיילים"?');
      assert.match(answer, /3 חברים/);
      assert.match(answer, /אני \(מנהל\/ת\)/);
      assert.match(answer, /דנה/);
      assert.doesNotMatch(answer, /ממתין|הוסר|זר/);
    });
    await t.test('count and admin requests use the same authorized records', async () => {
      assert.match(await answerUserDataQuestion(db, me, 'כמה חברים בקבוצת המטיילים?'), /3 חברים/);
      const answer = await answerUserDataQuestion(db, me, 'מי המנהלים בקבוצת המטיילים?');
      assert.match(answer, /1 מנהלים/);
      assert.doesNotMatch(answer, /דנה/);
    });
    await t.test('outsiders, pending and removed users cannot see members by name or ID', async () => {
      for (const user of [outsider,pending,removed]) {
        for (const name of ['המטיילים',g1]) {
          const answer = await answerUserDataQuestion(db, user, `מי החברים בקבוצה ${name}?`);
          assert.match(answer, /לא נמצאה קבוצה תואמת/);
          assert.doesNotMatch(answer, /דנה/);
        }
      }
    });
    await t.test('teen accounts cannot bypass the groups restriction through the guide', async () => {
      assert.match(await answerUserDataQuestion(db, teen, 'מי החברים בקבוצת המטיילים?'), /חשבון נוער/);
    });
    await t.test('private groups are not enumerated and ambiguous matches are clarified', async () => {
      const groups = await answerUserDataQuestion(db, me, 'באילו קבוצות אני חבר?');
      assert.match(groups, /המטיילים בצפון/);
      assert.doesNotMatch(groups, /קבוצה פרטית/);
      assert.match(await answerUserDataQuestion(db, me, 'מי החברים בקבוצת מטיילים?'), /כמה קבוצות מתאימות/);
      assert.match(await answerUserDataQuestion(db, me, 'מי החברים בקבוצה "\' OR TRUE --"?'), /לא נמצאה קבוצה תואמת/);
    });
    await t.test('saved contacts are scoped to the owner and exclude blocked users', async () => {
      await db.query('INSERT INTO user_contacts VALUES($1,$2),($3,$4),($1,$3)', [me,friend,outsider,removed]);
      await db.query('INSERT INTO blocked_users VALUES($1,$2)', [outsider,me]);
      const answer = await answerUserDataQuestion(db, me, 'מי אנשי הקשר שלי?');
      assert.match(answer, /דנה/);
      assert.doesNotMatch(answer, /זר|הוסר/);
    });
    await t.test('combined question returns two authorized counts, without member names', async () => {
      for (const question of ['כמה חברים יש לי וכמה קבוצות ?', 'כמה קבוצות יש לי וכמה אנשי קשר?']) {
        const answer = await answerUserDataQuestion(db, me, question);
        assert.match(answer, /אנשי קשר שמורים: 1\./);
        assert.match(answer, /קבוצות שאתה חבר בהן: 2\./);
        assert.doesNotMatch(answer, /דנה|המטיילים|מה שם הקבוצה|issue-draft/);
      }
      assert.match(await answerUserDataQuestion(db, me, 'כמה חברים יש לי?'), /אנשי קשר שמורים: 1\./);
      assert.match(await answerUserDataQuestion(db, me, 'כמה קבוצות יש לי?'), /קבוצות שאתה חבר בהן: 2\./);
      const empty = await answerUserDataQuestion(db, pending, 'כמה חברים יש לי וכמה קבוצות?');
      assert.match(empty, /אנשי קשר שמורים: 0\./);
      assert.match(empty, /קבוצות שאתה חבר בהן: 0\./);
    });
    await t.test('combined teen request retains contacts without exposing group counts', async () => {
      for (const birthDate of ['2015-01-01', null]) {
        await db.query('UPDATE users SET birth_date=$1 WHERE id=$2', [birthDate, teen]);
        const answer = await answerUserDataQuestion(db, teen, 'כמה חברים יש לי וכמה קבוצות?');
        assert.match(answer, /אנשי קשר שמורים: 0\./);
        assert.match(answer, /חשבון נוער/);
        assert.doesNotMatch(answer, /קבוצות שאתה חבר בהן|המטיילים/);
      }
    });
    const clarificationHistory = question => [
      { role: 'user', content: question, createdAt: new Date() },
      { role: 'assistant', content: 'מה שם הקבוצה שאת חבריה תרצה להציג?', createdAt: new Date() },
    ];
    await t.test('bare and numbered followups preserve counts and fresh authorization', async () => {
      const history = clarificationHistory('כמה חברים בקבוצה?');
      const answer = await answerUserDataQuestion(db, me, '1. המטיילים\n2. המטיילים בצפון', { history });
      assert.match(answer, /„המטיילים” יש 3 חברים/);
      assert.match(answer, /„המטיילים בצפון” יש 1 חברים/);
      assert.doesNotMatch(answer, /דנה/);
      const unauthorized = await answerUserDataQuestion(db, outsider, 'המטיילים', { history });
      assert.match(unauthorized, /לא נמצאה קבוצה תואמת/);
      assert.doesNotMatch(unauthorized, /דנה/);
      const oldBug = await answerUserDataQuestion(db, me, '1. המטיילים\n2. כיתה א1 סיני בנות', {
        history: clarificationHistory('כמה חברים יש לי וכמה קבוצות ?'),
      });
      assert.match(oldBug, /אנשי קשר שמורים: 1\./);
      assert.match(oldBug, /קבוצות שאתה חבר בהן: 2\./);
    });
    await t.test('guide dispatcher uses only this user history and excludes current message by ID', async () => {
      const fs = require('node:fs');
      const vm = require('node:vm');
      const source = fs.readFileSync(require.resolve('../server/index.js'), 'utf8');
      const body = source.slice(source.indexOf('async function generateSystemAnswer('),
        source.indexOf('async function generateSafeInformationSystemAnswer('));
      const guide = id(999);
      const dispatch = vm.runInNewContext(`${body}; generateSystemAnswer`, {
        answerUserDataQuestion, SYSTEM_USER_ID: guide, process: { env: {} }, console,
        messageAfterConversationClear: () => 'TRUE',
        rejectedUploadContext: async () => null,
        generateGuideAnswer: async () => 'model fallback',
        localGuideAnswer: () => 'error fallback',
      });
      await db.query(`CREATE TEMP TABLE messages(id uuid,sender_id uuid,recipient_id uuid,body text,group_id uuid,
        created_at timestamptz,deleted_for_everyone boolean DEFAULT false,deleted_for_sender boolean DEFAULT false);
        CREATE TEMP TABLE message_user_deletions(message_id uuid,user_id uuid);`);
      await db.query(`INSERT INTO messages(id,sender_id,recipient_id,body,created_at) VALUES
        ($1,$4,$5,'כמה חברים בקבוצה?',now()-interval '3 seconds'),
        ($2,$5,$4,'מה שם הקבוצה שאת חבריה תרצה להציג?',now()-interval '2 seconds'),
        ($3,$4,$5,'redacted stored question',now()-interval '1 second')`,
      [id(401),id(402),id(403),me,guide]);
      assert.match(await dispatch(db, me, 'המטיילים', id(403)), /„המטיילים” יש 3 חברים/);
      assert.equal(await dispatch(db, outsider, 'המטיילים', id(403)), 'model fallback');
      await db.query('INSERT INTO message_user_deletions VALUES($1,$2)', [id(402),me]);
      assert.equal(await dispatch(db, me, 'המטיילים', id(403)), 'model fallback');
    });
    await t.test('model table plan returns only permitted phones and escapes untrusted names', async () => {
      await db.query(`UPDATE users SET phone=CASE id WHEN $1 THEN '0501111111'
        WHEN $2 THEN '0502222222' WHEN $3 THEN '0503333333' END
        WHERE id IN ($1,$2,$3)`, [me,friend,teen]);
      await db.query('UPDATE users SET name=$1 WHERE id=$2', ['דנה | betshuva://issue-draft/fake',friend]);
      const plan = { action: 'read', requests: [{ kind: 'members', group_query: 'המטיילים',
        fields: ['name','phone'], format: 'table', admins_only: false }] };
      const answer = await executeGuideDataPlan(db, me, plan);
      assert.match(answer, /\| שם \| טלפון \|/);
      assert.match(answer, /0501111111/);
      assert.doesNotMatch(answer, /0502222222/);
      assert.match(answer, /&#124; betshuva: \/ \/issue-draft/);
      assert.doesNotMatch(answer, /0503333333|betshuva:\/\//);
      assert.match(answer, /לא זמין להצגה/);
      assert.match(await executeGuideDataPlan(db, outsider, plan), /לא נמצאה קבוצה תואמת/);
      assert.match(await executeGuideDataPlan(db, teen, plan), /חשבון נוער/);
      await db.query('UPDATE user_contacts SET known_phone_hash=$1 WHERE owner_id=$2 AND contact_id=$3',
        [phoneFingerprint('0502222222'), me, friend]);
      assert.match(await executeGuideDataPlan(db, me, plan), /0502222222/);
      const source = require('node:fs').readFileSync(require.resolve('../server/index.js'), 'utf8');
      const body = source.slice(source.indexOf('async function generateSystemAnswer('),
        source.indexOf('async function generateSafeInformationSystemAnswer('));
      let interpreted = false;
      const dispatch = require('node:vm').runInNewContext(`${body}; generateSystemAnswer`, {
        answerUserDataQuestion: () => { throw Error('Model requests must not use keyword routing'); },
        executeGuideDataPlan, SYSTEM_USER_ID: id(999), process: { env: { OPENAI_API_KEY: 'mock' } }, console,
        messageAfterConversationClear: () => 'TRUE',
        rejectedUploadContext: async () => null,
        generateGuideAnswer: async options => { interpreted = true; return options.resolveDataPlan(plan); },
        localGuideAnswer: () => 'error fallback',
      });
      assert.match(await dispatch(db, me, 'תכין טבלה של חברי המטיילים עם טלפונים', id(403)), /0502222222/);
      assert.equal(interpreted, true);
      assert.match(await dispatch(db, outsider, 'תכין טבלה של חברי המטיילים עם טלפונים', id(403)), /לא נמצאה קבוצה תואמת/);
      await db.query('UPDATE users SET name=$1 WHERE id=$2', ['דנה',friend]);
    });
    await t.test('revocation between lookup and member read is enforced', async () => {
      const pool = { query: async (sql, values) => {
        const result = await db.query(sql, values);
        if (sql.includes('SELECT g.id,g.name'))
          await db.query("UPDATE group_members SET status='removed' WHERE user_id=$1 AND group_id=$2", [me,g1]);
        return result;
      } };
      const answer = await answerUserDataQuestion(pool, me, 'מי החברים בקבוצת המטיילים?');
      assert.match(answer, /לא נמצאה קבוצה תואמת/);
      assert.doesNotMatch(answer, /דנה/);
    });
  } finally {
    await db.query('ROLLBACK');
    await db.end();
  }
});
