'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const path = require('node:path');
const jwt = require('jsonwebtoken');
const { createGuideSpreadsheet } = require('./guide-spreadsheet');
const { createVaultKey, wrapVaultKey, unwrapVaultKey } = require('./backup-vault-key');
const { decryptBuffer: decryptBackupBuffer } = require('./media-backup-crypto');
const personalDrive = require('./personal-drive');

const PRIVATE_DIRECTORY = '.guide-files';
const FILE_URL_BASE = '/betshuva-app/api/guide-files';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MIME_TYPE = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

function guideFileId(url) {
  const match = String(url || '').match(/^\/betshuva-app\/api\/guide-files\/([^/]+)\/download$/);
  return match && UUID.test(match[1]) ? match[1] : null;
}

function privateFilePath(uploadRoot, file) {
  if (!UUID.test(String(file.id)) || file.storage_path !== `${PRIVATE_DIRECTORY}/${file.id}.xlsx`)
    throw new Error('Invalid guide file path');
  return path.join(uploadRoot, PRIVATE_DIRECTORY, `${file.id}.xlsx`);
}

function downloadSecret(secret) {
  if (!secret) throw new Error('Guide download signing key is missing');
  return crypto.createHmac('sha256', secret).update('guide-file-download-v1').digest();
}

function signedDownloadUrl(file, secret) {
  const token = jwt.sign({ purpose: 'guide_file_download', fileId: file.id, userId: file.user_id },
    downloadSecret(secret), { algorithm: 'HS256', audience: 'guide-file-download', expiresIn: '5m' });
  return `${FILE_URL_BASE}/${file.id}/download?token=${encodeURIComponent(token)}`;
}

function verifyDownloadToken(token, fileId, secret) {
  const claims = jwt.verify(token, downloadSecret(secret), {
    algorithms: ['HS256'], audience: 'guide-file-download',
  });
  if (claims.purpose !== 'guide_file_download' || claims.fileId !== fileId || !UUID.test(claims.userId))
    throw new Error('Invalid guide download token');
  return claims.userId;
}

async function loadOwnedGuideFile(pool, userId, fileId) {
  if (!UUID.test(String(fileId)) || !userId) return null;
  const result = await pool.query(`SELECT sf.id,sf.user_id,sf.original_name,sf.storage_path,
      sf.public_url,sf.mime_type,sf.file_type,sf.file_size,sf.content_sha256,
      mbi.status AS backup_status
    FROM stored_files sf
    LEFT JOIN media_backup_items mbi ON mbi.stored_file_id=sf.id AND mbi.provider='google_drive'
    WHERE sf.id=$2 AND sf.user_id=$1 AND sf.moderation_status='approved'
      AND sf.content_purged_at IS NULL
      AND sf.moderation_details->>'generatedBy'='system_guide'`, [userId, fileId]);
  return result.rows[0] || null;
}

