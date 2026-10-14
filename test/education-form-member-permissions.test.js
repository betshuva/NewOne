const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { createEducationFormPolicy, denyTeenEducation } = require('../server/education-form-policy');
const { DEFAULT_CONTENT_FILTER, contentAllowedByFilter } = require('../server/content-filter-policy');
const { registerEducationFormEditing } = require('../server/education-form-edit');
const { SCHEMA, registerEducationSurveyManagement } = require('../server/education-survey-management');
const source = fs.readFileSync(path.join(__dirname, '../server/index.js'), 'utf8');
const question = { text: 'מתי?', options: ['בוקר', 'ערב'] };

test('education publication applies text, link, approved-file and destination-filter checks', async () => {
  const checks = [];
  let filter = { ...DEFAULT_CONTENT_FILTER }, approved = true;
  const policy = createEducationFormPolicy({
    moderateChatText: text => ({ blocked: text.includes('אסור') }),
    recordBlockedChat: (...args) => checks.push(['blocked', ...args]), clientIp: () => 'local',
    verifyMessageLinks: async text => { if (text.includes('unsafe.example')) throw new Error('unsafe'); },
    linkBlockedMessage: 'קישור חסום', getGroupContentFilter: async () => filter,
    contentAllowedByFilter: (policy, type, classification) => policy.text === false && type === 'text'
      ? false : contentAllowedByFilter(policy, type, classification),
    getStoredImageClassification: async () => ({ detectedCategories: ['women'] }),
    validateApprovedFile: async () => approved,
  });
  const pool = { query: async () => ({ rows: [{ file_type: 'document' }] }) };
  const req = { user: { id: 'sender' } };
  for (const body of [{ title: 'אסור' }, { title: 'סקר', description: 'אסור' },
    { title: 'סקר', questions: [{ text: 'מתי?', options: ['בוקר', 'אסור'] }] }])
    await assert.rejects(policy.validateContent(req, pool, 'group', body), { status: 422, code: 'CHAT_CONTENT_BLOCKED' });
  assert.equal(checks.length, 3);
  await assert.rejects(policy.validateContent(req, pool, 'group', { title: 'unsafe.example' }), { status: 422, code: 'UNSAFE_LINK' });
  assert.equal(await policy.canSend(pool, 'group', { role: 'member', send_permission: 'admin' }), false);
  assert.equal(await policy.canSend(pool, 'group', { role: 'admin', send_permission: 'admin' }), true);
  filter.text = false;
  assert.equal(await policy.canSend(pool, 'group', { role: 'member', send_permission: 'all' }), false);
  await assert.rejects(policy.validateContent(req, pool, 'group', { title: 'סקר' }), { status: 403, code: 'GROUP_CONTENT_FILTERED' });
  filter = null;
  assert.equal(await policy.canSend(pool, 'group', { role: 'member', send_permission: 'all' }), false);
  await assert.rejects(policy.validateContent(req, pool, 'group', { title: 'סקר' }), { status: 403, code: 'GROUP_CONTENT_FILTERED' });
  filter = { ...DEFAULT_CONTENT_FILTER };
  approved = false;
  await assert.rejects(policy.validateContent(req, pool, 'group', { title: 'אישור', file_url: 'private' }), { status: 403 });
  approved = true;
  filter.women = false;
  await assert.rejects(policy.validateContent(req, pool, 'group', { title: 'אישור', file_url: 'file' }), { status: 403, code: 'GROUP_CONTENT_FILTERED' });
});

