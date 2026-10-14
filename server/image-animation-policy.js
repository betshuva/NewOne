'use strict';

const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const ANIMATION_SAMPLE_LIMIT = 20;
const DEFAULT_FRAME_DELAY_MS = 100;

function sampleAnimationFrames(metadata) {
  const frameCount = Number(metadata?.pages ?? 1);
  if (!Number.isSafeInteger(frameCount) || frameCount < 1)
    throw new RangeError('Invalid animation frame count');
  const delays = Array.isArray(metadata?.delay) ? metadata.delay.slice(0, frameCount) : [];
  const ends = [];
  let knownDuration = 0;
  for (const delay of delays) {
    // Missing, zero and malformed delays use a normal short frame duration.
    // Bound representability so malformed finite values cannot overflow time.
    knownDuration += typeof delay === 'number' && Number.isFinite(delay) &&
      delay > 0 && delay <= Number.MAX_SAFE_INTEGER / frameCount
      ? delay : DEFAULT_FRAME_DELAY_MS;
    ends.push(knownDuration);
  }
  const totalDuration = knownDuration + (frameCount - delays.length) * DEFAULT_FRAME_DELAY_MS;
  const startTime = frameIndex => frameIndex < delays.length
    ? (frameIndex === 0 ? 0 : ends[frameIndex - 1])
    : knownDuration + (frameIndex - delays.length) * DEFAULT_FRAME_DELAY_MS;
  if (frameCount <= ANIMATION_SAMPLE_LIMIT) {
    return Array.from({ length: frameCount }, (_, frameIndex) =>
      ({ frameIndex, timeSeconds: startTime(frameIndex) / 1000 }));
  }

  const selected = new Set([0]);
  for (let sample = 1; sample < ANIMATION_SAMPLE_LIMIT - 1; sample++) {
    const time = totalDuration * sample / (ANIMATION_SAMPLE_LIMIT - 1);
    let low = 0, high = ends.length;
    // At a presentation boundary choose the newly displayed frame.
    while (low < high) {
      const middle = Math.floor((low + high) / 2);
      if (ends[middle] <= time) low = middle + 1;
      else high = middle;
    }
    const frameIndex = low < ends.length ? low : delays.length +
      Math.floor((time - knownDuration) / DEFAULT_FRAME_DELAY_MS);
    selected.add(Math.min(frameCount - 1, frameIndex));
  }
  selected.add(frameCount - 1);
  return [...selected].sort((a, b) => a - b).map(frameIndex =>
    ({ frameIndex, timeSeconds: startTime(frameIndex) / 1000 }));
}

function potentialAnimationFormat(buffer) {
  if (!Buffer.isBuffer(buffer) || buffer.length < 12) return null;
  const magic = buffer.subarray(0, 12).toString('ascii');
  // Even a single-frame GIF cannot use a static first-frame cache entry.
  if (magic.startsWith('GIF87a') || magic.startsWith('GIF89a')) return 'gif';
  if (magic.startsWith('RIFF') && magic.slice(8, 12) === 'WEBP') {
    for (let at = 12; at + 8 <= buffer.length;) {
      const type = buffer.subarray(at, at + 4).toString('ascii');
      if (type === 'ANIM' || type === 'ANMF') return 'webp';
      const length = buffer.readUInt32LE(at + 4);
      const next = at + 8 + length + (length % 2);
      if (next > buffer.length) break;
      at = next;
    }
  }
  if (buffer.subarray(0, 8).equals(PNG_SIGNATURE)) {
    for (let at = 8; at + 12 <= buffer.length;) {
      const type = buffer.subarray(at + 4, at + 8).toString('ascii');
      if (type === 'acTL') return 'apng';
      const next = at + 12 + buffer.readUInt32BE(at);
      if (next > buffer.length || type === 'IEND') break;
      at = next;
    }
  }
  return null;
}

function mergedFrameClassification(results) {
  const detected = new Set();
  let uncertain = results.length === 0;
  for (const result of results) {
    const classification = result?.classification;
    const categories = Array.isArray(classification?.detectedCategories) &&
      classification.detectedCategories.length
      ? classification.detectedCategories
      : classification?.category ? [classification.category] : [];
    categories.forEach(category => detected.add(category));
    uncertain ||= classification?.uncertain === true || categories.length === 0;
  }
  // Unknown demographics in any frame must not borrow another frame's known
  // category. This also keeps saved aggregate results conservative for filters.
  if (uncertain) ['men', 'women', 'children'].forEach(category => detected.add(category));
  const detectedCategories = [...detected];
  return {
    category: detectedCategories.length === 1 ? detectedCategories[0] : 'people',
    detectedCategories,
    uncertain,
  };
}

module.exports = { potentialAnimationFormat, mergedFrameClassification,
  sampleAnimationFrames, ANIMATION_SAMPLE_LIMIT };
