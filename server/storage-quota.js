'use strict';
const crypto = require('node:crypto');
const drive = require('./personal-drive');
const { createVaultKey, wrapVaultKey } = require('./backup-vault-key');

const LIMIT = 2000000000;
const PENDING_LIMIT = 512 * 1024 * 1024;
const MESSAGE = 'מכסת האחסון מלאה. אפשר למחוק קבצים ישנים במסך הקבצים או לחבר Google Drive אישי כדי להמשיך.';
const SCHEMA = `
ALTER TABLE cloud_backup_accounts ADD COLUMN IF NOT EXISTS storage_google_account_id TEXT;
ALTER TABLE stored_files ADD COLUMN IF NOT EXISTS storage_tier TEXT NOT NULL DEFAULT 'service'
  CHECK(storage_tier IN ('service','personal'));
ALTER TABLE stored_files ADD COLUMN IF NOT EXISTS quota_reservation UUID;
ALTER TABLE stored_files ADD COLUMN IF NOT EXISTS personal_storage_verified_at TIMESTAMPTZ;
CREATE TABLE IF NOT EXISTS storage_drive_health (
  user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL, ready_until TIMESTAMPTZ NOT NULL,
  free_bytes BIGINT, checked_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS storage_upload_reservations (
  id UUID PRIMARY KEY,user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  bytes BIGINT NOT NULL CHECK(bytes>0),tier TEXT NOT NULL CHECK(tier IN ('service','personal')),
  expires_at TIMESTAMPTZ NOT NULL DEFAULT now()+interval '1 hour'
);
CREATE INDEX IF NOT EXISTS storage_upload_reservations_owner ON storage_upload_reservations(user_id,expires_at);
CREATE OR REPLACE FUNCTION storage_service_bytes(owner UUID) RETURNS BIGINT AS $$
 SELECT COALESCE(sum(size),0)::bigint FROM (
   SELECT max(file_size) AS size FROM stored_files
   WHERE user_id=owner AND storage_tier='service' AND content_purged_at IS NULL
   GROUP BY COALESCE(content_sha256,id::text)
 ) content;
$$ LANGUAGE SQL VOLATILE;
CREATE OR REPLACE FUNCTION storage_choose_tier(owner UUID,bytes BIGINT,content_hash TEXT,reservation UUID)
RETURNS TEXT AS $$
DECLARE used BIGINT; reserved BIGINT; pending BIGINT; free BIGINT; existing TEXT;
BEGIN
 IF owner IS NULL THEN RETURN 'service'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('storage-quota:'||owner::text,0));
 IF bytes<0 THEN RAISE EXCEPTION 'Invalid file size'; END IF;
 SELECT storage_tier INTO existing FROM stored_files
   WHERE user_id=owner AND content_purged_at IS NULL AND content_hash IS NOT NULL
     AND content_sha256=content_hash ORDER BY storage_tier DESC LIMIT 1;
 IF existing='service' AND NOT EXISTS(SELECT 1 FROM cloud_backup_accounts WHERE user_id=owner AND status='connected') THEN RETURN 'service'; END IF;
 used := storage_service_bytes(owner);
 SELECT COALESCE(sum(r.bytes),0) INTO reserved FROM storage_upload_reservations r
   WHERE user_id=owner AND tier='service' AND expires_at>now() AND id IS DISTINCT FROM reservation;
 IF existing IS NULL AND used+reserved+bytes<=${LIMIT}
   AND NOT EXISTS(SELECT 1 FROM cloud_backup_accounts WHERE user_id=owner AND status='connected') THEN RETURN 'service'; END IF;
 SELECT h.free_bytes INTO free FROM storage_drive_health h
   JOIN cloud_backup_accounts c ON c.user_id=h.user_id AND c.status='connected'
   JOIN user_backup_settings s ON s.user_id=h.user_id AND s.encrypted_data_key IS NOT NULL
   WHERE h.user_id=owner AND h.ready_until>now()
     AND h.token_hash=encode(sha256(convert_to(c.encrypted_refresh_token,'UTF8')),'hex');
 IF NOT FOUND THEN RAISE EXCEPTION '${MESSAGE}' USING ERRCODE='P2001'; END IF;
 SELECT COALESCE(sum(file_size),0) INTO pending FROM stored_files
   WHERE user_id=owner AND storage_tier='personal' AND released_at IS NULL AND content_purged_at IS NULL;
 SELECT COALESCE(sum(r.bytes),0) INTO reserved FROM storage_upload_reservations r
   WHERE user_id=owner AND tier='personal' AND expires_at>now() AND id IS DISTINCT FROM reservation;
 -- Allow one large file when the staging queue is empty; serialize further uploads.
 IF pending+reserved>0 AND pending+reserved+bytes>${PENDING_LIMIT} THEN
   RAISE EXCEPTION 'יש להמתין לסיום השמירה ב־Drive או לפנות מקום לפני העלאה נוספת.' USING ERRCODE='P2002';
 END IF;
 IF free IS NOT NULL AND free<pending+reserved+bytes+10485760 THEN
   RAISE EXCEPTION 'אין מספיק מקום ב־Google Drive. אפשר לפנות מקום או למחוק קבצים ישנים מהאפליקציה.' USING ERRCODE='P2003';
 END IF;
 RETURN 'personal';
END; $$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION guard_storage_quota() RETURNS trigger AS $$
BEGIN
 IF NEW.user_id IS NULL THEN RETURN NEW; END IF;
 -- Accounting is enforced for every producer: uploads, received copies and generated documents.
 NEW.storage_tier := storage_choose_tier(NEW.user_id,NEW.file_size,NEW.content_sha256,NEW.quota_reservation);
 IF NEW.quota_reservation IS NOT NULL THEN
   DELETE FROM storage_upload_reservations WHERE id=NEW.quota_reservation AND user_id=NEW.user_id;
 END IF;
 RETURN NEW;
END; $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS stored_files_storage_quota ON stored_files;
CREATE TRIGGER stored_files_storage_quota BEFORE INSERT ON stored_files
  FOR EACH ROW EXECUTE FUNCTION guard_storage_quota();
`;

