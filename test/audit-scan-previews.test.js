'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const { Client, Pool } = require('pg');
const sharp = require('sharp');
const { ensureAuditScanPreviewSchema, saveAuditScanPreview, purgeExpiredAuditScanPreviews, registerAuditScanPreviewRoutes, attachOperationPreviews } =
  require('../server/audit-scan-previews');

const databaseUrl = process.env.AUDIT_SCAN_PREVIEW_TEST_DATABASE_URL || process.env.DATABASE_URL;
const dbOptions = { skip: process.env.RUN_DB_TESTS !== '1' || !databaseUrl };
const jpeg = (color = 'red', width = 100, height = 80) => sharp({ create: {
  width, height, channels: 3, background: color,
} }).jpeg().toBuffer();

function routes(pool) {
  let registered;
  const adminMiddleware = (_req, _res, next) => next();
  registerAuditScanPreviewRoutes({ get: (path, ...handlers) => { registered = { path, handlers }; } },
    { getPool: async () => pool, adminMiddleware });
  const call = async ({ id = '1', size, user = { id: randomUUID() }, adminPerm = 'view' } = {}) => {
    const response = { statusCode: 200, headers: {},
      set(key, value) { this.headers[key] = value; return this; },
      status(value) { this.statusCode = value; return this; },
      json(value) { this.body = value; return this; },
      send(value) { this.body = value; return this; },
    };
    await registered.handlers.at(-1)({ params: { id }, query: size === undefined ? {} : { size }, user, adminPerm }, response);
    return response;
  };
  return { registered, adminMiddleware, call };
}

