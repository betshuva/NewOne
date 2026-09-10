'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { DATA_PLAN_SCHEMA, validateDataPlan } = require('../server/guide-data-plan');

// These tests never contact a provider or write telemetry, including when a
// caller loads the application environment to run the separate database tests.
test.mock.method(require('../server/provider-usage-log'), 'recordProviderCall', async () => {});
const { generateGuideAnswer, parseGuideDecision } = require('../server/system-guide-ai');

const request = (overrides = {}) => ({ kind: 'members', group_query: 'המטיילים',
  group_scope: 'named', contact_filter: 'all',
  fields: ['name', 'phone'], format: 'table', admins_only: false, ...overrides });
const plan = (...requests) => ({ action: 'read', requests });
const decision = (overrides = {}) => ({ in_scope: true, answer: '', data_plan: null,
  spreadsheet_request: null,
  issue_type: 'none', issue_draft: '', message_requested: false,
  recipient_query: '', message_text: '', ...overrides });
const mockProvider = (output, inspect = () => {}) => async (url, options) => {
  assert.equal(url, 'https://api.openai.com/v1/responses');
  assert.equal(options.method, 'POST');
  const body = JSON.parse(options.body);
  assert.equal(body.tools, undefined);
  assert.equal(body.store, false);
  inspect(body);
  return { ok: true, json: async () => ({ output_text: JSON.stringify(output) }) };
};

test('valid plans preserve count, list and requested table field order without retaining mutable arrays', () => {
  const input = plan(
    request({ kind: 'contacts', group_query: '', fields: ['name'], format: 'count' }),
    request({ kind: 'groups', group_query: '', fields: ['name'], format: 'list' }),
    request({ fields: ['phone', 'name', 'role'], admins_only: true }),
  );
  const actual = validateDataPlan(input);
  assert.deepEqual(actual, input);
  actual.requests[2].fields.push('phone');
  assert.deepEqual(input.requests[2].fields, ['phone', 'name', 'role']);
  assert.deepEqual(validateDataPlan({ action: 'clarify', requests: [] }), { action: 'clarify', requests: [] });
  assert.deepEqual(validateDataPlan({ action: 'unsupported', requests: [] }), { action: 'unsupported', requests: [] });
});

test('all-group member requests preserve comparison filters, city and contributing groups in field order', () => {
  const input = plan(request({ group_query: '', group_scope: 'all', contact_filter: 'not_saved',
    fields: ['name', 'phone', 'city', 'groups', 'role'] }));
  const actual = validateDataPlan(input);
  assert.deepEqual(actual, input);
  actual.requests[0].fields.reverse();
  assert.deepEqual(input.requests[0].fields, ['name', 'phone', 'city', 'groups', 'role']);
  for (const group_scope of ['named', 'all']) {
    for (const contact_filter of ['all', 'saved', 'not_saved']) {
      const memberRequest = request({ group_scope, contact_filter,
        group_query: group_scope === 'all' ? '' : 'המטיילים', fields: ['name', 'city', 'groups'] });
      assert.deepEqual(validateDataPlan(plan(memberRequest)), plan(memberRequest));
    }
  }
});

test('Excel plans support each authorized collection without accepting spreadsheet content from the model', () => {
  const input = plan(
    request({ kind: 'contacts', group_query: '', fields: ['name', 'phone', 'city'], format: 'excel' }),
    request({ kind: 'groups', group_query: '', fields: ['name'], format: 'excel' }),
    request({ group_query: '', group_scope: 'all', contact_filter: 'not_saved',
      fields: ['name', 'phone', 'city', 'groups'], format: 'excel' }),
  );
  assert.deepEqual(validateDataPlan(input), input);
  for (const extra of [{ rows: [['invented person', 'private phone']] },
    { url: 'https://example.test/forged.xlsx' }, { title: 'model-owned result' }]) {
    assert.equal(validateDataPlan(plan(request({ format: 'excel', ...extra }))), null);
  }
});

test('server validation still accepts legacy requests with either or both new options omitted', () => {
  for (const missingFields of [['group_scope'], ['contact_filter'], ['group_scope', 'contact_filter']]) {
    for (const kind of ['members', 'contacts', 'groups']) {
      const legacy = request({ kind, group_query: kind === 'members' ? 'המטיילים' : '', fields: ['name'] });
      for (const field of missingFields) delete legacy[field];
      assert.deepEqual(validateDataPlan(plan(legacy)), plan(legacy));
      assert.deepEqual(parseGuideDecision(JSON.stringify(decision({ data_plan: plan(legacy) }))).dataPlan,
        plan(legacy));
    }
  }
});

