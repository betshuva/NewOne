'use strict';

const crypto = require('node:crypto');

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SOURCES = new Set(['unknown', 'in_app', 'phone_import', 'phone_manual', 'email_import']);
const REQUEST_COOLDOWN_HOURS = 24;

function fail(status, code, message) {
  throw Object.assign(new Error(message), { status, statusCode: status, code });
}

function checkId(id) {
  if (typeof id !== 'string' || !UUID.test(id))
    fail(400, 'INVALID_USER_ID', 'מזהה המשתמש אינו תקין');
}

function checkPair(actorId, targetId) {
  checkId(actorId);
  checkId(targetId);
  if (actorId.toLowerCase() === targetId.toLowerCase())
    fail(400, 'PHONE_SELF_REQUEST', 'אין צורך בבקשת מספר מעצמך');
}

function normalizePhone(value) {
  if (typeof value !== 'string') return null;
  let digits = value.replace(/[^0-9]/g, '');
  if (digits.startsWith('972') && digits.length > 10) digits = `0${digits.slice(3)}`;
  return digits.length >= 8 && digits.length <= 15 ? digits : null;
}

function phoneFingerprint(phone) {
  const normalized = normalizePhone(phone);
  return normalized ? crypto.createHash('sha256').update(normalized).digest('hex') : null;
}

function normalizedPhoneSql(expression) {
  const digits = `regexp_replace(COALESCE(${expression},''),'[^0-9]','','g')`;
  const normalized = `(CASE WHEN left(${digits},3)='972' AND length(${digits})>10
    THEN '0'||substring(${digits} from 4) ELSE ${digits} END)`;
  return `(CASE WHEN length(${normalized}) BETWEEN 8 AND 15 THEN ${normalized} ELSE NULL END)`;
}

function phoneHashSql(expression) {
  return `encode(sha256(convert_to(${normalizedPhoneSql(expression)},'UTF8')),'hex')`;
}

