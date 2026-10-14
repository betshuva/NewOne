'use strict';

const { contentAllowedByFilter, normalizeContentFilter } = require('./content-filter-policy');
const { getProfileAssetMetadata } = require('./profile-image-assets');
const { projectAudience, PHOTO_BASE, signedPhotoUrl } = require('./profile-photo-audience');

const IMAGE_CATEGORIES = ['men', 'women', 'children', 'nonHumanImages'];
// Built-in guide assets have known categories. Additional legacy portraits
// are verified against their reviewed bytes by getProfileAssetMetadata.
// Arbitrary URLs and account gender are never image-classification evidence.
const BUILTIN_PROFILE_CLASSIFICATIONS = new Map([
  ['/betshuva-app/assets/assets/guide/israel-profile-20260907.png', { category: 'men' }],
  ['/betshuva-app/assets/assets/guide/safe-information-ai.png', { category: 'nonHumanImages' }],
]);

function profileImageAllowed(url, filter, storedFile) {
  if (typeof url !== 'string' || !url.trim()) return false;
  if (url.startsWith('emoji:')) return true;
  const normalized = normalizeContentFilter(filter);
  let classification;
  if (storedFile) {
    if (storedFile.moderation_status !== 'approved' || storedFile.file_type !== 'image' ||
        storedFile.content_purged_at || storedFile.blocked === true) return false;
    classification = storedFile.classification;
  } else {
    classification = BUILTIN_PROFILE_CLASSIFICATIONS.get(url);
  }
  if (!classification || (!classification.category && !classification.detectedCategories?.length))
    return IMAGE_CATEGORIES.every(category => normalized[category] === true);
  return contentAllowedByFilter(normalized, 'image', classification);
}

async function projectProfileImages(pool, viewerId, rows, {
  fields = ['profile_pic_url'], resolveAsset = getProfileAssetMetadata,
} = {}) {
  if (!rows.length) return rows;
  rows = await projectAudience(pool, viewerId, rows, fields);
  const urls = [...new Set(rows.flatMap(row => fields.map(field => row[field]))
    .filter(url => typeof url === 'string' && url && !url.startsWith('emoji:')))];
  if (!urls.length) return rows;
  // Read preferences for each response so a setting change applies to the
  // next list refresh, including existing contacts and external legacy photos.
  const [viewer, files] = await Promise.all([
    pool.query('SELECT content_filter FROM users WHERE id=$1', [viewerId]),
    pool.query(`SELECT public_url, file_type, moderation_status, content_purged_at,
        moderation_details->'classification' AS classification,
        moderation_details->'blocked' AS blocked
      FROM stored_files WHERE public_url=ANY($1::text[])
      UNION ALL SELECT '${PHOTO_BASE}' || a.id::text AS public_url, 'image' AS file_type,
        COALESCE(sf.moderation_status,'approved') AS moderation_status,NULL AS content_purged_at,
        COALESCE(sf.moderation_details->'classification',a.classification) AS classification,
        sf.moderation_details->'blocked' AS blocked
        FROM profile_photo_assets a LEFT JOIN stored_files sf ON sf.public_url=a.source_url
        WHERE '${PHOTO_BASE}' || a.id::text=ANY($1::text[])`, [urls]),
  ]);
  const filter = viewer.rows[0]?.content_filter ||
    Object.fromEntries(IMAGE_CATEGORIES.map(category => [category, false]));
  const byUrl = new Map(files.rows.map(file => [file.public_url, file]));
  // Curated legacy portraits predate stored_files. Only verified asset bytes
  // supply missing metadata; an existing scan (including rejection) always wins.
  await Promise.all(urls.filter(url => !byUrl.has(url)).map(async url => {
    const asset = await resolveAsset(url);
    if (asset) byUrl.set(url, asset);
  }));
  return rows.map(row => {
    const projected = { ...row };
    for (const field of fields) {
      if (Object.hasOwn(row, field) &&
          !profileImageAllowed(row[field], filter, byUrl.get(row[field]))) projected[field] = null;
      else if (Object.hasOwn(row, field)) projected[field] = signedPhotoUrl(row[field], viewerId);
    }
    return projected;
  });
}

module.exports = { profileImageAllowed, projectProfileImages };
