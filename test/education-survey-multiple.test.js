const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const selection = require('../server/education-survey-questions');
const { registerEducationFormEditing } = require('../server/education-form-edit');
const { SCHEMA, registerEducationSurveyManagement } = require('../server/education-survey-management');

const questions = [
  { text: 'מתי?', options: ['בוקר', 'ערב'] },
  { text: 'מה נביא?', options: ['פירות', 'שתייה', 'עוגה'], allowMultiple: true },
];

test('survey answers use strings for one choice and unique ordered arrays for multiple choices', () => {
  assert.deepEqual(selection.normalizeSurveyAnswers(questions,
    { 0: 'בוקר', 1: ['עוגה', 'פירות'], unknown: 'לא לשמור' }),
  { 0: 'בוקר', 1: ['פירות', 'עוגה'] });
  assert.deepEqual(selection.normalizeSurveyAnswers(questions,
    { 0: 'בוקר', 1: 'פירות' }), { 0: 'בוקר', 1: ['פירות'] });
  assert.deepEqual(selection.normalizeSurveyAnswers([{ ...questions[0], allowMultiple: false }],
    { 0: 'ערב' }), { 0: 'ערב' });
  assert.deepEqual(selection.normalizeSurveyAnswers([
    { text: 'סקר ישן', options: ['בוקר', 'בוקר', 'ערב'], allowMultiple: true },
  ], { 0: ['ערב', 'בוקר'] }), { 0: ['בוקר', 'ערב'] });
  for (const answers of invalidAnswers())
    assert.throws(() => selection.normalizeSurveyAnswers(questions, answers));
});

function invalidAnswers() {
  return [null, [], { 0: ['בוקר'], 1: ['פירות'] }, { 0: 'לא קיים', 1: ['פירות'] },
    { 0: 'בוקר', 1: 'לא קיים' }, { 0: 'בוקר', 1: '' }, { 0: 'בוקר', 1: [] },
    { 0: 'בוקר', 1: ['פירות', 'פירות'] }, { 0: 'בוקר', 1: ['לא קיים'] },
    { 0: 'בוקר', 1: [1] }, { 0: 'בוקר', 1: [{ text: 'פירות' }] },
    { 0: 'בוקר', 1: ['פירות', 'שתייה', 'עוגה', 'פירות'] },
    { 0: 'בוקר' }, { 1: ['פירות'] }, {}];
}

