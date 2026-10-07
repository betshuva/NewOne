'use strict';

const MAX_LISTING_IMAGES = 8;
const { objectScanApproved, scanApproved, listingMediaAvailable, listingVideoApproved } = require('./listing-video-policy');
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

// Both release workers verify the live remote bytes before setting released_at.
// Retain their owner/hash binding and readable-account requirements here so a
// completed scan can still attach media after local disk space has been freed.
const BACKUP_AVAILABLE_SQL = `(
  EXISTS(SELECT 1 FROM media_backup_items mbi
    JOIN user_backup_settings s ON s.user_id=sf.user_id
    JOIN cloud_backup_accounts c ON c.user_id=sf.user_id AND c.provider='google_drive'
    WHERE mbi.stored_file_id=sf.id AND mbi.user_id=sf.user_id
      AND mbi.provider='google_drive' AND mbi.status='verified'
      AND mbi.remote_file_id IS NOT NULL AND mbi.restore_verified_at IS NOT NULL
      AND mbi.encryption_metadata->>'keySource'='server_vault'
      AND mbi.plaintext_sha256=sf.content_sha256
      AND s.encrypted_data_key IS NOT NULL AND c.status='connected'
      AND c.encrypted_refresh_token IS NOT NULL)
  OR EXISTS(SELECT 1 FROM central_drive_objects o JOIN central_drive_account a ON a.id=1
    WHERE o.file_id=sf.id AND o.owner_id=sf.user_id AND o.status='verified'
      AND o.remote_file_id IS NOT NULL AND o.encrypted_data_key IS NOT NULL
      AND o.encrypted_sha256 IS NOT NULL AND o.encryption_metadata IS NOT NULL
      AND o.plaintext_sha256=sf.content_sha256 AND o.file_size=sf.file_size
      AND a.encrypted_token IS NOT NULL)
)`;

function imageError(status, code, message) {
  return Object.assign(new Error(message), { status, code });
}

function imageUrl(value) {
  if (typeof value !== 'string' || !value.trim() || value.length > 4096)
    throw imageError(400, 'INVALID_LISTING_IMAGE', 'כתובת התמונה אינה תקינה');
  return value.trim();
}

function normalizeImageChanges(body = {}) {
  if (!body || typeof body !== 'object' || Array.isArray(body))
    throw imageError(400, 'INVALID_LISTING_IMAGES', 'פרטי התמונות אינם תקינים');
  const urls = body.image_urls === undefined ? [] : body.image_urls;
  const replacements = body.replacements === undefined ? [] : body.replacements;
  if (!Array.isArray(urls) || !Array.isArray(replacements) ||
      urls.length > MAX_LISTING_IMAGES || replacements.length > MAX_LISTING_IMAGES)
    throw imageError(400, 'INVALID_LISTING_IMAGES', 'ניתן לצרף עד 8 תמונות למודעה');
  const imageUrls = [...new Set(urls.map(imageUrl))];
  const normalizedReplacements = replacements.map(value => {
    if (!value || typeof value !== 'object' || Array.isArray(value))
      throw imageError(400, 'INVALID_LISTING_IMAGE', 'פרטי החלפת התמונה אינם תקינים');
    return { expected_old_url: imageUrl(value.expected_old_url), url: imageUrl(value.url) };
  });
  if (new Set(normalizedReplacements.map(value => value.expected_old_url)).size !== normalizedReplacements.length)
    throw imageError(400, 'INVALID_LISTING_IMAGES', 'לא ניתן להחליף תמונה פעמיים באותה בקשה');
  const newUrls = [...new Set([...imageUrls, ...normalizedReplacements.map(value => value.url)])];
  if ((!newUrls.length && !Object.hasOwn(body, 'video_url')) || newUrls.length > MAX_LISTING_IMAGES)
    throw imageError(400, 'INVALID_LISTING_IMAGES', 'יש לצרף 1 עד 8 תמונות');
  return { imageUrls, replacements: normalizedReplacements, newUrls };
}

// A delayed scan can complete without repeating the upload route's listing
// restriction. Verify the saved evidence as well as its approval before adding
// the image; a general-media approval alone does not allow people in listings.
function listingImageApproved(file) {
  const details = file.moderation_details || {};
  return file.file_type === 'image' && file.context_type === 'listing' &&
    file.moderation_status === 'approved' && listingMediaAvailable(file) &&
    scanApproved(details) && objectScanApproved(details);
}

