'use strict';

const crypto = require('node:crypto');
const personalDrive = require('./personal-drive');
const { unwrapVaultKey } = require('./backup-vault-key');
const { decryptBuffer } = require('./media-backup-crypto');

const SCHEMA = `
ALTER TABLE media_backup_items
  ADD COLUMN IF NOT EXISTS restore_attempt_count INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS restore_next_attempt_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS restore_last_error TEXT;
CREATE INDEX IF NOT EXISTS media_backup_items_restore_retry_idx
  ON media_backup_items(restore_next_attempt_at,verified_at)
  WHERE status='verified' AND restore_verified_at IS NULL;
`;

const SELECT_NEXT_SQL = `
SELECT mbi.id,mbi.user_id,mbi.stored_file_id,mbi.remote_file_id,
       mbi.plaintext_sha256,mbi.encrypted_sha256,mbi.encryption_metadata,
       sf.file_size,sf.content_sha256,s.encrypted_data_key,c.encrypted_refresh_token
FROM media_backup_items mbi
JOIN stored_files sf ON sf.id=mbi.stored_file_id AND sf.user_id=mbi.user_id
JOIN user_backup_settings s ON s.user_id=mbi.user_id
  AND (s.enabled=TRUE OR mbi.encryption_metadata->>'guideRequested'='true' OR sf.storage_tier='personal')
JOIN cloud_backup_accounts c ON c.user_id=mbi.user_id
  AND c.provider='google_drive' AND c.status='connected'
WHERE mbi.provider='google_drive' AND mbi.status='verified' AND mbi.restore_verified_at IS NULL
  AND mbi.encryption_metadata->>'keySource'='server_vault'
  AND sf.content_purged_at IS NULL AND sf.released_at IS NULL
  AND (mbi.restore_next_attempt_at IS NULL OR mbi.restore_next_attempt_at<=now())
ORDER BY COALESCE(mbi.restore_next_attempt_at,mbi.verified_at) ASC,mbi.id ASC LIMIT 1`;

function errorCode(error) {
  return ['TimeoutError', 'AbortError'].includes(error?.name) ||
    error?.code === 'ETIMEDOUT' || /timeout|timed out/i.test(error?.message || '')
    ? 'RESTORE_TIMEOUT' : 'RESTORE_VERIFICATION_FAILED';
}

function createVerificationLock() {
  let pending = Promise.resolve();
  return function withVerification(task) {
    const result = pending.then(task);
    pending = result.catch(() => {});
    return result;
  };
}

function createAutomaticRestoreQueue({ getPool, drive = personalDrive,
  withVerification = task => task(),
  releaseVerified = async () => {}, onVerified = async () => {}, onError = () => {} }) {
  let running = false;
  return async function tick() {
    if (running) return { skipped: true };
    running = true;
    let pool, row, verified = false;
    try {
      await withVerification(async () => {
        pool = await getPool();
        row = (await pool.query(SELECT_NEXT_SQL)).rows[0];
        if (!row) return { skipped: true };
        const metadata = row.encryption_metadata;
        const refreshToken = drive.decryptRefreshToken(row.encrypted_refresh_token, row.user_id);
        const downloads = await Promise.allSettled([
          drive.downloadAppDataFile(refreshToken, row.remote_file_id, Number(row.file_size) + 1024),
          drive.downloadAppDataFile(refreshToken, metadata.manifestRemoteId, 1024 * 1024),
        ]);
        const failedDownload = downloads.find(result => result.status === 'rejected');
        if (failedDownload) throw failedDownload.reason;
        const [encrypted, manifestBytes] = downloads.map(result => result.value);
        const manifest = JSON.parse(manifestBytes.toString('utf8'));
        const encryptedHash = crypto.createHash('sha256').update(encrypted).digest('hex');
        if (encryptedHash !== row.encrypted_sha256 ||
            manifest.encryptedSha256 !== row.encrypted_sha256 ||
            manifest.plaintextSha256 !== row.plaintext_sha256)
          throw new Error('Automatic restore manifest or checksum mismatch');
        const key = unwrapVaultKey(row.encrypted_data_key, row.user_id);
        const restored = decryptBuffer({ version: 1,
          algorithm: manifest.encryption.algorithm, nonce: manifest.encryption.nonce,
          tag: manifest.encryption.tag, ciphertext: encrypted }, key,
        manifest.encryption.associatedData);
        const restoredHash = crypto.createHash('sha256').update(restored).digest('hex');
        if (restored.length !== Number(row.file_size) || restoredHash !== row.plaintext_sha256 ||
            restoredHash !== row.content_sha256)
          throw new Error('Automatic restored plaintext checksum mismatch');
        const result = await pool.query(`WITH verified AS (
          UPDATE media_backup_items SET restore_verified_at=now(),updated_at=now(),
            restore_attempt_count=0,restore_next_attempt_at=NULL,restore_last_error=NULL
          WHERE id=$1 AND user_id=$2 AND plaintext_sha256=$3
            AND status='verified' AND restore_verified_at IS NULL
            AND EXISTS (SELECT 1 FROM stored_files sf WHERE sf.id=media_backup_items.stored_file_id
              AND sf.user_id=$2 AND sf.content_sha256=$3
              AND sf.content_purged_at IS NULL AND sf.released_at IS NULL)
          RETURNING stored_file_id,user_id
        ), confirmed AS (
          UPDATE stored_files sf SET release_scheduled_at=COALESCE(sf.release_scheduled_at,now()),
            personal_storage_verified_at=CASE WHEN sf.storage_tier='personal'
              THEN COALESCE(sf.personal_storage_verified_at,now()) ELSE sf.personal_storage_verified_at END
          FROM verified WHERE sf.id=verified.stored_file_id AND sf.user_id=verified.user_id
            AND sf.content_sha256=$3 AND sf.content_purged_at IS NULL AND sf.released_at IS NULL
          RETURNING sf.id,sf.storage_tier
        ), handoff AS (
          UPDATE central_drive_objects o SET status='delete_pending',next_attempt_at=now()
          FROM confirmed WHERE o.file_id=confirmed.id AND confirmed.storage_tier='personal'
          RETURNING o.id
        ) SELECT id FROM confirmed`, [row.id, row.user_id, restoredHash]);
        if (result.rowCount === 0) return;
        verified = true;
      });
      if (!verified) return { skipped: true };
      await onVerified({ storedFileId: row.stored_file_id, userId: row.user_id, bytes: Number(row.file_size) });
      await releaseVerified();
      return { verified: 1, failed: 0 };
    } catch (error) {
      const code = errorCode(error);
      if (verified) {
        onError(error, { stage: 'post_verification', fileId: row.id, code });
        return { verified: 1, failed: 0 };
      }
      if (row && pool) {
        try {
          await pool.query(`UPDATE media_backup_items SET
            restore_attempt_count=restore_attempt_count+1,
            restore_next_attempt_at=now()+INTERVAL '5 minutes'*power(2,LEAST(restore_attempt_count,3)),
            restore_last_error=$2,updated_at=now()
            WHERE id=$1 AND status='verified' AND restore_verified_at IS NULL`, [row.id, code]);
        } catch (recordError) {
          onError(recordError, { stage: 'queue', code: 'RESTORE_RETRY_RECORD_FAILED' });
        }
      }
      onError(error, { stage: row ? 'verification' : 'queue', fileId: row?.id, code });
      return { verified: 0, failed: 1, deferred: Boolean(row) };
    } finally {
      running = false;
    }
  };
}

module.exports = { SCHEMA, SELECT_NEXT_SQL, createAutomaticRestoreQueue, createVerificationLock };
