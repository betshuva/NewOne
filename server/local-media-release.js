'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const path = require('node:path');
const drive = require('./personal-drive');
const { unwrapVaultKey } = require('./backup-vault-key');
const { decryptBuffer } = require('./media-backup-crypto');

const RELEASE_FROM_SQL = `FROM stored_files sf
  JOIN media_backup_items mbi ON mbi.stored_file_id=sf.id AND mbi.user_id=sf.user_id
  JOIN user_backup_settings s ON s.user_id=sf.user_id
  JOIN cloud_backup_accounts c ON c.user_id=sf.user_id AND c.provider='google_drive'`;

// References keep the logical file alive, but no longer require local bytes.
const RELEASE_WHERE_SQL = `(s.enabled=TRUE OR to_jsonb(sf)->>'storage_tier'='personal') AND c.status='connected'
  AND s.encrypted_data_key IS NOT NULL
  AND mbi.provider='google_drive' AND mbi.status='verified'
  AND mbi.remote_file_id IS NOT NULL AND mbi.restore_verified_at IS NOT NULL
  AND mbi.encryption_metadata->>'keySource'='server_vault'
  AND mbi.plaintext_sha256=sf.content_sha256
  AND sf.moderation_status='approved' AND sf.content_purged_at IS NULL
  AND sf.moderation_details->>'pending' IS DISTINCT FROM 'true'
  AND sf.released_at IS NULL AND sf.release_scheduled_at<=now()
  AND NOT EXISTS (SELECT 1 FROM pending_scans ps WHERE ps.file_url=sf.public_url)`;

async function verifiedCloudBytes(row) {
  const token = drive.decryptRefreshToken(row.encrypted_refresh_token, row.user_id);
  const encrypted = await drive.downloadAppDataFile(token, row.remote_file_id,
    Number(row.file_size) + 1024);
  if (crypto.createHash('sha256').update(encrypted).digest('hex') !== row.encrypted_sha256)
    throw new Error('Cloud ciphertext checksum mismatch; local copy retained');
  const metadata = typeof row.encryption_metadata === 'string'
    ? JSON.parse(row.encryption_metadata) : row.encryption_metadata;
  const plain = decryptBuffer({ version: 1, algorithm: metadata.algorithm,
    nonce: metadata.nonce, tag: metadata.tag, ciphertext: encrypted },
  unwrapVaultKey(row.encrypted_data_key, row.user_id), metadata.associatedData);
  const hash = crypto.createHash('sha256').update(plain).digest('hex');
  if (plain.length !== Number(row.file_size) || hash !== row.content_sha256 ||
      hash !== row.plaintext_sha256)
    throw new Error('Cloud plaintext checksum mismatch; local copy retained');
  return plain;
}

async function releaseLocalMediaBatch({ pool, uploadRoot, limit = 10,
    onReleased = () => {}, onError = () => {} }) {
  const due = await pool.query(`SELECT sf.id ${RELEASE_FROM_SQL}
    WHERE ${RELEASE_WHERE_SQL} ORDER BY sf.release_scheduled_at,sf.id LIMIT $1`, [limit]);
  const result = { examined: due.rows.length, released: 0, bytes: 0, failed: 0 };
  for (const candidate of due.rows) {
    const client = await pool.connect();
    let row, plain, absolutePath, removed = false, committed = false;
    try {
      await client.query('BEGIN');
      // Recheck eligibility under locks, including opt-out/disconnect and scans.
      const claimed = await client.query(`SELECT sf.id,sf.user_id,sf.storage_path,
          sf.file_size,sf.content_sha256,mbi.remote_file_id,mbi.encrypted_sha256,
          mbi.plaintext_sha256,mbi.encryption_metadata,s.encrypted_data_key,
          c.encrypted_refresh_token ${RELEASE_FROM_SQL}
        WHERE sf.id=$1 AND ${RELEASE_WHERE_SQL}
        FOR UPDATE OF sf,mbi,s,c SKIP LOCKED`, [candidate.id]);
      row = claimed.rows[0];
      if (!row) { await client.query('ROLLBACK'); continue; }
      const root = await fs.realpath(uploadRoot);
      absolutePath = path.resolve(root, row.storage_path);
      if (!absolutePath.startsWith(root + path.sep)) throw new Error('Invalid release path');
      try {
        const real = await fs.realpath(absolutePath);
        if (!real.startsWith(root + path.sep)) throw new Error('Invalid release symlink');
      } catch (error) { if (error.code !== 'ENOENT') throw error; }
      // A historical verification is insufficient if the remote file disappeared.
      plain = await verifiedCloudBytes(row);
      try { await fs.unlink(absolutePath); removed = true; }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
      await client.query('UPDATE stored_files SET released_at=now() WHERE id=$1', [row.id]);
      await client.query('COMMIT');
      committed = true;
      result.released++;
      if (removed) result.bytes += plain.length;
    } catch (error) {
      await client.query('ROLLBACK').catch(() => {});
      if (removed && !committed) {
        await fs.writeFile(absolutePath, plain, { flag: 'wx', mode: 0o600 })
          .catch(restoreError => { if (restoreError.code !== 'EEXIST') throw restoreError; });
      }
      result.failed++;
      // A broken backup must not starve later files or spin on the Drive API.
      await client.query(`UPDATE stored_files SET release_scheduled_at=now()+INTERVAL '5 minutes'
        WHERE id=$1 AND released_at IS NULL`, [candidate.id]).catch(() => {});
      onError(candidate.id, error);
    } finally { client.release(); }
    if (committed) onReleased(row, plain.length);
  }
  return result;
}

module.exports = { RELEASE_FROM_SQL, RELEASE_WHERE_SQL, releaseLocalMediaBatch, verifiedCloudBytes };
