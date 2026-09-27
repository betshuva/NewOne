'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { randomUUID } = require('node:crypto');
const { runWithAuditContext, getAuditContext } = require('../server/system-audit');
const { auditIds, createRequestAudit, withPendingAudit, mirrorActivity,
  requestAction, responseOutcome, auditedSocketHandler, auditedMediaQuery } = require('../server/system-audit-context');

function database() {
  const events = [];
  const db = { events, async query(sql, values) {
    events.push({ sql, values });
    if (sql.startsWith('WITH operation')) return { rows: [{ id: values[0], root_event_id: '7' }] };
    return { rows: [{ id: '8' }] };
  } };
  return db;
}
function response() {
  return Object.assign(new EventEmitter(), {
    statusCode: 200, headers: {}, writableFinished: false,
    setHeader(key, value) { this.headers[key] = value; },
    status(value) { this.statusCode = value; return this; },
    json(value) { this.body = value; return this; },
  });
}
const flush = () => new Promise(resolve => setImmediate(resolve));

test('request roots are authenticated, server-generated and pending stays pending', async () => {
  const db = database(), res = response(), userId = randomUUID();
  const req = { method: 'POST', route: { path: '/api/upload' }, user: { id: userId },
    headers: { 'x-audit-operation-id': randomUUID() }, body: {} };
  await createRequestAudit({ getPool: async () => db })(req, res, () => {
    assert.equal(getAuditContext().initiatorId, userId);
    assert.equal(auditIds()[0], req.systemAudit.operationId);
    res.json({ status: 'pending', body: 'private text', token: 'secret' });
  });
  assert.notEqual(req.systemAudit.operationId, req.headers['x-audit-operation-id']);
  assert.equal(getAuditContext(), null);
  res.writableFinished = true;
  res.emit('finish'); res.emit('close');
  await flush();
  assert.equal(db.events.length, 2);
  assert.equal(db.events[1].values[2], 'http_response');
  assert.equal(db.events[1].values[8], 'pending');
  assert.doesNotMatch(JSON.stringify(db.events), /private text|secret/);
});

test('read requests do not write roots and audit failure blocks mutation without misreporting auth', async () => {
  let next = 0;
  const middleware = createRequestAudit({ getPool: async () => { throw new Error('database'); } });
  await middleware({ method: 'GET' }, response(), () => next++);
  assert.equal(next, 1);
  const res = response();
  await middleware({ method: 'POST', user: { id: randomUUID() } }, res, () => next++);
  assert.equal(next, 1);
  assert.equal(res.statusCode, 503);
  assert.equal(res.body.code, 'AUDIT_UNAVAILABLE');
});

test('connection loss does not claim rollback and generic failures do not expose response content', async () => {
  const db = database(), res = response();
  await createRequestAudit({ getPool: async () => db })({ method: 'DELETE',
    route: { path: '/api/admin/users/:id' }, user: { id: randomUUID() }, adminPerm: 'edit' }, res, () => {});
  res.emit('close');
  await flush();
  assert.equal(db.events[0].values[9], 'admin');
  assert.equal(db.events[1].values[2], 'http_connection_closed');
  assert.equal(db.events[1].values[8], null);
  assert.equal(db.events[1].values[9], 'outcome_unknown');
  assert.equal(responseOutcome(500, {}), 'failed');
  assert.equal(responseOutcome(403, {}), 'blocked');
  assert.equal(responseOutcome(200, { requestPending: true }), 'pending');
  assert.equal(requestAction({ route: { path: '/api/groups/:id/messages' } }), 'send_group_message');
});

test('only dedicated audit deletion routes own their transactional deletion evidence', async () => {
  const db = database(), middleware = createRequestAudit({ getPool: async () => db });
  let calls = 0;
  for (const path of ['/api/admin/audit/operations/:id', '/api/admin/audit/events/:id']) {
    await middleware({ method: 'DELETE', route: { path }, user: { id: randomUUID() } }, response(), () => calls++);
  }
  assert.equal(calls, 2);
  assert.equal(db.events.length, 0);
  for (const [method, path] of [['POST', '/api/admin/audit/events/:id'],
    ['DELETE', '/api/admin/audit/unrelated/:id']]) {
    await middleware({ method, route: { path }, user: { id: randomUUID() } }, response(), () => calls++);
  }
  assert.equal(db.events.length, 2);
});

