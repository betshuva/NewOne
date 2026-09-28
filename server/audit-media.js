'use strict';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_BYTES = 50 * 1024 * 1024;
const MIME_TYPES = {
  image: new Set(['image/jpeg', 'image/png', 'image/webp', 'image/gif']),
  video: new Set(['video/mp4', 'video/webm', 'video/quicktime']),
  audio: new Set(['audio/mpeg', 'audio/aac', 'audio/mp4', 'audio/webm', 'audio/ogg', 'audio/wav', 'audio/x-wav']),
  document: new Set(['application/pdf']),
};
// The operation/file relationship is rechecked on every request. Neither a URL
// supplied by the client nor possession of a file UUID grants access.
const FILE_LINK = `sf.id=COALESCE(CASE WHEN e.target_type='file' THEN e.target_id END,
  CASE WHEN e.details->>'storedFileId' ~* '${UUID.source}'
    THEN (e.details->>'storedFileId')::uuid END)`;

async function attachOperationMedia(db, rows, mode) {
  const ids = [...new Set(rows.map(row => mode === 'events' ? row.operation_id : row.id)
    .filter(id => UUID.test(id || '')))];
  if (!ids.length) return;
  const result = await db.query(`SELECT DISTINCT e.operation_id,sf.id,sf.file_type,sf.mime_type,
      sf.original_name,sf.content_purged_at,
      EXISTS(SELECT 1 FROM audit_scan_previews p WHERE p.stored_file_id=sf.id
        AND sf.file_type='image' AND sf.moderation_status='rejected') AS has_image_preview
    FROM audit_events e JOIN stored_files sf ON ${FILE_LINK}
    WHERE e.operation_id=ANY($1::uuid[]) ORDER BY e.operation_id,sf.id`, [ids]);
  const byOperation = new Map();
  for (const file of result.rows) {
    if (!MIME_TYPES[file.file_type]?.has(file.mime_type)) continue;
    const item = { id: file.id, operationId: file.operation_id, mediaType: file.file_type,
      mimeType: file.mime_type, name: file.original_name,
      available: !file.content_purged_at || file.has_image_preview,
      url: `/api/admin/audit/operations/${file.operation_id}/media/${file.id}` };
    if (!byOperation.has(file.operation_id)) byOperation.set(file.operation_id, []);
    byOperation.get(file.operation_id).push(item);
  }
  for (const row of rows) row.operationMedia = byOperation.get(mode === 'events' ? row.operation_id : row.id) || [];
}

function registerAuditMediaRoutes(app, { getPool, adminMiddleware, readMedia }) {
  app.get('/api/admin/audit/operations/:id/media/:fileId', adminMiddleware, async (req, res) => {
    res.set('Cache-Control', 'private, no-store, max-age=0');
    res.set('X-Content-Type-Options', 'nosniff');
    res.set('Referrer-Policy', 'no-referrer');
    if (!UUID.test(req.user?.id || '') || !['view', 'edit'].includes(req.adminPerm))
      return res.status(403).json({ error: 'אין הרשאת צפייה בקובץ' });
    if (!UUID.test(req.params.id || '') || !UUID.test(req.params.fileId || ''))
      return res.status(400).json({ error: 'בקשת תצוגה אינה תקינה' });
    try {
      const db = await getPool();
      const result = await db.query(`SELECT sf.* FROM stored_files sf WHERE sf.id=$2
        AND EXISTS(SELECT 1 FROM audit_events e WHERE e.operation_id=$1 AND ${FILE_LINK})`,
      [req.params.id, req.params.fileId]);
      const file = result.rows[0];
      if (!file || !MIME_TYPES[file.file_type]?.has(file.mime_type))
        return res.status(404).json({ error: 'הקובץ אינו זמין לתצוגה' });
      let bytes, mime = file.mime_type;
      // A retained audit image remains available after a rejected image's
      // original bytes expire. Never restore deleted audio/video/documents.
      if (file.content_purged_at) {
        if (file.file_type === 'image' && file.moderation_status === 'rejected') {
          const preview = await db.query('SELECT image FROM audit_scan_previews WHERE stored_file_id=$1 ORDER BY created_at LIMIT 1', [file.id]);
          bytes = preview.rows[0]?.image;
          mime = 'image/jpeg';
        }
        if (!bytes) return res.status(404).json({ error: 'הקובץ נמחק ואינו זמין' });
      } else {
        if (!Number.isFinite(Number(file.file_size)) || Number(file.file_size) > MAX_BYTES)
          return res.status(413).json({ error: 'הקובץ גדול מדי לתצוגה' });
        bytes = await readMedia(db, file);
      }
      if (!Buffer.isBuffer(bytes) || !bytes.length || bytes.length > MAX_BYTES)
        return res.status(404).json({ error: 'הקובץ אינו זמין' });
      res.set('Content-Type', mime);
      res.set('Content-Disposition', 'inline');
      return res.send(bytes);
    } catch (error) {
      console.warn('Audit media unavailable:', error.code || error.name);
      return res.status(error.code === 'ENOENT' ? 404 : 503).json({ error: 'הקובץ אינו זמין כרגע' });
    }
  });
}

module.exports = { attachOperationMedia, registerAuditMediaRoutes };
