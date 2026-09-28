'use strict';

// Explicit, operator-run repair of unsent WebM uploads misclassified as video.
// Defaults to a read-only dry run. Never queues or sends messages.
const fs = require('fs/promises');
const path = require('path');
const os = require('os');
const { createHash, randomUUID } = require('crypto');
const { MAX_AUDIO_BYTES, probeAudio, probeWebmMime } = require('./audio-moderation');
const { beginOperation, recordAuditEvent, runWithAuditContext } = require('./system-audit');
const { setAuditTransactionContext } = require('./system-audit-context');

async function verifyAudio(row, bytes) {
  if (row.file_type !== 'video' || row.mime_type !== 'video/webm' ||
      row.moderation_status !== 'stopped' ||
      row.moderation_details?.reasonCode !== 'scan_incomplete' ||
      !row.moderation_details?.error?.includes('The uploaded file is not a readable video')) {
    throw new Error('File is not an eligible stopped WebM upload');
  }
  if (!bytes.length || bytes.length > MAX_AUDIO_BYTES || bytes.length !== Number(row.file_size) ||
      createHash('sha256').update(bytes).digest('hex') !== row.content_sha256) {
    throw new Error('File size or checksum mismatch');
  }
  if (await probeWebmMime(bytes, row.original_name) !== 'audio/webm') {
    throw new Error('File contains video; audio repair refused');
  }
  return probeAudio(bytes, row.original_name);
}

async function repairFiles(db, ids, { apply = false } = {}) {
  if (!ids.length || ids.length > 20 || new Set(ids).size !== ids.length ||
      ids.some(id => !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id))) {
    throw new Error('Supply 1–20 distinct explicit file UUIDs');
  }
  await db.query(apply ? 'BEGIN ISOLATION LEVEL SERIALIZABLE' : 'BEGIN READ ONLY');
  try {
    await db.query("SET LOCAL lock_timeout='10s'");
    const { rows } = await db.query(
      `SELECT * FROM stored_files WHERE id=ANY($1::uuid[]) ORDER BY id${apply ? ' FOR UPDATE' : ''}`, [ids]);
    if (rows.length !== ids.length) throw new Error('One or more files were not found');
    const uploadsRoot = await fs.realpath(path.join(__dirname, '..', 'uploads'));
    const checked = [];
    for (const row of rows) {
      const references = await db.query(`SELECT
        EXISTS(SELECT 1 FROM messages WHERE file_url=$1) OR
        EXISTS(SELECT 1 FROM message_requests WHERE file_url=$1) OR
        EXISTS(SELECT 1 FROM pending_scans WHERE file_url=$1) AS referenced`, [row.public_url]);
      if (references.rows[0].referenced) throw new Error('File is already sent, requested or queued');
      const filePath = await fs.realpath(path.resolve(uploadsRoot, row.storage_path));
      if (!filePath.startsWith(uploadsRoot + path.sep)) throw new Error('Invalid upload path');
      const { durationSeconds } = await verifyAudio(row, await fs.readFile(filePath));
      checked.push({ row, durationSeconds });
    }
    if (apply) {
      const snapshotDirectory = path.join(os.homedir(), '.local', 'state', 'newone-repairs');
      await fs.mkdir(snapshotDirectory, { recursive: true, mode: 0o700 });
      await fs.chmod(snapshotDirectory, 0o700);
      const snapshotPath = path.join(snapshotDirectory, `webm-audio-${Date.now()}-${randomUUID()}.json`);
      await fs.writeFile(snapshotPath, JSON.stringify({ savedAt: new Date().toISOString(), rows }, null, 2),
        { flag: 'wx', mode: 0o600 });
      for (const { row, durationSeconds } of checked) {
        const operation = await beginOperation(db, {
          action: 'repair_audio_type', source: 'maintenance', executorType: 'system',
          executorId: 'maintenance', targetType: 'file', targetId: row.id,
          details: { storedFileId: row.id, mediaType: 'audio', auditOperationId: row.audit_operation_id },
        });
        await runWithAuditContext({ operationId: operation.id, parentEventId: operation.root_event_id,
          source: 'maintenance', executorType: 'system', executorId: 'maintenance' }, async () => {
          await setAuditTransactionContext(db);
          const details = {
            blocked: false, pending: false, blockedBy: null, reason: null,
            audio: { source: 'duration-probe', transcription: 'disabled', durationSeconds },
            moderationVersion: row.moderation_details.moderationVersion,
            repair: { operationId: operation.id, reasonCode: 'audio_type_corrected',
              previousFileType: row.file_type, previousStatus: row.moderation_status,
              previousDetails: row.moderation_details },
          };
          await db.query(`UPDATE stored_files SET file_type='audio', mime_type='audio/webm',
            moderation_status='approved', moderation_details=$2::jsonb,
            blocked_content_expires_at=NULL WHERE id=$1`, [row.id, JSON.stringify(details)]);
          await recordAuditEvent(db, { kind: 'scan_workflow_finished', status: 'completed',
            operationStatus: 'completed', reasonCode: 'audio_type_corrected',
            targetType: 'file', targetId: row.id,
            details: { storedFileId: row.id, mediaType: 'audio', previousStatus: 'stopped',
              nextStatus: 'approved', durationMs: Math.round(durationSeconds * 1000) },
          });
        });
      }
    }
    await db.query('COMMIT');
    return checked.map(({ row, durationSeconds }) => ({ id: row.id, durationSeconds,
      fileType: 'audio', applied: apply }));
  } catch (error) {
    await db.query('ROLLBACK');
    throw error;
  }
}

if (require.main === module) {
  require('dotenv').config({ path: path.join(__dirname, '..', '.env'), quiet: true });
  const { Client } = require('pg');
  const args = process.argv.slice(2);
  const apply = args[0] === '--apply';
  const db = new Client({ connectionString: process.env.DATABASE_URL });
  (async () => {
    await db.connect();
    try { console.log(JSON.stringify(await repairFiles(db, apply ? args.slice(1) : args, { apply }), null, 2)); }
    finally { await db.end(); }
  })().catch(error => { console.error(error.message); process.exitCode = 1; });
}

module.exports = { verifyAudio, repairFiles };
