'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');
const express = require('express');
const sharp = require('sharp');
const { createExpressionLibrary } = require('../server/expression-catalog');
const { inlineEmojiModerationText, inlineEmojiPlainText } = require('../server/inline-custom-emoji');

const libraryRoot = path.resolve(__dirname, '..', 'expression-library');
const prefix = 'cream-contrast-';
const mintPrefix = 'cream-mint-';
const strongGreenPrefix = 'strong-green-';
const strongRedPrefix = 'strong-red-';
const isRecentExpression = item => [prefix, mintPrefix, strongGreenPrefix, strongRedPrefix]
  .some(value => item.file.startsWith(value));
const ids = Array.from({ length: 64 }, (_, index) => index + 167);
const sha256 = bytes => crypto.createHash('sha256').update(bytes).digest('hex');

async function registry() {
  return JSON.parse(await fs.readFile(path.join(libraryRoot, 'emoji-registry.json'), 'utf8'));
}

test('cream, mint and colored expressions retain stable IDs and every previous registry entry', async () => {
  const { items } = await registry();
  const original = items.filter(item => item.id <= 166);
  assert.equal(original.length, 65);
  assert.equal(sha256(JSON.stringify(original)),
    'c8e3dbbcbc84edb898f7a56762e5bd1eefdf479b141fbc830f64e6334d7c8599');
  const beforeMint = items.filter(item => item.id <= 182);
  assert.equal(beforeMint.length, 81);
  assert.equal(sha256(JSON.stringify(beforeMint)),
    '48e48e3672d2ad82ab4da243a5c6472d8798d7b50bd5a68320c37a5d5f69bc2a');
  const beforeStrongGreen = items.filter(item => item.id <= 198);
  assert.equal(beforeStrongGreen.length, 97);
  assert.equal(sha256(JSON.stringify(beforeStrongGreen)),
    '978e5ad6511cacf7eba64ad36c35ba3886384dd590f210197aa643e30051d139');
  const beforeStrongRed = items.filter(item => item.id <= 214);
  assert.equal(beforeStrongRed.length, 113);
  assert.equal(sha256(JSON.stringify(beforeStrongRed)),
    '698df81058cfbf44080116b9343febeb6c5979402490ef83f26d0993c56902a3');
  const previousArtwork = await Promise.all(beforeStrongRed.map(async item => ({
    id: item.id, file: item.file,
    sha256: sha256(await fs.readFile(path.join(libraryRoot, 'emojis', item.file))),
  })));
  assert.equal(sha256(JSON.stringify(previousArtwork)),
    '43e98fda557de74c1205cecfce37f71cb9148f1a6feedc930ce5b86eb7a742d4',
    'every previous image, including the enlarged cream and mint faces, remains unchanged');
  const added = items.filter(isRecentExpression);
  for (const value of [prefix, mintPrefix, strongGreenPrefix, strongRedPrefix])
    assert.equal(added.filter(item => item.file.startsWith(value)).length, 16);
  assert.deepEqual(added.map(item => item.id), ids);
  assert.equal(new Set(items.map(item => item.id)).size, items.length);
  assert.equal(new Set(items.map(item => item.file)).size, items.length);
  assert.equal(new Set(added.map(item => item.label)).size, 64);
  const hashes = new Set();
  for (const item of added) {
    assert.match(item.file, /^(?:cream-(?:contrast|mint)|strong-(?:green|red))-[a-z]+(?:-[a-z]+)*\.png$/);
    assert.match(item.label, /[\u0590-\u05ff]/);
    const strongGreen = item.file.startsWith(strongGreenPrefix);
    const strongRed = item.file.startsWith(strongRedPrefix);
    const transparent = strongGreen || strongRed;
    const mint = item.file.startsWith(mintPrefix);
    assert.ok(item.label.endsWith(strongRed ? ' — אדום' : strongGreen ? ' — ירוק חזק' : mint ? ' — ירוק בהיר' : ' — קרם'));
    const background = mint ? [228, 244, 231] : [255, 255, 255];
    const bytes = await fs.readFile(path.join(libraryRoot, 'emojis', item.file));
    hashes.add(sha256(bytes));
    const metadata = await sharp(bytes).metadata();
    assert.equal(metadata.format, 'png');
    assert.equal(metadata.width, strongRed ? 240 : 224, item.label);
    assert.equal(metadata.height, strongRed ? 240 : 224, item.label);
    if (transparent) assert.ok(metadata.hasAlpha, item.label);
    const { data, info } = await sharp(bytes).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
    const last = info.channels - 1;
    for (const pixel of [0, info.width - 1, (info.height - 1) * info.width, info.height * info.width - 1]) {
      const start = pixel * info.channels;
      if (transparent) {
        assert.equal(data[start + last], 0, `${item.label}: transparent corner`);
      } else {
        assert.deepEqual([...data.subarray(start, start + 3)], background, `${item.label}: approved background corner`);
      }
    }
    let darkPixels = 0, opaquePixels = 0, greenPixels = 0, redPixels = 0, transparentPixels = 0;
    for (let start = 0; start < data.length; start += info.channels) {
      const alpha = data[start + last];
      if (!transparent) assert.equal(alpha, 255, `${item.label}: fully opaque artwork`);
      if (alpha === 0) transparentPixels++;
      if (alpha < 240) continue;
      opaquePixels++;
      if (data[start + 1] > data[start] + 20 && data[start + 1] > data[start + 2] + 20) greenPixels++;
      if (data[start] > data[start + 1] + 20 && data[start] > data[start + 2] + 20) redPixels++;
      if (data[start] < 160 && data[start + 1] < 160 && data[start + 2] < 160) darkPixels++;
    }
    if (transparent) {
      const bodyPixels = strongRed ? redPixels : greenPixels;
      assert.ok(opaquePixels > 1000 && bodyPixels > opaquePixels * 0.7,
        `${item.label}: ${strongRed ? 'red' : 'strongly green'} face body`);
      assert.ok(transparentPixels > info.width * info.height * 0.25, `${item.label}: transparent background`);
      const center = (Math.floor(info.height / 2) * info.width + Math.floor(info.width / 2)) * info.channels;
      assert.ok(data[center + last] >= 240, `${item.label}: solid face center`);
    }
    assert.ok(darkPixels > 20, `${item.label}: facial features remain visible`);
  }
  assert.equal(hashes.size, 64, 'every expression has its own artwork');
});

