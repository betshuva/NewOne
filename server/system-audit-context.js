'use strict';

const { beginOperation, getAuditContext, recordAuditEvent, runWithAuditContext } = require('./system-audit');
const { lookupAction } = require('./system-audit-catalog');

const {encryptMessageText}=require('./message-at-rest');
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const WORKER_ACTIONS = new Set(['send_file_delayed', 'send_group_file_delayed',
  'blocked_upload_delayed', 'group_file_delivery_rejected', 'blocked_audio_purged',
  'blocked_image_purged', 'pending_image_scan_expired', 'safe_local_media_release',
  'automatic_encrypted_backup', 'automatic_restore_verification']);

function auditIds() {
  const value = getAuditContext();
  return [value?.operationId || null, value?.parentEventId || null];
}

function dispatchDetails(body={}) {
  const details={};const recipient=body.groupId||body.toUserId;
  if(UUID.test(recipient||'')){details.recipientId=recipient;details.recipientType=body.groupId?'group':'user';}
  const content=body.text??body.message;
  if(typeof content==='string')details.dispatchBody=encryptMessageText(content.slice(0,4000));
  if(typeof body.fileName==='string')details.dispatchFileName=encryptMessageText(body.fileName.slice(0,256));
  details.messageType=body.fileType||body.type||(body.stickerId?'sticker':body.fileUrl?undefined:'text');return details;
}
function dispatchReason(body){
  const value=body?.reason||body?.error;
  return typeof value==='string'?value.replace(/https?:\/\/\S+|Bearer\s+\S+/gi,'[פרט מוסתר]').slice(0,500):undefined;
}
async function emitDispatchRejection(getPool,socket,payload){
  socket.emit('message:rejected',payload);
  try { await observeAudit(await getPool(),{kind:'dispatch_outcome',status:'blocked',reasonCode:typeof payload.code==='string'?payload.code.toLowerCase():'send_rejected',details:{dispatchReason:dispatchReason(payload)}}); } catch(error) { console.error('[system-audit:dispatch]',error.code||'write_failed'); }
}
function requestAction(req) {
  const route = req.route?.path || '';
  if (route === '/api/admin/system-message') return 'send_system_message';
  if (route === '/api/upload') return 'upload_file';
  if (route === '/api/messages' || route === '/api/guide-message-drafts/:id/send') return 'send_message';
  if (route === '/api/groups/:id/messages') return 'send_group_message';
  if (route.includes('filter')) return 'filter_change';
  if (route.startsWith('/api/admin/')) return 'admin_action';
  if (route === '/api/account') return 'delete_account';
  if (route === '/api/account/data') return 'delete_account_data';
  if (route === '/api/profile/preferences') return 'update_preferences';
  if (route.startsWith('/api/profile')) return 'update_profile';
  if (route.includes('/read')) return 'report_message_read';
  if (route.startsWith('/api/message-requests')) return 'manage_message_request';
  if (route.includes('/reactions')) return 'message_reaction';
  if (route.startsWith('/api/messages/')) return req.method === 'DELETE' ? 'delete_message' : 'edit_message';
  if (route.startsWith('/api/contacts')) return 'manage_contacts';
  if (route.startsWith('/api/block/')) return req.method === 'DELETE' ? 'unblock_user' : 'block_user';
  if (route.startsWith('/api/backup')) return 'manage_backup';
  if (route.startsWith('/api/calendar')) return 'manage_calendar';
  if (route.includes('education-forms')) return 'manage_education';
  if (route.startsWith('/api/groups')) return 'manage_groups';
  if (route.startsWith('/api/listings')) return 'manage_listings';
  if (route.startsWith('/api/media') || route.startsWith('/api/gifs')) return 'manage_media';
  if (route.startsWith('/api/location')) return 'change_location';
  if (route.startsWith('/api/invites')) return 'manage_invites';
  if (route.startsWith('/api/support-issues')) return 'manage_support';
  if (route === '/api/reports') return 'submit_report';
  if (route === '/api/fcm-token') return 'register_device';
  return 'api_mutation';
}

