const test = require('node:test');
const assert = require('node:assert/strict');
const { normalizeFormEdit, contentChanged, registerEducationFormEditing } = require('../server/education-form-edit');
const form = { status: 'open', id: 'form', group_id: 'group', form_type: 'survey', title: 'סקר',
  description: null, questions: [{text: 'מתי?', options: ['בוקר', 'ערב']}],
  file_url: null, file_name: null, anonymous: true, updated_at: '2026-10-11T10:00:00Z' };
const input = { title: form.title, description: '', questions: form.questions,
  anonymous: true, expectedUpdatedAt: form.updated_at };

test('survey edits validate every question and do not silently discard invalid options', () => {
  assert.deepEqual(normalizeFormEdit(input, 'survey').questions, form.questions);
  for (const questions of [[], [null], [{text: 'מתי?', options: ['כן', 'כן']}],
    [{text: 'מתי?', options: ['כן', '']}], Array(21).fill(form.questions[0])]) {
    assert.throws(() => normalizeFormEdit({...input, questions}, 'survey'));
  }
});
test('document rename and due-date edits retain responses; content changes require a fresh response', () => {
  const old = {...form, form_type: 'signature', questions: [], file_url: 'https://storage.test/doc.pdf', file_name: 'ישן.pdf'};
  const next = normalizeFormEdit({...input, fileUrl: old.file_url, fileName: 'חדש.pdf'}, 'signature');
  next.anonymous = old.anonymous;
  assert.equal(contentChanged(old, next), false);
  assert.equal(contentChanged(form, normalizeFormEdit({...input,
    questions: [...form.questions, {text: 'איפה?', options: ['כאן', 'שם']}]}, 'survey')), true);
  assert.throws(() => normalizeFormEdit({...input, fileUrl: null}, 'signature'));
});
test('question selection modes retain true, omit false, and count a mode change as edited content', () => {
  const multiple = { ...form.questions[0], allowMultiple: true };
  const next = normalizeFormEdit({ ...input, questions: [multiple] }, 'survey');
  assert.deepEqual(next.questions, [multiple]);
  assert.equal(contentChanged(form, next), true);
  assert.equal(contentChanged({ ...form, questions: [multiple] }, normalizeFormEdit(input, 'survey')), true);
  const single = normalizeFormEdit({ ...input,
    questions: [{ ...form.questions[0], allowMultiple: false }] }, 'survey');
  assert.deepEqual(single.questions, form.questions);
  assert.equal(contentChanged(form, single), false);
  assert.equal(contentChanged({ ...form, questions: [{ ...form.questions[0], allowMultiple: false }] }, single), false);
  for (const allowMultiple of [null, 'true', 1, [], {}])
    assert.throws(() => normalizeFormEdit({ ...input,
      questions: [{ ...form.questions[0], allowMultiple }] }, 'survey'));
});

async function edit(body, { authorized = true, failSave = false } = {}) {
  const calls = [], events = [], pushes = [];
  let handler, released = false;
  const client = { async query(sql, args) {
    calls.push({sql, args});
    if (sql.startsWith('SELECT f.*')) return {rows: authorized ? [form] : []};
    if (sql.startsWith('UPDATE education_forms')) {
      if (failSave) throw new Error('test write failure');
      return {rows: [{...form, title: args[1]}]};
    }
    if (sql.startsWith('SELECT recipient.user_id')) return {rows: [{user_id: 'recipient'}]};
    return {rows: []};
  }, release() {released = true;} };
  registerEducationFormEditing({get(){},put(path, auth, callback) {handler = callback;}}, {
    auth() {}, getPool: async () => ({connect: async () => client}),
    io: {to: () => ({emit: (...args) => events.push(args)})},
    sendPush: (...args) => pushes.push(args),
  });
  const res = {code: 200, status(v) {this.code = v; return this;}, json(v) {this.body = v;} };
  await handler({params: {id: 'form'}, user: {id: 'admin'}, body}, res);
  assert.equal(released, true);
  return {res, calls, events, pushes};
}
test('published content saves archive before resetting responses and committing', async () => {
  const result = await edit({...input, title: 'מעודכן'});
  assert.equal(result.res.code, 200);
  assert.equal(result.res.body.answersReset, true);
  const sql = result.calls.map(c => c.sql);
  assert(sql[1].includes('FOR UPDATE OF f'));
  assert(sql.findIndex(s => s.startsWith('INSERT INTO education_form_revisions')) <
    sql.findIndex(s => s.startsWith('DELETE FROM education_form_responses')));
  assert(sql.indexOf('COMMIT') > sql.findIndex(s => s.startsWith('UPDATE education_forms')));
  assert.equal(result.events[0][1].action, 'edited');
  assert.equal(result.pushes.length, 1);
});
test('unchanged content saves without resetting or notifying recipients', async () => {
  const result = await edit(input);
  assert.equal(result.res.code, 200);
  assert.equal(result.res.body.answersReset, false);
  assert(!result.calls.some(c => c.sql.startsWith('DELETE')));
  assert.equal(result.pushes.length, 0);
});
test('unauthorized and stale edits never write; failed saves rollback without notification', async () => {
  for (const [body, options, status] of [
    [input, {authorized: false}, 403],
    [{...input, expectedUpdatedAt: '2026-01-01'}, {}, 409],
    [{...input, title: 'מעודכן'}, {failSave: true}, 500],
  ]) {
    const result = await edit(body, options);
    assert.equal(result.res.code, status);
    assert(!result.calls.some(c => c.sql === 'COMMIT'));
    assert.equal(result.calls.at(-1).sql, 'ROLLBACK');
    assert.equal(result.events.length, 0);
    assert.equal(result.pushes.length, 0);
  }
});
test('anonymous revision history never exposes identity, signature or response timing', async () => {
  let history;
  const queries=[];
  registerEducationFormEditing({put(){},get(path,auth,fn){history=fn;}}, {
    auth(){},getPool: async () => ({query: async sql => {
      queries.push(sql);
      return {rows:[{snapshot: {...form,anonymous:true},created_at:'2026-10-11',responses:[{
        user_id:'secret-user',signer_name:'שם פרטי',signature_data:[{x:1,y:1}],
        response_status:'completed',answers:{0:'בוקר'},submitted_at:'2026-10-11T10:00:00Z',
      }]}]};
    }}),io:{},sendPush(){},
  });
  const res={status(){return this;},json(body){this.body=body;}};
  await history({params:{id:'form',revisionId:'revision'},user:{id:'admin'}},res);
  assert.deepEqual(res.body.responses,[{response_status:'completed',answers:{0:'בוקר'}}]);
  assert.equal(queries.length,1);
  assert(queries[0].includes("(gm.role='admin' OR f.created_by=$3) AND gm.status='member'"));
});
