'use strict';

const crypto = require('crypto');
const fs = require('fs/promises');
const path = require('path');
const personalDrive = require('./personal-drive');
const { personalMessageVisible } = require('./conversation-history');

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_DELETE_IDS = 1000;
const SYSTEM_USERS = ['00000000-0000-4000-8000-000000000001',
  '00000000-0000-4000-8000-000000000002', '00000000-0000-4000-8000-000000000003'];
const linkedTables = [
  ['users', 'profile_pic_url', 'profile', 'תמונות פרופיל'],
  ['groups', 'profile_pic_url', 'group', 'תמונות קבוצות'],
  ['listings', 'image_url', 'listing', 'תמונות ראשיות במודעות'],
  ['listing_images', 'url', 'listingImage', 'תמונות נוספות במודעות'],
  ['education_forms', 'file_url', 'form', 'קבצים בטפסים'],
];

// Keep only the deleted source's identity. Recipient-owned files have their own
// URL and remain independently available. A stale client cannot send this URL
// again, including through an older contact request or delayed scan.
const MEDIA_DELETE_SCHEMA = `
CREATE TABLE IF NOT EXISTS deleted_media_sources (
  public_url TEXT PRIMARY KEY,
  owner_id UUID NOT NULL,
  storage_path TEXT,
  deleted_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE deleted_media_sources ADD COLUMN IF NOT EXISTS storage_path TEXT;
CREATE INDEX IF NOT EXISTS deleted_media_sources_path_idx ON deleted_media_sources(storage_path);
CREATE TABLE IF NOT EXISTS media_deletion_jobs (
  file_id UUID PRIMARY KEY,
  owner_id UUID NOT NULL,
  storage_path TEXT NOT NULL,
  file_size BIGINT NOT NULL DEFAULT 0,
  remote_file_id TEXT,
  manifest_remote_id TEXT,
  local_deleted BOOLEAN NOT NULL DEFAULT FALSE,
  cloud_payload_deleted BOOLEAN NOT NULL DEFAULT FALSE,
  cloud_manifest_deleted BOOLEAN NOT NULL DEFAULT FALSE,
  attempt_count INTEGER NOT NULL DEFAULT 0,
  next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_error TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE OR REPLACE FUNCTION guard_deleted_media_reference() RETURNS trigger AS $$
DECLARE media_url TEXT; previous_url TEXT;
BEGIN
  media_url := to_jsonb(NEW)->>TG_ARGV[0];
  IF media_url IS NULL THEN RETURN NEW; END IF;
  -- Deletion takes UPDATE after locking pending deliveries and recipient jobs.
  -- Every new reference holds SHARE until it commits, closing the validation /
  -- insert gap without a global table lock.
  PERFORM id FROM stored_files WHERE public_url=media_url FOR SHARE;
  IF TG_OP='UPDATE' THEN previous_url := to_jsonb(OLD)->>TG_ARGV[0]; END IF;
  IF (TG_OP='INSERT' OR previous_url IS DISTINCT FROM media_url)
    AND EXISTS (SELECT 1 FROM deleted_media_sources WHERE public_url=media_url) THEN
    RAISE EXCEPTION 'MEDIA_DELETED' USING ERRCODE='P0001';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
${[['messages', 'file_url'], ['message_requests', 'file_url'], ['pending_scans', 'file_url'],
  ...linkedTables.map(([table, field]) => [table, field])].map(([table, field]) => `
DROP TRIGGER IF EXISTS guard_deleted_media_reference ON ${table};
CREATE TRIGGER guard_deleted_media_reference BEFORE INSERT OR UPDATE OF ${field}${table === 'messages' ? ',delivery_summary' : ''}
  ON ${table} FOR EACH ROW EXECUTE FUNCTION guard_deleted_media_reference('${field}');`).join('\n')}
`;

function failure(status, code, message, extra) {
  return Object.assign(new Error(message), { status, code, ...extra });
}

function normalizedIds(input) {
  if (!Array.isArray(input) || !input.length || input.some(id => !UUID.test(String(id))))
    throw failure(400, 'INVALID_MEDIA_IDS', 'יש לבחור קבצים למחיקה');
  const ids = [...new Set(input.map(id => String(id).toLowerCase()))].sort();
  if (ids.length > MAX_DELETE_IDS)
    throw failure(400, 'TOO_MANY_MEDIA_IDS', `אפשר למחוק עד ${MAX_DELETE_IDS} עותקים בכל אישור`, { maxIds: MAX_DELETE_IDS });
  return ids;
}

