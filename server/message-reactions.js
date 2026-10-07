'use strict';
const crypto = require('node:crypto');
const { personalMessageVisible } = require('./conversation-history');
const { projectProfileImages } = require('./profile-image-policy');
const { REACTIONS, ALLOWED_REACTIONS, REACTION_EMOJI_SCHEMA, reactionLabel } = require('./message-reaction-catalog');
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// Existing statuses receive the migration time, so past reactions stay read.
// Missing statuses also stay read until a future reaction explicitly seeds a
// watermark. A reaction never changes the original message's receipt status.
const REACTION_READ_SCHEMA = `ALTER TABLE message_status
  ADD COLUMN IF NOT EXISTS reactions_read_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP`;

function conversationTarget(viewer) {
  return `COALESCE(m.group_id,CASE WHEN m.sender_id=${viewer}
    THEN m.recipient_id ELSE m.sender_id END)`;
}

function visibility(viewer, actor = null) {
  const other = `CASE WHEN m.group_id IS NULL AND m.sender_id=${viewer}
    THEN m.recipient_id ELSE m.sender_id END`;
  return `${personalMessageVisible('m', viewer)}
    AND (m.group_id IS NULL OR u.birth_date<=CURRENT_DATE-INTERVAL '18 years')
    AND NOT EXISTS (SELECT 1 FROM blocked_users b WHERE
      (b.blocker_id=${viewer} AND b.blocked_id IN (${other}${actor ? `,${actor}` : ''})) OR
      (b.blocked_id=${viewer} AND b.blocker_id IN (${other}${actor ? `,${actor}` : ''})))`;
}

function contextJoins(viewer, includeViewer = true) {
  return `${includeViewer ? `JOIN users u ON u.id=${viewer}` : ''}
    LEFT JOIN group_members gm ON gm.group_id=m.group_id AND gm.user_id=${viewer} AND gm.status='member'
    LEFT JOIN groups g ON g.id=m.group_id
    LEFT JOIN user_contacts c ON m.group_id IS NULL AND c.owner_id=${viewer}
      AND c.contact_id=CASE WHEN m.sender_id=${viewer} THEN m.recipient_id ELSE m.sender_id END
    LEFT JOIN stored_files sf ON sf.public_url=m.file_url`;
}

const receivingFilter = `betshuva_effective_filter(u.content_filter,
  CASE WHEN m.group_id IS NULL THEN c.filter_override ELSE COALESCE(gm.filter_override,
    CASE WHEN gm.user_id=g.creator_id THEN g.content_filter END) END)`;

function contentVisible(row, viewerId, contentAllowedByFilter) {
  return row.sender_id === viewerId ||
    contentAllowedByFilter(row.receiving_filter, row.type, row.classification);
}

async function visibleMessage(pool, id, userId, contentAllowedByFilter) {
  const result = await pool.query(`SELECT m.id,m.sender_id,m.recipient_id,m.group_id,m.type,g.name AS group_name,
      sf.moderation_details->'classification' AS classification,
      ${receivingFilter} AS receiving_filter
    FROM messages m ${contextJoins('$2')}
    WHERE m.id=$1 AND ${visibility('$2')}`, [id, userId]);
  const message = result.rows[0];
  if (!message || !contentVisible(message, userId, contentAllowedByFilter)) return null;
  return message;
}
async function readReactions(pool, id, userId) {
  return (await pool.query(`SELECT emoji,COUNT(*)::int AS count,BOOL_OR(user_id=$2) AS mine
    FROM message_reactions WHERE message_id=$1 GROUP BY emoji ORDER BY emoji`, [id, userId])).rows;
}
async function readReactionDetails(pool, id, userId) {
  // Identities are available only within this viewer's visible message and
  // exclude actors blocked in either direction. Never expose account contact
  // fields or return a profile photo outside the existing image policy.
  const result = await pool.query(`SELECT r.user_id,actor.name,actor.profile_pic_url,r.emoji
    FROM message_reactions r JOIN messages m ON m.id=r.message_id
    JOIN users actor ON actor.id=r.user_id ${contextJoins('$2')}
    WHERE r.message_id=$1 AND ${visibility('$2', 'r.user_id')}
    ORDER BY r.emoji,(r.user_id=$2) DESC,r.updated_at DESC,r.user_id`, [id, userId]);
  const profiles = await projectProfileImages(pool, userId, result.rows);
  const reactions = new Map();
  const users = profiles.map(row => {
    const mine = row.user_id === userId;
    const summary = reactions.get(row.emoji) || { emoji: row.emoji, count: 0, mine: false };
    summary.count++;
    summary.mine ||= mine;
    reactions.set(row.emoji, summary);
    return { user_id: row.user_id, name: row.name || 'משתמש',
      photo_url: row.profile_pic_url || null, emoji: row.emoji, mine };
  });
  return { reactions: [...reactions.values()], users };
}
async function reactionRows(pool, viewerId, kind, targets, contentAllowedByFilter) {
  const result = await pool.query(`SELECT r.message_id,r.user_id AS actor_id,actor.name AS actor_name,
      r.emoji,r.updated_at,statement_timestamp()::text AS read_at,m.sender_id,m.recipient_id,m.group_id,m.type,
      ${conversationTarget('$1')} AS target_id,
      (r.user_id<>$1 AND r.updated_at>ms.reactions_read_at) AS unread,
      sf.moderation_details->'classification' AS classification,
      ${receivingFilter} AS receiving_filter
    FROM message_reactions r JOIN messages m ON m.id=r.message_id
    JOIN users actor ON actor.id=r.user_id ${contextJoins('$1')}
    LEFT JOIN message_status ms ON ms.message_id=m.id AND ms.user_id=$1
    WHERE CASE WHEN $2='group' THEN m.group_id IS NOT NULL ELSE m.group_id IS NULL END
      AND ($3::uuid[] IS NULL OR ${conversationTarget('$1')}=ANY($3::uuid[]))
      AND ${visibility('$1', 'r.user_id')}
    ORDER BY r.updated_at DESC,r.message_id,r.user_id`, [viewerId, kind, targets]);
  return result.rows.filter(row => contentVisible(row, viewerId, contentAllowedByFilter));
}

