'use strict';

const crypto = require('node:crypto');
const { accountAgeError } = require('./adult-access-policy');
const { NEW_ACCOUNT_CONTENT_FILTER } = require('./content-filter-policy');
const { profileImageAllowed, projectProfileImages } = require('./profile-image-policy');
const { getProfileAssetMetadata } = require('./profile-image-assets');

const SCHEMA = `CREATE TABLE IF NOT EXISTS group_invite_links (
  group_id UUID PRIMARY KEY REFERENCES groups(id) ON DELETE CASCADE,
  issued_by UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  nonce TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE OR REPLACE FUNCTION betshuva_invalidate_group_invite_issuer()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP='DELETE' OR NEW.status<>'member' OR NEW.role<>'admin' THEN
    DELETE FROM group_invite_links WHERE group_id=OLD.group_id AND issued_by=OLD.user_id;
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS group_invite_link_issuer ON group_members;
CREATE TRIGGER group_invite_link_issuer AFTER DELETE OR UPDATE OF role,status ON group_members
  FOR EACH ROW EXECUTE FUNCTION betshuva_invalidate_group_invite_issuer();`;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TOKEN = /^[A-Za-z0-9_-]{43}$/;
const PUBLIC_URL = 'https://betshuva.com/betshuva-app/group-invite.html';
const fail = (status, code, message) => Object.assign(new Error(message), { status, code });
const unavailable = () => fail(404, 'GROUP_INVITE_UNAVAILABLE', 'קישור ההזמנה אינו פעיל. בקשו קישור חדש ממנהל הקבוצה');
const tokenHash = token => crypto.createHash('sha256').update(token).digest('hex');

function requireAdult(user) {
  const error = accountAgeError(user);
  if (error) throw fail(error.status, error.code, error.error);
}

