'use strict';

const { resolveScopedContentFilter, contentAllowedByFilter } = require('./content-filter-policy');
const { personalMessageVisible } = require('./conversation-history');
const { recordFilterEvent } = require('./filter-audit');
const { getEffectiveSenderFilter } = require('./sender-content-filter');
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const IMAGE_KEYS = ['men', 'women', 'children', 'nonHumanImages'];
const FILTER_MEDIA_SCHEMA = `CREATE TABLE IF NOT EXISTS user_message_filter_actions (
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  message_id UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  action TEXT NOT NULL CHECK(action IN ('keep','hide','delete')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(user_id,message_id)
);`;

function error(status, code, message, extra = {}) {
  return Object.assign(new Error(message), { status, code, ...extra });
}

function imageAffectedByTightening(before, after, classification) {
  const tightened = IMAGE_KEYS.filter(key => before[key] === true && after[key] !== true);
  if (!tightened.length) return false;
  // Only newly blocked categories are relevant, including mixed/uncertain images.
  const newlyBlocked = Object.fromEntries(IMAGE_KEYS.map(key => [key, !tightened.includes(key)]));
  return !contentAllowedByFilter(newlyBlocked, 'image', classification);
}

async function lockFilterOwner(db, userId) {
  await db.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))', [`personal-media-owner:${userId}`]);
  const row = await db.query('SELECT content_filter FROM users WHERE id=$1 FOR UPDATE', [userId]);
  if (!row.rows.length) throw error(404, 'USER_NOT_FOUND', 'המשתמש לא נמצא');
  await db.query("SELECT set_config('app.actor_id',$1,true)", [userId]);
  return row.rows[0].content_filter;
}