async function projectReactionConversations(pool, viewerId, kind, rows, contentAllowedByFilter) {
  if (!rows.length) return rows;
  const reactions = await reactionRows(pool, viewerId, kind, rows.map(row => row.id), contentAllowedByFilter);
  const latest = new Map();
  for (const reaction of reactions) if (!latest.has(reaction.target_id)) latest.set(reaction.target_id, reaction);
  return rows.map(row => {
    const reaction = latest.get(row.id);
    if (!reaction || new Date(reaction.updated_at).getTime() <= new Date(row.last_message_at || 0).getTime()) return row;
    return { ...row, last_message_type: 'reaction', last_message: reaction.emoji,
      last_message_sender_name: reaction.actor_name, last_message_is_mine: reaction.actor_id === viewerId,
      last_message_at: reaction.updated_at, last_message_status: null,
      last_reaction_message_id: reaction.message_id, last_reaction_actor_id: reaction.actor_id };
  });
}

async function reactionUnreadCounts(pool, viewerId, kind, contentAllowedByFilter) {
  const counts = {};
  for (const row of await reactionRows(pool, viewerId, kind, null, contentAllowedByFilter)) {
    if (row.unread === true) counts[row.target_id] = (counts[row.target_id] || 0) + 1;
  }
  return counts;
}

async function markReactionsRead(pool, viewerId, kind, targetId, contentAllowedByFilter) {
  if (!UUID.test(targetId)) return;
  const rows = await reactionRows(pool, viewerId, kind, [targetId], contentAllowedByFilter);
  // Only messages with visible reactions need a watermark, including the
  // viewer's own messages. 'sent' cannot fabricate a read/delivery receipt.
  const ids = [...new Set(rows.map(row => row.message_id))];
  if (!ids.length) return;
  // Keep the read query's cutoff, including PostgreSQL microseconds. A later
  // reaction committed while this read is in flight must remain unread.
  await pool.query(`INSERT INTO message_status(message_id,user_id,status,reactions_read_at)
    SELECT id,$1,'sent',$3::timestamptz FROM unnest($2::uuid[]) AS message(id) WHERE TRUE
    ON CONFLICT(message_id,user_id) DO UPDATE SET reactions_read_at=
      GREATEST(message_status.reactions_read_at,EXCLUDED.reactions_read_at)`, [viewerId, ids, rows[0].read_at]);
}

async function reactionAudience(pool, message, actorId, contentAllowedByFilter) {
  const result = await pool.query(`SELECT u.id,m.sender_id,m.type,
      sf.moderation_details->'classification' AS classification,
      ${receivingFilter} AS receiving_filter
    FROM messages m JOIN users u ON
      (m.group_id IS NULL AND u.id IN (m.sender_id,m.recipient_id)) OR
      EXISTS (SELECT 1 FROM group_members member WHERE member.group_id=m.group_id
        AND member.user_id=u.id AND member.status='member')
    ${contextJoins('u.id', false)}
    WHERE m.id=$1 AND ${visibility('u.id', '$2')}`, [message.id, actorId]);
  return result.rows.filter(row => contentVisible(row, row.id, contentAllowedByFilter)).map(row => row.id);
}