function quotaError(error) {
  if (/^P200[123]$/.test(error?.code || '')) {
    error.status = 409;
    error.quotaCode = error.code === 'P2001' ? 'STORAGE_QUOTA_EXCEEDED'
      : error.code === 'P2002' ? 'DRIVE_TRANSFER_PENDING' : 'DRIVE_STORAGE_FULL';
  }
  return error;
}

async function verifyDrive(pool, userId, provider = drive) {
  const row = (await pool.query(`SELECT encrypted_refresh_token,storage_google_account_id FROM cloud_backup_accounts
    WHERE user_id=$1 AND status='connected'`, [userId])).rows[0];
  if (!row) throw quotaError(Object.assign(new Error(MESSAGE), { code: 'P2001' }));
  const tokenHash = crypto.createHash('sha256').update(row.encrypted_refresh_token).digest('hex');
  const cached = (await pool.query(`SELECT 1 FROM storage_drive_health
    WHERE user_id=$1 AND token_hash=$2 AND ready_until>now()+interval '1 minute'`, [userId, tokenHash])).rows[0];
  if (cached) return;
  let probeId;
  try {
    const token = provider.decryptRefreshToken(row.encrypted_refresh_token, userId);
    const identity = await provider.getAccountIdentity(token);
    if (row.storage_google_account_id && row.storage_google_account_id !== identity)
      throw new Error('Different Google storage account');
    const quota = await provider.getStorageQuota(token);
    if (quota.freeBytes !== null && BigInt(quota.freeBytes) < 10485760n)
      throw quotaError(Object.assign(new Error('אין מספיק מקום ב־Google Drive. יש לפנות מקום בחשבון.'), { code: 'P2003' }));
    const probe = crypto.randomBytes(32);
    try {
      const uploaded = await provider.uploadAppDataFile(token, `storage-check-${crypto.randomUUID()}.bin`,
        probe, 'application/octet-stream', { kind: 'storage-check' });
      probeId = uploaded.id;
      const restored = await provider.downloadAppDataFile(token, probeId, 1024);
      if (!restored.equals(probe)) throw new Error('Drive check mismatch');
    } finally {
      if (probeId) await provider.deleteAppDataFile(token, probeId);
    }
    await pool.query(`INSERT INTO user_backup_settings(user_id,provider,encrypted_data_key,data_key_version)
      VALUES($1,'google_drive',$2,1) ON CONFLICT(user_id) DO UPDATE
      SET encrypted_data_key=COALESCE(user_backup_settings.encrypted_data_key,$2),
          data_key_version=COALESCE(user_backup_settings.data_key_version,1)`,
    [userId, wrapVaultKey(createVaultKey(), userId)]);
    await pool.query(`INSERT INTO storage_drive_health(user_id,token_hash,ready_until,free_bytes)
      VALUES($1,$2,now()+interval '10 minutes',$3) ON CONFLICT(user_id) DO UPDATE
      SET token_hash=$2,ready_until=EXCLUDED.ready_until,free_bytes=$3,checked_at=now()`,
    [userId, tokenHash, quota.freeBytes]);
    await pool.query('UPDATE cloud_backup_accounts SET storage_google_account_id=$2 WHERE user_id=$1', [userId, identity]);
  } catch (error) {
    await pool.query('DELETE FROM storage_drive_health WHERE user_id=$1', [userId]);
    if (error.quotaCode) throw error;
    throw Object.assign(new Error('לא ניתן לשמור כרגע ב־Drive. חברו אותו מחדש או מחקו קבצים ישנים כדי לפנות מקום.'),
      { status: 409, code: 'DRIVE_RECONNECT_REQUIRED' });
  }
}

