'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const sharp = require('sharp');
const { createExpressionLibrary } = require('../server/expression-catalog');
const root = path.resolve(__dirname, '..');

test('live catalog has 128 selectable emojis while bundled catalog preserves the initial 49 IDs', async () => {
  const catalog = await createExpressionLibrary(path.join(root, 'expression-library')).catalog();
  assert.equal(catalog.version, 4);
  const emojis = catalog.categories.find(c => c.id === 'user-emojis').items;
  const stickers = catalog.categories.find(c => c.id === 'user-stickers').items;
  assert.equal(emojis.length, 128); assert.equal(stickers.length, 148);
  assert.deepEqual(emojis.slice(0, 16).map(item => item.emojiId),
    Array.from({ length: 16 }, (_, index) => index + 1));
  assert.deepEqual(emojis.slice(16, 32).map(item => item.emojiId),
    [159, 152, 154, 156, 155, 151, 163, 158, 153, 161, 162, 166, 164, 160, 165, 157]);
  assert.deepEqual(emojis.slice(32, 64).map(item => item.emojiId),
    Array.from({ length: 33 }, (_, index) => index + 17).filter(id => id !== 41));
  assert.deepEqual(emojis.slice(64).map(item => item.emojiId),
    Array.from({ length: 64 }, (_, index) => index + 167));
  const added = emojis.filter(item => item.emojiId > 150);
  assert.equal(added.length, 80);
  assert.equal(new Set(added.map(item => item.emojiId)).size, 80);
  for (const item of added) {
    const file = await createExpressionLibrary(path.join(root, 'expression-library')).emojiFile(item.emojiId);
    const metadata = await sharp(file).metadata();
    assert.equal(metadata.format, 'png');
    if (item.emojiId < 167 || item.emojiId >= 199) assert.ok(metadata.hasAlpha, item.label);
    const { data, info } = await sharp(file).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
    if (item.emojiId >= 199) {
      assert.equal(data[info.channels - 1], 0, `${item.label}: transparent colored face corner`);
    } else if (item.emojiId >= 183) {
      assert.deepEqual([...data.subarray(0, 4)], [228, 244, 231, 255], `${item.label}: opaque pale green corner`);
    } else if (item.emojiId >= 167) {
      assert.deepEqual([...data.subarray(0, 4)], [255, 255, 255, 255], `${item.label}: opaque white corner`);
    } else {
      assert.equal(data[info.channels - 1], 0, `${item.label}: transparent corner`);
    }
    const center = (Math.floor(info.height / 2) * info.width + Math.floor(info.width / 2)) * info.channels;
    assert.ok(data[center + info.channels - 1] >= 240, `${item.label}: visible face`);
  }
  assert.equal(stickers.at(-1).id, 'user-stickers-150');
  for (const item of stickers) {
    const metadata = await sharp(path.join(root, item.libraryUrl.replace('/betshuva-app/', ''))).metadata();
    assert.equal(metadata.format, 'png');
    assert.ok(metadata.width > 100 && metadata.height > 100);
  }
  const source = JSON.parse(await fs.readFile(path.join(root, 'expression-library/catalog.json')));
  const bundled = JSON.parse(await fs.readFile(path.join(root, 'flutter_app/assets/stickers/user-catalog.json')));
  assert.deepEqual(source, bundled);
  assert.equal(bundled.categories.find(c => c.id === 'user-emojis').labels.length, 49);
  assert.equal(bundled.categories.find(c => c.id === 'user-stickers').labels.length, 150);
  for (const folder of ['user-20260907', 'user-20261008-color']) {
    assert.equal((await fs.readdir(path.join(root, 'expression-library', folder)))
      .filter(name => /^sticker-\d+\.png$/.test(name)).length, 150);
  }
});

test('live discovery is isolated, supports arbitrary names, and keeps IDs across deletion and restart', async t => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'expression-library-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  for (const folder of ['emojis', 'stickers']) await fs.mkdir(path.join(directory, folder));
  await fs.writeFile(path.join(directory, 'catalog.json'), JSON.stringify({ categories: [] }));
  await fs.writeFile(path.join(directory, 'emoji-registry.json'), JSON.stringify({ items: [] }));
  let changes = 0;
  const library = createExpressionLibrary(directory, { onChange: () => changes++ });
  await fs.writeFile(path.join(directory, 'emojis', 'חיוך חדש.png'), 'image');
  await fs.writeFile(path.join(directory, 'stickers', 'שבת שלום.webp'), 'image');
  await fs.writeFile(path.join(directory, 'emojis', 'ignore.txt'), 'ignored');
  await fs.symlink('/etc/passwd', path.join(directory, 'emojis', 'ignore.png'));
  const catalogs = await Promise.all([library.catalog(), library.catalog(), library.catalog()]);
  for (const catalog of catalogs) {
    assert.equal(catalog.categories[0].items.length, 1);
    assert.equal(catalog.categories[0].items[0].emojiId, 151);
    assert.equal(catalog.categories[1].items.length, 1);
    assert.match(catalog.categories[1].items[0].url, /%/);
  }
  assert.equal(changes, 1);
  assert.equal(await library.emojiFile(151), path.join(directory, 'emojis', 'חיוך חדש.png'));
  await fs.unlink(path.join(directory, 'emojis', 'חיוך חדש.png'));
  await fs.writeFile(path.join(directory, 'emojis', 'another.jpg'), 'image');
  const restarted = createExpressionLibrary(directory);
  assert.equal((await restarted.catalog()).categories[0].items[0].emojiId, 152);
  assert.equal(await restarted.emojiFile(151), null);
  assert.equal(await restarted.emojiFile(6401), null);
  await fs.writeFile(path.join(directory, 'emojis', 'חיוך חדש.png'), 'image');
  assert.equal((await restarted.catalog()).categories[0].items.find(i => i.label === 'חיוך חדש').emojiId, 151);
});