function normalizeListingVideoChange(body = {}) {
  const supplied = Object.hasOwn(body, 'video_url');
  if (Object.hasOwn(body, 'video_urls'))
    throw imageError(400, 'LISTING_VIDEO_LIMIT', 'ניתן לצרף למודעה סרטון אחד בלבד');
  if (!supplied) return { supplied: false };
  const url = body.video_url === null ? null : imageUrl(body.video_url);
  const expected = body.expected_old_video_url == null ? null : imageUrl(body.expected_old_video_url);
  return { supplied, url, expected };
}

function mergeListingVideo(current, change) {
  current ||= null;
  if (!change.supplied || current === change.url) return current;
  if (current !== change.expected)
    throw imageError(409, 'LISTING_VIDEO_CHANGED', 'הסרטון השתנה מאז תחילת ההעלאה; יש לרענן את המודעה');
  return change.url;
}

async function validateListingMedia(db, userId, images, video) {
  if (!Array.isArray(images) || images.length > MAX_LISTING_IMAGES)
    throw imageError(400, 'INVALID_LISTING_IMAGES', 'ניתן לצרף עד 8 תמונות למודעה');
  const imageUrls = [...new Set(images.map(imageUrl))];
  const videoUrl = video == null ? null : imageUrl(video);
  const urls = [...new Set([...imageUrls, ...(videoUrl ? [videoUrl] : [])])];
  if (!urls.length) return;
  const files = await db.query(
    `SELECT sf.public_url,sf.file_type,sf.mime_type,sf.context_type,sf.moderation_status,sf.moderation_details,
            sf.content_purged_at,sf.released_at,${BACKUP_AVAILABLE_SQL} AS backup_available
     FROM stored_files sf WHERE sf.user_id=$1 AND sf.public_url=ANY($2::text[]) ORDER BY sf.id FOR SHARE OF sf`,
    [userId, urls]);
  const byUrl = new Map(files.rows.map(file => [file.public_url, file]));
  if (imageUrls.some(url => !byUrl.has(url) || !listingImageApproved(byUrl.get(url))))
    throw imageError(400, 'LISTING_IMAGE_NOT_APPROVED', 'אחת התמונות אינה זמינה או לא אושרה להצגה במודעה');
  if (videoUrl && (!byUrl.has(videoUrl) || !listingVideoApproved(byUrl.get(videoUrl))))
    throw imageError(400, 'LISTING_VIDEO_NOT_APPROVED', 'הסרטון אינו זמין או לא אושר; מותר סרטון ללא אנשים באורך עד 10 שניות');
}

function mergeListingImages(current, changes) {
  const images = [...new Set(current.filter(Boolean))];
  for (const replacement of changes.replacements) {
    const index = images.indexOf(replacement.expected_old_url);
    if (index === -1) {
      // A repeated successful request is safe, but an intervening replacement
      // must not be silently overwritten by a late background upload.
      if (images.includes(replacement.url)) continue;
      throw imageError(409, 'LISTING_IMAGE_CHANGED', 'התמונה השתנתה מאז תחילת ההעלאה; יש לרענן את המודעה');
    }
    if (replacement.expected_old_url === replacement.url) continue;
    if (images.includes(replacement.url))
      throw imageError(409, 'DUPLICATE_LISTING_IMAGE', 'התמונה החדשה כבר מצורפת למודעה');
    images[index] = replacement.url;
  }
  for (const url of changes.imageUrls) if (!images.includes(url)) images.push(url);
  if (images.length > MAX_LISTING_IMAGES)
    throw imageError(409, 'LISTING_IMAGE_LIMIT', 'במודעה כבר יש תמונות; ניתן לצרף עד 8 תמונות בסך הכול');
  return images;
}

async function getListingImageStatuses(pool, userId, body) {
  const imageUrls = Array.isArray(body?.image_urls) && body.image_urls.length === 0 ? []
    : body?.image_urls === undefined ? [] : normalizeImageChanges({ image_urls: body.image_urls }).imageUrls;
  const rawVideos = body?.video_urls === undefined ? [] : body.video_urls;
  if (!Array.isArray(rawVideos) || rawVideos.length > 1 || !imageUrls.length && !rawVideos.length)
    throw imageError(400, 'INVALID_LISTING_MEDIA', 'יש לבחור עד 8 תמונות או סרטון אחד');
  const videoUrls = rawVideos.map(imageUrl);
  const files = await pool.query(
    `SELECT sf.public_url,sf.file_type,sf.mime_type,sf.context_type,sf.moderation_status,sf.moderation_details,
            sf.content_purged_at,sf.released_at,${BACKUP_AVAILABLE_SQL} AS backup_available
     FROM stored_files sf WHERE sf.user_id=$1 AND sf.public_url=ANY($2::text[])`,
    [userId, [...imageUrls, ...videoUrls]]);
  const byUrl = new Map(files.rows.map(file => [file.public_url, file]));
  const status = (url, type, approved) => {
    const file = byUrl.get(url);
    const label = type === 'video' ? 'הסרטון' : 'התמונה';
    if (!file || file.file_type !== type || file.context_type !== 'listing' ||
        !listingMediaAvailable(file))
      return { url, status: 'unavailable', reason: `${label} אינו זמין` };
    if (file.moderation_status === 'pending')
      return { url, status: 'pending', reason: `${label} ממתין לסריקה` };
    if (approved(file)) return { url, status: 'approved' };
    const details = file.moderation_details || {};
    const reason = typeof details.reason === 'string' ? details.reason.slice(0, 300)
      : type === 'video' ? 'הסרטון לא אושר; מותר סרטון ללא אנשים באורך עד 10 שניות'
        : 'התמונה לא אושרה להצגה במודעה; מותרות רק תמונות ללא אנשים';
    return { url, status: 'rejected', reason };
  };
  return { images: imageUrls.map(url => status(url, 'image', listingImageApproved)),
    videos: videoUrls.map(url => status(url, 'video', listingVideoApproved)) };
}

