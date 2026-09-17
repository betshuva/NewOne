'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  assertSenderMediaAllowed,
  getEffectiveSenderFilter,
} = require('../server/sender-content-filter');

const ALL = { text: true, video: true, nonHumanImages: true,
  men: true, women: true, children: true };
const MEN = { category: 'men', detectedCategories: ['men'], uncertain: false };
const OBJECTS = { category: 'nonHumanImages', detectedCategories: ['nonHumanImages'] };
const USER = '10000000-0000-4000-8000-000000000001';
const CONTACT = '10000000-0000-4000-8000-000000000002';
const FILE = '10000000-0000-4000-8000-000000000003';
const MESSAGE = '10000000-0000-4000-8000-000000000004';

function database(general = ALL, scoped = null) {
  const db = { general, scoped, queries: [], events: [], missing: false };
  db.query = async (sql, params) => {
    db.queries.push({ sql, params });
    if (sql.startsWith('SELECT u.content_filter')) return { rows: db.missing ? [] : [{
      general_filter: db.general, scoped_filter: params[1] === 'general' ? null : db.scoped,
    }] };
    if (sql.startsWith('SELECT id FROM stored_files')) return { rows: [{ id: FILE }] };
    if (sql.startsWith('INSERT INTO filter_audit_events')) {
      const [kind,userId,actorId,scopeType,scopeId,messageId,fileId,details] = params;
      const event = { kind,userId,actorId,scopeType,scopeId,messageId,fileId,
        details: JSON.parse(details) };
      db.events.push(event);
      return { rows: [event] };
    }
    throw new Error('Unexpected query: ' + sql);
  };
  return db;
}

function send(db, extra = {}) {
  return assertSenderMediaAllowed(db, { userId: USER,
    contextType: 'chat', contextId: CONTACT, type: 'image', classification: MEN,
    fileId: FILE, ...extra });
}

test('blocked sender image is rejected with the exact sender policy and audit identifiers', async () => {
  const db = database({ ...ALL, men: false, enforceGeneralFilter: true }, ALL);
  await assert.rejects(send(db, { messageId: MESSAGE, source: 'direct_socket_send' }), {
    status: 403, code: 'SENDER_CONTENT_FILTERED',
  });
  assert.deepEqual(db.queries[0].params, [USER, 'contact', CONTACT]);
  assert.equal(db.events.length, 1);
  assert.deepEqual(db.events[0], {
    kind: 'decision_blocked', userId: USER, actorId: USER,
    scopeType: 'contact', scopeId: CONTACT, messageId: MESSAGE, fileId: FILE,
    details: { policy: { ...ALL, men: false }, classification: MEN,
      messageType: 'image', source: 'direct_socket_send',
      reasonCode: 'sender_content_filter', snapshotMoment: 'decision' },
  });
});

test('standalone uploads and scan-only requests use general preferences', async () => {
  for (const contextType of ['general', 'profile', 'scan', 'unknown', undefined]) {
    const db = database({ ...ALL, men: false }, ALL);
    await assert.rejects(send(db, { contextType }), { code: 'SENDER_CONTENT_FILTERED' });
    assert.deepEqual(db.queries[0].params, [USER, 'general', null]);
    assert.equal(db.events[0].scopeType, 'general');
    assert.equal(db.events[0].scopeId, null);
  }
});

test('scoped allowance respects the existing general-enforcement switch', async () => {
  const db = database({ ...ALL, men: false, enforceGeneralFilter: false }, ALL);
  assert.deepEqual(await send(db), ALL);
  db.general.enforceGeneralFilter = true;
  await assert.rejects(send(db), { code: 'SENDER_CONTENT_FILTERED' });
});

test('own contact preferences can further restrict an otherwise allowed sender', async () => {
  const db = database({ ...ALL, enforceGeneralFilter: true }, { ...ALL, men: false });
  await assert.rejects(send(db), { code: 'SENDER_CONTENT_FILTERED' });
  assert.equal(db.events[0].details.policy.men, false);
});

test('group member or creator fallback policy is resolved as a group scope', async () => {
  const db = database({ ...ALL, enforceGeneralFilter: true }, { ...ALL, men: false });
  await assert.rejects(send(db, { contextType: 'group' }), { code: 'SENDER_CONTENT_FILTERED' });
  assert.deepEqual(db.queries[0].params, [USER, 'group', CONTACT]);
  assert.equal(db.events[0].scopeType, 'group');
  db.scoped = null;
  assert.deepEqual(await send(db, { contextType: 'group' }), ALL);
});

