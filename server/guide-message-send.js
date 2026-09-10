'use strict';

const { phoneSelect } = require('./contact-phone-privacy');

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function registerGuideMessageSend(app, { auth, rateLimit, getPool, systemUserId,
  safeInformationUserId, scanBotId, sendMessage }) {
  app.get('/api/guide-message-recipients', auth, async (req, res) => {
    try {
      const pool = await getPool();
      const result = await pool.query(`SELECT u.id,u.name,${phoneSelect()},u.email
        FROM user_contacts c JOIN users u ON u.id=c.contact_id
        WHERE c.owner_id=$1 AND u.id<>ALL($2::uuid[])
          AND NOT EXISTS (SELECT 1 FROM blocked_users b
            WHERE (b.blocker_id=$1 AND b.blocked_id=u.id)
               OR (b.blocker_id=u.id AND b.blocked_id=$1))
        ORDER BY u.name,u.id`, [req.user.id, [systemUserId,safeInformationUserId,scanBotId]]);
      return res.json(result.rows);
    } catch (_) { return res.status(500).json({ error: 'לא ניתן לטעון אנשי קשר' }); }
  });
  async function ownedDraft(pool, userId, sourceId) {
    if (!UUID.test(sourceId || '')) return false;
    const result = await pool.query(`SELECT body FROM messages
      WHERE id=$1 AND sender_id=$2 AND recipient_id=$3
        AND deleted_for_everyone=FALSE`, [sourceId, systemUserId, userId]);
    return /betshuva:\/\/message-draft\/[A-Za-z0-9_-]+/.test(result.rows[0]?.body || '');
  }
  app.get('/api/guide-message-drafts/:id', auth, async (req, res) => {
    try {
      const pool = await getPool();
      if (!await ownedDraft(pool, req.user.id, req.params.id))
        return res.status(404).json({ error: 'הטיוטה לא נמצאה' });
      const saved = await pool.query(`SELECT result FROM guide_message_sends
        WHERE source_message_id=$1 AND user_id=$2`, [req.params.id, req.user.id]);
      return res.json({ sent: Boolean(saved.rows.length), result: saved.rows[0]?.result || null });
    } catch (_) { return res.status(500).json({ error: 'לא ניתן לבדוק את מצב הטיוטה' }); }
  });
  app.post('/api/guide-message-drafts/:id/send', auth, rateLimit, async (req, res) => {
    const { toUserId, text, confirmed } = req.body || {};
    if (confirmed !== true || !UUID.test(toUserId || '') ||
        [systemUserId, safeInformationUserId, scanBotId].includes(toUserId) ||
        typeof text !== 'string' || !text.trim() || text.length > 2000)
      return res.status(400).json({ error: 'יש לבחור נמען ולאשר את תוכן ההודעה' });
    const pool = await getPool();
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      await client.query("SET LOCAL statement_timeout='30s'");
      if (!await ownedDraft(client, req.user.id, req.params.id)) {
        await client.query('ROLLBACK');
        return res.status(404).json({ error: 'הטיוטה לא נמצאה' });
      }
      // The transaction serializes confirmations across tabs and server workers.
      await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))', [req.params.id]);
      const saved = await client.query(`SELECT result FROM guide_message_sends
        WHERE source_message_id=$1 AND user_id=$2`, [req.params.id, req.user.id]);
      if (saved.rows.length) {
        await client.query('COMMIT');
        return res.json(saved.rows[0].result);
      }
      const contact = await client.query(`SELECT 1 FROM user_contacts
        WHERE owner_id=$1 AND contact_id=$2`, [req.user.id, toUserId]);
      const blocked = await client.query(`SELECT 1 FROM blocked_users
        WHERE (blocker_id=$1 AND blocked_id=$2) OR (blocker_id=$2 AND blocked_id=$1)`,
      [req.user.id, toUserId]);
      if (!contact.rows.length || blocked.rows.length) {
        await client.query('ROLLBACK');
        return res.status(403).json({ error: 'יש לבחור איש קשר שמור שאינו חסום' });
      }
      let status = 200;
      let result;
      const capture = { status(code) { status = code; return this; },
        json(value) { result = value; return this; } };
      req.body = { toUserId, text: text.trim() };
      req.messagePool = client;
      req.messageEffects = [];
      await sendMessage(req, capture);
      if (status >= 400 || !result?.id) {
        await client.query('ROLLBACK');
        return res.status(status >= 400 ? status : 500).json(result || { error: 'השליחה לא הושלמה' });
      }
      await client.query(`INSERT INTO guide_message_sends(source_message_id,user_id,result)
        VALUES($1,$2,$3::jsonb)`, [req.params.id, req.user.id, JSON.stringify(result)]);
      await client.query('COMMIT');
      for (const effect of req.messageEffects) {
        try { effect(); } catch (error) { console.error('guide send notification:', error.message); }
      }
      return res.json(result);
    } catch (error) {
      await client.query('ROLLBACK').catch(() => {});
      console.error('guide message send:', error.message);
      return res.status(500).json({ error: 'לא ניתן לשלוח כעת. אפשר לנסות שוב בבטחה.' });
    } finally { client.release(); }
  });
}

module.exports = { registerGuideMessageSend };
