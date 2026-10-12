'use strict';

const crypto = require('node:crypto');

class UnicodeEmojiModerationError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

function emojiModerationError(error) {
  if (error instanceof UnicodeEmojiModerationError) return error;
  if (error?.code === 'UNSUPPORTED_EMOJI') return new UnicodeEmojiModerationError(
    422, 'UNSUPPORTED_EMOJI',
    'לא נמצא איור מתאים לסריקת אחד האימוג׳ים. ההודעה לא נשלחה; אפשר לבחור אימוג׳י אחר.');
  return new UnicodeEmojiModerationError(503, 'EMOJI_SCAN_PENDING',
    'סריקת האימוג׳י לא הושלמה. ההודעה לא נשלחה; אפשר לנסות שוב.');
}

// Results describe immutable artwork, never a user's receiving preferences.
// Every destination must apply its current policy after this safety check.
function createUnicodeEmojiModerator({ extractEmoji, loadArtwork, scanImage,
  moderationVersion, artworkVersion, recordCheck = async () => {},
  now = Date.now, cacheLimit = 512, cacheTtlMs = 24 * 60 * 60 * 1000,
  maxUnfamiliarEmoji = 16 }) {
  const cache = new Map();
  const inFlight = new Map();
  const version = `${moderationVersion}:${artworkVersion}`;

  function validClassification(classification) {
    if (!classification?.category || classification.uncertain === true) return false;
    const categories = classification.detectedCategories?.length
      ? classification.detectedCategories : [classification.category];
    return Array.isArray(categories) && categories.every(category =>
      ['nonHumanImages', 'men', 'women', 'children', 'people'].includes(category));
  }

  function cached(code) {
    const entry = cache.get(code);
    if (!entry) return null;
    cache.delete(code);
    if (entry.expiresAt <= now()) return null;
    cache.set(code, entry);
    return structuredClone(entry.result);
  }

  function retain(code, result) {
    if (result.pending || result.scanStopped ||
        result.classification?.uncertain === true ||
        (result.blocked !== true &&
          (result.blocked !== false || !validClassification(result.classification)))) return;
    const summary = { blocked: result.blocked === true,
      blockedBy: result.blockedBy || null,
      classification: result.classification || null };
    cache.delete(code);
    cache.set(code, { expiresAt: now() + cacheTtlMs,
      result: structuredClone(summary) });
    while (cache.size > cacheLimit) cache.delete(cache.keys().next().value);
  }

  async function inspectGlyph(glyph, tracking) {
    const hit = cached(glyph.code);
    if (hit) {
      await recordCheck({ provider: 'cache', operation: 'unicode_emoji',
        tracking, result: hit, cacheHit: true });
      return hit;
    }
    if (inFlight.has(glyph.code)) {
      const result = structuredClone(await inFlight.get(glyph.code));
      await recordCheck({ provider: 'cache', operation: 'unicode_emoji',
        tracking, result, cacheHit: true });
      return result;
    }
    const pending = (async () => {
      const artwork = await loadArtwork(glyph);
      if (!Buffer.isBuffer(artwork) || !artwork.length)
        throw new Error('emoji_artwork_missing');
      const result = await scanImage(artwork, { tracking });
      if (!result || typeof result !== 'object')
        throw new Error('emoji_scan_result_missing');
      retain(glyph.code, result);
      return result;
    })();
    inFlight.set(glyph.code, pending);
    try { return await pending; }
    finally { inFlight.delete(glyph.code); }
  }

  async function inspect(text, { userId, attempt = 1 } = {}) {
    const unfamiliar = extractEmoji(text).filter(glyph => !glyph.knownApproved);
    if (!unfamiliar.length) return null;
    if (unfamiliar.length > maxUnfamiliarEmoji)
      throw new UnicodeEmojiModerationError(422, 'EMOJI_SCAN_LIMIT',
        'בהודעה יש יותר מדי אימוג׳ים שונים שדורשים סריקה. אפשר לפצל אותה להודעות קצרות יותר.');
    const categories = new Set();
    const codes = [];
    try {
      for (const glyph of unfamiliar) {
        const result = await inspectGlyph(glyph,
          { userId, workflow: 'unicode_emoji', attempt });
        if (result.blocked === true)
          throw new UnicodeEmojiModerationError(422, 'EMOJI_CONTENT_BLOCKED',
            'אחד האימוג׳ים לא אושר בבדיקת התוכן. ההודעה לא נשלחה.');
        if (result.blocked !== false || result.pending || result.scanStopped ||
            !validClassification(result.classification))
          throw new Error('emoji_scan_incomplete');
        const classification = result.classification;
        const detected = classification.detectedCategories?.length
          ? classification.detectedCategories : [classification.category];
        if (!detected.every(category =>
            ['nonHumanImages', 'men', 'women', 'children', 'people'].includes(category)))
          throw new Error('emoji_scan_classification_invalid');
        detected.forEach(category => categories.add(category));
        codes.push(glyph.code);
      }
    } catch (error) { throw emojiModerationError(error); }
    return { inlineEmoji: true,
      category: categories.size === 1 ? [...categories][0] : 'people',
      detectedCategories: [...categories], uncertain: false,
      artworkVersion, moderationVersion,
      artworkHash: crypto.createHash('sha256')
        .update(version + ':' + codes.sort().join(',')).digest('hex') };
  }

  return { inspect };
}

module.exports = { createUnicodeEmojiModerator, UnicodeEmojiModerationError,
  emojiModerationError };
