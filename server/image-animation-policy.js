'use strict';

const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

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

module.exports = { potentialAnimationFormat, mergedFrameClassification };
