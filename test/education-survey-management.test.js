const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { SCHEMA, normalizeSurveyDraft, registerEducationSurveyManagement } = require('../server/education-survey-management');

const draftBody = { title: 'טיוטת טיול', description: 'עוד לא מוכנה', anonymous: true,
  questions: [{ text: '', options: ['', 'בוקר'] }, { text: 'לאן?', options: [] }] };

test('drafts retain incomplete questions while enforcing survey storage limits', () => {
  assert.deepEqual(normalizeSurveyDraft(draftBody), draftBody);
  assert.deepEqual(normalizeSurveyDraft({ title: 'כותרת בלבד' }), {
    title: 'כותרת בלבד', description: null, questions: [], anonymous: false,
  });
  for (const body of [
    { title: '' }, { title: 'א'.repeat(161) }, { title: 'סקר', description: 'א'.repeat(5001) },
    { title: 'סקר', questions: {} }, { title: 'סקר', questions: Array(21).fill({}) },
    { title: 'סקר', questions: [null] }, { title: 'סקר', questions: [{ text: 'א'.repeat(301) }] },
    { title: 'סקר', questions: [{ options: 'אפשרות' }] },
    { title: 'סקר', questions: [{ options: Array(13).fill('') }] },
    { title: 'סקר', questions: [{ options: ['א'.repeat(151)] }] },
  ]) assert.throws(() => normalizeSurveyDraft(body));
});
test('survey drafts retain each question selection mode and reject invalid flags', () => {
  const questions = [{ ...draftBody.questions[0], allowMultiple: true },
    { ...draftBody.questions[1], allowMultiple: false }];
  assert.deepEqual(normalizeSurveyDraft({ ...draftBody, questions }).questions,
    [questions[0], draftBody.questions[1]]);
  for (const allowMultiple of [null, 'true', 1, [], {}])
    assert.throws(() => normalizeSurveyDraft({ ...draftBody,
      questions: [{ ...draftBody.questions[0], allowMultiple }] }));
});

function routes(dependencies) {
  const handlers = new Map();
  const app = Object.fromEntries(['get', 'post', 'put', 'delete'].map(method => [method,
    (path, auth, handler) => handlers.set(`${method.toUpperCase()} ${path}`, handler)]));
  registerEducationSurveyManagement(app, { auth() {}, ...dependencies });
  return async function call(method, path, user, id, body = {}) {
    const res = { code: 200, status(value) { this.code = value; return this; },
      json(value) { this.body = value; return this; } };
    await handlers.get(`${method} ${path}`)({ params: { id }, user: { id: user }, body }, res);
    return res;
  };
}

test('published survey deletion rolls back every failure before broadcasting', async () => {
  for (const scenario of ['unauthorized', 'other-type', 'write-failure', 'success']) {
    const calls = [], events = [];
    let released = false;
    const client = {
      async query(sql, args) {
        calls.push({ sql, args });
        if (sql.startsWith('SELECT f.id')) return { rows: scenario === 'unauthorized' ? [] : [{
          id: 'survey', group_id: 'group', form_type: scenario === 'other-type' ? 'approval' : 'survey',
        }] };
        if (sql.startsWith('UPDATE messages')) return { rows: [{ id: 'announcement' }] };
        if (sql.startsWith('DELETE FROM education_forms') && scenario === 'write-failure')
          throw new Error('simulated transaction failure');
        return { rows: [] };
      },
      release() { released = true; },
    };
    const call = routes({ getPool: async () => ({ connect: async () => client }),
      io: { to: room => ({ emit: (name, data) => {
        assert(calls.some(c => c.sql === 'COMMIT'));
        events.push({ room, name, data });
      } }) } });
    const response = await call('DELETE', '/api/education-forms/:id', 'admin', 'survey');
    assert.equal(released, true);
    if (scenario === 'success') {
      assert.equal(response.code, 200);
      assert(!calls.some(c => c.sql === 'ROLLBACK'));
      assert(calls[1].sql.includes('FOR UPDATE OF f'));
      assert(calls[1].sql.includes("gm.role='admin' AND gm.status='member'"));
      assert.deepEqual(events, [
        { room: 'group:group', name: 'message:deleted', data: { id: 'announcement', groupId: 'group' } },
        { room: 'group:group', name: 'education:updated', data: { groupId: 'group', formId: 'survey', action: 'deleted' } },
      ]);
    } else {
      assert.equal(response.code, scenario === 'unauthorized' ? 403 : scenario === 'other-type' ? 400 : 500);
      assert.equal(calls.at(-1).sql, 'ROLLBACK');
      assert(!calls.some(c => c.sql === 'COMMIT'));
      assert.equal(events.length, 0);
      if (scenario !== 'write-failure') assert(!calls.some(c => c.sql.startsWith('UPDATE messages')));
    }
  }
});

