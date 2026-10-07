'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const path = require('node:path');
const { OAuth2Client } = require('google-auth-library');
const personal = require('./personal-drive');
const { encryptBuffer, decryptBuffer } = require('./media-backup-crypto');
const { createVaultKey, wrapVaultKey, unwrapVaultKey } = require('./backup-vault-key');
const { uploadResumable } = require('./drive-resumable');

const ACCOUNT = 'betshuva@betshuva.com';
const TOKEN_OWNER = `central-drive:${ACCOUNT}`;
const ROOT = path.join(__dirname, '..', '.transfer-state', 'central-drive');
const LOCK = 8640317;
const hash = value => crypto.createHash('sha256').update(value).digest('hex');
function failureReason(error) {
  const allowed = new Set(['central_ciphertext_mismatch', 'central_binding_mismatch', 'central_plaintext_mismatch',
    'central_spool_mismatch', 'central_spool_missing', 'source_checksum_mismatch', 'local_content_changed',
    'existing_remote_mismatch', 'invalid_storage_path', 'invalid_storage_symlink']);
  if (allowed.has(error?.message)) return error.message;
  if (error?.code === 'ENOENT') return 'source_missing';
  if (Number.isInteger(error?.response?.status)) return `provider_http_${error.response.status}`;
  return 'transfer_or_verification_failed';
}
const ELIGIBLE = `sf.user_id IS NOT NULL AND sf.moderation_status='approved'
  AND sf.content_purged_at IS NULL
  AND sf.moderation_details->>'pending' IS DISTINCT FROM 'true'
  AND NOT EXISTS(SELECT 1 FROM pending_scans ps WHERE ps.file_url=sf.public_url)
  AND NOT EXISTS(SELECT 1 FROM deleted_media_sources ds WHERE ds.storage_path=sf.storage_path)`;
const CENTRAL_DESTINATION = `COALESCE(to_jsonb(sf)->>'storage_tier','service')<>'personal'
  AND NOT EXISTS(SELECT 1 FROM cloud_backup_accounts personal_account
    WHERE personal_account.user_id=sf.user_id AND personal_account.status='connected')`;

const SCHEMA = `
CREATE TABLE IF NOT EXISTS central_drive_account (
  id INTEGER PRIMARY KEY CHECK(id=1), email TEXT NOT NULL,
  encrypted_token TEXT NOT NULL, enabled BOOLEAN NOT NULL DEFAULT FALSE,
  quota JSONB, checked_at TIMESTAMPTZ, updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS central_drive_objects (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  file_id UUID UNIQUE REFERENCES stored_files(id) ON DELETE SET NULL,
  owner_id UUID NOT NULL, storage_path TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'uploading' CHECK(status IN ('uploading','verified','failed','delete_pending')),
  remote_file_id TEXT, encrypted_data_key TEXT NOT NULL,
  file_size BIGINT, plaintext_sha256 TEXT, encrypted_sha256 TEXT, encryption_metadata JSONB,
  attempt_count INTEGER NOT NULL DEFAULT 0, last_error TEXT,
  next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  verified_at TIMESTAMPTZ, created_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS central_drive_queue_idx ON central_drive_objects(status,next_attempt_at);
CREATE OR REPLACE FUNCTION retire_central_drive_object() RETURNS trigger AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    UPDATE central_drive_objects SET status='delete_pending',next_attempt_at=now() WHERE file_id=OLD.id;
    RETURN OLD;
  END IF;
  IF NEW.user_id IS DISTINCT FROM OLD.user_id OR NEW.content_purged_at IS NOT NULL
    OR (OLD.content_sha256 IS NOT NULL AND NEW.content_sha256 IS DISTINCT FROM OLD.content_sha256) THEN
    UPDATE central_drive_objects SET status='delete_pending',next_attempt_at=now() WHERE file_id=OLD.id;
  END IF;
  RETURN NEW;
END; $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS stored_files_retire_central_drive ON stored_files;
CREATE TRIGGER stored_files_retire_central_drive BEFORE DELETE OR UPDATE OF user_id,content_purged_at,content_sha256
  ON stored_files FOR EACH ROW EXECUTE FUNCTION retire_central_drive_object();
`;

