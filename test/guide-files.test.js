'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const express = require('express');
const jwt = require('jsonwebtoken');
const ExcelJS = require('exceljs');
const personalDrive = require('../server/personal-drive');
const { createVaultKey, wrapVaultKey, unwrapVaultKey } = require('../server/backup-vault-key');
const { encryptBuffer } = require('../server/media-backup-crypto');
const { PRIVATE_DIRECTORY, FILE_URL_BASE, guideFileId, loadOwnedGuideFile, readGuideFileBytes,
  persistGuideSpreadsheetReply, registerGuideFileRoutes, signedDownloadUrl, verifyDownloadToken } =
  require('../server/guide-files');

const OWNER = '11111111-1111-4111-8111-111111111111';
const OTHER = '22222222-2222-4222-8222-222222222222';
const GUIDE = '33333333-3333-4333-8333-333333333333';
const SOURCE = '44444444-4444-4444-8444-444444444444';
const SECRET = 'test-only-guide-download-secret-at-least-32-characters';
const spreadsheet = { title: 'חברי קבוצת הבדיקה', tables: [{ columns: ['שם', 'טלפון'],
  rows: [['חבר לדוגמה', '0500000001']] }] };
const digest = bytes => crypto.createHash('sha256').update(bytes).digest('hex');

// A transaction-aware in-memory database: the production SQL must bind the
// authenticated owner, and failed transactions never publish staged records.
function database({ connected = false, failAt, restore } = {}) {
  const state = { files: [], messages: [], backups: [], settings: [] };
  const calls = [];
  let released = 0;
  let staged = null;
  const client = {
    async query(sql, args = []) {
      calls.push({ sql, args });
      if (failAt && sql.includes(failAt)) throw new Error(`test failure: ${failAt}`);
      if (sql === 'BEGIN') { staged = structuredClone(state); return { rows: [] }; }
      if (sql === 'COMMIT') { Object.assign(state, staged); staged = null; return { rows: [] }; }
      if (sql === 'ROLLBACK') { staged = null; return { rows: [] }; }
      assert.ok(staged, 'writes are inside a transaction');
      if (sql.includes('INSERT INTO stored_files')) {
        const [id, user_id, original_name, storage_path, public_url, mime_type, file_size,
          context_id, content_sha256, details] = args;
        staged.files.push({ id, user_id, original_name, storage_path, public_url, mime_type,
          file_size, context_id, content_sha256, moderation_details: JSON.parse(details),
          file_type: 'document', moderation_status: 'approved', content_purged_at: null });
      } else if (sql.includes('FROM cloud_backup_accounts')) {
        assert.deepEqual(args, [OWNER]);
        return { rows: connected ? [{}] : [] };
      } else if (sql.includes('INSERT INTO user_backup_settings')) {
        assert.doesNotMatch(sql, /enabled\s*=\s*(?:true|\$)/i, 'explicit file save does not enable blanket backups');
        staged.settings.push({ user_id: args[0], encrypted_data_key: args[1], enabled: false });
      } else if (sql.includes('INSERT INTO media_backup_items')) {
        staged.backups.push({ user_id: args[0], stored_file_id: args[1], status: 'queued',
          plaintext_sha256: args[2], encryption_metadata: JSON.parse(args[3]) });
      } else if (sql.includes('INSERT INTO messages')) {
        const [sender_id, recipient_id, body, file_url, file_name, file_size, reply_to_id] = args;
        const message = { id: crypto.randomUUID(), created_at: new Date().toISOString(),
          sender_id, recipient_id, body, file_url, file_name, file_size, reply_to_id };
        staged.messages.push(message);
        return { rows: [message] };
      } else throw new Error(`Unexpected transaction query: ${sql}`);
      return { rows: [] };
    },
    release() { released++; },
  };
  const pool = {
    async connect() {
      if (failAt === 'connect') throw new Error('test failure: connect');
      return client;
    },
    async query(sql, args) {
      calls.push({ sql, args });
      if (sql.includes('FROM stored_files sf')) {
        assert.match(sql, /sf\.id=\$2 AND sf\.user_id=\$1/);
        assert.match(sql, /sf\.moderation_status='approved'/);
        assert.match(sql, /sf\.content_purged_at IS NULL/);
        assert.match(sql, /sf\.moderation_details->>'generatedBy'='system_guide'/);
        const file = state.files.find(file => file.id === args[1] && file.user_id === args[0] &&
          file.moderation_status === 'approved' && file.content_purged_at === null &&
          file.moderation_details.generatedBy === 'system_guide');
        return { rows: file ? [{ ...file, backup_status: state.backups.find(item => item.stored_file_id === file.id)?.status }] : [] };
      }
      if (sql.includes('FROM media_backup_items mbi')) {
        assert.match(sql, /mbi\.stored_file_id=\$2 AND mbi\.user_id=\$1/);
        assert.match(sql, /c\.status='connected'/);
        assert.match(sql, /mbi\.status='verified'/);
        return { rows: restore && args[0] === OWNER ? [restore] : [] };
      }
      throw new Error(`Unexpected read query: ${sql}`);
    },
  };
  return { pool, state, calls, get released() { return released; } };
}