function requestTarget(req) {
  const route = req.route?.path || '';
  let targetId = req.params?.id || req.params?.userId || req.body?.toUserId || req.body?.groupId;
  let targetType = 'entity';
  if (route.startsWith('/api/groups')) targetType = 'group';
  else if (route.startsWith('/api/media-library')) targetType = 'file';
  else if (route.startsWith('/api/messages/') && req.params?.id) targetType = 'message';
  else if (req.body?.toUserId || req.params?.userId) targetType = 'user';
  else if (route.startsWith('/api/profile') || route === '/api/account') {
    targetType = 'user'; targetId = req.user.id;
  }
  return UUID.test(targetId || '') ? { targetId, targetType } : {};
}

function responseOutcome(statusCode, body) {
  if (statusCode >= 500) return 'failed';
  if (statusCode >= 400 || body?.status === 'rejected') return 'blocked';
  if (body?.status === 'pending' || body?.requestPending === true) return 'pending';
  return 'completed';
}

async function observeAudit(db, data) {
  if (!getAuditContext()?.operationId) return null;
  try { return await recordAuditEvent(db, data); }
  catch (error) { console.error('[system-audit:observation]', error.code || 'write_failed'); return null; }
}

// Multipart parsers may resume on a request-stream resource created outside
// the authentication context. Restore only the server-owned request identity.
function restoreRequestAuditContext(req, _res, next) {
  return runWithAuditContext(req.systemAudit || {}, next);
}

function uploadAuditDetails(body, mediaType) {
  const expected = { camera_video: 'video', camera_image: 'image', microphone: 'audio' };
  const captureKind = typeof body?.captureKind === 'string' &&
    Object.hasOwn(expected, body.captureKind) && expected[body.captureKind] === mediaType
    ? body.captureKind : null;
  return { mediaType, ...(captureKind ? { captureKind } : {}) };
}

// Authentication has already succeeded. Start evidence before business writes;
// failure to create the root must not silently perform an unaudited mutation.
function createRequestAudit({ getPool }) {
  return async (req, res, next) => {
    if (!['POST', 'PUT', 'PATCH', 'DELETE'].includes(req.method) || req.systemAudit)
      return next();
    // High-volume client telemetry keeps its own explicitly reported evidence.
    if (req.route?.path === '/api/filter-display-events') return next();
    // These handlers record successful administrative deletion atomically.
    if (req.method === 'DELETE' && ['/api/admin/audit/operations/:id',
      '/api/admin/audit/events/:id','/api/admin/audit/records'].includes(req.route?.path)) return next();
    let db, operation;
    try {
      db = await getPool();
      operation = await beginOperation(db, {
        action: requestAction(req), initiatorId: req.user.id,
        executorType: req.adminPerm ? 'admin' : 'user', executorId: req.user.id,
        source: 'http', ...requestTarget(req),
        // Use the server route template. Sending context is separately allowlisted and encrypted.
        details: { httpRoute: req.route?.path, httpMethod: req.method, ...(['send_message','send_group_message','send_system_message'].includes(requestAction(req))?dispatchDetails({...req.body,...(requestAction(req)==='send_group_message'?{groupId:req.params?.id}:{})}):{}) },
      });
    } catch (error) {
      console.error('[system-audit:start]', error.code || 'write_failed');
      return res.status(503).json({ error: 'Audit service unavailable', code: 'AUDIT_UNAVAILABLE' });
    }
    const context = { operationId: operation.id, parentEventId: operation.root_event_id,
      initiatorId: req.user.id, executorType: 'system', executorId: 'api', source: 'http' };
    req.systemAudit = context;
    res.setHeader('X-Audit-Operation-Id', operation.id);
    let outcome = 'completed';
    let reasonCode = null,sendReason;
    const json = res.json;
    res.json = function (body) {
      outcome = responseOutcome(res.statusCode, body);
      if(['send_message','send_group_message','send_system_message','upload_file'].includes(requestAction(req)))sendReason=dispatchReason(body);
      reasonCode = typeof body?.code === 'string' && /^[A-Z][A-Z0-9_]{0,79}$/.test(body.code)
        ? body.code.toLowerCase() : null;
      return json.call(this, body);
    };
    let finished = false;
    const finish = (aborted) => {
      if (finished) return;
      finished = true;
      const status = aborted ? 'observed' : responseOutcome(res.statusCode) === 'completed'
        ? outcome : responseOutcome(res.statusCode);
      runWithAuditContext(context, () => observeAudit(db, {
        kind: aborted ? 'http_connection_closed' : 'http_response', status,
        // A disconnected client is not proof the server operation failed.
        operationStatus: aborted ? undefined : status,
        reasonCode: aborted ? 'outcome_unknown' : reasonCode || `http_${res.statusCode}`,
        details:{dispatchReason:sendReason},
      }));
    };
    res.once('finish', () => finish(false));
    res.once('close', () => finish(!res.writableFinished));
    return runWithAuditContext(context, next);
  };
}

