const { personalMessageVisible } = require('./conversation-history');

const MAX_ITEMS = 20;
const MAX_FILE_BYTES = 2 * 1024 * 1024;
const MAX_TOTAL_BYTES = 10 * 1024 * 1024;

function registerUnreadMediaPrefetch(app, {
  auth, getPool, projectFilteredHistory, contentAllowedByFilter,
  teenContactAllowed,
}) {
  app.get('/api/media/unread-prefetch', auth, async (req, res) => {
    res.set('Cache-Control', 'no-store');
    try {
      const pool = await getPool();
      // A read-only selection: never retain copies, acknowledge delivery, or
      // mark messages as read just because their bytes were prefetched.
      const result = await pool.query(`
        SELECT m.id,m.sender_id,m.recipient_id,m.group_id,m.type,m.file_url,
          m.created_at,sf.file_size,
          sf.moderation_details->'classification' AS classification,
          betshuva_effective_filter(viewer.content_filter,
            CASE WHEN m.group_id IS NULL THEN contact.filter_override
              ELSE COALESCE(gm.filter_override,
                CASE WHEN g.creator_id=$1 THEN g.content_filter END) END) AS viewer_filter,
          betshuva_effective_filter(creator.content_filter,g.content_filter) AS group_filter
        FROM messages m
        JOIN stored_files sf ON sf.public_url=m.file_url
        JOIN users viewer ON viewer.id=$1
        LEFT JOIN message_status ms ON ms.message_id=m.id AND ms.user_id=$1
        LEFT JOIN group_members gm ON gm.group_id=m.group_id AND gm.user_id=$1
        LEFT JOIN groups g ON g.id=m.group_id
        LEFT JOIN users creator ON creator.id=g.creator_id
        LEFT JOIN user_contacts contact ON contact.owner_id=$1 AND contact.contact_id=m.sender_id
        WHERE m.sender_id<>$1 AND m.type IN ('image','video')
          AND sf.file_type=m.type
          AND sf.moderation_status='approved' AND sf.content_purged_at IS NULL
          AND sf.file_size>0 AND sf.file_size<=$3
          AND (ms.status IS NULL OR ms.status<>'read')
          AND NOT EXISTS (SELECT 1 FROM user_message_filter_actions action
            WHERE action.user_id=$1 AND action.message_id=m.id AND action.action IN ('hide','delete'))
          AND ${personalMessageVisible('m', '$1')}
          AND (m.group_id IS NOT NULL OR m.recipient_id=$1)
          AND (NOT $2 OR m.group_id IS NULL)
        ORDER BY m.created_at DESC,m.id DESC LIMIT 100`,
      [req.user.id, req.user.isTeen === true, MAX_FILE_BYTES]);
      const grouped = new Map();
      for (const row of result.rows) {
        const key = row.group_id || '';
        if (!grouped.has(key)) grouped.set(key, []);
        grouped.get(key).push(row);
      }
      const visible = new Map();
      for (const [groupId, rows] of grouped) {
        const projected = await projectFilteredHistory(pool, req.user.id, rows,
          { groupId: groupId || null });
        for (const row of projected) visible.set(row.id, row);
      }
      const contacts = new Map(), urls = new Set(), perConversation = new Map();
      const items = [];
      let totalBytes = 0;
      for (const candidate of result.rows) {
        const row = visible.get(candidate.id);
        if (!row || row.filter_hidden || !row.file_url ||
            row.content_purged_at || row.file_url !== candidate.file_url) continue;
        if (!row.group_id) {
          if (!contacts.has(row.sender_id)) contacts.set(row.sender_id,
            await teenContactAllowed(pool, req.user.id, row.sender_id));
          if (!contacts.get(row.sender_id)) continue;
        }
        if (row.type === 'video' &&
            (!contentAllowedByFilter(row.viewer_filter, 'video', row.classification) ||
              row.group_id && !contentAllowedByFilter(row.group_filter, 'video', row.classification))) continue;
        const size = Number(row.file_size), kind = row.group_id ? 'group' : 'chat';
        const targetId = row.group_id || row.sender_id, conversation = `${kind}:${targetId}`;
        if (!Number.isSafeInteger(size) || size <= 0 || size > MAX_FILE_BYTES ||
            urls.has(row.file_url) || totalBytes + size > MAX_TOTAL_BYTES ||
            (perConversation.get(conversation) || 0) >= 5) continue;
        urls.add(row.file_url);
        totalBytes += size;
        perConversation.set(conversation, (perConversation.get(conversation) || 0) + 1);
        items.push({ messageId: row.id, kind, targetId, type: row.type,
          url: row.file_url, bytes: size });
        if (items.length >= MAX_ITEMS) break;
      }
      res.json({ items, limits: { maxItems: MAX_ITEMS, maxFileBytes: MAX_FILE_BYTES,
        maxTotalBytes: MAX_TOTAL_BYTES, concurrency: 2 } });
    } catch (error) {
      console.error('unread media prefetch:', error.message);
      res.status(500).json({ error: 'טעינת המדיה המקדימה נכשלה' });
    }
  });
}

module.exports = { registerUnreadMediaPrefetch, MAX_ITEMS, MAX_FILE_BYTES, MAX_TOTAL_BYTES };