// These arguments are trusted SQL identifiers/placeholders from server code.
// Validate them anyway so no caller can accidentally pass a request fragment.
function phoneSelect(viewerSql = '$1', userAlias = 'u') {
  if (!/^\$[1-9][0-9]*$|^[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*$/i.test(viewerSql) ||
      !/^[a-z_][a-z0-9_]*$/i.test(userAlias)) throw new TypeError('Invalid phone projection SQL');
  const target = userAlias;
  const hash = phoneHashSql(`${target}.phone`);
  return `CASE WHEN ${target}.id=${viewerSql} OR (
    NOT EXISTS (SELECT 1 FROM blocked_users phone_block
      WHERE (phone_block.blocker_id=${viewerSql} AND phone_block.blocked_id=${target}.id)
         OR (phone_block.blocker_id=${target}.id AND phone_block.blocked_id=${viewerSql}))
    AND (EXISTS (SELECT 1 FROM user_contacts phone_contact
      WHERE phone_contact.owner_id=${viewerSql} AND phone_contact.contact_id=${target}.id
        AND phone_contact.known_phone_hash=${hash})
      OR (${target}.birth_date<=CURRENT_DATE-INTERVAL '18 years'
        AND EXISTS (SELECT 1 FROM users phone_viewer WHERE phone_viewer.id=${viewerSql}
          AND phone_viewer.birth_date<=CURRENT_DATE-INTERVAL '18 years')
        AND EXISTS (SELECT 1 FROM contact_phone_permissions phone_permission
          WHERE phone_permission.phone_owner_id=${target}.id AND phone_permission.viewer_id=${viewerSql}
            AND phone_permission.state='approved' AND phone_permission.phone_hash=${hash}))))
    THEN ${target}.phone ELSE NULL END AS phone`;
}

async function initializePhonePrivacy(pool) {
  await pool.query(`ALTER TABLE user_contacts ADD COLUMN IF NOT EXISTS contact_source TEXT NOT NULL DEFAULT 'unknown';
    ALTER TABLE user_contacts ADD COLUMN IF NOT EXISTS known_phone_hash TEXT;
    CREATE TABLE IF NOT EXISTS contact_phone_permissions (
      phone_owner_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      viewer_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      state TEXT NOT NULL CHECK (state IN ('pending','approved','declined','revoked')),
      phone_hash TEXT,
      requested_at TIMESTAMPTZ,
      updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      PRIMARY KEY (phone_owner_id,viewer_id),
      CHECK (phone_owner_id<>viewer_id)
    );
    CREATE INDEX IF NOT EXISTS contact_phone_permissions_viewer_idx
      ON contact_phone_permissions(viewer_id,phone_owner_id);`);
}

async function withTransaction(pool, action) {
  // A checked-out Client belongs to the caller's transaction. A Pool owns a
  // new transaction here, making multi-choice requests atomic for route callers.
  if (typeof pool.totalCount !== 'number' || typeof pool.connect !== 'function') return action(pool);
  const db = await pool.connect();
  try {
    await db.query('BEGIN');
    const result = await action(db);
    await db.query('COMMIT');
    return result;
  } catch (error) {
    await db.query('ROLLBACK').catch(() => {});
    throw error;
  } finally { db.release(); }
}

async function loadRows(pool, viewerId, ids) {
  const result = await pool.query(`SELECT u.id,u.phone,
      u.birth_date<=CURRENT_DATE-INTERVAL '18 years' AS target_adult,
      viewer.phone AS viewer_phone,
      viewer.birth_date<=CURRENT_DATE-INTERVAL '18 years' AS viewer_adult,
      c.contact_source,c.known_phone_hash,
      outgoing.state AS request_state,outgoing.phone_hash AS requested_phone_hash,
      incoming.state AS incoming_state,incoming.phone_hash AS shared_phone_hash,
      EXISTS (SELECT 1 FROM blocked_users b
        WHERE (b.blocker_id=$1 AND b.blocked_id=u.id)
           OR (b.blocker_id=u.id AND b.blocked_id=$1)) AS blocked
    FROM users u JOIN users viewer ON viewer.id=$1
    LEFT JOIN user_contacts c ON c.owner_id=$1 AND c.contact_id=u.id
    LEFT JOIN contact_phone_permissions outgoing
      ON outgoing.phone_owner_id=u.id AND outgoing.viewer_id=$1
    LEFT JOIN contact_phone_permissions incoming
      ON incoming.phone_owner_id=$1 AND incoming.viewer_id=u.id
    WHERE u.id=ANY($2::uuid[])`, [viewerId, ids]);
  return result.rows;
}

function sharingStatus(row, viewerId, suppliedPhones = new Set()) {
  const self = row.id.toLowerCase() === viewerId.toLowerCase();
  const normalized = normalizePhone(row.phone);
  const targetHash = phoneFingerprint(row.phone);
  const ownHash = phoneFingerprint(row.viewer_phone);
  const adults = row.target_adult === true && row.viewer_adult === true;
  const known = targetHash && (row.known_phone_hash === targetHash || suppliedPhones.has(normalized));
  const shared = adults && targetHash && row.request_state === 'approved' && row.requested_phone_hash === targetHash;
  const ownShared = adults && ownHash && row.incoming_state === 'approved' && row.shared_phone_hash === ownHash;
  const visibility = row.blocked && !self ? 'hidden' : !normalized ? 'unavailable'
    : self ? 'self' : known ? 'known' : shared ? 'shared' : 'hidden';
  // A grant never follows a user to a new number. A request/denial is also for
  // the phone version in effect when it was made, not a future replacement.
  const requestState = row.requested_phone_hash === targetHash ? row.request_state || 'none' : 'none';
  const incomingRequest = row.incoming_state === 'pending' && row.shared_phone_hash === ownHash;
  return {
    phone: ['self', 'known', 'shared'].includes(visibility) ? row.phone : null,
    phone_visibility: visibility,
    contact_source: SOURCES.has(row.contact_source) ? row.contact_source : 'unknown',
    request_state: row.blocked ? 'none' : requestState,
    incoming_request: !row.blocked && adults && Boolean(ownHash) && incomingRequest,
    share_my_phone: !row.blocked && Boolean(ownShared),
    my_phone_available: Boolean(ownHash),
    share_unavailable_reason: row.blocked ? 'blocked' : !adults ? 'age_restricted'
      : !ownHash ? 'missing_phone' : null,
    can_share_my_phone: !self && !row.blocked && adults && Boolean(ownHash),
    can_request_phone: !self && !row.blocked && adults && Boolean(targetHash) && !known && !shared,
  };
}

async function projectContactPhones(pool, viewerId, rows, { knownPhones = [] } = {}) {
  checkId(viewerId);
  if (!Array.isArray(rows) || !Array.isArray(knownPhones))
    fail(400, 'INVALID_PHONE_PROJECTION', 'רשימת אנשי הקשר אינה תקינה');
  if (!rows.length) return [];
  const ids = [...new Set(rows.map(row => { checkId(row.id); return row.id.toLowerCase(); }))];
  const supplied = new Set(knownPhones.map(normalizePhone).filter(Boolean));
  const loaded = new Map((await loadRows(pool, viewerId, ids)).map(row => [row.id.toLowerCase(), row]));
  return rows.map(row => {
    const target = loaded.get(row.id.toLowerCase());
    const status = target ? sharingStatus(target, viewerId, supplied) : {
      phone: null, phone_visibility: 'hidden', contact_source: 'unknown', request_state: 'none',
      incoming_request: false, share_my_phone: false, can_share_my_phone: false, can_request_phone: false,
      my_phone_available: false, share_unavailable_reason: null,
    };
    return { ...row, ...status };
  });
}

async function getPhoneSharingStatus(pool, viewerId, targetId) {
  checkId(viewerId);
  checkId(targetId);
  const row = (await loadRows(pool, viewerId, [targetId]))[0];
  if (!row) fail(404, 'USER_NOT_FOUND', 'המשתמש לא נמצא');
  return sharingStatus(row, viewerId);
}

async function rememberKnownContactPhones(pool, viewerId, phones, { source = 'phone_import' } = {}) {
  checkId(viewerId);
  if (!Array.isArray(phones) || !['phone_import', 'phone_manual'].includes(source))
    fail(400, 'INVALID_KNOWN_PHONES', 'רשימת המספרים המוכרים אינה תקינה');
  const normalized = [...new Set(phones.slice(0, 2000).map(normalizePhone).filter(Boolean))];
  if (!normalized.length) return 0;
  const hash = phoneHashSql('u.phone');
  // Discovery can provide fresh evidence for an already-saved app/legacy
  // contact. Only exact numbers supplied by this viewer count; an email match,
  // a source flag, and another person's contact row cannot upgrade access.
  const result = await pool.query(`UPDATE user_contacts c SET
      contact_source=$3,known_phone_hash=${hash}
    FROM users u WHERE c.owner_id=$1 AND c.contact_id=u.id
      AND ${normalizedPhoneSql('u.phone')}=ANY($2::text[])
      AND NOT (u.name='משתמש' AND u.gender IS NULL)
      AND (u.email_verified=TRUE OR u.phone_verified=TRUE)
      AND NOT EXISTS (SELECT 1 FROM blocked_users b
        WHERE (b.blocker_id=$1 AND b.blocked_id=u.id)
           OR (b.blocker_id=u.id AND b.blocked_id=$1))
      AND (c.known_phone_hash IS DISTINCT FROM ${hash} OR c.contact_source IS DISTINCT FROM $3)`,
  [viewerId, normalized, source]);
  return result.rowCount || 0;
}

async function lockPair(db, actorId, targetId, { allowBlocked = false } = {}) {
  const users = await db.query(`SELECT id,phone,
    birth_date<=CURRENT_DATE-INTERVAL '18 years' AS adult
    FROM users WHERE id=ANY($1::uuid[]) ORDER BY id FOR UPDATE`, [[actorId, targetId]]);
  if (users.rows.length !== 2) fail(404, 'USER_NOT_FOUND', 'המשתמש לא נמצא');
  const blocks = await db.query(`SELECT 1 FROM blocked_users
    WHERE (blocker_id=$1 AND blocked_id=$2) OR (blocker_id=$2 AND blocked_id=$1) LIMIT 1`, [actorId, targetId]);
  if (blocks.rows.length && !allowBlocked) fail(403, 'PHONE_SHARING_UNAVAILABLE', 'שיתוף מספר אינו זמין');
  return {
    actor: users.rows.find(row => row.id.toLowerCase() === actorId.toLowerCase()),
    target: users.rows.find(row => row.id.toLowerCase() === targetId.toLowerCase()),
  };
}

async function saveContactWithPhone(pool, viewerId, targetId, { source = 'in_app', knownPhone } = {}) {
  checkPair(viewerId, targetId);
  if (!SOURCES.has(source)) fail(400, 'INVALID_CONTACT_SOURCE', 'מקור איש הקשר אינו תקין');
  const supplied = knownPhone == null ? null : normalizePhone(knownPhone);
  if ((knownPhone != null && !supplied) || (['phone_import', 'phone_manual'].includes(source) && !supplied))
    fail(400, 'KNOWN_PHONE_REQUIRED', 'יש לספק את המספר המוכר לצורך התאמה');
  return withTransaction(pool, async db => {
    const { target } = await lockPair(db, viewerId, targetId);
    const eligible = await db.query(`SELECT 1 FROM users WHERE id=$1
      AND NOT (name='משתמש' AND gender IS NULL)
      AND (email_verified=TRUE OR phone_verified=TRUE)`, [targetId]);
    if (!eligible.rows.length) fail(404, 'USER_NOT_FOUND', 'המשתמש לא נמצא');
    if (supplied && supplied !== normalizePhone(target.phone))
      fail(400, 'PHONE_DOES_NOT_MATCH', 'המספר שסופק אינו מתאים לאיש הקשר');
    const hash = supplied ? phoneFingerprint(supplied) : null;
    const verifiedSource = hash ? (source === 'phone_import' ? 'phone_import' : 'phone_manual') : source;
    await db.query(`INSERT INTO user_contacts(owner_id,contact_id,contact_source,known_phone_hash)
      VALUES($1,$2,$3,$4) ON CONFLICT(owner_id,contact_id) DO UPDATE SET
        contact_source=CASE WHEN EXCLUDED.known_phone_hash IS NOT NULL OR user_contacts.contact_source='unknown'
          THEN EXCLUDED.contact_source ELSE user_contacts.contact_source END,
        known_phone_hash=COALESCE(EXCLUDED.known_phone_hash,user_contacts.known_phone_hash)`,
    [viewerId, targetId, verifiedSource, hash]);
    return getPhoneSharingStatus(db, viewerId, targetId);
  });
}

async function applyPhoneSharingChoices(pool, actorId, targetId, choices = {}) {
  checkPair(actorId, targetId);
  if (!choices || typeof choices !== 'object' || Array.isArray(choices))
    fail(400, 'INVALID_PHONE_CHOICES', 'בחירת שיתוף הטלפון אינה תקינה');
  for (const key of ['share_my_phone', 'request_phone']) {
    if (Object.hasOwn(choices, key) && typeof choices[key] !== 'boolean')
      fail(400, 'INVALID_PHONE_CHOICES', 'יש לבחור אם לשתף או לבקש מספר');
  }
  if (Object.hasOwn(choices, 'phone_response') && !['approve', 'decline'].includes(choices.phone_response))
    fail(400, 'INVALID_PHONE_RESPONSE', 'התשובה לבקשת המספר אינה תקינה');
  if ((choices.phone_response === 'approve' && choices.share_my_phone === false) ||
      (choices.phone_response === 'decline' && choices.share_my_phone === true))
    fail(400, 'CONFLICTING_PHONE_CHOICES', 'בחירות שיתוף הטלפון סותרות זו את זו');
  return withTransaction(pool, async db => {
    const wantsNewAccess = choices.share_my_phone === true || choices.request_phone === true || choices.phone_response === 'approve';
    const { actor, target } = await lockPair(db, actorId, targetId, { allowBlocked: !wantsNewAccess });
    const changes = { requested: false, shared: false, responded: false, revoked: false };
    if (wantsNewAccess && !(actor.adult === true && target.adult === true))
      fail(403, 'ADULTS_ONLY', 'בקשת מספר ושיתוף מספר חדש זמינים לבגירים בלבד');
    const ownHash = phoneFingerprint(actor.phone);
    const targetHash = phoneFingerprint(target.phone);
    if ((choices.share_my_phone === true || choices.phone_response === 'approve') && !ownHash)
      fail(400, 'PHONE_REQUIRED', 'יש להוסיף מספר טלפון בפרופיל לפני שיתוף');
    if (choices.request_phone === true && !targetHash)
      fail(400, 'CONTACT_PHONE_UNAVAILABLE', 'לא קיים מספר זמין לבקשה');
    const permissions = await db.query(`SELECT *,
      updated_at>now()-INTERVAL '${REQUEST_COOLDOWN_HOURS} hours' AS cooling_down
      FROM contact_phone_permissions WHERE
      (phone_owner_id=$1 AND viewer_id=$2) OR (phone_owner_id=$2 AND viewer_id=$1) FOR UPDATE`, [actorId, targetId]);
    const incoming = permissions.rows.find(row => row.phone_owner_id.toLowerCase() === actorId.toLowerCase());
    const outgoing = permissions.rows.find(row => row.phone_owner_id.toLowerCase() === targetId.toLowerCase());
    const incomingCurrent = incoming?.phone_hash === ownHash;
    if (choices.phone_response && (!incomingCurrent || !['pending', choices.phone_response === 'approve' ? 'approved' : 'declined'].includes(incoming?.state)))
      fail(409, 'PHONE_REQUEST_NOT_PENDING', 'בקשת המספר אינה ממתינה לתשובה');
    const statusBefore = await getPhoneSharingStatus(db, actorId, targetId);
    const shouldRequest = choices.request_phone === true && statusBefore.can_request_phone &&
      !(outgoing?.state === 'pending' && outgoing.phone_hash === targetHash);
    if (shouldRequest && ['declined', 'revoked'].includes(outgoing?.state) && outgoing.cooling_down)
      fail(429, 'PHONE_REQUEST_COOLDOWN', 'אפשר לשלוח בקשת מספר נוספת לאחר 24 שעות');
    if (choices.share_my_phone === true || choices.phone_response === 'approve') {
      if (!(incoming?.state === 'approved' && incomingCurrent)) {
        await db.query(`INSERT INTO contact_phone_permissions(phone_owner_id,viewer_id,state,phone_hash)
          VALUES($1,$2,'approved',$3) ON CONFLICT(phone_owner_id,viewer_id) DO UPDATE
          SET state='approved',phone_hash=EXCLUDED.phone_hash,updated_at=now()`, [actorId, targetId, ownHash]);
        changes.shared = true;
        changes.responded = incomingCurrent && incoming?.state === 'pending';
      }
    } else if (choices.phone_response === 'decline' && incoming?.state === 'pending') {
      await db.query(`UPDATE contact_phone_permissions SET state='declined',updated_at=now()
        WHERE phone_owner_id=$1 AND viewer_id=$2`, [actorId, targetId]);
      changes.responded = true;
    } else if (choices.share_my_phone === false && incoming?.state === 'approved') {
      await db.query(`UPDATE contact_phone_permissions SET state='revoked',updated_at=now()
        WHERE phone_owner_id=$1 AND viewer_id=$2`, [actorId, targetId]);
      changes.revoked = true;
    }
    if (shouldRequest) {
      await db.query(`INSERT INTO contact_phone_permissions(phone_owner_id,viewer_id,state,phone_hash,requested_at)
        VALUES($1,$2,'pending',$3,now()) ON CONFLICT(phone_owner_id,viewer_id) DO UPDATE
        SET state='pending',phone_hash=EXCLUDED.phone_hash,requested_at=now(),updated_at=now()`, [targetId, actorId, targetHash]);
      changes.requested = true;
    }
    return { ...await getPhoneSharingStatus(db, actorId, targetId), changes };
  });
}

module.exports = { initializePhonePrivacy, phoneSelect, projectContactPhones,
  saveContactWithPhone, getPhoneSharingStatus, applyPhoneSharingChoices,
  rememberKnownContactPhones, normalizePhone, phoneFingerprint, REQUEST_COOLDOWN_HOURS };
