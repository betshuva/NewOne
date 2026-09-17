'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const path = require('node:path');
const personalDrive = require('./personal-drive');
const { decryptBuffer } = require('./media-backup-crypto');
const { unwrapVaultKey } = require('./backup-vault-key');
const { messageAfterConversationClear } = require('./conversation-history');

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const HUMAN_USER = `NOT IN ('00000000-0000-4000-8000-000000000001',
  '00000000-0000-4000-8000-000000000002','00000000-0000-4000-8000-000000000003')`;

function visibleMessage(alias, user) {
  return `${alias}.deleted_for_everyone=FALSE
    AND NOT (${alias}.sender_id=${user} AND COALESCE(${alias}.deleted_for_sender,FALSE))
    AND NOT EXISTS (SELECT 1 FROM message_user_deletions d
      WHERE d.message_id=${alias}.id AND d.user_id=${user})
    AND ${messageAfterConversationClear(alias, user)}
    AND ((${alias}.group_id IS NULL AND ${alias}.recipient_id=${user}) OR
      (${alias}.group_id IS NOT NULL AND ${alias}.sender_id<>${user} AND EXISTS (
        SELECT 1 FROM group_members gm WHERE gm.group_id=${alias}.group_id
          AND gm.user_id=${user} AND gm.status='member' AND ${alias}.created_at>=gm.joined_at)))`;
}

const RECEIVED_MEDIA_SCHEMA = `
CREATE TABLE IF NOT EXISTS deleted_media_sources (
  public_url TEXT PRIMARY KEY,owner_id UUID NOT NULL,storage_path TEXT,deleted_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE conversation_user_state ADD COLUMN IF NOT EXISTS media_deleted_at TIMESTAMPTZ;
CREATE TABLE IF NOT EXISTS personal_media_content (
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  content_sha256 TEXT NOT NULL CHECK (content_sha256 ~ '^[0-9a-f]{64}$'),
  stored_file_id UUID NOT NULL REFERENCES stored_files(id) ON DELETE CASCADE,
  PRIMARY KEY(user_id,content_sha256)
);
CREATE INDEX IF NOT EXISTS personal_media_content_file_idx ON personal_media_content(stored_file_id);
CREATE TABLE IF NOT EXISTS received_message_media (
  message_id UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  source_file_id UUID REFERENCES stored_files(id) ON DELETE SET NULL,
  stored_file_id UUID REFERENCES stored_files(id) ON DELETE SET NULL,
  status TEXT NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','ready','skipped')),
  attempt_count INTEGER NOT NULL DEFAULT 0,
  next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_error TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY(message_id,user_id)
);
CREATE INDEX IF NOT EXISTS received_message_media_queue_idx
  ON received_message_media(next_attempt_at,created_at) WHERE status='queued';
CREATE INDEX IF NOT EXISTS received_message_media_file_idx ON received_message_media(stored_file_id);
CREATE INDEX IF NOT EXISTS received_message_media_source_idx ON received_message_media(source_file_id);
CREATE INDEX IF NOT EXISTS stored_files_owner_hash_idx
  ON stored_files(user_id,content_sha256) WHERE content_sha256 IS NOT NULL;
CREATE OR REPLACE FUNCTION enqueue_received_message_media() RETURNS trigger AS $$
DECLARE source_id UUID;
BEGIN
  IF NEW.file_url IS NULL OR NEW.deleted_for_everyone=TRUE THEN RETURN NEW; END IF;
  SELECT id INTO source_id FROM stored_files WHERE public_url=NEW.file_url
    AND moderation_status='approved' AND content_purged_at IS NULL;
  IF source_id IS NULL THEN RETURN NEW; END IF;
  IF NEW.group_id IS NULL THEN
    INSERT INTO received_message_media(message_id,user_id,source_file_id)
      SELECT NEW.id,NEW.recipient_id,source_id
      WHERE NEW.recipient_id ${HUMAN_USER}
      ON CONFLICT DO NOTHING;
  ELSIF jsonb_typeof(NEW.delivery_summary->'deliveredTo')='array' THEN
    INSERT INTO received_message_media(message_id,user_id,source_file_id)
      SELECT NEW.id,gm.user_id,source_id FROM group_members gm
      WHERE gm.group_id=NEW.group_id AND gm.status='member'
        AND gm.user_id<>NEW.sender_id AND gm.user_id ${HUMAN_USER}
        AND EXISTS (SELECT 1 FROM jsonb_array_elements(NEW.delivery_summary->'deliveredTo') r
          WHERE r->>'id'=gm.user_id::text)
      ON CONFLICT DO NOTHING;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS messages_retain_received_media ON messages;
CREATE TRIGGER messages_retain_received_media
  AFTER INSERT OR UPDATE OF file_url,delivery_summary ON messages
  FOR EACH ROW EXECUTE FUNCTION enqueue_received_message_media();
CREATE OR REPLACE FUNCTION reject_received_media_copies() RETURNS trigger AS $$
BEGIN
  IF pg_trigger_depth()>1 THEN RETURN NEW; END IF;
  IF NEW.moderation_status='rejected' AND NEW.content_sha256 IS NOT NULL
    AND COALESCE((NEW.moderation_details->>'destinationFilterRejected')::boolean,FALSE)=FALSE THEN
    UPDATE stored_files SET moderation_status='rejected',moderation_details=NEW.moderation_details,
      blocked_content_expires_at=NEW.blocked_content_expires_at
      WHERE context_type='received' AND content_sha256=NEW.content_sha256
        AND moderation_status<>'rejected';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS stored_files_reject_received_copies ON stored_files;
CREATE TRIGGER stored_files_reject_received_copies AFTER UPDATE OF moderation_status ON stored_files
  FOR EACH ROW WHEN (NEW.moderation_status='rejected' AND OLD.moderation_status IS DISTINCT FROM NEW.moderation_status)
  EXECUTE FUNCTION reject_received_media_copies();
`;

