'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const sharp = require('sharp');
const { createExpressionLibrary } = require('../server/expression-catalog');
const root = path.resolve(__dirname, '..');

test('server and bundled catalogs separate 49 emojis from all 150 stickers', async () => {
  const catalog = await createExpressionLibrary(path.join(root, 'expression-library')).catalog();
  assert.equal(catalog.version, 4);
  const emojis = catalog.categories.find(c => c.id === 'user-emojis').items;
  const stickers = catalog.categories.find(c => c.id === 'user-stickers').items;
  assert.equal(emojis.length, 49); assert.equal(stickers.length, 150);
  assert.equal(emojis[48].emojiId, 49);
  assert.equal(stickers[149].id, 'user-stickers-150');
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
