'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const { registerAttachmentReadFailures } = require('../server/attachment-read-failures');

test('clipboard diagnostics require authentication, validate codes and omit private data', async t => {
  const app = express(); app.use(express.json());
  const logs = [];
  let limited = false;
  registerAttachmentReadFailures(app, {
    auth(req, res, next) {
      if (req.headers.authorization !== 'Bearer fixture') return res.sendStatus(401);
      req.user = { id: 'owner' }; next();
    },
    rateLimit(req, res, next) { if (limited) return res.sendStatus(429); next(); },
    log: (...args) => logs.push(args),
  });
  const server = app.listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const url = `http://127.0.0.1:${server.address().port}/api/attachment-read-failures`;
  const valid = { origin: 'clipboard', extension: 'docx', fileSize: 200,
    batchSize: 2, index: 1, events: [{ stage: 'snapshot', code: 'NotReadableError' }] };
  const post = (body, token = 'fixture') => fetch(url, { method: 'POST', headers: {
    authorization: `Bearer ${token}`, 'content-type': 'application/json',
    'user-agent': 'Mozilla/5.0 (Windows NT 10.0) Chrome/141.0.0.0 PRIVATE',
  }, body: JSON.stringify(body) });
  assert.equal((await post(valid, 'wrong')).status, 401);
  assert.equal(logs.length, 0);
  assert.equal((await post({ ...valid, fileName: 'private.docx', token: 'PRIVATE',
    events: [{ ...valid.events[0], message: 'PRIVATE path', stack: 'PRIVATE' }] })).status, 202);
  assert.deepEqual(JSON.parse(logs[0][1]), { userId: 'owner', ...valid,
    browser: 'Chrome/141', platform: 'windows' });
  assert.ok(!JSON.stringify(logs).includes('PRIVATE'));
  assert.ok(!JSON.stringify(logs).includes('private.docx'));
  for (const bad of [ { index: 2 }, { batchSize: 0 }, { fileSize: -1 },
    { extension: 'private.docx' }, { events: [] },
    { events: [{ stage: 'snapshot', code: 'private error message' }] },
    { events: Array(13).fill(valid.events[0]) } ]) {
    assert.equal((await post({ ...valid, ...bad })).status, 400);
  }
  limited = true;
  assert.equal((await post(valid)).status, 429);
  assert.equal(logs.length, 1);
});
