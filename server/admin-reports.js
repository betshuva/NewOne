'use strict';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const STATUSES = new Set(['pending', 'reviewed', 'resolved', 'dismissed']);

function registerAdminReportRoutes(app, { getPool, adminMiddleware }) {
  app.get('/api/admin/reports', adminMiddleware, async (req, res) => {
    res.set('Cache-Control', 'no-store');
    const status = String(req.query.status || 'pending');
    const offset = String(req.query.offset || '0');
    if ((!STATUSES.has(status) && status !== 'all') || !/^\d{1,7}$/.test(offset))
      return res.status(400).json({ error: 'מסנן הדיווחים אינו תקין' });
    try {
      const pool = await getPool();
      const result = await pool.query(`
        SELECT r.id,r.target_type,r.target_id,r.reason,r.details,r.status,
          r.created_at,r.reviewed_at,r.reviewed_by,r.xmin::text AS revision,
          r.reporter_id,u.name AS reporter_name,u.email AS reporter_email,
          reviewer.name AS reviewer_name,
          CASE r.target_type
            WHEN 'user' THEN left(target_user.name,2000)
            WHEN 'group' THEN left(concat_ws(E'\n',g.name,g.description),2000)
            WHEN 'listing' THEN left(concat_ws(E'\n',l.title,l.description),2000)
            WHEN 'message' THEN left(concat_ws(E'\n',m.body,m.file_name),2000)
          END AS target_summary,
          COALESCE(target_user.id,g.id,l.id,m.id) IS NOT NULL AS target_available,
          m.sender_id AS message_sender_id,m.deleted_for_everyone,
          r.notification_version,r.notified_version,r.notification_sent_at
        FROM user_reports r JOIN users u ON u.id=r.reporter_id
        LEFT JOIN users reviewer ON reviewer.id=r.reviewed_by
        LEFT JOIN users target_user ON r.target_type='user' AND target_user.id=r.target_id
        LEFT JOIN groups g ON r.target_type='group' AND g.id=r.target_id
        LEFT JOIN listings l ON r.target_type='listing' AND l.id=r.target_id
        LEFT JOIN messages m ON r.target_type='message' AND m.id=r.target_id
        WHERE ($1='all' OR r.status=$1)
        ORDER BY r.created_at DESC,r.id DESC LIMIT 101 OFFSET $2`, [status, Number(offset)]);
      res.set('X-Has-More', result.rows.length > 100 ? 'true' : 'false');
      res.json(result.rows.slice(0, 100));
    } catch {
      res.status(500).json({ error: 'לא ניתן לטעון את הדיווחים' });
    }
  });

  app.put('/api/admin/reports/:id', adminMiddleware, async (req, res) => {
    res.set('Cache-Control', 'no-store');
    if (req.adminPerm !== 'edit')
      return res.status(403).json({ error: 'נדרשת הרשאת עריכה' });
    const { status, revision } = req.body || {};
    if (!UUID.test(req.params.id) || !STATUSES.has(status) || !/^\d{1,20}$/.test(String(revision || '')))
      return res.status(400).json({ error: 'פרטי העדכון אינם תקינים; יש לרענן את רשימת הדיווחים' });
    try {
      const pool = await getPool();
      // Reject a stale review, including a report resubmitted while the screen was open.
      const result = await pool.query(`UPDATE user_reports
        SET status=$1,reviewed_by=$2,reviewed_at=clock_timestamp()
        WHERE id=$3 AND xmin::text=$4
        RETURNING id,status,reviewed_by,reviewed_at,xmin::text AS revision`,
      [status, req.user.id, req.params.id, String(revision)]);
      if (!result.rows.length) {
        const exists = await pool.query('SELECT 1 FROM user_reports WHERE id=$1', [req.params.id]);
        return res.status(exists.rows.length ? 409 : 404).json({ error: exists.rows.length
          ? 'הדיווח השתנה מאז טעינת המסך. יש לרענן ולבדוק את העדכון לפני השמירה'
          : 'דיווח לא נמצא' });
      }
      res.json(result.rows[0]);
    } catch {
      res.status(500).json({ error: 'לא ניתן לעדכן את הדיווח' });
    }
  });
}

module.exports = { registerAdminReportRoutes };
