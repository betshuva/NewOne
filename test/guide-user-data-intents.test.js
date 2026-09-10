'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  answerUserDataQuestion,
  personalDataRequest,
  followupDataRequest,
} = require('../server/guide-user-data');

const NAME_PROMPT = 'מה שם הקבוצה שאת חבריה תרצה להציג?';
const CHOICE_PROMPT = 'יש כמה קבוצות מתאימות. כתוב „מי החברים בקבוצה” ואחריו השם המלא או מזהה הקבוצה:\nהמטיילים בצפון — north\nהמטיילים בדרום — south';
const turn = (role, content, ageMinutes = 1) => ({
  role, content, createdAt: new Date(Date.now() - ageMinutes * 60_000).toISOString(),
});
const clarification = (question, prompt = NAME_PROMPT) => [
  turn('user', question, 2), turn('assistant', prompt),
];

for (const question of [
  'כמה חברים יש לי וכמה קבוצות?',
  'כמה קבוצות יש לי וכמה חברים?',
  'כמה אנשי קשר יש לי וכמה קבוצות?',
  'כמה קבוצות יש לי וכמה אנשי קשר?',
]) {
  test(`combined account counts: ${question}`, () => {
    assert.deepEqual(personalDataRequest(question), { kind: 'overview', countOnly: true });
  });
}

for (const [question, kind] of [
  ['כמה חברים יש לי?', 'contacts'],
  ['כמה אנשי קשר יש לי?', 'contacts'],
  ['כמה אנשי הקשר שלי?', 'contacts'],
  ['כמה קבוצות יש לי?', 'groups'],
  ['בכמה קבוצות אני חבר?', 'groups'],
  ['כמה קבוצות אני חבר בהן?', 'groups'],
]) {
  test(`standalone account count: ${question}`, () => {
    assert.deepEqual(personalDataRequest(question), { kind, countOnly: true });
  });
}

test('account lists remain lists rather than becoming counts', () => {
  assert.deepEqual(personalDataRequest('מי אנשי הקשר שלי?'), { kind: 'contacts', countOnly: false });
  assert.deepEqual(personalDataRequest('באילו קבוצות אני חבר?'), { kind: 'groups', countOnly: false });
});

for (const [question, name, adminsOnly, countOnly] of [
  ['כמה חברים בקבוצת המטיילים?', 'המטיילים', false, true],
  ['מי מנהל בקבוצת החברים שלי?', 'החברים שלי', true, false],
  ['מי החברים בקבוצת הקבוצות שלי?', 'הקבוצות שלי', false, false],
  ['כמה מנהלים בקבוצה "המטיילים"?', 'המטיילים', true, true],
]) {
  test(`an explicit group remains distinct from account counts: ${question}`, () => {
    assert.deepEqual(personalDataRequest(question), { kind: 'members', name, adminsOnly, countOnly });
  });
}

test('bare group-name followup preserves the requested member count', () => {
  const request = followupDataRequest('„המטיילים”', clarification('כמה חברים בקבוצה?'));
  assert.equal(request.kind, 'members');
  assert.equal(request.name, 'המטיילים');
  assert.equal(request.countOnly, true);
  assert.equal(request.adminsOnly, false);
});

test('numbered group names preserve the requested administrator list', () => {
  const request = followupDataRequest('1. המטיילים בצפון\n2. המטיילים בדרום',
    clarification('מי המנהלים בקבוצה?'));
  assert.deepEqual(request.names, ['המטיילים בצפון', 'המטיילים בדרום']);
  assert.equal(request.countOnly, false);
  assert.equal(request.adminsOnly, true);
});

test('an exact name after an ambiguity prompt preserves the administrator count', () => {
  const request = followupDataRequest('המטיילים בצפון',
    clarification('כמה מנהלים בקבוצת מטיילים?', CHOICE_PROMPT));
  assert.equal(request.name, 'המטיילים בצפון');
  assert.equal(request.countOnly, true);
  assert.equal(request.adminsOnly, true);
});

test('a second clarification after a bare partial name retains the original request', () => {
  const history = [
    ...clarification('כמה מנהלים בקבוצה?'),
    turn('user', 'מטיילים'), turn('assistant', CHOICE_PROMPT),
  ];
  const request = followupDataRequest('המטיילים בצפון', history);
  assert.ok(request, 'the clarification chain must retain its original intent');
  assert.equal(request.name, 'המטיילים בצפון');
  assert.equal(request.countOnly, true);
  assert.equal(request.adminsOnly, true);
});

test('the original combined-count bug can recover after a mistaken group-name prompt', () => {
  assert.deepEqual(followupDataRequest('1. המטיילים\n2. חברים',
    clarification('כמה חברים יש לי וכמה קבוצות?')),
  { kind: 'overview', countOnly: true });
});

test('a new direct data request overrides the pending group-name question', async () => {
  let calls = 0;
  const pool = { query: async (sql, values) => {
    calls++;
    assert.match(sql, /FROM user_contacts c/);
    assert.deepEqual(values, ['current-user']);
    return { rows: [{ count: 4 }] };
  } };
  const answer = await answerUserDataQuestion(pool, 'current-user', 'כמה חברים יש לי?', {
    history: clarification('כמה מנהלים בקבוצה?'),
  });
  assert.equal(calls, 1);
  assert.match(answer, /אנשי קשר שמורים: 4/);
  assert.doesNotMatch(answer, /מה שם הקבוצה|מנהלים/);
});

for (const question of ['עזוב', 'בטל', 'לא משנה', 'תודה', 'איך משנים סינון?',
  'תציג לי את התמונה האחרונה']) {
  test(`cancellation or a new topic is not a group name: ${question}`, () => {
    assert.equal(followupDataRequest(question, clarification('מי החברים בקבוצה?')), null);
  });
}

test('a cancellation or new-topic exchange invalidates an older clarification', () => {
  for (const content of ['עזוב', 'איך משנים סינון?']) {
    const history = [...clarification('מי החברים בקבוצה?'), turn('user', content),
      turn('assistant', 'בסדר.')];
    assert.equal(followupDataRequest('המטיילים', history), null);
  }
});

test('only an immediately preceding trusted guide clarification opens name followup', () => {
  for (const history of [
    [],
    [turn('user', 'מי החברים בקבוצה?'), turn('user', NAME_PROMPT)],
    [turn('user', 'מי החברים בקבוצה?'), turn('assistant', 'אפשר לכתוב שם קבוצה.')],
    [turn('user', 'איך משנים סינון?'), turn('assistant', NAME_PROMPT)],
    [...clarification('מי החברים בקבוצה?'), turn('user', 'עזוב')],
  ]) assert.equal(followupDataRequest('המטיילים', history), null);
});

test('expired or missing clarification timestamps cannot reopen group requests', () => {
  for (const last of [
    turn('assistant', NAME_PROMPT, 16),
    { role: 'assistant', content: NAME_PROMPT },
    { role: 'assistant', content: NAME_PROMPT, createdAt: 'invalid-date' },
  ]) assert.equal(followupDataRequest('המטיילים', [turn('user', 'מי החברים בקבוצה?'), last]), null);
});

test('a bare selection number cannot select an unnumbered ambiguity result', () => {
  assert.equal(followupDataRequest('2', clarification('מי החברים בקבוצת מטיילים?', CHOICE_PROMPT)), null);
});
