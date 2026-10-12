'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const sharp = require('sharp');
const { ARTWORK_SOURCE, extractKeyboardEmoji, createKeyboardEmojiArtworkLoader } =
  require('../server/unicode-emoji-artwork');
const approvedCatalog = require('../flutter_app/assets/twemoji/emoji_allowlist.json');
const manifest = require('../server/keyboard-emoji-artwork-manifest.json');
const fixtureDirectory = path.join(__dirname, 'fixtures', 'keyboard-emoji-artwork');

async function cacheFor(t) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'betshuva-emoji-test-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  return directory;
}

function fixtureFetch(seen = []) {
  return async (url, options) => {
    seen.push({ url, options });
    const filename = new URL(url).pathname.split('/').at(-1);
    assert.match(filename, /^[0-9a-f]+(?:-[0-9a-f]+)*\.svg$/);
    const bytes = await fs.readFile(path.join(fixtureDirectory, filename));
    return new Response(bytes, { headers: { 'content-type': 'image/svg+xml', 'content-length': String(bytes.length) } });
  };
}

const itemFor = emoji => extractKeyboardEmoji(emoji)[0];

test('ordinary Hebrew, formatting markers, digits and copyright prose need no visual emoji scan', () => {
  const text = 'שלום 123 #* © ® ™ ©︎ [[bt-emoji:001]][[bt-style:fg=1976D2]]טקסט[[/bt-style]]';
  assert.deepEqual(extractKeyboardEmoji(text), []);
  assert.deepEqual(extractKeyboardEmoji('©️'), [{ emoji: '©️', code: 'a9', knownApproved: false }]);
});

test('every approved catalog glyph and valid skin variant avoids an additional provider call', () => {
  for (const item of approvedCatalog) {
    const found = extractKeyboardEmoji(item.emoji);
    assert.equal(found.length, 1, item.emoji);
    assert.equal(found[0].knownApproved, true, item.emoji);
    assert.ok(Object.hasOwn(manifest.assets, found[0].code));
    if (/\p{Emoji_Modifier_Base}/u.test(item.emoji)) {
      const base = item.emoji.replace(/[\uFE0E\uFE0F]/gu, '');
      for (const skin of ['🏻', '🏼', '🏽', '🏾', '🏿'])
        assert.equal(itemFor(base + skin).knownApproved, true, base + skin);
    }
  }
});

test('full graphemes preserve ZWJ, skin, regional flags, keycaps and tag flags', () => {
  const input = '👨‍👩‍👧‍👦 🫱🏻‍🫲🏿 🇮🇱 1️⃣ #️⃣ 🏴\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}';
  const found = extractKeyboardEmoji(input);
  assert.equal(found.length, 6);
  assert.deepEqual(found.map(item => item.code), [
    '1f468-200d-1f469-200d-1f467-200d-1f466',
    '1faf1-1f3fb-200d-1faf2-1f3ff', '1f1ee-1f1f1', '31-20e3', '23-20e3',
    '1f3f4-e0067-e0062-e0065-e006e-e0067-e007f',
  ]);
  assert.ok(found.every(item => !item.knownApproved));
  assert.deepEqual(found.map(item => item.emoji), input.split(' '));
});

test('canonical aliases share one inspection while retaining the first full original grapheme', () => {
  const text = 'שלום 😀 😀 ❤ ❤️ ☀︎ ☀️ 👍🏽 👍🏽';
  const found = extractKeyboardEmoji(text);
  assert.deepEqual(found.map(item => item.emoji), ['😀', '❤', '☀︎', '👍🏽']);
  assert.deepEqual(found.map(item => item.code), ['1f600', '2764', '2600', '1f44d-1f3fd']);
  assert.ok(found.every(item => item.knownApproved));
  assert.equal(text, 'שלום 😀 😀 ❤ ❤️ ☀︎ ☀️ 👍🏽 👍🏽');
});

test('unknown joins, invalid skin modifiers and repeated selectors gain no approved alias', async t => {
  const loader = createKeyboardEmojiArtworkLoader({ cacheDirectory: await cacheFor(t),
    fetch: () => assert.fail('unsupported sequence must not request artwork') });
  for (const emoji of ['😀‍😀', '👋🏻🏽', '💖🏻', '😀️️', '👍🏽️']) {
    const item = itemFor(emoji);
    assert.equal(item.emoji, emoji); assert.equal(item.knownApproved, false);
    await assert.rejects(loader(item), error => error.code === 'UNSUPPORTED_EMOJI');
  }
});

test('canonical ZWJ selector aliases retain the complete official composition', () => {
  for (const emoji of ['🏳️‍🌈', '🏳‍🌈'])
    assert.equal(itemFor(emoji).code, '1f3f3-fe0f-200d-1f308');
  for (const emoji of ['❤️‍🔥', '❤‍🔥']) {
    const item = itemFor(emoji);
    assert.equal(item.code, '2764-fe0f-200d-1f525');
    assert.equal(item.knownApproved, false);
  }
});

