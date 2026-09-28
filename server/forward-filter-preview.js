'use strict';

const { contentAllowedByFilter, resolveScopedContentFilter,
  isUnfilteredAssistantConversation, DEFAULT_CONTENT_FILTER } = require('./content-filter-policy');
const { shortFilterReason } = require('./guide-filter-notice');
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const UNKNOWN = { status: 'unknown', reason: 'לא ניתן לבדוק כרגע את הסינון ליעד זה. הסינון ייבדק בעת השליחה.' };

// A preview only: delivery always rechecks the current policy. No scans,
// filter audit decisions, guide messages or other delivery side effects here.
function previewForPolicy(filter, items, kind) {
  const reasons = new Set();
  let blockedCount = 0;
  let unknown = false;
  for (const item of items) {
    if (!item.known) {
      // Even before classification, a disabled video switch is definitive.
      if (item.type !== 'video' || filter.video !== false) {
        unknown = true;
        continue;
      }
    }
    if (!contentAllowedByFilter(filter, item.type, item.classification)) {
      blockedCount++;
      reasons.add(shortFilterReason({ filter, fileType: item.type,
        classification: item.classification }));
    }
  }
  if (blockedCount) return { status: 'blocked', blockedCount,
    reason: `לא ניתן להעביר ${blockedCount} מתוך ${items.length} פריטים: ${[...reasons].join('; ')} — לפי הגדרות ${kind === 'group' ? 'הקבוצה' : 'הנמען'}.` };
  return unknown ? UNKNOWN : { status: 'allowed' };
}

async function loadForwardFilterPreview(db, userId, messages, targets) {
  if (!Array.isArray(messages) || !messages.length || messages.length > 500 ||
      !Array.isArray(targets) || targets.length > 500 ||
      messages.some(m => !m || typeof m !== 'object' ||
        (m.fileUrl != null && (typeof m.fileUrl !== 'string' || m.fileUrl.length > 4096))) ||
      targets.some(t => !t || !['user', 'group'].includes(t.kind) || !UUID.test(t.id))) {
    throw Object.assign(new Error('בקשת בדיקת הסינון אינה תקינה'), { status: 400 });
  }
  const urls = [...new Set(messages.map(m => m.fileUrl).filter(Boolean))];
  const files = urls.length ? (await db.query(`SELECT sf.public_url, sf.file_type,
      sf.moderation_details->'classification' AS classification
    FROM stored_files sf WHERE sf.public_url=ANY($2::text[])
      AND sf.moderation_status='approved' AND sf.content_purged_at IS NULL
      AND (sf.user_id=$1 OR EXISTS (
        SELECT 1 FROM messages m WHERE m.file_url=sf.public_url
          AND m.deleted_for_everyone=FALSE AND (
            (m.group_id IS NULL AND (m.sender_id=$1 OR m.recipient_id=$1)) OR
            EXISTS (SELECT 1 FROM group_members gm WHERE gm.group_id=m.group_id
              AND gm.user_id=$1 AND gm.status='member')))
        OR EXISTS (SELECT 1 FROM shared_gifs sg WHERE sg.stored_file_id=sf.id AND sg.status='active'))`,
  [userId, urls])).rows : [];
  const byUrl = new Map(files.map(f => [f.public_url, f]));
  const items = messages.map(m => {
    const file = byUrl.get(m.fileUrl);
    if (file) return { known: true, type: file.file_type, classification: file.classification };
    // Client-provided classifications never replace the stored scan result.
    return { known: !m.fileUrl && ['text', 'audio', 'sticker'].includes(m.fileType || 'text'),
      type: m.fileType || 'text', classification: null };
  });
  const userIds = targets.filter(t => t.kind === 'user').map(t => t.id);
  const groupIds = targets.filter(t => t.kind === 'group').map(t => t.id);
  const users = userIds.length ? (await db.query(`SELECT u.id, u.content_filter,
      c.filter_override, (c.owner_id IS NOT NULL OR u.id=$1) AS is_contact
    FROM users u LEFT JOIN user_contacts c ON c.owner_id=u.id AND c.contact_id=$1
    WHERE u.id=ANY($2::uuid[])`, [userId, userIds])).rows : [];
  const groups = groupIds.length ? (await db.query(`SELECT g.id,
      betshuva_effective_filter(creator.content_filter, g.content_filter) AS content_filter
    FROM groups g JOIN users creator ON creator.id=g.creator_id
    JOIN group_members gm ON gm.group_id=g.id AND gm.user_id=$1 AND gm.status='member'
    WHERE g.id=ANY($2::uuid[])`, [userId, groupIds])).rows : [];
  const usersById = new Map(users.map(u => [u.id, u]));
  const groupsById = new Map(groups.map(g => [g.id, g]));
  return targets.map(target => {
    let filter;
    if (target.kind === 'group') filter = groupsById.get(target.id)?.content_filter;
    else {
      const user = usersById.get(target.id);
      if (user && isUnfilteredAssistantConversation(userId, target.id)) filter = DEFAULT_CONTENT_FILTER;
      else if (user?.is_contact) filter = resolveScopedContentFilter(user.content_filter, user.filter_override);
      else if (user) return { ...target, status: 'unknown',
        reason: 'הסינון ייבדק לאחר שהנמען יאשר את בקשת הקשר.' };
    }
    return { ...target, ...(filter ? previewForPolicy(filter, items, target.kind) : UNKNOWN) };
  });
}

function registerForwardFilterPreview(app, { auth, getPool }) {
  app.post('/api/forward/filter-preview', auth, async (req, res) => {
    res.set('Cache-Control', 'no-store');
    try {
      const targets = await loadForwardFilterPreview(await getPool(), req.user.id,
        req.body?.messages, req.body?.targets);
      res.json({ targets });
    } catch (error) {
      res.status(error.status || 503).json({ error: error.status === 400
        ? error.message : 'לא ניתן לבדוק כרגע את הסינון ליעדים שנבחרו' });
    }
  });
}
module.exports = { previewForPolicy, loadForwardFilterPreview, registerForwardFilterPreview };
