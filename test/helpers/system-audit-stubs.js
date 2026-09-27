'use strict';

// Domain-handler fixtures isolate audit plumbing; its real context and storage
// behavior is exercised by the dedicated system-audit suites.
module.exports = {
  emitDispatchRejection: async (_getPool,socket,payload) => socket.emit('message:rejected',payload),
  auditIds: () => [null, null],
  getAuditContext: () => null,
  runWithAuditContext: (_context, callback) => callback(),
  withPendingAudit: async (_db, _row, callback) => callback(),
  observeAudit: async () => null,
  auditedSocketHandler: (_options, handler) => handler,
  requestAudit: (_req, _res, next) => next(),
  restoreRequestAuditContext: (_req, _res, next) => next(),
  uploadAuditDetails: (_body, mediaType) => ({ mediaType }),
  auditedMediaQuery: (db, sql, values) => db.query(sql, values),
  setAuditTransactionContext: async () => {},
};

Object.assign(module.exports, require('../../server/moderation-user-reason'));
