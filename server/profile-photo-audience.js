'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const path = require('node:path');
const sharp = require('sharp');
const { readSourceMedia } = require('./received-media');
const { getProfileAssetMetadata } = require('./profile-image-assets');

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PHOTO_BASE = '/betshuva-app/api/profile-photos/';
const SCHEMA = `
ALTER TABLE users ADD COLUMN IF NOT EXISTS profile_photo_user_ids UUID[] NOT NULL DEFAULT '{}';
ALTER TABLE users ADD COLUMN IF NOT EXISTS profile_photo_group_ids UUID[] NOT NULL DEFAULT '{}';
CREATE TABLE IF NOT EXISTS profile_photo_assets (
  id UUID PRIMARY KEY, owner_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  source_url TEXT NOT NULL, classification JSONB, image_bytes BYTEA NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS profile_photo_assets_owner_idx ON profile_photo_assets(owner_id);
`;

function audienceAllowedSql(owner = 'u', viewer = '$1') {
  return `((${owner}.id=${viewer} OR ${owner}.privacy_pic='all'
    OR (${owner}.privacy_pic='contacts' AND EXISTS (
      SELECT 1 FROM user_contacts c WHERE c.owner_id=${owner}.id AND c.contact_id=${viewer}))
    OR (${owner}.privacy_pic='selected' AND (${viewer}=ANY(${owner}.profile_photo_user_ids)
      OR EXISTS (SELECT 1 FROM group_members mine JOIN group_members theirs
        ON theirs.group_id=mine.group_id AND theirs.user_id=${viewer} AND theirs.status='member'
        WHERE mine.user_id=${owner}.id AND mine.status='member'
          AND mine.group_id=ANY(${owner}.profile_photo_group_ids)))))
    AND NOT EXISTS (SELECT 1 FROM blocked_users b
      WHERE (b.blocker_id=${owner}.id AND b.blocked_id=${viewer})
         OR (b.blocker_id=${viewer} AND b.blocked_id=${owner}.id)))`;
}

function profileOwnerId(row) {
  return row.seller_id || row.sender_id || row.user_id || row.id;
}

async function projectAudience(pool, viewerId, rows, fields) {
  const ids = [...new Set(rows.filter(row => fields.some(field => row[field])).map(row => profileOwnerId(row)).filter(Boolean))];
  if (!ids.length) return rows;
  const owners = await pool.query(`SELECT u.id,${audienceAllowedSql()} AS photo_audience_allowed
    FROM users u WHERE u.id::text=ANY($2::text[])`, [viewerId, ids]);
  const allowed = new Map(owners.rows.map(row => [row.id, row.photo_audience_allowed]));
  return rows.map(row => {
    if (allowed.get(profileOwnerId(row)) !== false) return row;
    return { ...row, ...Object.fromEntries(fields.filter(field => Object.hasOwn(row, field))
      .map(field => [field, null])) };
  });
}

function photoId(url) {
  if (typeof url !== 'string') return null;
  const pathname = url.split('?')[0];
  const id = pathname.startsWith(PHOTO_BASE) ? pathname.slice(PHOTO_BASE.length) : '';
  return UUID.test(id) ? id : null;
}

function signature(id, viewer, expires, secret) {
  return crypto.createHmac('sha256', secret).update(`profile-photo:v1:${id}:${viewer}:${expires}`).digest('hex');
}

function signedPhotoUrl(url, viewer, secret = process.env.JWT_SECRET, now = Date.now()) {
  const id = photoId(url);
  if (!id) return url;
  if (!secret) return null;
  // Hour buckets keep avatar URLs stable across list refreshes. Every byte
  // request still rechecks the current audience and current profile photo.
  const expires = (Math.floor(now / 3600000) + 2) * 3600;
  return `${PHOTO_BASE}${id}?viewer=${viewer}&expires=${expires}&sig=${signature(id, viewer, expires, secret)}`;
}

function validPhotoTicket(id, query, secret, now = Date.now()) {
  const { viewer, expires, sig } = query;
  if (!UUID.test(id) || !UUID.test(viewer || '') || !/^\d{10}$/.test(expires || '') ||
      !/^[a-f0-9]{64}$/.test(sig || '') || !secret) return false;
  if (Number(expires) <= now / 1000 || Number(expires) > now / 1000 + 7200) return false;
  return crypto.timingSafeEqual(Buffer.from(sig, 'hex'),
    Buffer.from(signature(id, viewer, expires, secret), 'hex'));
}

