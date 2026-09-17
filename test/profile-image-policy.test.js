'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { DEFAULT_CONTENT_FILTER } = require('../server/content-filter-policy');
const { profileImageAllowed, projectProfileImages } = require('../server/profile-image-policy');

const all = { ...DEFAULT_CONTENT_FILTER };
const withoutWomen = { ...all, women: false, enforceGeneralFilter: false };
const url = '/betshuva-app/uploads/profile.jpg';
const approved = classification => ({
  public_url: url, file_type: 'image', moderation_status: 'approved',
  content_purged_at: null, classification,
});

test('profile images follow the viewer general choice even without enforcement enabled', () => {
  assert.equal(profileImageAllowed(url, withoutWomen, approved({ category: 'women' })), false);
  assert.equal(profileImageAllowed(url, withoutWomen, approved({ category: 'men' })), true);
  assert.equal(profileImageAllowed(url, withoutWomen, approved({ category: 'nonHumanImages' })), true);
  assert.equal(profileImageAllowed(url, all, approved({ category: 'women' })), true);
});

test('all detected categories must be allowed, including women in a mixed profile image', () => {
  assert.equal(profileImageAllowed(url, withoutWomen, approved({
    category: 'men', detectedCategories: ['men', 'women', 'people'],
  })), false);
  assert.equal(profileImageAllowed(url, withoutWomen, approved({
    category: 'men', detectedCategories: ['men', 'people'],
  })), true);
  assert.equal(profileImageAllowed(url, { ...all, children: false }, approved({
    detectedCategories: ['women', 'children'],
  })), false);
});

test('external and legacy unclassified photos require every people category', () => {
  for (const category of ['men', 'women', 'children']) {
    const filter = { ...all, [category]: false };
    for (const metadata of [undefined, approved(null), approved({}), approved({ uncertain: true })]) {
      assert.equal(profileImageAllowed(url, filter, metadata), false, category);
    }
  }
  assert.equal(profileImageAllowed('https://lh3.googleusercontent.com/legacy', withoutWomen), false);
  assert.equal(profileImageAllowed('https://lh3.googleusercontent.com/legacy', all), true);
  assert.equal(profileImageAllowed(url, all, approved(null)), true);
  assert.equal(profileImageAllowed(url, { ...all, nonHumanImages: false }, approved(null)), true);
});

test('pending, rejected, removed and non-image stored files never become profile images', () => {
  const good = approved({ category: 'men' });
  for (const metadata of [
    { ...good, moderation_status: 'pending' },
    { ...good, moderation_status: 'rejected' },
    { ...good, moderation_status: undefined },
    { ...good, content_purged_at: '2026-09-17T00:00:00Z' },
    { ...good, blocked: true },
    { ...good, file_type: 'video' },
  ]) assert.equal(profileImageAllowed(url, all, metadata), false);
});

test('only exact builtin assets have trusted categories; emoji avatars remain available', () => {
  const guide = '/betshuva-app/assets/assets/guide/israel-profile-20260907.png';
  const logo = '/betshuva-app/assets/assets/guide/safe-information-ai.png';
  assert.equal(profileImageAllowed(guide, withoutWomen), true);
  assert.equal(profileImageAllowed(guide, { ...all, men: false }), false);
  assert.equal(profileImageAllowed(logo, { ...all, men: false, women: false }), true);
  assert.equal(profileImageAllowed(logo, { ...all, nonHumanImages: false }), true);
  assert.equal(profileImageAllowed(`https://example.test${logo}`, withoutWomen), false);
  assert.equal(profileImageAllowed(`${logo}?different-image`, withoutWomen), false);
  assert.equal(profileImageAllowed('emoji:🌻', { ...all, nonHumanImages: false, women: false }), true);
  assert.equal(profileImageAllowed(null, all), false);
});

function fakePool(filter, files) {
  return {
    filter, calls: [],
    async query(sql, params) {
      this.calls.push({ sql, params });
      if (sql.startsWith('SELECT content_filter')) return { rows: [{ content_filter: this.filter }] };
      if (sql.includes('FROM stored_files'))
        return { rows: files.filter(file => params[0].includes(file.public_url)) };
      throw new Error('Unexpected query');
    },
  };
}

test('projection batches duplicate URLs, preserves row fields and never mutates source rows', async () => {
  const external = 'https://lh3.googleusercontent.com/legacy';
  const pool = fakePool(withoutWomen, [approved({ category: 'men' })]);
  const rows = [
    { id: 'friend-1', name: 'one', profile_pic_url: url, phone: null, filter_override: all },
    { id: 'friend-2', name: 'two', profile_pic_url: url },
    { id: 'friend-3', name: 'three', profile_pic_url: external, gender: 'male' },
    { id: 'friend-4', profile_pic_url: 'emoji:🌻' },
  ];
  const projected = await projectProfileImages(pool, 'viewer', rows);
  assert.equal(projected[0].profile_pic_url, url);
  assert.equal(projected[1].profile_pic_url, url);
  assert.deepEqual(projected[2], { ...rows[2], profile_pic_url: null });
  assert.equal(projected[3].profile_pic_url, 'emoji:🌻');
  assert.equal(rows[2].profile_pic_url, external);
  assert.equal(pool.calls.length, 2, 'one preference query and one batched file query');
  assert.deepEqual(pool.calls[0].params, ['viewer']);
  assert.deepEqual(pool.calls[1].params, [[url, external]]);
});

test('changing general preferences takes effect on the next response for existing contacts', async () => {
  const pool = fakePool(all, [approved({ category: 'women' })]);
  const rows = [{ id: 'saved-friend', saved: true, profile_pic_url: url, filter_override: all }];
  assert.equal((await projectProfileImages(pool, 'viewer', rows))[0].profile_pic_url, url);
  pool.filter = withoutWomen;
  assert.equal((await projectProfileImages(pool, 'viewer', rows))[0].profile_pic_url, null);
  pool.filter = all;
  assert.equal((await projectProfileImages(pool, 'viewer', rows))[0].profile_pic_url, url);
});

test('seller aliases and group pictures use the same policy without relying on user IDs', async () => {
  const pool = fakePool(withoutWomen, [approved({ category: 'women' })]);
  const rows = [{ id: 'listing', seller_pic: url, title: 'item' }];
  assert.deepEqual(await projectProfileImages(pool, 'viewer', rows, { fields: ['seller_pic'] }),
    [{ ...rows[0], seller_pic: null }]);
  assert.deepEqual(await projectProfileImages(pool, 'viewer', [{ id: 'group', profile_pic_url: url }]),
    [{ id: 'group', profile_pic_url: null }]);
});

test('empty or emoji-only responses need no classification query', async () => {
  const pool = { query: async () => assert.fail('no raster images to project') };
  for (const rows of [[], [{ id: 'friend' }], [{ profile_pic_url: null }], [{ profile_pic_url: 'emoji:🌻' }]])
    assert.deepEqual(await projectProfileImages(pool, 'viewer', rows), rows);
});

test('missing viewer records never expose unclassified images', async () => {
  const pool = { query: async () => ({ rows: [] }) };
  assert.deepEqual(await projectProfileImages(pool, 'deleted-viewer', [{ profile_pic_url: url }]),
    [{ profile_pic_url: null }]);
});
