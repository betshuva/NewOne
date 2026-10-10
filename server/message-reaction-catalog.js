'use strict';

// Reaction IDs use the same immutable catalog as the bundled message editor.
// Keep this an exact finite allowlist; never interpret reaction URLs or text.
const catalog = require('../flutter_app/assets/stickers/user-catalog.json');
const { inlineEmojiPlainText } = require('./inline-custom-emoji');
const category = catalog.categories?.find(item => item.id === 'user-stickers' &&
  item.prefix === 'sticker' && item.extension === 'png');
if (!Array.isArray(category?.labels) || category.labels.length !== 150 ||
    category.labels.some(label => typeof label !== 'string' || !label.trim()))
  throw new Error('The message reaction catalog must contain the 150 bundled emoji labels');

const REACTIONS = Object.freeze(['👍', '❤️', '😂', '🙏', '😮', '😢']);
const customReactions = category.labels.map((_, index) =>
  `[[bt-emoji:${String(index + 1).padStart(3, '0')}]]`);
const ALLOWED_REACTIONS = Object.freeze([...REACTIONS, ...customReactions]);

function reactionLabel(emoji) {
  return inlineEmojiPlainText(emoji);
}

const sqlLiteral = value => `'${value.replaceAll("'", "''")}'`;
const values = ALLOWED_REACTIONS.map(sqlLiteral).join(',');
const definition = `CHECK ((emoji = ANY (ARRAY[${ALLOWED_REACTIONS.map(value =>
  `${sqlLiteral(value)}::text`).join(', ')}])))`;

// pg_get_constraintdef has a canonical representation for this finite text
// array. A second startup leaves the constraint OID, rows and timestamps alone.
// Recheck after acquiring the DDL lock if another startup upgraded it first.
// A failed validation rolls back this whole block, retaining the old CHECK.
const REACTION_EMOJI_SCHEMA = `DO $reaction_emoji$
DECLARE current_definition text;
BEGIN
  SELECT pg_get_constraintdef(oid) INTO current_definition FROM pg_constraint
    WHERE conrelid='message_reactions'::regclass AND conname='message_reactions_emoji_check';
  IF current_definition IS DISTINCT FROM ${sqlLiteral(definition)} THEN
    LOCK TABLE message_reactions IN ACCESS EXCLUSIVE MODE;
    SELECT pg_get_constraintdef(oid) INTO current_definition FROM pg_constraint
      WHERE conrelid='message_reactions'::regclass AND conname='message_reactions_emoji_check';
    IF current_definition IS DISTINCT FROM ${sqlLiteral(definition)} THEN
      ALTER TABLE message_reactions DROP CONSTRAINT IF EXISTS message_reactions_emoji_check;
      ALTER TABLE message_reactions ADD CONSTRAINT message_reactions_emoji_check
        CHECK (emoji=ANY(ARRAY[${values}]::text[]));
    END IF;
  END IF;
END
$reaction_emoji$`;

module.exports = { REACTIONS, ALLOWED_REACTIONS, REACTION_EMOJI_SCHEMA, reactionLabel };