test('PostgreSQL keeps survey drafts private and unannounced and deletes published surveys atomically',
  { skip: process.env.EDUCATION_TEST_DB !== '1' }, async () => {
  require('dotenv').config({ quiet: true });
  const { Client } = require('pg');
  const db = new Client({ connectionString: process.env.DATABASE_URL,
    ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' } : false });
  await db.connect();
  try {
    await db.query('SET search_path TO pg_temp, public');
    await db.query(`CREATE TEMP TABLE groups(id uuid PRIMARY KEY);
      CREATE TEMP TABLE users(id uuid PRIMARY KEY);
      CREATE TEMP TABLE group_members(group_id uuid,user_id uuid,role text,status text,PRIMARY KEY(group_id,user_id));
      CREATE TEMP TABLE education_forms(id uuid PRIMARY KEY,group_id uuid,form_type text,title text);
      CREATE TEMP TABLE education_form_recipients(form_id uuid REFERENCES education_forms(id) ON DELETE CASCADE,user_id uuid);
      CREATE TEMP TABLE education_form_responses(form_id uuid REFERENCES education_forms(id) ON DELETE CASCADE,answers jsonb);
      CREATE TEMP TABLE education_form_revisions(form_id uuid REFERENCES education_forms(id) ON DELETE CASCADE,snapshot jsonb);
      CREATE TEMP TABLE education_form_reminders(form_id uuid REFERENCES education_forms(id) ON DELETE CASCADE);
      CREATE TEMP TABLE education_response_change_requests(form_id uuid REFERENCES education_forms(id) ON DELETE CASCADE);
      CREATE TEMP TABLE messages(id uuid PRIMARY KEY,group_id uuid,body text,file_url text,file_name text,
        education_form_id uuid REFERENCES education_forms(id) ON DELETE SET NULL,
        deleted_for_everyone boolean DEFAULT false,reply_to_id uuid REFERENCES messages(id));
      CREATE TEMP TABLE message_status(message_id uuid REFERENCES messages(id),user_id uuid);`);
    // All tables, including the actual draft schema, live only in this session.
    await db.query(SCHEMA.replace('CREATE TABLE IF NOT EXISTS education_survey_drafts',
      'CREATE TEMP TABLE education_survey_drafts'));
    const [group, otherGroup, admin, otherAdmin, member, pending, removed, outsider] =
      Array.from({ length: 8 }, () => crypto.randomUUID());
    await db.query('INSERT INTO groups VALUES($1),($2)', [group, otherGroup]);
    for (const user of [admin, otherAdmin, member, pending, removed, outsider])
      await db.query('INSERT INTO users VALUES($1)', [user]);
    for (const [user, role, status] of [[admin, 'admin', 'member'], [otherAdmin, 'admin', 'member'],
      [member, 'member', 'member'], [pending, 'admin', 'pending'], [removed, 'admin', 'removed']])
      await db.query('INSERT INTO group_members VALUES($1,$2,$3,$4)', [group, user, role, status]);
    await db.query("INSERT INTO group_members VALUES($1,$2,'admin','member')", [otherGroup, admin]);
    const events = [], queries = [];
    const query = async (sql, args) => { queries.push(sql); return db.query(sql, args); };
    const call = routes({ getPool: async () => ({ query,
      connect: async () => ({ query, release() {} }) }),
    io: { to: room => ({ emit: (name, data) => events.push({ room, name, data }) }) } });
    for (const user of [member, pending, removed, outsider]) {
      assert.equal((await call('GET', '/api/groups/:id/education-survey-drafts', user, group)).code, 403);
      assert.equal((await call('POST', '/api/groups/:id/education-survey-drafts', user, group, draftBody)).code, 403);
    }
    const saved = await call('POST', '/api/groups/:id/education-survey-drafts', admin, group, draftBody);
    assert.equal(saved.code, 201, JSON.stringify(saved.body));
    assert.deepEqual(saved.body.questions, draftBody.questions);
    const draftId = saved.body.id;
    assert.equal((await call('GET', '/api/groups/:id/education-survey-drafts', admin, group)).body.drafts.length, 1);
    assert.deepEqual((await call('GET', '/api/groups/:id/education-survey-drafts', otherAdmin, group)).body.drafts, []);
    assert.deepEqual((await call('GET', '/api/groups/:id/education-survey-drafts', admin, otherGroup)).body.drafts, []);
    for (const user of [otherAdmin, member, pending, removed, outsider]) {
      assert.equal((await call('PUT', '/api/education-survey-drafts/:id', user, draftId, draftBody)).code, 404);
      assert.equal((await call('DELETE', '/api/education-survey-drafts/:id', user, draftId)).code, 404);
    }
    const updated = await call('PUT', '/api/education-survey-drafts/:id', admin, draftId,
      { ...draftBody, title: 'טיוטה מעודכנת', questions: [{ text: 'מתי?', options: [''] }] });
    assert.equal(updated.code, 200);
    assert.equal(updated.body.id, draftId);
    assert.equal(updated.body.title, 'טיוטה מעודכנת');
    await db.query("UPDATE group_members SET status='pending' WHERE group_id=$1 AND user_id=$2", [group, admin]);
    assert.equal((await call('PUT', '/api/education-survey-drafts/:id', admin, draftId, draftBody)).code, 404);
    assert.equal((await call('DELETE', '/api/education-survey-drafts/:id', admin, draftId)).code, 404);
    await db.query("UPDATE group_members SET status='member' WHERE group_id=$1 AND user_id=$2", [group, admin]);
    for (const table of ['education_forms', 'education_form_recipients', 'messages'])
      assert.equal((await db.query(`SELECT * FROM ${table}`)).rowCount, 0, 'Draft saving must not publish');
    assert.equal(events.length, 0);
    assert.equal((await call('DELETE', '/api/education-survey-drafts/:id', admin, draftId)).code, 200);
    assert.equal((await db.query('SELECT * FROM education_survey_drafts')).rowCount, 0);

    const [survey, approval, failure, announcement, republished, reply, failureMessage] =
      Array.from({ length: 7 }, () => crypto.randomUUID());
    await db.query("INSERT INTO education_forms VALUES($1,$4,'survey','סקר'),($2,$4,'approval','אישור'),($3,$4,'survey','fail')",
      [survey, approval, failure, group]);
    for (const table of ['education_form_recipients', 'education_form_responses', 'education_form_revisions',
      'education_form_reminders', 'education_response_change_requests'])
      await db.query(`INSERT INTO ${table}(form_id) VALUES($1)`, [survey]);
    for (const [id, form] of [[announcement, survey], [republished, survey], [failureMessage, failure]])
      await db.query('INSERT INTO messages(id,group_id,body,education_form_id) VALUES($1,$2,$3,$4)',
        [id, group, 'סקר חדש', form]);
    await db.query("INSERT INTO messages(id,group_id,body,reply_to_id) VALUES($1,$2,'תגובה',$3)", [reply, group, announcement]);
    await db.query('INSERT INTO message_status VALUES($1,$2)', [announcement, member]);
    for (const user of [member, pending, removed, outsider])
      assert.equal((await call('DELETE', '/api/education-forms/:id', user, survey)).code, 403);
    assert.equal((await call('DELETE', '/api/education-forms/:id', admin, approval)).code, 400);
    assert.equal(events.length, 0);

    await db.query(`CREATE FUNCTION pg_temp.reject_survey_delete() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN IF OLD.title='fail' THEN RAISE EXCEPTION 'simulated delete failure'; END IF; RETURN OLD; END $$;
      CREATE TRIGGER survey_delete_failure BEFORE DELETE ON education_forms
        FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_survey_delete();`);
    assert.equal((await call('DELETE', '/api/education-forms/:id', admin, failure)).code, 500);
    const untouched = (await db.query('SELECT * FROM messages WHERE id=$1', [failureMessage])).rows[0];
    assert.equal(untouched.education_form_id, failure);
    assert.equal(untouched.body, 'סקר חדש');
    assert.equal(untouched.deleted_for_everyone, false);
    assert.equal(events.length, 0);

    assert.equal((await call('DELETE', '/api/education-forms/:id', otherAdmin, survey)).code, 200);
    assert.equal((await db.query('SELECT * FROM education_forms WHERE id=$1', [survey])).rowCount, 0);
    for (const table of ['education_form_recipients', 'education_form_responses', 'education_form_revisions',
      'education_form_reminders', 'education_response_change_requests'])
      assert.equal((await db.query(`SELECT * FROM ${table} WHERE form_id=$1`, [survey])).rowCount, 0);
    const messages = (await db.query('SELECT * FROM messages WHERE id=ANY($1::uuid[])', [[announcement, republished]])).rows;
    assert.equal(messages.length, 2);
    assert(messages.every(message => message.deleted_for_everyone && message.body === null && message.education_form_id === null));
    assert.equal((await db.query('SELECT reply_to_id FROM messages WHERE id=$1', [reply])).rows[0].reply_to_id, announcement);
    assert.equal((await db.query('SELECT * FROM message_status')).rowCount, 1);
    assert.equal(events.filter(event => event.name === 'message:deleted').length, 2);
    assert.equal(events.at(-1).data.action, 'deleted');
    assert(queries.includes('ROLLBACK'));
  } finally { await db.end(); }
});