function transport(refreshToken) {
  const client = new OAuth2Client(process.env.GOOGLE_DRIVE_OAUTH_CLIENT_ID,
    process.env.GOOGLE_DRIVE_OAUTH_CLIENT_SECRET);
  client.setCredentials({ refresh_token: refreshToken });
  const get = async (resource, params) => (await client.request({
    url: `https://www.googleapis.com/drive/v3/${resource}`, params,
    timeout: 30000, retry: false, responseType: 'json' })).data;
  return {
    identity: () => get('about', { fields: 'user(emailAddress),storageQuota(limit,usage)' }),
    async reserve() {
      const result = await get('files/generateIds', { count: 1, space: 'appDataFolder' });
      if (!/^[\w-]{10,200}$/.test(result.ids?.[0] || '')) throw new Error('invalid_reserved_id');
      return result.ids[0];
    },
    async upload(row, bytes) {
      // A reserved ID makes a crash after Google's commit safe to retry or delete.
      try {
        const remote = await get(`files/${row.remote_file_id}`, { fields: 'id,size,md5Checksum' });
        if (Number(remote.size) !== bytes.length || remote.md5Checksum !== crypto.createHash('md5').update(bytes).digest('hex'))
          throw new Error('existing_remote_mismatch');
        return remote;
      } catch (error) { if (error.response?.status !== 404) throw error; }
      return uploadResumable({ client, ownerKey: TOKEN_OWNER, root: path.join(ROOT, 'uploads'),
        metadata: { id: row.remote_file_id, name: `${row.id}.bin`, parents: ['appDataFolder'],
          appProperties: { kind: 'central-media', version: '1' } },
        bytes, mimeType: 'application/octet-stream' });
    },
    download: (row) => personal.downloadAppDataFile(refreshToken, row.remote_file_id, Number(row.file_size) + 1024),
    remove: id => personal.deleteAppDataFile(refreshToken, id),
  };
}

async function configure(pool, enabled = false) {
  const current = await pool.query('SELECT email FROM central_drive_account WHERE id=1');
  if (current.rows.length) throw new Error('Central storage is already configured; use its existing account');
  const { rows } = await pool.query(`SELECT c.user_id,c.encrypted_refresh_token
    FROM cloud_backup_accounts c JOIN users u ON u.id=c.user_id
    WHERE lower(u.email)=$1 AND c.provider='google_drive' AND c.status='connected'`, [ACCOUNT]);
  if (!rows[0]) throw new Error('The company Drive must be connected first');
  const token = personal.decryptRefreshToken(rows[0].encrypted_refresh_token, rows[0].user_id);
  const remote = transport(token), about = await remote.identity();
  if (about.user?.emailAddress?.toLowerCase() !== ACCOUNT) throw new Error('Unexpected Drive account');
  await personal.verifyAppDataAccess(token);
  await pool.query(`INSERT INTO central_drive_account(id,email,encrypted_token,enabled,quota,checked_at)
    VALUES(1,$1,$2,$3,$4,now())`, [ACCOUNT, personal.encryptRefreshToken(token, TOKEN_OWNER), enabled, about.storageQuota]);
  return { email: ACCOUNT, enabled, quota: about.storageQuota };
}

async function deliveryRecord(db, storagePath, { forProcessing = false } = {}) {
  // Check without raising SQL errors: readers can run inside an existing transaction.
  const ready = (await db.query("SELECT to_regclass('central_drive_objects') AS objects,to_regclass('central_drive_account') AS account")).rows[0];
  if (!ready?.objects || !ready?.account) return null;
  try {
    // Server scans may need retained bytes while delivery is blocked. Ownership,
    // purge and deletion checks still apply; public delivery always uses ELIGIBLE.
    const readable = forProcessing ? `sf.user_id IS NOT NULL AND sf.content_purged_at IS NULL
      AND NOT EXISTS(SELECT 1 FROM deleted_media_sources ds WHERE ds.storage_path=sf.storage_path)` : ELIGIBLE;
    const { rows } = await db.query(`SELECT sf.id,sf.user_id,sf.storage_path,sf.mime_type,sf.file_size,sf.content_sha256,
      o.remote_file_id,o.encrypted_sha256,o.encryption_metadata,o.encrypted_data_key,
      a.encrypted_token AS encrypted_refresh_token,TRUE AS central_storage
      FROM stored_files sf JOIN central_drive_objects o ON o.file_id=sf.id AND o.owner_id=sf.user_id
      JOIN central_drive_account a ON a.id=1
      WHERE sf.storage_path=$1 AND o.status='verified' AND o.plaintext_sha256=sf.content_sha256
        AND o.file_size=sf.file_size AND ${readable}`, [storagePath]);
    return rows.find(row => row.central_storage === true) || null;
  } catch (error) {
    // Legacy isolated tests/databases have no central migration yet.
    if (error.code === '42P01') return null;
    throw error;
  }
}

