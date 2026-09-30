'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const { encryptBuffer } = require('./media-backup-crypto');

const ROOT = path.join(__dirname, '..', '.transfer-state', 'backup-jobs');

async function prepareBackupTransfer({ plain, key, userId, fileId, associatedData, root = ROOT }) {
  const fingerprint = crypto.createHash('sha256').update(userId).update(fileId).update(key).update(plain).digest('hex');
  const directory = path.join(root, fingerprint);
  let metadata = await fs.readFile(path.join(directory, 'metadata.json'), 'utf8').then(JSON.parse).catch(e => {
    if (e.code !== 'ENOENT') throw e;
    return null;
  });
  if (!metadata) {
    const envelope = encryptBuffer(plain, key, associatedData);
    const backupId = crypto.randomUUID();
    metadata = { backupId, fileId, userId, createdAt: new Date().toISOString(), associatedData, version: envelope.version, algorithm: envelope.algorithm,
      nonce: envelope.nonce, tag: envelope.tag,
      encryptedHash: crypto.createHash('sha256').update(envelope.ciphertext).digest('hex') };
    await fs.mkdir(directory, { recursive: true, mode: 0o700 });
    await fs.writeFile(path.join(directory, 'payload'), envelope.ciphertext, { mode: 0o600 });
    await fs.writeFile(path.join(directory, 'metadata.tmp'), JSON.stringify(metadata), { mode: 0o600 });
    await fs.rename(path.join(directory, 'metadata.tmp'), path.join(directory, 'metadata.json'));
  }
  const ciphertext = await fs.readFile(path.join(directory, 'payload'));
  if (crypto.createHash('sha256').update(ciphertext).digest('hex') !== metadata.encryptedHash)
    throw new Error('Saved encrypted upload is corrupt');
  return { directory, backupId: metadata.backupId, createdAt: metadata.createdAt, encryptedHash: metadata.encryptedHash,
    envelope: { version: metadata.version, algorithm: metadata.algorithm,
      nonce: metadata.nonce, tag: metadata.tag, ciphertext } };
}

async function clearBackupTransfer(job) {
  await fs.rm(job.directory, { recursive: true, force: true });
}

async function recoverBackupTransfers(pool, root = ROOT) {
  for (const directory of await fs.readdir(root).catch(() => [])) {
    if (!/^[a-f0-9]{64}$/.test(directory)) continue;
    const metadata = await fs.readFile(path.join(root, directory, 'metadata.json'), 'utf8')
      .then(JSON.parse).catch(() => null);
    if (!metadata?.fileId || !metadata?.userId) continue;
    await pool.query(`UPDATE media_backup_items SET status='failed',
      attempt_count=GREATEST(attempt_count-1,0),updated_at=now()-INTERVAL '10 minutes',
      last_error='Interrupted transfer; resumable session retained'
      WHERE stored_file_id=$1 AND user_id=$2 AND provider='google_drive' AND status='uploading'`,
    [metadata.fileId, metadata.userId]);
  }
}

module.exports = { prepareBackupTransfer, clearBackupTransfer, recoverBackupTransfers };