// Called inside the same transaction as the settings update. A cancelled choice
// rolls everything back, including the settings and the audit event.
async function prepareFilterHistoryChange(db, userId, scope, nextFilter, action) {
  if (action !== undefined && !['keep', 'hide', 'delete'].includes(action))
    throw error(400, 'INVALID_EXISTING_MEDIA_ACTION', 'בחירה לא תקינה עבור התמונות הקיימות');
  const rows = await db.query(`SELECT m.id,m.group_id,m.sender_id,m.recipient_id,
      COALESCE(sf.moderation_details->'classification',owned_copy.moderation_details->'classification') AS classification,
      u.content_filter AS general_filter,c.filter_override AS contact_filter,
      gm.filter_override AS member_filter,g.content_filter AS group_filter,
      g.creator_id,creator.content_filter AS creator_filter,
      a.action AS previous_action,owned_copy.id AS personal_file_id,
      CASE WHEN sf.user_id=$1 THEN sf.id END AS owned_source_file_id
    FROM messages m
    JOIN users u ON u.id=$1
    LEFT JOIN stored_files sf ON sf.public_url=m.file_url
    LEFT JOIN user_contacts c ON c.owner_id=$1 AND c.contact_id=CASE WHEN m.sender_id=$1 THEN m.recipient_id ELSE m.sender_id END
    LEFT JOIN groups g ON g.id=m.group_id
    LEFT JOIN users creator ON creator.id=g.creator_id
    LEFT JOIN group_members gm ON gm.group_id=m.group_id AND gm.user_id=$1
    LEFT JOIN user_message_filter_actions a ON a.user_id=$1 AND a.message_id=m.id
    LEFT JOIN received_message_media received ON received.user_id=$1 AND received.message_id=m.id
    LEFT JOIN stored_files owned_copy ON owned_copy.id=received.stored_file_id AND owned_copy.user_id=$1
    WHERE m.type='image' AND ${personalMessageVisible('m', '$1')}
      AND ($2='general' OR ($2='contact' AND m.group_id IS NULL
        AND CASE WHEN m.sender_id=$1 THEN m.recipient_id ELSE m.sender_id END=$3::uuid)
        OR ($2 IN ('group','group_personal') AND m.group_id=$3::uuid))`,
  [userId, scope.kind, scope.id || null]);
  const affected = rows.rows.filter(row => {
    const currentScope = row.group_id
      ? row.member_filter ?? (row.creator_id === userId ? row.group_filter : null)
      : row.contact_filter;
    let before = resolveScopedContentFilter(row.general_filter, currentScope);
    let after;
    if (scope.kind === 'general') after = resolveScopedContentFilter(nextFilter, currentScope);
    else if (scope.kind === 'group') {
      before = resolveScopedContentFilter(row.creator_filter, row.group_filter);
      after = resolveScopedContentFilter(row.creator_filter, nextFilter);
    } else after = resolveScopedContentFilter(row.general_filter, nextFilter);
    // Older releases never offered a choice for the user's own images. A
    // unchanged save can resolve these blocked, undecided IDs once. Explicit
    // actions may also replace an earlier choice without toggling settings.
    const blocked = !contentAllowedByFilter(after, 'image', row.classification);
    return imageAffectedByTightening(before, after, row.classification) ||
      (blocked && (!row.previous_action || (action !== undefined && row.previous_action !== action)));
  });
  if (affected.length && action === undefined)
    throw error(409, 'EXISTING_MEDIA_CHOICE_REQUIRED',
      'מה לעשות עם התמונות שכבר נשלחו או התקבלו?', { affectedCount: affected.length });
  if (!affected.length) return { affectedCount: 0, action: action || null, fileIds: [] };
  const ids = affected.map(row => row.id);
  await db.query(`INSERT INTO user_message_filter_actions(user_id,message_id,action)
    SELECT $1,id,$3 FROM unnest($2::uuid[]) id
    ON CONFLICT(user_id,message_id) DO UPDATE SET action=EXCLUDED.action,created_at=clock_timestamp()`,
  [userId, ids, action]);
  if (action === 'delete') {
    await db.query(`INSERT INTO message_user_deletions(message_id,user_id)
      SELECT id,$1 FROM unnest($2::uuid[]) id ON CONFLICT DO NOTHING`, [userId, ids]);
    await db.query(`UPDATE received_message_media SET status='skipped'
      WHERE user_id=$1 AND message_id=ANY($2::uuid[]) AND status='queued'`, [userId, ids]);
  }
  const auditScope = scope.kind === 'group_personal' ? 'group' : scope.kind;
  const level = scope.kind === 'group_personal' ? 'member' : scope.kind;
  await recordFilterEvent(db, { kind: 'history_action', userId, actorId: userId,
    scopeType: auditScope, scopeId: scope.id || null,
    details: { action, affectedCount: ids.length, level } });
  await db.query(`INSERT INTO filter_audit_events(kind,user_id,actor_id,scope_type,scope_id,message_id,details)
    SELECT 'history_image_action',$1,$1,$3,$4,id,jsonb_build_object('action',$5::text,'level',$6::text)
    FROM unnest($2::uuid[]) id`, [userId,ids,auditScope,scope.id || null,action,level]);
  return { action, affectedCount: ids.length,
    fileIds: action === 'delete' ? [...new Set(affected.flatMap(row => [row.personal_file_id,row.owned_source_file_id]).filter(Boolean))] : [] };
}

async function finishFilterHistoryChange(pool, userId, change, deleteOwnMedia) {
  const result = { action: change.action, affectedCount: change.affectedCount,
    deletedPersonalFiles: 0, retainedSharedFiles: 0, failedFiles: 0 };
  for (const id of change.fileIds || []) {
    try { await deleteOwnMedia(pool, userId, id); result.deletedPersonalFiles++; }
    catch (e) {
      if (e.code === 'MEDIA_IN_USE' || e.status === 404) result.retainedSharedFiles++;
      else result.failedFiles++;
    }
  }
  if (change.action === 'delete' && change.fileIds?.length)
    await recordFilterEvent(pool, { kind: 'history_cleanup', userId, actorId: userId,
      details: result });
  return result;
}