async function tempRoot(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'guide-files-test-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  return root;
}

function backupKey(t) {
  const previous = process.env.BACKUP_TOKEN_ENCRYPTION_KEY;
  process.env.BACKUP_TOKEN_ENCRYPTION_KEY = 'guide-files-test-only-backup-master-key-at-least-32-characters';
  t.after(() => {
    if (previous === undefined) delete process.env.BACKUP_TOKEN_ENCRYPTION_KEY;
    else process.env.BACKUP_TOKEN_ENCRYPTION_KEY = previous;
  });
}

function persist(pool, uploadRoot, extra = {}) {
  return persistGuideSpreadsheetReply({ pool, uploadRoot, userId: OWNER, assistantId: GUIDE,
    sourceMessageId: SOURCE, spreadsheet, ...extra });
}

async function server(t, pool, uploadRoot) {
  const app = express();
  const router = express.Router();
  registerGuideFileRoutes(router, { getPool: async () => pool, uploadRoot, secret: SECRET,
    auth(req, res, next) {
      const id = req.headers.authorization?.replace(/^Bearer /, '');
      if (id !== OWNER && id !== OTHER) return res.status(401).json({ error: 'authentication required' });
      req.user = { id };
      next();
    },
  });
  // Match the app's public static upload serving: dot-directories stay hidden.
  router.use('/uploads', express.static(uploadRoot));
  app.use('/betshuva-app', router);
  const listener = await new Promise(resolve => {
    const listening = app.listen(0, '127.0.0.1', () => resolve(listening));
  });
  t.after(() => new Promise((resolve, reject) => {
    listener.closeAllConnections();
    listener.close(error => error ? reject(error) : resolve());
  }));
  return `http://127.0.0.1:${listener.address().port}`;
}

test('Excel file, user ownership and reply persist together with private file permissions', async t => {
  const root = await tempRoot(t);
  const db = database();
  const result = await persist(db.pool, root);
  assert.equal(result.backupStatus, 'not_connected');
  assert.equal(db.state.files.length, 1);
  assert.equal(db.state.messages.length, 1);
  assert.equal(db.state.backups.length, 0);
  const [file] = db.state.files;
  const [message] = db.state.messages;
  assert.equal(file.user_id, OWNER);
  assert.equal(file.context_id, GUIDE);
  assert.equal(file.moderation_details.sourceMessageId, SOURCE);
  assert.equal(file.moderation_details.rowCount, 1);
  assert.equal(message.sender_id, GUIDE);
  assert.equal(message.recipient_id, OWNER);
  assert.equal(message.reply_to_id, SOURCE);
  assert.equal(message.file_url, result.file.url);
  assert.equal(message.file_url, file.public_url);
  assert.equal(result.reply.id, message.id);
  assert.match(message.body, new RegExp(`betshuva://app/guide-file/${file.id}`));
  assert.match(message.body, /backup-settings/);
  assert.doesNotMatch(message.body, /[?&]token=/, 'chat keeps a permanent owner-authorized link, not an expiring token');
  const absolutePath = path.join(root, file.storage_path);
  const bytes = await fs.readFile(absolutePath);
  assert.equal(digest(bytes), file.content_sha256);
  assert.equal(bytes.length, file.file_size);
  assert.equal((await fs.stat(absolutePath)).mode & 0o777, 0o600);
  assert.equal((await fs.stat(path.join(root, PRIVATE_DIRECTORY))).mode & 0o777, 0o700);
  assert.equal((await new ExcelJS.Workbook().xlsx.load(bytes)).worksheets[0].getCell('B2').value, '0500000001');
  assert.equal(db.calls.at(-1).sql, 'COMMIT');
  assert.equal(db.released, 1);
});

