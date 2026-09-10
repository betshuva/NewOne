'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const sharp = require('sharp');
const { loadMarketplaceImages } = require('../server/marketplace-images');

const OWNER = '11111111-1111-4111-8111-111111111111';
const LISTING = '22222222-2222-4222-8222-222222222222';
const OTHER = '33333333-3333-4333-8333-333333333333';
const PUBLIC_BASE = '/betshuva-app/uploads/';

async function root(t) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'marketplace-images-test-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  return directory;
}

function row(overrides = {}) {
  return { listing_id: LISTING, listing_owner_id: OWNER, stored_file_id: OTHER,
    file_owner_id: OWNER, storage_path: `${OWNER}/photo.png`,
    public_url: `${PUBLIC_BASE}${OWNER}/photo.png`, file_type: 'image', file_size: 500,
    moderation_status: 'approved', content_purged_at: null, released_at: null,
    status: 'active', expires_at: Date.now() + 60000, ...overrides };
}

function database(rows, { audience = true, userExists = true } = {}) {
  const calls = [];
  return { calls, async query(sql, args) {
    calls.push({ sql, args });
    if (sql.includes('FROM users')) {
      assert.deepEqual(args, [OWNER]);
      assert.match(sql, /birth_date <= CURRENT_DATE - INTERVAL '18 years'/);
      return { rows: userExists ? [{ allowed: audience }] : [] };
    }
    assert.match(sql, /l\.status='active'/);
    assert.match(sql, /l\.expires_at > now\(\)/);
    assert.match(sql, /sf\.moderation_status='approved'/);
    assert.match(sql, /sf\.user_id=l\.user_id/);
    assert.match(sql, /sf\.content_purged_at IS NULL/);
    assert.match(sql, /l\.id=ANY\(\$1::uuid\[\]\)/);
    assert.ok(args[0].length <= 20);
    return { rows: rows.filter(item => args[0].includes(item.listing_id) &&
      item.status === 'active' && item.expires_at > Date.now()) };
  } };
}

async function png(width = 30) {
  return sharp({ create: { width, height: 20, channels: 3, background: '#88ccff' } })
    .withMetadata().png().toBuffer();
}

async function writeImage(directory, item, bytes = undefined) {
  const target = path.join(directory, item.storage_path);
  await fs.mkdir(path.dirname(target), { recursive: true });
  await fs.writeFile(target, bytes || await png());
}

test('loads real image bytes, strips metadata, resizes, and retains only listing labels', async t => {
  const uploadRoot = await root(t);
  const first = row();
  const second = row({ listing_id: OTHER, storage_path: `${OWNER}/second.png`,
    public_url: `${PUBLIC_BASE}${OWNER}/second.png` });
  await writeImage(uploadRoot, first, await png(2000));
  await writeImage(uploadRoot, second);
  const result = await loadMarketplaceImages(database([first, second]), OWNER,
    [LISTING, OTHER], { uploadRoot });
  assert.deepEqual(result.map(item => item.listing_id), [LISTING, OTHER]);
  assert.deepEqual(Object.keys(result[0]), ['listing_id', 'image_url']);
  const metadata = await sharp(Buffer.from(result[0].image_url.split(',')[1], 'base64')).metadata();
  assert.equal(metadata.format, 'jpeg');
  assert.equal(metadata.width, 1280);
  assert.equal(metadata.exif, undefined);
  assert.equal(metadata.icc, undefined);
});

test('minor, unknown age and nonexistent user never read listing images', async () => {
  for (const config of [{ audience: false }, { audience: null }, { userExists: false }]) {
    const db = database([row()], config);
    assert.deepEqual(await loadMarketplaceImages(db, OWNER, [LISTING]), []);
    assert.equal(db.calls.length, 1);
  }
});

test('invalid ids and zero image budget perform no database or filesystem access', async () => {
  const db = database([row()]);
  assert.deepEqual(await loadMarketplaceImages(db, OWNER, ['../../../secret', null, {}]), []);
  assert.deepEqual(await loadMarketplaceImages(db, OWNER, [LISTING], { maxImages: 0 }), []);
  assert.equal(db.calls.length, 0);
});

test('expired and inactive listings yield no image even when its file exists', async t => {
  const uploadRoot = await root(t);
  await writeImage(uploadRoot, row());
  const db = database([row({ expires_at: Date.now() - 1 }), row({ status: 'sold' })]);
  assert.deepEqual(await loadMarketplaceImages(db, OWNER, [LISTING], { uploadRoot }), []);
});

test('clamps the output to eight images and deduplicates repeated listing photos', async t => {
  const uploadRoot = await root(t);
  const rows = [];
  for (let i = 0; i < 12; i++) {
    const item = row({ storage_path: `${OWNER}/${i}.png`, public_url: `${PUBLIC_BASE}${OWNER}/${i}.png` });
    await writeImage(uploadRoot, item);
    rows.push(item, item);
  }
  const result = await loadMarketplaceImages(database(rows), OWNER, [LISTING, LISTING],
    { uploadRoot, maxImages: 100 });
  assert.equal(result.length, 8);
});

