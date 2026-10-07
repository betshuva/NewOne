'use strict';

const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const execFileAsync = promisify(execFile);
const MAX_LISTING_VIDEO_SECONDS = 10;
const VIDEO_PROBE_VERSION = 'pyav-listing-v1';

function listingVideoError(code, message) {
  return Object.assign(new Error(message), { status: 400, code });
}

function validateListingVideoDuration(value) {
  const duration = Number(value);
  if (!Number.isFinite(duration) || duration <= 0)
    throw listingVideoError('LISTING_VIDEO_DURATION_UNKNOWN', 'לא ניתן לזהות את משך הסרטון. יש לצלם שוב');
  if (duration > MAX_LISTING_VIDEO_SECONDS + 1e-6)
    throw listingVideoError('LISTING_VIDEO_TOO_LONG', 'אפשר לצרף למודעה סרטון באורך עד 10 שניות');
  return duration;
}

async function probeListingVideo(source, fileName) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'betshuva-listing-video-'));
  try {
    const input = Buffer.isBuffer(source) ? path.join(directory, 'input.video') : source.path;
    if (Buffer.isBuffer(source)) await fs.writeFile(input, source, { flag: 'wx', mode: 0o600 });
    const python = process.env.WHISPER_PYTHON || path.join(__dirname, '..', '.venv-whisper', 'bin', 'python');
    let result;
    try {
      const { stdout } = await execFileAsync(python,
        [path.join(__dirname, '..', 'scripts', 'listing_video_probe.py'), input],
        { timeout: 15000, maxBuffer: 64 * 1024 });
      result = JSON.parse(stdout);
    } catch (error) {
      let diagnostic;
      try { diagnostic = JSON.parse(error.stderr || '{}'); } catch (_) {}
      if (diagnostic?.code === 'LISTING_VIDEO_TOO_LONG')
        throw listingVideoError(diagnostic.code, 'אפשר לצרף למודעה סרטון באורך עד 10 שניות');
      throw listingVideoError('LISTING_VIDEO_DURATION_UNKNOWN', 'לא ניתן לבדוק את משך הסרטון. יש לצלם שוב או לנסות מאוחר יותר');
    }
    return { durationSeconds: validateListingVideoDuration(result.durationSeconds),
      source: VIDEO_PROBE_VERSION };
  } finally { await fs.rm(directory, { recursive: true, force: true }); }
}

function objectScanApproved(details) {
  const classification = details.classification || {};
  const categories = Array.isArray(classification.detectedCategories) ? classification.detectedCategories : [];
  const people = ['men', 'women', 'children', 'people'];
  const hasPeople = (Array.isArray(details.faces) && details.faces.length > 0) ||
    categories.some(value => people.includes(value)) || people.includes(classification.category) ||
    details.googleObjectLocalization?.personDetected === true || details.googleFaceDetection?.faceDetected === true;
  const uncertain = classification.uncertain === true || !classification.category || categories.length === 0;
  return !hasPeople && ((classification.category === 'nonHumanImages' && !uncertain) ||
    (uncertain && details.googleObjectLocalization?.available === true &&
      details.googleObjectLocalization.personDetected === false));
}

function scanApproved(details) {
  return details.pending !== true && details.blocked !== true && details.scanStopped !== true &&
    details.senderFilterRejected !== true && details.destinationFilterRejected !== true &&
    details.deliveryRejected !== true && details.scanSkipped !== true && details.source !== 'builtin-expression';
}

// released_at records verified local-disk offload, not removal of the media.
// The caller supplies owner-bound readiness evidence from the saved vault copy.
function listingMediaAvailable(file) {
  return !file.content_purged_at && (!file.released_at || file.backup_available === true);
}

function listingVideoApproved(file) {
  const details = file.moderation_details || {};
  const classification = details.classification || {};
  const frames = details.frameResults;
  const proof = details.listingVideoProof;
  if (file.file_type !== 'video' || file.context_type !== 'listing' ||
      !String(file.mime_type || '').startsWith('video/') || file.moderation_status !== 'approved' ||
      !listingMediaAvailable(file) || !scanApproved(details) ||
      proof?.source !== VIDEO_PROBE_VERSION || classification.category !== 'video' ||
      classification.uncertain !== false || !Array.isArray(frames) || frames.length < 1 ||
      frames.length !== classification.sampledFrames || frames.length !== classification.fullyScannedFrames)
    return false;
  try {
    validateListingVideoDuration(proof.durationSeconds);
    validateListingVideoDuration(classification.durationSeconds);
  } catch (_) { return false; }
  return frames.every(frame => frame && scanApproved(frame) && objectScanApproved(frame));
}

module.exports = { MAX_LISTING_VIDEO_SECONDS, VIDEO_PROBE_VERSION, validateListingVideoDuration,
  probeListingVideo, objectScanApproved, scanApproved, listingMediaAvailable, listingVideoApproved };
