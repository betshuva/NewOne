'use strict';
const { createHash } = require('node:crypto');
const { observeAudit } = require('./system-audit-context');

// Keep the result and the message in one transaction. A retry after a lost HTTP
// response returns the same acknowledgement without sending a second message.
function withPrivateMessageReceipt({ getPool, sendMessage, excludedRecipients = [] }) {
  return async (req, res) => {
    const key = req.body?.clientMessageId;
    if (!key || excludedRecipients.includes(req.body?.toUserId))
      return sendMessage(req, res);
    if (typeof key !== 'string' || !/^[a-zA-Z0-9_-]{16,100}$/.test(key))
      return res.status(400).json({ error: 'מזהה השליחה אינו תקין' });
    const content = Object.fromEntries(['toUserId', 'text', 'replyToId', 'fileUrl',
      'fileName', 'fileType', 'listingId', 'stickerId'].map(k => [k, req.body[k] ?? null]));
    const fingerprint = createHash('sha256').update(JSON.stringify(content)).digest('hex');
    let client;
    try {
      client = await (await getPool()).connect();
      await client.query('BEGIN');
      await client.query("SET LOCAL statement_timeout='30s'");
      await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))',
        [`private-send:${req.user.id}:${key}`]);
      const saved = await client.query(`SELECT request_hash,result FROM private_message_sends
        WHERE user_id=$1 AND client_message_id=$2`, [req.user.id, key]);
      if (saved.rows.length) {
        await client.query('COMMIT');
        if (saved.rows[0].request_hash !== fingerprint)
          return res.status(409).json({ error: 'מזהה השליחה כבר שימש להודעה אחרת' });
        await observeAudit(client, { kind: 'message_retry_reused', status: 'completed',
          reasonCode: 'idempotent_replay', details: { messageId: saved.rows[0].result?.id } });
        return res.json(saved.rows[0].result);
      }
      let status = 200, result;
      const capture = { status(code) { status = code; return this; },
        json(value) { result = value; return this; } };
      req.messagePool = client;
      req.messageEffects = [];
      await sendMessage(req, capture);
      if (status >= 400 || !result?.id) {
        await client.query('ROLLBACK');
        return res.status(status >= 400 ? status : 500)
          .json(result || { error: 'השליחה לא הושלמה' });
      }
      await client.query(`INSERT INTO private_message_sends
        (user_id,client_message_id,request_hash,result) VALUES($1,$2,$3,$4::jsonb)`,
      [req.user.id, key, fingerprint, JSON.stringify(result)]);
      await client.query('COMMIT');
      for (const effect of req.messageEffects) {
        try { await effect(); } catch (error) { console.error('message notification:', error.message); }
      }
      return res.json(result);
    } catch (error) {
      if (client) await client.query('ROLLBACK').catch(() => {});
      console.error('private message receipt:', error.message);
      return res.status(500).json({ error: 'השליחה לא הושלמה. ניתן לנסות שוב בבטחה' });
    } finally { client?.release(); }
  };
}
module.exports = { withPrivateMessageReceipt };