// Existing delivered history is imported once. Later history reads may enqueue
// newly visible group messages after the caller applies the recipient's filter.
// A retained mapping is never reset, including after its owner deletes a copy.
async function migrateReceivedMedia(pool) {
  const db = await pool.connect();
  try {
    await db.query('BEGIN');
    await db.query(RECEIVED_MEDIA_SCHEMA);
    const marker = await db.query(`INSERT INTO app_settings(key_name,value)
      VALUES('received_media_backfill_v1','true') ON CONFLICT DO NOTHING RETURNING key_name`);
    if (marker.rows.length) {
      await db.query(`INSERT INTO received_message_media(message_id,user_id,source_file_id)
        SELECT m.id,recipient.user_id,sf.id FROM messages m
        JOIN stored_files sf ON sf.public_url=m.file_url
          AND sf.moderation_status='approved' AND sf.content_purged_at IS NULL
        CROSS JOIN LATERAL (
          SELECT m.recipient_id AS user_id WHERE m.group_id IS NULL
          UNION
          SELECT gm.user_id FROM group_members gm WHERE gm.group_id=m.group_id
            AND gm.status='member' AND gm.user_id<>m.sender_id
            AND EXISTS (SELECT 1 FROM jsonb_array_elements(
              CASE WHEN jsonb_typeof(m.delivery_summary->'deliveredTo')='array'
                THEN m.delivery_summary->'deliveredTo' ELSE '[]'::jsonb END) r
              WHERE r->>'id'=gm.user_id::text)
        ) recipient
        WHERE recipient.user_id ${HUMAN_USER} AND ${visibleMessage('m', 'recipient.user_id')}
        ON CONFLICT DO NOTHING`);
    }
    await db.query('COMMIT');
  } catch (error) {
    await db.query('ROLLBACK').catch(() => {});
    throw error;
  } finally { db.release(); }
}