async function readGuideFileBytes(pool, uploadRoot, file) {
  const absolutePath = privateFilePath(uploadRoot, file);
  try {
    const bytes = await fs.readFile(absolutePath);
    if (crypto.createHash('sha256').update(bytes).digest('hex') !== file.content_sha256)
      throw new Error('Guide file checksum mismatch');
    return bytes;
  } catch (error) { if (error.code !== 'ENOENT') throw error; }
  // A file explicitly saved to Drive remains restorable even if automatic
  // backups are later disabled. Ownership was checked before this read.
  const result = await pool.query(`SELECT mbi.remote_file_id,mbi.encrypted_sha256,
      mbi.encryption_metadata,s.encrypted_data_key,c.encrypted_refresh_token
    FROM media_backup_items mbi
    JOIN user_backup_settings s ON s.user_id=mbi.user_id
    JOIN cloud_backup_accounts c ON c.user_id=mbi.user_id
      AND c.provider='google_drive' AND c.status='connected'
    WHERE mbi.stored_file_id=$2 AND mbi.user_id=$1 AND mbi.provider='google_drive'
      AND mbi.status='verified'`, [file.user_id, file.id]);
  const backup = result.rows[0];
  if (!backup?.encrypted_data_key) throw new Error('Guide file backup is unavailable');
  const refreshToken = personalDrive.decryptRefreshToken(backup.encrypted_refresh_token, file.user_id);
  const encrypted = await personalDrive.downloadAppDataFile(refreshToken, backup.remote_file_id,
    Number(file.file_size) + 1024);
  if (crypto.createHash('sha256').update(encrypted).digest('hex') !== backup.encrypted_sha256)
    throw new Error('Guide backup checksum mismatch');
  const metadata = typeof backup.encryption_metadata === 'string'
    ? JSON.parse(backup.encryption_metadata) : backup.encryption_metadata;
  const bytes = decryptBackupBuffer({ version: 1, algorithm: metadata.algorithm,
    nonce: metadata.nonce, tag: metadata.tag, ciphertext: encrypted },
  unwrapVaultKey(backup.encrypted_data_key, file.user_id), metadata.associatedData);
  if (crypto.createHash('sha256').update(bytes).digest('hex') !== file.content_sha256)
    throw new Error('Restored guide file checksum mismatch');
  return bytes;
}

async function persistGuideSpreadsheetReply({ pool, userId, assistantId, sourceMessageId,
    spreadsheet, answer = '', uploadRoot, sanitizeText = value => value }) {
  const workbook = await createGuideSpreadsheet(spreadsheet);
  const fileId = crypto.randomUUID();
  const storagePath = `${PRIVATE_DIRECTORY}/${fileId}.xlsx`;
  const fileUrl = `${FILE_URL_BASE}/${fileId}/download`;
  const hash = crypto.createHash('sha256').update(workbook.buffer).digest('hex');
  const directory = path.join(uploadRoot, PRIVATE_DIRECTORY);
  await fs.mkdir(directory, { recursive: true, mode: 0o700 });
  const absolutePath = privateFilePath(uploadRoot, { id: fileId, storage_path: storagePath });
  let fileHandle;
  let fileCreated = false;
  let client;
  let committed = false;
  try {
    fileHandle = await fs.open(absolutePath, 'wx', 0o600);
    fileCreated = true;
    await fileHandle.writeFile(workbook.buffer);
    await fileHandle.close();
    fileHandle = null;
    client = await pool.connect();
    await client.query('BEGIN');
    await client.query(`INSERT INTO stored_files
      (id,user_id,original_name,storage_path,public_url,mime_type,file_type,file_size,
       context_type,context_id,moderation_status,content_sha256,moderation_details)
      VALUES($1,$2,$3,$4,$5,$6,'document',$7,'chat',$8,'approved',$9,$10)`,
    [fileId, userId, workbook.fileName, storagePath, fileUrl, workbook.mimeType,
      workbook.buffer.length, assistantId, hash,
      JSON.stringify({ generatedBy: 'system_guide', sourceMessageId, rowCount: workbook.rowCount })]);
    const account = await client.query(`SELECT 1 FROM cloud_backup_accounts
      WHERE user_id=$1 AND provider='google_drive' AND status='connected'`, [userId]);
    let backupStatus = 'not_connected';
    if (account.rows.length) {
      const wrappedKey = wrapVaultKey(createVaultKey(), userId);
      await client.query(`INSERT INTO user_backup_settings
        (user_id,provider,encrypted_data_key,data_key_version)
        VALUES($1,'google_drive',$2,1)
        ON CONFLICT(user_id) DO UPDATE SET
          provider='google_drive',
          encrypted_data_key=COALESCE(user_backup_settings.encrypted_data_key,$2),
          data_key_version=COALESCE(user_backup_settings.data_key_version,1),updated_at=now()`,
      [userId, wrappedKey]);
      // This is a request to save this file, not an opt-in for all user media.
      await client.query(`INSERT INTO media_backup_items
        (user_id,stored_file_id,provider,status,plaintext_sha256,encryption_metadata)
        VALUES($1,$2,'google_drive','queued',$3,$4)`,
      [userId, fileId, hash, JSON.stringify({ guideRequested: true })]);
      backupStatus = 'queued';
    }
    const backupText = backupStatus === 'queued'
      ? 'הקובץ נשמר בנתונים שלך וממתין לשמירה ב־Google Drive האישי שלך.'
      : 'הקובץ נשמר בנתונים שלך. כדי לשמור אותו גם ב־Google Drive, יש לחבר את החשבון ולהפעיל גיבוי:\nbetshuva://app/backup-settings';
    const body = sanitizeText(`${answer ? `${answer}\n\n` : ''}קובץ Excel מוכן (${workbook.rowCount} שורות).\n` +
      `לפתיחה ולהורדה:\nbetshuva://app/guide-file/${fileId}\n\n${backupText}`);
    const saved = await client.query(`INSERT INTO messages
      (sender_id,recipient_id,type,body,file_url,file_name,file_size,reply_to_id)
      VALUES($1,$2,'document',$3,$4,$5,$6,$7) RETURNING id,created_at`,
    [assistantId, userId, body, fileUrl, workbook.fileName, workbook.buffer.length, sourceMessageId]);
    await client.query('COMMIT');
    committed = true;
    return { answer: body, reply: saved.rows[0], file: { id: fileId, url: fileUrl,
      name: workbook.fileName, size: workbook.buffer.length, type: 'document' }, backupStatus };
  } catch (error) {
    if (client) await client.query('ROLLBACK').catch(() => {});
    throw error;
  } finally {
    if (fileHandle) await fileHandle.close().catch(() => {});
    if (client) client.release();
    if (fileCreated && !committed) await fs.unlink(absolutePath).catch(() => {});
  }
}