// An invitation deliberately exposes only the group title, description and
// an approved avatar. Anonymous visitors keep the default image restrictions.
async function publicAvatar(pool, url) {
  if (!url || url.startsWith('emoji:')) return url || null;
  let parsed;
  try { parsed = new URL(url, 'https://betshuva.com'); } catch { return null; }
  if (parsed.origin !== 'https://betshuva.com' ||
      !/^\/(?:betshuva-app\/)?(?:uploads|assets)\//.test(parsed.pathname)) return null;
  const result = await pool.query(`SELECT public_url, file_type, moderation_status,
      content_purged_at, moderation_details->'classification' AS classification,
      moderation_details->'blocked' AS blocked
    FROM stored_files WHERE public_url=$1`, [url]);
  const file = result.rows[0] || await getProfileAssetMetadata(url);
  return profileImageAllowed(url, NEW_ACCOUNT_CONTENT_FILTER, file) ? url : null;
}

function createGroupInviteLinks({ getPool, secret, projectImages = projectProfileImages,
  avatar = publicAvatar }) {
  if (!secret) throw new Error('A server secret is required for group invitation links');
  // Store only a token digest. The random nonce lets an administrator recover
  // the same shareable link without storing its secret value in the database.
  const tokenFor = row => crypto.createHmac('sha256', secret)
    .update(`betshuva:group-invite:v1:${row.group_id}:${row.issued_by}:${row.nonce}`)
    .digest('base64url');

  async function transaction(operation) {
    const client = await (await getPool()).connect();
    try {
      await client.query('BEGIN');
      const result = await operation(client);
      await client.query('COMMIT');
      return result;
    } catch (error) {
      await client.query('ROLLBACK').catch(() => {});
      throw error;
    } finally { client.release(); }
  }

  async function activeLink(db, token, { lock = false } = {}) {
    if (typeof token !== 'string' || !TOKEN.test(token)) throw unavailable();
    // Joining takes the same group lock as reset/issue. A revoked token can
    // never be accepted after rotation has committed, including racing joins.
    if (lock) {
      const found = await db.query(`SELECT g.id FROM groups g
        JOIN group_invite_links link ON link.group_id=g.id
        WHERE link.token_hash=$1 AND g.is_self=FALSE FOR UPDATE OF g`, [tokenHash(token)]);
      if (!found.rows.length) throw unavailable();
    }
    const result = await db.query(`SELECT g.*, link.issued_by, issuer.name AS inviter_name,
        issuer.birth_date AS inviter_birth_date
      FROM group_invite_links link JOIN groups g ON g.id=link.group_id
      JOIN group_members admin ON admin.group_id=g.id AND admin.user_id=link.issued_by
        AND admin.status='member' AND admin.role='admin'
      JOIN users issuer ON issuer.id=link.issued_by
      WHERE link.token_hash=$1 AND g.is_self=FALSE
      ${lock ? 'FOR SHARE OF admin, issuer' : ''}`, [tokenHash(token)]);
    const row = result.rows[0];
    if (!row || accountAgeError({ birth_date: row.inviter_birth_date })) throw unavailable();
    return row;
  }

  async function issue(groupId, userId, { reset = false } = {}) {
    if (!UUID.test(groupId || '')) throw fail(400, 'INVALID_GROUP_ID', 'הקבוצה אינה תקינה');
    return transaction(async db => {
      const group = await db.query('SELECT id,is_self FROM groups WHERE id=$1 FOR UPDATE', [groupId]);
      if (!group.rows.length || group.rows[0].is_self) throw unavailable();
      const admin = await db.query(`SELECT u.birth_date FROM group_members gm
        JOIN users u ON u.id=gm.user_id
        WHERE gm.group_id=$1 AND gm.user_id=$2 AND gm.role='admin' AND gm.status='member'
        FOR SHARE OF gm, u`, [groupId, userId]);
      if (!admin.rows.length) throw fail(403, 'GROUP_ADMIN_REQUIRED', 'רק מנהל פעיל יכול ליצור קישור הזמנה');
      requireAdult(admin.rows[0]);
      const existing = await db.query(`SELECT link.*, u.birth_date AS issuer_birth_date FROM group_invite_links link
        JOIN group_members gm ON gm.group_id=link.group_id AND gm.user_id=link.issued_by
          AND gm.status='member' AND gm.role='admin'
        JOIN users u ON u.id=gm.user_id
        WHERE link.group_id=$1`, [groupId]);
      let row = existing.rows[0];
      if (row && accountAgeError({ birth_date: row.issuer_birth_date })) row = null;
      if (reset || !row || tokenHash(tokenFor(row)) !== row.token_hash) {
        row = { group_id: groupId, issued_by: userId, nonce: crypto.randomBytes(32).toString('hex') };
        await db.query(`INSERT INTO group_invite_links(group_id,issued_by,nonce,token_hash)
          VALUES($1,$2,$3,$4) ON CONFLICT(group_id) DO UPDATE SET
          issued_by=EXCLUDED.issued_by,nonce=EXCLUDED.nonce,token_hash=EXCLUDED.token_hash,created_at=now()`,
        [groupId, userId, row.nonce, tokenHash(tokenFor(row))]);
      }
      const token = tokenFor(row);
      return { url: `${PUBLIC_URL}?groupInvite=${token}`, token, groupId };
    });
  }

  async function preview(token) {
    const pool = await getPool();
    const row = await activeLink(pool, token);
    return { group: { id: row.id, name: row.name, description: row.description || '',
      avatar_url: await avatar(pool, row.profile_pic_url) }, inviter: { name: row.inviter_name } };
  }

  async function join(token, userId) {
    const result = await transaction(async db => {
      const row = await activeLink(db, token, { lock: true });
      const user = await db.query('SELECT birth_date FROM users WHERE id=$1 FOR SHARE', [userId]);
      if (!user.rows.length) throw fail(401, 'USER_NOT_FOUND', 'יש להתחבר מחדש');
      requireAdult(user.rows[0]);
      const previous = await db.query(`SELECT status FROM group_members
        WHERE group_id=$1 AND user_id=$2 FOR UPDATE`, [row.id, userId]);
      // Invitation acceptance does not edit filters. New members inherit their
      // general filter; pending/existing members retain their chosen override.
      // Phone sharing is off until the new member explicitly chooses otherwise.
      const membership = await db.query(`INSERT INTO group_members AS member
          (group_id,user_id,role,status,added_by,filter_override,share_phone)
        VALUES($1,$2,'member','member',$3,NULL,FALSE)
        ON CONFLICT(group_id,user_id) DO UPDATE SET status='member',pending_since=NULL,
          joined_at=CASE WHEN member.status='member' THEN member.joined_at ELSE now() END,
          added_by=COALESCE(member.added_by,EXCLUDED.added_by),
          share_phone=CASE WHEN member.status='member' THEN member.share_phone ELSE FALSE END
        RETURNING role,status,share_phone`, [row.id, userId, row.issued_by]);
      const count = await db.query(`SELECT COUNT(*)::integer AS member_count FROM group_members
        WHERE group_id=$1 AND status='member'`, [row.id]);
      const { issued_by, inviter_name, inviter_birth_date, ...group } = row;
      return { group: { ...group, ...membership.rows[0], member_count: count.rows[0].member_count },
        alreadyMember: previous.rows[0]?.status === 'member' };
    });
    const [group] = await projectImages(await getPool(), userId, [result.group]);
    return { ...result, group };
  }

  return { issue, preview, join };
}

function registerGroupInviteLinks(app, { auth, getPool, secret,
  rateLimit = (_req, _res, next) => next(), onJoin = () => {}, ...options }) {
  const links = createGroupInviteLinks({ getPool, secret, ...options });
  const handle = operation => async (req, res) => {
    res.set('Cache-Control', 'no-store');
    res.set('Referrer-Policy', 'no-referrer');
    try { res.json(await operation(req)); }
    catch (error) {
      if (!error.status) console.error('group invitation request failed:', error.code || 'unknown');
      res.status(error.status || 503).json({ error: error.status ? error.message : 'לא ניתן לבצע את הפעולה כעת',
        code: error.code || 'GROUP_INVITE_UNAVAILABLE' });
    }
  };
  app.post('/api/groups/:id/invite-link', auth, rateLimit, handle(req => {
    if (req.body?.reset !== undefined && typeof req.body.reset !== 'boolean')
      throw fail(400, 'INVALID_INVITE_RESET', 'בחירת חידוש הקישור אינה תקינה');
    return links.issue(req.params.id, req.user.id, { reset: req.body?.reset === true });
  }));
  app.get('/api/group-invites/:token', rateLimit, handle(req => links.preview(req.params.token)));
  app.post('/api/group-invites/:token/join', auth, rateLimit, handle(async req => {
    const result = await links.join(req.params.token, req.user.id);
    if (!result.alreadyMember) {
      try { await onJoin(req, result.group); }
      catch (error) { console.error('group invitation notification failed:', error.code || 'unknown'); }
    }
    return result;
  }));
  return links;
}

module.exports = { SCHEMA, createGroupInviteLinks, registerGroupInviteLinks, tokenHash };
