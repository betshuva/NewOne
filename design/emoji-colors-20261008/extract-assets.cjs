// Deterministic asset extraction only; artwork/color edits were made by image_gen.
const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const sharp = require('../../node_modules/sharp');

const root = path.resolve(__dirname, '../..');
const original = path.join(root, 'expression-library/user-20260907');
const output = path.join(root, 'expression-library/user-20261008-color');
const source = path.join(__dirname, 'colored-atlas.png');
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');

(async () => {
  await fs.mkdir(output, {recursive: true});
  const metadata = await sharp(source).metadata();
  if (!metadata.hasAlpha || metadata.width !== 1403 || metadata.height !== 1121) {
    throw new Error('Unexpected colored atlas geometry or missing alpha');
  }
  const assets = [];
  for (let index = 1; index <= 150; index++) {
    const name = `sticker-${String(index).padStart(2, '0')}.png`;
    const target = path.join(output, name);
    if (index <= 48) {
      const col = (index - 1) % 8;
      const row = Math.floor((index - 1) / 8);
      const left = Math.round(col * metadata.width / 8);
      const top = Math.round(row * metadata.height / 6);
      const cell = await sharp(source).extract({
        left, top,
        width: Math.round((col + 1) * metadata.width / 8) - left,
        height: Math.round((row + 1) * metadata.height / 6) - top,
      }).png().toBuffer();
      await sharp(cell)
        .trim({background: {r: 0, g: 0, b: 0, alpha: 0}, threshold: 10, margin: 6})
        .resize(160, 160, {fit: 'contain', background: {r: 0, g: 0, b: 0, alpha: 0}})
        .png().toFile(target);
    } else {
      await fs.copyFile(path.join(original, name), target);
    }
    const bytes = await fs.readFile(target);
    const originalBytes = await fs.readFile(path.join(original, name));
    const meta = await sharp(bytes).metadata();
    if (meta.width <= 100 || meta.height <= 100) {
      throw new Error(`Asset too small: ${name}`);
    }
    const asset = {index, name, source: index <= 48 ? 'colored-atlas.png' : 'original',
      bytes: bytes.length, sha256: sha(bytes), originalSha256: sha(originalBytes),
      width: meta.width, height: meta.height, hasAlpha: meta.hasAlpha,
      unchanged: bytes.equals(originalBytes)};
    if (index <= 48) {
      const {data, info} = await sharp(bytes).ensureAlpha().raw().toBuffer({resolveWithObject: true});
      let zeroAlpha = 0;
      let opaque = 0;
      for (let pixel = 0; pixel < info.width * info.height; pixel++) {
        const alpha = data[pixel * info.channels + 3];
        if (alpha === 0) zeroAlpha++;
        if (alpha >= 240) opaque++;
      }
      asset.transparentFraction = zeroAlpha / (info.width * info.height);
      asset.opaqueFraction = opaque / (info.width * info.height);
      if (!meta.hasAlpha || zeroAlpha === 0 || opaque < 100) {
        throw new Error(`Alpha or artwork missing: ${name}`);
      }
    } else if (!asset.unchanged) {
      throw new Error(`Original artwork changed: ${name}`);
    }
    assets.push(asset);
  }
  const manifest = {mode: 'built-in image_gen edits; Sharp grid extraction and transparent padding trim',
    atlas: 'colored-atlas.png', atlasSha256: sha(await fs.readFile(source)),
    sourceAtlas: '/home/yaniv/Emoji/WhatsApp Image 2026-09-07 at 00.01.32.jpeg',
    outputDirectory: output, recoloredCount: 48, unchangedCount: 102, assets};
  await fs.writeFile(path.join(__dirname, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
  console.log(JSON.stringify({outputDirectory: output, recoloredCount: 48, unchangedCount: 102,
    atlasSha256: manifest.atlasSha256, assetBytes: assets.reduce((total, item) => total + item.bytes, 0),
    minimumTransparentFraction: Math.min(...assets.slice(0, 48).map(item => item.transparentFraction))}));
})().catch(error => { console.error(error); process.exitCode = 1; });
