'use strict';

const { personalMessageVisible } = require('./conversation-history');

const MEDIA_PROGRESS_SCHEMA = `CREATE TABLE IF NOT EXISTS media_playback_progress (
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  content_key TEXT NOT NULL,
  position_ms BIGINT NOT NULL CHECK (position_ms >= 0),
  version BIGINT NOT NULL DEFAULT 1,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY(user_id,content_key)
)`;

async function accessibleMedia(db, userId, fileUrl, fileType) {
  const result = await db.query(`SELECT sf.id,sf.content_sha256,
      sf.moderation_details->'audio'->>'durationSeconds' AS duration_seconds
    FROM stored_files sf WHERE sf.public_url=$2 AND sf.file_type=$3
      AND sf.moderation_status='approved' AND sf.content_purged_at IS NULL
      AND (sf.user_id=$1 OR EXISTS (SELECT 1 FROM messages m
        WHERE m.file_url=sf.public_url AND ${personalMessageVisible('m', '$1')}))
    LIMIT 1`, [userId, fileUrl, fileType]);
  const file = result.rows[0];
  if (!file) return null;
  // Personal copies and repeated sends of the same recording share progress.
  return { key: /^[a-f0-9]{64}$/.test(file.content_sha256 || '')
    ? `${fileType}:sha256:${file.content_sha256}` : `${fileType}:file:${file.id}`,
    durationMs: Math.round(Number(file.duration_seconds) * 1000) };
}

function registerMediaProgressRoutes(app, { auth, getPool }) {
  for (const fileType of ['audio', 'video']) {
  for (const method of ['get', 'put']) app[method](`/api/${fileType}-progress`, auth, async (req, res) => {
    res.set('Cache-Control', 'no-store');
    const url = req.query.fileUrl;
    if (typeof url !== 'string' || !url.startsWith('/betshuva-app/uploads/') ||
        url.length > 2048 || /[\x00-\x20\x7f]/.test(url)) {
      return res.status(400).json({ error: 'כתובת הקובץ אינה תקינה' });
    }
    const { positionMs, version } = req.body || {};
    if (method === 'put' && (!Number.isSafeInteger(positionMs) || positionMs < 0 ||
        !Number.isSafeInteger(version) || version < 0)) {
      return res.status(400).json({ error: 'נקודת ההמשך אינה תקינה' });
    }
    try {
      const db = await getPool();
      const file = await accessibleMedia(db, req.user.id, url, fileType);
      if (!file) return res.status(404).json({ error: 'הקובץ אינו זמין' });
      if (method === 'put') {
        const boundedPosition = file.durationMs > 0 ? Math.min(positionMs, file.durationMs) : positionMs;
        // Compare-and-swap prevents a delayed save from another tab/device
        // replacing a newer stop point. Seeking backwards remains supported.
        const updated = await db.query(`INSERT INTO media_playback_progress AS progress
          (user_id,content_key,position_ms,version)
          SELECT $1,$2,$3,1 WHERE $4::bigint=0
          ON CONFLICT(user_id,content_key) DO NOTHING RETURNING position_ms,version`,
        [req.user.id, file.key, boundedPosition, version]);
        const result = updated.rows.length ? updated : await db.query(`UPDATE media_playback_progress
          SET position_ms=$3,version=version+1,updated_at=now()
          WHERE user_id=$1 AND content_key=$2 AND version=$4 RETURNING position_ms,version`,
        [req.user.id, file.key, boundedPosition, version]);
        if (result.rows.length) return res.json({ positionMs: Number(result.rows[0].position_ms),
          version: Number(result.rows[0].version) });
        return res.status(409).json({ error: 'נקודת ההמשך עודכנה ממכשיר אחר', code: 'PROGRESS_CHANGED' });
      }
      const result = await db.query(`SELECT position_ms,version FROM media_playback_progress
        WHERE user_id=$1 AND content_key=$2`, [req.user.id, file.key]);
      const saved = result.rows[0];
      return res.json({ positionMs: Number(saved?.position_ms || 0), version: Number(saved?.version || 0) });
    } catch (error) {
      console.error('[media-progress]', error.code || 'unavailable');
      return res.status(503).json({ error: 'שמירת נקודת ההמשך אינה זמינה כרגע' });
    }
  });
  }
}

module.exports = { MEDIA_PROGRESS_SCHEMA, registerMediaProgressRoutes };
