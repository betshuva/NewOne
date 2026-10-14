'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { createRequire } = require('node:module');
const { createAiPresentation, readAiPresentation } = require('../server/ai-presentation');
const { PREFIX, encryptMessageText, decryptMessageText, encryptedQueryValues, decryptMessageRows } = require('../server/message-at-rest');
const server = fs.readFileSync(require.resolve('../server/index.js'), 'utf8');
process.env.MESSAGE_ENCRYPTION_KEY ||= 'presentation-fixture-key-at-least-32-bytes-long';
const INFO = '00000000-0000-4000-8000-000000000003';
const GUIDE = '00000000-0000-4000-8000-000000000002';
const USER = '10000000-0000-4000-8000-000000000001';
const sources = [{ title: 'משרד ממשלתי', url: 'https://www.gov.il/first' }, { title: 'בנק ישראל', url: 'https://www.boi.org.il/second' }];
const legacyAnswer = `## מידע מאומת\n**פרט חשוב** 🙂 טמבל (https://www.gov.il/first)\n- צעד נוסף (https://www.boi.org.il/second)`;

function generator() {
  const filename = require.resolve('../server/safe-information-ai');
  const localRequire = createRequire(filename), module = { exports: {} };
  vm.runInNewContext(fs.readFileSync(filename, 'utf8'), { module, console, process, performance,
    AbortSignal, URL, Buffer, require: name => name === './provider-usage-log'
      ? { recordProviderCall: async () => {} } : localRequire(name) });
  return module.exports.generateSafeInformationAnswer;
}

function provider(text, annotations = [], searched = true, consulted = sources) {
  return { ok: true, json: async () => ({ output: [
    ...(searched ? [{ type: 'web_search_call', status: 'completed', action: { sources: consulted } }] : []),
    { type: 'message', content: [{ type: 'output_text', text, annotations }] },
  ] }) };
}

function annotatedText() {
  const markers = ['citefirst', 'citesecond', 'citeagain'];
  let text = '## מידע מאומת\n**חשוב** 🙂 ';
  const annotations = [];
  for (const [position, citation] of [sources[0], sources[1], sources[0]].entries()) {
    const start_index = text.length;
    text += markers[position];
    annotations.push({ type: 'url_citation', ...citation, start_index, end_index: text.length });
    text += '\n- פרט נוסף ';
  }
  return { text, annotations };
}

test('optional presentation retains only verified citations and final UTF-16 references without changing legacy strings', async () => {
  const run = generator(), data = annotatedText(), validated = [];
  const options = { apiKey: 'fake-key', question: 'חפש באינטרנט מידע כללי',
    validateSource: async url => { validated.push(url); return true; },
    fetchImpl: async (_, request) => {
      const body = JSON.parse(request.body);
      assert.match(body.instructions, /עצב מידע כללי ב-Markdown/);
      assert.equal(body.store, false);
      return provider(data.text, data.annotations, true, [...sources, { title: 'לא צוטט', url: 'https://consulted-only.example.test/' }]);
    } };
  const plain = await run(options);
  assert.equal(typeof plain, 'string');
  const result = await run({ ...options, includePresentation: true });
  assert.equal(result.answer, plain);
  assert.equal(result.aiPresentation.version, 1);
  assert.equal(result.aiPresentation.format, 'markdown');
  assert.deepEqual(result.aiPresentation.citations, sources.map((source, index) => ({ index: index + 1, ...source })));
  assert.equal(result.aiPresentation.references.length, 3);
  assert.deepEqual(result.aiPresentation.references.map(reference => reference.index), [1, 2, 1]);
  for (const reference of result.aiPresentation.references) {
    const citation = result.aiPresentation.citations[reference.index - 1];
    assert.equal(result.answer.slice(reference.startIndex, reference.endIndex), citation.url);
  }
  assert(result.answer.includes('## מידע מאומת') && result.answer.includes('**חשוב**'));
  assert.deepEqual(validated, [sources[0].url, sources[1].url, sources[0].url, sources[1].url]);
});

