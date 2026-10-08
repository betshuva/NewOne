'use strict';
const { marketplaceConversation } = require('./friendship-policy');

const { contentAllowedByFilter } = require('./content-filter-policy');
const { shortFilterReason } = require('./guide-filter-notice');

const REQUEST_SCHEMA = `ALTER TABLE message_requests
  ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'pending',
  ADD COLUMN IF NOT EXISTS rejection_reason TEXT,
  ADD COLUMN IF NOT EXISTS rejection_code TEXT,
  ADD COLUMN IF NOT EXISTS resolved_at TIMESTAMPTZ;
  CREATE INDEX IF NOT EXISTS message_requests_pending_recipient
    ON message_requests(recipient_id,sender_id,created_at) WHERE status='pending';`;

async function lockContactRequests(db, senderId, recipientId) {
  await db.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))',
    [`contact-request:${senderId}:${recipientId}`]);
}

// A pool starts a transaction; a caller-owned client joins its transaction.
// Serialize queueing with acceptance/decline, and deduplicate the same pending
// attachment when an upload retry races with the ordinary send path.
async function queueContactRequest(db, { senderId, recipientId, body, type,
  fileUrl, fileName, operationId = null, parentEventId = null }) {
  const ownTransaction = typeof db.connect === 'function' && !(db instanceof require('pg').Client);
  const client = ownTransaction ? await db.connect() : db;
  try {
    if (ownTransaction) await client.query('BEGIN');
    await lockContactRequests(client, senderId, recipientId);
    const blocked = await client.query('SELECT 1 FROM blocked_users WHERE blocker_id=$1 AND blocked_id=$2',
      [recipientId, senderId]);
    if (blocked.rows.length) throw Object.assign(new Error('נחסמת על ידי הנמען'),
      { status: 403, code: 'RECIPIENT_BLOCKED_SENDER' });
    const contact = await client.query('SELECT 1 FROM user_contacts WHERE owner_id=$1 AND contact_id=$2',
      [recipientId, senderId]);
    let request = null;
    if (String(senderId) !== String(recipientId) && !contact.rows.length &&
        !await marketplaceConversation(client,senderId,recipientId)) {
      if (fileUrl) request = (await client.query(`SELECT id,created_at FROM message_requests
        WHERE sender_id=$1 AND recipient_id=$2 AND file_url=$3 AND status='pending'
        ORDER BY created_at LIMIT 1`, [senderId, recipientId, fileUrl])).rows[0];
      if (!request) request = (await client.query(`INSERT INTO message_requests
        (sender_id,recipient_id,body,type,file_url,file_name,audit_operation_id,audit_parent_event_id)
        VALUES ($1,$2,$3,$4,$5,$6,$7,$8) RETURNING id,created_at`,
      [senderId, recipientId, body || null, type, fileUrl || null, fileName || null,
        operationId, parentEventId])).rows[0];
    }
    if (ownTransaction) await client.query('COMMIT');
    return request;
  } catch (error) {
    if (ownTransaction) await client.query('ROLLBACK').catch(() => {});
    throw error;
  } finally { if (ownTransaction) client.release(); }
}

// The caller owns the pair lock and transaction. No media or message is sent
// until the selected recipient policy AND current source access have passed.
async function settleContactRequests(db, { senderId, recipientId, filter, decline = false,
  validateFile, audit, auditIds = () => [null, null] }) {
  const pending = await db.query(`SELECT mr.*,sf.file_type AS stored_type,
      sf.moderation_status,sf.moderation_details,sf.content_purged_at
    FROM message_requests mr LEFT JOIN stored_files sf ON sf.public_url=mr.file_url
    WHERE mr.sender_id=$1 AND mr.recipient_id=$2 AND mr.status='pending'
    ORDER BY mr.created_at,mr.id FOR UPDATE OF mr`, [senderId, recipientId]);
  const blockedUser = await db.query('SELECT 1 FROM blocked_users WHERE blocker_id=$1 AND blocked_id=$2',
    [recipientId, senderId]);
  const sent = [], rejected = [];
  for (const request of pending.rows) {
    const type = request.file_url ? request.stored_type || request.type : request.type;
    let reason = null, code = null;
    if (decline) { reason = 'הנמען דחה את בקשת החברות'; code = 'contact_request_declined'; }
    else if (blockedUser.rows.length) { reason = 'נחסמת על ידי הנמען'; code = 'recipient_blocked_sender'; }
    else if (request.file_url && (request.moderation_status !== 'approved' || request.content_purged_at)) {
      reason = request.moderation_details?.reason || 'הקובץ אינו זמין או שבדיקת הבטיחות שלו לא הושלמה';
      code = 'file_not_approved';
    } else if (!contentAllowedByFilter(filter, type, request.moderation_details?.classification)) {
      reason = shortFilterReason({ filter, fileType: type,
        classification: request.moderation_details?.classification }) + ' בהגדרות הנמען';
      code = 'recipient_content_filter';
    } else if (request.file_url) {
      try {
        if (!await validateFile(db, senderId, request.file_url, 'chat', recipientId)) {
          reason = 'לשולח אין הרשאה לשלוח את הקובץ'; code = 'file_access_denied';
        }
      } catch (error) {
        if (error.code !== 'SENDER_CONTENT_FILTERED') throw error;
        reason = error.message; code = 'sender_content_filter';
      }
    }
    if (reason) {
      await db.query(`UPDATE message_requests SET status='rejected',rejection_reason=$1,
        rejection_code=$2,resolved_at=now() WHERE id=$3`, [reason, code, request.id]);
      rejected.push({ id: request.id, reason, code });
      await audit(db, request, { rejected: true, reason, code });
    } else {
      const fallback = auditIds();
      const saved = await db.query(`INSERT INTO messages
        (sender_id,recipient_id,body,type,file_url,file_name,audit_operation_id,audit_parent_event_id)
        VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
        RETURNING id,created_at,sender_id,body,type,file_url,file_name`,
      [senderId, recipientId, request.body, type, request.file_url, request.file_name,
        request.audit_operation_id || fallback[0],
        request.audit_operation_id ? request.audit_parent_event_id : fallback[1]]);
      const message = saved.rows[0];
      await audit(db, request, { message });
      await db.query('DELETE FROM message_requests WHERE id=$1', [request.id]);
      sent.push(message);
    }
  }
  return { sent, rejected };
}

module.exports = { REQUEST_SCHEMA, lockContactRequests, queueContactRequest, settleContactRequests };