test('background rows restore only durable context and clear inherited upload context for legacy rows', async () => {
  const db = database(), first = randomUUID(), queued = randomUUID(), user = randomUUID();
  await runWithAuditContext({ operationId: first }, async () => {
    await withPendingAudit(db, { audit_operation_id: queued, audit_parent_event_id: '19', user_id: user }, async () => {
      await flush();
      assert.deepEqual(auditIds(), [queued, '19']);
      assert.equal(getAuditContext().executorType, 'worker');
      assert.equal(getAuditContext().initiatorId, user);
    });
    await withPendingAudit(db, {}, async () => {
      assert.deepEqual(auditIds(), [null, null]);
    });
    assert.equal(getAuditContext().operationId, first);
  });
});

test('legacy worker observations do not label the media owner as executor or invent a parent', async () => {
  const db = database();
  await mirrorActivity(db, randomUUID(), 'send_file_delayed', { fileName: 'private.mp4', text: 'secret' });
  assert.equal(db.events[0].values[3], null);
  assert.equal(db.events[0].values[9], 'worker');
  assert.equal(db.events[1].values[3], 'worker');
  assert.doesNotMatch(JSON.stringify(db.events), /private\.mp4|secret/);
  await withPendingAudit(db, {}, () => mirrorActivity(db, randomUUID(), 'send_file_delayed', {}));
  assert.equal(db.events.length, 4);
});

test('socket handlers and awaited continuations retain isolated context', async () => {
  const db = database(), userId = randomUUID();
  let called = false;
  const handler = auditedSocketHandler({ getPool: async () => db, userId, action: 'send_message' }, async payload => {
    await flush();
    assert.equal(getAuditContext().initiatorId, userId);
    assert.equal(payload, 'payload');
    called = true;
  });
  await handler('payload');
  assert.equal(called, true);
  assert.equal(getAuditContext(), null);
});

test('socket rate checks run before audit writes, and business errors are not audit outages', async () => {
  const db = database(), errors = [], userId = randomUUID();
  const make = accept => auditedSocketHandler({ getPool: async () => db, userId,
    action: 'send_message', accept, onError: code => errors.push(code) }, async () => { throw new Error('private error'); });
  await make(() => false)({});
  assert.equal(db.events.length, 0);
  await make(() => true)({});
  assert.deepEqual(errors, ['MESSAGE_PROCESSING_FAILED']);
  assert.equal(db.events[1].values[2], 'socket_handler_failed');
  assert.doesNotMatch(JSON.stringify(db.events), /private error/);
});

test('media writes set context only inside an owned transaction and rollback/release on failure', async () => {
  const calls = [], operationId = randomUUID();
  const client = { async query(sql, values) { calls.push([sql, values]);
    if (sql === 'FAIL') throw new Error('write failed');
    return { rows: [] };
  }, release() { calls.push(['release']); } };
  const pool = { connect: async () => client };
  await runWithAuditContext({ operationId, parentEventId: '5' }, async () => {
    await auditedMediaQuery(pool, 'UPDATE stored_files', []);
    assert.deepEqual(calls.map(([sql]) => sql), ['BEGIN',
      "SELECT set_config('app.audit_operation_id',$1,true), set_config('app.audit_parent_event_id',$2,true)",
      'UPDATE stored_files', 'COMMIT', 'release']);
    assert.deepEqual(calls[1][1], [operationId, '5']);
    calls.length = 0;
    await assert.rejects(auditedMediaQuery(pool, 'FAIL', []), /write failed/);
    assert.deepEqual(calls.slice(-2).map(([sql]) => sql), ['ROLLBACK', 'release']);
  });
});

test('action catalog separates clearing account data, deleting identity and message reactions', () => {
  const action = (path, method = 'DELETE') => requestAction({ method, route: { path } });
  assert.equal(action('/api/account'), 'delete_account');
  assert.equal(action('/api/account/data'), 'delete_account_data');
  assert.equal(action('/api/messages/:id/reactions', 'PUT'), 'message_reaction');
  assert.equal(action('/api/profile/preferences', 'PATCH'), 'update_preferences');
});


test('socket rejection records the precise reason in the active operation and preserves the client event',async()=>{
 const {emitDispatchRejection}=require('../server/system-audit-context'),db=database(),sent=[],operationId=randomUUID();
 await runWithAuditContext({operationId,executorType:'system',executorId:'socket'},()=>emitDispatchRejection(async()=>db,{emit:(event,payload)=>sent.push({event,payload})},{code:'CHAT_CONTENT_BLOCKED',reason:'הודעות טקסט חסומות בהגדרות הנמען'}));
 assert.equal(sent[0].event,'message:rejected');assert.equal(db.events.length,1);assert.equal(db.events[0].values[0],operationId);assert.equal(db.events[0].values[2],'dispatch_outcome');assert.match(JSON.stringify(db.events),/הודעות טקסט חסומות בהגדרות הנמען/);
});