async function snapshot(db, userId, ids) {
  const files = (await db.query(`SELECT sf.id,sf.original_name,sf.public_url,sf.storage_path,
      sf.file_size,sf.file_type,sf.content_sha256,sf.moderation_status,sf.content_purged_at,
      mbi.status AS backup_status,mbi.remote_file_id,mbi.encryption_metadata,
      c.encrypted_refresh_token
    FROM stored_files sf
    LEFT JOIN media_backup_items mbi ON mbi.stored_file_id=sf.id AND mbi.provider='google_drive'
    LEFT JOIN cloud_backup_accounts c ON c.user_id=sf.user_id AND c.status='connected'
    WHERE sf.user_id=$1 AND sf.id=ANY($2::uuid[]) ORDER BY sf.id`, [userId, ids])).rows;
  if (files.length !== ids.length)
    throw failure(404, 'MEDIA_NOT_FOUND', 'אחד הקבצים שנבחרו אינו נמצא במדיה שלך');
  const urls = files.map(file => file.public_url);
  const messages = (await db.query(`SELECT m.id,m.sender_id,m.recipient_id,m.group_id,m.file_url,
      m.delivery_summary,m.deleted_for_everyone
    FROM messages m WHERE m.file_url=ANY($1::text[]) ORDER BY m.id`, [urls])).rows;
  const ledger = (await db.query(`SELECT r.message_id,r.user_id,r.source_file_id,r.stored_file_id,r.status,
      (sf.id IS NOT NULL AND sf.user_id=r.user_id) AS copy_exists
    FROM received_message_media r LEFT JOIN stored_files sf ON sf.id=r.stored_file_id
    WHERE r.source_file_id=ANY($1::uuid[]) OR r.stored_file_id=ANY($1::uuid[])
      OR r.message_id=ANY($2::uuid[]) ORDER BY r.message_id,r.user_id`, [ids, messages.map(m => m.id)])).rows;
  const readers = (await db.query(`SELECT m.id AS message_id,recipient.user_id FROM messages m
    CROSS JOIN LATERAL (
      SELECT m.recipient_id AS user_id WHERE m.group_id IS NULL AND m.recipient_id IS NOT NULL
      UNION SELECT gm.user_id FROM group_members gm WHERE gm.group_id=m.group_id AND gm.status='member'
    ) recipient WHERE m.id=ANY($1::uuid[]) AND ${personalMessageVisible('m', 'recipient.user_id')}
    ORDER BY m.id,recipient.user_id`, [messages.map(m => m.id)])).rows;
  const pending = (await db.query(`
    SELECT 'request' AS kind,mr.id::text AS id,mr.recipient_id AS user_id,NULL::uuid AS group_id,
      mr.file_url,u.name AS name,NULL::text AS group_name
    FROM message_requests mr LEFT JOIN users u ON u.id=mr.recipient_id WHERE mr.file_url=ANY($1::text[])
    UNION ALL
    SELECT 'scan',ps.id::text,ps.to_user_id,ps.group_id,ps.file_url,u.name,g.name
    FROM pending_scans ps LEFT JOIN users u ON u.id=ps.to_user_id LEFT JOIN groups g ON g.id=ps.group_id
    WHERE ps.file_url=ANY($1::text[]) ORDER BY kind,id`, [urls])).rows;
  const groupIds = [...new Set(messages.map(m => m.group_id).filter(Boolean))];
  const members = groupIds.length ? (await db.query(`SELECT gm.group_id,gm.user_id,u.name,g.name AS group_name
    FROM group_members gm JOIN users u ON u.id=gm.user_id JOIN groups g ON g.id=gm.group_id
    WHERE gm.group_id=ANY($1::uuid[]) AND gm.status='member' ORDER BY gm.group_id,gm.user_id`, [groupIds])).rows : [];
  const userIds = [...new Set([...messages.map(m => m.recipient_id), ...ledger.map(r => r.user_id)].filter(Boolean))];
  const people = userIds.length ? (await db.query('SELECT id,name FROM users WHERE id=ANY($1::uuid[]) ORDER BY id', [userIds])).rows : [];
  const links = [];
  for (const [table, field, type, label] of linkedTables) {
    const rows = (await db.query(`SELECT id::text,${field} AS url FROM ${table}
      WHERE ${field}=ANY($1::text[]) ORDER BY id`, [urls])).rows;
    for (const row of rows) links.push({ type, label, ...row });
  }
  const gifs = (await db.query(`SELECT id::text,stored_file_id,status FROM shared_gifs
    WHERE stored_file_id=ANY($1::uuid[]) ORDER BY id`, [ids])).rows;
  for (const row of gifs) links.push({ type: 'gif', label: 'קובצי GIF משותפים', ...row });
  return { files, messages, ledger, readers, pending, members, people, links };
}

