'use strict';

const { personalMessageVisible } = require('./conversation-history');

function registerMediaRenameRoutes(app, { auth, getPool }) {
  app.get('/api/media-library/resolve', auth, async (req, res) => {
    const url = req.query.url;
    if (typeof url !== 'string' || !url || url.length > 2048 ||
        /[\x00-\x20\x7f]/.test(url) ||
        !(url.startsWith('/') && !url.startsWith('//') || /^https?:\/\//i.test(url))) {
      return res.status(400).json({ error: 'כתובת הקובץ אינה תקינה' });
    }
    res.set('Cache-Control', 'no-store');
    try {
      const db = await getPool();
      const result = await db.query(`SELECT sf.id,sf.original_name AS name
        FROM stored_files sf
        WHERE sf.user_id=$1 AND sf.content_purged_at IS NULL AND (
          sf.public_url=$2 OR EXISTS (
            SELECT 1 FROM received_message_media received
            JOIN messages m ON m.id=received.message_id
            WHERE received.user_id=$1 AND received.stored_file_id=sf.id
              AND received.status='ready' AND m.file_url=$2
              AND ${personalMessageVisible('m', '$1')}
          ))
        ORDER BY (sf.public_url=$2) DESC,sf.id LIMIT 1`, [req.user.id, url]);
      if (!result.rows.length) return res.status(404).json({ error: 'הקובץ אינו נמצא במדיה שלך' });
      return res.json({ item: result.rows[0] });
    } catch (_) {
      return res.status(500).json({ error: 'לא ניתן לטעון את שם הקובץ' });
    }
  });
}

module.exports = { registerMediaRenameRoutes };