async function reserve(pool, userId, id, bytes, hash = null) {
  if (!Number.isSafeInteger(bytes) || bytes < 1) throw Object.assign(new Error('גודל קובץ אינו תקין'), { status: 400 });
  // A failed health check must never block a file that still fits in the service allowance.
  const save = async () => {
    const db = await pool.connect();
    try {
      await db.query('BEGIN');
      const owned = (await db.query('SELECT user_id FROM storage_upload_reservations WHERE id=$1', [id])).rows[0];
      if (owned && owned.user_id !== userId) throw Object.assign(new Error('מזהה העלאה אינו זמין'), { status: 409 });
      const tier = (await db.query('SELECT storage_choose_tier($1,$2,$3,$4) AS tier', [userId, bytes, hash, id])).rows[0].tier;
      const saved = await db.query(`INSERT INTO storage_upload_reservations(id,user_id,bytes,tier)
        VALUES($1,$2,$3,$4) ON CONFLICT(id) DO UPDATE SET bytes=$3,tier=$4,expires_at=now()+interval '1 hour'
        WHERE storage_upload_reservations.user_id=EXCLUDED.user_id RETURNING id`,
      [id, userId, bytes, tier]);
      if (!saved.rowCount) throw Object.assign(new Error('מזהה העלאה אינו זמין'), { status: 409 });
      await db.query('COMMIT');
      return tier;
    } catch (error) { await db.query('ROLLBACK'); throw quotaError(error); }
    finally { db.release(); }
  };
  try { return await save(); }
  catch (error) {
    if (error.code !== 'P2001') throw error;
    await verifyDrive(pool, userId);
    return save();
  }
}

async function release(pool, userId, id) {
  if (id) await pool.query('DELETE FROM storage_upload_reservations WHERE id=$1 AND user_id=$2', [id, userId]);
}

async function status(pool, userId) {
  const row = (await pool.query(`SELECT storage_service_bytes($1)::text AS used,
    (SELECT COALESCE(sum(bytes),0)::text FROM storage_upload_reservations WHERE user_id=$1 AND tier='service' AND expires_at>now()) AS reserved,
    (SELECT COALESCE(sum(file_size),0)::text FROM stored_files WHERE user_id=$1 AND storage_tier='personal' AND content_purged_at IS NULL) AS personal,
    (SELECT count(*)::int FROM stored_files WHERE user_id=$1 AND storage_tier='personal'
      AND (personal_storage_verified_at IS NULL OR released_at IS NULL) AND content_purged_at IS NULL) AS pending,
    (SELECT count(*)::int FROM stored_files sf JOIN media_backup_items m ON m.stored_file_id=sf.id
      WHERE sf.user_id=$1 AND sf.storage_tier='personal' AND sf.content_purged_at IS NULL AND m.status='failed') AS failed,
    EXISTS(SELECT 1 FROM cloud_backup_accounts WHERE user_id=$1 AND status='connected') AS connected`, [userId])).rows[0];
  const occupied = Number(row.used) + Number(row.reserved);
  return { limitBytes: LIMIT, usedBytes: Number(row.used), reservedBytes: Number(row.reserved),
    freeBytes: Math.max(0, LIMIT - Number(row.used) - Number(row.reserved)),
    warning: Number(row.used) + Number(row.reserved) >= LIMIT * .8,
    warningLevel: occupied >= LIMIT ? 100 : occupied >= LIMIT * .95 ? 95 : occupied >= LIMIT * .9 ? 90 : occupied >= LIMIT * .8 ? 80 : 0,
    personalBytes: Number(row.personal), pendingPersonalFiles: row.pending, failedPersonalFiles: row.failed, driveConnected: row.connected };
}
async function queueUserMigration(pool, userId) {
  await pool.query(`UPDATE stored_files sf SET storage_tier='personal'
    WHERE sf.user_id=$1 AND sf.storage_tier='service' AND sf.moderation_status='approved'
      AND sf.content_purged_at IS NULL AND sf.moderation_details->>'pending' IS DISTINCT FROM 'true'
      AND NOT EXISTS(SELECT 1 FROM pending_scans ps WHERE ps.file_url=sf.public_url)
      AND NOT EXISTS(SELECT 1 FROM deleted_media_sources ds WHERE ds.storage_path=sf.storage_path)
      AND EXISTS(SELECT 1 FROM storage_drive_health h
        JOIN cloud_backup_accounts c ON c.user_id=h.user_id AND c.status='connected'
        WHERE h.user_id=$1 AND h.ready_until>now()
          AND h.token_hash=encode(sha256(convert_to(c.encrypted_refresh_token,'UTF8')),'hex'))`, [userId]);
}

