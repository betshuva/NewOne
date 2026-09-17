'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { contentAllowedByFilter, normalizeContentFilter } = require('../server/content-filter-policy');

const source = fs.readFileSync(require.resolve('../server/index.js'), 'utf8');
const all = { text: true, video: true, men: true, women: true, children: true, nonHumanImages: true };
const classification = { category: 'men', detectedCategories: ['men'], uncertain: false };
function section(start, end) {
  const from = source.indexOf(start);
  const to = source.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, start);
  return source.slice(from, to);
}
const uploadCode = section("    if (!scanResult?.pending && groupFilter &&", "    if (scanResult?.pending) {");
const delayedCode = section('        let deliveryFilter = null;', "        if (row.file_type === 'image' && row.to_user_id");

async function upload({ group = false, type = 'image', filter = { ...all, men: false }, pending = false,
  scanClassification = classification } = {}) {
  const calls = [];
  let approved = false;
  let response;
  const pool = { async query(sql) {
    assert.match(sql, /UPDATE stored_files SET moderation_status='approved'/);
    approved = true;
    return { rows: [] };
  } };
  const scope = {
    pool, allowed: { dbType: type }, file: { originalname: 'sample', size: 12 },
    req: { user: { id: 'sender' }, body: group ? { groupId: 'group' } : { toUserId: 'friend' }, ip: 'test' },
    res: { json(value) { response = value; return value; } },
    scanResult: { classification: scanClassification, pending },
    groupFilter: group ? filter : null,
    recipientPolicy: group ? null : { filter },
    storedInsert: { rows: [{ id: 'file' }] }, url: '/betshuva-app/uploads/sample',
    scanBotUpload: false, reportImageScan: false, reused: null,
    contentAllowedByFilter, normalizeContentFilter,
    recordFilterDecision: async () => {}, logActivity: () => {},
    notifyDestinationFilterBlock: async (db, details) => {
      assert.equal(db, pool);
      assert.equal(approved, true, 'guide receives only a safety-approved stored file');
      calls.push(details);
    },
  };
  await vm.runInNewContext(`(async () => { ${uploadCode} })()`, scope);
  return { response, calls };
}

for (const group of [false, true]) {
  for (const [type, key] of [['image', 'men'], ['video', 'video'], ['document', 'men']]) {
    test(`new ${type} upload reports ${group ? 'group' : 'private'} filter block after approval`, async () => {
      const result = await upload({ group, type, filter: { ...all, [key]: false } });
      assert.equal(result.response.status, 'rejected');
      assert.equal(result.response.forwardAllowed, true);
      assert.equal(result.calls.length, 1);
      const call = result.calls[0];
      assert.equal(call.userId, 'sender');
      assert.equal(group ? call.groupId : call.toUserId, group ? 'group' : 'friend');
      assert.equal(call.fileUrl, '/betshuva-app/uploads/sample');
      assert.equal(call.filter[key], false);
    });
  }
  test(`legacy text and landscape flags cannot reject ${group ? 'group' : 'private'} uploads`, async () => {
    for (const type of ['audio', 'document', 'image']) {
      const result = await upload({ group, type,
        filter: { ...all, text: false, nonHumanImages: false },
        scanClassification: { category: 'nonHumanImages', detectedCategories: ['nonHumanImages'] },
      });
      assert.equal(result.response, undefined);
      assert.equal(result.calls.length, 0);
    }
  });
  test(`allowed or pending ${group ? 'group' : 'private'} upload produces no false guide warning`, async () => {
    for (const options of [{ filter: all }, { pending: true }]) {
      const result = await upload({ group, ...options });
      assert.equal(result.response, undefined);
      assert.equal(result.calls.length, 0);
    }
  });
}

async function delayed({ group = false, permitted = true, allowed = false } = {}) {
  const notices = [];
  const rejected = [];
  let approved = false;
  const filter = { ...all, men: allowed };
  const pool = { async query(sql) {
    assert.match(sql, /UPDATE stored_files SET moderation_status='approved'/);
    approved = true;
    return { rows: [] };
  } };
  const scope = {
    pool, row: { user_id: 'sender', group_id: group ? 'group' : null,
      to_user_id: group ? null : 'friend', file_url: '/betshuva-app/uploads/sample',
      file_name: 'sample.jpg', file_type: 'image' },
    scanResult: { classification }, SCAN_BOT_ID: 'scan', outcomePersisted: false,
    getEffectiveRecipientFilter: async () => ({ filter, isContact: permitted }),
    getGroupContentFilter: async () => permitted ? filter : null,
    contentAllowedByFilter,
    completePending: async (_, callback) => callback(pool),
    recordFilterDecision: async () => {},
    relay: (...args) => rejected.push(args),
    notifyDestinationFilterBlock: async (_, details) => {
      assert.equal(approved, true);
      notices.push(details);
    },
  };
  await vm.runInNewContext(`(async () => { for (let attempt=0;attempt<1;attempt++) { ${delayedCode} } })()`, scope);
  return { notices, rejected };
}

for (const group of [false, true]) {
  test(`delayed ${group ? 'group' : 'private'} safety scan reports actual filter failure`, async () => {
    const result = await delayed({ group });
    assert.equal(result.notices.length, 1);
    assert.equal(result.notices[0].userId, 'sender');
    assert.equal(result.rejected.length, 1);
  });
  test(`delayed ${group ? 'group' : 'private'} contact/access failure is not mislabeled as filter warning`, async () => {
    const denied = await delayed({ group, permitted: false });
    assert.equal(denied.notices.length, 0);
    assert.equal(denied.rejected.length, 1);
    const allowed = await delayed({ group, allowed: true });
    assert.equal(allowed.notices.length, 0);
    assert.equal(allowed.rejected.length, 0);
  });
}