async function projectFilteredHistory(db, userId, messages, { groupId = null, preserveClearedCopies = false } = {}) {
  const ids = messages.filter(row => UUID.test(String(row.id))).map(row => row.id);
  if (!ids.length) return messages;
  const state = await db.query(`SELECT m.id,m.sender_id,m.type,
      a.action,EXISTS(SELECT 1 FROM message_user_deletions d
        WHERE d.user_id=$1 AND d.message_id=m.id) AS deleted,
      COALESCE(sf.moderation_details->'classification',owned_copy.moderation_details->'classification') AS classification,
      CASE WHEN sf.moderation_status IN ('pending','rejected') THEN sf.moderation_status
        ELSE COALESCE(owned_copy.moderation_status,sf.moderation_status) END AS moderation_status,
      CASE WHEN sf.moderation_status IN ('pending','rejected') THEN sf.moderation_details->>'reason'
        ELSE COALESCE(owned_copy.moderation_details->>'reason',sf.moderation_details->>'reason') END AS scan_reason,
      CASE WHEN owned_copy.id IS NOT NULL THEN owned_copy.content_purged_at ELSE sf.content_purged_at END AS content_purged_at,
      (SELECT e.details->'groupPolicy' FROM filter_audit_events e
        WHERE e.message_id=m.id AND e.user_id=$1
          AND e.kind IN ('delivery_persisted','delivery_blocked_persisted')
        ORDER BY e.id DESC LIMIT 1) AS delivery_group_filter,
      betshuva_effective_filter(u.content_filter,
        CASE WHEN m.group_id IS NULL THEN c.filter_override
          ELSE COALESCE(gm.filter_override,CASE WHEN g.creator_id=$1 THEN g.content_filter END) END) AS filter
    FROM messages m JOIN users u ON u.id=$1
    LEFT JOIN user_contacts c ON c.owner_id=$1 AND c.contact_id=CASE WHEN m.sender_id=$1 THEN m.recipient_id ELSE m.sender_id END
    LEFT JOIN group_members gm ON gm.group_id=m.group_id AND gm.user_id=$1
    LEFT JOIN groups g ON g.id=m.group_id
    LEFT JOIN stored_files sf ON sf.public_url=m.file_url
    LEFT JOIN received_message_media received ON received.message_id=m.id AND received.user_id=$1 AND received.status='ready'
    LEFT JOIN stored_files owned_copy ON owned_copy.id=received.stored_file_id AND owned_copy.user_id=$1
    LEFT JOIN user_message_filter_actions a ON a.user_id=$1 AND a.message_id=m.id
    WHERE m.id=ANY($2::uuid[])`, [userId, ids]);
  const byId = new Map(state.rows.map(row => [row.id, row]));
  return messages.flatMap(message => {
    const row = byId.get(message.id);
    if (!row) return [message];
    if ((!preserveClearedCopies && row.deleted) || row.action === 'delete') return [];
    if (row.type !== 'image') {
      if (row.sender_id === userId) return [message];
      return groupId && !contentAllowedByFilter(row.filter, row.type, row.classification) ? [] : [message];
    }
    const safe = row.moderation_status === 'approved' && !row.content_purged_at;
    const hidden = !safe || row.action === 'hide' ||
      (row.action !== 'keep' && (!contentAllowedByFilter(row.filter, 'image', row.classification) ||
        (row.delivery_group_filter && !contentAllowedByFilter(row.delivery_group_filter, 'image', row.classification))));
    if (hidden) return [{ ...message, file_url: null, fileUrl: null, body: null,
      text: null, file_name: null, fileName: null, filter_hidden: true,
      moderation_status: row.moderation_status || null,
      scan_reason: row.scan_reason || null, content_purged_at: row.content_purged_at || null,
      hidden_reason: safe ? 'content_filter' : 'moderation', filter_kept: false }];
    return [{ ...message, filter_hidden: false, filter_kept: row.action === 'keep' }];
  });
}