function decode(row, encrypted) {
  if (hash(encrypted) !== row.encrypted_sha256) throw new Error('central_ciphertext_mismatch');
  const metadata = row.encryption_metadata;
  const owner = row.owner_id || row.user_id;
  const fileId = row.file_id || row.id;
  if (metadata?.associatedData !== `central-v1/${owner}/${fileId}`) throw new Error('central_binding_mismatch');
  const plain = decryptBuffer({ version: 1, algorithm: metadata.algorithm,
    nonce: metadata.nonce, tag: metadata.tag, ciphertext: encrypted },
  unwrapVaultKey(row.encrypted_data_key, owner), metadata.associatedData);
  if (plain.length !== Number(row.file_size) || hash(plain) !== (row.plaintext_sha256 || row.content_sha256))
    throw new Error('central_plaintext_mismatch');
  return plain;
}
async function readFile(db, file, makeTransport = transport, options = {}) {
  const row = await deliveryRecord(db, file.storage_path, options);
  if (!row) return null;
  if (row.id !== file.id || row.user_id !== file.user_id) throw new Error('central_owner_mismatch');
  const remote = makeTransport(personal.decryptRefreshToken(row.encrypted_refresh_token, TOKEN_OWNER));
  return decode(row, await remote.download(row));
}

async function safePath(root, storagePath) {
  const base = await fs.realpath(root), absolute = path.resolve(base, storagePath);
  if (!absolute.startsWith(base + path.sep)) throw new Error('invalid_storage_path');
  try {
    if (!(await fs.realpath(absolute)).startsWith(base + path.sep)) throw new Error('invalid_storage_symlink');
  } catch (error) { if (error.code !== 'ENOENT') throw error; }
  return absolute;
}