test('the full pinned artwork catalog resolves as whole graphemes on the deployed Node runtime', () => {
  for (const code of Object.keys(manifest.assets)) {
    let emoji = String.fromCodePoint(...code.split('-').map(part => parseInt(part, 16)));
    if (['a9', 'ae', '2122'].includes(code)) emoji += '\uFE0F';
    const found = extractKeyboardEmoji(emoji);
    assert.equal(found.length, 1, code);
    assert.equal(found[0].emoji, emoji, code);
    assert.ok(Object.hasOwn(manifest.assets, found[0].code), code);
  }
});

test('loader renders a verified pinned SVG to a bounded canonical PNG and sends no message text', async t => {
  const seen = [], loader = createKeyboardEmojiArtworkLoader({ cacheDirectory: await cacheFor(t), fetch: fixtureFetch(seen) });
  const png = await loader(itemFor('😉'));
  const metadata = await sharp(png).metadata();
  assert.equal(metadata.format, 'png'); assert.equal(metadata.width, 128); assert.equal(metadata.height, 128);
  assert.ok(png.length < 128 * 1024);
  assert.equal(seen.length, 1);
  assert.equal(seen[0].url, `https://raw.githubusercontent.com/jdecked/twemoji/${ARTWORK_SOURCE.commit}/assets/svg/1f609.svg`);
  assert.equal(seen[0].options.redirect, 'error'); assert.equal(seen[0].options.credentials, 'omit');
  assert.ok(seen[0].options.signal instanceof AbortSignal);
});

test('actual family, flag and keycap SVGs remain whole when rasterized', async t => {
  const loader = createKeyboardEmojiArtworkLoader({ cacheDirectory: await cacheFor(t), fetch: fixtureFetch() });
  for (const emoji of ['👨‍👩‍👧‍👦', '🇮🇱', '1️⃣']) {
    const png = await loader(itemFor(emoji)), metadata = await sharp(png).metadata();
    assert.equal(metadata.format, 'png'); assert.equal(metadata.width, 128); assert.equal(metadata.height, 128);
  }
});

test('a complete private SVG bundle is used without any request-triggered network call', async t => {
  const directory = await cacheFor(t);
  await fs.mkdir(path.join(directory, 'svg'));
  await fs.copyFile(path.join(fixtureDirectory, '1f609.svg'), path.join(directory, 'svg', '1f609.svg'));
  const loader = createKeyboardEmojiArtworkLoader({ cacheDirectory: directory,
    fetch: () => assert.fail('a bundled SVG must not trigger a download') });
  assert.equal((await sharp(await loader(itemFor('😉'))).metadata()).format, 'png');
});

test('concurrent loads share one download and cached buffers cannot be mutated by callers', async t => {
  const seen = [], loader = createKeyboardEmojiArtworkLoader({ cacheDirectory: await cacheFor(t), fetch: fixtureFetch(seen) });
  const [first, second] = await Promise.all([loader(itemFor('😉')), loader(itemFor('😉'))]);
  assert.equal(seen.length, 1); assert.deepEqual(first, second); assert.notEqual(first, second);
  const expected = Buffer.from(second); first.fill(0);
  assert.deepEqual(await loader(itemFor('😉')), expected);
});

test('memory and PNG file cache limits evict older renders while retaining pinned SVG sources', async t => {
  const directory = await cacheFor(t);
  let renders = 0;
  const loader = createKeyboardEmojiArtworkLoader({ cacheDirectory: directory, fetch: fixtureFetch(),
    maxCacheEntries: 2, maxFileCacheEntries: 2,
    render: async () => { renders++; return sharp({ create: { width: 2, height: 2, channels: 3,
      background: 'white' } }).png().toBuffer(); } });
  for (const emoji of ['😉', '😞', '🖕']) await loader(itemFor(emoji));
  assert.equal((await fs.readdir(path.join(directory, 'png'))).filter(name => name.endsWith('.png')).length, 2);
  assert.equal((await fs.readdir(path.join(directory, 'svg'))).length, 3);
  assert.equal(renders, 3);
  await loader(itemFor('😉')); assert.equal(renders, 4);
});

test('a validated disk PNG is reusable by a new loader without a fetch or renderer call', async t => {
  const directory = await cacheFor(t);
  const first = createKeyboardEmojiArtworkLoader({ cacheDirectory: directory, fetch: fixtureFetch() });
  const expected = await first(itemFor('😉'));
  const next = createKeyboardEmojiArtworkLoader({ cacheDirectory: directory,
    fetch: () => assert.fail('disk cache should not fetch'), render: () => assert.fail('disk cache should not render') });
  assert.deepEqual(await next(itemFor('😉')), expected);
});