test('connected Drive queues this explicit file save without enabling automatic backups', async t => {
  backupKey(t);
  const root = await tempRoot(t);
  const db = database({ connected: true });
  const result = await persist(db.pool, root);
  assert.equal(result.backupStatus, 'queued');
  assert.match(result.answer, /ממתין לשמירה/);
  assert.equal(db.state.backups.length, 1);
  assert.equal(db.state.backups[0].user_id, OWNER);
  assert.equal(db.state.backups[0].stored_file_id, result.file.id);
  assert.equal(db.state.backups[0].plaintext_sha256, db.state.files[0].content_sha256);
  assert.deepEqual(db.state.backups[0].encryption_metadata, { guideRequested: true });
  assert.equal(db.state.settings[0].enabled, false);
  assert.equal(unwrapVaultKey(db.state.settings[0].encrypted_data_key, OWNER).length, 32);
  assert.throws(() => unwrapVaultKey(db.state.settings[0].encrypted_data_key, OTHER));
});

test('connection, file-record, backup, message and commit failures clean local files and roll back every record', async t => {
  backupKey(t);
  for (const failAt of ['connect', 'INSERT INTO stored_files', 'INSERT INTO media_backup_items', 'INSERT INTO messages', 'COMMIT']) {
    await t.test(failAt, async t => {
      const root = await tempRoot(t);
      const db = database({ connected: true, failAt });
      await assert.rejects(persist(db.pool, root), /test failure/);
      assert.deepEqual(db.state, { files: [], messages: [], backups: [], settings: [] });
      assert.deepEqual(await fs.readdir(path.join(root, PRIVATE_DIRECTORY)), []);
      assert.equal(db.released, failAt === 'connect' ? 0 : 1);
      if (failAt !== 'connect') assert.equal(db.calls.at(-1).sql, 'ROLLBACK');
    });
  }
});

test('failed body sanitization also rolls back the file and reply', async t => {
  const root = await tempRoot(t);
  const db = database();
  await assert.rejects(persist(db.pool, root, { sanitizeText() { throw new Error('sanitizer failure'); } }), /sanitizer failure/);
  assert.equal(db.state.files.length, 0);
  assert.equal(db.state.messages.length, 0);
  assert.deepEqual(await fs.readdir(path.join(root, PRIVATE_DIRECTORY)), []);
});

test('a failed partial disk write does not leave an orphan file', async t => {
  const root = await tempRoot(t);
  const db = database();
  const open = fs.open.bind(fs);
  t.mock.method(fs, 'open', async (...args) => {
    const handle = await open(...args);
    const writeFile = handle.writeFile.bind(handle);
    t.mock.method(handle, 'writeFile', async bytes => {
      await writeFile(bytes.subarray(0, 16));
      throw Object.assign(new Error('test disk full'), { code: 'ENOSPC' });
    });
    return handle;
  });
  await assert.rejects(persist(db.pool, root), { code: 'ENOSPC' });
  assert.deepEqual(await fs.readdir(path.join(root, PRIVATE_DIRECTORY)), []);
  assert.deepEqual(db.state, { files: [], messages: [], backups: [], settings: [] });
});

test('an existing filename collision cannot overwrite or delete the previous file', async t => {
  const root = await tempRoot(t);
  const directory = path.join(root, PRIVATE_DIRECTORY);
  await fs.mkdir(directory, { mode: 0o700 });
  const previous = Buffer.from('previous file must remain intact');
  const filePath = path.join(directory, `${SOURCE}.xlsx`);
  await fs.writeFile(filePath, previous);
  t.mock.method(crypto, 'randomUUID', () => SOURCE);
  const db = database();
  await assert.rejects(persist(db.pool, root), { code: 'EEXIST' });
  assert.deepEqual(await fs.readFile(filePath), previous);
  assert.equal(db.state.files.length, 0);
});