function createCentralStorage({ getPool, uploadRoot, readSource, makeTransport = transport, spoolRoot = ROOT, lockKey = LOCK }) {
  let running = false;
  async function spool(row, plain, db) {
    const filename = path.join(spoolRoot, `${row.id}.enc`);
    if (row.encryption_metadata) {
      try {
        const bytes = await fs.readFile(filename);
        if (hash(bytes) !== row.encrypted_sha256) throw new Error('central_spool_mismatch');
        return bytes;
      } catch (error) { if (error.code !== 'ENOENT') throw error; }
      // A spool cannot be regenerated with a new nonce under the same remote ID.
      throw new Error('central_spool_missing');
    }
    const associatedData = `central-v1/${row.owner_id}/${row.file_id}`;
    const envelope = encryptBuffer(plain, unwrapVaultKey(row.encrypted_data_key, row.owner_id), associatedData);
    await fs.mkdir(spoolRoot, { recursive: true, mode: 0o700 });
    const temporary = `${filename}.${crypto.randomUUID()}.tmp`;
    await fs.writeFile(temporary, envelope.ciphertext, { mode: 0o600 });
    await fs.rename(temporary, filename);
    const metadata = { version: 1, algorithm: envelope.algorithm, nonce: envelope.nonce, tag: envelope.tag, associatedData };
    await db.query(`UPDATE central_drive_objects SET encryption_metadata=$2,encrypted_sha256=$3 WHERE id=$1`,
      [row.id, metadata, hash(envelope.ciphertext)]);
    row.encryption_metadata = metadata; row.encrypted_sha256 = hash(envelope.ciphertext);
    return envelope.ciphertext;
  }
  async function release(db, row, remote) {
    let absolute, plain, removed = false, committed = false;
    await db.query('BEGIN');
    try {
      const check = await db.query(`SELECT sf.id FROM stored_files sf
        JOIN central_drive_objects o ON o.file_id=sf.id
        WHERE sf.id=$1 AND sf.user_id=$2 AND sf.content_sha256=$3 AND sf.file_size=$4
          AND o.status='verified' AND ${ELIGIBLE}
          AND NOT EXISTS(SELECT 1 FROM media_backup_items m WHERE m.stored_file_id=sf.id AND m.status='uploading')
        FOR UPDATE OF sf`, [row.file_id, row.owner_id, row.plaintext_sha256, row.file_size]);
      if (!check.rows.length) { await db.query('ROLLBACK'); return false; }
      // Verify the live remote bytes immediately before freeing disk space.
      plain = decode(row, await remote.download(row));
      absolute = await safePath(uploadRoot, row.storage_path);
      try {
        const local = await fs.readFile(absolute);
        if (hash(local) !== row.plaintext_sha256) throw new Error('local_content_changed');
        await fs.unlink(absolute); removed = true;
      } catch (error) { if (error.code !== 'ENOENT') throw error; }
      await db.query(`UPDATE stored_files SET released_at=COALESCE(released_at,now()) WHERE id=$1`, [row.file_id]);
      await db.query('COMMIT'); committed = true;
      return true;
    } catch (error) {
      await db.query('ROLLBACK').catch(() => {});
      if (removed && !committed) await fs.writeFile(absolute, plain, { flag: 'wx', mode: 0o600 });
      throw error;
    }
  }
  async function runBatch({ limit = 5, fileId = null, releaseLocal = true, allowPaused = false } = {}) {
    if (running) return { busy: true };
    running = true;
    let db, locked = false;
    const result = { transferred: 0, released: 0, deleted: 0, failed: 0, bytes: 0 };
    try {
      const pool = await getPool(); db = await pool.connect();
      locked = (await db.query('SELECT pg_try_advisory_lock($1) AS locked', [lockKey])).rows[0].locked;
      if (!locked) return { busy: true };
      const account = (await db.query('SELECT * FROM central_drive_account WHERE id=1')).rows[0];
      if (!account) return result;
      const remote = makeTransport(personal.decryptRefreshToken(account.encrypted_token, TOKEN_OWNER));
      // The same lock covers uploads and cleanup, including crash recovery.
      const retired = await db.query(`SELECT * FROM central_drive_objects
        WHERE status='delete_pending' AND next_attempt_at<=now() LIMIT 20`);
      for (const row of retired.rows) {
        try {
          if (row.remote_file_id) await remote.remove(row.remote_file_id);
          await fs.rm(path.join(spoolRoot, `${row.id}.enc`), { force: true });
          await db.query('DELETE FROM central_drive_objects WHERE id=$1', [row.id]); result.deleted++;
        } catch {
          await db.query(`UPDATE central_drive_objects SET last_error='remote_delete_failed',
            next_attempt_at=now()+interval '5 minutes' WHERE id=$1`, [row.id]); result.failed++;
        }
      }
      if (!account.enabled && !allowPaused) return result;
      const about = await remote.identity();
      if (about.user?.emailAddress?.toLowerCase() !== ACCOUNT) throw new Error('central_account_mismatch');
      await db.query('UPDATE central_drive_account SET quota=$1,checked_at=now() WHERE id=1', [about.storageQuota]);
      let free = about.storageQuota?.limit ? BigInt(about.storageQuota.limit) - BigInt(about.storageQuota.usage) : null;
      for (let i = 0; i < limit; i++) {
        let object;
        try {
          await db.query('BEGIN');
          const candidates = await db.query(`SELECT sf.*,o.id AS object_id,o.status AS central_status
            FROM stored_files sf LEFT JOIN central_drive_objects o ON o.file_id=sf.id
            WHERE ${ELIGIBLE} AND ${CENTRAL_DESTINATION}
              AND ($1::uuid IS NULL OR sf.id=$1)
              AND (o.id IS NULL OR (o.status IN ('uploading','failed') AND o.next_attempt_at<=now())
                OR (o.status='verified' AND sf.released_at IS NULL AND o.next_attempt_at<=now()))
            ORDER BY (sf.released_at IS NULL) DESC,sf.created_at,sf.id LIMIT 1 FOR UPDATE OF sf SKIP LOCKED`, [fileId]);
          const file = candidates.rows[0];
          if (!file) { await db.query('ROLLBACK'); break; }
          if (free !== null && free < BigInt(file.file_size) + 104857600n && file.central_status !== 'verified') {
            await db.query('ROLLBACK'); result.quotaFull = true; break;
          }
          if (!file.object_id) {
            file.object_id = crypto.randomUUID();
            await db.query(`INSERT INTO central_drive_objects(id,file_id,owner_id,storage_path,encrypted_data_key)
              VALUES($1,$2,$3,$4,$5)`, [file.object_id, file.id, file.user_id, file.storage_path,
              wrapVaultKey(createVaultKey(), file.user_id)]);
          }
          object = (await db.query('SELECT * FROM central_drive_objects WHERE id=$1', [file.object_id])).rows[0];
          await db.query(`UPDATE central_drive_objects SET attempt_count=attempt_count+1,
            next_attempt_at=now()+interval '5 minutes',updated_at=now() WHERE id=$1`, [object.id]);
          await db.query('COMMIT');
          if (object.status !== 'verified') {
            // Prefer a previously committed upload after a restart, even if its spool vanished.
            let restored = null;
            if (object.remote_file_id && object.encryption_metadata) {
              try { restored = decode(object, await remote.download(object)); } catch (_) {}
            }
            if (!restored) {
              await safePath(uploadRoot, file.storage_path);
              const plain = await readSource(pool, uploadRoot, file);
              const plainHash = hash(plain);
              if (plain.length !== Number(file.file_size) || (file.content_sha256 && file.content_sha256 !== plainHash))
                throw new Error('source_checksum_mismatch');
              await db.query(`UPDATE stored_files SET content_sha256=$2 WHERE id=$1 AND content_sha256 IS NULL`, [file.id, plainHash]);
              object.plaintext_sha256 = plainHash; object.file_size = plain.length;
              await db.query('UPDATE central_drive_objects SET plaintext_sha256=$2,file_size=$3 WHERE id=$1', [object.id, plainHash, plain.length]);
              if (!object.remote_file_id) {
                object.remote_file_id = await remote.reserve();
                await db.query('UPDATE central_drive_objects SET remote_file_id=$2 WHERE id=$1', [object.id, object.remote_file_id]);
              }
              const encrypted = await spool(object, plain, db);
              await remote.upload(object, encrypted);
              restored = decode(object, await remote.download(object));
            }
            await db.query(`UPDATE central_drive_objects SET status=CASE WHEN status='delete_pending'
              THEN status ELSE 'verified' END,verified_at=now(),last_error=NULL,updated_at=now() WHERE id=$1`, [object.id]);
            object.status = 'verified'; result.transferred++; result.bytes += restored.length;
            if (free !== null) free -= BigInt(restored.length);
          }
          if (releaseLocal && await release(db, object, remote)) result.released++;
          await fs.rm(path.join(spoolRoot, `${object.id}.enc`), { force: true });
        } catch (error) {
          await db.query('ROLLBACK').catch(() => {});
          if (object) await db.query(`UPDATE central_drive_objects SET status=CASE WHEN status IN ('verified','delete_pending')
            THEN status ELSE 'failed' END,last_error=$2,
            next_attempt_at=now()+interval '5 minutes',updated_at=now() WHERE id=$1`, [object.id, failureReason(error)]);
          result.failed++;
        }
      }
      return result;
    } finally {
      if (locked && db) await db.query('SELECT pg_advisory_unlock($1)', [lockKey]).catch(() => {});
      if (db) db.release(); running = false;
    }
  }
  return { runBatch };
}

