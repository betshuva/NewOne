'use strict';

const { createHash, randomUUID } = require('node:crypto');

const REVIEW_VERSION = 'visible-areas-review-v1';
const MAX_IMAGE_REVIEWS = 3;
const SCHEMA = `CREATE TABLE IF NOT EXISTS image_modesty_uncertainty_reviews (
  id uuid PRIMARY KEY,
  stored_file_id uuid NOT NULL REFERENCES stored_files(id) ON DELETE CASCADE,
  content_sha256 text NOT NULL CHECK (content_sha256 ~ '^[a-f0-9]{64}$'),
  review_version text NOT NULL,
  provider text NOT NULL CHECK (provider IN ('gemini','openai')),
  status text NOT NULL CHECK (status IN ('reserved','completed')),
  result jsonb,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  completed_at timestamptz,
  UNIQUE (stored_file_id,content_sha256,review_version)
);`;

function clearlyCompliant(review) {
  return review?.available === true && review.status === 'completed' &&
    review.decision === 'modest' && Number.isFinite(review.confidence) &&
    review.confidence >= 0.85 && review.violationClearlyVisible === false &&
    review.visibleAreasDecision === 'compliant' &&
    ['none', 'out_of_frame_only'].includes(review.uncertaintyReason) &&
    typeof review.visibleEvidence === 'string' && review.visibleEvidence.trim().length >= 5;
}

function clearlyViolating(review) {
  return review?.available === true && review.decision === 'non_modest' &&
    (review.status === 'safety_blocked' || review.violationClearlyVisible === true &&
      Number.isFinite(review.confidence) && review.confidence >= 0.85);
}

function uncertaintyReviewProvider(options) {
  if (!options.verifiedPeople || !options.classification?.category ||
      options.classification.uncertain === true ||
      options.googleSafeSearch?.available !== true ||
      options.googleSafeSearch.blocked === true || options.googleSafeSearch.uncertain === true ||
      options.localSafety?.available !== true || options.localSafety.wouldBlock === true)
    return null;
  const required = [['gemini', options.geminiModestyVerification],
    ...(options.requireOpenAI ? [['openai', options.modestyVerification]] : [])];
  const unresolved = required.filter(([, review]) => review?.available !== true || review.decision !== 'modest');
  // One additional request cannot resolve two independent missing decisions.
  if (unresolved.length !== 1) return null;
  const [provider, review] = unresolved[0];
  if (review?.available !== true || review.status !== 'completed' ||
      review.decision !== 'uncertain' || review.violationClearlyVisible !== false ||
      !['compliant', 'uncertain'].includes(review.visibleAreasDecision) ||
      !['none', 'out_of_frame_only', 'visible_area_ambiguous'].includes(review.uncertaintyReason) ||
      typeof review.visibleEvidence !== 'string' || review.visibleEvidence.trim().length < 5)
    return null;
  if (required.some(([name, result]) => name !== provider && !clearlyCompliant(result))) return null;
  // Optional evidence cannot override an actual visible violation either.
  if (options.useOpenAI && clearlyViolating(options.modestyVerification)) return null;
  return provider;
}

function createImageReviewState() {
  return { used: 0, entries: new Map() };
}

async function reserveImageReview(pool, { storedFileId, contentSha256, reviewVersion, provider }) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const file = await client.query('SELECT id FROM stored_files WHERE id=$1 FOR UPDATE', [storedFileId]);
    if (!file.rows.length) {
      await client.query('ROLLBACK');
      return { status: 'stopped', reasonCode: 'source_unavailable' };
    }
    const existing = await client.query(`SELECT provider,status,result FROM image_modesty_uncertainty_reviews
      WHERE stored_file_id=$1 AND content_sha256=$2 AND review_version=$3`,
    [storedFileId, contentSha256, reviewVersion]);
    if (existing.rows.length) {
      const row = existing.rows[0];
      await client.query('COMMIT');
      if (row.provider !== provider) return { status: 'stopped', reasonCode: 'uncertainty_review_limit' };
      return row.status === 'completed' && row.result
        ? { status: 'cached', result: row.result }
        : { status: 'stopped', reasonCode: 'operation_outcome_unknown' };
    }
    const count = await client.query(`SELECT count(*)::integer AS used FROM image_modesty_uncertainty_reviews
      WHERE stored_file_id=$1`, [storedFileId]);
    // Static images need one review. This also bounds animated/document images
    // sharing a stored-file identity, rather than adding a review per page forever.
    if (count.rows[0].used >= MAX_IMAGE_REVIEWS) {
      await client.query('COMMIT');
      return { status: 'stopped', reasonCode: 'uncertainty_review_limit' };
    }
    const id = randomUUID();
    await client.query(`INSERT INTO image_modesty_uncertainty_reviews
      (id,stored_file_id,content_sha256,review_version,provider,status)
      VALUES($1,$2,$3,$4,$5,'reserved')`, [id, storedFileId, contentSha256, reviewVersion, provider]);
    await client.query('COMMIT');
    return { status: 'reserved', id };
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    throw error;
  } finally { client.release(); }
}

async function finishImageReview(pool, id, result) {
  const persisted = JSON.parse(JSON.stringify(result, (key, value) => key === 'signal' ? undefined : value));
  const saved = await pool.query(`UPDATE image_modesty_uncertainty_reviews
    SET status='completed',result=$1,completed_at=clock_timestamp()
    WHERE id=$2 AND status='reserved' RETURNING id`, [JSON.stringify(persisted), id]);
  return saved.rows.length === 1;
}

