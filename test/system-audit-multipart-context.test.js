'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { once } = require('node:events');
const { randomUUID } = require('node:crypto');
const { Client } = require('pg');
const express = require('express');
const multer = require('multer');
const { getAuditContext, runWithAuditContext, ensureSystemAuditSchema, recordAuditEvent } =
  require('../server/system-audit');
const { auditIds, createRequestAudit, observeAudit, restoreRequestAuditContext, uploadAuditDetails,
  withPendingAudit, setAuditTransactionContext } =
  require('../server/system-audit-context');

const flush = () => new Promise(resolve => setImmediate(resolve));

function database() {
  const writes = [];
  let sequence = 0;
  return { writes, async query(sql, values) {
    await flush();
    writes.push({ sql, values });
    if (sql.startsWith('WITH operation'))
      return { rows: [{ id: values[0], root_event_id: String(++sequence) }] };
    return { rows: [{ id: String(++sequence) }] };
  } };
}

async function multipartServer(t, restore, { db = database(), receive } = {}) {
  const app = express();
  const audit = createRequestAudit({ getPool: async () => db });
  const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 1024 } });
  const route = [
    (req, res, next) => {
      req.user = { id: req.headers['x-test-user-id'] };
      return audit(req, res, next);
    },
    upload.single('file'),
  ];
  if (restore) route.push(restoreRequestAuditContext);
  route.push(async (req, res) => {
    if (receive) return receive(req, res, db);
    const beforeAwait = auditIds();
    await flush();
    const afterAwait = auditIds();
    await observeAudit(db, { kind: 'upload_received', status: 'completed',
      details: { fileType: 'video', fileSize: req.file.size } });
    res.json({ beforeAwait, afterAwait, context: getAuditContext(),
      requestContext: req.systemAudit, bytes: req.file.size,
      destination: req.body.toUserId });
  });
  app.post('/api/upload', ...route);
  const server = http.createServer(app);
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise((resolve, reject) => {
    server.close(error => error ? reject(error) : resolve());
    server.closeAllConnections();
  }));
  return { db, port: server.address().port };
}

function uploadChunks(port, userId, toUserId, { captureKind } = {}) {
  const boundary = `audit-${randomUUID()}`;
  const forgedOperation = randomUUID();
  const pieces = [
    `--${boundary}\r\nContent-Disposition: form-data; name="toUserId"\r\n\r\n${toUserId}\r\n`,
    `--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="private-video.webm"\r\nContent-Type: video/webm\r\n\r\n`,
    'not-real-media-bytes',
    `\r\n--${boundary}--\r\n`,
  ];
  if (captureKind) pieces.splice(1, 0,
    `--${boundary}\r\nContent-Disposition: form-data; name="captureKind"\r\n\r\n${captureKind}\r\n`);
  return new Promise((resolve, reject) => {
    const request = http.request({ hostname: '127.0.0.1', port, path: '/api/upload', method: 'POST',
      headers: { 'content-type': `multipart/form-data; boundary=${boundary}`,
        'x-test-user-id': userId, 'x-audit-operation-id': forgedOperation } }, response => {
      let body = '';
      response.setEncoding('utf8');
      response.on('data', chunk => { body += chunk; });
      response.once('end', () => {
        try { resolve({ status: response.statusCode, body: JSON.parse(body),
          operationId: response.headers['x-audit-operation-id'], forgedOperation }); }
        catch (error) { reject(error); }
      });
    });
    request.once('error', reject);
    request.setTimeout(3000, () => request.destroy(new Error('Multipart fixture timed out')));
    request.flushHeaders();
    let index = 0;
    const timer = setInterval(() => {
      if (request.destroyed) { clearInterval(timer); return; }
      request.write(pieces[index++]);
      if (index === pieces.length) { clearInterval(timer); request.end(); }
    }, 15);
  });
}

test('unwrapped multipart callbacks reproduce the missing business events despite the HTTP event', async t => {
  const { db, port } = await multipartServer(t, false);
  const result = await uploadChunks(port, randomUUID(), randomUUID());
  assert.equal(result.status, 200);
  assert.deepEqual(result.body.beforeAwait, [null, null]);
  assert.deepEqual(result.body.afterAwait, [null, null]);
  assert.ok(result.body.requestContext.operationId);
  await flush();
  assert.equal(db.writes.filter(write => write.sql.startsWith('WITH operation')).length, 1);
  assert.deepEqual(db.writes.filter(write => !write.sql.startsWith('WITH operation'))
    .map(write => write.values[2]), ['http_response']);
});

