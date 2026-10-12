'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const https = require('node:https');
const crypto = require('node:crypto');
const sharp = require('sharp');
const manifest = require('./keyboard-emoji-artwork-manifest.json');
const approvedCatalog = require('../flutter_app/assets/twemoji/emoji_allowlist.json');
const { potentialAnimationFormat } = require('./image-animation-policy');

// Artwork: jdecked/Twemoji 17.0.3, CC-BY-4.0. SVGs are converted to PNG tiles.
// Full upstream graphics license accompanies the server's private SVG bundle;
// existing Flutter ATTRIBUTION.txt identifies this same upstream project.
const ARTWORK_SOURCE = Object.freeze({ version: manifest.version, commit: manifest.commit,
  repository: manifest.source, license: manifest.graphicsLicense });
const ARTWORK_VERSION = `twemoji-${manifest.version}:${manifest.commit}`;
const SVG_BASE = `https://raw.githubusercontent.com/jdecked/twemoji/${manifest.commit}/assets/svg/`;
const DEFAULT_CACHE_DIRECTORY = path.join(os.homedir(), '.local', 'state',
  'betshuva', 'emoji-artwork', manifest.commit);
const MAX_SVG_BYTES = 64 * 1024;
const MAX_PNG_BYTES = 128 * 1024;
const TILE_SIZE = 128;
const segmenter = new Intl.Segmenter('und', { granularity: 'grapheme' });
const variation = /^[\uFE0E\uFE0F]$/u;
const modifier = /^\p{Emoji_Modifier}$/u;
const modifierBase = /^\p{Emoji_Modifier_Base}$/u;
const emojiCharacter = /^\p{Emoji}$/u;
const emojiCandidate = /[\p{Extended_Pictographic}\p{Regional_Indicator}\p{Emoji_Modifier}\u20E3\u{E0020}-\u{E007F}]/u;
const codeOf = value => Array.from(value, character => character.codePointAt(0).toString(16)).join('-');
const withoutSelectors = value => Array.from(value).filter(character => !variation.test(character)).join('');
const approved = new Set(approvedCatalog.map(item => codeOf(withoutSelectors(item.emoji))));
const artworkAliases = new Map();
for (const code of Object.keys(manifest.assets)) {
  const key = code.split('-').filter(part => part !== 'fe0e' && part !== 'fe0f').join('-');
  // Retain the entire ZWJ/tag/modifier sequence. Only presentation selectors
  // are aliases; an unknown composition never becomes separate safe pieces.
  if (!artworkAliases.has(key) || key === code) artworkAliases.set(key, code);
}

function selectorsValid(emoji) {
  const characters = Array.from(emoji);
  return characters.every((character, index) => !variation.test(character) ||
    (index > 0 && emojiCharacter.test(characters[index - 1]) &&
      !modifier.test(characters[index - 1]) &&
      !/\p{Regional_Indicator}/u.test(characters[index - 1])));
}

function resolveEmoji(emoji) {
  // Copyright/trademark in ordinary prose remains text. Explicit emoji
  // presentation is inspected like other emoji, without mutating stored text.
  if (/^[©®™]\uFE0E?$/u.test(emoji)) return null;
  const rawCode = codeOf(emoji);
  const key = codeOf(withoutSelectors(emoji));
  if (!emojiCandidate.test(emoji) && !artworkAliases.has(key)) return null;
  const canonicalCode = selectorsValid(emoji) ? artworkAliases.get(key) : null;
  const characters = Array.from(withoutSelectors(emoji));
  const skinVariant = characters.length === 2 && modifierBase.test(characters[0]) &&
    modifier.test(characters[1]);
  const knownApproved = !!canonicalCode && (approved.has(key) ||
    (skinVariant && approved.has(codeOf(characters[0]))));
  return { emoji, code: canonicalCode || rawCode, knownApproved };
}

function extractKeyboardEmoji(text) {
  const found = [], seen = new Set();
  for (const part of segmenter.segment(String(text || ''))) {
    const item = resolveEmoji(part.segment);
    if (item && !seen.has(item.code)) { found.push(item); seen.add(item.code); }
  }
  return found;
}

function artworkError(reasonCode, unsupported = false) {
  return Object.assign(new Error(unsupported
    ? 'האימוג׳י הזה עדיין אינו נתמך בסריקה. אפשר לבחור אימוג׳י אחר'
    : 'לא ניתן להכין את האימוג׳י לסריקה כרגע. אפשר לנסות שוב'), {
    code: unsupported ? 'UNSUPPORTED_EMOJI' : 'EMOJI_ARTWORK_UNAVAILABLE', reasonCode,
  });
}