test('the actual catalog and emoji HTTP handlers expose every new image without changing stickers', async t => {
  const library = createExpressionLibrary(libraryRoot);
  const app = express();
  const source = await fs.readFile(path.resolve(__dirname, '..', 'server', 'index.js'), 'utf8');
  const start = source.indexOf("app.get('/api/expressions/emoji/:id'");
  const end = source.indexOf("app.get('/api/gifs/search'", start);
  assert.ok(start >= 0 && end > start);
  vm.runInNewContext(source.slice(start, end), {
    app, expressionLibrary: library, getExpressionCatalog: () => library.catalog(),
    auth: (_req, _res, next) => next(),
    console: { error: (...args) => assert.fail(args.join(' ')) },
  });
  const server = app.listen(0, '127.0.0.1');
  await new Promise((resolve, reject) => { server.once('listening', resolve); server.once('error', reject); });
  t.after(() => new Promise((resolve, reject) => {
    server.close(error => error ? reject(error) : resolve());
    server.closeIdleConnections();
  }));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const response = await fetch(`${origin}/api/expressions/catalog`);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  const catalog = await response.json();
  assert.equal(catalog.version, 4);
  const emojis = catalog.categories.find(category => category.id === 'user-emojis').items;
  assert.equal(emojis.length, 128);
  const stickers = catalog.categories.find(category => category.id === 'user-stickers').items;
  assert.equal(stickers.length, 148);
  assert.equal(stickers.at(-1).id, 'user-stickers-150');
  const added = (await registry()).items.filter(isRecentExpression);
  for (const item of added) {
    const choice = emojis.find(emoji => emoji.emojiId === item.id);
    assert.deepEqual(choice, { id: `user-emojis-${item.id}`, emojiId: item.id, label: item.label,
      url: `/betshuva-app/api/expressions/emoji/${item.id}`, animated: false });
    const image = await fetch(origin + choice.url.replace('/betshuva-app', ''));
    assert.equal(image.status, 200);
    assert.equal(image.headers.get('cache-control'), 'no-cache');
    assert.match(image.headers.get('content-type'), /^image\/png/);
    const actual = Buffer.from(await image.arrayBuffer());
    assert.equal(sha256(actual), sha256(await fs.readFile(path.join(libraryRoot, 'emojis', item.file))));
  }
  for (const invalid of ['0167', '0183', '0199', '0215', '6401', '6400'])
    assert.equal((await fetch(`${origin}/api/expressions/emoji/${invalid}`)).status, 404);
});

test('new emoji markers keep readable Hebrew notification labels and remain decorative moderation tokens', async () => {
  const added = (await registry()).items.filter(isRecentExpression);
  assert.equal(added.length, 64);
  for (const item of added) {
    const marker = `[[bt-emoji:${String(item.id).padStart(3, '0')}]]`;
    const wire = `שלום ${marker} עולם`;
    assert.equal(inlineEmojiPlainText(wire), `שלום [${item.label}] עולם`);
    assert.equal(inlineEmojiModerationText(wire), 'שלום   עולם');
    assert.equal(wire, `שלום ${marker} עולם`);
  }
});
