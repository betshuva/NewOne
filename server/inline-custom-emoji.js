'use strict';

// Legacy IDs retain their meaning; new IDs must exist in the server registry.
const INLINE_EMOJI = /\[\[bt-emoji:([0-9]{3}|[1-9][0-9]{3})\]\]/g;
const fs = require('node:fs');
const path = require('node:path');
function registeredLabel(id) {
  if (id >= 1 && id <= 150) return labels[id - 1] || 'אימוג׳י';
  if (id > 6400) return null;
  try {
    const registry = JSON.parse(fs.readFileSync(path.join(__dirname, '..',
      'expression-library', 'emoji-registry.json'), 'utf8'));
    return registry.items.find(item => item.id === id)?.label || null;
  } catch (_) { return null; }
}
let labels = [];
try {
  const catalog = require('../expression-library/catalog.json');
  const category = catalog.categories?.find(item =>
    item.id === 'user-stickers' &&
    item.prefix === 'sticker' && item.extension === 'png');
  if (Array.isArray(category?.labels)) labels = category.labels;
} catch (_) {
  // Notifications remain readable if the optional artwork catalog is missing.
}

function inlineEmojiModerationText(value) {
  // A decorative image must not insert a synthetic word into a harmful phrase.
  return String(value || '').replace(INLINE_EMOJI, (marker, id) =>
    registeredLabel(Number(id)) ? ' ' : marker);
}

function inlineEmojiPlainText(value) {
  return String(value || '').replace(INLINE_EMOJI, (marker, id) => {
    const label = registeredLabel(Number(id));
    return label ? `[${label.trim()}]` : marker;
  });
}

module.exports = { inlineEmojiModerationText, inlineEmojiPlainText };
