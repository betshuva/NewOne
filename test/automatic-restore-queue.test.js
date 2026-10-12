'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const test = require('node:test');
const { encryptBuffer } = require('../server/media-backup-crypto');
const { wrapVaultKey } = require('../server/backup-vault-key');
const { createAutomaticRestoreQueue, createVerificationLock, SELECT_NEXT_SQL, SCHEMA } =
  require('../server/automatic-restore-queue');

const INITIAL_TIME = Date.parse('2026-10-13T09:00:00Z');
const sha256 = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const oldMasterKey = process.env.BACKUP_TOKEN_ENCRYPTION_KEY;
test.before(() => {
  process.env.BACKUP_TOKEN_ENCRYPTION_KEY =
    'automatic-restore-test-master-key-at-least-32-characters';
});
test.after(() => {
  if (oldMasterKey === undefined) delete process.env.BACKUP_TOKEN_ENCRYPTION_KEY;
  else process.env.BACKUP_TOKEN_ENCRYPTION_KEY = oldMasterKey;
});

function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
}

function backup(order = 0, changes = {}) {
  const id = crypto.randomUUID();
  const userId = crypto.randomUUID();
  const fileId = crypto.randomUUID();
  const key = crypto.randomBytes(32);
  const plain = Buffer.from('actual AES-GCM restore fixture ' + order);
  const associatedData = userId + '/' + fileId + '/server-v1';
  const envelope = encryptBuffer(plain, key, associatedData);
  const manifest = {
    version: 1, backupId: crypto.randomUUID(), storedFileId: fileId,
    byteLength: plain.length, remoteFileId: 'payload-' + id,
    plaintextSha256: sha256(plain), encryptedSha256: sha256(envelope.ciphertext),
    encryption: {
      algorithm: envelope.algorithm, nonce: envelope.nonce, tag: envelope.tag,
      associatedData, keySource: 'server_vault', keyVersion: 1,
    },
  };
  const row = {
    id, user_id: userId, stored_user_id: userId,
    stored_file_id: fileId, remote_file_id: manifest.remoteFileId,
    plaintext_sha256: manifest.plaintextSha256,
    content_sha256: manifest.plaintextSha256,
    encrypted_sha256: manifest.encryptedSha256,
    encryption_metadata: {
      ...manifest.encryption, manifestRemoteId: 'manifest-' + id,
      backupId: manifest.backupId,
    },
    file_size: String(plain.length),
    encrypted_data_key: wrapVaultKey(key, userId),
    encrypted_refresh_token: 'wrapped-token-' + id,
    provider: 'google_drive', status: 'verified', attempt_count: 7,
    restore_attempt_count: 0, restore_next_attempt_at: null,
    restore_last_error: null, restore_verified_at: null,
    release_scheduled_at: null, verified_at: new Date(INITIAL_TIME + order),
    personal_storage_verified_at: null,
    central_status: null, central_next_attempt_at: null,
    enabled: true, connected: true, storage_tier: 'service',
    released_at: null, content_purged_at: null,
    ...changes,
  };
  return { row, key, plain, payload: envelope.ciphertext, manifest };
}