function normalizeAudience(body, current, teen = false) {
  const mode = body.privacy_pic ?? current.privacy_pic ?? 'all';
  if (!['all', 'contacts', 'nobody', 'selected'].includes(mode))
    throw Object.assign(new Error('בחירת פרטיות לא תקינה'), { status: 400 });
  const ids = (value, fallback) => {
    const values = value ?? fallback ?? [];
    if (!Array.isArray(values) || values.length > 500 || values.some(id => typeof id !== 'string' || !UUID.test(id)))
      throw Object.assign(new Error('רשימת הצופים אינה תקינה'), { status: 400 });
    return [...new Set(values.map(id => id.toLowerCase()))];
  };
  const userIds = ids(body.profile_photo_user_ids, current.profile_photo_user_ids);
  const groupIds = ids(body.profile_photo_group_ids, current.profile_photo_group_ids);
  if (teen && groupIds.length)
    throw Object.assign(new Error('קבוצות אינן זמינות בחשבון נוער'), { status: 403 });
  return { mode: teen && mode === 'all' ? 'contacts' : mode, userIds, groupIds };
}

async function validateAudience(pool, owner, audience, teen, current = {}) {
  if (audience.mode !== 'selected') return;
  const users = await pool.query(`SELECT id FROM users u WHERE id=ANY($2::uuid[])
    AND ((NOT $3::boolean AND u.birth_date<=CURRENT_DATE-INTERVAL '18 years')
      OR EXISTS (SELECT 1 FROM user_contacts c WHERE c.owner_id=$1 AND c.contact_id=u.id))`, [owner, audience.userIds, teen]);
  const groups = await pool.query(`SELECT group_id FROM group_members
    WHERE user_id=$1 AND status='member' AND group_id=ANY($2::uuid[])`, [owner, audience.groupIds]);
  const userIds = new Set(users.rows.map(row => row.id));
  const groupIds = new Set(groups.rows.map(row => row.group_id));
  if (audience.userIds.some(id => !userIds.has(id) && !(current.profile_photo_user_ids || []).includes(id)) ||
      audience.groupIds.some(id => !groupIds.has(id) && !(current.profile_photo_group_ids || []).includes(id)))
    throw Object.assign(new Error('יש לבחור משתמשים קיימים וקבוצות שבהן אתה חבר פעיל'), { status: 400 });
  // A deleted person or a group the owner has left must not make their own
  // existing profile impossible to save. Remove only previously saved choices.
  audience.userIds = audience.userIds.filter(id => userIds.has(id));
  audience.groupIds = audience.groupIds.filter(id => groupIds.has(id));
}

// Profile copies are private database bytes, outside public uploads. Sharing an image in a chat is
// a separate action; choosing it as an avatar never publishes its source URL.
async function prepareProfilePhoto(pool, owner, url, currentUrl, { trustedMessage = false, requirePrivate = false } = {}) {
  if (url != null && typeof url !== 'string')
    throw Object.assign(new Error('תמונת פרופיל לא תקינה'), { status: 400 });
  if (!url || url.startsWith('emoji:')) return url || null;
  if (url === currentUrl && !requirePrivate && !photoId(url)) return url;
  if (photoId(url)) {
    const canonical = PHOTO_BASE + photoId(url);
    if (canonical !== (currentUrl || '').split('?')[0])
      throw Object.assign(new Error('תמונת הפרופיל אינה שייכת לחשבון'), { status: 400 });
    return canonical;
  }
  const source = await pool.query(`SELECT *,moderation_details->'classification' AS classification
    FROM stored_files WHERE public_url=$1 AND moderation_status='approved'
      AND file_type='image' AND content_purged_at IS NULL
      AND COALESCE((moderation_details->>'blocked')::boolean,FALSE)=FALSE
      AND (user_id=$2 OR $3::boolean) LIMIT 1`, [url, owner, trustedMessage || url === currentUrl]);
  let bytes;
  let classification;
  if (source.rows.length) {
    const file = source.rows[0];
    if (Number(file.file_size) > 10 * 1024 * 1024)
      throw Object.assign(new Error('תמונת הפרופיל גדולה מדי'), { status: 400 });
    bytes = await readSourceMedia(pool, path.join(__dirname, '..', 'uploads'), file);
    classification = file.classification;
  } else if (url === currentUrl) {
    // Legacy reviewed assets and Google avatars can be made private too.
    const reviewed = await getProfileAssetMetadata(url);
    if (reviewed) {
      bytes = await fs.readFile(path.join(__dirname, '..', url.split('?')[0].replace('/betshuva-app/', '')));
      classification = reviewed.classification;
    } else {
      let parsed;
      try { parsed = new URL(url); } catch (_) {}
      if (!parsed || parsed.protocol !== 'https:' || parsed.username || parsed.password ||
          parsed.port || !/^lh\d+\.googleusercontent\.com$/.test(parsed.hostname))
        throw Object.assign(new Error('כדי לשנות את פרטיות התמונה יש להעלות אותה מחדש'), { status: 400 });
      const response = await fetch(parsed, { redirect: 'error', signal: AbortSignal.timeout(10000) });
      if (!response.ok) throw Object.assign(new Error('לא ניתן לטעון את התמונה; נסה להעלות אותה מחדש'), { status: 400 });
      const chunks = [];
      let size = 0;
      for await (const chunk of response.body) {
        size += chunk.length;
        if (size > 10 * 1024 * 1024) {
          await response.body.cancel().catch(() => {});
          throw Object.assign(new Error('תמונת הפרופיל גדולה מדי'), { status: 400 });
        }
        chunks.push(chunk);
      }
      bytes = Buffer.concat(chunks);
    }
  } else {
    throw Object.assign(new Error('יש לבחור תמונה שלך שאושרה בסריקה'), { status: 400 });
  }
  if (bytes.length > 10 * 1024 * 1024)
    throw Object.assign(new Error('תמונת הפרופיל גדולה מדי'), { status: 400 });
  const image = await sharp(bytes, { limitInputPixels: 25000000 }).rotate()
    .resize(512, 512, { fit: 'inside', withoutEnlargement: true }).webp({ quality: 85 }).toBuffer();
  const id = crypto.randomUUID();
  await pool.query(`INSERT INTO profile_photo_assets(id,owner_id,source_url,classification,image_bytes)
    VALUES($1,$2,$3,$4,$5)`, [id, owner, url, classification || null, image]);
  return PHOTO_BASE + id;
}

