'use strict';

const { createHash, randomUUID } = require('node:crypto');
const sharp = require('sharp');

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_IMAGE_BYTES = 512 * 1024;
const MAX_THUMB_BYTES = 24 * 1024;

async function ensureAuditScanPreviewSchema(pool) {
  await pool.query(`CREATE TABLE IF NOT EXISTS audit_scan_previews (
    id uuid PRIMARY KEY,
    stored_file_id uuid NOT NULL REFERENCES stored_files(id) ON DELETE CASCADE,
    content_sha256 text NOT NULL CHECK (content_sha256 ~ '^[a-f0-9]{64}$'),
    thumbnail bytea NOT NULL CHECK (octet_length(thumbnail) BETWEEN 1 AND ${MAX_THUMB_BYTES}),
    image bytea NOT NULL CHECK (octet_length(image) BETWEEN 1 AND ${MAX_IMAGE_BYTES}),
    width integer NOT NULL CHECK (width BETWEEN 1 AND 768),
    height integer NOT NULL CHECK (height BETWEEN 1 AND 768),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(stored_file_id,content_sha256)
  );
  CREATE OR REPLACE FUNCTION purge_audit_scan_previews() RETURNS trigger LANGUAGE plpgsql AS $$
  BEGIN
    IF NEW.content_purged_at IS NOT NULL
      AND NOT (NEW.file_type IN ('image','video') AND NEW.moderation_status IN ('rejected','stopped')) THEN
      DELETE FROM audit_scan_previews WHERE stored_file_id=NEW.id;
    END IF;
    RETURN NEW;
  END $$;
  DROP TRIGGER IF EXISTS purge_audit_scan_previews ON stored_files;
  CREATE TRIGGER purge_audit_scan_previews AFTER UPDATE OF content_purged_at ON stored_files
    FOR EACH ROW EXECUTE FUNCTION purge_audit_scan_previews();`);
}

async function saveAuditScanPreview(pool, { storedFileId, buffer }) {
  if (!UUID.test(storedFileId || '') || !Buffer.isBuffer(buffer) ||
      !buffer.length || buffer.length > 50 * 1024 * 1024) return null;
  // Preview errors must never change the moderation decision or retry a provider.
  try {
    const hash = createHash('sha256').update(buffer).digest('hex');
    const prepared = await sharp(buffer, { limitInputPixels: 40000000, animated: false })
      .rotate().resize({ width: 768, height: 768, fit: 'inside', withoutEnlargement: true })
      .flatten({ background: '#ffffff' }).jpeg({ quality: 80 }).toBuffer({ resolveWithObject: true });
    const thumbnail = await sharp(prepared.data)
      .resize({ width: 120, height: 90, fit: 'inside', withoutEnlargement: true })
      .jpeg({ quality: 72 }).toBuffer();
    if (prepared.data.length > MAX_IMAGE_BYTES || thumbnail.length > MAX_THUMB_BYTES) return null;
    // Lock the source before inserting so a concurrent purge cannot leave a new copy behind.
    const saved = await pool.query(`WITH source AS (
      SELECT id FROM stored_files WHERE id=$2 AND content_purged_at IS NULL
        AND (blocked_content_expires_at IS NULL OR blocked_content_expires_at>clock_timestamp()) FOR SHARE
    ) INSERT INTO audit_scan_previews(id,stored_file_id,content_sha256,thumbnail,image,width,height)
      SELECT $1,source.id,$3,$4,$5,$6,$7 FROM source
      ON CONFLICT(stored_file_id,content_sha256) DO UPDATE SET content_sha256=EXCLUDED.content_sha256
      RETURNING id`, [randomUUID(), storedFileId, hash, thumbnail, prepared.data,
    prepared.info.width, prepared.info.height]);
    return saved.rows[0]?.id || null;
  } catch (error) {
    console.warn('Scan preview unavailable:', error.code || error.name);
    return null;
  }
}

async function purgeExpiredAuditScanPreviews(pool) {
  // Keep rejected image/video evidence for the admin audit after playback expires.
  // Deleting the source record still cascades to every retained preview.
  return pool.query(`DELETE FROM audit_scan_previews WHERE id IN (
    SELECT p.id FROM audit_scan_previews p JOIN stored_files sf ON sf.id=p.stored_file_id
    WHERE (sf.content_purged_at IS NOT NULL OR sf.blocked_content_expires_at<=clock_timestamp())
      AND NOT (sf.file_type IN ('image','video') AND sf.moderation_status IN ('rejected','stopped'))
    ORDER BY p.created_at LIMIT 500)`);
}