function registerMessageReactions(app, { auth, rateLimit, getPool, contentAllowedByFilter,
  notifyReaction = () => {}, sendPush = async () => {} }) {
  const handler = (write, details = false) => async (req, res) => {
    if (!UUID.test(req.params.id)) return res.status(400).json({ error: 'מזהה הודעה לא תקין' });
    const emoji = req.body?.emoji;
    // A client's user_id/actorId/mine fields never select the mutation owner.
    // Every insert, replacement and removal is bound to authenticated req.user.
    if (write && emoji !== null && !ALLOWED_REACTIONS.includes(emoji))
      return res.status(400).json({ error: 'תגובה לא נתמכת' });
    try {
      const pool = await getPool();
      const message = await visibleMessage(pool, req.params.id, req.user.id, contentAllowedByFilter);
      if (!message)
        return res.status(404).json({ error: 'ההודעה אינה זמינה' });
      let changed;
      if (write) {
        const audience = await reactionAudience(pool, message, req.user.id, contentAllowedByFilter);
        const actor = await pool.query('SELECT name FROM users WHERE id=$1', [req.user.id]);
        const actorName = actor.rows[0]?.name || 'משתמש';
        if (emoji === null) changed = await pool.query(
          'DELETE FROM message_reactions WHERE message_id=$1 AND user_id=$2 RETURNING clock_timestamp() AS updated_at', [req.params.id, req.user.id]);
        else changed = await pool.query(`WITH changed AS (INSERT INTO message_reactions(message_id,user_id,emoji)
          VALUES($1,$2,$3) ON CONFLICT(message_id,user_id)
          DO UPDATE SET emoji=EXCLUDED.emoji,updated_at=clock_timestamp()
          WHERE message_reactions.emoji IS DISTINCT FROM EXCLUDED.emoji
          RETURNING updated_at), watermarks AS (
            INSERT INTO message_status(message_id,user_id,status,reactions_read_at)
            SELECT $1,id,'sent',changed.updated_at-INTERVAL '1 microsecond'
            FROM changed CROSS JOIN unnest($4::uuid[]) AS recipient(id) WHERE TRUE
            ON CONFLICT(message_id,user_id) DO UPDATE SET reactions_read_at=
              COALESCE(message_status.reactions_read_at,EXCLUDED.reactions_read_at)
            RETURNING message_id)
          SELECT updated_at FROM changed`, [req.params.id, req.user.id, emoji,
          audience.filter(viewerId => viewerId !== req.user.id)]);
        if (changed.rows.length) {
          const createdAt = new Date(changed.rows[0].updated_at).toISOString();
          const eventId = crypto.randomUUID();
          for (const viewerId of audience) {
            const targetId = message.group_id || (message.sender_id === viewerId ? message.recipient_id : message.sender_id);
            const payload = { eventId, messageId: message.id, actorId: req.user.id, actorName, emoji,
              kind: message.group_id ? 'group' : 'chat', targetId, groupId: message.group_id || null,
              createdAt, removed: emoji === null };
            // Persistence has completed. Transport failure cannot reject an
            // accepted reaction or turn a retry into another notification.
            Promise.resolve().then(() => notifyReaction(viewerId, payload)).catch(() => {});
            if (emoji !== null && viewerId !== req.user.id) {
              const data = message.group_id
                ? { type: 'group', groupId: message.group_id, groupName: message.group_name || 'קבוצה', fromUserId: req.user.id }
                : { type: 'chat', fromUserId: req.user.id };
              Promise.resolve().then(() => sendPush(viewerId,
                message.group_id ? `${message.group_name || 'קבוצה'} • ${actorName}` : actorName,
                `הגיב/ה ${reactionLabel(emoji)}`, { ...data, messageId: message.id, reaction: 'true' })).catch(() => {});
            }
          }
        }
      }
      res.set('Cache-Control', 'no-store');
      if (details) return res.json(await readReactionDetails(pool, req.params.id, req.user.id));
      return res.json(await readReactions(pool, req.params.id, req.user.id));
    } catch (_) { return res.status(500).json({ error: 'לא ניתן לעדכן או לטעון תגובות כעת' }); }
  };
  app.get('/api/messages/:id/reactions', auth, handler(false));
  app.get('/api/messages/:id/reactions/details', auth, handler(false, true));
  app.put('/api/messages/:id/reactions', auth, rateLimit, handler(true));
}
module.exports = { REACTIONS, ALLOWED_REACTIONS, REACTION_EMOJI_SCHEMA, REACTION_READ_SCHEMA,
  visibleMessage, readReactions, readReactionDetails, registerMessageReactions,
  reactionRows, projectReactionConversations, reactionUnreadCounts, markReactionsRead };
