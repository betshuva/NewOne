'use strict';

const { randomUUID } = require('node:crypto');

// Evidence lives as long as the cached decision, even if its original upload
// was deleted. Account deletion and explicit scan-cache reset remove it.
const SCHEMA = `CREATE TABLE IF NOT EXISTS cached_scan_previews (
  scan_id uuid NOT NULL REFERENCES video_scan_budgets(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  frame_index integer NOT NULL CHECK(frame_index BETWEEN 0 AND 19),
  content_sha256 text NOT NULL,
  thumbnail bytea NOT NULL CHECK(octet_length(thumbnail) BETWEEN 1 AND 24576),
  image bytea NOT NULL CHECK(octet_length(image) BETWEEN 1 AND 524288),
  width integer NOT NULL, height integer NOT NULL,
  PRIMARY KEY(scan_id,frame_index)
);`;

async function retainScanPreview(pool, previewId, context) {
  if (!context?.scanId || !Number.isInteger(context.frameIndex)) return;
  await pool.query(`INSERT INTO cached_scan_previews
    (scan_id,user_id,frame_index,content_sha256,thumbnail,image,width,height)
    SELECT b.id,sf.user_id,$3::integer,p.content_sha256,p.thumbnail,p.image,p.width,p.height
    FROM audit_scan_previews p JOIN stored_files sf ON sf.id=p.stored_file_id
    JOIN video_scan_budgets b ON b.id=$2 AND b.user_id=sf.user_id::text
      AND b.content_sha256=sf.content_sha256
    WHERE p.id=$1 AND b.manifest->($3::integer)->>'sha256'=p.content_sha256
    ON CONFLICT(scan_id,frame_index) DO NOTHING`, [previewId,context.scanId,context.frameIndex]);
}

async function attachCachedScanPreview(pool, state, tracking, record) {
  const frames = state.result?.frameResults;
  if (!Array.isArray(frames)) return;
  const index = frames.findIndex(frame => frame &&
    (state.result.blocked ? frame.blocked : frame.pending || frame.scanStopped));
  if (index < 0) return;
  const frame = frames[index], sample = state.budget?.manifest?.[index];
  if (!sample || Math.round(sample.timeSeconds * 1000) !== Math.round(frame.timestampSeconds * 1000)) return;
  const saved = await pool.query(`INSERT INTO audit_scan_previews
    (id,stored_file_id,content_sha256,thumbnail,image,width,height)
    SELECT $1,sf.id,p.content_sha256,p.thumbnail,p.image,p.width,p.height
    FROM cached_scan_previews p JOIN video_scan_budgets b ON b.id=p.scan_id
    JOIN stored_files sf ON sf.id=$2 AND sf.user_id=p.user_id
      AND sf.content_sha256=b.content_sha256 AND sf.content_purged_at IS NULL
    WHERE p.scan_id=$3 AND p.user_id=$4 AND p.frame_index=$5 AND p.content_sha256=$6
      AND b.manifest->($5::integer)->>'sha256'=p.content_sha256
    ON CONFLICT(stored_file_id,content_sha256) DO UPDATE SET content_sha256=EXCLUDED.content_sha256
    RETURNING id`, [randomUUID(),tracking.storedFileId,state.id,tracking.userId,index,sample.sha256]);
  const id = saved.rows[0]?.id;
  if (!id) return;
  await record({ provider:'cache', operation:'video_frames', cacheHit:true,
    tracking:{ ...tracking, scanPreviewId:id,
      videoBudget:{ frameIndex:index,timestampSeconds:frame.timestampSeconds } }, result:frame });
}

module.exports = { SCHEMA, retainScanPreview, attachCachedScanPreview };
