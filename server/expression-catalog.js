'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const IMAGE = /\.(png|gif|webp|jpe?g)$/i;
const MAX_EMOJI_ID = 6400;

function createExpressionLibrary(root, { onChange = () => {} } = {}) {
  const registryPath = path.join(root, 'emoji-registry.json');
  let pending = Promise.resolve();
  let fileList = '';

  async function readRegistry() {
    return JSON.parse(await fs.readFile(registryPath, 'utf8'));
  }

  async function files(folder) {
    const entries = await fs.readdir(path.join(root, folder), { withFileTypes: true });
    return entries.filter(entry => entry.isFile() && IMAGE.test(entry.name))
      .map(entry => entry.name).sort((a, b) => a.localeCompare(b, 'en', { numeric: true }));
  }

  // Serialize discovery so simultaneous clients cannot assign different IDs.
  // Never recycle IDs: saved messages must retain their original artwork.
  function discover() {
    const result = pending.then(async () => {
      const registry = await readRegistry();
      const names = await files('emojis');
      const known = new Set(registry.items.map(item => item.file));
      let nextId = Math.max(150, ...registry.items.map(item => item.id)) + 1;
      let changed = false;
      for (const file of names) {
        if (known.has(file)) continue;
        if (nextId > MAX_EMOJI_ID) throw new Error('Emoji ID capacity reached');
        registry.items.push({ id: nextId++, file, label: path.parse(file).name });
        changed = true;
      }
      if (changed) {
        const temporary = `${registryPath}.tmp`;
        await fs.writeFile(temporary, JSON.stringify(registry, null, 2) + '\n');
        await fs.rename(temporary, registryPath);
      }
      return { registry, names: new Set(names) };
    });
    pending = result.catch(() => {});
    return result;
  }

  async function catalog() {
    const [{ registry, names }, stickerNames, legacy] = await Promise.all([
      discover(), files('stickers'),
      fs.readFile(path.join(root, 'catalog.json'), 'utf8').then(JSON.parse),
    ]);
    const discoveredFiles = JSON.stringify([[...names], stickerNames]);
    if (discoveredFiles !== fileList) {
      fileList = discoveredFiles;
      onChange();
    }
    const labels = legacy.categories.find(category => category.id === 'user-stickers')?.labels || [];
    const emojis = registry.items.filter(item => names.has(item.file)).map(item => ({
      id: `user-emojis-${item.id}`, emojiId: item.id, label: item.label,
      url: `/betshuva-app/api/expressions/emoji/${item.id}`, animated: /\.gif$/i.test(item.file),
    }));
    const stickers = stickerNames.map(file => {
      const id = /^sticker-(\d+)\.png$/i.exec(file)?.[1];
      const libraryUrl = `/betshuva-app/expression-library/stickers/${encodeURIComponent(file)}`;
      return {
        id: `user-stickers-${id ? Number(id) : file}`,
        label: (id && labels[Number(id) - 1]) || path.parse(file).name,
        // Existing installed clients only recognize these legacy PNG URLs.
        url: id && Number(id) <= 150
          ? `/betshuva-app/expression-library/user-20261008-color/${file}` : libraryUrl,
        libraryUrl,
        animated: /\.gif$/i.test(file),
      };
    });
    return { version: 4, categories: [
      { id: 'user-emojis', title: 'אימוג׳ים בתשובה', items: emojis },
      { id: 'user-stickers', title: 'מדבקות בתשובה', items: stickers },
    ] };
  }

  async function emojiFile(id) {
    if (!Number.isInteger(id) || id < 1 || id > MAX_EMOJI_ID) return null;
    const registry = await readRegistry();
    const item = registry.items.find(item => item.id === id);
    if (!item && id <= 150) {
      const legacy = path.join(root, 'user-20261008-color',
        `sticker-${String(id).padStart(2, '0')}.png`);
      return await fs.lstat(legacy).then(stat => stat.isFile() ? legacy : null).catch(() => null);
    }
    if (!item || path.basename(item.file) !== item.file || !IMAGE.test(item.file)) return null;
    const target = path.join(root, 'emojis', item.file);
    const stat = await fs.lstat(target).catch(() => null);
    return stat?.isFile() ? target : null;
  }

  return { catalog, emojiFile };
}

module.exports = { createExpressionLibrary, MAX_EMOJI_ID };