function registerGuideFileRoutes(app, { auth, getPool, uploadRoot, secret }) {
  app.get('/api/guide-files/:id', auth, async (req, res) => {
    try {
      const file = await loadOwnedGuideFile(await getPool(), req.user.id, req.params.id);
      if (!file) return res.status(404).json({ error: 'הקובץ אינו זמין בחשבון שלך' });
      res.set('Cache-Control', 'private, no-store');
      res.json({ id: file.id, fileUrl: file.public_url, fileName: file.original_name,
        fileType: 'document', fileSize: Number(file.file_size),
        downloadUrl: signedDownloadUrl(file, secret), backupStatus: file.backup_status || 'not_connected' });
    } catch (error) {
      console.error('guide file metadata:', error.code || error.name);
      res.status(503).json({ error: 'לא ניתן לטעון את הקובץ כרגע' });
    }
  });
  const downloadAuth = (req, res, next) => {
    if (!req.query.token) return auth(req, res, next);
    try {
      req.user = { id: verifyDownloadToken(String(req.query.token), req.params.id, secret) };
      next();
    } catch (_) { res.status(401).json({ error: 'קישור ההורדה פג. פתח שוב את הקובץ מתוך השיחה' }); }
  };
  app.get('/api/guide-files/:id/download', downloadAuth, async (req, res) => {
    try {
      const pool = await getPool();
      const file = await loadOwnedGuideFile(pool, req.user.id, req.params.id);
      if (!file) return res.status(404).json({ error: 'הקובץ אינו זמין בחשבון שלך' });
      const bytes = await readGuideFileBytes(pool, uploadRoot, file);
      res.set({ 'Cache-Control': 'private, no-store', 'Content-Type': MIME_TYPE });
      res.attachment(file.original_name);
      res.send(bytes);
    } catch (error) {
      console.error('guide file download:', error.code || error.name);
      res.status(503).json({ error: 'הקובץ אינו זמין כרגע. נסה שוב בעוד רגע' });
    }
  });
}

module.exports = { PRIVATE_DIRECTORY, FILE_URL_BASE, guideFileId, loadOwnedGuideFile,
  readGuideFileBytes, persistGuideSpreadsheetReply, registerGuideFileRoutes,
  signedDownloadUrl, verifyDownloadToken };
