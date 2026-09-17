'use strict';

const { createHash } = require('node:crypto');

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TYPES = { image: 'התמונה', video: 'הסרטון', audio: 'ההקלטה', document: 'המסמך' };

function safeReason(value) {
  return String(value || '').replace(/[\u0000-\u001f\u007f\u202a-\u202e\u2066-\u2069]/g, ' ')
    // Reasons can originate in scanners. Never turn an internal path or URL
    // into a clickable attachment, including in an otherwise text-only notice.
    .replace(/(?:https?:\/\/|www\.|\/)[^\s]+/gi, '[כתובת הוסרה]')
    .replace(/\s+/g, ' ').trim().slice(0, 240);
}

// This helper is called only after a real rejection. It cannot approve, attach,
// rescan or restore media. The mandatory authorization callback checks the
// sender's access to the exact rejected file inside the notice transaction.
async function notifyGuideRejectedSend({ pool, guideUserId, guideUserName = 'ישראל מדריך בתשובה',
  userId, targetType, targetId = null, fileId, fileType, kind, reason, authorize, relay }) {
  if (!pool || typeof pool.connect !== 'function' || typeof authorize !== 'function' ||
      typeof relay !== 'function' || ![guideUserId, userId, fileId].every(id => UUID.test(String(id))) ||
      guideUserId === userId || !Object.hasOwn(TYPES, fileType) ||
      !['sender_filter', 'moderation'].includes(kind) ||
      !['chat', 'group', 'general'].includes(targetType) ||
      (targetType === 'general' ? targetId != null : !UUID.test(String(targetId))))
    throw new TypeError('Invalid sender-only rejection notice');
  const explanation = safeReason(reason) || (kind === 'sender_filter'
    ? 'סוג התוכן חסום בהגדרות הסינון שלך' : 'הקובץ לא עבר את בדיקת התוכן');
  const verb = fileType === 'image' || fileType === 'audio' ? 'לא נשלחה' : 'לא נשלח';
  const body = `${TYPES[fileType]} ${verb}. ${
    kind === 'sender_filter' ? 'לפי הגדרות הסינון שלך' : 'לפי בדיקת התוכן'}: ${explanation}`;
  const key = createHash('sha256').update(JSON.stringify([
    userId.toLowerCase(), fileId.toLowerCase(), targetType, targetId?.toLowerCase() || null,
    kind, explanation,
  ])).digest('hex');
  const client = await pool.connect();
  let notice;
  try {
    await client.query('BEGIN');
    await client.query("SET LOCAL statement_timeout='10s'");
    await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))', [`guide-rejected-send:${key}`]);
    if (!await authorize(client)) {
      await client.query('ROLLBACK');
      return null;
    }
    const existing = await client.query(`SELECT id FROM messages
      WHERE sender_id=$1 AND recipient_id=$2 AND group_id IS NULL AND type='text'
        AND delivery_summary->'guideRejectedSend'->>'key'=$3
      ORDER BY created_at DESC LIMIT 1`, [guideUserId, userId, key]);
    if (existing.rows.length) {
      await client.query('COMMIT');
      return { duplicate: true, noticeMessageId: existing.rows[0].id };
    }
    const saved = await client.query(`INSERT INTO messages
      (sender_id,recipient_id,type,body,delivery_summary,created_at)
      VALUES($1,$2,'text',$3,$4::jsonb,clock_timestamp()) RETURNING id,created_at`,
    [guideUserId, userId, body, JSON.stringify({ guideRejectedSend: { key, kind } })]);
    notice = saved.rows[0];
    await client.query('COMMIT');
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    throw error;
  } finally { client.release(); }
  await relay(userId, 'chat:message', { id: notice.id, fromUserId: guideUserId,
    fromName: guideUserName, text: body, fileType: 'text', createdAt: notice.created_at });
  return { duplicate: false, noticeMessageId: notice.id };
}

module.exports = { notifyGuideRejectedSend };
