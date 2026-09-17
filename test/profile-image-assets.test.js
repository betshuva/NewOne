'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const {
  PROFILE_IMAGE_ASSET_MANIFEST, createProfileAssetResolver, getProfileAssetMetadata,
} = require('../server/profile-image-assets');

const assetRoot = path.join(__dirname, '..', 'uploads', 'demo-historical');
const name = 'first-temple-man.webp';
const url = `/betshuva-app/uploads/demo-historical/${name}`;
const sha256 = bytes => crypto.createHash('sha256').update(bytes).digest('hex');

async function fixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'profile-assets-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const bytes = Buffer.from('reviewed application-owned portrait fixture');
  const file = path.join(root, name);
  await fs.writeFile(file, bytes);
  const manifest = { [name]: { sha256: sha256(bytes), categories: ['men'] } };
  return { root, file, bytes, manifest,
    resolve: createProfileAssetResolver({ assetRoot: root, manifest }) };
}

// Production uploads are not part of a source checkout. Run this integrity
// check explicitly on deployments; resolver behavior uses temporary fixtures.
test('reviewed catalog hashes match the actual assets and all supported aliases',
  { skip: process.env.RUN_PROFILE_ASSET_TESTS !== '1' }, async () => {
  const women = new Set(['beruriah.webp', 'sarah-schenirer.webp',
    'first-temple-woman.webp', 'second-temple-woman.webp', 'temple-women-group.webp']);
  assert.equal(Object.keys(PROFILE_IMAGE_ASSET_MANIFEST).length, 12);
  for (const [assetName, reviewed] of Object.entries(PROFILE_IMAGE_ASSET_MANIFEST)) {
    assert.equal(sha256(await fs.readFile(path.join(assetRoot, assetName))), reviewed.sha256);
    for (const suffix of ['', '?v=painted1']) {
      const metadata = await getProfileAssetMetadata(
        `/betshuva-app/uploads/demo-historical/${assetName}${suffix}`);
      assert.equal(metadata.moderation_status, 'approved', assetName);
      assert.equal(metadata.file_type, 'image');
      assert.equal(metadata.blocked, false);
      assert.equal(metadata.classification.uncertain, false);
      assert.deepEqual(metadata.classification.detectedCategories,
        [women.has(assetName) ? 'women' : 'men']);
    }
  }
});

test('only exact app-local URLs and the reviewed version alias are accepted', async t => {
  const { resolve } = await fixture(t);
  assert.equal((await resolve(url)).classification.category, 'men');
  assert.equal((await resolve(`${url}?v=painted1`)).classification.category, 'men');
  for (const other of [null, {}, '', `https://betshuva.com${url}`,
    `https://example.test${url}`, `//example.test${url}`, `${url}?v=other`,
    `${url}?v=painted1&other=1`, `${url}?v=painted1#fragment`, `${url}#fragment`,
    `${url} `, ` ${url}`, `${url}\n`, url.replace('first', '%66irst'),
    url.replace(name, `../${name}`), url.replace(name, `nested/${name}`),
    url.replace(name, 'unreviewed.webp'), url.replace('.webp', '.png'),
    url.replace('demo-historical', 'some-user-id')]) {
    assert.equal(await resolve(other), null, String(other));
  }
});

test('wrong and missing bytes cannot receive a reviewed classification', async t => {
  const { resolve, file, bytes } = await fixture(t);
  const other = Buffer.from(bytes);
  other[other.length - 1] ^= 1;
  await fs.writeFile(file, other);
  assert.equal(await resolve(url), null);
  await fs.unlink(file);
  assert.equal(await resolve(url), null);
  await fs.writeFile(file, bytes);
  assert.equal((await resolve(url)).classification.category, 'men');
});

test('cached approvals and rejections are invalidated by changed bytes', async t => {
  const { resolve, file, bytes } = await fixture(t);
  assert.equal((await resolve(url)).classification.category, 'men');
  assert.equal((await resolve(`${url}?v=painted1`)).classification.category, 'men');
  const before = await fs.stat(file);
  const altered = Buffer.from(bytes);
  altered[altered.length - 1] ^= 1;
  await fs.writeFile(file, altered);
  // Retain size and mtime to exercise the independent ctime/inode identity.
  await fs.utimes(file, before.atime, before.mtime);
  assert.equal(await resolve(url), null);
  assert.equal(await resolve(`${url}?v=painted1`), null);
  await fs.writeFile(file, bytes);
  assert.equal((await resolve(url)).classification.category, 'men');
});

test('an atomically replaced asset cannot retain the old cached approval', async t => {
  const { resolve, file, root, bytes } = await fixture(t);
  assert.ok(await resolve(url));
  const replacement = path.join(root, 'replacement');
  const altered = Buffer.from(bytes);
  altered[0] ^= 1;
  await fs.writeFile(replacement, altered);
  await fs.rename(replacement, file);
  assert.equal(await resolve(url), null);
});

test('file and directory symlinks remain untrusted even with identical approved bytes', async t => {
  const { resolve, file, root, bytes, manifest } = await fixture(t);
  assert.ok(await resolve(url));
  const target = path.join(root, 'other.webp');
  await fs.writeFile(target, bytes);
  await fs.unlink(file);
  await fs.symlink(target, file);
  assert.equal(await resolve(url), null);
  await fs.unlink(file);
  await fs.writeFile(file, bytes);
  const link = `${root}-link`;
  t.after(() => fs.unlink(link));
  await fs.symlink(root, link, 'dir');
  const throughLink = createProfileAssetResolver({ assetRoot: link, manifest });
  assert.equal(await throughLink(url), null);
});

test('empty, oversized and non-regular files are not classified', async t => {
  const { resolve, file } = await fixture(t);
  await fs.truncate(file, 0);
  assert.equal(await resolve(url), null);
  await fs.truncate(file, 10 * 1024 * 1024 + 1);
  assert.equal(await resolve(url), null);
  await fs.unlink(file);
  await fs.mkdir(file);
  assert.equal(await resolve(url), null);
});

test('resolver snapshots the reviewed manifest and returned metadata is immutable', async t => {
  const { resolve, manifest } = await fixture(t);
  const metadata = await resolve(url);
  manifest[name].categories[0] = 'women';
  manifest[name].sha256 = '0'.repeat(64);
  assert.equal((await resolve(url)).classification.category, 'men');
  assert.throws(() => { metadata.classification.category = 'women'; }, TypeError);
  assert.throws(() => metadata.classification.detectedCategories.push('women'), TypeError);
});

test('invalid manifest categories and filesystem names are rejected', () => {
  for (const manifest of [
    { '../escape.webp': { sha256: '0'.repeat(64), categories: ['men'] } },
    { [name]: { sha256: 'invalid', categories: ['men'] } },
    { [name]: { sha256: '0'.repeat(64), categories: [] } },
    { [name]: { sha256: '0'.repeat(64), categories: ['unknown'] } },
  ]) assert.throws(() => createProfileAssetResolver({ manifest }), TypeError);
});