async function reviewModestyUncertainty(buffer, options) {
  const provider = uncertaintyReviewProvider(options);
  if (!provider) return null;
  if (String(process.env.MODERATION_UNCERTAINTY_REVIEW_ENABLED || '').trim().toLowerCase() === 'false')
    return { provider, attempted: false, resolution: 'unresolved', reasonCode: 'uncertainty_review_disabled' };
  if (options.signal?.aborted)
    return { provider, attempted: false, resolution: 'unresolved', reasonCode: 'deadline_exceeded' };
  const deps = options.reviewDependencies || {};
  let pool, reservation;
  const trackedImage = !options.tracking?.videoBudget && options.tracking?.storedFileId;
  const transient = !options.tracking?.videoBudget && !trackedImage ? options.reviewState : null;
  const contentSha256 = createHash('sha256').update(buffer).digest('hex');
  if (transient) {
    const existing = transient.entries.get(contentSha256);
    if (existing) {
      if (existing.provider !== provider)
        return { provider, attempted: false, resolution: 'unresolved', reasonCode: 'uncertainty_review_limit' };
      if (existing.status !== 'completed')
        return { provider, attempted: false, resolution: 'unresolved', reasonCode: 'operation_outcome_unknown' };
      reservation = { status: 'cached', result: existing.result };
    } else {
      if (transient.used >= MAX_IMAGE_REVIEWS)
        return { provider, attempted: false, resolution: 'unresolved', reasonCode: 'uncertainty_review_limit' };
      transient.used++;
      transient.entries.set(contentSha256, { provider, status: 'reserved' });
    }
  }
  if (trackedImage) {
    try {
      pool = deps.pool || await (deps.getPool || require('./db').getPool)();
      reservation = await (deps.reserveImageReview || reserveImageReview)(pool, {
        storedFileId: options.tracking.storedFileId,
        contentSha256,
        reviewVersion: `${options.reviewVersion || ''}:${REVIEW_VERSION}`, provider,
      });
    } catch (_) { reservation = { status: 'stopped', reasonCode: 'provider_guard_unavailable' }; }
    if (!reservation || !['reserved', 'cached'].includes(reservation.status))
      return { provider, attempted: false, resolution: 'unresolved',
        reasonCode: reservation?.reasonCode || 'provider_guard_unavailable' };
    if (reservation.status === 'cached' && (!reservation.result || typeof reservation.result !== 'object'))
      return { provider, attempted: false, resolution: 'unresolved', reasonCode: 'operation_outcome_unknown' };
  }
  let result;
  try {
    result = reservation?.status === 'cached'
      ? { ...reservation.result, cacheHit: true }
      : await options.reviewProvider(provider, buffer, { tracking: options.tracking, signal: options.signal });
  } catch (_) { result = { available: false, status: 'error', errorCode: 'REQUEST_FAILED' }; }
  if (transient && reservation?.status !== 'cached')
    transient.entries.set(contentSha256, { provider, status: 'completed', result });
  if (reservation?.status === 'cached') {
    await (deps.recordProviderCheck || require('./provider-usage-log').recordProviderCheck)({
      provider, operation: 'modesty_uncertainty_review', tracking: options.tracking,
      result, cacheHit: true, model: result.model, durationMs: 0,
    }).catch(() => {});
  }
  if (reservation?.status === 'reserved') {
    try {
      if (!await (deps.finishImageReview || finishImageReview)(pool, reservation.id, result))
        throw new Error('review acknowledgement missing');
    } catch (_) {
      return { provider, attempted: true, result, resolution: 'unresolved', reasonCode: 'provider_guard_unavailable' };
    }
  }
  const resolution = clearlyCompliant(result) ? 'approved'
    : clearlyViolating(result) ? 'blocked' : 'unresolved';
  const reasonCode = resolution !== 'unresolved' ? undefined
    : result?.reasonCode || (result?.available !== true ? 'provider_error' : 'modesty_uncertain');
  return { provider, attempted: true, ...(reservation?.status === 'cached' ? { cacheHit: true } : {}),
    resolution, result, ...(reasonCode ? { reasonCode } : {}) };
}

function stoppedImageResult(reasonCode, previous = {}) {
  const reasons = {
    modesty_uncertain: 'לא ניתן להכריע אם הלבוש הנראה עומד בכללים',
    provider_error: 'בדיקת הסינון לא הושלמה בגלל תקלה בשירות הבדיקה',
    uncertainty_review_limit: 'מכסת בדיקות ההכרעה לקובץ מוצתה',
    uncertainty_review_disabled: 'לא התקבל אישור ברור בבדיקת הסינון',
    provider_guard_unavailable: 'לא ניתן לאמת את מכסת בדיקות ההכרעה',
    operation_outcome_unknown: 'תוצאת בדיקת הכרעה קודמת אינה ידועה',
  };
  return { ...previous, blocked: false, pending: false, stopped: true, scanStopped: true,
    retryable: false, reasonCode, reason: `הסריקה נעצרה: ${reasons[reasonCode] || 'בדיקה נדרשת לא הושלמה'}`,
    classification: { ...(previous.classification || {}), uncertain: true } };
}

module.exports = { SCHEMA, REVIEW_VERSION, MAX_IMAGE_REVIEWS, clearlyCompliant,
  createImageReviewState, uncertaintyReviewProvider, reserveImageReview, finishImageReview,
  reviewModestyUncertainty, stoppedImageResult };