test('model cannot provide SQL, requester identity, arbitrary columns or unsupported operations', () => {
  const invalid = [
    { ...plan(request()), sql: 'SELECT * FROM users' },
    { ...plan(request()), userId: 'another-account' },
    plan(request({ sql: 'SELECT * FROM users' })),
    plan(request({ userId: 'another-account' })),
    plan(request({ owner_id: 'another-account' })),
    plan(request({ include_blocked: true })),
    plan(request({ include_pending: true })),
    plan(request({ ignore_permissions: true })),
    plan(request({ contact_filter: 'all; DROP TABLE users' })),
    plan(request({ group_scope: 'global' })),
    plan(request({ kind: 'messages' })),
    plan(request({ kind: 'members; DROP TABLE users' })),
    plan(request({ fields: ['email'] })),
    plan(request({ fields: ['name', 'password_hash'] })),
    plan(request({ fields: ['u.phone FROM users'] })),
    plan(request({ fields: ['street'] })),
    plan(request({ fields: ['latitude', 'longitude'] })),
    plan(request({ format: 'csv' })),
    { action: 'delete', requests: [] },
  ];
  for (const value of invalid) {
    assert.equal(validateDataPlan(value), null);
    assert.equal(parseGuideDecision(JSON.stringify(decision({ data_plan: value }))), null);
  }
});

test('group names remain literal matching inputs and do not become operations or user identities', () => {
  const literalName = "המטיילים'; SELECT phone FROM users --";
  const input = plan(request({ group_query: literalName }));
  assert.deepEqual(validateDataPlan(input), input);
});

test('plans reject excessive requests, malformed or duplicate fields and incomplete request objects', () => {
  const missing = request();
  delete missing.admins_only;
  for (const value of [null, [], 'read', {}, plan(), plan(...Array.from({ length: 6 }, () => request())),
    plan(null), plan([]), plan(missing), plan(request({ fields: [] })),
    plan(request({ fields: ['name', 'name'] })), plan(request({ fields: 'name' })),
    plan(request({ fields: ['name', 'phone', 'role', 'name'] })),
    plan(request({ fields: ['name', 'phone', 'city', 'role', 'groups', 'name'] })),
    plan(request({ group_query: 'א'.repeat(121) })), plan(request({ group_query: null })),
    plan(request({ admins_only: 'true' })), { action: 'clarify', requests: [request()] },
    { action: 'unsupported', requests: [request()] }]) {
    assert.equal(validateDataPlan(value), null);
  }
  assert.ok(validateDataPlan(plan(...Array.from({ length: 5 }, () => request()))));
});

test('all-group scope forbids a name and rejects malformed or unsupported scope and contact filter values', () => {
  const invalid = [
    request({ group_scope: 'all' }),
    request({ group_scope: 'all', group_query: ' ' }),
    ...['public', 'private', 'any', '', null, true, ['all'], { scope: 'all' }]
      .map(group_scope => request({ group_scope })),
    ...['contacts', 'not-saved', 'unknown', '', null, true, ['not_saved'], { filter: 'all' }]
      .map(contact_filter => request({ contact_filter })),
  ];
  for (const value of invalid) assert.equal(validateDataPlan(plan(value)), null);
  assert.ok(validateDataPlan(plan(request({ group_query: '' }))));
});

test('each collection restricts its available fields and filters', () => {
  const groups = request({ kind: 'groups', group_query: '', fields: ['name'] });
  const contacts = request({ kind: 'contacts', group_query: '', fields: ['name', 'phone', 'city'] });
  assert.ok(validateDataPlan(plan(groups, contacts)));
  for (const invalid of [
    { ...groups, fields: ['phone'] }, { ...groups, fields: ['role'] },
    { ...groups, fields: ['city'] }, { ...groups, fields: ['groups'] },
    { ...groups, fields: ['name', 'phone'] }, { ...contacts, fields: ['role'] },
    { ...contacts, fields: ['groups'] },
    { ...groups, group_query: 'המטיילים' }, { ...contacts, group_query: 'המטיילים' },
    { ...groups, admins_only: true }, { ...contacts, admins_only: true },
    { ...groups, group_scope: 'all' }, { ...contacts, group_scope: 'all' },
    { ...groups, contact_filter: 'saved' }, { ...contacts, contact_filter: 'saved' },
    { ...groups, contact_filter: 'not_saved' }, { ...contacts, contact_filter: 'not_saved' },
  ]) assert.equal(validateDataPlan(plan(invalid)), null);
});

