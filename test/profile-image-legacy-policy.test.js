'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { DEFAULT_CONTENT_FILTER } = require('../server/content-filter-policy');
const { projectProfileImages } = require('../server/profile-image-policy');

const man = '/betshuva-app/uploads/demo-historical/first-temple-man.webp?v=painted1';
const woman = '/betshuva-app/uploads/demo-historical/first-temple-woman.webp?v=painted1';
const unknown = 'https://example.test/unclassified.jpg';
const reviewed = category => ({ file_type: 'image', moderation_status: 'approved',
  content_purged_at: null, blocked: false,
  classification: { category, detectedCategories: [category], uncertain: false } });
const asset = async url => url === man ? reviewed('men')
  : url === woman ? reviewed('women') : null;
function poolFor(filter, files = []) {
  return { query: async sql => sql.startsWith('SELECT content_filter')
    ? { rows: [{ content_filter: filter }] } : { rows: files } };
}
const rows = [{ name: 'Ben-Ori', profile_pic_url: man },
  { name: 'Abigail', profile_pic_url: woman }, { name: 'Unknown', profile_pic_url: unknown }];

test('reviewed legacy male portrait appears while women and unclassified photos remain hidden', async () => {
  const pool = poolFor({ ...DEFAULT_CONTENT_FILTER, women: false, enforceGeneralFilter: false });
  const output = await projectProfileImages(pool, 'viewer', rows, { resolveAsset: asset });
  assert.deepEqual(output.map(row => row.profile_pic_url), [man, null, null]);
  assert.equal(output[0].name, 'Ben-Ori');
  assert.equal(rows[1].profile_pic_url, woman, 'the stored profile is not changed');
});

test('reviewed portraits still obey the inverse preference and group/seller field selection', async () => {
  const pool = poolFor({ ...DEFAULT_CONTENT_FILTER, men: false });
  const input = rows.map(row => ({ seller_pic: row.profile_pic_url }));
  const output = await projectProfileImages(pool, 'viewer', input,
    { fields: ['seller_pic'], resolveAsset: asset });
  assert.deepEqual(output.map(row => row.seller_pic), [null, woman, null]);
});

test('every existing stored-file decision takes precedence over reviewed legacy metadata', async () => {
  const filter = { ...DEFAULT_CONTENT_FILTER, women: false };
  for (const metadata of [
    { ...reviewed('men'), moderation_status: 'pending' },
    { ...reviewed('men'), moderation_status: 'rejected' },
    { ...reviewed('men'), content_purged_at: new Date() },
    { ...reviewed('men'), blocked: true },
    reviewed('women'),
    { ...reviewed('men'), classification: null },
  ]) {
    const pool = poolFor(filter, [{ public_url: man, ...metadata }]);
    const output = await projectProfileImages(pool, 'viewer', [rows[0]], {
      resolveAsset: async () => assert.fail('an existing scan must never be replaced'),
    });
    assert.equal(output[0].profile_pic_url, null);
  }
});

test('failed byte verification leaves the legacy portrait subject to the unknown-image policy', async () => {
  const pool = poolFor({ ...DEFAULT_CONTENT_FILTER, women: false });
  const output = await projectProfileImages(pool, 'viewer', [rows[0]],
    { resolveAsset: async () => null });
  assert.equal(output[0].profile_pic_url, null);
});

test('duplicate legacy image URLs are resolved once per response', async () => {
  let calls = 0;
  const pool = poolFor({ ...DEFAULT_CONTENT_FILTER, women: false });
  const output = await projectProfileImages(pool, 'viewer', [rows[0], rows[0]], {
    resolveAsset: async url => { calls++; return asset(url); },
  });
  assert.equal(calls, 1);
  assert.deepEqual(output.map(row => row.profile_pic_url), [man, man]);
});