async function fixture(t) {
  const url = new URL(databaseUrl);
  assert.ok(['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname), 'Preview tests require a disposable local database');
  assert.match(url.pathname, /test/i, 'Preview tests require an explicitly named test database');
  const owner = new Client({ connectionString: url.href, ssl: false });
  await owner.connect();
  const schema = `scan_preview_test_${randomUUID().replaceAll('-', '')}`;
  await owner.query(`CREATE SCHEMA "${schema}"`);
  const pool = new Pool({ connectionString: url.href, ssl: false,
    options: `-c search_path=${schema}`, max: 8 });
  t.after(async () => {
    await pool.end();
    await owner.query(`DROP SCHEMA "${schema}" CASCADE`);
    await owner.end();
  });
  await pool.query(`CREATE TABLE stored_files(id uuid PRIMARY KEY,user_id uuid,file_type text,
    moderation_status text,content_purged_at timestamptz,blocked_content_expires_at timestamptz);
    CREATE TABLE audit_events(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,operation_id uuid,details jsonb NOT NULL);`);
  await ensureAuditScanPreviewSchema(pool);
  await ensureAuditScanPreviewSchema(pool);
  const file = async overrides => {
    const id = randomUUID();
    await pool.query(`INSERT INTO stored_files(id,user_id,file_type,moderation_status,content_purged_at,blocked_content_expires_at)
      VALUES($1,$2,$6,$3,$4,$5)`, [id, randomUUID(), overrides?.status || 'approved',
      overrides?.purgedAt || null, overrides?.expiresAt || null, overrides?.fileType || 'image']);
    return id;
  };
  const event = async (details, operationId = null) => (await pool.query('INSERT INTO audit_events(details,operation_id) VALUES($1,$2) RETURNING id',
    [JSON.stringify(details), operationId])).rows[0].id;
  return { pool, schema, file, event, ...routes(pool) };
}

test('preview conversion produces bounded metadata-free JPEGs while preserving original bytes', async () => {
  const original = await sharp({ create: { width: 1600, height: 1200, channels: 4,
    background: { r: 255, g: 0, b: 0, alpha: 0.5 } } }).png().withMetadata({ orientation: 6 }).toBuffer();
  const unchanged = Buffer.from(original), savedId = randomUUID();
  let saved;
  const pool = { query: async (_sql, values) => { saved = values; return { rows: [{ id: savedId }] }; } };
  assert.equal(await saveAuditScanPreview(pool, { storedFileId: randomUUID(), buffer: original }), savedId);
  assert.deepEqual(original, unchanged);
  const thumbnail = saved[3], image = saved[4];
  assert.ok(image.length <= 512 * 1024);
  assert.ok(thumbnail.length <= 24 * 1024);
  const fullInfo = await sharp(image).metadata(), thumbInfo = await sharp(thumbnail).metadata();
  assert.equal(fullInfo.format, 'jpeg');
  assert.equal(thumbInfo.format, 'jpeg');
  assert.ok(fullInfo.width <= 768 && fullInfo.height <= 768);
  assert.ok(thumbInfo.width <= 120 && thumbInfo.height <= 90);
  assert.equal(fullInfo.channels, 3);
  assert.equal(fullInfo.exif, undefined);
  assert.equal(fullInfo.icc, undefined);
  assert.equal(fullInfo.orientation, undefined);
  assert.equal(thumbInfo.exif, undefined);
});

test('invalid identifiers and bounded input validation avoid database writes', async () => {
  let calls = 0;
  const pool = { query: async () => { calls++; throw new Error('must not access database'); } };
  for (const args of [
    { storedFileId: 'invalid', buffer: Buffer.from('image') },
    { storedFileId: randomUUID(), buffer: null },
    { storedFileId: randomUUID(), buffer: Buffer.alloc(0) },
    { storedFileId: randomUUID(), buffer: Buffer.alloc(50 * 1024 * 1024 + 1) },
  ]) assert.equal(await saveAuditScanPreview(pool, args), null);
  assert.equal(calls, 0);
});

test('preview routes require the existing admin middleware and validated actor, event and size', async () => {
  let queries = 0;
  const f = routes({ query: async () => { queries++; return { rows: [] }; } });
  assert.equal(f.registered.path, '/api/admin/audit/events/:id/preview');
  assert.equal(f.registered.handlers[0], f.adminMiddleware);
  for (const request of [{ user: null }, { user: { id: 'not-a-user' } }, { adminPerm: '' },
    { adminPerm: 'admin' }, { adminPerm: 'EDIT' }]) assert.equal((await f.call(request)).statusCode, 403);
  for (const id of ['0', '-1', '1.0', '1e2', '9223372036854775808', "1' OR 1=1", ''])
    assert.equal((await f.call({ id })).statusCode, 400);
  for (const size of ['original', '../full', ['full']]) assert.equal((await f.call({ size })).statusCode, 400);
  assert.equal(queries, 0);
});

test('returned preview bytes have private no-store headers and no path or credential metadata', async () => {
  const bytes = await jpeg();
  const f = routes({ query: async () => ({ rows: [{ bytes }] }) });
  for (const size of ['thumb', 'full']) {
    const result = await f.call({ size, adminPerm: 'edit' });
    assert.equal(result.statusCode, 200);
    assert.deepEqual(result.body, bytes);
    assert.equal(result.headers['Content-Type'], 'image/jpeg');
    assert.match(result.headers['Cache-Control'], /private.*no-store/);
    assert.equal(result.headers['X-Content-Type-Options'], 'nosniff');
    assert.equal(result.headers['Referrer-Policy'], 'no-referrer');
    assert.equal(result.headers['Content-Disposition'], 'inline; filename="scan-preview.jpg"');
  }
});

test('database previews deduplicate concurrently per source and serve the referenced event image', dbOptions, async t => {
  const f = await fixture(t), storedFileId = await f.file(), bytes = await jpeg();
  const ids = await Promise.all(Array.from({ length: 8 }, () => saveAuditScanPreview(f.pool, { storedFileId, buffer: bytes })));
  assert.ok(ids.every(id => typeof id === 'string'));
  assert.equal(new Set(ids).size, 1);
  assert.equal((await f.pool.query('SELECT count(*) FROM audit_scan_previews')).rows[0].count, '1');
  const otherFile = await f.file();
  const otherId = await saveAuditScanPreview(f.pool, { storedFileId: otherFile, buffer: bytes });
  assert.notEqual(otherId, ids[0]);
  const id = await f.event({ scanPreviewId: ids[0], storedFileId });
  const row = (await f.pool.query('SELECT * FROM audit_scan_previews WHERE id=$1', [ids[0]])).rows[0];
  assert.deepEqual((await f.call({ id })).body, row.thumbnail);
  assert.deepEqual((await f.call({ id, size: 'full' })).body, row.image);
});

test('missing or deleted events, foreign preview substitution and invalid linkage never reveal bytes', dbOptions, async t => {
  const f = await fixture(t), firstFile = await f.file(), secondFile = await f.file();
  const firstPreview = await saveAuditScanPreview(f.pool, { storedFileId: firstFile, buffer: await jpeg('red') });
  const secondPreview = await saveAuditScanPreview(f.pool, { storedFileId: secondFile, buffer: await jpeg('blue') });
  const id = await f.event({ storedFileId: firstFile, scanPreviewId: firstPreview });
  assert.equal((await f.call({ id })).statusCode, 200);
  for (const details of [
    { storedFileId: firstFile, scanPreviewId: secondPreview },
    { storedFileId: secondFile, scanPreviewId: firstPreview },
    { scanPreviewId: firstPreview }, { storedFileId: firstFile },
    { storedFileId: firstFile, scanPreviewId: 'invalid-uuid' },
    { storedFileId: 'invalid-uuid', scanPreviewId: firstPreview },
  ]) {
    const mismatched = await f.event(details);
    assert.equal((await f.call({ id: mismatched })).statusCode, 404);
  }
  await f.pool.query('DELETE FROM audit_events WHERE id=$1', [id]);
  assert.equal((await f.call({ id })).statusCode, 404);
  assert.equal((await f.call({ id: '9223372036854775807' })).statusCode, 404);
});

test('purging or deleting source media physically removes all associated previews', dbOptions, async t => {
  const f = await fixture(t), storedFileId = await f.file();
  const preview = await saveAuditScanPreview(f.pool, { storedFileId, buffer: await jpeg() });
  const id = await f.event({ storedFileId, scanPreviewId: preview });
  await f.pool.query('UPDATE stored_files SET content_purged_at=now() WHERE id=$1', [storedFileId]);
  assert.equal((await f.pool.query('SELECT count(*) FROM audit_scan_previews')).rows[0].count, '0');
  assert.equal((await f.call({ id, size: 'full' })).statusCode, 404);
  assert.equal(await saveAuditScanPreview(f.pool, { storedFileId, buffer: await jpeg() }), null);
  const anotherFile = await f.file();
  await saveAuditScanPreview(f.pool, { storedFileId: anotherFile, buffer: await jpeg() });
  await f.pool.query('DELETE FROM stored_files WHERE id=$1', [anotherFile]);
  assert.equal((await f.pool.query('SELECT count(*) FROM audit_scan_previews')).rows[0].count, '0');
});

test('expired blocked media and missing source rows cannot create or serve previews', dbOptions, async t => {
  const f = await fixture(t), bytes = await jpeg();
  const missing = randomUUID();
  const expired = await f.file({ status: 'rejected', expiresAt: new Date(Date.now() - 10000) });
  const purged = await f.file({ purgedAt: new Date() });
  for (const storedFileId of [missing, expired, purged])
    assert.equal(await saveAuditScanPreview(f.pool, { storedFileId, buffer: bytes }), null);
  const pendingExpiry = await f.file({ fileType: 'video', status: 'rejected', expiresAt: new Date(Date.now() + 60000) });
  const preview = await saveAuditScanPreview(f.pool, { storedFileId: pendingExpiry, buffer: bytes });
  const id = await f.event({ storedFileId: pendingExpiry, scanPreviewId: preview });
  assert.equal((await f.call({ id })).statusCode, 200);
  await f.pool.query("UPDATE stored_files SET blocked_content_expires_at=now()-interval '1 second' WHERE id=$1", [pendingExpiry]);
  for (const size of ['thumb', 'full']) assert.equal((await f.call({ id, size })).statusCode, 404);
});

test('scheduled preview purge deletes expired bytes while preserving current previews and audit history', dbOptions, async t => {
  const f = await fixture(t);
  const expiringFile = await f.file({ fileType: 'video', status: 'rejected', expiresAt: new Date(Date.now() + 60000) });
  const currentFile = await f.file();
  const futureFile = await f.file({ status: 'rejected', expiresAt: new Date(Date.now() + 60000) });
  const previews = [];
  for (const [storedFileId, color] of [[expiringFile, 'red'], [currentFile, 'blue'], [futureFile, 'green']])
    previews.push(await saveAuditScanPreview(f.pool, { storedFileId, buffer: await jpeg(color) }));
  const eventId = await f.event({ storedFileId: expiringFile, scanPreviewId: previews[0] });
  const before = (await f.pool.query('SELECT id,thumbnail,image FROM audit_scan_previews ORDER BY id')).rows;
  assert.equal(before.length, 3);
  await f.pool.query("UPDATE stored_files SET blocked_content_expires_at=clock_timestamp()-interval '1 second' WHERE id=$1", [expiringFile]);
  assert.equal((await purgeExpiredAuditScanPreviews(f.pool)).rowCount, 1);
  const after = (await f.pool.query('SELECT id,thumbnail,image FROM audit_scan_previews ORDER BY id')).rows;
  assert.deepEqual(after, before.filter(row => row.id !== previews[0]));
  assert.equal((await f.pool.query('SELECT count(*) FROM stored_files')).rows[0].count, '3');
  assert.equal((await f.pool.query('SELECT count(*) FROM audit_events WHERE id=$1', [eventId])).rows[0].count, '1');
  assert.equal((await f.call({ id: eventId, size: 'full' })).statusCode, 404);
  assert.equal((await purgeExpiredAuditScanPreviews(f.pool)).rowCount, 0);
});

test('a source purge already holding the row lock prevents a racing save from leaving new bytes', dbOptions, async t => {
  const f = await fixture(t), storedFileId = await f.file(), bytes = await jpeg();
  const blocker = await f.pool.connect(), savingClient = await f.pool.connect();
  const pid = (await savingClient.query('SELECT pg_backend_pid() AS pid')).rows[0].pid;
  let save;
  try {
    await blocker.query('BEGIN');
    await blocker.query('SELECT id FROM stored_files WHERE id=$1 FOR UPDATE', [storedFileId]);
    save = saveAuditScanPreview(savingClient, { storedFileId, buffer: bytes });
    let waiting = false;
    for (let attempt = 0; attempt < 100; attempt++) {
      const state = (await f.pool.query('SELECT wait_event_type FROM pg_stat_activity WHERE pid=$1', [pid])).rows[0];
      if (state?.wait_event_type === 'Lock') { waiting = true; break; }
      await new Promise(resolve => setTimeout(resolve, 10));
    }
    assert.equal(waiting, true, 'The preview save must wait on the source row lock');
    await blocker.query('UPDATE stored_files SET content_purged_at=now() WHERE id=$1', [storedFileId]);
    await blocker.query('COMMIT');
    assert.equal(await save, null);
    assert.equal((await f.pool.query('SELECT count(*) FROM audit_scan_previews')).rows[0].count, '0');
  } finally {
    await blocker.query('ROLLBACK');
    if (save) await save;
    savingClient.release();
    blocker.release();
  }
});


test('blocked image history survives expiry and original purge, but source deletion removes every copy', dbOptions, async t => {
  const f = await fixture(t);
  const storedFileId = await f.file({ status: 'pending' });
  const previewId = await saveAuditScanPreview(f.pool, { storedFileId, buffer: await jpeg() });
  const eventId = await f.event({ storedFileId, scanPreviewId: previewId });
  await f.pool.query("UPDATE stored_files SET moderation_status='rejected',blocked_content_expires_at=now()-interval '1 second' WHERE id=$1", [storedFileId]);
  assert.equal((await purgeExpiredAuditScanPreviews(f.pool)).rowCount, 0);
  await f.pool.query('UPDATE stored_files SET content_purged_at=now() WHERE id=$1', [storedFileId]);
  for (const size of ['thumb', 'full']) {
    assert.equal((await f.call({ id: eventId, size })).statusCode, 200);
  }
  await f.pool.query('DELETE FROM stored_files WHERE id=$1', [storedFileId]);
  assert.equal((await f.pool.query('SELECT count(*) FROM audit_scan_previews')).rows[0].count, '0');
});



test('all operation rows use the image or first video frame despite completion order and filters', dbOptions, async t => {
  const f = await fixture(t), video = await f.file({ fileType: 'video' }), image = await f.file();
  const videoOperation = randomUUID(), imageOperation = randomUUID(), noFirstFrame = randomUUID();
  const later = await saveAuditScanPreview(f.pool, { storedFileId: video, buffer: await jpeg('blue') });
  const first = await saveAuditScanPreview(f.pool, { storedFileId: video, buffer: await jpeg('red') });
  const photo = await saveAuditScanPreview(f.pool, { storedFileId: image, buffer: await jpeg('green') });
  const laterEvent = await f.event({ storedFileId: video, scanPreviewId: later, frameIndex: 2 }, videoOperation);
  const firstEvent = await f.event({ storedFileId: video, scanPreviewId: first, frameIndex: 0 }, videoOperation);
  const imageEvent = await f.event({ storedFileId: image, scanPreviewId: photo }, imageOperation);
  await f.event({ storedFileId: video, scanPreviewId: later, frameIndex: 2 }, noFirstFrame);
  const operations = [{ id: videoOperation }, { id: imageOperation }, { id: noFirstFrame }];
  await attachOperationPreviews(f.pool, operations, 'operations');
  assert.equal(operations[0].operationPreview.eventId, firstEvent);
  assert.equal(operations[0].operationPreview.mediaType, 'video');
  assert.equal(operations[1].operationPreview.eventId, imageEvent);
  assert.equal(operations[2].operationPreview, null, 'later frame cannot impersonate the first frame');
  const filteredSteps = [{ id: laterEvent, operation_id: videoOperation, kind: 'provider_call_finished' },
    { id: '9999', operation_id: videoOperation, kind: 'http_response' }];
  await attachOperationPreviews(f.pool, filteredSteps, 'events');
  for (const row of filteredSteps) assert.deepEqual(row.operationPreview, operations[0].operationPreview);
  // The display selection never rewrites the exact frame evidence.
  const exactLater = await f.call({ id: laterEvent });
  const selectedFirst = await f.call({ id: firstEvent });
  assert.notDeepEqual(exactLater.body, selectedFirst.body);
});