test('corrupted cached PNG data is regenerated from the verified source rather than returned', async t => {
  const directory = await cacheFor(t);
  const first = createKeyboardEmojiArtworkLoader({ cacheDirectory: directory, fetch: fixtureFetch() });
  const expected = await first(itemFor('😉'));
  await fs.writeFile(path.join(directory, 'png', '1f609.png'), Buffer.from('corrupt PNG'));
  const next = createKeyboardEmojiArtworkLoader({ cacheDirectory: directory,
    fetch: () => assert.fail('verified local SVG should repair PNG cache') });
  assert.deepEqual(await next(itemFor('😉')), expected);
});

test('arbitrary URLs, traversal codes and mismatched emoji/code pairs never reach the fetcher', async t => {
  const loader = createKeyboardEmojiArtworkLoader({ cacheDirectory: await cacheFor(t),
    fetch: () => assert.fail('invalid input must not fetch') });
  for (const item of [
    { emoji: '😉', code: '../1f609' }, { emoji: '😉', code: 'https://example.test/x' },
    { emoji: '😉', code: '1f595' }, { emoji: 'hello😉', code: '1f609' },
    { emoji: '😉', code: 'constructor' }, { code: '1f609' },
  ]) await assert.rejects(loader(item), error => error.code === 'UNSUPPORTED_EMOJI');
});

test('download failures, redirects and wrong pinned bytes are unavailable rather than approved', async t => {
  const directory = await cacheFor(t);
  const fetches = [
    async () => { throw new Error('offline'); },
    async () => new Response('not found', { status: 404 }),
    async () => ({ ok: true, redirected: true, url: 'https://other.test/1f609.svg' }),
    async () => new Response('<svg xmlns="http://www.w3.org/2000/svg"/>'),
    async () => new Response(Buffer.alloc(65537), { headers: { 'content-length': '65537' } }),
    async () => new Response(Buffer.alloc(65537)),
  ];
  for (const fetch of fetches) {
    const loader = createKeyboardEmojiArtworkLoader({ cacheDirectory: directory, fetch,
      render: () => assert.fail('invalid SVG must not be rendered') });
    await assert.rejects(loader(itemFor('😉')), error => error.code === 'EMOJI_ARTWORK_UNAVAILABLE');
  }
  assert.deepEqual(await fs.readdir(directory), []);
});

test('a corrupt private SVG fails integrity checks without pretending a scan occurred', async t => {
  const directory = await cacheFor(t);
  await fs.mkdir(path.join(directory, 'svg'));
  await fs.writeFile(path.join(directory, 'svg', '1f609.svg'), '<svg/>');
  const loader = createKeyboardEmojiArtworkLoader({ cacheDirectory: directory,
    fetch: () => assert.fail('corrupt staged source should fail explicitly'),
    render: () => assert.fail('corrupt source must not render') });
  await assert.rejects(loader(itemFor('😉')), error => error.code === 'EMOJI_ARTWORK_UNAVAILABLE');
});

test('hanging download and rendering operations have bounded explicit failure', async t => {
  const download = createKeyboardEmojiArtworkLoader({ cacheDirectory: await cacheFor(t),
    downloadTimeoutMs: 20, fetch: () => new Promise(() => {}) });
  await assert.rejects(download(itemFor('😉')), error => error.code === 'EMOJI_ARTWORK_UNAVAILABLE' && error.reasonCode === 'timeout');
  const render = createKeyboardEmojiArtworkLoader({ cacheDirectory: await cacheFor(t),
    renderTimeoutMs: 20, fetch: fixtureFetch(), render: () => new Promise(() => {}) });
  await assert.rejects(render(itemFor('😉')), error => error.code === 'EMOJI_ARTWORK_UNAVAILABLE' && error.reasonCode === 'timeout');
});

test('inflight artwork work is bounded while duplicate requests still share the existing task', async t => {
  let release;
  const blocked = new Promise(resolve => { release = resolve; });
  const fetch = fixtureFetch();
  const loader = createKeyboardEmojiArtworkLoader({ cacheDirectory: await cacheFor(t), maxInflight: 1,
    fetch: async (url, options) => { await blocked; return fetch(url, options); } });
  const first = loader(itemFor('😉')), duplicate = loader(itemFor('😉'));
  await assert.rejects(loader(itemFor('😞')), error => error.code === 'EMOJI_ARTWORK_UNAVAILABLE' && error.reasonCode === 'artwork_busy');
  release(); assert.deepEqual(await first, await duplicate);
});

test('renderer output must be a bounded static PNG, not arbitrary bytes or oversized pixels', async t => {
  const hugePng = await sharp({ create: { width: 129, height: 1, channels: 3,
    background: 'white' } }).png().toBuffer();
  for (const output of [Buffer.from('not PNG'), Buffer.alloc(128 * 1024 + 1), hugePng]) {
    const loader = createKeyboardEmojiArtworkLoader({ cacheDirectory: await cacheFor(t), fetch: fixtureFetch(),
      render: async () => output });
    await assert.rejects(loader(itemFor('😉')), error => error.code === 'EMOJI_ARTWORK_UNAVAILABLE');
  }
});