async function retainVisibleReceivedMessages(db, userId, rows) {
  const ids = rows.map(row => row.id).filter(id => UUID.test(String(id)));
  if (!ids.length || !UUID.test(String(userId))) return;
  await db.query(`WITH readable_sources AS MATERIALIZED (
    SELECT m.id AS message_id,sf.id AS source_file_id FROM messages m
    JOIN stored_files sf ON sf.public_url=m.file_url
    WHERE m.id=ANY($2::uuid[]) AND $1::uuid ${HUMAN_USER}
      AND sf.moderation_status='approved' AND sf.content_purged_at IS NULL
      AND ${visibleMessage('m', '$1')}
    ORDER BY sf.id FOR SHARE OF sf
    ) INSERT INTO received_message_media(message_id,user_id,source_file_id)
    SELECT message_id,$1,source_file_id FROM readable_sources
    ON CONFLICT DO NOTHING`, [userId, ids]);
}

async function personalizeReceivedMessages(db, userId, rows) {
  const ids = rows.map(row => row.id).filter(id => UUID.test(String(id)));
  if (!ids.length || !UUID.test(String(userId))) return rows;
  const result = await db.query(`SELECT r.message_id,r.source_file_id,sf.id,sf.public_url,sf.file_size
    FROM received_message_media r JOIN stored_files sf ON sf.id=r.stored_file_id
    WHERE r.user_id=$1 AND sf.user_id=$1 AND r.message_id=ANY($2::uuid[])
      AND r.status='ready'`, [userId, ids]);
  const saved = new Map(result.rows.map(row => [row.message_id, row]));
  const removed = await db.query(`SELECT m.id FROM messages m
    LEFT JOIN received_message_media r ON r.message_id=m.id AND r.user_id=$1
    WHERE m.id=ANY($2::uuid[]) AND (
      (r.status='skipped' AND r.last_error IN ('owner_deleted','source_deleted'))
      OR EXISTS (SELECT 1 FROM deleted_media_sources d WHERE d.public_url=m.file_url))`, [userId, ids]);
  const deleted = new Set(removed.rows.map(row => row.id));
  return rows.map(row => {
    const copy = saved.get(row.id);
    if (!copy && deleted.has(row.id)) return { ...row,
      file_url: null, fileUrl: null, file_deleted: true,
      filter_hidden: false, hidden_reason: null };
    if (!copy || !(row.file_url || row.fileUrl)) return row;
    const textFields = {};
    if (copy.source_file_id && copy.public_url.startsWith('/betshuva-app/api/guide-files/')) {
      for (const key of ['body', 'text']) if (typeof row[key] === 'string')
        textFields[key] = row[key].replaceAll(`betshuva://app/guide-file/${copy.source_file_id}`,
          `betshuva://app/guide-file/${copy.id}`);
    }
    return { ...row, ...('file_url' in row ? { file_url: copy.public_url } : {}),
      ...('fileUrl' in row ? { fileUrl: copy.public_url } : {}), ...textFields };
  });
}

function checkedPath(uploadRoot, storagePath) {
  const root = path.resolve(uploadRoot);
  const absolute = path.resolve(root, storagePath);
  if (!absolute.startsWith(root + path.sep)) throw new Error('Invalid received media path');
  return absolute;
}

async function readSourceMedia(db, uploadRoot, file) {
  const absolute = checkedPath(uploadRoot, file.storage_path);
  try {
    const real = await fs.realpath(absolute);
    if (!real.startsWith(await fs.realpath(uploadRoot) + path.sep))
      throw new Error('Invalid received media symlink');
    return await fs.readFile(real);
  } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const result = await db.query(`SELECT mbi.remote_file_id,mbi.encrypted_sha256,mbi.plaintext_sha256,
      mbi.encryption_metadata,s.encrypted_data_key,c.encrypted_refresh_token
    FROM media_backup_items mbi
    JOIN user_backup_settings s ON s.user_id=mbi.user_id
    JOIN cloud_backup_accounts c ON c.user_id=mbi.user_id AND c.status='connected'
    WHERE mbi.stored_file_id=$1 AND mbi.user_id=$2 AND mbi.provider='google_drive'
      AND mbi.status='verified'`, [file.id, file.user_id]);
  const backup = result.rows[0];
  if (!backup?.encrypted_data_key) throw new Error('Source media is temporarily unavailable');
  const token = personalDrive.decryptRefreshToken(backup.encrypted_refresh_token, file.user_id);
  const encrypted = await personalDrive.downloadAppDataFile(token, backup.remote_file_id,
    Number(file.file_size) + 1024);
  if (crypto.createHash('sha256').update(encrypted).digest('hex') !== backup.encrypted_sha256)
    throw new Error('Received media backup checksum mismatch');
  const metadata = typeof backup.encryption_metadata === 'string'
    ? JSON.parse(backup.encryption_metadata) : backup.encryption_metadata;
  const plain = decryptBuffer({ version: 1, algorithm: metadata.algorithm,
    nonce: metadata.nonce, tag: metadata.tag, ciphertext: encrypted },
  unwrapVaultKey(backup.encrypted_data_key, file.user_id), metadata.associatedData);
  if (crypto.createHash('sha256').update(plain).digest('hex') !== backup.plaintext_sha256)
    throw new Error('Restored received media checksum mismatch');
  return plain;
}

