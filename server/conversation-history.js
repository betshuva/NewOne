'use strict';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CONVERSATION_SCHEMA = `CREATE TABLE IF NOT EXISTS conversation_user_state (
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('chat','group')),
  target_id UUID NOT NULL,
  hidden BOOLEAN NOT NULL DEFAULT FALSE,
  cleared_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  media_deleted_at TIMESTAMPTZ,
  PRIMARY KEY (user_id,kind,target_id)
)`;

// The cutoff also hides an older send transaction that commits after the clear
// snapshot, when its message id could not yet be added to the deletion ledger.
function messageAfterConversationClear(alias, userParameter) {
  return `NOT EXISTS (SELECT 1 FROM conversation_user_state clear_state
    WHERE clear_state.user_id=${userParameter}
      AND clear_state.kind=CASE WHEN ${alias}.group_id IS NULL THEN 'chat' ELSE 'group' END
      AND clear_state.target_id=COALESCE(${alias}.group_id,
        CASE WHEN ${alias}.sender_id=${userParameter} THEN ${alias}.recipient_id ELSE ${alias}.sender_id END)
      AND ${alias}.created_at<=clear_state.cleared_at)`;
}

// A received copy belongs to its reader. Only messages that reader can still
// open keep their copy in use; hiding someone else's conversation is unrelated.
function personalMessageVisible(alias, userParameter) {
  return `${alias}.deleted_for_everyone=FALSE
    AND NOT (${alias}.sender_id=${userParameter} AND COALESCE(${alias}.deleted_for_sender,FALSE))
    AND NOT EXISTS (SELECT 1 FROM message_user_deletions personal_deletion
      WHERE personal_deletion.message_id=${alias}.id AND personal_deletion.user_id=${userParameter})
    AND ${messageAfterConversationClear(alias, userParameter)}
    AND (( ${alias}.group_id IS NULL AND
      (${alias}.sender_id=${userParameter} OR ${alias}.recipient_id=${userParameter}))
      OR EXISTS (SELECT 1 FROM group_members personal_member
        WHERE personal_member.group_id=${alias}.group_id
          AND personal_member.user_id=${userParameter} AND personal_member.status='member'
          AND ${alias}.created_at>=personal_member.joined_at))`;
}

function conversationError(status, message) {
  return Object.assign(new Error(message), { status });
}

async function assertConversationAccess(db, user, kind, targetId) {
  if (kind === 'group') {
    if (user.isTeen) throw conversationError(403, 'קבוצות אינן זמינות בחשבון נוער');
    const member = await db.query(`SELECT 1 FROM group_members
      WHERE group_id=$1 AND user_id=$2 AND status='member' FOR SHARE`,
    [targetId, user.id]);
    if (!member.rows.length) throw conversationError(403, 'לא חבר פעיל בקבוצה');
  } else {
    const contact = await db.query(`SELECT 1 FROM users u WHERE u.id=$2 AND (
      u.id=$1 OR EXISTS (SELECT 1 FROM user_contacts c WHERE c.owner_id=$1 AND c.contact_id=u.id)
      OR EXISTS (SELECT 1 FROM messages m WHERE m.group_id IS NULL AND
        ((m.sender_id=$1 AND m.recipient_id=u.id) OR (m.sender_id=u.id AND m.recipient_id=$1)))
      OR EXISTS (SELECT 1 FROM message_requests r WHERE
        (r.sender_id=$1 AND r.recipient_id=u.id) OR (r.sender_id=u.id AND r.recipient_id=$1)))`,
    [user.id, targetId]);
    if (!contact.rows.length) throw conversationError(404, 'השיחה לא נמצאה');
  }
}

const conversationMessages = `(CASE WHEN $2='group' THEN m.group_id=$3::uuid ELSE
  m.group_id IS NULL AND ((m.sender_id=$1 AND m.recipient_id=$3::uuid)
    OR (m.sender_id=$3::uuid AND m.recipient_id=$1)) END)`;