test('a missing scope inherits the general filter; a missing user cannot send', async () => {
  const db = database({ ...ALL, men: false }, null);
  await assert.rejects(send(db, { contextId: null }), { code: 'SENDER_CONTENT_FILTERED' });
  assert.deepEqual(db.queries[0].params, [USER, 'general', null]);
  db.missing = true;
  await assert.rejects(getEffectiveSenderFilter(db, USER, 'chat', CONTACT), {
    status: 403, code: 'SENDER_USER_NOT_FOUND',
  });
});

test('cached or reused image approval cannot reuse a stale sender preference', async () => {
  const db = database({ ...ALL, enforceGeneralFilter: true });
  assert.deepEqual(await send(db, { source: 'cached_upload' }), ALL);
  db.general = { ...db.general, men: false };
  await assert.rejects(send(db, { source: 'reused_file_send' }), {
    code: 'SENDER_CONTENT_FILTERED',
  });
  assert.equal(db.queries.filter(q => q.sql.startsWith('SELECT u.content_filter')).length, 2);
  assert.equal(db.events[0].details.source, 'reused_file_send');
});

test('delayed delivery uses current policy and resolves its file audit link', async () => {
  const db = database({ ...ALL, men: false, enforceGeneralFilter: true });
  await assert.rejects(send(db, { fileId: undefined, fileUrl: '/photo.jpg', source: 'delayed_scan' }), {
    code: 'SENDER_CONTENT_FILTERED',
  });
  assert.equal(db.events[0].fileId, FILE);
  assert.equal(db.events[0].details.source, 'delayed_scan');
});

test('mixed images and images with unknown people cannot bypass a blocked category', async () => {
  for (const classification of [null, { category: 'people' },
    { uncertain: true }, { detectedCategories: ['women', 'men'] }]) {
    const db = database({ ...ALL, men: false });
    await assert.rejects(send(db, { classification }), { code: 'SENDER_CONTENT_FILTERED' });
  }
  const db = database({ ...ALL, men: false });
  const policy = await send(db, { classification: OBJECTS });
  assert.equal(policy.men, false);
  assert.equal(db.events.length, 0);
});

test('video checks both its category and the sender video preference', async () => {
  const byCategory = database({ ...ALL, men: false });
  await assert.rejects(send(byCategory, { type: 'video' }), { code: 'SENDER_CONTENT_FILTERED' });
  const byType = database({ ...ALL, video: false });
  await assert.rejects(send(byType, { type: 'video', classification: OBJECTS }), {
    code: 'SENDER_CONTENT_FILTERED',
  });
});

test('documents check visual classifications without newly restricting their text', async () => {
  const db = database({ ...ALL, text: false, men: false });
  await assert.rejects(send(db, { type: 'document' }), { code: 'SENDER_CONTENT_FILTERED' });
  assert.equal((await send(db, { type: 'document', classification: OBJECTS })).text, true);
  for (const classification of [null, {}, { detectedCategories: [] }]) {
    const before = db.queries.length;
    assert.equal(await send(db, { type: 'document', classification }), null);
    assert.equal(db.queries.length, before);
  }
});

test('text, audio, and stickers do not add an outgoing content restriction', async () => {
  const db = database({ ...ALL, text: false, men: false });
  for (const type of ['text', 'audio', 'sticker'])
    assert.equal(await send(db, { type }), null);
  assert.equal(db.queries.length, 0);
});


test('a transactional rejection carries an independent audit snapshot for persistence after rollback', async () => {
  const db = database({ ...ALL, men: false });
  const classification = { ...MEN, detectedCategories: [...MEN.detectedCategories] };
  let failure;
  try { await send(db, { classification }); } catch (error) { failure = error; }
  assert.equal(failure?.code, 'SENDER_CONTENT_FILTERED');
  assert.equal(failure.senderDecision.userId, USER);
  assert.equal(failure.senderDecision.policy.men, false);
  db.general.men = true;
  classification.detectedCategories[0] = 'women';
  assert.equal(failure.senderDecision.policy.men, false);
  assert.deepEqual(failure.senderDecision.classification.detectedCategories, ['men']);
});