// The fake store models committed queue state and external callbacks. SQL
// filtering itself is checked by the opt-in test against TEMP PostgreSQL tables.
function harness(records, options = {}) {
  let now = INITIAL_TIME;
  const selects = [];
  const downloads = [];
  const errors = [];
  const events = [];
  const releases = [];
  const updateOrder = [];
  const pool = {
    async query(sql, args = []) {
      const statement = typeof sql === 'string' ? sql : sql.text;
      if (statement === SELECT_NEXT_SQL) {
        const eligible = records.filter(({ row }) =>
          row.status === 'verified' && row.restore_verified_at === null &&
          row.provider === 'google_drive' && row.connected &&
          row.stored_user_id === row.user_id &&
          (row.enabled || row.encryption_metadata.guideRequested === true ||
            row.storage_tier === 'personal') &&
          row.encryption_metadata.keySource === 'server_vault' &&
          row.released_at === null && row.content_purged_at === null &&
          (row.restore_next_attempt_at === null ||
            row.restore_next_attempt_at.getTime() <= now));
        eligible.sort((a, b) =>
          (a.row.restore_next_attempt_at ?? a.row.verified_at) -
          (b.row.restore_next_attempt_at ?? b.row.verified_at));
        const row = eligible[0]?.row;
        selects.push(row?.id ?? null);
        return { rows: row ? [{ ...row }] : [], rowCount: row ? 1 : 0 };
      }
      const record = records.find(item => item.row.id === args[0]);
      assert.ok(record, 'queue updates only a selected fixture backup');
      const { row } = record;
      if (/restore_attempt_count\s*=\s*restore_attempt_count\s*\+\s*1/.test(statement)) {
        const oldAttempts = row.restore_attempt_count;
        row.restore_attempt_count++;
        row.restore_next_attempt_at =
          new Date(now + 5 * 60000 * 2 ** Math.min(oldAttempts, 3));
        row.restore_last_error = args[1];
        updateOrder.push('failed:' + row.id);
        return { rows: [], rowCount: 1 };
      }
      assert.match(statement, /restore_verified_at\s*=\s*now\(\)/);
      if (options.skipCommit) return { rows: [], rowCount: 0 };
      row.restore_verified_at = new Date(now);
      row.release_scheduled_at ??= new Date(now);
      if (statement.includes('personal_storage_verified_at') && row.storage_tier === 'personal') {
        row.personal_storage_verified_at ??= new Date(now);
      }
      if (statement.includes('central_drive_objects') && row.storage_tier === 'personal' &&
          row.central_status === 'verified') {
        row.central_status = 'delete_pending';
        row.central_next_attempt_at = new Date(now);
      }
      row.restore_attempt_count = 0;
      row.restore_next_attempt_at = null;
      row.restore_last_error = null;
      updateOrder.push('verified:' + row.id);
      return { rows: [{ stored_file_id: row.stored_file_id }], rowCount: 1 };
    },
  };
  const drive = {
    decryptRefreshToken(value, owner) {
      const record = records.find(item => item.row.user_id === owner);
      assert.equal(value, record.row.encrypted_refresh_token);
      return 'token-' + owner;
    },
    async downloadAppDataFile(token, remoteId, maxBytes) {
      const record = records.find(item => item.row.remote_file_id === remoteId ||
        item.row.encryption_metadata.manifestRemoteId === remoteId);
      assert.ok(record, 'downloads only known fixture remote objects');
      assert.equal(token, 'token-' + record.row.user_id);
      downloads.push(remoteId);
      if (remoteId === record.row.remote_file_id) {
        assert.ok(maxBytes >= record.payload.length);
      }
      if (options.download) {
        const answer = await options.download(record, remoteId);
        if (answer !== undefined) return answer;
      }
      return remoteId === record.row.remote_file_id
        ? Buffer.from(record.payload)
        : Buffer.from(JSON.stringify(record.manifest));
    },
  };
  const tick = createAutomaticRestoreQueue({
    getPool: async () => pool, drive,
    withVerification: options.withVerification,
    async onVerified(info) {
      const record = records.find(item => item.row.stored_file_id === info.storedFileId);
      assert.ok(record.row.restore_verified_at, 'success notification follows commit');
      assert.deepEqual(info, {
        storedFileId: record.row.stored_file_id, userId: record.row.user_id,
        bytes: record.plain.length,
      });
      events.push(info);
      if (options.onVerified) await options.onVerified(info);
    },
    async releaseVerified() {
      assert.ok(records.some(item => item.row.restore_verified_at),
        'release follows verified cloud round-trip');
      releases.push(updateOrder.slice());
      if (options.releaseVerified) await options.releaseVerified();
    },
    onError(error, context) { errors.push({ error, context }); },
  });
  return { tick, records, pool, selects, downloads, errors, events, releases,
    advance(milliseconds) { now += milliseconds; } };
}

test('a timed-out FIFO head backs off so the next valid backup verifies and releases', async () => {
  const head = backup(0);
  const next = backup(1);
  const app = harness([head, next], {
    async download(record) {
      if (record === head) {
        throw new DOMException('The operation was aborted due to timeout', 'TimeoutError');
      }
    },
  });
  const failed = await app.tick();
  assert.equal(failed.failed, 1);
  assert.equal(head.row.restore_verified_at, null);
  assert.equal(head.row.release_scheduled_at, null);
  assert.equal(head.row.restore_attempt_count, 1);
  assert.ok(head.row.restore_next_attempt_at.getTime() > INITIAL_TIME);
  assert.equal(head.row.status, 'verified');
  assert.equal(head.row.attempt_count, 7);
  assert.equal(app.releases.length, 0);
  assert.doesNotMatch(head.row.restore_last_error, /private|provider|token/);
  assert.equal(head.row.restore_last_error, 'RESTORE_TIMEOUT');
  assert.equal((await app.tick()).verified, 1);
  assert.ok(next.row.restore_verified_at);
  assert.ok(next.row.release_scheduled_at);
  assert.equal(app.events.length, 1);
  assert.equal(app.releases.length, 1);
  assert.deepEqual(app.selects, [head.row.id, next.row.id]);
});