test('no-web, local emergency, rejected-link and listing replies expose no external cards', async () => {
  const run = generator();
  const noWeb = await run({ apiKey: 'fake', includePresentation: true, question: 'מהו מידע כללי?',
    fetchImpl: async () => provider('## מידע כללי\n**הסבר**', [], false) });
  assert.equal(typeof noWeb, 'string');
  const local = await run({ apiKey: 'fake', includePresentation: true, question: 'יש לו כאב חזק בחזה',
    fetchImpl: async () => assert.fail('Local policies must not call AI') });
  assert.equal(typeof local, 'string');
  assert.match(local, /מד״א 101/);
  const data = annotatedText();
  const rejected = await run({ apiKey: 'fake', includePresentation: true, question: 'חפש באינטרנט מידע כללי',
    validateSource: async () => false, fetchImpl: async () => provider(data.text, data.annotations) });
  assert.equal(typeof rejected, 'string');
  assert.match(rejected, /## מידע מאומת/);
  assert.match(rejected, /\*\*חשוב\*\*/);
  assert.doesNotMatch(rejected, /https:|cite/);
  const listing = await run({ apiKey: 'fake', includePresentation: true, question: 'חפש מודעות למקרר',
    validateSource: async () => true, fetchImpl: async (_, request) => {
      assert.doesNotMatch(JSON.parse(request.body).instructions, /עצב מידע כללי ב-Markdown/);
      return provider(data.text, data.annotations);
    } });
  assert.equal(typeof listing, 'string');
  assert.doesNotMatch(listing, /https:/);
});

test('tool citations stay clickable when the optional validator is absent', async () => {
  const run = generator(), data = annotatedText();
  const result = await run({ apiKey: 'fake', includePresentation: true,
    question: 'חפש באינטרנט מידע כללי',
    fetchImpl: async () => provider(data.text, data.annotations) });
  assert.match(result.answer, /## מידע מאומת/);
  assert.deepEqual(result.aiPresentation.citations,
    sources.map((source, index) => ({ index: index + 1, ...source })));
  assert.equal(result.aiPresentation.references.length, 3);
});

for (const [name, reject] of [
  ['rejects', async () => false],
  ['throws', async () => { throw new Error('synthetic validation unavailable'); }],
]) {
  test(`one source validator ${name} without hiding prose or the surviving citation`, async () => {
    const run = generator(), data = annotatedText(), checked = [];
    const result = await run({ apiKey: 'fake', includePresentation: true,
      question: 'חפש באינטרנט מידע כללי',
      validateSource: async url => {
        checked.push(url);
        return url === sources[0].url ? true : reject();
      },
      fetchImpl: async () => provider(data.text, data.annotations) });
    assert.match(result.answer, /## מידע מאומת/);
    assert.match(result.answer, /\*\*חשוב\*\*/);
    assert.equal(result.answer.split('- פרט נוסף').length - 1, 3);
    assert.ok(!result.answer.includes(sources[1].url));
    assert.deepEqual(checked, sources.map(source => source.url));
    assert.deepEqual(result.aiPresentation.citations, [{ index: 1, ...sources[0] }]);
    assert.deepEqual(result.aiPresentation.references.map(reference => reference.index), [1, 1]);
  });
}

test('blocked social and credential citations disappear while educational prose remains', async () => {
  const run = generator();
  const forbidden = ['https://www.facebook.com/source', 'https://user:password@example.test/source'];
  const text = `## לימוד כללי\nהסבר מפורט. ${forbidden.join(' ')} citeblocked`;
  const annotations = forbidden.map(url => ({ type: 'url_citation', url, title: 'מקור חסום' }));
  const result = await run({ apiKey: 'fake', includePresentation: true,
    question: 'תן לי הלכה אחת מפורטת מהלכות שבת',
    validateSource: async () => assert.fail('blocked URLs must not reach source validation'),
    fetchImpl: async () => provider(text, annotations, true, forbidden.map(url => ({ url }))) });
  assert.equal(typeof result, 'string');
  assert.match(result, /## לימוד כללי\nהסבר מפורט/);
  assert.doesNotMatch(result, /https:|facebook|password|מקור חסום|cite/);
});

test('presentation deduplicates five sources, handles punctuation and never uses supplied provider offsets', () => {
  const citations = [{ ...sources[0], startIndex: 999, endIndex: 1000 }, sources[0],
    { title: 'unsafe', url: 'http://example.test/' }, { title: 'credentials', url: 'https://user:secret@example.test/' },
    ...Array.from({ length: 7 }, (_, index) => ({ title: `מקור ${index}`, url: `https://example.test/${index}` }))];
  const answer = `🙂 ${sources[0].url}).\n${sources[0].url}!`;
  const presentation = createAiPresentation(answer, citations);
  assert.equal(presentation.citations.length, 5);
  assert.deepEqual(presentation.references, [
    { index: 1, startIndex: 3, endIndex: 3 + sources[0].url.length },
    { index: 1, startIndex: answer.lastIndexOf(sources[0].url), endIndex: answer.lastIndexOf(sources[0].url) + sources[0].url.length },
  ]);
  assert.equal(readAiPresentation('plaintext', answer), null);
  assert.equal(readAiPresentation('enc:v1:bad', answer), null);
});

function exchangeFixture(generated = { answer: legacyAnswer, aiPresentation: createAiPresentation(legacyAnswer, sources) }) {
  const start = server.indexOf('async function createSystemExchange(');
  const create = vm.runInNewContext(server.slice(start, server.indexOf('// ── Activity logger', start)) + ';createSystemExchange', {
    SYSTEM_USER_ID: GUIDE, SAFE_INFORMATION_USER_ID: INFO, createAiPresentation, encryptMessageText,
    auditIds: () => [null, null], redactHarmfulLanguageForDisplay: text => String(text).replaceAll('טמבל', 'מילה פוגענית'),
    generateSafeInformationSystemAnswer: async () => generated, generateSystemAnswer: async () => 'תשובת מדריך',
  });
  return create;
}

test('actual exchange stores encrypted metadata and recomputes references after reply redaction', async () => {
  const writes = [];
  const exchange = await exchangeFixture()({ query: async (sql, args) => {
    writes.push({ sql, args }); return { rows: [{ id: `message-${writes.length}`, created_at: '2026-10-12' }] };
  } }, USER, 'שאלה', null, INFO);
  assert.match(exchange.answer, /מילה פוגענית/);
  assert.equal(writes.length, 2);
  const stored = JSON.parse(writes[1].args[5]);
  assert(stored.aiPresentation.startsWith(PREFIX));
  assert(!writes[1].args[5].includes('gov.il') && !writes[1].args[5].includes('משרד ממשלתי'));
  assert.deepEqual(readAiPresentation(stored.aiPresentation, exchange.answer), exchange.aiPresentation);
  for (const reference of exchange.aiPresentation.references)
    assert.equal(exchange.answer.slice(reference.startIndex, reference.endIndex), exchange.aiPresentation.citations[reference.index - 1].url);
  const fallbackWrites = [];
  await exchangeFixture('מידע כללי')({ query: async (sql, args) => { fallbackWrites.push(args); return { rows: [{ id: 'plain' }] }; } }, USER, 'שאלה', null, INFO);
  assert.equal(fallbackWrites[1][5], null);
});

test('official information wrapper requests presentation and history without bot audience filtering', async () => {
  const start = server.indexOf('async function generateSafeInformationSystemAnswer(');
  const end = server.indexOf('const GROUP_FILTER_ACTIONS', start);
  let requested;
  const result = { answer: legacyAnswer, aiPresentation: createAiPresentation(legacyAnswer, sources) };
  const wrapper = vm.runInNewContext(server.slice(start, end) + ';generateSafeInformationSystemAnswer', {
    process: { env: { OPENAI_API_KEY: 'fixture' } }, SAFE_INFORMATION_USER_ID: INFO,
    messageAfterConversationClear: () => 'TRUE',
    generateSafeInformationAnswer: async options => { requested = options; return result; }, console,
  });
  const queries = [];
  const pool = { query: async sql => { queries.push(sql); return { rows: [] }; } };
  assert.equal(await wrapper(pool, USER, 'שאלה'), result);
  assert.equal(requested.includePresentation, true);
  assert.equal(requested.userId, USER);
  assert.equal(Object.hasOwn(requested, 'isTeen'), false);
  assert.ok(queries.every(sql => !/birth_date/.test(sql)));
  assert.equal(requested.history.length, 0);
});

test('actual assistant Socket and HTTP branches send the same presentation only back to the requesting user', async () => {
  const presentation = createAiPresentation(legacyAnswer, sources), exchange = {
    sent: { id: 'sent' }, reply: { id: 'reply', created_at: '2026-10-12' }, answer: legacyAnswer, aiPresentation: presentation,
  };
  const emitted = [];
  const context = { SYSTEM_USER_ID: GUIDE, SAFE_INFORMATION_USER_ID: INFO, SYSTEM_USER_NAME: 'מדריך', SAFE_INFORMATION_USER_NAME: 'מידע בטוח',
    getPool: async () => ({}), resolveSystemInput: async () => ({ question: 'שאלה', file: null }), createSystemExchange: async () => exchange,
    onlineUsers: new Map([[USER, 'requester-socket']]), io: { to: socket => ({ emit: (event, payload) => emitted.push({ socket, event, payload }) }) },
  };
  const socketStart = server.indexOf('      if ([SYSTEM_USER_ID, SAFE_INFORMATION_USER_ID].includes(toUserId)) {', server.indexOf("socket.on('chat:message'"));
  assert(socketStart >= 0);
  const socketEnd = server.indexOf('      if (!await teenContactAllowed', socketStart);
  const socketHandler = vm.runInNewContext(`(async function(socket,toUserId,text,fileUrl,fileName,normalizedStickerId){
    const pool=await getPool();${server.slice(socketStart, socketEnd)} })`, context);
  await socketHandler({ user: { id: USER }, emit: (event, payload) => emitted.push({ socket: 'requester-socket', event, payload }) }, INFO, 'שאלה');
  assert.deepEqual(emitted[0].payload.aiPresentation, presentation);
  const httpStart = server.indexOf('    if ([SYSTEM_USER_ID, SAFE_INFORMATION_USER_ID].includes(toUserId)) {', server.indexOf('async function sendPrivateHttpMessage('));
  assert(httpStart >= 0);
  const httpEnd = server.indexOf('    if (!await teenContactAllowed', httpStart);
  const httpHandler = vm.runInNewContext(`(async function(req,res,senderId,toUserId,text,fileUrl,fileName,normalizedStickerId){
    const pool=await getPool();${server.slice(httpStart, httpEnd)} })`, context);
  const res = { status(code) { this.code = code; return this; }, json(body) { this.body = body; return this; } };
  await httpHandler({ user: { id: USER } }, res, USER, INFO, 'שאלה');
  assert.deepEqual(res.body.systemReply.aiPresentation, presentation);
  assert.deepEqual(emitted[1].payload.aiPresentation, presentation);
  assert(emitted.every(event => event.socket === 'requester-socket'));
});

test('actual history route returns decoded metadata after the existing filtering and private projection pipeline', async () => {
  const presentation = createAiPresentation(legacyAnswer, sources);
  const protectedHistory = [{ id: 'answer', sender_id: INFO, recipient_id: USER, body: legacyAnswer,
    type: 'text', created_at: '2026-10-12T12:00:00Z',
    aiPresentation: encryptMessageText(JSON.stringify(presentation)) },
  { id: 'legacy', sender_id: INFO, recipient_id: USER, body: 'הודעה קודמת', type: 'text', created_at: '2026-10-12T11:00:00Z', aiPresentation: null }];
  const calls = [], rows = [protectedHistory, [], [], []];
  let handler;
  const start = server.indexOf("app.get('/api/messages/:userId',");
  const end = server.indexOf('\n});', start) + 5;
  vm.runInNewContext(server.slice(start, end), { app: { get(route, auth, callback) { handler = callback; } }, auth() {},
    ...require('../server/chat-history-window'), SYSTEM_USER_ID: GUIDE, SAFE_INFORMATION_USER_ID: INFO, readAiPresentation,
    teenContactAllowed: async () => true, messageAfterConversationClear: () => 'TRUE',
    getPool: async () => ({ query: async () => ({ rows: rows.shift() }) }),
    projectFilteredHistory: async (pool, user, entries) => { calls.push('filter'); return entries; },
    retainVisibleReceivedMessages: async () => { calls.push('retain'); },
    personalizeReceivedMessages: async (pool, user, entries) => { calls.push('personalize'); return entries; },
    projectOwnScans: async (pool, user, entries) => entries,
    projectGuideFilterNotice: row => row,
  });
  const res = { code: 200, status(code) { this.code = code; return this; }, json(body) { this.body = body; return this; } };
  await handler({ params: { userId: INFO }, user: { id: USER }, query: {} }, res);
  assert.equal(res.code, 200);
  assert.deepEqual(calls, ['filter', 'retain', 'personalize']);
  assert.deepEqual(res.body.find(row => row.id === 'answer').aiPresentation, presentation);
  assert.equal(res.body.find(row => row.id === 'legacy').aiPresentation, undefined);
});

test('encrypted presentation persists with actual exchange and private history SQL in isolated PostgreSQL tables',
  { skip: process.env.EDUCATION_TEST_DB !== '1' }, async () => {
  require('dotenv').config({ quiet: true });
  const { Client } = require('pg');
  const db = new Client({ connectionString: process.env.DATABASE_URL,
    ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' } : false });
  await db.connect();
  try {
    await db.query('SET search_path TO pg_temp, public');
    await db.query(`CREATE TEMP TABLE users(id uuid PRIMARY KEY,name text,read_receipts_enabled boolean DEFAULT true);
      CREATE TEMP TABLE messages(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),sender_id uuid,recipient_id uuid,group_id uuid,type text,
        body text,file_url text,file_name text,file_size bigint,reply_to_id uuid,created_at timestamptz DEFAULT now(),
        audit_operation_id uuid,audit_parent_event_id uuid,delivery_summary jsonb,deleted_for_everyone boolean DEFAULT false,deleted_for_sender boolean DEFAULT false);
      CREATE TEMP TABLE private_message_sends(user_id uuid,result jsonb,client_message_id text);
      CREATE TEMP TABLE stored_files(user_id uuid,public_url text,client_upload_id text,moderation_details jsonb,moderation_status text);
      CREATE TEMP TABLE message_user_deletions(message_id uuid,user_id uuid);
      CREATE TEMP TABLE message_status(message_id uuid,user_id uuid,status text);`);
    await db.query('INSERT INTO users(id,name) VALUES($1,$4),($2,$4),($3,$4)', [USER, INFO, GUIDE, 'שם בדיקה']);
    const protectedDb = { query: async (sql, args) => decryptMessageRows(await db.query(sql, encryptedQueryValues(sql, args))) };
    const exchange = await exchangeFixture()(protectedDb, USER, 'שאלה', null, INFO);
    const stored = (await db.query('SELECT body,delivery_summary FROM messages WHERE id=$1', [exchange.reply.id])).rows[0];
    assert(stored.body.startsWith(PREFIX));
    assert.equal(decryptMessageText(stored.body), exchange.answer);
    assert(stored.delivery_summary.aiPresentation.startsWith(PREFIX));
    assert(!JSON.stringify(stored.delivery_summary).includes('gov.il'));
    // User-authored metadata must never acquire an official assistant identity.
    await db.query('UPDATE messages SET delivery_summary=$2 WHERE id=$1', [exchange.sent.id, stored.delivery_summary]);
    const historyStart = server.indexOf('    const historySql = `', server.indexOf("app.get('/api/messages/:userId'"));
    const historyEnd = server.indexOf('    const historyQuery =', historyStart);
    const historySql = vm.runInNewContext(server.slice(historyStart, historyEnd) + ';historySql', {
      SAFE_INFORMATION_USER_ID: INFO, before: false, messageAfterConversationClear: () => 'TRUE',
    });
    const history = decryptMessageRows(await db.query(historySql, [USER, INFO])).rows;
    const answer = history.find(message => message.id === exchange.reply.id);
    assert.deepEqual(readAiPresentation(answer.aiPresentation, answer.body), exchange.aiPresentation);
    assert.equal(history.find(message => message.id === exchange.sent.id).aiPresentation, null);
    const foreignHistory = (await db.query(historySql, [GUIDE, INFO])).rows;
    assert.equal(foreignHistory.length, 0, 'Presentation follows the same private conversation gate');
  } finally { await db.end(); }
});
