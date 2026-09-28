'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const { registerAuditMediaRoutes, attachOperationMedia } = require('../server/audit-media');

function routes(db, readMedia) {
  let route;
  const adminMiddleware = (_req, _res, next) => next();
  registerAuditMediaRoutes({ get: (path, ...handlers) => { route = { path, handlers }; } },
    { getPool: async () => db, adminMiddleware, readMedia });
  return { route, adminMiddleware, call: async (overrides = {}) => {
    const res = { statusCode: 200, headers: {},
      set(key, value) { this.headers[key] = value; return this; },
      status(value) { this.statusCode = value; return this; },
      json(body) { this.body = body; return this; }, send(body) { this.body = body; return this; } };
    await route.handlers.at(-1)({ user: { id: randomUUID() }, adminPerm: 'view',
      params: { id: randomUUID(), fileId: randomUUID() }, ...overrides }, res);
    return res;
  } };
}

test('audit media requires admin middleware, view/edit permission, and validated operation/file IDs', async () => {
  const f = routes({ query: () => assert.fail('not authorized') }, () => assert.fail());
  assert.equal(f.route.handlers[0], f.adminMiddleware);
  for (const override of [{ user: null }, { adminPerm: '' }, { adminPerm: 'admin' }])
    assert.equal((await f.call(override)).statusCode, 403);
  assert.equal((await f.call({ params: { id: '../', fileId: randomUUID() } })).statusCode, 400);
});

test('all supported media, including blocked files, use authenticated private responses', async () => {
  for (const [file_type, mime_type] of [['image','image/png'],['video','video/mp4'],['audio','audio/mpeg'],['document','application/pdf']]) {
    const bytes = Buffer.from('test media');
    const file = { id: randomUUID(), file_type, mime_type, file_size: bytes.length, moderation_status: 'rejected' };
    const f = routes({ query: async () => ({ rows: [file] }) }, async (_db, actual) => { assert.equal(actual.id, file.id); return bytes; });
    const response = await f.call();
    assert.equal(response.statusCode, 200);
    assert.equal(response.body, bytes);
    assert.equal(response.headers['Content-Type'], mime_type);
    assert.match(response.headers['Cache-Control'], /no-store/);
    assert.equal(response.headers['X-Content-Type-Options'], 'nosniff');
  }
});

test('deleted original media is not restored; retained rejected image evidence may still open', async () => {
  for (const file_type of ['audio', 'video', 'document']) {
    const mime_type = { audio: 'audio/mpeg', video: 'video/mp4', document: 'application/pdf' }[file_type];
    const f = routes({ query: async () => ({ rows: [{ file_type, mime_type, content_purged_at: new Date() }] }) }, () => assert.fail('must not restore deleted content'));
    assert.equal((await f.call()).statusCode, 404);
  }
  let calls = 0;
  const bytes = Buffer.from('retained image');
  const image = routes({ query: async () => ({ rows: ++calls === 1
    ? [{ id: randomUUID(), file_type: 'image', mime_type: 'image/png', content_purged_at: new Date(), moderation_status: 'rejected' }]
    : [{ image: bytes }] }) }, () => assert.fail('original was deleted'));
  assert.equal((await image.call()).body, bytes);
});

test('unsupported active content and oversized files never reach the media reader', async () => {
  for (const file of [{ file_type: 'image', mime_type: 'image/svg+xml' },
    { file_type: 'video', mime_type: 'video/mp4', file_size: 51 * 1024 * 1024 }]) {
    const f = routes({ query: async () => ({ rows: [file] }) }, () => assert.fail());
    assert.ok([404,413].includes((await f.call()).statusCode));
  }
});

test('real SQL ties a media file to its operation and ignores unrelated files and malformed event details', {
  skip: process.env.RUN_DB_TESTS !== '1',
}, async () => {
  require('dotenv').config({ quiet: true });
  const { Client } = require('pg');
  const db = new Client({ connectionString: process.env.DATABASE_URL });
  await db.connect();
  try {
    await db.query('BEGIN');
    await db.query(`CREATE TEMP TABLE stored_files(id uuid, file_type text, mime_type text, original_name text,
      file_size bigint, content_purged_at timestamptz, moderation_status text);
      CREATE TEMP TABLE audit_events(id bigint, operation_id uuid, target_type text, target_id uuid, details jsonb);
      CREATE TEMP TABLE audit_scan_previews(stored_file_id uuid, image bytea, created_at timestamptz);`);
    const [op, otherOp, file, otherFile] = Array.from({ length: 4 }, randomUUID);
    for (const id of [file, otherFile]) await db.query("INSERT INTO stored_files VALUES($1,'video','video/mp4','video.mp4',4,NULL,'rejected')", [id]);
    await db.query("INSERT INTO audit_events VALUES(1,$1,'file',$2,'{}'),(2,$1,NULL,NULL,$3),(3,$4,'file',$5,'{}')",
      [op, file, JSON.stringify({ storedFileId: 'invalid UUID' }), otherOp, otherFile]);
    const f = routes(db, async () => Buffer.from('test'));
    assert.equal((await f.call({ params: { id: op, fileId: file } })).statusCode, 200);
    assert.equal((await f.call({ params: { id: op, fileId: otherFile } })).statusCode, 404);
    const rows = [{ id: op }];
    await attachOperationMedia(db, rows, 'operations');
    assert.equal(rows[0].operationMedia.length, 1);
    assert.equal(rows[0].operationMedia[0].id, file);
    assert.equal(rows[0].operationMedia[0].available, true);
    await db.query('UPDATE audit_events SET target_type=NULL,target_id=NULL,details=$1 WHERE id=1', [JSON.stringify({ storedFileId: file })]);
    assert.equal((await f.call({ params: { id: op, fileId: file } })).statusCode, 200);
  } finally { await db.query('ROLLBACK'); await db.end(); }
});