function secureFetch(url, { signal } = {}) {
  return new Promise((resolve, reject) => {
    const request = https.get(url, { signal, rejectUnauthorized: true,
      headers: { Accept: 'image/svg+xml', 'User-Agent': 'Betshuva-Emoji-Artwork/1' } }, response => {
      resolve({ ok: response.statusCode === 200, status: response.statusCode,
        url, redirected: false, body: response,
        headers: { get: name => response.headers[name.toLowerCase()] } });
    });
    request.on('error', reject);
  });
}

function boundedMilliseconds(value, fallback, maximum) {
  return Number.isInteger(value) && value > 0 ? Math.min(value, maximum) : fallback;
}

async function withDeadline(operation, milliseconds) {
  const controller = new AbortController();
  let timer;
  try {
    return await Promise.race([
      operation(controller.signal),
      new Promise((_, reject) => { timer = setTimeout(() => {
        controller.abort(); reject(artworkError('timeout'));
      }, milliseconds); }),
    ]);
  } finally {
    clearTimeout(timer); controller.abort();
  }
}

function validateSvg(bytes, asset) {
  if (!Buffer.isBuffer(bytes) || bytes.length > MAX_SVG_BYTES || bytes.length !== asset.bytes ||
      crypto.createHash('sha256').update(bytes).digest('hex') !== asset.sha256)
    throw artworkError('artwork_integrity');
  const text = bytes.toString('utf8');
  if (!/<svg\b/i.test(text) || /<!DOCTYPE|<!ENTITY|<script\b|<foreignObject\b|<image\b|(?:href|xlink:href)\s*=/i.test(text) ||
      /url\(\s*(?!#)/i.test(text)) throw artworkError('unsafe_svg');
  return bytes;
}

async function renderSvg(bytes) {
  const image = sharp(bytes, { density: 144, limitInputPixels: 256 * 256 }).timeout({ seconds: 2 });
  const metadata = await image.metadata();
  if (metadata.format !== 'svg' || !metadata.width || !metadata.height ||
      metadata.width > 256 || metadata.height > 256) throw artworkError('artwork_dimensions');
  return image.resize(TILE_SIZE, TILE_SIZE, { fit: 'contain',
    background: { r: 255, g: 255, b: 255, alpha: 1 } }).flatten({ background: '#ffffff' })
    .png().toBuffer();
}

async function validatePng(bytes) {
  if (!Buffer.isBuffer(bytes) || bytes.length > MAX_PNG_BYTES || potentialAnimationFormat(bytes))
    throw artworkError('rendered_artwork_invalid');
  const metadata = await sharp(bytes, { limitInputPixels: TILE_SIZE * TILE_SIZE }).metadata();
  if (metadata.format !== 'png' || !metadata.width || !metadata.height ||
      metadata.width > TILE_SIZE || metadata.height > TILE_SIZE || (metadata.pages || 1) !== 1)
    throw artworkError('rendered_artwork_invalid');
  return bytes;
}

function createKeyboardEmojiArtworkLoader(options = {}) {
  const fetchArtwork = options.fetch || secureFetch;
  const render = options.render || renderSvg;
  const cacheDirectory = options.cacheDirectory || DEFAULT_CACHE_DIRECTORY;
  const svgDirectory = path.join(cacheDirectory, 'svg');
  const pngDirectory = path.join(cacheDirectory, 'png');
  const downloadTimeoutMs = boundedMilliseconds(options.downloadTimeoutMs, 5000, 10000);
  const renderTimeoutMs = boundedMilliseconds(options.renderTimeoutMs, 3000, 5000);
  const maxCacheEntries = boundedMilliseconds(options.maxCacheEntries, 128, 256);
  const maxFileCacheEntries = boundedMilliseconds(options.maxFileCacheEntries, 256, 512);
  const maxInflight = boundedMilliseconds(options.maxInflight, 16, 32);
  const memory = new Map(), inflight = new Map();
  let trimQueue = Promise.resolve();

  async function writeAtomically(filename, bytes) {
    const temporary = `${filename}.${crypto.randomUUID()}.tmp`;
    await fs.mkdir(path.dirname(filename), { recursive: true, mode: 0o700 });
    try {
      await fs.writeFile(temporary, bytes, { mode: 0o600 });
      await fs.rename(temporary, filename);
    } finally { await fs.unlink(temporary).catch(() => {}); }
  }

  async function svgFor(code, asset) {
    const filename = path.join(svgDirectory, `${code}.svg`);
    try {
      const stat = await fs.stat(filename);
      if (stat.size > MAX_SVG_BYTES) throw artworkError('artwork_size');
      return validateSvg(await fs.readFile(filename), asset);
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
    const url = `${SVG_BASE}${code}.svg`;
    const bytes = await withDeadline(async signal => {
      const response = await fetchArtwork(url, { signal, redirect: 'error', credentials: 'omit' });
      if (!response?.ok || response.redirected || (response.url && response.url !== url)) {
        response?.body?.destroy?.(); throw artworkError('artwork_download');
      }
      const declaredLength = Number(response.headers?.get?.('content-length'));
      if (declaredLength > MAX_SVG_BYTES) {
        response.body?.destroy?.(); throw artworkError('artwork_size');
      }
      let size = 0;
      const chunks = [];
      if (!response.body || !response.body[Symbol.asyncIterator]) throw artworkError('artwork_download');
      for await (const chunk of response.body) {
        const buffer = Buffer.from(chunk); size += buffer.length;
        if (size > MAX_SVG_BYTES) {
          response.body.destroy?.(); throw artworkError('artwork_size');
        }
        chunks.push(buffer);
      }
      return validateSvg(Buffer.concat(chunks), asset);
    }, downloadTimeoutMs);
    // The finite manifest bounds SVG storage to the pinned 4009 assets. A full
    // private SVG bundle avoids any request-triggered external downloads.
    await writeAtomically(filename, bytes);
    return bytes;
  }

  async function readCachedPng(code, asset) {
    try {
      const filename = path.join(pngDirectory, `${code}.png`);
      const stat = await fs.stat(filename);
      if (stat.size > MAX_PNG_BYTES) return null;
      const info = JSON.parse(await fs.readFile(`${filename}.json`, 'utf8'));
      const bytes = await fs.readFile(filename);
      if (info.sourceSha256 !== asset.sha256 ||
          info.pngSha256 !== crypto.createHash('sha256').update(bytes).digest('hex')) return null;
      await validatePng(bytes);
      await fs.utimes(filename, new Date(), new Date()).catch(() => {});
      return bytes;
    } catch (_) { return null; }
  }

  async function trimFileCache() {
    const entries = await fs.readdir(pngDirectory);
    const candidates = await Promise.all(entries.filter(name =>
      name.endsWith('.png') && Object.hasOwn(manifest.assets, name.slice(0, -4)))
      .map(async name => ({ name, time: (await fs.stat(path.join(pngDirectory, name))).mtimeMs })));
    candidates.sort((a, b) => a.time - b.time);
    for (const entry of candidates.slice(0, Math.max(0, candidates.length - maxFileCacheEntries))) {
      await fs.unlink(path.join(pngDirectory, entry.name)).catch(() => {});
      await fs.unlink(path.join(pngDirectory, `${entry.name}.json`)).catch(() => {});
    }
  }

  async function prepare(code) {
    const asset = manifest.assets[code];
    let bytes = await readCachedPng(code, asset);
    if (!bytes) {
      const svg = await svgFor(code, asset);
      bytes = await withDeadline(async signal =>
        validatePng(await render(svg, { code, size: TILE_SIZE, signal })), renderTimeoutMs);
      const filename = path.join(pngDirectory, `${code}.png`);
      await writeAtomically(filename, bytes);
      await writeAtomically(`${filename}.json`, JSON.stringify({ sourceSha256: asset.sha256,
        pngSha256: crypto.createHash('sha256').update(bytes).digest('hex') }));
      trimQueue = trimQueue.catch(() => {}).then(trimFileCache);
      await trimQueue;
    }
    memory.set(code, Buffer.from(bytes));
    while (memory.size > maxCacheEntries) memory.delete(memory.keys().next().value);
    return bytes;
  }

  return async function load({ emoji, code } = {}) {
    const extracted = typeof emoji === 'string' ? extractKeyboardEmoji(emoji) : [];
    if (extracted.length !== 1 || extracted[0].emoji !== emoji || extracted[0].code !== code ||
        !/^[0-9a-f]+(?:-[0-9a-f]+)*$/.test(code || '') || !Object.hasOwn(manifest.assets, code))
      throw artworkError('unsupported_sequence', true);
    if (memory.has(code)) {
      const bytes = memory.get(code); memory.delete(code); memory.set(code, bytes);
      return Buffer.from(bytes);
    }
    if (!inflight.has(code)) {
      if (inflight.size >= maxInflight) throw artworkError('artwork_busy');
      const promise = prepare(code).catch(error => {
        if (error.code === 'EMOJI_ARTWORK_UNAVAILABLE') throw error;
        throw artworkError('artwork_processing');
      }).finally(() => inflight.delete(code));
      inflight.set(code, promise);
    }
    return Buffer.from(await inflight.get(code));
  };
}

module.exports = { ARTWORK_SOURCE, ARTWORK_VERSION, DEFAULT_CACHE_DIRECTORY,
  extractKeyboardEmoji, createKeyboardEmojiArtworkLoader };