function describe(state, userId) {
  const ledger = new Map(state.ledger.map(r => [`${r.message_id}:${r.user_id}`, r]));
  const readers = new Set(state.readers.map(r => `${r.message_id}:${r.user_id}`));
  const people = new Map(state.people.map(person => [person.id, person.name]));
  const candidates = new Map();
  const add = (message, recipient, name, groupName) => {
    if (!recipient || recipient === userId || SYSTEM_USERS.includes(recipient)) return;
    const key = `${message.id}:${recipient}`;
    const saved = ledger.get(key);
    // Missing legacy ledger rows are potential deliveries only for someone
    // who can actually see that message. A previously authorized queued copy
    // still survives normal history clears and leaving a group.
    if (!saved && !readers.has(key)) return;
    // 'skipped' is an intentional cancellation, never an invitation to recover.
    if (saved?.status === 'skipped' || (saved?.status === 'ready' && saved.copy_exists)) return;
    candidates.set(key, { key, messageId: message.id, id: recipient,
      name: name || 'נמען', groupId: message.group_id || null, groupName: groupName || null });
  };
  for (const message of state.messages) {
    if (message.deleted_for_everyone) continue;
    if (!message.group_id) add(message, message.recipient_id, people.get(message.recipient_id));
    else {
      const members = state.members.filter(member => member.group_id === message.group_id);
      const delivered = message.delivery_summary?.deliveredTo;
      for (const member of members) if (member.user_id !== message.sender_id &&
          (!Array.isArray(delivered) || delivered.some(item => item.id === member.user_id)))
        add(message, member.user_id, member.name, member.group_name);
    }
  }
  // A queued copy remains authorized even after its recipient leaves a group.
  for (const row of state.ledger) if (row.status === 'queued') {
    const message = state.messages.find(m => m.id === row.message_id);
    if (message && !message.deleted_for_everyone)
      add(message, row.user_id, people.get(row.user_id), state.members.find(m => m.group_id === message.group_id)?.group_name);
  }
  for (const row of state.pending) if (row.user_id !== userId) candidates.set(`${row.kind}:${row.id}`, {
    key: `${row.kind}:${row.id}`, id: row.user_id, name: row.name || (row.group_id ? 'קבוצה' : 'שליחה בהמתנה'),
    groupId: row.group_id, groupName: row.group_name,
  });
  const recipients = new Map();
  for (const row of candidates.values()) {
    const key = `${row.id || ''}:${row.groupId || ''}`;
    const current = recipients.get(key) || { id: row.id, name: row.name,
      groupId: row.groupId, groupName: row.groupName, count: 0 };
    current.count++;
    recipients.set(key, current);
  }
  const uses = new Map();
  for (const link of state.links) {
    const use = uses.get(link.type) || { type: link.type, label: link.label, count: 0 };
    use.count++; uses.set(link.type, use);
  }
  const files = state.files.map(file => ({ id: file.id, name: file.original_name,
    size: Number(file.file_size || 0), hasBackup: !!file.remote_file_id, backupStatus: file.backup_status || null }));
  return { ids: files.map(file => file.id), fileCount: new Set(state.files.map(file =>
    file.moderation_status === 'approved' && !file.content_purged_at && file.content_sha256
      ? `${file.file_type}:${file.content_sha256}` : file.id)).size,
    copyCount: files.length, totalBytes: files.reduce((sum, file) => sum + file.size, 0), files,
    hasBackup: files.some(file => file.hasBackup), pendingCount: candidates.size,
    pendingRecipientCount: recipients.size, pendingRecipients: [...recipients.values()],
    linkedUses: [...uses.values()], cancellations: [...candidates.values()].filter(row => row.messageId) };
}

