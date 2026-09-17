'use strict';

const fs = require('node:fs/promises');
const { constants } = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const MAX_BYTES = 10 * 1024 * 1024;
const URL_PATTERN = /^\/betshuva-app\/uploads\/demo-historical\/([a-z0-9-]+\.webp)(?:\?v=painted1)?$/;
const IMAGE_CATEGORIES = new Set(['men', 'women', 'children', 'nonHumanImages']);
// These application-owned portraits were reviewed as images, not classified
// from account gender or filenames. A replacement needs its own review/hash.
const PROFILE_IMAGE_ASSET_MANIFEST = Object.freeze(Object.fromEntries([
  ['beruriah.webp', 'fdd8e0009f2fafe4600daf99ae63a185b6a520632232fadac2350334c68dacab', ['women']],
  ['chofetz-chaim.webp', '44c1e35ce5c5cd8b43b057f4b54559a8e4cb236d5eb76ee31abeaca8f4d868f2', ['men']],
  ['first-temple-man.webp', '0ab64c2613a3eea291b586dbabbbfec63837bb5fcc39720fb503d88edf51fe50', ['men']],
  ['first-temple-woman.webp', '8f1d6ed9ac6ac2d55b5d07c5847e4a29e77018cfaa90bca9210fc016d8116301', ['women']],
  ['naor-hakohen.webp', 'b8b364a058c01068bf2a2c89f2210ab5d406aa38e7c941e5bbfa02a3d93b9bd1', ['men']],
  ['rabbi-akiva.webp', '280cdc77478c204a5ceaca95fc4b9b43bf182a7c3677d8a26493ead02d49aac8', ['men']],
  ['rambam.webp', '7e8893b35870605741ba583ae8359de3b00d0fabb74c425024edf1a9be5c551c', ['men']],
  ['sarah-schenirer.webp', 'c805438388e35ea2b921647d0db21be041f81c98bc5e842c16c15e925d9a4df5', ['women']],
  ['second-temple-man.webp', '1d473d3e26457b9a879eddcd22127b7651afe5302ec237d18206b1dd6939f020', ['men']],
  ['second-temple-woman.webp', '16a6770b17ac5a67f8a2698e094e5e93d5c242106dc3c5451ccb613e98d192cc', ['women']],
  ['temple-men-group.webp', '3780967bc0a4843fd4ae13b79f385da8fd24d793a90ed8cecfeac7541090d5e1', ['men']],
  ['temple-women-group.webp', 'e4b492caf407f0c3e75eff85ba20e7ebd1448eb2822aa109c8348720a41c4326', ['women']],
].map(([name, sha256, categories]) => [name, Object.freeze({
  sha256, categories: Object.freeze(categories),
})])));

function fileIdentity(stat) {
  return [stat.dev, stat.ino, stat.size, stat.mtimeNs, stat.ctimeNs].join(':');
}

function createProfileAssetResolver({
  assetRoot = path.join(__dirname, '..', 'uploads', 'demo-historical'),
  manifest = PROFILE_IMAGE_ASSET_MANIFEST,
} = {}) {
  const root = path.resolve(assetRoot);
  const cache = new Map();
  // Snapshot server-owned configuration; changing a manifest cannot reuse a
  // digest result approved under another classification or hash.
  const entries = new Map(Object.entries(manifest).map(([name, entry]) => {
    if (!/^[a-z0-9-]+\.webp$/.test(name) || !/^[a-f0-9]{64}$/.test(entry.sha256) ||
        !Array.isArray(entry.categories) || !entry.categories.length ||
        entry.categories.some(category => !IMAGE_CATEGORIES.has(category)))
      throw new TypeError('Invalid reviewed profile asset');
    const categories = Object.freeze([...new Set(entry.categories)]);
    return [name, {
      sha256: entry.sha256,
      metadata: Object.freeze({
        file_type: 'image', moderation_status: 'approved', content_purged_at: null,
        blocked: false,
        classification: Object.freeze({
          category: categories[0], detectedCategories: categories, uncertain: false,
          source: 'reviewed-application-asset',
        }),
      }),
    }];
  }));

  return async function getProfileAssetMetadata(url) {
    if (typeof url !== 'string') return null;
    const name = URL_PATTERN.exec(url)?.[1];
    const entry = entries.get(name);
    if (!entry) return null;
    const requested = path.join(root, name);
    let file;
    try {
      // A symlink must never turn a public built-in URL into a trusted alias
      // for different bytes, including when a previously valid file changes.
      if (await fs.realpath(root) !== root || await fs.realpath(requested) !== requested)
        return null;
      const stat = await fs.lstat(requested, { bigint: true });
      if (!stat.isFile() || stat.size <= 0n || stat.size > BigInt(MAX_BYTES)) return null;
      const identity = fileIdentity(stat);
      if (cache.get(name)?.identity === identity) return cache.get(name).metadata;

      file = await fs.open(requested, constants.O_RDONLY | constants.O_NOFOLLOW);
      if (fileIdentity(await file.stat({ bigint: true })) !== identity) return null;
      const bytes = Buffer.alloc(Number(stat.size));
      let offset = 0;
      while (offset < bytes.length) {
        const result = await file.read(bytes, offset, bytes.length - offset, offset);
        if (!result.bytesRead) return null;
        offset += result.bytesRead;
      }
      const extra = await file.read(Buffer.alloc(1), 0, 1, offset);
      if (extra.bytesRead || fileIdentity(await file.stat({ bigint: true })) !== identity ||
          fileIdentity(await fs.lstat(requested, { bigint: true })) !== identity)
        return null;
      const metadata = crypto.createHash('sha256').update(bytes).digest('hex') === entry.sha256
        ? entry.metadata : null;
      cache.set(name, { identity, metadata });
      return metadata;
    } catch {
      // Missing, changed, unreadable or unreviewed assets retain the normal
      // unknown-image policy. A failed lookup never approves an image.
      return null;
    } finally {
      await file?.close().catch(() => {});
    }
  };
}

const getProfileAssetMetadata = createProfileAssetResolver();
module.exports = {
  PROFILE_IMAGE_ASSET_MANIFEST, createProfileAssetResolver, getProfileAssetMetadata,
};