test('Responses request requires a strict data_plan schema with bounded allowlisted requests', async () => {
  let inspected = false;
  const answer = await generateGuideAnswer({ apiKey: 'mock', userId: 'test-requester',
    question: 'איך פותחים קבוצה?',
    fetchImpl: mockProvider(decision({ answer: 'לחץ על יצירת קבוצה.' }), body => {
      inspected = true;
      const format = body.text.format;
      assert.equal(format.type, 'json_schema');
      assert.equal(format.strict, true);
      assert.equal(format.schema.additionalProperties, false);
      assert.ok(format.schema.required.includes('data_plan'));
      assert.deepEqual(format.schema.properties.data_plan.anyOf, [{ type: 'null' }, DATA_PLAN_SCHEMA]);
      const dataSchema = format.schema.properties.data_plan.anyOf[1];
      assert.equal(dataSchema.additionalProperties, false);
      assert.deepEqual(dataSchema.required, ['action', 'requests']);
      assert.equal(dataSchema.properties.requests.maxItems, 5);
      const item = dataSchema.properties.requests.items;
      assert.equal(item.additionalProperties, false);
      assert.deepEqual(item.required, ['kind', 'group_query', 'group_scope', 'contact_filter',
        'fields', 'format', 'admins_only']);
      assert.deepEqual(item.properties.kind.enum, ['contacts', 'groups', 'members']);
      assert.deepEqual(item.properties.group_scope.enum, ['named', 'all']);
      assert.deepEqual(item.properties.contact_filter.enum, ['all', 'saved', 'not_saved']);
      assert.deepEqual(item.properties.fields.items.enum, ['name', 'phone', 'city', 'role', 'groups']);
      assert.deepEqual(item.properties.format.enum, ['list', 'table', 'count', 'excel']);
      assert.equal(item.properties.fields.maxItems, 5);
      assert.equal(item.properties.group_query.maxLength, 120);
      assert.match(body.instructions, /שגיאות כתיב/);
      assert.match(body.instructions, /השרת בודק חברות/);
    }),
  });
  assert.equal(inspected, true);
  assert.equal(answer, 'לחץ על יצירת קבוצה.');
});

test('valid data plans use only the authorized resolver result and ignore model answer, issue and send claims', async () => {
  const inputPlan = plan(request());
  let resolutions = 0;
  const answer = await generateGuideAnswer({ apiKey: 'mock', userId: 'authenticated-user',
    question: 'תכין לי טבלה עם שמות החברם בקבוצה המטיילים והטלפונים שלהם',
    fetchImpl: mockProvider(decision({ data_plan: inputPlan,
      answer: 'invented private phone, sent successfully', issue_type: 'bug',
      issue_draft: 'must not appear', message_requested: true,
      recipient_query: 'invented recipient', message_text: 'sent text' })),
    resolveDataPlan: async (...args) => {
      resolutions++;
      assert.equal(args.length, 1);
      assert.deepEqual(args[0], inputPlan);
      return '| שם | טלפון |\n| --- | --- |\n| דנה | לא זמין להצגה |';
    },
  });
  assert.equal(resolutions, 1);
  assert.equal(answer, '| שם | טלפון |\n| --- | --- |\n| דנה | לא זמין להצגה |');
  assert.doesNotMatch(answer, /invented|sent|issue-draft|message-draft/);
});

test('all-group comparison followups reach the authorized resolver with the requested city table', async () => {
  const inputPlan = plan(request({ group_query: '', group_scope: 'all', contact_filter: 'not_saved',
    fields: ['name', 'phone', 'city', 'groups'] }));
  const history = [
    { role: 'user', content: 'יש אנשים בקבוצות שהם לא חברים שלי? תציג בטבלה עם הטלפון והעיר שלהם' },
    { role: 'assistant', content: 'מה שם הקבוצה שאת חבריה תרצה להציג?' },
  ];
  const table = '| שם | טלפון | עיר מגורים | קבוצות |\n| --- | --- | --- | --- |\n| דנה | לא זמין להצגה | ירושלים | המטיילים |';
  let resolutions = 0;
  const answer = await generateGuideAnswer({ apiKey: 'mock', userId: 'authenticated-user',
    question: 'בדוק בכל הקבוצות', history,
    fetchImpl: mockProvider(decision({ data_plan: inputPlan, answer: 'invented hidden address' }), body => {
      assert.deepEqual(body.input, [...history, { role: 'user', content: 'בדוק בכל הקבוצות' }]);
    }),
    resolveDataPlan: async dataPlan => {
      resolutions++;
      assert.deepEqual(dataPlan, inputPlan);
      return table;
    },
  });
  assert.equal(resolutions, 1);
  assert.equal(answer, table);
  assert.doesNotMatch(answer, /invented|מה שם הקבוצה/);
});