function createMediaLibraryDeletion({ uploadRoot, secret = crypto.randomBytes(32),
  filesystem = fs, drive = personalDrive, now = Date.now } = {}) {
  if (!uploadRoot) throw new Error('uploadRoot is required');
  const hash = state => crypto.createHash('sha256').update(JSON.stringify({
    ...state, files: state.files.map(({ encrypted_refresh_token, ...file }) =>
      ({ ...file, driveConnected: !!encrypted_refresh_token })),
  })).digest('hex');
  const sign = value => crypto.createHmac('sha256', secret).update(value).digest('base64url');
  const makePreview = (state, userId) => {
    const { cancellations, ...view } = describe(state, userId);
    const body = Buffer.from(JSON.stringify({ userId, ids: view.ids, state: hash(state), expires: now() + 10 * 60 * 1000 })).toString('base64url');
    return { ...view, confirmationToken: `${body}.${sign(body)}`, maxIds: MAX_DELETE_IDS };
  };
  const parseToken = (token, userId, ids) => {
    if (typeof token !== 'string' || token.length > 100000) throw failure(400, 'INVALID_DELETE_CONFIRMATION', 'אישור המחיקה אינו תקין');
    const [body, signature, extra] = token.split('.');
    const expected = Buffer.from(sign(body || ''));
    const supplied = Buffer.from(signature || '');
    if (extra || expected.length !== supplied.length || !crypto.timingSafeEqual(expected, supplied))
      throw failure(400, 'INVALID_DELETE_CONFIRMATION', 'אישור המחיקה אינו תקין');
    let parsed;
    try { parsed = JSON.parse(Buffer.from(body, 'base64url').toString()); } catch (_) {}
    if (!parsed || parsed.userId !== userId || JSON.stringify(parsed.ids) !== JSON.stringify(ids))
      throw failure(400, 'INVALID_DELETE_CONFIRMATION', 'אישור המחיקה אינו תואם לקבצים שנבחרו');
    return parsed;
  };
  const cleanup = async (pool, ids = null, limit = 20, localOnly = false) => {
    let processed = 0;
    for (let count = 0; count < limit; count++) {
      const db = await pool.connect();
      try {
        await db.query('BEGIN');
        const job = (await db.query(`SELECT * FROM media_deletion_jobs
          WHERE next_attempt_at<=now() AND ($1::uuid[] IS NULL OR file_id=ANY($1::uuid[]))
            AND ($2::boolean=FALSE OR (remote_file_id IS NULL AND manifest_remote_id IS NULL))
          ORDER BY created_at,file_id LIMIT 1 FOR UPDATE SKIP LOCKED`, [ids, localOnly])).rows[0];
        if (!job) { await db.query('COMMIT'); break; }
        processed++;
        try {
          const absolute = path.resolve(uploadRoot, job.storage_path);
          if (!absolute.startsWith(path.resolve(uploadRoot) + path.sep)) throw new Error('invalid stored media path');
          // No original metadata can be restored at this point: the deletion
          // and cleanup job were committed together before touching any bytes.
          if (!job.local_deleted) {
            await filesystem.unlink(absolute).catch(error => { if (error.code !== 'ENOENT') throw error; });
            await db.query('UPDATE media_deletion_jobs SET local_deleted=TRUE WHERE file_id=$1', [job.file_id]);
          }
          if ((job.remote_file_id && !job.cloud_payload_deleted) ||
              (job.manifest_remote_id && !job.cloud_manifest_deleted)) {
            const account = (await db.query(`SELECT encrypted_refresh_token FROM cloud_backup_accounts
              WHERE user_id=$1 AND status='connected'`, [job.owner_id])).rows[0];
            if (!account?.encrypted_refresh_token) throw new Error('BACKUP_RECONNECT_REQUIRED');
            const refresh = drive.decryptRefreshToken(account.encrypted_refresh_token, job.owner_id);
            for (const [remoteId, column, done] of [
              [job.remote_file_id, 'cloud_payload_deleted', job.cloud_payload_deleted],
              [job.manifest_remote_id, 'cloud_manifest_deleted', job.cloud_manifest_deleted],
            ]) if (remoteId && !done) {
              // Drive deletion treats an already absent object as success, so
              // even an uncertain network/commit outcome is safe to retry.
              await drive.deleteAppDataFile(refresh, remoteId);
              await db.query(`UPDATE media_deletion_jobs SET ${column}=TRUE WHERE file_id=$1`, [job.file_id]);
            }
          }
          await db.query('DELETE FROM media_deletion_jobs WHERE file_id=$1', [job.file_id]);
        } catch (error) {
          await db.query(`UPDATE media_deletion_jobs SET attempt_count=attempt_count+1,
            next_attempt_at=now()+interval '1 minute',last_error=$2 WHERE file_id=$1`,
          [job.file_id, error.code || (error.message === 'BACKUP_RECONNECT_REQUIRED' ? error.message : 'CLEANUP_RETRY')]);
        }
        await db.query('COMMIT');
      } catch (error) {
        await db.query('ROLLBACK').catch(() => {});
        // The committed job remains retryable even if updating progress fails.
        break;
      } finally { db.release(); }
    }
    return processed;
  };
  const preview = async (pool, userId, selection) => {
    let ids;
    if (selection?.all === true) ids = normalizedIds((await pool.query(
      'SELECT id FROM stored_files WHERE user_id=$1 ORDER BY id LIMIT $2', [userId, MAX_DELETE_IDS + 1])).rows.map(row => row.id));
    else ids = normalizedIds(selection?.ids);
    const db = await pool.connect();
    try {
      await db.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
      const result = makePreview(await snapshot(db, userId, ids), userId);
      await db.query('COMMIT');
      return result;
    } catch (error) { await db.query('ROLLBACK').catch(() => {}); throw error; }
    finally { db.release(); }
  };
  const confirm = async (pool, userId, request) => {
    const ids = normalizedIds(request?.ids);
    const token = parseToken(request?.confirmationToken, userId, ids);
    const db = await pool.connect();
    const result = { deletedIds: [], failed: [], deletedBytes: 0 };
    try {
      await db.query('BEGIN');
      await db.query("SET LOCAL lock_timeout='5s'");
      await db.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))', [`personal-media-owner:${userId}`]);
      const initial = await snapshot(db, userId, ids);
      const urls = initial.files.map(file => file.public_url);
      // Match the pending-send and copy-worker order. Locking the source first
      // would deadlock a worker that already owns a queue row and wants SHARE.
      await db.query('SELECT id FROM pending_scans WHERE file_url=ANY($1::text[]) ORDER BY id FOR UPDATE', [urls]);
      await db.query('SELECT id FROM message_requests WHERE file_url=ANY($1::text[]) ORDER BY id FOR UPDATE', [urls]);
      await db.query(`SELECT message_id,user_id FROM received_message_media
        WHERE source_file_id=ANY($1::uuid[]) OR stored_file_id=ANY($1::uuid[])
        ORDER BY message_id,user_id FOR UPDATE`, [ids]);
      for (const [table, field] of linkedTables)
        await db.query(`SELECT id FROM ${table} WHERE ${field}=ANY($1::text[]) ORDER BY id FOR UPDATE`, [urls]);
      await db.query('SELECT id FROM shared_gifs WHERE stored_file_id=ANY($1::uuid[]) ORDER BY id FOR UPDATE', [ids]);
      await db.query('SELECT id FROM stored_files WHERE user_id=$1 AND id=ANY($2::uuid[]) ORDER BY id FOR UPDATE', [userId, ids]);
      await db.query("SELECT stored_file_id FROM media_backup_items WHERE stored_file_id=ANY($1::uuid[]) AND provider='google_drive' ORDER BY stored_file_id FOR UPDATE", [ids]);
      const state = await snapshot(db, userId, ids);
      if (token.expires < now() || token.state !== hash(state))
        throw failure(409, 'DELETE_PREVIEW_CHANGED', 'מצב הקבצים השתנה. יש לבדוק ולאשר שוב את המחיקה.', { preview: makePreview(state, userId) });
      const cancellations = describe(state, userId).cancellations;
      for (const file of state.files) {
        await db.query('SAVEPOINT delete_personal_file');
        try {
          if (file.backup_status === 'uploading')
            throw failure(409, 'BACKUP_IN_PROGRESS', 'גיבוי הקובץ נמצא בתהליך. יש לנסות שוב לאחר סיומו.');
          if (file.remote_file_id && !file.encrypted_refresh_token)
            throw failure(409, 'BACKUP_RECONNECT_REQUIRED', 'יש לחבר מחדש את Google Drive לפני מחיקה מלאה של הגיבוי.');
          const absolute = path.resolve(uploadRoot, file.storage_path);
          if (!absolute.startsWith(path.resolve(uploadRoot) + path.sep)) throw new Error('invalid stored media path');
          await db.query('INSERT INTO deleted_media_sources(public_url,owner_id,storage_path) VALUES($1,$2,$3) ON CONFLICT DO NOTHING', [file.public_url, userId, file.storage_path]);
          await db.query(`INSERT INTO media_deletion_jobs(file_id,owner_id,storage_path,remote_file_id,manifest_remote_id,file_size)
            VALUES($1,$2,$3,$4,$5,$6)`, [file.id, userId, file.storage_path, file.remote_file_id || null,
            file.encryption_metadata?.manifestRemoteId || null, Number(file.file_size || 0)]);
          await db.query('DELETE FROM pending_scans WHERE file_url=$1', [file.public_url]);
          await db.query('DELETE FROM message_requests WHERE file_url=$1', [file.public_url]);
          await db.query(`UPDATE received_message_media SET status='skipped',stored_file_id=NULL,last_error='owner_deleted'
            WHERE stored_file_id=$1 AND user_id=$2`, [file.id, userId]);
          await db.query(`UPDATE received_message_media SET status='skipped',last_error='source_deleted'
            WHERE source_file_id=$1 AND status='queued'`, [file.id]);
          for (const row of cancellations) if (state.messages.some(message => message.id === row.messageId && message.file_url === file.public_url))
            await db.query(`INSERT INTO received_message_media(message_id,user_id,source_file_id,status,last_error)
              VALUES($1,$2,$3,'skipped','source_deleted') ON CONFLICT DO NOTHING`, [row.messageId, row.id, file.id]);
          for (const [table, field] of linkedTables) {
            if (table === 'listing_images') await db.query('DELETE FROM listing_images WHERE url=$1', [file.public_url]);
            else await db.query(`UPDATE ${table} SET ${field}=NULL${table === 'education_forms' ? ',file_name=NULL' : ''} WHERE ${field}=$1`, [file.public_url]);
          }
          // Keep messages and their original URLs: ready recipient projections
          // need that metadata to resolve the independent recipient-owned copy.
          await db.query('DELETE FROM stored_files WHERE id=$1 AND user_id=$2', [file.id, userId]);
          await db.query('RELEASE SAVEPOINT delete_personal_file');
          result.deletedIds.push(file.id);
          result.deletedBytes += Number(file.file_size || 0);
        } catch (error) {
          await db.query('ROLLBACK TO SAVEPOINT delete_personal_file');
          await db.query('RELEASE SAVEPOINT delete_personal_file');
          result.failed.push({ id: file.id, name: file.original_name,
            code: error.code || 'MEDIA_DELETE_FAILED', error: error.status ? error.message : 'מחיקת הקובץ נכשלה. אפשר לנסות שוב.' });
        }
      }
      await db.query('COMMIT');
    } catch (error) { await db.query('ROLLBACK').catch(() => {}); throw error; }
    finally { db.release(); }
    // Release the source/queue transaction and its pool connection before any
    // filesystem/network effects. Post-commit failures cannot become a false
    // "deletion failed" response: the durable outbox continues the cleanup.
    // Keep request latency bounded. Cloud operations and large selections are
    // drained by the background worker; at most 20 local-only files finish here.
    await cleanup(pool, result.deletedIds, Math.min(20, result.deletedIds.length), true).catch(() => {});
    let pending = { count: result.deletedIds.length, bytes: result.deletedBytes };
    try { pending = (await pool.query(`SELECT COUNT(*)::int AS count,COALESCE(SUM(file_size),0) AS bytes
      FROM media_deletion_jobs WHERE file_id=ANY($1::uuid[])`, [result.deletedIds])).rows[0]; } catch (_) {}
    result.cleanupPendingCount = Number(pending.count);
    result.cleanupPendingBytes = Number(pending.bytes);
    result.deletedBytes = Math.max(0, result.deletedBytes - result.cleanupPendingBytes);
    return result;
  };
  return { preview, confirm, cleanup };
}

module.exports = { MAX_DELETE_IDS, MEDIA_DELETE_SCHEMA, createMediaLibraryDeletion };