test('actual survey handlers persist modes, validate mixed answers and archive changes in temporary PostgreSQL tables',
  { skip: process.env.EDUCATION_TEST_DB !== '1' }, async () => {
  require('dotenv').config({ quiet: true });
  const { Client } = require('pg');
  const db = new Client({ connectionString: process.env.DATABASE_URL,
    ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' } : false });
  await db.connect();
  try {
    await db.query('SET search_path TO pg_temp, public');
    await db.query(`CREATE TEMP TABLE groups(id uuid PRIMARY KEY,name text,send_permission text DEFAULT 'all');
      CREATE TEMP TABLE users(id uuid PRIMARY KEY,name text);
      CREATE TEMP TABLE group_members(group_id uuid,user_id uuid,role text,status text);
      CREATE TEMP TABLE education_forms(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),group_id uuid,
        created_by uuid,form_type text,title text,description text,file_url text,file_name text,
        questions jsonb,anonymous boolean,due_at timestamptz,status text DEFAULT 'open',
        created_at timestamptz DEFAULT now(),updated_at timestamptz DEFAULT now());
      CREATE TEMP TABLE education_form_recipients(form_id uuid,user_id uuid,notified_at timestamptz,
        PRIMARY KEY(form_id,user_id));
      CREATE TEMP TABLE education_form_responses(form_id uuid,user_id uuid,response_status text,answers jsonb,
        signer_name text,signature_data jsonb,document_version text,submitted_at timestamptz DEFAULT now(),
        PRIMARY KEY(form_id,user_id));
      CREATE TEMP TABLE education_response_change_requests(form_id uuid,user_id uuid,status text);
      CREATE TEMP TABLE education_form_revisions(id uuid DEFAULT gen_random_uuid(),form_id uuid,edited_by uuid,
        snapshot jsonb,responses jsonb,created_at timestamptz DEFAULT now());
      CREATE TEMP TABLE messages(id uuid DEFAULT gen_random_uuid(),sender_id uuid,group_id uuid,body text,
        type text,education_form_id uuid,created_at timestamptz DEFAULT now());`);
    await db.query(SCHEMA.replace('CREATE TABLE IF NOT EXISTS education_survey_drafts',
      'CREATE TEMP TABLE education_survey_drafts'));
    const [group, admin, active, pending] = Array.from({ length: 4 }, () => crypto.randomUUID());
    await db.query('INSERT INTO groups(id,name) VALUES($1,$2)', [group, 'בדיקת בחירות']);
    for (const [id, role, status] of [[admin, 'admin', 'member'], [active, 'member', 'member'], [pending, 'admin', 'pending']]) {
      await db.query('INSERT INTO users VALUES($1,$2)', [id, 'שם בדיקה']);
      await db.query('INSERT INTO group_members VALUES($1,$2,$3,$4)', [group, id, role, status]);
    }
    const handlers = new Map(), pushes = [], events = [];
    const app = Object.fromEntries(['get', 'post', 'put', 'delete'].map(method => [method,
      (route, ...middleware) => handlers.set(`${method.toUpperCase()} ${route}`, middleware.at(-1))]));
    const pool = { query: db.query.bind(db), connect: async () => ({ query: db.query.bind(db), release() {} }) };
    const io = { to: room => ({ emit: (name, body) => events.push({ room, name, body }) }) };
    const dependencies = { auth() {}, getPool: async () => pool, io, sendPush: (...args) => pushes.push(args) };
    const source = fs.readFileSync(path.join(__dirname, '../server/index.js'), 'utf8');
    for (const [begin, end] of [
      ["app.post('/api/groups/:id/education-forms'", "app.get('/api/education-forms/:id'"],
      ["app.post('/api/education-forms/:id/respond'", "app.post('/api/education-forms/:id/remind'"],
    ]) {
      const start = source.indexOf(begin);
      assert(start >= 0);
      vm.runInNewContext(source.slice(start, source.indexOf(end, start)), {
        app, ...dependencies, ...selection, crypto, console, logActivity() {}, messageRateLimit() {},
        denyTeenEducation: require('../server/education-form-policy').denyTeenEducation,
        educationFormPolicy: { canSend: async () => true, validateContent: async () => {} },
      });
    }
    registerEducationFormEditing(app, dependencies);
    registerEducationSurveyManagement(app, dependencies);
    async function call(method, route, user, id, body = {}) {
      const res = { code: 200, status(value) { this.code = value; return this; },
        json(value) { this.body = value; return this; } };
      await handlers.get(`${method} ${route}`)({ params: { id }, user: { id: user, name: 'בדיקה' },
        body, app: { get: () => io } }, res);
      return res;
    }
    const create = body => call('POST', '/api/groups/:id/education-forms', admin, group,
      { formType: 'survey', title: 'סקר בחירות', questions, ...body });
    for (const allowMultiple of [null, 'true', 1, [], {}]) {
      const bad = await create({ questions: [{ ...questions[0], allowMultiple }] });
      assert.equal(bad.code, 400);
    }
    assert.equal((await db.query('SELECT * FROM education_forms')).rowCount, 0);
    const created = await create({ questions: [{ ...questions[0], allowMultiple: false }, questions[1]] });
    assert.equal(created.code, 201, JSON.stringify(created.body));
    assert.deepEqual(created.body.questions, questions);
    const form = created.body;
    assert.deepEqual((await db.query('SELECT questions FROM education_forms WHERE id=$1', [form.id])).rows[0].questions, questions);
    assert.equal((await db.query('SELECT * FROM education_form_recipients WHERE form_id=$1', [form.id])).rowCount, 3);
    assert.equal(pushes.length, 1);
    assert.equal(pushes[0][0], active);
    const responseBody = { status: 'completed', expectedUpdatedAt: form.updated_at,
      answers: { 0: 'בוקר', 1: ['עוגה', 'פירות'], extra: 'לא נשמר' } };
    assert.equal((await call('POST', '/api/education-forms/:id/respond', pending, form.id, responseBody)).code, 404);
    const eventCount = events.length;
    for (const answers of invalidAnswers())
      assert.equal((await call('POST', '/api/education-forms/:id/respond', active, form.id,
        { ...responseBody, answers })).code, 400);
    assert.equal((await db.query('SELECT * FROM education_form_responses')).rowCount, 0);
    assert.equal(events.length, eventCount);
    assert.equal((await call('POST', '/api/education-forms/:id/respond', active, form.id, responseBody)).code, 200);
    assert.deepEqual((await db.query('SELECT answers FROM education_form_responses')).rows[0].answers,
      { 0: 'בוקר', 1: ['פירות', 'עוגה'] });
    assert.equal((await call('POST', '/api/education-forms/:id/respond', active, form.id, responseBody)).code, 409);
    assert.equal(events.length, eventCount + 1);

    const unchanged = await call('PUT', '/api/education-forms/:id', admin, form.id,
      { title: form.title, anonymous: false, expectedUpdatedAt: form.updated_at,
        questions: [{ ...questions[0], allowMultiple: false }, questions[1]] });
    assert.equal(unchanged.code, 200, JSON.stringify(unchanged.body));
    assert.equal(unchanged.body.answersReset, false);
    assert.equal((await db.query('SELECT * FROM education_form_responses')).rowCount, 1);
    assert.equal(pushes.length, 1);
    const changedQuestions = [questions[0], { ...questions[1], allowMultiple: false }];
    const changed = await call('PUT', '/api/education-forms/:id', admin, form.id,
      { title: form.title, expectedUpdatedAt: unchanged.body.updated_at, questions: changedQuestions });
    assert.equal(changed.code, 200, JSON.stringify(changed.body));
    assert.equal(changed.body.answersReset, true);
    assert.equal((await db.query('SELECT * FROM education_form_responses')).rowCount, 0);
    const archived = (await db.query('SELECT * FROM education_form_revisions WHERE snapshot->>\'updated_at\'=$1',
      [unchanged.body.updated_at.toISOString()])).rows[0];
    assert(archived, 'The previous answered version was archived');
    assert.deepEqual(archived.snapshot.questions, questions);
    assert.deepEqual(archived.responses[0].answers, { 0: 'בוקר', 1: ['פירות', 'עוגה'] });
    assert.equal(pushes.length, 3);
    assert(pushes.every(push => push[0] !== pending), 'Pending invitees never receive form content pushes');
    assert(pushes.slice(1).some(push => push[0] === admin), 'A participating creator receives updates like other active recipients');
    assert.equal((await db.query('SELECT * FROM messages WHERE education_form_id=$1', [form.id])).rowCount, 1);
    assert.equal((await db.query('SELECT * FROM education_form_recipients WHERE form_id=$1', [form.id])).rowCount, 3);
    assert.equal((await call('POST', '/api/education-forms/:id/respond', active, form.id, responseBody)).code, 409);
    assert.equal((await call('POST', '/api/education-forms/:id/respond', pending, form.id,
      { ...responseBody, expectedUpdatedAt: changed.body.updated_at })).code, 404);
    await db.query("UPDATE group_members SET status='member' WHERE user_id=$1", [pending]);
    assert.equal((await call('POST', '/api/education-forms/:id/respond', pending, form.id,
      { ...responseBody, expectedUpdatedAt: changed.body.updated_at, answers: { 0: 'ערב', 1: 'שתייה' } })).code, 200);

    const draftBody = { title: 'טיוטה', questions: [{ text: '', options: ['', ''], allowMultiple: true }, questions[0]] };
    const draft = await call('POST', '/api/groups/:id/education-survey-drafts', admin, group, draftBody);
    assert.equal(draft.code, 201);
    assert.deepEqual(draft.body.questions, draftBody.questions);
    const loaded = await call('GET', '/api/groups/:id/education-survey-drafts', admin, group);
    assert.deepEqual(loaded.body.drafts[0].questions, draftBody.questions);
    const savedDraft = await call('PUT', '/api/education-survey-drafts/:id', admin, draft.body.id,
      { ...draftBody, questions: [{ ...draftBody.questions[0], allowMultiple: false }, questions[1]] });
    assert.equal(savedDraft.code, 200);
    assert.deepEqual(savedDraft.body.questions, [{ text: '', options: ['', ''] }, questions[1]]);
    for (const allowMultiple of [null, 'true', 1, [], {}]) {
      const badDraft = { ...draftBody, questions: [{ ...questions[0], allowMultiple }] };
      assert.equal((await call('POST', '/api/groups/:id/education-survey-drafts', admin, group, badDraft)).code, 400);
      assert.equal((await call('PUT', '/api/education-survey-drafts/:id', admin, draft.body.id, badDraft)).code, 400);
      assert.equal((await call('PUT', '/api/education-forms/:id', admin, form.id,
        { ...badDraft, title: form.title, expectedUpdatedAt: changed.body.updated_at })).code, 400);
    }
    const compatible = await create({ title: 'תשובה מלקוח קודם' });
    assert.equal(compatible.code, 201);
    assert.equal((await call('POST', '/api/education-forms/:id/respond', active, compatible.body.id,
      { status: 'completed', expectedUpdatedAt: compatible.body.updated_at,
        answers: { 0: 'ערב', 1: 'שתייה' } })).code, 200);
    assert.deepEqual((await db.query('SELECT answers FROM education_form_responses WHERE form_id=$1 AND user_id=$2',
      [compatible.body.id, active])).rows[0].answers, { 0: 'ערב', 1: ['שתייה'] });
    const legacy = await create({ title: 'סקר רגיל', questions: [questions[0]] });
    assert.equal(legacy.code, 201);
    assert.deepEqual(legacy.body.questions, [questions[0]]);
    const legacyAnswer = { status: 'completed', expectedUpdatedAt: legacy.body.updated_at, answers: { 0: ['בוקר'] } };
    assert.equal((await call('POST', '/api/education-forms/:id/respond', active, legacy.body.id, legacyAnswer)).code, 400);
    assert.equal((await call('POST', '/api/education-forms/:id/respond', active, legacy.body.id,
      { ...legacyAnswer, answers: { 0: 'בוקר' } })).code, 200);
  } finally { await db.end(); }
});