async function attachListingImages(pool, userId, listingId, body) {
  if (!UUID.test(String(listingId || '')))
    throw imageError(400, 'INVALID_LISTING_ID', 'מזהה המודעה אינו תקין');
  const changes = normalizeImageChanges(body);
  const videoChange = normalizeListingVideoChange(body);
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const listing = await client.query(
      'SELECT image_url,video_url FROM listings WHERE id=$1 AND user_id=$2 FOR UPDATE',
      [listingId, userId]);
    if (!listing.rows.length) throw imageError(404, 'LISTING_NOT_FOUND', 'המודעה לא נמצאה');
    await validateListingMedia(client, userId, changes.newUrls, videoChange.supplied ? videoChange.url : null);
    const current = await client.query(
      'SELECT url FROM listing_images WHERE listing_id=$1 ORDER BY sort_order,id', [listingId]);
    const previousImages = current.rows.length ? current.rows.map(row => row.url)
      : listing.rows[0].image_url ? [listing.rows[0].image_url] : [];
    const images = mergeListingImages(previousImages, changes);
    const video = mergeListingVideo(listing.rows[0].video_url, videoChange);
    // Only image fields are changed. Content, price, status and expiry edited
    // while the upload ran are preserved.
    await client.query('UPDATE listings SET image_url=$1,video_url=$2 WHERE id=$3', [images[0] || null, video, listingId]);
    await client.query('DELETE FROM listing_images WHERE listing_id=$1', [listingId]);
    for (let index = 0; index < images.length; index++) {
      await client.query('INSERT INTO listing_images(listing_id,url,sort_order) VALUES($1,$2,$3)',
        [listingId, images[index], index]);
    }
    await client.query('COMMIT');
    return { ok: true, images, image_url: images[0] || null, video_url: video };
  } catch (error) {
    try { await client.query('ROLLBACK'); } catch (_) {}
    throw error;
  } finally {
    client.release();
  }
}

function registerListingBackgroundImages(app, { auth, getPool, logActivity = () => {} }) {
  app.post('/api/listings/:id/images', auth, async (req, res) => {
    if (req.user.isTeen)
      return res.status(403).json({ error: 'לוח המודעות אינו זמין בחשבון נוער', code: 'TEEN_LISTINGS_DISABLED' });
    try {
      const result = await attachListingImages(await getPool(), req.user.id, req.params.id, req.body);
      logActivity(req.user.id, 'attach_listing_images', { id: req.params.id, imageCount: result.images.length }, req.ip);
      res.set('Cache-Control', 'no-store');
      res.json(result);
    } catch (error) {
      res.status(error.status || 500).json({ error: error.status ? error.message : 'צירוף התמונות למודעה נכשל', code: error.code });
    }
  });
  app.post('/api/listing-image-status', auth, async (req, res) => {
    if (req.user.isTeen)
      return res.status(403).json({ error: 'לוח המודעות אינו זמין בחשבון נוער', code: 'TEEN_LISTINGS_DISABLED' });
    try {
      const result = await getListingImageStatuses(await getPool(), req.user.id, req.body);
      res.set('Cache-Control', 'no-store');
      res.json(result);
    } catch (error) {
      res.status(error.status || 500).json({ error: error.status ? error.message : 'בדיקת מצב התמונה נכשלה', code: error.code });
    }
  });
}

module.exports = { MAX_LISTING_IMAGES, normalizeImageChanges, listingImageApproved,
  normalizeListingVideoChange, mergeListingVideo, validateListingMedia,
  mergeListingImages, getListingImageStatuses, attachListingImages, registerListingBackgroundImages };