test('restored multipart requests retain distinct server roots and child IDs after asynchronous parsing', async t => {
  const { db, port } = await multipartServer(t, true);
  const users = [randomUUID(), randomUUID(), randomUUID()];
  const recipients = users.map(() => randomUUID());
  const results = await Promise.all(users.map((user, index) => uploadChunks(port, user, recipients[index])));
  await flush();
  assert.equal(new Set(results.map(result => result.operationId)).size, users.length);
  for (const [index, result] of results.entries()) {
    assert.equal(result.status, 200);
    assert.notEqual(result.operationId, result.forgedOperation);
    assert.equal(result.body.context.initiatorId, users[index]);
    assert.equal(result.body.destination, recipients[index]);
    assert.equal(result.body.bytes, Buffer.byteLength('not-real-media-bytes'));
    const expected = [result.operationId, result.body.requestContext.parentEventId];
    assert.deepEqual(result.body.beforeAwait, expected);
    assert.deepEqual(result.body.afterAwait, expected);
    const events = db.writes.filter(write => !write.sql.startsWith('WITH operation') &&
      write.values[0] === result.operationId);
    assert.deepEqual(events.map(write => write.values[2]), ['upload_received', 'http_response']);
    assert.ok(events.every(write => write.values[1] === expected[1]));
  }
  assert.equal(getAuditContext(), null);
  assert.doesNotMatch(JSON.stringify(db.writes), /private-video|not-real-media-bytes/);
});

test('missing server request context clears an inherited root instead of using client headers', async () => {
  await runWithAuditContext({ operationId: randomUUID(), parentEventId: '81',
    initiatorId: randomUUID() }, async () => {
    const prior = auditIds();
    await restoreRequestAuditContext({ headers: { 'x-audit-operation-id': randomUUID() } }, {}, async () => {
      await flush();
      assert.deepEqual(auditIds(), [null, null]);
      assert.equal(getAuditContext().initiatorId, undefined);
    });
    assert.deepEqual(auditIds(), prior);
  });
  assert.equal(getAuditContext(), null);
});

test('capture provenance is explicit, type-matched and never inferred from a file name', () => {
  for (const [captureKind, mediaType] of [
    ['camera_video', 'video'], ['camera_image', 'image'], ['microphone', 'audio'],
  ]) {
    assert.deepEqual(uploadAuditDetails({ captureKind, fileName: 'private-file',
      fileUrl: 'https://private.invalid', text: 'private-message' }, mediaType),
    { captureKind, mediaType });
  }
  assert.deepEqual(uploadAuditDetails({ fileName: 'betshuva_video_ID123_2026-09-24.mp4',
    originalname: 'camera.webm', recordedAudio: 'true' }, 'video'), { mediaType: 'video' });
  for (const captureKind of ['camera_image', 'microphone', 'unknown', '__proto__',
    'constructor', { camera_video: true }, ['camera_video'], true, null]) {
    assert.deepEqual(uploadAuditDetails({ captureKind }, 'video'), { mediaType: 'video' });
  }
  assert.deepEqual(uploadAuditDetails(null, 'video'), { mediaType: 'video' });
});

