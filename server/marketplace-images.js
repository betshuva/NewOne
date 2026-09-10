'use strict';

const fs = require('node:fs/promises');
const { constants } = require('node:fs');
const path = require('node:path');
const sharp = require('sharp');

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PUBLIC_BASE = '/betshuva-app/uploads/';
const MAX_BYTES = 10 * 1024 * 1024;
const MAX_OUTPUT_BYTES = 1024 * 1024;
const MAX_LOAD_MS = 10000;
// These are the public, server-created assets in seed-demo-listings.js. User
// uploads always live under their owner's UUID; they cannot write this namespace.
const DEMO_FILES = new Set([
  ...['רכב', 'רהיטים', 'אלקטרוניקה', 'בגדים', 'ספרים', 'כלי בית', 'צעצועים', 'אחר']
    .flatMap(category => Array.from({ length: 8 }, (_, i) =>
      `demo-listings/${Buffer.from(category).toString('hex')}-${i + 1}.png`)),
  ...['bike', 'desk'].flatMap(item => Array.from({ length: 8 }, (_, i) =>
    `demo-listings/${item}-photo-${i + 1}.jpg`)),
]);

function imagePath(row) {
  // Never resolve arbitrary URLs from listing descriptions or user-supplied
  // image fields. Only an exact registered upload or a known public demo exists.
  if (typeof row.public_url !== 'string' || !row.public_url.startsWith(PUBLIC_BASE)) return null;
  const relative = row.public_url.slice(PUBLIC_BASE.length);
  if (row.stored_file_id) {
    if (row.moderation_status !== 'approved' || row.file_type !== 'image' ||
        row.content_purged_at != null || row.file_owner_id !== row.listing_owner_id ||
        relative !== row.storage_path || !UUID.test(relative.split('/')[0]) ||
        relative.split('/').some(part => !/^[\w.-]+$/.test(part) || part.startsWith('.')) ||
        !Number.isSafeInteger(Number(row.file_size)) || Number(row.file_size) <= 0 ||
        Number(row.file_size) > MAX_BYTES) return null;
    return { relative, mayRestore: row.released_at != null };
  }
  return DEMO_FILES.has(relative) ? { relative, mayRestore: false } : null;
}

async function localImageBytes(root, relative) {
  const realRoot = await fs.realpath(root);
  const requestedPath = path.join(realRoot, relative);
  const realPath = await fs.realpath(requestedPath);
  if (!realPath.startsWith(realRoot + path.sep) || realPath !== requestedPath)
    throw new Error('Image outside its registered location');
  const file = await fs.open(realPath, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const stat = await file.stat();
    if (!stat.isFile() || stat.size <= 0 || stat.size > MAX_BYTES)
      throw new Error('Image size unavailable');
    // The extra byte catches growth after stat without ever reading an unbounded file.
    const bytes = Buffer.alloc(stat.size + 1);
    let offset = 0;
    while (offset < bytes.length) {
      const result = await file.read(bytes, offset, bytes.length - offset, offset);
      if (!result.bytesRead) break;
      offset += result.bytesRead;
    }
    if (offset !== stat.size) throw new Error('Image changed during read');
    return bytes.subarray(0, offset);
  } finally {
    await file.close();
  }
}

async function restoredImageBytes(publicUrl, fetchImpl, remainingMs) {
  // This fixed origin is the existing public Drive-backed media route. The
  // caller already verified the exact registered path and owner. No redirects,
  // arbitrary hosts, auth headers or user-controlled remote URLs are permitted.
  const response = await fetchImpl(`https://betshuva.com${publicUrl}`, {
    redirect: 'error', signal: AbortSignal.timeout(Math.max(1, Math.min(3000, remainingMs))),
  });
  const declaredSize = Number(response.headers.get('content-length'));
  if (!response.ok || declaredSize > MAX_BYTES || !response.body?.getReader) {
    await response.body?.cancel?.();
    throw new Error('Stored image unavailable');
  }
  const reader = response.body.getReader();
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > MAX_BYTES) throw new Error('Stored image too large');
      chunks.push(value);
    }
    if (!size) throw new Error('Stored image empty');
    return Buffer.concat(chunks, size);
  } finally {
    await reader.cancel().catch(() => {});
  }
}