test('owner lookup rejects other users, invalid identifiers, ordinary uploads, unapproved and purged files', async t => {
  const root = await tempRoot(t);
  const db = database();
  const saved = await persist(db.pool, root);
  assert.equal((await loadOwnedGuideFile(db.pool, OWNER, saved.file.id)).id, saved.file.id);
  assert.equal(await loadOwnedGuideFile(db.pool, OTHER, saved.file.id), null);
  const calls = db.calls.length;
  assert.equal(await loadOwnedGuideFile(db.pool, OWNER, '../private'), null);
  assert.equal(await loadOwnedGuideFile(db.pool, null, saved.file.id), null);
  assert.equal(db.calls.length, calls);
  const file = db.state.files[0];
  for (const overrides of [{ moderation_status: 'pending' }, { content_purged_at: '2026-01-01' },
    { moderation_details: { generatedBy: 'user_upload' } }]) {
    const previous = structuredClone(file);
    Object.assign(file, overrides);
    assert.equal(await loadOwnedGuideFile(db.pool, OWNER, file.id), null);
    Object.assign(file, previous);
  }
});

test('signed downloads reject wrong file, wrong purpose, wrong key, expiry and tampering', () => {
  const file = { id: SOURCE, user_id: OWNER };
  const signed = new URL(signedDownloadUrl(file, SECRET), 'http://localhost');
  const token = signed.searchParams.get('token');
  assert.equal(verifyDownloadToken(token, SOURCE, SECRET), OWNER);
  const claims = jwt.decode(token);
  assert.equal(claims.exp - claims.iat, 300);
  assert.throws(() => verifyDownloadToken(token, GUIDE, SECRET));
  assert.throws(() => verifyDownloadToken(token, SOURCE, `${SECRET}wrong`));
  const pieces = token.split('.');
  pieces[1] = Buffer.from(JSON.stringify({ ...claims, userId: OTHER })).toString('base64url');
  assert.throws(() => verifyDownloadToken(pieces.join('.'), SOURCE, SECRET));
  const signingKey = crypto.createHmac('sha256', SECRET).update('guide-file-download-v1').digest();
  for (const overrides of [{ purpose: 'login' }, { userId: 'invalid' }, { exp: Math.floor(Date.now() / 1000) - 10 },
    { aud: 'different-audience' }]) {
    const forged = jwt.sign({ ...claims, ...overrides }, signingKey, { algorithm: 'HS256' });
    assert.throws(() => verifyDownloadToken(forged, SOURCE, SECRET));
  }
  assert.throws(() => signedDownloadUrl(file, ''));
});

test('local HTTP routes return real Excel bytes only with owner auth or valid download capability', async t => {
  const root = await tempRoot(t);
  const db = database();
  const saved = await persist(db.pool, root);
  const base = await server(t, db.pool, root);
  const metaUrl = `${base}${FILE_URL_BASE}/${saved.file.id}`;
  assert.equal((await fetch(metaUrl)).status, 401);
  assert.equal((await fetch(metaUrl, { headers: { authorization: `Bearer ${OTHER}` } })).status, 404);
  const response = await fetch(metaUrl, { headers: { authorization: `Bearer ${OWNER}` } });
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('cache-control'), 'private, no-store');
  const metadata = await response.json();
  assert.equal(metadata.fileUrl, saved.file.url);
  assert.equal(metadata.backupStatus, 'not_connected');
  assert.equal(metadata.fileSize, saved.file.size);
  assert.equal((await fetch(`${base}${saved.file.url}`)).status, 401);
  assert.equal((await fetch(`${base}${saved.file.url}`, { headers: { authorization: `Bearer ${OTHER}` } })).status, 404);
  for (const [url, options] of [[`${base}${metadata.downloadUrl}`, {}],
    [`${base}${saved.file.url}`, { headers: { authorization: `Bearer ${OWNER}` } }]]) {
    const download = await fetch(url, options);
    assert.equal(download.status, 200);
    assert.equal(download.headers.get('content-type'), 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
    assert.equal(download.headers.get('cache-control'), 'private, no-store');
    assert.match(download.headers.get('content-disposition'), /^attachment;/);
    const bytes = Buffer.from(await download.arrayBuffer());
    assert.equal(digest(bytes), db.state.files[0].content_sha256);
    assert.equal((await new ExcelJS.Workbook().xlsx.load(bytes)).worksheets[0].getCell('B2').value, '0500000001');
  }
  assert.equal((await fetch(`${base}${saved.file.url}?token=bad`)).status, 401);
  const wrongFileUrl = metadata.downloadUrl.replace(saved.file.id, GUIDE);
  assert.equal((await fetch(`${base}${wrongFileUrl}`)).status, 401);
  for (const name of [PRIVATE_DIRECTORY, encodeURIComponent(PRIVATE_DIRECTORY)]) {
    assert.equal((await fetch(`${base}/betshuva-app/uploads/${name}/${saved.file.id}.xlsx`)).status, 404);
  }
});