async function attachOperationPreviews(pool, rows, mode) {
  const ids = [...new Set(rows.map(row => mode === 'events' ? row.operation_id : row.id)
    .filter(id => UUID.test(id || '')))];
  if (!ids.length) return;
  // Select across the whole operation, independent of filters, pagination and
  // provider completion order. Later video frames never substitute for frame 0.
  const result = await pool.query(`SELECT DISTINCT ON (e.operation_id)
      e.operation_id,e.id AS event_id,sf.file_type
    FROM audit_events e
    JOIN audit_scan_previews p ON p.id::text=e.details->>'scanPreviewId'
    JOIN stored_files sf ON sf.id=p.stored_file_id
    WHERE e.operation_id=ANY($1::uuid[]) AND e.details->>'storedFileId'=sf.id::text
      AND (sf.file_type='image' OR (sf.file_type='video' AND
        (e.details->>'frameIndex'='0' OR (NOT (e.details ? 'frameIndex') AND e.details->>'frameTimestampMs'='0'))))
      AND ((sf.file_type IN ('image','video') AND sf.moderation_status IN ('rejected','stopped')) OR
        (sf.content_purged_at IS NULL AND
          (sf.blocked_content_expires_at IS NULL OR sf.blocked_content_expires_at>clock_timestamp())))
    ORDER BY e.operation_id,e.id`, [ids]);
  const byOperation = new Map(result.rows.map(row => [row.operation_id, {
    eventId: String(row.event_id), mediaType: row.file_type,
    url: `/api/admin/audit/events/${row.event_id}/preview?size=thumb`,
    fullUrl: `/api/admin/audit/events/${row.event_id}/preview?size=full`,
  }]));
  for (const row of rows) row.operationPreview = byOperation.get(mode === 'events' ? row.operation_id : row.id) || null;
}

function registerAuditScanPreviewRoutes(app, { getPool, adminMiddleware }) {
  app.get('/api/admin/audit/events/:id/preview', adminMiddleware, async (req, res) => {
    res.set('Cache-Control', 'private, no-store, max-age=0');
    res.set('X-Content-Type-Options', 'nosniff');
    res.set('Referrer-Policy', 'no-referrer');
    if (!UUID.test(req.user?.id || '') || !['view', 'edit'].includes(req.adminPerm))
      return res.status(403).json({ error: 'אין הרשאת צפייה בתמונת הסריקה' });
    const id = req.params?.id;
    const size = req.query?.size || 'thumb';
    if (typeof id !== 'string' || !/^[1-9]\d{0,18}$/.test(id) ||
        BigInt(id) > 9223372036854775807n || !['thumb', 'full'].includes(size))
      return res.status(400).json({ error: 'בקשת תמונת הסריקה אינה תקינה' });
    try {
      const pool = await getPool();
      const result = await pool.query(`SELECT p.${size === 'full' ? 'image' : 'thumbnail'} AS bytes
        FROM audit_events e JOIN audit_scan_previews p ON p.id::text=e.details->>'scanPreviewId'
        JOIN stored_files sf ON sf.id=p.stored_file_id
        WHERE e.id=$1 AND e.details->>'storedFileId'=sf.id::text
          AND ((sf.file_type IN ('image','video') AND sf.moderation_status IN ('rejected','stopped')) OR
            (sf.content_purged_at IS NULL AND
              (sf.blocked_content_expires_at IS NULL OR sf.blocked_content_expires_at>clock_timestamp())))`, [id]);
      const bytes = result.rows[0]?.bytes;
      if (!Buffer.isBuffer(bytes))
        return res.status(404).json({ error: 'תמונת הסריקה אינה זמינה' });
      res.set('Content-Type', 'image/jpeg');
      res.set('Content-Disposition', 'inline; filename="scan-preview.jpg"');
      return res.send(bytes);
    } catch (error) {
      console.warn('Scan preview read failed:', error.code || error.name);
      return res.status(503).json({ error: 'תמונת הסריקה אינה זמינה כרגע' });
    }
  });
}

module.exports = { ensureAuditScanPreviewSchema, saveAuditScanPreview,
  purgeExpiredAuditScanPreviews, registerAuditScanPreviewRoutes, attachOperationPreviews };