test('corrupt or invalid cloud data never opens the local-release gate', async t => {
  const mutations = {
    'invalid JSON': record => { record.manifest = null; },
    'corrupt ciphertext': record => { record.payload[0] ^= 0xff; },
    'manifest encrypted hash mismatch': record => {
      record.manifest.encryptedSha256 = '0'.repeat(64);
    },
    'manifest plaintext hash mismatch': record => {
      record.manifest.plaintextSha256 = '0'.repeat(64);
    },
    'invalid AES-GCM authentication tag': record => {
      record.manifest.encryption.tag = Buffer.alloc(16).toString('base64');
    },
    'restored plaintext differs despite matching manifest and stored hashes': record => {
      record.row.plaintext_sha256 = '0'.repeat(64);
      record.manifest.plaintextSha256 = record.row.plaintext_sha256;
    },
    'vault key belongs to a different user': record => {
      record.row.encrypted_data_key = wrapVaultKey(record.key, crypto.randomUUID());
    },
    'plaintext byte length differs from the stored file': record => {
      record.row.file_size = String(record.plain.length + 1);
    },
    'stored-file source hash differs from valid backup and manifest hashes': record => {
      record.row.content_sha256 = '0'.repeat(64);
    },
  };
  for (const [name, mutate] of Object.entries(mutations)) {
    await t.test(name, async () => {
      const record = backup(0, { storage_tier: 'personal', enabled: false, central_status: 'verified' });
      mutate(record);
      const app = harness([record], {
        async download(item, remoteId) {
          if (name === 'invalid JSON' &&
              remoteId === item.row.encryption_metadata.manifestRemoteId) {
            return Buffer.from('{not-valid-json');
          }
        },
      });
      assert.equal((await app.tick()).failed, 1);
      assert.equal(record.row.restore_verified_at, null);
      assert.equal(record.row.release_scheduled_at, null);
      assert.equal(record.row.personal_storage_verified_at, null);
      assert.equal(record.row.central_status, 'verified');
      assert.equal(record.row.status, 'verified');
      assert.equal(record.row.attempt_count, 7);
      assert.equal(app.events.length, 0);
      assert.equal(app.releases.length, 0);
      assert.equal(record.row.restore_last_error, 'RESTORE_VERIFICATION_FAILED');
    });
  }
});

test('due retries use bounded backoff and a successful retry clears only restore state', async () => {
  const record = backup();
  let outage = true;
  const app = harness([record], {
    async download() {
      if (outage) throw new Error('synthetic provider outage');
    },
  });
  for (const minutes of [5, 10, 20, 40, 40]) {
    const before = record.row.restore_attempt_count;
    assert.equal((await app.tick()).failed, 1);
    assert.equal(record.row.restore_attempt_count, before + 1);
    const reads = app.downloads.length;
    assert.notEqual((await app.tick()).verified, 1);
    assert.equal(app.downloads.length, reads, 'retry is not polled before its due time');
    app.advance(minutes * 60000 - 1);
    await app.tick();
    assert.equal(app.downloads.length, reads, 'retry is still deferred one millisecond early');
    app.advance(1);
  }
  outage = false;
  assert.equal((await app.tick()).verified, 1);
  assert.equal(record.row.restore_attempt_count, 0);
  assert.equal(record.row.restore_next_attempt_at, null);
  assert.equal(record.row.restore_last_error, null);
  assert.equal(record.row.status, 'verified');
  assert.equal(record.row.attempt_count, 7);
  assert.equal(app.releases.length, 1);
});

