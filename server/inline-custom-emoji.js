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

function stripChatColorMetadata(value) {
  const text = String(value || '');
  // Code stays literal. Only balanced, valid color pairs are internal data.
  const tokens = /`(?=\S)[^`\r\n]*\S`|\[\[bt-style:((?:fg|bg)=[0-9a-fA-F]{6}(?:;(?:fg|bg)=[0-9a-fA-F]{6})?)\]\]|\[\[\/bt-style\]\]/g;
  const stack = [];
  const hidden = new Set();
  for (const match of text.matchAll(tokens)) {
    let slashes = 0;
    for (let at = match.index - 1; at >= 0 && text[at] === '\\'; at--) slashes++;
    if (slashes % 2 || match[0].startsWith('`')) continue;
    if (match[1]) {
      const names = match[1].split(';').map(attribute => attribute.slice(0, 2));
      if (new Set(names).size === names.length) stack.push(match.index);
    } else if (stack.length) {
      hidden.add(stack.pop());
      hidden.add(match.index);
    }
  }
  return text.replace(tokens, (marker, attributes, at) => hidden.has(at) ? '' : marker);
}

function inlineEmojiModerationText(value) {
  // A decorative image must not insert a synthetic word into a harmful phrase.
  return stripChatColorMetadata(value).replace(INLINE_EMOJI, (marker, id) =>
    registeredLabel(Number(id)) ? ' ' : marker);
}

function inlineEmojiPlainText(value) {
  return stripChatColorMetadata(value).replace(INLINE_EMOJI, (marker, id) => {
    const label = registeredLabel(Number(id));
    return label ? `[${label.trim()}]` : marker;
  });
}

module.exports = { inlineEmojiModerationText, inlineEmojiPlainText };