function createMaintenance({ getPool, verifyBytes = require('./local-media-release').verifiedCloudBytes,
  verifyAccount = verifyDrive, lockKey = 8640317 }) {
  let running = false;
  return async function tick() {
    if (running) return;
    running = true;
    try {
      const pool = await getPool();
      await pool.query('DELETE FROM storage_upload_reservations WHERE expires_at<now()');
      const accounts = (await pool.query("SELECT user_id FROM cloud_backup_accounts WHERE status='connected'")).rows;
      for (const account of accounts) {
        try { await verifyAccount(pool, account.user_id); await queueUserMigration(pool, account.user_id); }
        catch { /* Keep service copies and retry when this account becomes available. */ }
      }
      const candidates = (await pool.query(`SELECT sf.id FROM stored_files sf
        JOIN media_backup_items m ON m.stored_file_id=sf.id AND m.user_id=sf.user_id
        WHERE sf.storage_tier='personal' AND sf.personal_storage_verified_at IS NULL
          AND sf.content_purged_at IS NULL AND sf.moderation_status='approved'
          AND m.status='verified' AND m.encryption_metadata->>'keySource'='server_vault'
        ORDER BY sf.created_at LIMIT 20`)).rows;
      for (const candidate of candidates) {
        const db = await pool.connect();
        try {
          await db.query('BEGIN');
          if (!(await db.query('SELECT pg_try_advisory_xact_lock($1) AS locked', [lockKey])).rows[0].locked) {
            await db.query('ROLLBACK'); break;
          }
          const row = (await db.query(`SELECT sf.id,sf.user_id,sf.file_size,sf.content_sha256,
            m.remote_file_id,m.encrypted_sha256,m.plaintext_sha256,m.encryption_metadata,
            s.encrypted_data_key,c.encrypted_refresh_token
            FROM stored_files sf JOIN media_backup_items m ON m.stored_file_id=sf.id AND m.user_id=sf.user_id
            JOIN user_backup_settings s ON s.user_id=sf.user_id
            JOIN cloud_backup_accounts c ON c.user_id=sf.user_id AND c.status='connected'
            WHERE sf.id=$1 AND sf.storage_tier='personal' AND sf.personal_storage_verified_at IS NULL
              AND sf.moderation_status='approved' AND sf.content_purged_at IS NULL AND m.status='verified'
              AND m.plaintext_sha256=sf.content_sha256 AND m.encryption_metadata->>'keySource'='server_vault'
            FOR UPDATE OF sf,m`, [candidate.id])).rows[0];
          if (row) {
            // A fresh download, decryption and hash check is mandatory, including for old backups.
            await verifyBytes(row);
            await db.query(`UPDATE stored_files SET personal_storage_verified_at=now(),
              release_scheduled_at=COALESCE(release_scheduled_at,now()) WHERE id=$1`, [row.id]);
            await db.query(`UPDATE central_drive_objects SET status='delete_pending',next_attempt_at=now()
              WHERE file_id=$1`, [row.id]);
          }
          await db.query('COMMIT');
        } catch {
          await db.query('ROLLBACK').catch(() => {});
          // Preserve the central copy. Queue a fresh personal backup from that source.
          await pool.query(`UPDATE media_backup_items m SET status='queued',attempt_count=0,updated_at=now()
            WHERE m.stored_file_id=$1 AND m.status='verified' AND EXISTS(
              SELECT 1 FROM central_drive_objects o WHERE o.file_id=$1 AND o.status='verified')`, [candidate.id]);
        } finally { db.release(); }
      }
    } finally { running = false; }
  };
}
module.exports = { SCHEMA, LIMIT, reserve, release, verifyDrive, status, quotaError, queueUserMigration, createMaintenance };