test('download capabilities cannot bypass later ownership, moderation or purge checks', async t => {
  const root = await tempRoot(t);
  const db = database();
  const saved = await persist(db.pool, root);
  const base = await server(t, db.pool, root);
  const signedUrl = `${base}${signedDownloadUrl(db.state.files[0], SECRET)}`;
  for (const override of [{ user_id: OTHER }, { moderation_status: 'rejected' }, { content_purged_at: '2026-01-01' }]) {
    const previous = structuredClone(db.state.files[0]);
    Object.assign(db.state.files[0], override);
    assert.equal((await fetch(signedUrl)).status, 404);
    Object.assign(db.state.files[0], previous);
  }
});

test('local checksum and path validation reject tampering instead of serving arbitrary bytes', async t => {
  const root = await tempRoot(t);
  const db = database();
  await persist(db.pool, root);
  const file = db.state.files[0];
  await assert.rejects(readGuideFileBytes(db.pool, root, { ...file, storage_path: '../private.xlsx' }), /Invalid guide file path/);
  await assert.rejects(readGuideFileBytes(db.pool, root, { ...file, id: '../private' }), /Invalid guide file path/);
  await fs.writeFile(path.join(root, file.storage_path), Buffer.from('tampered workbook'));
  await assert.rejects(readGuideFileBytes(db.pool, root, file), /checksum mismatch/);
  assert.ok(!db.calls.some(call => call.sql.includes('FROM media_backup_items mbi')),
    'an existing corrupt local file is not silently replaced');
});

test('missing local file restores from owner-bound encrypted Drive data even when automatic backup is disabled', async t => {
  backupKey(t);
  const root = await tempRoot(t);
  const db = database();
  await persist(db.pool, root);
  const file = db.state.files[0];
  const original = await fs.readFile(path.join(root, file.storage_path));
  await fs.unlink(path.join(root, file.storage_path));
  const key = createVaultKey();
  const associatedData = `user:${OWNER}:file:${file.id}`;
  const encrypted = encryptBuffer(original, key, associatedData);
  const restore = { remote_file_id: 'mock-drive-file', encrypted_sha256: digest(encrypted.ciphertext),
    encryption_metadata: { algorithm: encrypted.algorithm, nonce: encrypted.nonce, tag: encrypted.tag, associatedData },
    encrypted_data_key: wrapVaultKey(key, OWNER),
    encrypted_refresh_token: personalDrive.encryptRefreshToken('mock-refresh-token', OWNER) };
  const restoredDb = database({ restore });
  t.mock.method(personalDrive, 'downloadAppDataFile', async (refreshToken, remoteId, maxBytes) => {
    assert.equal(refreshToken, 'mock-refresh-token');
    assert.equal(remoteId, restore.remote_file_id);
    assert.equal(maxBytes, original.length + 1024);
    return encrypted.ciphertext;
  });
  assert.deepEqual(await readGuideFileBytes(restoredDb.pool, root, file), original);
  assert.doesNotMatch(restoredDb.calls[0].sql, /s\.enabled\s*=\s*(?:true|TRUE)/);
  await assert.rejects(fs.access(path.join(root, file.storage_path)), { code: 'ENOENT' }, 'restoration is in memory');
  restore.encrypted_sha256 = '0'.repeat(64);
  await assert.rejects(readGuideFileBytes(restoredDb.pool, root, file), /backup checksum mismatch/);
  restore.encrypted_sha256 = digest(encrypted.ciphertext);
  await assert.rejects(readGuideFileBytes(restoredDb.pool, root, { ...file, content_sha256: '0'.repeat(64) }), /Restored guide file checksum mismatch/);
  restore.encrypted_data_key = wrapVaultKey(key, OTHER);
  await assert.rejects(readGuideFileBytes(restoredDb.pool, root, file));
});

test('guide file URL parser accepts only the permanent generated download path', () => {
  assert.equal(guideFileId(`${FILE_URL_BASE}/${SOURCE}/download`), SOURCE);
  for (const value of ['', null, `/uploads/${SOURCE}.xlsx`, `${FILE_URL_BASE}/../download`,
    `${FILE_URL_BASE}/${SOURCE}/download?token=example`, `https://example.com${FILE_URL_BASE}/${SOURCE}/download`]) {
    assert.equal(guideFileId(value), null);
  }
});
