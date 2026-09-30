'use strict';

const { recordAuditEvent } = require('./system-audit');
const { dispatchDetails } = require('./system-audit-context');

function registerUploadRejectionAudit(app, { auth, uploadRateLimit, getPool }) {
  app.post('/api/upload-attempts/rejected', auth, uploadRateLimit, async (req, res) => {
    const body = req.body || {};
    if (body.reasonCode !== 'file_too_large' ||
        typeof body.fileName !== 'string' || !body.fileName.trim() || body.fileName.length > 512 ||
        !['audio', 'video', 'image', 'document', 'file'].includes(body.fileType) ||
        !Number.isSafeInteger(body.fileSize) ||
        ![50 * 1024 * 1024, 150 * 1024 * 1024, 256 * 1024 * 1024].includes(body.maxBytes) ||
        body.fileSize <= body.maxBytes) {
      return res.status(400).json({ error: 'פרטי ניסיון ההעלאה אינם תקינים',
        code: 'INVALID_UPLOAD_REJECTION' });
    }
    const fileName = body.fileName.replace(/[\x00-\x1f\x7f]/g, '')
      .split(/[\\/]/).pop().trim();
    if (!fileName || fileName.startsWith('enc:v1:'))
      return res.status(400).json({ error: 'שם הקובץ אינו תקין', code: 'INVALID_UPLOAD_REJECTION' });
    const reason = `דווח מהדפדפן: ההעלאה נדחתה לפני שליחת הקובץ — הקובץ גדול מדי ` +
      `(${body.fileSize.toLocaleString('en-US')} בייט; מגבלה: ${body.maxBytes / 1048576}MB)`;
    try {
      // Keep this evidence explicitly client-reported. No stored file or
      // delivery is created, and the authenticated account owns the event.
      await recordAuditEvent(await getPool(), {
        kind: 'dispatch_context', source: 'client_upload_validation',
        executorType: 'client', executorId: req.user.id,
        status: 'blocked', operationStatus: 'blocked', reasonCode: 'client_file_too_large',
        details: { ...dispatchDetails({ fileName, fileType: body.fileType }),
          ...(body.fileType === 'file' ? {} : { mediaType: body.fileType }),
          fileSize: body.fileSize, maxBytes: body.maxBytes, clientReported: true,
          dispatchReason: reason },
      });
      return res.json({ recorded: true, status: 'rejected',
        code: 'CLIENT_FILE_TOO_LARGE', reason });
    } catch (error) {
      console.error('[upload-rejection-audit]', error.code || 'write_failed');
      return res.status(503).json({ error: 'לא ניתן לתעד את ניסיון ההעלאה כרגע',
        code: 'AUDIT_UNAVAILABLE' });
    }
  });
}

module.exports = { registerUploadRejectionAudit };
