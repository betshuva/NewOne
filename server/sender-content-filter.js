'use strict';

const {
  contentAllowedByFilter,
  imageAllowedByFilter,
  resolveScopedContentFilter,
} = require('./content-filter-policy');
const { recordFilterDecision } = require('./filter-audit');

function senderScope(contextType, contextId) {
  if (contextId && (contextType === 'chat' || contextType === 'contact'))
    return { type: 'contact', id: contextId };
  if (contextId && contextType === 'group')
    return { type: 'group', id: contextId };
  return { type: 'general', id: null };
}

// Read the sender's current settings at every send/delivery decision. Cached
// moderation approves the file's safety, not its use under current preferences.
async function getEffectiveSenderFilter(db, userId, contextType, contextId) {
  const scope = senderScope(contextType, contextId);
  const result = await db.query(`SELECT u.content_filter AS general_filter,
      CASE WHEN $2='contact' THEN c.filter_override
        WHEN $2='group' THEN COALESCE(gm.filter_override,
          CASE WHEN g.creator_id=u.id THEN g.content_filter END)
      END AS scoped_filter
    FROM users u
    LEFT JOIN user_contacts c ON $2='contact' AND c.owner_id=u.id
      AND c.contact_id=$3::uuid
    LEFT JOIN groups g ON $2='group' AND g.id=$3::uuid
    LEFT JOIN group_members gm ON gm.group_id=g.id AND gm.user_id=u.id
      AND gm.status='member'
    WHERE u.id=$1`, [userId, scope.type, scope.id]);
  const row = result.rows[0];
  if (!row) throw Object.assign(new Error('המשתמש אינו זמין לשליחת תוכן'), {
    status: 403, code: 'SENDER_USER_NOT_FOUND',
  });
  return resolveScopedContentFilter(row.general_filter, row.scoped_filter);
}

function documentContainsImages(classification) {
  return Boolean(classification && (
    classification.detectedCategories?.length > 0 ||
    classification.category || classification.uncertain === true));
}

// A contact's receiving choices and the group's delivery policy remain separate
// checks. This guard adds the sender's own visual preferences to those checks.
async function assertSenderMediaAllowed(db, {
  userId, contextType, contextId, type, classification,
  fileId, fileUrl, messageId, source = 'sender_media',
}) {
  if (type !== 'image' && type !== 'video' &&
      !(type === 'document' && documentContainsImages(classification))) return null;
  const policy = await getEffectiveSenderFilter(db, userId, contextType, contextId);
  // The added document restriction concerns its images. Existing text rules
  // continue to be enforced by their original receiving/delivery checks.
  const allowed = type === 'document'
    ? imageAllowedByFilter(policy, classification)
    : contentAllowedByFilter(policy, type, classification);
  if (allowed) return policy;
  const scope = senderScope(contextType, contextId);
  const senderDecision = {
    userId, actorId: userId, scopeType: scope.type, scopeId: scope.id,
    messageType: type,
    classification: classification ? Object.fromEntries(
      ['category', 'detectedCategories', 'uncertain', 'source']
        .filter(key => classification[key] !== undefined)
        .map(key => [key, Array.isArray(classification[key])
          ? [...classification[key]] : classification[key]])) : null,
    policy: { ...policy }, fileId, fileUrl, messageId,
    source, reasonCode: 'sender_content_filter',
  };
  await recordFilterDecision(db, senderDecision);
  throw Object.assign(new Error('סוג התוכן חסום בהגדרות הסינון שלך'), {
    status: 403, code: 'SENDER_CONTENT_FILTERED',
    // A surrounding media transaction may roll its audit insert back. Expose
    // this exact decision so its owner can persist it after rolling back.
    senderDecision,
  });
}

module.exports = { getEffectiveSenderFilter, assertSenderMediaAllowed };
