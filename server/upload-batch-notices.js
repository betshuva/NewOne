'use strict';

const SCHEMA = `CREATE TABLE IF NOT EXISTS user_upload_batch_notices (
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('personal','group')),
  target_id TEXT NOT NULL,
  body TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (user_id,id)
);
CREATE INDEX IF NOT EXISTS upload_batch_notice_conversation
ON user_upload_batch_notices(user_id,kind,target_id,created_at);`;

function registerUploadBatchNotices(app, { auth, getPool }) {
  const validTarget = value => ['personal', 'group'].includes(value.kind) &&
    typeof value.target === 'string' && /^[\w-]{1,100}$/.test(value.target);
  app.get('/api/upload-batch-notices', auth, async (req, res) => {
    if (!validTarget(req.query)) return res.status(400).json({ error: 'שיחה לא תקינה' });
    try {
      const db = await getPool();
      const result = await db.query(`SELECT id,body AS text,created_at AS "createdAt"
        FROM user_upload_batch_notices WHERE user_id=$1 AND kind=$2 AND target_id=$3
        ORDER BY created_at,id`, [req.user.id, req.query.kind, req.query.target]);
      res.set('Cache-Control', 'no-store');
      res.json(result.rows.map(row => ({ ...row, isUploadBatchNotice: true })));
    } catch (_) {
      res.status(500).json({ error: 'טעינת הודעות ההעלאה נכשלה' });
    }
  });
  app.post('/api/upload-batch-notices', auth, async (req, res) => {
    const data = req.body || {};
    const count = /^(?:מעלה ([1-9]\d{0,2}) קבצים|סוף העלאת ([1-9]\d{0,2}) קבצים|העלאת ([1-9]\d{0,2}) קבצים הופסקה)$/.exec(data.text || '');
    const summary = /^סוף תור ההעלאה: (\d{1,3}) מתוך ([1-9]\d{0,2}) הושלמו, ([1-9]\d{0,2}) נכשלו$/.exec(data.text || '');
    const validCount = count && Number(count[1] || count[2] || count[3]) <= 100;
    const validSummary = summary && Number(summary[2]) <= 100 &&
      Number(summary[1]) + Number(summary[3]) === Number(summary[2]);
    if (!validTarget(data) || typeof data.id !== 'string' || !/^[\w-]{1,100}$/.test(data.id) ||
        (!validCount && !validSummary) ||
        typeof data.createdAt !== 'string' || !Number.isFinite(Date.parse(data.createdAt)))
      return res.status(400).json({ error: 'הודעת העלאה לא תקינה' });
    try {
      const db = await getPool();
      // Private history annotations: no recipient message, notification or AI reply.
      await db.query(`INSERT INTO user_upload_batch_notices
        (user_id,id,kind,target_id,body,created_at) VALUES($1,$2,$3,$4,$5,$6)
        ON CONFLICT(user_id,id) DO NOTHING`,
      [req.user.id, data.id, data.kind, data.target, data.text, data.createdAt]);
      res.status(201).json({ saved: true });
    } catch (_) {
      res.status(500).json({ error: 'שמירת הודעת ההעלאה נכשלה' });
    }
  });
}

module.exports = { SCHEMA, registerUploadBatchNotices };
