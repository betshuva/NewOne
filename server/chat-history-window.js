function chatHistoryWindow(query = {}) {
  if (query.before) return { initialUnread: false, since: null, extended: false };
  const raw = typeof query.historySince === 'string' ? query.historySince : '';
  const since = raw && Number.isFinite(Date.parse(raw)) ? new Date(raw) : null;
  const initialUnread = !since && query.initialUnread === '1';
  return { initialUnread, since, extended: Boolean(initialUnread || since) };
}

// baseSql already enforces membership, deletion, clear-history and file access.
// Select the opening window from that same visible set, never from raw messages.
function chatHistoryQuery(baseSql, params, viewerParameter, window) {
  if (window.since) {
    return {
      text: `SELECT * FROM (${baseSql}) visible_history
        WHERE created_at >= $${params.length + 1}
        ORDER BY created_at DESC, id DESC`,
      values: [...params, window.since],
    };
  }
  if (window.initialUnread) {
    return {
      text: `WITH visible_history AS (${baseSql})
        SELECT * FROM visible_history
        WHERE id IN (SELECT id FROM visible_history ORDER BY created_at DESC, id DESC LIMIT 50)
          OR created_at >= (SELECT MIN(created_at) FROM visible_history
            WHERE sender_id <> ${viewerParameter} AND is_read = 0)
        ORDER BY created_at DESC, id DESC`,
      values: params,
    };
  }
  return { text: `${baseSql} ORDER BY created_at DESC, id DESC LIMIT 50`, values: params };
}

module.exports = { chatHistoryWindow, chatHistoryQuery };