async function clearConversation(pool, user, kind, targetId, options, deleteOwnMedia) {
  const db = await pool.connect();
  let result;
  let mediaIds = [];
  try {
    await db.query('BEGIN');
    await db.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))',
      [`personal-media-owner:${user.id}`]);
    await assertConversationAccess(db, user, kind, targetId);
    // Keep the cutoff in the database so every client uses the same snapshot.
    const state = await db.query(`INSERT INTO conversation_user_state(user_id,kind,target_id,hidden,cleared_at)
      VALUES($1,$2,$3,$4,clock_timestamp()) ON CONFLICT(user_id,kind,target_id)
      DO UPDATE SET hidden=EXCLUDED.hidden,cleared_at=clock_timestamp()
      RETURNING hidden,cleared_at`, [user.id, kind, targetId, options.deleteConversation]);
    const clearedAt = state.rows[0].cleared_at;
    const params = [user.id, kind, targetId, clearedAt];
    if (options.deleteMedia) {
      // Retain this cutoff across later keep-files clears. It also cancels an
      // older send transaction that commits after this cleanup's snapshot.
      await db.query(`UPDATE conversation_user_state SET media_deleted_at=$4
        WHERE user_id=$1 AND kind=$2 AND target_id=$3::uuid`, params);
      const media = await db.query(`SELECT sf.id FROM stored_files sf
        WHERE sf.user_id=$1 AND sf.created_at<=$4 AND (
          (sf.context_type=$2 AND sf.context_id=$3::uuid)
          OR EXISTS (SELECT 1 FROM messages m WHERE m.file_url=sf.public_url
            AND m.created_at<=$4 AND ${conversationMessages})
          OR EXISTS (SELECT 1 FROM received_message_media received
            JOIN messages m ON m.id=received.message_id
            WHERE received.user_id=$1 AND received.stored_file_id=sf.id
              AND received.status='ready' AND m.created_at<=$4 AND ${conversationMessages})
          OR ($2='chat' AND EXISTS (SELECT 1 FROM message_requests r
            WHERE r.file_url=sf.public_url AND r.sender_id=$1 AND r.recipient_id=$3::uuid
              AND r.created_at<=$4))) ORDER BY sf.id`, params);
      mediaIds = media.rows.map(row => row.id);
      // Delivery already granted a personal copy. A normal clear preserves
      // pending saves; explicit media deletion also cancels copies that have
      // not been written yet while the owner lock excludes the copy worker.
      await db.query(`UPDATE received_message_media received SET status='skipped'
        FROM messages m WHERE received.message_id=m.id AND received.user_id=$1
          AND received.status='queued' AND m.created_at<=$4 AND ${conversationMessages}`, params);
    }
    const cleared = await db.query(`WITH removed AS (
      INSERT INTO message_user_deletions(message_id,user_id)
      SELECT m.id,$1 FROM messages m WHERE ${conversationMessages}
        AND m.created_at<=$4 AND m.deleted_for_everyone=FALSE
        AND NOT (m.sender_id=$1 AND COALESCE(m.deleted_for_sender,FALSE))
        AND ($2<>'group' OR m.created_at >= (
          SELECT gm.joined_at FROM group_members gm WHERE gm.group_id=$3::uuid AND gm.user_id=$1))
      ON CONFLICT DO NOTHING RETURNING message_id
    ) SELECT COUNT(*)::int AS count FROM removed`, params);
    result = { ok: true, kind, targetId, hidden: state.rows[0].hidden,
      clearedAt: new Date(clearedAt).toISOString(), clearedMessages: cleared.rows[0].count,
      media: { requested: options.deleteMedia, deleted: 0, skipped: 0, failed: 0, deletedBytes: 0 } };
    await db.query('COMMIT');
  } catch (error) {
    await db.query('ROLLBACK').catch(() => {});
    throw error;
  } finally { db.release(); }

  // Personal history is committed independently: a disconnected Drive account
  // cannot undo the clear. Every file is rechecked under its own owner lock.
  for (const fileId of mediaIds) {
    try {
      const deleted = await deleteOwnMedia(pool, user.id, fileId);
      result.media.deleted++;
      result.media.deletedBytes += deleted.deletedBytes;
    } catch (error) {
      if (error.code === 'MEDIA_IN_USE' || error.status === 404) result.media.skipped++;
      else result.media.failed++;
    }
  }
  return result;
}

function registerConversationHistory(app, { auth, rateLimit, getPool, deleteOwnMedia, notifyUser }) {
  const validate = (req, res, next) => {
    if (!['chat', 'group'].includes(req.params.kind) || !UUID.test(req.params.id))
      return res.status(400).json({ error: 'מזהה שיחה לא תקין' });
    next();
  };
  app.post('/api/conversations/:kind/:id/clear', auth, rateLimit, validate, async (req, res) => {
    const { deleteConversation = false, deleteMedia = false } = req.body || {};
    if (typeof deleteConversation !== 'boolean' || typeof deleteMedia !== 'boolean')
      return res.status(400).json({ error: 'אפשרויות המחיקה אינן תקינות' });
    try {
      const result = await clearConversation(await getPool(), req.user, req.params.kind,
        req.params.id, { deleteConversation, deleteMedia }, deleteOwnMedia);
      notifyUser(req.user.id, 'conversation:changed', result);
      res.json(result);
    } catch (error) {
      res.status(error.status || 500).json({ error: error.status ? error.message : 'ניקוי השיחה נכשל. אפשר לנסות שוב.' });
    }
  });
  app.post('/api/conversations/:kind/:id/open', auth, validate, async (req, res) => {
    const pool = await getPool();
    const db = await pool.connect();
    try {
      await db.query('BEGIN');
      await assertConversationAccess(db, req.user, req.params.kind, req.params.id);
      const state = await db.query(`UPDATE conversation_user_state SET hidden=FALSE
        WHERE user_id=$1 AND kind=$2 AND target_id=$3 RETURNING cleared_at`,
      [req.user.id, req.params.kind, req.params.id]);
      await db.query('COMMIT');
      const result = { ok: true, kind: req.params.kind, targetId: req.params.id,
        hidden: false, clearedAt: state.rows[0]?.cleared_at || null };
      notifyUser(req.user.id, 'conversation:changed', result);
      res.json(result);
    } catch (error) {
      await db.query('ROLLBACK').catch(() => {});
      res.status(error.status || 500).json({ error: error.status ? error.message : 'לא ניתן לפתוח את השיחה כרגע' });
    } finally { db.release(); }
  });
}

module.exports = { CONVERSATION_SCHEMA, messageAfterConversationClear, personalMessageVisible,
  clearConversation, registerConversationHistory };