test('real multipart upload persists one PostgreSQL causal chain through storage, queue and a later worker',
  { skip: process.env.RUN_DB_TESTS !== '1' }, async t => {
    const url = new URL(process.env.DATABASE_URL);
    assert.match(url.pathname, /test/i, 'Multipart DB test requires an explicitly named disposable test database');
    const db = new Client({ connectionString: url.href, ssl: false });
    await db.connect();
    const schema = `audit_multipart_test_${randomUUID().replaceAll('-', '')}`;
    await db.query(`CREATE SCHEMA "${schema}"`);
    t.after(async () => {
      await db.query(`DROP SCHEMA "${schema}" CASCADE`);
      await db.end();
    });
    await db.query(`SET search_path TO "${schema}";
      CREATE TABLE users(id uuid PRIMARY KEY, name text, short_id integer);
      CREATE TABLE groups(id uuid PRIMARY KEY, name text);
      CREATE TABLE stored_files(id uuid PRIMARY KEY, user_id uuid, file_type text,
        moderation_status text, moderation_details jsonb NOT NULL DEFAULT '{}');
      CREATE TABLE pending_scans(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        user_id uuid, to_user_id uuid, group_id uuid, file_type text, retry_count integer DEFAULT 0);
      CREATE TABLE messages(id uuid PRIMARY KEY, sender_id uuid, receiver_id uuid, type text);`);
    const actor = randomUUID(), recipient = randomUUID(), fileId = randomUUID(), messageId = randomUUID();
    await db.query('INSERT INTO users VALUES($1,$2,42),($3,$4,123)',
      [actor, 'Multipart Actor', recipient, 'Multipart Recipient']);
    await ensureSystemAuditSchema(db);
    const { port } = await multipartServer(t, true, { db, receive: async (req, res) => {
      await observeAudit(db, { kind: 'upload_context', details: {
        ...uploadAuditDetails(req.body, 'video'), recipientType: 'user', recipientId: req.body.toUserId,
      } });
      await db.query(`INSERT INTO stored_files
        (id,user_id,file_type,moderation_status,audit_operation_id,audit_parent_event_id)
        VALUES($1,$2,'video','pending',$3,$4)`, [fileId, req.user.id, ...auditIds()]);
      const queue = await db.query(`INSERT INTO pending_scans
        (user_id,to_user_id,file_type,audit_operation_id,audit_parent_event_id)
        VALUES($1,$2,'video',$3,$4) RETURNING id`, [req.user.id, req.body.toUserId, ...auditIds()]);
      res.json({ status: 'pending', queueId: queue.rows[0].id });
    } });
    const result = await uploadChunks(port, actor, recipient, { captureKind: 'camera_video' });
    assert.equal(result.status, 200);
    assert.equal(getAuditContext(), null);
    const queue = (await db.query('SELECT * FROM pending_scans WHERE id=$1', [result.body.queueId])).rows[0];
    const stored = (await db.query('SELECT * FROM stored_files WHERE id=$1', [fileId])).rows[0];
    const operation = (await db.query('SELECT * FROM audit_operations WHERE id=$1', [result.operationId])).rows[0];
    assert.equal(queue.audit_operation_id, operation.id);
    assert.equal(stored.audit_operation_id, operation.id);
    assert.equal(queue.audit_parent_event_id, operation.root_event_id);
    assert.equal(stored.audit_parent_event_id, operation.root_event_id);
    assert.equal(operation.status, 'pending');
    assert.equal(operation.capture_kind, 'camera_video');
    assert.equal(operation.media_type, 'video');
    assert.equal(operation.recipient_id, recipient);
    assert.equal(operation.recipient_name, 'Multipart Recipient');
    assert.equal(operation.recipient_short_id, '123');

    // Continue using only durable queue evidence after the HTTP scope has gone.
    await withPendingAudit(db, queue, async () => {
      await flush();
      assert.deepEqual(auditIds(), [operation.id, operation.root_event_id]);
      assert.equal(getAuditContext().executorType, 'worker');
      await db.query('BEGIN');
      try {
        await setAuditTransactionContext(db);
        await db.query('UPDATE pending_scans SET retry_count=1 WHERE id=$1', [queue.id]);
        await recordAuditEvent(db, { kind: 'provider_call_finished', status: 'observed' });
        await db.query("UPDATE stored_files SET moderation_status='approved' WHERE id=$1", [fileId]);
        await db.query(`INSERT INTO messages
          (id,sender_id,receiver_id,type,audit_operation_id,audit_parent_event_id)
          VALUES($1,$2,$3,'video',$4,$5)`, [messageId, actor, recipient, ...auditIds()]);
        await recordAuditEvent(db, { kind: 'scan_workflow_finished', status: 'completed', operationStatus: 'completed' });
        await db.query('DELETE FROM pending_scans WHERE id=$1', [queue.id]);
        await db.query('COMMIT');
      } catch (error) {
        await db.query('ROLLBACK');
        throw error;
      }
    });
    assert.equal(getAuditContext(), null);
    const events = (await db.query('SELECT * FROM audit_events ORDER BY id')).rows;
    assert.deepEqual(events.map(event => event.kind), ['operation_started', 'upload_context',
      'media_stored', 'scan_queued', 'http_response', 'scan_attempt_started', 'provider_call_finished',
      'media_moderation_changed', 'message_persisted', 'scan_workflow_finished', 'scan_queue_removed']);
    assert.ok(events.every(event => event.operation_id === operation.id));
    assert.ok(events.slice(1).every(event => event.parent_event_id === operation.root_event_id));
    const updated = (await db.query('SELECT * FROM audit_operations WHERE id=$1', [operation.id])).rows[0];
    assert.equal(updated.event_count, '11');
    assert.equal(updated.status, 'completed');
    assert.equal(updated.status_source, 'scan_workflow_finished');
    assert.doesNotMatch(JSON.stringify(events), /private-video|not-real-media-bytes/);
  });