test('disconnected or ineligible backups remain untouched while an eligible item advances', async () => {
  const changes = [
    { connected: false }, { enabled: false }, { provider: 'other' },
    { status: 'failed' }, { content_purged_at: new Date(INITIAL_TIME) },
    { released_at: new Date(INITIAL_TIME) },
    { restore_verified_at: new Date(INITIAL_TIME) },
    { stored_user_id: crypto.randomUUID() },
  ];
  const excluded = changes.map((change, i) => backup(i, change));
  const valid = backup(changes.length);
  const original = excluded.map(item => JSON.stringify(item.row));
  const app = harness([...excluded, valid]);
  assert.equal((await app.tick()).verified, 1);
  assert.deepEqual(excluded.map(item => JSON.stringify(item.row)), original);
  assert.ok(valid.row.restore_verified_at);
  assert.deepEqual(app.selects, [valid.row.id]);
  assert.equal(app.downloads.length, 2);
});

test('a due failed retry yields to older backups awaiting their first restore check', async () => {
  const retry = backup(0, {
    verified_at: new Date(INITIAL_TIME - 60 * 60000),
    restore_next_attempt_at: new Date(INITIAL_TIME - 1000),
    restore_attempt_count: 1,
  });
  const virgin = backup(1, { verified_at: new Date(INITIAL_TIME - 30 * 60000) });
  const app = harness([retry, virgin]);
  assert.equal((await app.tick()).verified, 1);
  assert.ok(virgin.row.restore_verified_at);
  assert.equal(retry.row.restore_verified_at, null);
  assert.equal((await app.tick()).verified, 1);
  assert.ok(retry.row.restore_verified_at);
  assert.deepEqual(app.selects, [virgin.row.id, retry.row.id]);
});

test('a fully verified personal backup records its storage proof before release', async () => {
  const record = backup(0, { storage_tier: 'personal', enabled: false, central_status: 'verified' });
  const app = harness([record]);
  assert.equal((await app.tick()).verified, 1);
  assert.ok(record.row.restore_verified_at);
  assert.ok(record.row.personal_storage_verified_at);
  assert.ok(record.row.release_scheduled_at);
  assert.equal(record.row.central_status, 'delete_pending');
  assert.ok(record.row.central_next_attempt_at);
  assert.equal(app.releases.length, 1);
});

test('verified restore releases the shared lock before a release callback acquires it', {
  timeout: 2000,
}, async () => {
  const record = backup();
  const withVerification = createVerificationLock();
  const stages = [];
  const app = harness([record], {
    withVerification,
    async releaseVerified() {
      await withVerification(async () => {
        assert.ok(record.row.restore_verified_at);
        stages.push('release');
      });
    },
  });
  assert.equal((await app.tick()).verified, 1);
  assert.deepEqual(stages, ['release']);
  assert.equal(app.errors.length, 0);
});

test('a concurrent tick does not duplicate in-flight downloads or release', async () => {
  const record = backup();
  const started = deferred();
  const download = deferred();
  const app = harness([record], {
    async download(item, remoteId) {
      if (remoteId === item.row.remote_file_id) {
        started.resolve();
        return download.promise;
      }
    },
  });
  const first = app.tick();
  await started.promise;
  const second = await app.tick();
  assert.ok(second.deferred || second.skipped);
  assert.equal(app.selects.length, 1);
  assert.equal(app.downloads.length, 2);
  assert.equal(app.releases.length, 0);
  download.resolve(Buffer.from(record.payload));
  assert.equal((await first).verified, 1);
  assert.equal(app.events.length, 1);
  assert.equal(app.releases.length, 1);
});

test('a deleted or changed candidate cannot emit success or run the release queue', async () => {
  const record = backup();
  const app = harness([record], { skipCommit: true });
  const result = await app.tick();
  assert.equal(result.skipped, true);
  assert.notEqual(result.verified, 1);
  assert.equal(record.row.restore_verified_at, null);
  assert.equal(app.events.length, 0);
  assert.equal(app.releases.length, 0);
});

test('an early manifest failure holds the worker until its payload download settles', async () => {
  const head = backup(0);
  const next = backup(1);
  const started = deferred();
  const payload = deferred();
  const app = harness([head, next], {
    async download(record, remoteId) {
      if (record !== head) return;
      if (remoteId === record.row.remote_file_id) {
        started.resolve();
        return payload.promise;
      }
      throw new Error('synthetic manifest 404');
    },
  });
  let firstSettled = false;
  const first = app.tick().then(result => { firstSettled = true; return result; });
  await started.promise;
  await new Promise(resolve => setImmediate(resolve));
  const settledBeforePartner = firstSettled;
  const second = await app.tick();
  payload.resolve(Buffer.from(head.payload));
  assert.equal((await first).failed, 1);
  assert.equal(settledBeforePartner, false, 'a failed sibling must not unlock active I/O');
  assert.ok(second.skipped || second.deferred);
  assert.equal(app.selects.length, 1);
  assert.equal((await app.tick()).verified, 1);
  assert.ok(next.row.restore_verified_at);
});

