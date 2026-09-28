'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const http = require('node:http');
const { once } = require('node:events');
const { randomUUID } = require('node:crypto');
const { createRequestAudit } = require('../server/system-audit-context');
const { decryptMessageText } = require('../server/message-at-rest');
const { registerUploadRejectionAudit } = require('../server/upload-rejection-audit');
process.env.MESSAGE_ENCRYPTION_KEY = 'upload-rejection-fixture-encryption-key-12345';

async function fixture(t, { failWrite = false } = {}) {
  const userId = randomUUID(), writes = [];
  const db = { async query(sql, values) {
    if (failWrite && sql.startsWith('INSERT INTO audit_events')) throw new Error('fixture unavailable');
    writes.push({ sql, values });
    return { rows: [{ id: sql.startsWith('WITH operation') ? values[0] : '2', root_event_id: '1' }] };
  } };
  const app = express();
  app.use(express.json());
  const audit = createRequestAudit({ getPool: async () => db });
  registerUploadRejectionAudit(app, { getPool: async () => db,
    uploadRateLimit: (_req, _res, next) => next(),
    auth(req, res, next) {
      if (req.headers.authorization !== 'Bearer fixture') return res.sendStatus(401);
      req.user = { id: userId };
      return audit(req, res, next);
    },
  });
  const server = http.createServer(app).listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise(resolve => { server.close(resolve); server.closeAllConnections(); }));
  return { userId, writes, async report(body, token = 'fixture') {
    const response = await fetch(`http://127.0.0.1:${server.address().port}/api/upload-attempts/rejected`, {
      method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify(body),
    });
    await new Promise(resolve => setImmediate(resolve));
    return response;
  } };
}
const valid = () => ({ fileName: 'הקלטה ארוכה.mp3', fileType: 'audio',
  fileSize: 150 * 1024 * 1024 + 1, maxBytes: 150 * 1024 * 1024, reasonCode: 'file_too_large' });

test('authenticated client rejection records encrypted filename, size and blocked upload outcome', async t => {
  const f = await fixture(t);
  const result = await f.report({ ...valid(), userId: randomUUID(), fileUrl: 'forged',
    text: 'do not retain this', operationId: randomUUID() });
  assert.equal(result.status, 200);
  assert.equal((await result.json()).recorded, true);
  const root = f.writes.find(write => write.sql.startsWith('WITH operation'));
  assert.equal(root.values[1], 'upload_file');
  assert.equal(root.values[3], f.userId);
  const child = f.writes.find(write => write.values[2] === 'dispatch_context');
  assert.equal(child.values[3], 'client');
  assert.equal(child.values[4], f.userId);
  assert.equal(child.values[6], 'client_upload_validation');
  assert.equal(child.values[8], 'blocked');
  const details = JSON.parse(child.values[13]);
  assert.equal(decryptMessageText(details.dispatchFileName), valid().fileName);
  assert.equal(details.fileSize, valid().fileSize);
  assert.equal(details.maxBytes, valid().maxBytes);
  assert.equal(details.mediaType, 'audio');
  assert.equal(details.clientReported, true);
  assert.match(details.dispatchReason, /לפני שליחת הקובץ/);
  const terminal = f.writes.find(write => write.values[2] === 'http_response');
  assert.equal(terminal.values[8], 'blocked');
  assert.equal(terminal.values[9], 'client_file_too_large');
  assert.doesNotMatch(JSON.stringify(f.writes), /הקלטה ארוכה|forged|do not retain this/);
});

test('unauthenticated or invalid reports cannot create rejection evidence', async t => {
  const f = await fixture(t);
  assert.equal((await f.report(valid(), 'invalid')).status, 401);
  assert.equal(f.writes.length, 0);
  for (const changes of [{ fileSize: 1 }, { maxBytes: 1 }, { fileName: '' },
    { fileType: 'script' }, { reasonCode: 'pretend_success' }, { fileSize: '999999999' }]) {
    assert.equal((await f.report({ ...valid(), ...changes })).status, 400);
  }
  assert.ok(!f.writes.some(write => write.values[2] === 'dispatch_context'));
});

test('reporting failure is returned explicitly instead of claiming a saved audit event', async t => {
  const f = await fixture(t, { failWrite: true });
  const response = await f.report(valid());
  assert.equal(response.status, 503);
  assert.equal((await response.json()).code, 'AUDIT_UNAVAILABLE');
});