async function mirrorActivity(db, userId, action, details) {
  let context = getAuditContext();
  if (!context?.operationId) {
    const worker = WORKER_ACTIONS.has(action);
    const operation = await beginOperation(db, { action,
      category: lookupAction(action)?.category || 'other',
      initiatorId: worker ? null : userId || null,
      executorType: worker ? 'worker' : 'unknown',
      executorId: worker ? 'background' : null, source: 'activity_log', status: 'observed',
      reasonCode: 'legacy_observation', details,
    });
    context = { operationId: operation.id, parentEventId: operation.root_event_id,
      executorType: worker ? 'worker' : 'unknown', executorId: worker ? 'background' : null,
      source: 'activity_log' };
  }
  return runWithAuditContext(context, () => recordAuditEvent(db, {
    kind: action, source: 'activity_log', status: 'observed', details: {
      ...details, recipientId: details?.toUserId, messageType: details?.type,
    },
    targetType: UUID.test(details?.messageId || '') ? 'message' : null,
    targetId: UUID.test(details?.messageId || '') ? details.messageId : null,
  }));
}

function auditedSocketHandler({ getPool, userId, action, onError, accept }, handler) {
  return async (...args) => {
    if (accept && !accept(...args)) return;
    let db, operation;
    try {
      db = await getPool();
      operation = await beginOperation(db, { action, initiatorId: userId,
        executorType: 'user', executorId: userId, source: 'socket', status: 'observed',
        ...requestTarget({route:{path:action==='send_group_message'?'/api/groups/:id/messages':'/api/messages'},body:args[0],user:{id:userId}}),details:dispatchDetails(args[0]) });
    } catch (error) {
      console.error('[system-audit:socket-start]', error.code || 'write_failed');
      onError?.('AUDIT_UNAVAILABLE');
      return;
    }
    return runWithAuditContext({ operationId: operation.id,
        parentEventId: operation.root_event_id, initiatorId: userId,
        executorType: 'system', executorId: 'socket', source: 'socket' }, async () => {
      try { return await handler(...args); }
      catch (error) {
        await observeAudit(db, { kind: 'socket_handler_failed', status: 'failed',
          operationStatus: 'failed', reasonCode: 'handler_error' });
        console.error('[system-audit:socket-handler]', error.code || 'handler_failed');
        onError?.('MESSAGE_PROCESSING_FAILED');
      }
    });
  };
}

async function withPendingAudit(db, row, callback) {
  // Legacy queue rows have no causal evidence. Never borrow a context from
  // another upload that happened to wake this worker.
  const context = row.audit_operation_id ? { operationId: row.audit_operation_id,
    parentEventId: row.audit_parent_event_id, initiatorId: row.user_id,
    executorType: 'worker', executorId: 'pending_scans', source: 'scan_worker' } : {};
  return runWithAuditContext(context, callback);
}

async function setAuditTransactionContext(db) {
  const audit = getAuditContext();
  if (!audit?.operationId) return;
  await db.query(
    "SELECT set_config('app.audit_operation_id',$1,true), set_config('app.audit_parent_event_id',$2,true)",
    [audit.operationId, audit.parentEventId || '']);
}

// Explicitly scoped to a media write. Never persist context on a pooled session
// or attach a later rescan to the file's original upload merely by its ID.
async function auditedMediaQuery(db, sql, values) {
  const audit = getAuditContext();
  if (!audit?.operationId) return db.query(sql, values);
  if (typeof db.connect !== 'function') {
    await setAuditTransactionContext(db);
    return db.query(sql, values);
  }
  const client = await db.connect();
  try {
    await client.query('BEGIN');
    await setAuditTransactionContext(client);
    const result = await client.query(sql, values);
    await client.query('COMMIT');
    return result;
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    throw error;
  } finally { client.release(); }
}

module.exports = { dispatchDetails, dispatchReason, emitDispatchRejection, auditIds, createRequestAudit, restoreRequestAuditContext, uploadAuditDetails, mirrorActivity, observeAudit,
  auditedSocketHandler, withPendingAudit, requestAction, responseOutcome,
  auditedMediaQuery, setAuditTransactionContext };