// Synthetic scan/request rows have no message ID and therefore cannot have a
// historical keep grant. Read the authoritative owned file state before showing
// any preview; pending or rejected content must never reveal its upload URL.
async function projectOwnScans(db, userId, rows, { contextType = null, contextId = null } = {}) {
  const visual = rows.filter(row => ['image', 'video'].includes(row.type || row.file_type));
  if (!visual.length) return rows;
  const urls = visual.map(row => row.file_url || row.public_url).filter(Boolean);
  const ids = visual.map(row => String(row.id).replace(/^scan_/, '')).filter(id => UUID.test(id));
  const stored = await db.query(`SELECT sf.* FROM stored_files sf
    WHERE sf.user_id=$1 AND (sf.id=ANY($2::uuid[]) OR sf.public_url=ANY($3::text[]))`, [userId, ids, urls]);
  const byUrl = new Map(stored.rows.map(row => [row.public_url, row]));
  const byId = new Map(stored.rows.map(row => [row.id, row]));
  const filters = new Map();
  return Promise.all(rows.map(async row => {
    const type = row.type || row.file_type;
    if (!['image', 'video'].includes(type)) return row;
    const file = byUrl.get(row.file_url || row.public_url) || byId.get(String(row.id).replace(/^scan_/, ''));
    const safe = file?.moderation_status === 'approved' && !file.content_purged_at;
    const targetType = contextType || (row.group_id ? 'group' : file?.context_type || 'general');
    const targetId = contextId || row.group_id || row.recipient_id || file?.context_id || null;
    const key = targetType + ':' + targetId;
    if (!filters.has(key)) filters.set(key, getEffectiveSenderFilter(db,userId,targetType,targetId));
    const filter = await filters.get(key);
    if (safe && contentAllowedByFilter(filter,type,file.moderation_details?.classification))
      return { ...row, filter_hidden: false };
    return { ...row, file_url: null, fileUrl: null, public_url: null,
      blocked_preview_url: null, thumbnail_url: null, preview_url: null,
      body: null, text: null, file_name: null, fileName: null,
      moderation_status: file?.moderation_status || null,
      scan_reason: file?.moderation_details?.reason || null,
      content_purged_at: file?.content_purged_at || null,
      filter_hidden: true, hidden_reason: safe ? 'content_filter' : 'moderation', filter_kept: false };
  }));
}

async function projectFilterMediaLibrary(db, userId, items) {
  const representatives = new Map(items.filter(row => row.file_type === 'image')
    .flatMap(row => (row.duplicate_ids || [row.id]).map(id => [id, row.id])));
  const ids = [...representatives.keys()];
  if (!ids.length) return items;
  // Both a received personal copy and an original sent by this user inherit
  // exact-message history decisions. A file can be linked to several messages;
  // one visible, safe instance keeps the owner's library preview available.
  const links = await db.query(`SELECT m.id,m.file_url,m.type,r.stored_file_id AS library_file_id
    FROM received_message_media r JOIN messages m ON m.id=r.message_id
    JOIN stored_files sf ON sf.id=r.stored_file_id
    WHERE r.user_id=$1 AND sf.user_id=$1 AND r.status='ready'
      AND r.stored_file_id=ANY($2::uuid[])
    UNION
    SELECT m.id,m.file_url,m.type,sf.id AS library_file_id
    FROM stored_files sf JOIN messages m ON m.file_url=sf.public_url AND m.sender_id=$1
    WHERE sf.user_id=$1 AND sf.id=ANY($2::uuid[])`, [userId,ids]);
  // Ordinary conversation clearing explicitly preserves personal files. Only a
  // filter decision (or current blocked category) hides their library preview.
  const visible = await projectFilteredHistory(db,userId,links.rows,{preserveClearedCopies:true});
  const linked = new Map(links.rows.map(row=>[representatives.get(row.library_file_id),row.id]));
  const allowed = new Map(visible.filter(row=>!row.filter_hidden)
    .map(row=>[representatives.get(row.library_file_id),row.id]));
  const hidden = new Map(visible.filter(row=>row.filter_hidden)
    .map(row=>[representatives.get(row.library_file_id),row]));
  const unlinked = items.filter(row=>row.file_type==='image' && !linked.has(row.id));
  const standalone = new Map((await projectOwnScans(db,userId,unlinked)).map(row=>[row.id,row]));
  return items.map(row => !linked.has(row.id) ? (standalone.get(row.id) || row) : {
    ...row, filter_source_message_id: allowed.get(row.id) || linked.get(row.id),
    filter_hidden: !allowed.has(row.id),
    ...(!allowed.has(row.id) ? {
      hidden_reason: hidden.get(row.id)?.hidden_reason || 'moderation',
      moderation_status: hidden.get(row.id)?.moderation_status ?? row.moderation_status,
      scan_reason: hidden.get(row.id)?.scan_reason || null,
      content_purged_at: hidden.get(row.id)?.content_purged_at ?? row.content_purged_at,
      public_url: null, file_url: null, fileUrl: null,
      blocked_preview_url: null, thumbnail_url: null, preview_url: null } : {}),
  });
}

