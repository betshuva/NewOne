'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { createExpressionLibrary } = require('../server/expression-catalog');
const { inlineEmojiPlainText } = require('../server/inline-custom-emoji');

test('removed house choices retain stable IDs and readable historical artwork', async t => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'expression-retirement-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  for (const folder of ['emojis', 'stickers']) await fs.mkdir(path.join(directory, folder));
  const labels = Array.from({ length: 150 }, (_, index) => `label-${index + 1}`);
  labels[40] = 'בית'; labels[95] = 'תמיד בבית'; labels[96] = 'הבית של בתשובה';
  await fs.writeFile(path.join(directory, 'catalog.json'), JSON.stringify({ categories: [
    { id: 'user-stickers', labels, removedIds: [41, 97] },
    { id: 'user-emojis', removedIds: [41] },
  ] }));
  const registry = { items: [
    { id: 1, file: 'sticker-01.png', label: 'שמחה' },
    { id: 41, file: 'sticker-41.png', label: 'בית' },
  ] };
  await fs.writeFile(path.join(directory, 'emoji-registry.json'), JSON.stringify(registry));
  for (const name of ['sticker-01.png', 'sticker-41.png']) {
    await fs.writeFile(path.join(directory, 'emojis', name), `historical-${name}`);
  }
  for (const name of ['sticker-01.png', 'sticker-41.png', 'sticker-96.png', 'sticker-97.png', 'new-greeting.gif']) {
    await fs.writeFile(path.join(directory, 'stickers', name), `historical-${name}`);
  }
  const library = createExpressionLibrary(directory);
  const catalog = await library.catalog();
  assert.deepEqual(catalog.categories[0].items.map(item => item.emojiId), [1]);
  const stickers = catalog.categories[1].items;
  assert.deepEqual(stickers.map(item => item.id), [
    'user-stickers-new-greeting.gif', 'user-stickers-1', 'user-stickers-96',
  ]);
  assert.equal(stickers.find(item => item.id === 'user-stickers-96').label, 'תמיד בבית');
  assert.equal(stickers.find(item => item.id === 'user-stickers-new-greeting.gif').animated, true);
  const historicalFile = await library.emojiFile(41);
  assert.equal(historicalFile, path.join(directory, 'emojis/sticker-41.png'));
  assert.equal(await fs.readFile(historicalFile, 'utf8'), 'historical-sticker-41.png');
  assert.equal(await fs.readFile(path.join(directory, 'stickers/sticker-97.png'), 'utf8'),
    'historical-sticker-97.png');
  assert.deepEqual(JSON.parse(await fs.readFile(path.join(directory, 'emoji-registry.json'), 'utf8')), registry);
  assert.deepEqual((await createExpressionLibrary(directory).catalog()).categories[0].items
    .map(item => item.emojiId), [1]);
  assert.equal(inlineEmojiPlainText('[[bt-emoji:041]]'), '[בית]');
});

test('server and bundled picker declarations remove houses without renumbering labels', async () => {
  const root = path.resolve(__dirname, '..');
  const catalog = JSON.parse(await fs.readFile(path.join(root, 'expression-library/catalog.json'), 'utf8'));
  const bundled = JSON.parse(await fs.readFile(path.join(root, 'flutter_app/assets/stickers/user-catalog.json'), 'utf8'));
  assert.deepEqual(bundled, catalog);
  for (const category of catalog.categories) {
    assert.equal(category.labels[40], 'בית');
    assert.ok(category.removedIds.includes(41));
    if (category.id === 'user-stickers') {
      assert.equal(category.labels[96], 'הבית של בתשובה');
      assert.ok(category.removedIds.includes(97));
      assert.equal(category.labels[95], 'תמיד בבית');
      assert.equal(category.removedIds.includes(96), false);
    }
  }
  assert.equal(await fs.readFile(path.join(root, 'expression-library/emojis/sticker-41.png')).then(bytes => bytes.length > 0), true);
  assert.equal(await fs.readFile(path.join(root, 'expression-library/stickers/sticker-97.png')).then(bytes => bytes.length > 0), true);
});