function registerProfilePhotoAudience(app, { auth, getPool, secret }) {
  app.get('/api/profile/photo-audience', auth, async (req, res) => {
    try {
      const pool = await getPool();
      const me = await pool.query(`SELECT privacy_pic,profile_photo_user_ids,profile_photo_group_ids,
        (birth_date IS NULL OR birth_date>CURRENT_DATE-INTERVAL '18 years') AS is_teen FROM users WHERE id=$1`, [req.user.id]);
      if (!me.rows.length) return res.status(404).json({ error: 'החשבון לא נמצא' });
      const teen = me.rows[0].is_teen;
      const users = await pool.query(`SELECT u.id,u.name FROM users u WHERE u.id<>$1
        AND (u.email_verified=TRUE OR u.phone_verified=TRUE)
        AND (EXISTS (SELECT 1 FROM user_contacts c WHERE c.owner_id=$1 AND c.contact_id=u.id)
          OR (NOT $2::boolean AND u.birth_date<=CURRENT_DATE-INTERVAL '18 years'))
        AND NOT EXISTS (SELECT 1 FROM blocked_users b WHERE b.blocker_id=$1 AND b.blocked_id=u.id)
        ORDER BY u.name`, [req.user.id, teen]);
      const groups = teen ? { rows: [] } : await pool.query(`SELECT g.id,g.name FROM groups g
        JOIN group_members gm ON gm.group_id=g.id WHERE gm.user_id=$1 AND gm.status='member'
        AND COALESCE(g.is_self,FALSE)=FALSE ORDER BY g.name`, [req.user.id]);
      res.set('Cache-Control', 'private, no-store').json({ ...me.rows[0], users: users.rows, groups: groups.rows });
    } catch (_) { res.status(500).json({ error: 'לא ניתן לטעון את בחירת הצופים' }); }
  });

  app.get('/api/profile-photos/:id', async (req, res) => {
    res.set({ 'Cache-Control': 'private, no-store', 'Referrer-Policy': 'no-referrer', 'X-Content-Type-Options': 'nosniff' });
    if (!validPhotoTicket(req.params.id, req.query, secret)) return res.status(403).end();
    try {
      const pool = await getPool();
      const result = await pool.query(`SELECT a.owner_id,a.image_bytes,COALESCE(sf.moderation_details->'classification',a.classification) AS classification,
        COALESCE(sf.moderation_status,'approved') AS moderation_status,NULL AS content_purged_at,
        sf.moderation_details->'blocked' AS blocked,v.content_filter FROM profile_photo_assets a
        JOIN users u ON u.id=a.owner_id JOIN users v ON v.id=$1
        LEFT JOIN stored_files sf ON sf.public_url=a.source_url
        WHERE a.id=$2 AND u.profile_pic_url=$3 AND ${audienceAllowedSql()}`,
      [req.query.viewer, req.params.id, PHOTO_BASE + req.params.id]);
      if (!result.rows.length) return res.status(404).end();
      if (result.rows[0].moderation_status !== 'approved' || result.rows[0].content_purged_at || result.rows[0].blocked === true)
        return res.status(403).end();
      const { profileImageAllowed } = require('./profile-image-policy');
      if (req.query.viewer !== result.rows[0].owner_id &&
          !profileImageAllowed(PHOTO_BASE + req.params.id, result.rows[0].content_filter, {
            ...result.rows[0], file_type: 'image' }))
        return res.status(403).end();
      return res.type('webp').send(result.rows[0].image_bytes);
    } catch (_) { return res.status(404).end(); }
  });
}

module.exports = { SCHEMA, PHOTO_BASE, audienceAllowedSql, projectAudience, photoId,
  signedPhotoUrl, validPhotoTicket, normalizeAudience, validateAudience,
  prepareProfilePhoto, registerProfilePhotoAudience };