test('active senders create and manage only their own forms while admin, privacy and invitation gates remain intact',
  { skip: process.env.EDUCATION_TEST_DB !== '1' }, async () => {
  require('dotenv').config({ quiet: true });
  const { Client } = require('pg');
  const db = new Client({ connectionString: process.env.DATABASE_URL,
    ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' } : false });
  await db.connect();
  try {
    await db.query('SET search_path TO pg_temp, public');
    await db.query(`CREATE TEMP TABLE groups(id uuid PRIMARY KEY,name text,send_permission text DEFAULT 'all',content_filter jsonb);
      CREATE TEMP TABLE users(id uuid PRIMARY KEY,name text);
      CREATE TEMP TABLE group_members(group_id uuid,user_id uuid,role text,status text);
      CREATE TEMP TABLE education_forms(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),group_id uuid,
        created_by uuid,form_type text,title text,description text,file_url text,file_name text,
        questions jsonb,anonymous boolean,due_at timestamptz,status text DEFAULT 'open',
        created_at timestamptz DEFAULT now(),updated_at timestamptz DEFAULT now());
      CREATE TEMP TABLE education_form_recipients(form_id uuid REFERENCES education_forms(id) ON DELETE CASCADE,user_id uuid,notified_at timestamptz,
        PRIMARY KEY(form_id,user_id));
      CREATE TEMP TABLE education_form_responses(form_id uuid REFERENCES education_forms(id) ON DELETE CASCADE,user_id uuid,response_status text,answers jsonb,
        signer_name text,signature_data jsonb,document_version text,submitted_at timestamptz DEFAULT now(), PRIMARY KEY(form_id,user_id));
      CREATE TEMP TABLE education_response_change_requests(form_id uuid REFERENCES education_forms(id) ON DELETE CASCADE,user_id uuid,status text,
        requested_at timestamptz,decided_at timestamptz,decided_by uuid,PRIMARY KEY(form_id,user_id));
      CREATE TEMP TABLE education_form_revisions(id uuid DEFAULT gen_random_uuid(),form_id uuid REFERENCES education_forms(id) ON DELETE CASCADE,
        edited_by uuid,snapshot jsonb,responses jsonb,created_at timestamptz DEFAULT now());
      CREATE TEMP TABLE education_form_reminders(form_id uuid REFERENCES education_forms(id) ON DELETE CASCADE,sent_by uuid,recipient_id uuid,sent_at timestamptz DEFAULT now());
      CREATE TEMP TABLE stored_files(id uuid DEFAULT gen_random_uuid(),public_url text,file_type text,user_id uuid,
        context_type text,context_id uuid,moderation_status text,content_purged_at timestamptz,moderation_details jsonb);
      CREATE TEMP TABLE shared_gifs(stored_file_id uuid,status text);
      CREATE TEMP TABLE messages(id uuid DEFAULT gen_random_uuid(),sender_id uuid,recipient_id uuid,group_id uuid,body text,type text,
        education_form_id uuid REFERENCES education_forms(id) ON DELETE SET NULL,created_at timestamptz DEFAULT now(),
        file_url text,file_name text,deleted_for_everyone boolean DEFAULT false);`);
    await db.query(SCHEMA.replace('CREATE TABLE IF NOT EXISTS education_survey_drafts', 'CREATE TEMP TABLE education_survey_drafts'));
    const [group, admin, owner, other, pending, removed, outsider, privateOwner] = Array.from({ length: 8 }, () => crypto.randomUUID());
    await db.query('INSERT INTO groups(id,name,content_filter) VALUES($1,$2,$3)', [group, 'בדיקת הרשאות', DEFAULT_CONTENT_FILTER]);
    for (const [id, role, status] of [[admin, 'admin', 'member'], [owner, 'member', 'member'], [other, 'member', 'member'],
      [pending, 'admin', 'pending'], [removed, 'admin', 'removed'], [outsider, null, null], [privateOwner, null, null]]) {
      await db.query('INSERT INTO users VALUES($1,$2)', [id, id === pending ? 'שם מוזמן חסוי' : 'שם בדיקה']);
      if (role) await db.query('INSERT INTO group_members VALUES($1,$2,$3,$4)', [group, id, role, status]);
    }
    for (const [url, userId, context, status] of [['own-file', owner, group, 'approved'], ['private-file', privateOwner, outsider, 'approved'],
      ['rejected-file', owner, group, 'rejected'], ['image-file', owner, group, 'approved']])
      await db.query(`INSERT INTO stored_files(public_url,file_type,user_id,context_type,context_id,moderation_status,moderation_details)
        VALUES($1,$2,$3,'group',$4,$5,$6)`, [url, url === 'image-file' ? 'image' : 'document', userId, context, status,
        url === 'image-file' ? { classification: { detectedCategories: ['women'] } } : {}]);
    const handlers = new Map(), stacks = new Map(), pushes = [], events = [];
    const messageRateLimit = () => {};
    const app = Object.fromEntries(['get', 'post', 'put', 'delete'].map(method => [method,
      (route, ...middleware) => {
        handlers.set(`${method.toUpperCase()} ${route}`, middleware.at(-1));
        stacks.set(`${method.toUpperCase()} ${route}`, middleware);
      }]));
    const pool = { query: db.query.bind(db), connect: async () => ({ query: db.query.bind(db), release() {} }) };
    const io = { to: room => ({ emit: (name, body) => events.push({ room, name, body }) }) };
    const fileStart = source.indexOf('async function validateApprovedFile(');
    const fileCheck = vm.runInNewContext(source.slice(fileStart, source.indexOf('async function assertSenderFileAllowed(', fileStart)) +
      '; validateApprovedFile', { assertSenderFileAllowed: async () => {} });
    const educationFormPolicy = createEducationFormPolicy({
      moderateChatText: text => ({ blocked: text.includes('אסור') }), recordBlockedChat() {}, clientIp: () => 'local',
      verifyMessageLinks: async text => { if (text.includes('unsafe.example')) throw new Error('unsafe'); },
      linkBlockedMessage: 'קישור חסום', contentAllowedByFilter,
      getGroupContentFilter: async (client, id) => (await client.query('SELECT content_filter FROM groups WHERE id=$1', [id])).rows[0]?.content_filter,
      getStoredImageClassification: async (client, url) => (await client.query('SELECT moderation_details FROM stored_files WHERE public_url=$1', [url])).rows[0]?.moderation_details?.classification,
      validateApprovedFile: fileCheck,
    });
    const dependencies = { auth() {}, getPool: async () => pool, io, sendPush: (...args) => pushes.push(args), ...educationFormPolicy };
    const start = source.indexOf("app.get('/api/groups/:id/education-forms'");
    vm.runInNewContext(source.slice(start, source.indexOf('// ── Groups: invite a registered user', start)), {
      app, ...dependencies, ...require('../server/education-survey-questions'), denyTeenEducation, educationFormPolicy, crypto, console, logActivity() {}, messageRateLimit,
    });
    registerEducationFormEditing(app, dependencies);
    registerEducationSurveyManagement(app, dependencies);
    for (const route of ['/api/groups/:id/education-forms', '/api/education-forms/:id/assign-new-members', '/api/education-forms/:id/republish'])
      assert(stacks.get(`POST ${route}`).includes(messageRateLimit), 'Publications share the ordinary message rate limit');
    async function call(method, route, user, id, body = {}, extraParams = {}, isTeen = false) {
      const res = { code: 200, status(value) { this.code = value; return this; }, json(value) { this.body = value; return this; } };
      await handlers.get(`${method} ${route}`)({ params: { id, ...extraParams }, user: { id: user, name: 'שם בדיקה', isTeen },
        body, app: { get: () => io } }, res);
      return res;
    }
    const create = (user, body = {}) => call('POST', '/api/groups/:id/education-forms', user, group,
      { formType: 'survey', title: 'סקר חבר', questions: [question], ...body });
    for (const user of [pending, removed, outsider]) assert.equal((await create(user)).code, 403);
    assert.equal((await call('POST', '/api/groups/:id/education-forms', owner, group,
      { formType: 'survey', title: 'נוער', questions: [question] }, {}, true)).code, 403);
    for (const body of [{ title: 'אסור' }, { description: 'unsafe.example' },
      { questions: [{ ...question, options: ['בוקר', 'אסור'] }] }]) assert.equal((await create(owner, body)).code, 422);
    assert.equal((await create(owner, { formType: 'signature', fileUrl: 'private-file' })).code, 403);
    assert.equal((await create(owner, { formType: 'signature', fileUrl: 'rejected-file' })).code, 403);
    const created = await create(owner, { anonymous: true });
    assert.equal(created.code, 201, JSON.stringify(created.body));
    const form = created.body;
    assert.equal(form.created_by, owner);
    assert.equal(form.canManage, true);
    assert.equal(form.isRecipient, true);
    assert.equal(form.canRespond, true);
    const signatureForm = await create(owner, { formType: 'signature', title: 'חתימה', fileUrl: 'own-file' });
    assert.equal(signatureForm.code, 201);
    const signature = [{x:10,y:10},{x:20,y:20}];
    await db.query(`INSERT INTO education_form_responses(form_id,user_id,response_status,signer_name,signature_data)
      VALUES($1,$2,'approved','חותם',$3)`, [signatureForm.body.id,owner,JSON.stringify(signature)]);
    const signedDetails = await call('GET','/api/education-forms/:id',owner,signatureForm.body.id);
    assert.equal(signedDetails.code,200,JSON.stringify(signedDetails.body));
    assert.deepEqual(signedDetails.body.participants.find(p=>p.id===owner).signature_data,signature);
    const recipientDetails = await call('GET','/api/education-forms/:id',other,signatureForm.body.id);
    assert.equal(recipientDetails.code,200);
    assert.equal(recipientDetails.body.participants,null);

    assert.equal((await create(owner, { formType: 'approval', title: 'אישור' })).code, 201);
    assert(!pushes.some(push => push[0] === pending));
    assert(!pushes.some(push => push[0] === owner), 'Publishing includes the sender without notifying them of their own action');
    const recipients = (await db.query('SELECT user_id FROM education_form_recipients WHERE form_id=$1', [form.id])).rows.map(row => row.user_id);
    assert(recipients.includes(pending) && recipients.includes(other) && recipients.includes(admin) && recipients.includes(owner));
    const list = await call('GET', '/api/groups/:id/education-forms', owner, group);
    assert.equal(list.body.isAdmin, false);
    assert.equal(list.body.canCreate, true);
    assert(list.body.forms.every(item => item.canManage && item.isCreator && item.isRecipient && item.canRespond));
    const details = await call('GET', '/api/education-forms/:id', owner, form.id);
    assert.equal(details.code, 200, JSON.stringify(details.body));
    assert.equal(details.body.form.my_role, 'member');
    assert.equal(details.body.form.canManage, true);
    assert.equal(details.body.form.isRecipient, true);
    assert.equal(details.body.form.pending_recipient_count, 1);
    assert.equal(details.body.form.expected_count, 4);
    assert(!details.body.participants.some(participant => participant.id === pending));
    const otherDetails = await call('GET', '/api/education-forms/:id', other, form.id);
    assert.equal(otherDetails.body.form.canManage, false);
    assert.equal(otherDetails.body.participants, null);
    assert.equal(otherDetails.body.results, null);
    assert.equal((await call('GET', '/api/education-forms/:id', pending, form.id)).code, 404);
    assert((await call('GET', '/api/education-forms/:id', admin, form.id)).body.participants.some(participant => participant.id === pending));
    const announcement = events.find(event => event.name === 'group:message' && event.body.formId === form.id).body;
    assert.equal(announcement.text, `📋 סקר: ${form.title}`);
    assert.equal(announcement.educationFormTitle, form.title);
    assert.equal(announcement.educationFormType, 'survey');
    assert.equal(announcement.educationFormCreatorId, owner);
    assert.equal(announcement.educationFormStatus, 'open');
    assert.equal(new Date(announcement.educationFormCreatedAt).getTime(), new Date(form.created_at).getTime());
    assert(!Object.hasOwn(announcement, 'recipientIds'), 'Recipient selections remain private to the form APIs');
    for (const formType of ['survey', 'approval', 'signature']) {
      const formBody = { formType, title: `השתתפות שולח ${formType}`,
        ...(formType === 'signature' ? { fileUrl: 'own-file', fileName: 'מסמך.pdf' } : {}),
        anonymous: formType === 'survey' };
      const defaultSelf = await create(owner, formBody);
      assert.equal(defaultSelf.code, 201, JSON.stringify(defaultSelf.body));
      assert.equal(defaultSelf.body.isRecipient, true, formType);
      const selfAnswer = { status: formType === 'survey' ? 'completed' : 'approved',
        answers: { 0: 'בוקר' }, signerName: 'שם השולח', signatureData: [{ x: 1, y: 1 }, { x: 2, y: 2 }],
        expectedUpdatedAt: defaultSelf.body.updated_at };
      assert.equal((await call('POST', '/api/education-forms/:id/respond', owner, defaultSelf.body.id, selfAnswer)).code, 200, formType);
      const selfDetails = await call('GET', '/api/education-forms/:id', owner, defaultSelf.body.id);
      assert.equal(selfDetails.body.form.my_response_status, selfAnswer.status, formType);
      assert.equal(selfDetails.body.form.response_count, 1, formType);
      assert.equal(selfDetails.body.form.expected_count, 4, formType);
      if (formType === 'survey') {
        assert.deepEqual(selfDetails.body.form.my_answers, { 0: 'בוקר' });
        assert.deepEqual(selfDetails.body.results, [{ answers: { 0: 'בוקר' } }]);
        assert(selfDetails.body.participants.every(participant => participant.answers === null && participant.signer_name === null && participant.submitted_at === null));
      }
      const explicitSelf = await create(owner, { ...formBody, recipientIds: [owner] });
      assert.equal(explicitSelf.code, 201, formType);
      assert.equal(explicitSelf.body.isRecipient, true, formType);
      assert.equal((await call('POST', '/api/education-forms/:id/respond', owner, explicitSelf.body.id,
        { ...selfAnswer, expectedUpdatedAt: explicitSelf.body.updated_at })).code, 200, formType);
      const optedOut = await create(owner, { ...formBody, recipientIds: [other] });
      assert.equal(optedOut.code, 201, formType);
      assert.equal(optedOut.body.isRecipient, false, formType);
      assert.equal(optedOut.body.canRespond, false, formType);
      assert.equal(optedOut.body.canManage, true, formType);
      for (const user of [owner, admin]) {
        const managerDetails = await call('GET', '/api/education-forms/:id', user, optedOut.body.id);
        assert.equal(managerDetails.body.form.canManage, true, formType);
        assert.equal(managerDetails.body.form.isRecipient, false, formType);
        assert.equal((await call('POST', '/api/education-forms/:id/respond', user, optedOut.body.id,
          { ...selfAnswer, expectedUpdatedAt: optedOut.body.updated_at })).code, 404,
        'Managing a form does not enroll the manager as a participant');
      }
      const optedOutList = await call('GET', '/api/groups/:id/education-forms', owner, group);
      assert.equal(optedOutList.body.forms.find(item => item.id === optedOut.body.id).isRecipient, false);
      assert.equal((await call('POST', '/api/education-forms/:id/republish', admin, optedOut.body.id)).code, 200);
      const managerAnnouncement = events.filter(event => event.name === 'group:message' && event.body.formId === optedOut.body.id).at(-1).body;
      assert.equal(managerAnnouncement.fromUserId, admin);
      assert.equal(managerAnnouncement.educationFormCreatorId, owner,
        'An announcement sent by another admin must preserve its opted-out creator for management');
      assert.equal((await call('GET', '/api/education-forms/:id', owner, optedOut.body.id)).body.form.new_member_count, 3,
        'An unassigned creator can be selected later alongside unassigned members');
      assert.equal((await call('POST', '/api/education-forms/:id/remind', owner, optedOut.body.id, { userIds: [owner] })).body.sent, 0);
      assert.equal((await call('POST', '/api/education-forms/:id/assign-new-members', owner, optedOut.body.id,
        { recipientIds: [owner] })).body.sent, 1, formType);
      assert.equal((await call('POST', '/api/education-forms/:id/assign-new-members', owner, optedOut.body.id,
        { recipientIds: [owner] })).body.sent, 0, 'Assigning the sender twice cannot duplicate the recipient');
      assert.equal((await call('POST', '/api/education-forms/:id/remind', owner, optedOut.body.id, { userIds: [owner] })).body.sent, 1,
        'A participating sender receives ordinary pending-response reminders');
      assert.equal((await call('GET', '/api/education-forms/:id', owner, optedOut.body.id)).body.form.isRecipient, true);
      assert.equal((await call('POST', '/api/education-forms/:id/respond', owner, optedOut.body.id,
        { ...selfAnswer, expectedUpdatedAt: optedOut.body.updated_at })).code, 200, formType);
      assert.equal((await call('POST', '/api/education-forms/:id/remind', owner, optedOut.body.id, { userIds: [owner] })).body.sent, 0);
    }
    const answer = { status: 'completed', answers: { 0: 'בוקר' }, expectedUpdatedAt: form.updated_at };
    assert.equal((await call('POST', '/api/education-forms/:id/respond', other, form.id, answer)).code, 200);
    const ownerResults = await call('GET', '/api/education-forms/:id', owner, form.id);
    assert.deepEqual(ownerResults.body.results, [{ answers: { 0: 'בוקר' } }]);
    assert(ownerResults.body.participants.every(participant => participant.answers === null));
    assert(ownerResults.body.participants.every(participant => participant.submitted_at === null && participant.signer_name === null));
    assert.equal(ownerResults.body.form.response_count, 1);
    const beforeRequest = pushes.length;
    assert.equal((await call('POST', '/api/education-forms/:id/change-request', other, form.id)).code, 200);
    const notifiedManagers = pushes.slice(beforeRequest).map(push => push[0]);
    assert(notifiedManagers.includes(owner) && notifiedManagers.includes(admin));
    assert(!notifiedManagers.includes(pending));
    assert.equal((await call('POST', '/api/education-forms/:id/change-request/:userId/decision', other, form.id,
      { decision: 'approved' }, { userId: other })).code, 403);
    assert.equal((await call('POST', '/api/education-forms/:id/change-request/:userId/decision', owner, form.id,
      { decision: 'rejected' }, { userId: other })).code, 200);
    for (const [method, route, body] of [['PUT', '/api/education-forms/:id', { title: 'עריכה', questions: [question], expectedUpdatedAt: form.updated_at }],
      ['PUT', '/api/education-forms/:id/status', { status: 'closed' }], ['POST', '/api/education-forms/:id/remind', {}],
      ['POST', '/api/education-forms/:id/republish', {}], ['POST', '/api/education-forms/:id/assign-new-members', {}],
      ['DELETE', '/api/education-forms/:id', {}]])
      assert.equal((await call(method, route, other, form.id, body)).code, 403, route);
    const edited = await call('PUT', '/api/education-forms/:id', owner, form.id,
      { title: 'סקר מעודכן', anonymous: true, questions: [question], expectedUpdatedAt: form.updated_at });
    assert.equal(edited.code, 200, JSON.stringify(edited.body));
    const revision = (await db.query('SELECT id FROM education_form_revisions WHERE form_id=$1', [form.id])).rows[0];
    assert.equal((await call('GET', '/api/education-forms/:id/revisions/:revisionId', other, form.id, {}, { revisionId: revision.id })).code, 404);
    const history = await call('GET', '/api/education-forms/:id/revisions/:revisionId', owner, form.id, {}, { revisionId: revision.id });
    assert.equal(history.code, 200);
    assert.deepEqual(Object.keys(history.body.responses[0]).sort(), ['answers', 'response_status']);
    await db.query("UPDATE group_members SET status='pending' WHERE user_id=$1", [other]);
    await db.query("UPDATE education_form_revisions SET snapshot=snapshot||'{\"anonymous\":false}'::jsonb WHERE id=$1", [revision.id]);
    const hiddenHistory = await call('GET', '/api/education-forms/:id/revisions/:revisionId', owner, form.id, {}, { revisionId: revision.id });
    assert.equal(hiddenHistory.body.responses[0].name, '');
    await db.query("UPDATE group_members SET status='member' WHERE user_id=$1", [other]);
    assert.equal((await call('POST', '/api/education-forms/:id/remind', owner, form.id)).code, 200);
    assert.equal((await call('POST', '/api/education-forms/:id/republish', owner, form.id)).code, 200);
    const republished = events.filter(event => event.name === 'group:message' && event.body.formId === form.id).at(-1).body;
    assert.equal(republished.educationFormTitle, 'סקר מעודכן');
    assert.equal(republished.educationFormType, 'survey');
    assert.equal(republished.educationFormCreatorId, owner);
    assert.equal(republished.educationFormStatus, 'open');
    const newMember = crypto.randomUUID();
    await db.query('INSERT INTO users VALUES($1,$2)', [newMember, 'חבר נוסף']);
    await db.query("INSERT INTO group_members VALUES($1,$2,'member','pending')", [group, newMember]);
    const beforeAssign = pushes.length;
    assert.equal((await call('POST', '/api/education-forms/:id/assign-new-members', owner, form.id)).body.sent, 1);
    assert.equal(pushes.length, beforeAssign, 'Pending assignment is queued without content notification');
    const assignedMessage = events.filter(event => event.name === 'group:message' && event.body.formId === form.id).at(-1).body;
    assert.equal(assignedMessage.educationFormTitle, 'סקר מעודכן');
    assert.equal(assignedMessage.educationFormType, 'survey');
    assert.equal(assignedMessage.educationFormCreatorId, owner);
    assert.equal((await call('PUT', '/api/education-forms/:id/status', owner, form.id, { status: 'closed' })).code, 200);
    assert.equal((await call('PUT', '/api/education-forms/:id/status', admin, form.id, { status: 'open' })).code, 200);
    const draftBody = { title: 'טיוטת חבר', questions: [question] };
    const draft = await call('POST', '/api/groups/:id/education-survey-drafts', owner, group, draftBody);
    assert.equal(draft.code, 201);
    assert.equal((await call('GET', '/api/groups/:id/education-survey-drafts', owner, group)).body.drafts.length, 1);
    assert.deepEqual((await call('GET', '/api/groups/:id/education-survey-drafts', other, group)).body.drafts, []);
    assert.equal((await call('PUT', '/api/education-survey-drafts/:id', other, draft.body.id, draftBody)).code, 404);
    assert.equal((await call('PUT', '/api/education-survey-drafts/:id', owner, draft.body.id, draftBody)).code, 200);
    await db.query("UPDATE groups SET send_permission='admin' WHERE id=$1", [group]);
    assert.equal((await create(owner)).code, 403);
    assert.equal((await call('GET', '/api/groups/:id/education-forms', owner, group)).body.canCreate, false);
    const locked = await call('GET', '/api/education-forms/:id', owner, form.id);
    assert.equal(locked.body.form.canManage, true);
    assert.equal(locked.body.form.canSend, false);
    for (const route of ['/api/education-forms/:id/remind', '/api/education-forms/:id/republish', '/api/education-forms/:id/assign-new-members'])
      assert.equal((await call('POST', route, owner, form.id)).code, 403);
    const beforeLockedEdit = pushes.length;
    assert.equal((await call('PUT', '/api/education-forms/:id', owner, form.id,
      { title: 'ניהול גם לאחר חסימת השליחה', anonymous: true, questions: [question], expectedUpdatedAt: edited.body.updated_at })).code, 200);
    assert.equal(pushes.length, beforeLockedEdit);
    assert.equal((await call('POST', '/api/groups/:id/education-survey-drafts', owner, group, draftBody)).code, 403);
    assert.equal((await call('DELETE', '/api/education-survey-drafts/:id', owner, draft.body.id)).code, 200);
    assert.equal((await create(admin)).code, 201);
    await db.query("UPDATE groups SET send_permission='all',content_filter=$2 WHERE id=$1", [group, { ...DEFAULT_CONTENT_FILTER, text: false }]);
    assert.equal((await create(owner)).code, 201, 'Text remains allowed by the existing normalized content policy');
    assert.equal((await call('GET', '/api/education-forms/:id', owner, form.id)).body.form.canSend, true);
    await db.query('UPDATE groups SET content_filter=$2 WHERE id=$1', [group, { ...DEFAULT_CONTENT_FILTER, women: false }]);
    assert.equal((await create(owner, { formType: 'approval', fileUrl: 'image-file' })).code, 403);
    await db.query('UPDATE groups SET content_filter=$2 WHERE id=$1', [group, DEFAULT_CONTENT_FILTER]);
    for (const status of ['pending', 'removed']) {
      await db.query('UPDATE group_members SET status=$2 WHERE user_id=$1', [owner, status]);
      assert.equal((await call('GET', '/api/education-forms/:id', owner, form.id)).code, 404);
      assert.equal((await call('PUT', '/api/education-forms/:id/status', owner, form.id, { status: 'closed' })).code, 403);
      assert.equal((await call('GET', '/api/education-forms/:id/revisions/:revisionId', owner, form.id, {}, { revisionId: revision.id })).code, 404);
      assert.equal((await call('DELETE', '/api/education-forms/:id', owner, form.id)).code, 403);
    }
    const ownedDeletion = await create(other, { title: 'סקר למחיקה בידי היוצר' });
    assert.equal(ownedDeletion.code, 201);
    assert.equal((await call('DELETE', '/api/education-forms/:id', other, ownedDeletion.body.id)).code, 200);
    assert.equal((await db.query('SELECT * FROM education_forms WHERE id=$1', [ownedDeletion.body.id])).rowCount, 0);
    assert.equal((await call('DELETE', '/api/education-forms/:id', admin, form.id)).code, 200);
    assert.equal((await db.query('SELECT * FROM education_forms WHERE id=$1', [form.id])).rowCount, 0);
  } finally { await db.end(); }
});