async function status(pool) {
  const account = (await pool.query('SELECT email,enabled,quota,checked_at FROM central_drive_account WHERE id=1')).rows[0];
  const counts = (await pool.query(`SELECT count(*) FILTER(WHERE status='verified')::int AS verified,
    COALESCE(sum(file_size) FILTER(WHERE status='verified'),0)::text AS bytes,
    count(*) FILTER(WHERE status='failed')::int AS failed,
    count(*) FILTER(WHERE status='delete_pending')::int AS pending_deletions FROM central_drive_objects`)).rows[0];
  const pending = (await pool.query(`SELECT count(*)::int AS count FROM stored_files sf
    WHERE ${ELIGIBLE} AND ${CENTRAL_DESTINATION}
      AND NOT EXISTS(SELECT 1 FROM central_drive_objects o WHERE o.file_id=sf.id AND o.status='verified')`)).rows[0].count;
  const personal = (await pool.query(`SELECT
    count(*) FILTER(WHERE to_jsonb(sf)->>'personal_storage_verified_at' IS NOT NULL)::int AS personal_verified,
    count(*) FILTER(WHERE to_jsonb(sf)->>'personal_storage_verified_at' IS NULL)::int AS personal_pending
    FROM stored_files sf WHERE to_jsonb(sf)->>'storage_tier'='personal' AND sf.content_purged_at IS NULL`)).rows[0];
  return { connected: Boolean(account), ...account, ...counts, pending, ...personal };
}
module.exports = { SCHEMA, ACCOUNT, TOKEN_OWNER, ELIGIBLE, configure, transport,
  deliveryRecord, readFile, decode, createCentralStorage, status };
