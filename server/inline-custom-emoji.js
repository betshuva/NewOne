'use strict';

// Keep the wire format limited to the same immutable 150 images as the editor.
// Unknown tokens stay ordinary text; this module never resolves image URLs.
const INLINE_EMOJI = /\[\[bt-emoji:(00[1-9]|0[1-9][0-9]|1[0-4][0-9]|150)\]\]/g;
let labels = [];
try {
  const catalog = require('../expression-library/catalog.json');
  const category = catalog.categories?.find(item =>
    item.id === 'user-stickers' && item.path === 'user-20260907' &&
    item.prefix === 'sticker' && item.extension === 'png');
  if (Array.isArray(category?.labels)) labels = category.labels;
} catch (_) {
  // Notifications remain readable if the optional artwork catalog is missing.
}

function inlineEmojiModerationText(value) {
  // A decorative image must not insert a synthetic word into a harmful phrase.
  return String(value || '').replace(INLINE_EMOJI, ' ');
}

function inlineEmojiPlainText(value) {
  return String(value || '').replace(INLINE_EMOJI, (_, id) => {
    const label = labels[Number(id) - 1];
    return `[${typeof label === 'string' && label.trim() ? label.trim() : 'אימוג׳י'}]`;
  });
}

module.exports = { inlineEmojiModerationText, inlineEmojiPlainText };