test('failure after the verification commit never retries an already verified backup', async t => {
  for (const callback of ['onVerified', 'releaseVerified']) {
    await t.test(callback, async () => {
      const record = backup();
      const app = harness([record], {
        [callback]: async () => { throw new Error('synthetic callback failure'); },
      });
      assert.equal((await app.tick()).verified, 1);
      assert.ok(record.row.restore_verified_at);
      assert.equal(record.row.restore_attempt_count, 0);
      assert.equal(record.row.restore_last_error, null);
      assert.equal(app.errors.at(-1).context.stage, 'post_verification');
      const reads = app.downloads.length;
      await app.tick();
      assert.equal(app.downloads.length, reads);
    });
  }
});

test('queue SQL excludes future retries, disconnected users and ineligible files', {
  skip: process.env.RUN_DB_TESTS !== '1',
}, async t => {
  const { Client } = require('pg');
  const db = new Client({
    connectionString: process.env.DATABASE_URL,
    ssl: process.env.DB_SSL === 'true'
      ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' }
      : false,
  });
  await db.connect();
  t.after(() => db.end());
  // All writes below affect session-local TEMP tables. There is no public
  // fallback, no live records and no production worker invocation.
  await db.query('SET search_path=pg_temp');
  await db.query([
    'CREATE TEMP TABLE stored_files(id uuid PRIMARY KEY,user_id uuid,file_size bigint,content_sha256 text,',
    "storage_tier text DEFAULT 'service',content_purged_at timestamptz,released_at timestamptz,",
    'release_scheduled_at timestamptz,personal_storage_verified_at timestamptz);',
    'CREATE TEMP TABLE user_backup_settings(user_id uuid PRIMARY KEY,enabled boolean,',
    'encrypted_data_key text);',
    'CREATE TEMP TABLE cloud_backup_accounts(user_id uuid,provider text,status text,',
    'encrypted_refresh_token text);',
    'CREATE TEMP TABLE central_drive_objects(id uuid PRIMARY KEY,file_id uuid,status text,next_attempt_at timestamptz);',
    'CREATE TEMP TABLE media_backup_items(id uuid PRIMARY KEY,user_id uuid,stored_file_id uuid,',
    'provider text,status text,remote_file_id text,plaintext_sha256 text,encrypted_sha256 text,',
    'encryption_metadata jsonb,verified_at timestamptz,restore_verified_at timestamptz,',
    'updated_at timestamptz DEFAULT now(),attempt_count integer DEFAULT 7);',
  ].join('\n'));
  await db.query(SCHEMA);
  const records = [];
  const seed = async (changes = {}) => {
    const record = backup(records.length, changes);
    records.push(record);
    const row = record.row;
    await db.query('INSERT INTO stored_files(id,user_id,file_size,content_sha256,storage_tier,content_purged_at,released_at) '
      + 'VALUES($1,$2,$3,$4,$5,$6,$7)',
      [row.stored_file_id,row.stored_user_id,row.file_size,row.content_sha256,row.storage_tier,
        row.content_purged_at,row.released_at]);
    await db.query('INSERT INTO user_backup_settings VALUES($1,$2,$3)',
      [row.user_id,row.enabled,row.encrypted_data_key]);
    await db.query('INSERT INTO cloud_backup_accounts VALUES($1,$2,$3,$4)',
      [row.user_id,row.provider,row.connected ? 'connected' : 'error',
        row.encrypted_refresh_token]);
    await db.query('INSERT INTO media_backup_items(id,user_id,stored_file_id,provider,status,'
      + 'remote_file_id,plaintext_sha256,encrypted_sha256,encryption_metadata,verified_at,'
      + 'restore_verified_at,restore_next_attempt_at) VALUES'
      + '($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)',
    [row.id,row.user_id,row.stored_file_id,row.provider,row.status,row.remote_file_id,
      row.plaintext_sha256,row.encrypted_sha256,JSON.stringify(row.encryption_metadata),
      row.verified_at,row.restore_verified_at,row.restore_next_attempt_at]);
    if (row.central_status !== null) {
      await db.query('INSERT INTO central_drive_objects VALUES($1,$2,$3,NULL)',
        [crypto.randomUUID(),row.stored_file_id,row.central_status]);
    }
    return record;
  };
  await seed({ connected: false });
  await seed({ enabled: false });
  await seed({ provider: 'other' });
  await seed({ status: 'failed' });
  await seed({ content_purged_at: new Date() });
  await seed({ released_at: new Date() });
  await seed({ stored_user_id: crypto.randomUUID() });
  await seed({ restore_verified_at: new Date() });
  await seed({ restore_next_attempt_at: new Date(Date.now() + 3600000) });
  const valid = await seed();
  assert.equal((await db.query(SELECT_NEXT_SQL)).rows[0].id, valid.row.id);
  await db.query('UPDATE media_backup_items SET restore_verified_at=now() WHERE id=$1',
    [valid.row.id]);
  const personal = await seed({ enabled: false, storage_tier: 'personal' });
  assert.equal((await db.query(SELECT_NEXT_SQL)).rows[0].id, personal.row.id);
  await db.query('UPDATE media_backup_items SET restore_verified_at=now() WHERE id=$1',
    [personal.row.id]);
  const guide = await seed({ enabled: false });
  await db.query("UPDATE media_backup_items SET encryption_metadata=encryption_metadata || "
    + "'{\"guideRequested\":true}'::jsonb WHERE id=$1", [guide.row.id]);
  assert.equal((await db.query(SELECT_NEXT_SQL)).rows[0].id, guide.row.id);
  await db.query('UPDATE media_backup_items SET restore_verified_at=now() WHERE id=$1',
    [guide.row.id]);

  const failedHead = await seed();
  const nextGood = await seed({ storage_tier: 'personal', enabled: false, central_status: 'verified' });
  let releaseCalls = 0;
  const worker = createAutomaticRestoreQueue({
    getPool: async () => db,
    drive: {
      decryptRefreshToken(token, owner) {
        const record = records.find(item => item.row.user_id === owner);
        assert.equal(token, record.row.encrypted_refresh_token);
        return owner;
      },
      async downloadAppDataFile(owner, remoteId) {
        const record = records.find(item => item.row.user_id === owner);
        if (record === failedHead) {
          throw new DOMException('The operation was aborted due to timeout', 'TimeoutError');
        }
        return remoteId === record.row.remote_file_id
          ? Buffer.from(record.payload)
          : Buffer.from(JSON.stringify(record.manifest));
      },
    },
    releaseVerified: async () => { releaseCalls++; },
  });
  assert.equal((await worker()).failed, 1);
  const retry = (await db.query('SELECT restore_attempt_count,restore_next_attempt_at,now() AS current_time, '
    + 'restore_last_error,status,attempt_count,restore_verified_at FROM media_backup_items WHERE id=$1',
  [failedHead.row.id])).rows[0];
  assert.equal(retry.restore_attempt_count, 1);
  assert.equal(retry.restore_last_error, 'RESTORE_TIMEOUT');
  assert.equal(retry.status, 'verified');
  assert.equal(retry.attempt_count, 7);
  assert.equal(retry.restore_verified_at, null);
  const minutesUntilRetry = (retry.restore_next_attempt_at - retry.current_time) / 60000;
  assert.ok(minutesUntilRetry > 4.9 && minutesUntilRetry <= 5,
    'actual PostgreSQL retry time must be five minutes after the failure');
  assert.equal((await worker()).verified, 1);
  const verified = (await db.query('SELECT mbi.restore_verified_at,mbi.restore_attempt_count, '
    + 'mbi.restore_next_attempt_at,mbi.restore_last_error,sf.release_scheduled_at,sf.personal_storage_verified_at '
    + 'FROM media_backup_items mbi JOIN stored_files sf ON sf.id=mbi.stored_file_id WHERE mbi.id=$1',
  [nextGood.row.id])).rows[0];
  assert.ok(verified.restore_verified_at);
  assert.ok(verified.release_scheduled_at);
  assert.ok(verified.personal_storage_verified_at);
  const retired = (await db.query('SELECT status,next_attempt_at FROM central_drive_objects WHERE file_id=$1',
    [nextGood.row.stored_file_id])).rows[0];
  assert.equal(retired.status, 'delete_pending');
  assert.ok(retired.next_attempt_at);
  assert.equal(verified.restore_attempt_count, 0);
  assert.equal(verified.restore_next_attempt_at, null);
  assert.equal(verified.restore_last_error, null);
  assert.equal(releaseCalls, 1);
  await db.query('UPDATE media_backup_items SET restore_next_attempt_at=now(),restore_attempt_count=1 WHERE id=$1',
    [failedHead.row.id]);
  assert.equal((await db.query(SELECT_NEXT_SQL)).rows[0].id, failedHead.row.id,
    'a due retry becomes eligible again after later successful items');
  for (const minutes of [10, 20, 40, 40]) {
    await db.query('UPDATE media_backup_items SET restore_next_attempt_at=now() WHERE id=$1',
      [failedHead.row.id]);
    assert.equal((await worker()).failed, 1);
    const persisted = (await db.query('SELECT restore_next_attempt_at,now() AS current_time '
      + 'FROM media_backup_items WHERE id=$1', [failedHead.row.id])).rows[0];
    const delay = (persisted.restore_next_attempt_at - persisted.current_time) / 60000;
    assert.ok(delay > minutes - .1 && delay <= minutes,
      'PostgreSQL persists the expected bounded retry delay of ' + minutes + ' minutes');
    assert.equal(releaseCalls, 1);
  }
  await db.query("UPDATE media_backup_items SET restore_next_attempt_at=now()+interval '40 minutes' WHERE id=$1",
    [failedHead.row.id]);
  const corrupt = await seed();
  corrupt.payload[0] ^= 0xff;
  assert.equal((await worker()).failed, 1);
  const retained = (await db.query('SELECT mbi.restore_verified_at,mbi.status,mbi.attempt_count, '
    + 'sf.release_scheduled_at FROM media_backup_items mbi '
    + 'JOIN stored_files sf ON sf.id=mbi.stored_file_id WHERE mbi.id=$1',
  [corrupt.row.id])).rows[0];
  assert.equal(retained.restore_verified_at, null);
  assert.equal(retained.release_scheduled_at, null);
  assert.equal(retained.status, 'verified');
  assert.equal(retained.attempt_count, 7);
  assert.equal(releaseCalls, 1, 'corrupt ciphertext never causes a second release');

  const sourceMismatch = await seed({ storage_tier: 'personal', enabled: false,
    central_status: 'verified', content_sha256: '0'.repeat(64) });
  assert.equal((await worker()).failed, 1);
  const mismatched = (await db.query('SELECT sf.personal_storage_verified_at,sf.release_scheduled_at, '
    + 'mbi.restore_verified_at,o.status AS central_status FROM stored_files sf '
    + 'JOIN media_backup_items mbi ON mbi.stored_file_id=sf.id '
    + 'JOIN central_drive_objects o ON o.file_id=sf.id WHERE sf.id=$1',
  [sourceMismatch.row.stored_file_id])).rows[0];
  assert.equal(mismatched.restore_verified_at, null);
  assert.equal(mismatched.personal_storage_verified_at, null);
  assert.equal(mismatched.release_scheduled_at, null);
  assert.equal(mismatched.central_status, 'verified');
  assert.equal(releaseCalls, 1, 'valid backup bytes cannot release a different original file');

  const dueRetry = await seed();
  const awaitingFirstCheck = await seed();
  await db.query("UPDATE media_backup_items SET verified_at=now()-interval '1 hour', "
    + "restore_next_attempt_at=now()-interval '1 second',restore_attempt_count=1 WHERE id=$1",
  [dueRetry.row.id]);
  await db.query("UPDATE media_backup_items SET verified_at=now()-interval '30 minutes', "
    + 'restore_next_attempt_at=NULL WHERE id=$1', [awaitingFirstCheck.row.id]);
  assert.equal((await db.query(SELECT_NEXT_SQL)).rows[0].id, awaitingFirstCheck.row.id,
    'the retry becomes due without jumping ahead of an older first-time check');
  await db.query('UPDATE media_backup_items SET restore_verified_at=now() WHERE id=$1',
    [awaitingFirstCheck.row.id]);
  assert.equal((await db.query(SELECT_NEXT_SQL)).rows[0].id, dueRetry.row.id,
    'the due retry runs after the waiting first-time check is complete');
});