test('rejects foreign or arbitrary image URLs, private uploads, rejected and purged images without fetch', async t => {
  const uploadRoot = await root(t);
  const rows = [
    row({ public_url: 'https://evil.example/image.png', released_at: new Date() }),
    row({ public_url: 'http://127.0.0.1/private', released_at: new Date() }),
    row({ public_url: '/uploads/private.png' }),
    row({ public_url: `${PUBLIC_BASE}${OWNER}/../secret.png`, storage_path: `${OWNER}/../secret.png` }),
    row({ file_owner_id: OTHER }), row({ moderation_status: 'pending' }),
    row({ moderation_status: 'rejected' }), row({ content_purged_at: new Date() }),
    row({ stored_file_id: null }),
  ];
  const result = await loadMarketplaceImages(database(rows), OWNER, [LISTING], {
    uploadRoot, fetchImpl() { assert.fail('Untrusted images must never reach the network'); },
  });
  assert.deepEqual(result, []);
});

test('skips missing, corrupt, oversize and symlink images and continues to a valid photo', async t => {
  const uploadRoot = await root(t);
  const valid = row({ storage_path: `${OWNER}/valid.png`, public_url: `${PUBLIC_BASE}${OWNER}/valid.png` });
  await writeImage(uploadRoot, valid);
  const corrupt = row({ storage_path: `${OWNER}/corrupt.png`, public_url: `${PUBLIC_BASE}${OWNER}/corrupt.png` });
  await writeImage(uploadRoot, corrupt, Buffer.from('<svg>untrusted external-reference SVG</svg>'));
  const oversized = row({ storage_path: `${OWNER}/large.png`, public_url: `${PUBLIC_BASE}${OWNER}/large.png` });
  await fs.writeFile(path.join(uploadRoot, oversized.storage_path), Buffer.alloc(10 * 1024 * 1024 + 1));
  const symlink = row({ storage_path: `${OWNER}/link.png`, public_url: `${PUBLIC_BASE}${OWNER}/link.png` });
  await fs.symlink(path.join(uploadRoot, valid.storage_path), path.join(uploadRoot, symlink.storage_path));
  const result = await loadMarketplaceImages(database([row(), corrupt, oversized, symlink, valid]),
    OWNER, [LISTING], { uploadRoot, fetchImpl() { assert.fail('No cloud-released files'); } });
  assert.equal(result.length, 1);
});

test('known server-generated demo images work without a stored_file row, other demo paths do not', async t => {
  const uploadRoot = await root(t);
  const demo = row({ stored_file_id: null, storage_path: 'demo-listings/bike-photo-1.jpg',
    public_url: `${PUBLIC_BASE}demo-listings/bike-photo-1.jpg` });
  await writeImage(uploadRoot, demo);
  const arbitrary = row({ stored_file_id: null, storage_path: 'demo-listings/private.png',
    public_url: `${PUBLIC_BASE}demo-listings/private.png` });
  await writeImage(uploadRoot, arbitrary);
  assert.equal((await loadMarketplaceImages(database([demo, arbitrary]), OWNER, [LISTING],
    { uploadRoot })).length, 1);
});

test('restores missing registered released images only from fixed app origin with deadline and redirects disabled', async t => {
  const uploadRoot = await root(t);
  const item = row({ released_at: new Date() });
  const bytes = await png();
  const calls = [];
  const result = await loadMarketplaceImages(database([item]), OWNER, [LISTING], {
    uploadRoot, async fetchImpl(url, options) {
      calls.push(url);
      assert.equal(url, `https://betshuva.com${item.public_url}`);
      assert.equal(options.redirect, 'error');
      assert.ok(options.signal instanceof AbortSignal);
      assert.equal(options.headers, undefined);
      return new Response(bytes, { headers: { 'content-length': bytes.length } });
    },
  });
  assert.equal(calls.length, 1);
  assert.equal(result.length, 1);
});

test('remote redirect, unavailable response and timeout fail gracefully', async t => {
  const uploadRoot = await root(t);
  for (const fail of [
    async () => { throw new TypeError('Redirect disallowed'); },
    async () => new Response(null, { status: 503 }),
    async () => { throw new DOMException('Timeout', 'TimeoutError'); },
  ]) {
    const result = await loadMarketplaceImages(database([row({ released_at: new Date() })]),
      OWNER, [LISTING], { uploadRoot, fetchImpl: fail });
    assert.deepEqual(result, []);
  }
});

test('remote declared and streamed oversize bodies are stopped before image decoding', async t => {
  const uploadRoot = await root(t);
  for (const declared of [true, false]) {
    let cancelled = false;
    const body = new ReadableStream({
      start(controller) { controller.enqueue(new Uint8Array(10 * 1024 * 1024 + 1)); },
      cancel() { cancelled = true; },
    });
    const result = await loadMarketplaceImages(database([row({ released_at: new Date() })]),
      OWNER, [LISTING], { uploadRoot, fetchImpl: async () => new Response(body,
        { headers: declared ? { 'content-length': String(10 * 1024 * 1024 + 1) } : {} }) });
    assert.deepEqual(result, []);
    assert.equal(cancelled, true);
  }
});

test('the total loading deadline stops repeated unavailable cloud images', async t => {
  const uploadRoot = await root(t);
  const start = Date.now();
  let now = start;
  t.mock.method(Date, 'now', () => now);
  let calls = 0;
  const rows = Array.from({ length: 8 }, (_, i) => row({
    storage_path: `${OWNER}/${i}.png`, public_url: `${PUBLIC_BASE}${OWNER}/${i}.png`,
    released_at: new Date(), expires_at: start + 60000,
  }));
  const result = await loadMarketplaceImages(database(rows), OWNER, [LISTING], {
    uploadRoot, async fetchImpl() {
      calls++;
      now += 3000;
      throw new DOMException('Timeout', 'TimeoutError');
    },
  });
  assert.deepEqual(result, []);
  assert.equal(calls, 4);
});
