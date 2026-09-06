'use strict';
const REACTIONS = Object.freeze(['👍', '❤️', '😂', '🙏', '😮', '😢']);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
async function visibleMessage(pool, id, userId, contentAllowedByFilter) {
  const result = await pool.query(`SELECT m.id,m.sender_id,m.recipient_id,m.group_id,m.type,
      sf.moderation_details->'classification' AS classification,
      betshuva_effective_filter(u.content_filter, COALESCE(gm.filter_override,
        CASE WHEN gm.user_id=g.creator_id THEN g.content_filter END)) AS receiving_filter
    FROM messages m
    JOIN users u ON u.id=$2
    LEFT JOIN group_members gm ON gm.group_id=m.group_id AND gm.user_id=$2 AND gm.status='member'
    LEFT JOIN groups g ON g.id=m.group_id
    LEFT JOIN stored_files sf ON sf.public_url=m.file_url
    WHERE m.id=$1 AND m.deleted_for_everyone=FALSE
      AND NOT (m.sender_id=$2 AND COALESCE(m.deleted_for_sender,FALSE))
      AND NOT EXISTS (SELECT 1 FROM message_user_deletions d WHERE d.message_id=m.id AND d.user_id=$2)
      AND ((m.group_id IS NULL AND (m.sender_id=$2 OR m.recipient_id=$2))
        OR (m.group_id IS NOT NULL AND gm.user_id IS NOT NULL))
      AND NOT EXISTS (SELECT 1 FROM blocked_users b WHERE
        (b.blocker_id=$2 AND b.blocked_id=m.sender_id) OR
        (b.blocked_id=$2 AND b.blocker_id=m.sender_id))`, [id, userId]);
  const message = result.rows[0];
  if (!message) return null;
  if (message.group_id && message.sender_id !== userId &&
      !contentAllowedByFilter(message.receiving_filter, message.type, message.classification)) return null;
  return message;
}
async function readReactions(pool, id, userId) {
  return (await pool.query(`SELECT emoji,COUNT(*)::int AS count,BOOL_OR(user_id=$2) AS mine
    FROM message_reactions WHERE message_id=$1 GROUP BY emoji ORDER BY emoji`, [id, userId])).rows;
}
function registerMessageReactions(app, { auth, rateLimit, getPool, contentAllowedByFilter }) {
  const handler = write => async (req, res) => {
    if (!UUID.test(req.params.id)) return res.status(400).json({ error: 'מזהה הודעה לא תקין' });
    const emoji = req.body?.emoji;
    if (write && emoji !== null && !REACTIONS.includes(emoji))
      return res.status(400).json({ error: 'תגובה לא נתמכת' });
    try {
      const pool = await getPool();
      if (!await visibleMessage(pool, req.params.id, req.user.id, contentAllowedByFilter))
        return res.status(404).json({ error: 'ההודעה אינה זמינה' });
      if (write) {
        if (emoji === null) await pool.query(
          'DELETE FROM message_reactions WHERE message_id=$1 AND user_id=$2', [req.params.id, req.user.id]);
        else await pool.query(`INSERT INTO message_reactions(message_id,user_id,emoji)
          VALUES($1,$2,$3) ON CONFLICT(message_id,user_id)
          DO UPDATE SET emoji=EXCLUDED.emoji,updated_at=now()`, [req.params.id, req.user.id, emoji]);
      }
      return res.json(await readReactions(pool, req.params.id, req.user.id));
    } catch (_) { return res.status(500).json({ error: 'לא ניתן לעדכן או לטעון תגובות כעת' }); }
  };
  app.get('/api/messages/:id/reactions', auth, handler(false));
  app.put('/api/messages/:id/reactions', auth, rateLimit, handler(true));
}
module.exports = { REACTIONS, visibleMessage, readReactions, registerMessageReactions };
