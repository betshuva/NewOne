'use strict';

const { personalMessageVisible } = require('./conversation-history');
const { inlineEmojiPlainText } = require('./inline-custom-emoji');
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PAGE_SIZE = 500;

function searchText(value) {
  return inlineEmojiPlainText(String(value || '')).normalize('NFKC')
    .replace(/[\u0591-\u05bd\u05bf-\u05c7]/g, '').toLocaleLowerCase();
}

function registerConversationSearch(app, { auth, rateLimit, getPool,
  projectFilteredHistory, teenContactAllowed, projectGuideFilterNotice, systemUserId }) {
  app.get('/api/conversations/search', auth, rateLimit, async (req, res) => {
    res.set('Cache-Control', 'no-store');
    const query = searchText(String(req.query.q || '').trim().slice(0, 120));
    if (!query) return res.json({ messages: [], nextCursor: null });
    let cursor = null;
    if (req.query.cursor) {
      try {
        cursor = JSON.parse(Buffer.from(String(req.query.cursor), 'base64url').toString());
        if (!UUID.test(cursor.id) || !Number.isFinite(Date.parse(cursor.at))) throw Error();
      } catch (_) { return res.status(400).json({ error: 'סמן חיפוש לא תקין' }); }
    }
    try {
      const pool = await getPool();
      // Bodies are decrypted by the protected DB adapter. Never build a
      // plaintext index or return raw matches before applying history policy.
      const result = await pool.query(`SELECT m.id,m.sender_id,m.recipient_id,m.group_id,
          m.body,m.type,m.file_name,m.created_at,
          to_char(m.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS cursor_at,
          (m.delivery_summary->'guideFilterNotice'->>'key') IS NOT NULL AS _guide_filter_notice,
          COALESCE(g.name,u.name) AS conversation_name, sender.name AS sender_name,
          COALESCE(m.group_id,u.id) AS conversation_id
        FROM messages m
        LEFT JOIN groups g ON g.id=m.group_id
        LEFT JOIN users u ON u.id=CASE WHEN m.sender_id=$1 THEN m.recipient_id ELSE m.sender_id END
        LEFT JOIN users sender ON sender.id=m.sender_id
        WHERE ${personalMessageVisible('m', '$1')}
          AND (NOT $2::boolean OR m.group_id IS NULL)
          ${cursor ? 'AND (m.created_at,m.id)<($3::timestamptz,$4::uuid)' : ''}
        ORDER BY m.created_at DESC,m.id DESC LIMIT ${PAGE_SIZE + 1}`,
      cursor ? [req.user.id, !!req.user.isTeen, cursor.at, cursor.id] : [req.user.id, !!req.user.isTeen]);
      const page = result.rows.slice(0, PAGE_SIZE);
      const candidates = page.filter(row => searchText(row.body).includes(query) || searchText(row.file_name).includes(query));
      const conversations = new Map();
      for (const row of candidates) {
        const key = `${row.group_id ? 'group' : 'chat'}:${row.conversation_id}`;
        if (!conversations.has(key)) conversations.set(key, []);
        conversations.get(key).push(row);
      }
      const messages = [];
      for (const rows of conversations.values()) {
        const first = rows[0];
        if (!first.group_id && !await teenContactAllowed(pool, req.user.id, first.conversation_id)) continue;
        const visible = await projectFilteredHistory(pool, req.user.id, rows, { groupId: first.group_id });
        for (const raw of visible) {
          const row = projectGuideFilterNotice(raw, req.user.id, systemUserId);
          if (row.filter_hidden) continue;
          const content = inlineEmojiPlainText([row.body, row.file_name].filter(Boolean).join(' '));
          const matchAt = searchText(content).indexOf(query);
          if (matchAt < 0) continue;
          const start = Math.max(0, matchAt - 80);
          const body = (start ? '…' : '') + content.slice(start, start + 320) +
            (content.length > start + 320 ? '…' : '');
          messages.push({ id: row.id, kind: row.group_id ? 'group' : 'chat',
            conversation_id: row.conversation_id, conversation_name: row.conversation_name,
            sender_name: row.sender_name, created_at: row.created_at, body });
        }
      }
      messages.sort((a, b) => new Date(b.created_at) - new Date(a.created_at) || b.id.localeCompare(a.id));
      const last = page.at(-1);
      res.json({ messages, nextCursor: result.rows.length > PAGE_SIZE && last
        ? Buffer.from(JSON.stringify({ at: last.cursor_at, id: last.id })).toString('base64url') : null });
    } catch (_) { res.status(500).json({ error: 'לא ניתן לחפש בשיחות כרגע' }); }
  });
}

module.exports = { registerConversationSearch, searchText };
