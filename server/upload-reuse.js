'use strict';

// The API runs in one process. Queue identical uploads before looking up an
// existing file so two simultaneous requests cannot both miss the first insert.
// No database connection remains checked out while moderation services run.
const uploads = new Map();

async function acquireUploadLock(userId, contentSha256, fileType) {
  const key = JSON.stringify([userId, contentSha256, fileType]);
  const previous = uploads.get(key);
  let resolve;
  const current = new Promise(done => { resolve = done; });
  uploads.set(key, current);
  if (previous) await previous;
  let released = false;
  return () => {
    if (released) return;
    released = true;
    if (uploads.get(key) === current) uploads.delete(key);
    resolve();
  };
}

async function findReusableUpload(pool, {
  userId, contentSha256, fileType, mimeType, fileSize, listingImage,
  moderationVersion, trustedBuiltinExpression = false,
}) {
  const result = await pool.query(
    `SELECT id,public_url FROM stored_files
     WHERE user_id=$1 AND content_sha256=$2 AND file_type=$3 AND mime_type=$4
       AND file_size=$5 AND moderation_status='approved'
       AND content_purged_at IS NULL AND released_at IS NULL
       AND moderation_details->>'moderationVersion'=$6
       AND moderation_details->>'pending' IS DISTINCT FROM 'true'
       AND moderation_details->>'blocked' IS DISTINCT FROM 'true'
       AND ($8::boolean OR (
         moderation_details->>'source' IS DISTINCT FROM 'builtin-expression'
         AND moderation_details->>'scanSkipped' IS DISTINCT FROM 'true'))
       AND (COALESCE(context_type,'general')='listing')=$7::boolean
       AND public_url IS NOT NULL AND public_url<>''
     ORDER BY created_at DESC,id DESC LIMIT 1`,
    [userId, contentSha256, fileType, mimeType, fileSize, moderationVersion,
      listingImage === true, trustedBuiltinExpression === true]);
  // A released file may need unavailable Drive credentials to restore; retain
  // the newly uploaded bytes instead of returning that potentially unusable URL.
  // Listing cleanup owns its URLs separately; never reuse across that boundary.
  return result.rows[0] || null;
}

module.exports = { acquireUploadLock, findReusableUpload };