/** Load at most eight current, authorized listing images as metadata-free JPEGs.
 * Options are server-side only: uploadRoot for deployment/tests, maxImages (0–8),
 * fetchImpl for testing the fixed-origin Drive fallback. No listing URLs are accepted.
 */
async function loadMarketplaceImages(pool, userId, listingIds, options = {}) {
  const maxImages = Number.isInteger(options.maxImages)
    ? Math.min(8, Math.max(0, options.maxImages)) : 8;
  const ids = [...new Set((Array.isArray(listingIds) ? listingIds : [])
    .filter(id => typeof id === 'string' && UUID.test(id)).map(id => id.toLowerCase()))].slice(0, 20);
  if (!maxImages || !ids.length) return [];
  const audience = await pool.query(
    `SELECT birth_date <= CURRENT_DATE - INTERVAL '18 years' AS allowed FROM users WHERE id=$1`, [userId]);
  if (audience.rows[0]?.allowed !== true) return [];
  const result = await pool.query(`SELECT l.id AS listing_id, l.user_id AS listing_owner_id,
      i.url AS public_url, sf.id AS stored_file_id, sf.user_id AS file_owner_id,
      sf.storage_path, sf.file_type, sf.file_size, sf.moderation_status,
      sf.content_purged_at, sf.released_at
    FROM listings l
    JOIN LATERAL (
      SELECT url, MIN(sort_order) AS sort_order FROM (
        SELECT li.url, li.sort_order FROM listing_images li WHERE li.listing_id=l.id
        UNION ALL SELECT l.image_url, 0 WHERE l.image_url IS NOT NULL
      ) images GROUP BY url ORDER BY MIN(sort_order), url LIMIT 8
    ) i ON TRUE
    LEFT JOIN stored_files sf ON sf.public_url=i.url
    WHERE l.id=ANY($1::uuid[]) AND l.status='active' AND l.expires_at > now()
      AND ((sf.moderation_status='approved' AND sf.file_type='image'
        AND sf.content_purged_at IS NULL AND sf.user_id=l.user_id
        AND sf.file_size > 0 AND sf.file_size <= $2)
        OR (sf.id IS NULL AND i.url LIKE '/betshuva-app/uploads/demo-listings/%'))
    ORDER BY i.sort_order, array_position($1::uuid[], l.id), i.url LIMIT 160`, [ids, MAX_BYTES]);
  const root = options.uploadRoot || path.join(__dirname, '..', 'uploads');
  const fetchImpl = options.fetchImpl === undefined ? globalThis.fetch : options.fetchImpl;
  const deadline = Date.now() + MAX_LOAD_MS;
  const output = [];
  const seen = new Set();
  let attempts = 0;
  for (const row of result.rows) {
    if (output.length >= maxImages || Date.now() >= deadline || attempts >= maxImages * 2) break;
    if (!ids.includes(row.listing_id)) continue;
    const source = imagePath(row);
    const key = `${row.listing_id}:${row.public_url}`;
    if (!source || seen.has(key)) continue;
    seen.add(key);
    attempts++;
    try {
      let bytes;
      try {
        bytes = await localImageBytes(root, source.relative);
      } catch (error) {
        if (error.code !== 'ENOENT' || !source.mayRestore || typeof fetchImpl !== 'function') continue;
        bytes = await restoredImageBytes(row.public_url, fetchImpl, deadline - Date.now());
      }
      if (Date.now() >= deadline) break;
      const image = sharp(bytes, { limitInputPixels: 25_000_000, pages: 1 });
      const metadata = await image.metadata();
      if (!['jpeg', 'png', 'webp', 'gif'].includes(metadata.format)) continue;
      const encoded = await image.rotate().resize(1280, 1280, {
        fit: 'inside', withoutEnlargement: true,
      }).flatten({ background: '#ffffff' }).jpeg({ quality: 80 })
        .timeout({ seconds: 2 }).toBuffer();
      if (encoded.length > MAX_OUTPUT_BYTES) continue;
      output.push({ listing_id: row.listing_id,
        image_url: `data:image/jpeg;base64,${encoded.toString('base64')}` });
    } catch {
      // One missing, corrupt or unavailable photo must not prevent the answer.
    }
  }
  return output;
}

module.exports = { loadMarketplaceImages };
