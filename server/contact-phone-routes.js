'use strict';

const { getPhoneSharingStatus, applyPhoneSharingChoices, projectContactPhones } = require('./contact-phone-privacy');

function phoneSharingChoices(body) {
  const choices = {};
  for (const key of ['share_my_phone', 'request_phone', 'phone_response']) {
    if (body && Object.hasOwn(body, key)) choices[key] = body[key];
  }
  return choices;
}

function notifyPhoneSharingChange(io, onlineUsers, actorId, targetId, status) {
  if (!Object.values(status?.changes || {}).some(Boolean)) return;
  // Notifications only invalidate recipient-specific state. Never broadcast a
  // phone number, even when a grant has just been approved.
  for (const [viewerId, otherId] of [[actorId, targetId], [targetId, actorId]]) {
    const socketId = onlineUsers.get(viewerId);
    if (socketId) io.to(socketId).emit('contact:phone-sharing', { userId: otherId });
  }
}

function registerContactPhoneRoutes(app, { auth, rateLimit, getPool, notify = () => {} }) {
  const fail = (res, error) => res.status(error.status || 500)
    .json({ error: error.status ? error.message : 'לא ניתן לעדכן כעת את שיתוף הטלפון', code: error.code });

  app.get('/api/contacts/:userId/phone-sharing', auth, async (req, res) => {
    try {
      const status = await getPhoneSharingStatus(await getPool(), req.user.id, req.params.userId);
      res.set('Cache-Control', 'no-store');
      res.json(status);
    } catch (error) { fail(res, error); }
  });

  app.put('/api/contacts/:userId/phone-sharing', auth, rateLimit, async (req, res) => {
    try {
      const status = await applyPhoneSharingChoices(await getPool(), req.user.id,
        req.params.userId, phoneSharingChoices(req.body));
      notify(req.user.id, req.params.userId, status);
      res.set('Cache-Control', 'no-store');
      res.json(status);
    } catch (error) { fail(res, error); }
  });

  const listPermissions = state => async (req, res) => {
    try {
      const pool = await getPool();
      const result = await pool.query(`SELECT u.id AS user_id,u.name,u.profile_pic_url,
          permission.requested_at,permission.updated_at
        FROM contact_phone_permissions permission JOIN users u ON u.id=permission.viewer_id
        WHERE permission.phone_owner_id=$1 AND permission.state=$2
          AND NOT EXISTS (SELECT 1 FROM blocked_users b
            WHERE (b.blocker_id=$1 AND b.blocked_id=u.id)
               OR (b.blocker_id=u.id AND b.blocked_id=$1))
        ORDER BY permission.updated_at DESC`, [req.user.id, state]);
      const projected = await projectContactPhones(pool, req.user.id,
        result.rows.map(row => ({ id: row.user_id })));
      const allowed = new Set(projected.filter(status =>
        state === 'pending' ? status.incoming_request : status.share_my_phone).map(status => status.id));
      res.set('Cache-Control', 'no-store');
      res.json(result.rows.filter(row => allowed.has(row.user_id)));
    } catch (error) { fail(res, error); }
  };
  app.get('/api/phone-sharing/requests', auth, listPermissions('pending'));
  app.get('/api/phone-sharing/grants', auth, listPermissions('approved'));
}

module.exports = { registerContactPhoneRoutes, phoneSharingChoices, notifyPhoneSharingChange };