function registerFilterHistoryRoutes(app, { auth, getPool, notifyUser }) {
  app.post('/api/messages/:messageId/filter-visibility', auth, async (req, res) => {
    if (!UUID.test(req.params.messageId) || req.body?.action !== 'restore')
      return res.status(400).json({ error: 'בקשה לא תקינה' });
    const db = await (await getPool()).connect();
    try {
      await db.query('BEGIN');
      await lockFilterOwner(db, req.user.id);
      const row = await db.query(`SELECT m.id,m.group_id,m.sender_id,m.recipient_id FROM messages m
        LEFT JOIN stored_files sf ON sf.public_url=m.file_url
        LEFT JOIN received_message_media received ON received.message_id=m.id
          AND received.user_id=$1 AND received.status='ready'
        LEFT JOIN stored_files owned_copy ON owned_copy.id=received.stored_file_id AND owned_copy.user_id=$1
        WHERE m.id=$2 AND m.type='image'
          AND (CASE WHEN sf.moderation_status IN ('pending','rejected') THEN sf.moderation_status
            ELSE COALESCE(owned_copy.moderation_status,sf.moderation_status) END)='approved'
          AND (CASE WHEN owned_copy.id IS NOT NULL THEN owned_copy.content_purged_at ELSE sf.content_purged_at END) IS NULL
          AND ${personalMessageVisible('m', '$1')} FOR SHARE OF m`, [req.user.id, req.params.messageId]);
      if (!row.rows.length) throw error(404, 'IMAGE_NOT_FOUND', 'התמונה אינה זמינה');
      await db.query(`INSERT INTO user_message_filter_actions(user_id,message_id,action)
        VALUES($1,$2,'keep') ON CONFLICT(user_id,message_id)
        DO UPDATE SET action='keep',created_at=clock_timestamp()`, [req.user.id, req.params.messageId]);
      await recordFilterEvent(db, { kind: 'history_restored', userId: req.user.id,
        actorId: req.user.id, messageId: req.params.messageId,
        scopeType: row.rows[0].group_id ? 'group' : 'contact',
        scopeId: row.rows[0].group_id || (row.rows[0].sender_id === req.user.id ? row.rows[0].recipient_id : row.rows[0].sender_id),
        details: { action: 'restore' } });
      await db.query('COMMIT');
      notifyUser(req.user.id, 'filter:changed', { scope: row.rows[0].group_id ? 'group_personal' : 'contact',
        targetId: row.rows[0].group_id || (row.rows[0].sender_id === req.user.id ? row.rows[0].recipient_id : row.rows[0].sender_id), restoredMessageId: req.params.messageId });
      res.json({ ok: true });
    } catch (e) {
      await db.query('ROLLBACK').catch(() => {});
      res.status(e.status || 500).json({ error: e.message, code: e.code });
    } finally { db.release(); }
  });
}

module.exports = { FILTER_MEDIA_SCHEMA, imageAffectedByTightening, lockFilterOwner,
  prepareFilterHistoryChange, finishFilterHistoryChange, projectFilteredHistory, projectFilterMediaLibrary, projectOwnScans, registerFilterHistoryRoutes };
