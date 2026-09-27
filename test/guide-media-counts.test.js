const test = require('node:test');
const assert = require('node:assert/strict');
const { personalDataRequest, answerUserDataQuestion, executeGuideDataPlan } = require('../server/guide-user-data');
const { validateDataPlan } = require('../server/guide-data-plan');
const media = { kind: 'media', group_query: '', group_scope: 'named', contact_filter: 'all', fields: ['name'], format: 'count', admins_only: false };
const plan = request => ({ action: 'read', requests: [request] });
test('media counts recognize original question and keep the requester scope', async () => {
  assert.equal(personalDataRequest('כמה קבצים יש לי פרט לפי סוגים').kind, 'media');
  let reads = 0;
  const output = await answerUserDataQuestion({}, 'owner', 'כמה קבצים יש לי פרט לפי סוגים', {
    loadMediaCounts: async id => { assert.equal(id, 'owner'); reads++; return [{file_type:'image',count:2},{file_type:'video',count:1}]; },
  });
  assert.equal(reads, 1); assert.match(output,/3 קבצים/); assert.match(output,/תמונות: 2/); assert.match(output,/מסמכים: 0/);
});
test('structured media requests cannot request names, other accounts or unsupported exports', async () => {
  assert.ok(validateDataPlan(plan(media)));
  for (const patch of [{group_query:'someone'}, {format:'excel'}, {fields:['phone']}, {admins_only:true}, {group_scope:'all'}])
    assert.equal(validateDataPlan(plan({...media,...patch})),null);
  const output = await executeGuideDataPlan({}, 'owner', plan(media), { loadMediaCounts: async id => {assert.equal(id,'owner'); return []; }});
  assert.match(output,/0 קבצים/);
});
test('missing identity and unavailable storage do not invent counts', async () => {
  let calls=0;
  assert.match(await answerUserDataQuestion({}, null, 'כמה קבצים יש לי', {loadMediaCounts:async()=>{calls++;return[];}}),/להתחבר/);
  assert.equal(calls,0);
  assert.match(await answerUserDataQuestion({}, 'owner', '', {request:media,loadMediaCounts:async()=>{throw new Error('offline');}}),/לא ניתן לטעון/);
});