function createReceivedMediaService({ getPool, uploadRoot, publicBase = '/betshuva-app/uploads',
    readSourceBytes = readSourceMedia }) {
  let running = false;
  async function retainNext(pool) {
    const db = await pool.connect();
    let job;
    let createdPath;
    try {
      await db.query('BEGIN');
      const jobs = await db.query(`SELECT r.* FROM received_message_media r
        WHERE r.status='queued' AND r.next_attempt_at<=now()
        ORDER BY r.created_at LIMIT 1 FOR UPDATE OF r SKIP LOCKED`);
      job = jobs.rows[0];
      if (!job) { await db.query('ROLLBACK'); return false; }
      const ownerLock = await db.query('SELECT pg_try_advisory_xact_lock(hashtextextended($1,0)) AS locked',
        [`personal-media-owner:${job.user_id}`]);
      if (!ownerLock.rows[0].locked) { await db.query('ROLLBACK'); return false; }
      const deleted = await db.query(`SELECT 1 FROM messages m
        JOIN conversation_user_state cs ON cs.user_id=$2
          AND cs.kind=CASE WHEN m.group_id IS NULL THEN 'chat' ELSE 'group' END
          AND cs.target_id=COALESCE(m.group_id,
            CASE WHEN m.sender_id=$2 THEN m.recipient_id ELSE m.sender_id END)
        WHERE m.id=$1 AND m.created_at<=cs.media_deleted_at`, [job.message_id, job.user_id]);
      const sources = await db.query(`SELECT sf.* FROM stored_files sf WHERE sf.id=$1
        AND sf.moderation_status='approved' AND sf.content_purged_at IS NULL
        FOR SHARE OF sf`, [job.source_file_id]);
      const source = sources.rows[0];
      // Queue entries record an authorized delivery. A normal history clear or
      // leaving a group must retain the received file; explicit media deletion
      // cancels queued entries under the same owner lock.
      if (deleted.rows.length || !source) {
        await db.query(`UPDATE received_message_media SET status='skipped',last_error=NULL
          WHERE message_id=$1 AND user_id=$2`, [job.message_id, job.user_id]);
        await db.query('COMMIT');
        return true;
      }
      let bytes;
      let hash = /^[0-9a-f]{64}$/.test(source.content_sha256 || '') ? source.content_sha256 : null;
      if (!hash) {
        bytes = await readSourceBytes(db, uploadRoot, source);
        hash = crypto.createHash('sha256').update(bytes).digest('hex');
      }
      // Exact bytes identify the content, never its sender, URL or filename.
      // Serialize all copies of this user's content across concurrent workers.
      await db.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))',
        [`received-media:${job.user_id}:${hash}`]);
      const existing = await db.query(`SELECT sf.* FROM stored_files sf
        LEFT JOIN personal_media_content p ON p.stored_file_id=sf.id
          AND p.user_id=$1 AND p.content_sha256=$2
        WHERE sf.user_id=$1 AND (sf.content_sha256=$2 OR p.stored_file_id IS NOT NULL)
          AND sf.moderation_status='approved'
          AND sf.content_purged_at IS NULL
        ORDER BY (p.stored_file_id IS NOT NULL) DESC,sf.created_at,sf.id LIMIT 1
        FOR SHARE OF sf`, [job.user_id, hash]);
      let owned = existing.rows[0] || (source.user_id === job.user_id ? source : null);
      if (!owned) {
        bytes ||= await readSourceBytes(db, uploadRoot, source);
        if (crypto.createHash('sha256').update(bytes).digest('hex') !== hash)
          throw new Error('Received media checksum mismatch');
        const id = crypto.randomUUID();
        const privateGuide = /^\.guide-files\/[0-9a-f-]+\.xlsx$/i.test(source.storage_path);
        const extension = path.extname(source.storage_path).match(/^\.[a-z0-9]{1,10}$/i)?.[0] || '.bin';
        const storagePath = privateGuide ? `.guide-files/${id}.xlsx`
          : `received/${job.user_id}/${id}${extension}`;
        const url = privateGuide ? `/betshuva-app/api/guide-files/${id}/download`
          : `${publicBase}/${storagePath}`;
        createdPath = checkedPath(uploadRoot, storagePath);
        await fs.mkdir(path.dirname(createdPath), { recursive: true });
        await fs.writeFile(createdPath, bytes, { flag: 'wx', mode: 0o600 });
        const inserted = await db.query(`INSERT INTO stored_files
          (id,user_id,original_name,storage_path,public_url,mime_type,file_type,file_size,
           context_type,moderation_status,moderation_details,content_sha256,visual_fingerprint)
          VALUES($1,$2,$3,$4,$5,$6,$7,$8,'received','approved',$9,$10,$11) RETURNING *`,
        [id, job.user_id, source.original_name, storagePath, url, source.mime_type,
          source.file_type, bytes.length, JSON.stringify(source.moderation_details || {}), hash,
          source.visual_fingerprint ? JSON.stringify(source.visual_fingerprint) : null]);
        owned = inserted.rows[0];
      }
      await db.query(`INSERT INTO personal_media_content(user_id,content_sha256,stored_file_id)
        VALUES($1,$2,$3) ON CONFLICT(user_id,content_sha256)
        DO UPDATE SET stored_file_id=EXCLUDED.stored_file_id`, [job.user_id, hash, owned.id]);
      await db.query(`UPDATE received_message_media SET stored_file_id=$3,status='ready',last_error=NULL
        WHERE message_id=$1 AND user_id=$2`, [job.message_id, job.user_id, owned.id]);
      await db.query('COMMIT');
      createdPath = null;
      // Backfill server-generated hashes without upgrading the source SHARE
      // lock while a second recipient may be retaining the same legacy file.
      if (!source.content_sha256) await db.query(`UPDATE stored_files SET content_sha256=$2
        WHERE id=$1 AND content_sha256 IS NULL`, [source.id, hash]).catch(() => {});
      return true;
    } catch (error) {
      await db.query('ROLLBACK').catch(() => {});
      if (createdPath) await fs.unlink(createdPath).catch(() => {});
      if (!job) throw error;
      // Persistent retry state survives restarts and never blocks another file.
      await db.query(`UPDATE received_message_media SET attempt_count=attempt_count+1,
        next_attempt_at=now()+LEAST(3600,30*power(2,LEAST(attempt_count,7))) * interval '1 second',
        last_error=$3 WHERE message_id=$1 AND user_id=$2 AND status='queued'`,
      [job.message_id, job.user_id, String(error.message).slice(0, 300)]);
      return true;
    } finally { db.release(); }
  }
  return {
    async runOnce() {
      if (running) return 0;
      running = true;
      let count = 0;
      try {
        const pool = await getPool();
        while (count < 8 && await retainNext(pool)) count++;
        return count;
      } finally { running = false; }
    },
    personalizeMessages: personalizeReceivedMessages,
  };
}

module.exports = { RECEIVED_MEDIA_SCHEMA, migrateReceivedMedia, createReceivedMediaService,
  retainVisibleReceivedMessages, personalizeReceivedMessages, readSourceMedia };