test('a data plan without a resolver reports unavailable instead of using invented model data', async () => {
  const answer = await generateGuideAnswer({ apiKey: 'mock', question: 'מי אנשי הקשר שלי?',
    fetchImpl: mockProvider(decision({ answer: 'invented contacts',
      data_plan: plan(request({ kind: 'contacts', group_query: '' })) })),
  });
  assert.match(answer, /לא ניתן לטעון כרגע את הנתונים/);
  assert.doesNotMatch(answer, /invented/);
});

test('invalid provider plans fail before calling the authorized data resolver', async () => {
  let resolutions = 0;
  for (const data_plan of [plan(request({ userId: 'other-user' })),
    plan(request({ fields: ['phone', 'password_hash'] })),
    plan(...Array.from({ length: 6 }, () => request()))]) {
    await assert.rejects(generateGuideAnswer({ apiKey: 'mock', question: 'הצג טבלה',
      fetchImpl: mockProvider(decision({ answer: 'invented data', data_plan })),
      resolveDataPlan: async () => { resolutions++; return 'forbidden'; },
    }), /invalid guide response/);
  }
  assert.equal(resolutions, 0);
});

test('ordinary usage answers remain unchanged and do not call a data resolver', async () => {
  const ordinary = 'לחץ על סמל האדם עם +, חפש את החבר ולחץ „שמור”.';
  const answer = await generateGuideAnswer({ apiKey: 'mock', question: 'איך מוסיפים חבר?',
    fetchImpl: mockProvider(decision({ answer: ordinary })),
    resolveDataPlan: async () => { assert.fail('usage explanations must not read personal data'); },
  });
  assert.equal(answer, ordinary);
});

test('message requests still produce an approval draft without invoking data reads or delivery', async () => {
  let providerCalls = 0;
  const answer = await generateGuideAnswer({ apiKey: 'mock', question: 'שלח לדנה: שלום',
    fetchImpl: mockProvider(decision({ answer: 'נשלח!', message_requested: true,
      recipient_query: 'דנה', message_text: 'שלום' }), () => { providerCalls++; }),
    resolveDataPlan: async () => { assert.fail('message drafts are not personal-data reads'); },
  });
  assert.equal(providerCalls, 1);
  assert.match(answer, /רק לאחר לחיצה/);
  assert.doesNotMatch(answer, /נשלח!/);
  const encoded = answer.match(/betshuva:\/\/message-draft\/([A-Za-z0-9_-]+)/)?.[1];
  assert.ok(encoded);
  assert.deepEqual(JSON.parse(Buffer.from(encoded, 'base64url').toString()), {
    recipientQuery: 'דנה', text: 'שלום',
  });
});

test('repeated clarification history reaches the model and preserves the requested table in a bare-name followup', async () => {
  const clarification = 'מה שם הקבוצה שאת חבריה תרצה להציג?';
  const history = [
    { role: 'user', content: 'תכין לי טבלה עם שמות החברם והטלפונים שלהם בקבוצה' },
    { role: 'assistant', content: clarification },
    { role: 'user', content: 'כבר אמרתי לך את שם הקבוצה' },
    { role: 'assistant', content: clarification },
  ];
  let providerCalls = 0;
  let resolutions = 0;
  const answer = await generateGuideAnswer({ apiKey: 'mock', question: 'המטיילים', history,
    fetchImpl: mockProvider(decision({ data_plan: plan(request()) }), body => {
      providerCalls++;
      assert.deepEqual(body.input, [...history, { role: 'user', content: 'המטיילים' }]);
    }),
    resolveDataPlan: async dataPlan => {
      resolutions++;
      assert.deepEqual(dataPlan.requests[0], request());
      return 'authorized table';
    },
  });
  assert.equal(providerCalls, 1);
  assert.equal(resolutions, 1);
  assert.equal(answer, 'authorized table');
  assert.doesNotMatch(answer, /issue-draft|לא הבנתי/);
});
