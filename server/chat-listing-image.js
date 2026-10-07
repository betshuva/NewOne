'use strict';

const fs = require('node:fs/promises');
const { constants } = require('node:fs');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { personalMessageVisible } = require('./conversation-history');
const { projectFilteredHistory, projectOwnScans } = require('./filter-media-history');
const { personalizeReceivedMessages, readSourceMedia } = require('./received-media');

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MAX_IMAGE_BYTES = 10 * 1024 * 1024;
const IMAGE_MIMES = new Map([
  ['image/jpeg', 'jpg'], ['image/png', 'png'], ['image/webp', 'webp'], ['image/gif', 'gif'],
]);

function imageError(status, code, message) {
  return Object.assign(new Error(message), { status, code });
}
function unavailable() {
  return imageError(404, 'CHAT_IMAGE_UNAVAILABLE', 'התמונה אינה זמינה או לא אושרה בסריקה');
}
function tooLarge() {
  return imageError(413, 'CHAT_IMAGE_TOO_LARGE', 'ניתן לצרף תמונה בגודל עד 10MB');
}
function filename(file) {
  // A filename is display metadata only; it never becomes a filesystem path.
  const name = path.basename(String(file.original_name || '').replaceAll('\\', '/'))
    .replace(/[\u0000-\u001f\u007f]/g, '').trim().slice(0, 240);
  const wellFormed = Buffer.from(name, 'utf8').toString('utf8');
  return wellFormed || `image.${IMAGE_MIMES.get(file.mime_type)}`;
}

async function accessibleImage(db, userId, messageId, projectHistory, personalizeMessages) {
  const messages = await db.query(`SELECT m.id,m.sender_id,m.recipient_id,m.group_id,
      m.type,m.file_url,m.file_name
    FROM messages m WHERE m.id=$2 AND m.type='image'
      AND ${personalMessageVisible('m', '$1')}`, [userId, messageId]);
  const message = messages.rows[0];
  if (!message) throw unavailable();
  const visible = await projectHistory(db, userId, [message], { groupId: message.group_id || null });
  if (visible.length !== 1 || visible[0].filter_hidden || !visible[0].file_url) throw unavailable();
  const personalized = await personalizeMessages(db, userId, visible);
  const selected = personalized[0];
  if (personalized.length !== 1 || selected.filter_hidden || !selected.file_url || selected.file_deleted)
    throw unavailable();
  const files = await db.query(`SELECT sf.* FROM stored_files sf
    WHERE sf.public_url=$2 AND sf.file_type='image' AND sf.moderation_status='approved'
      AND sf.content_purged_at IS NULL
      AND sf.moderation_details->>'blocked' IS DISTINCT FROM 'true'
      AND sf.moderation_details->>'pending' IS DISTINCT FROM 'true'
      AND sf.moderation_details->>'scanStopped' IS DISTINCT FROM 'true'
      AND NOT EXISTS(SELECT 1 FROM deleted_media_sources d WHERE d.public_url=sf.public_url)
      AND (sf.public_url=$3 OR (sf.user_id=$1 AND EXISTS(
        SELECT 1 FROM received_message_media received
        WHERE received.message_id=$4 AND received.user_id=$1
          AND received.status='ready' AND received.stored_file_id=sf.id)))`,
  [userId, selected.file_url, message.file_url, messageId]);
  return checkedSourceFile(files.rows[0]);
}

// Pending contact approval concerns delivery to the recipient, not the safety
// of the sender's own upload. Keep this separate namespace owner-only: it must
// never promote a request, search another message, or use a received copy.
async function accessibleRequestImage(db, userId, requestId, projectRequests) {
  const requests = await db.query(`SELECT mr.id,mr.sender_id,mr.recipient_id,
      mr.type,mr.file_url,mr.file_name
    FROM message_requests mr WHERE mr.id=$2 AND mr.sender_id=$1 AND mr.type='image'
      AND mr.status IN ('pending','rejected')
      AND NOT EXISTS(SELECT 1 FROM message_user_deletions d
        WHERE d.user_id=$1 AND d.message_id=mr.id)
      AND NOT EXISTS(SELECT 1 FROM conversation_user_state clear_state
        WHERE clear_state.user_id=$1 AND clear_state.kind='chat'
          AND clear_state.target_id=mr.recipient_id AND mr.created_at<=clear_state.cleared_at)`,
  [userId, requestId]);
  const request = requests.rows[0];
  if (!request || !request.file_url) throw unavailable();
  const projected = await projectRequests(db, userId,
    [{ ...request, id: `request_${request.id}` }],
    { contextType: 'chat', contextId: request.recipient_id });
  const selected = projected[0];
  if (projected.length !== 1 || selected.filter_hidden || selected.file_deleted ||
      !selected.file_url || selected.file_url !== request.file_url) throw unavailable();
  const files = await db.query(`SELECT sf.* FROM stored_files sf
    WHERE sf.user_id=$1 AND sf.public_url=$2 AND sf.file_type='image'
      AND sf.moderation_status='approved' AND sf.content_purged_at IS NULL
      AND sf.moderation_details->>'blocked' IS DISTINCT FROM 'true'
      AND sf.moderation_details->>'pending' IS DISTINCT FROM 'true'
      AND sf.moderation_details->>'scanStopped' IS DISTINCT FROM 'true'
      AND NOT EXISTS(SELECT 1 FROM deleted_media_sources d WHERE d.public_url=sf.public_url)`,
  [userId, request.file_url]);
  return checkedSourceFile(files.rows[0]);
}

function checkedSourceFile(file) {
  if (!file || !IMAGE_MIMES.has(file.mime_type)) throw unavailable();
  const size = Number(file.file_size);
  if (!Number.isSafeInteger(size) || size <= 0) throw unavailable();
  if (size > MAX_IMAGE_BYTES) throw tooLarge();
  return file;
}

// The ordinary reader restores authenticated Drive objects with checksum and
// download-size limits. Bound local reads too, including files changed on disk
// since their metadata was saved, without fetching any client-supplied URL.
async function readBoundedSourceMedia(db, uploadRoot, file, restore = readSourceMedia) {
  const size = Number(file.file_size);
  if (!Number.isSafeInteger(size) || size <= 0) throw unavailable();
  if (size > MAX_IMAGE_BYTES) throw tooLarge();
  const root = await fs.realpath(uploadRoot);
  const absolute = path.resolve(root, file.storage_path);
  if (!absolute.startsWith(root + path.sep)) throw unavailable();
  let handle;
  try {
    const real = await fs.realpath(absolute);
    if (!real.startsWith(root + path.sep)) throw unavailable();
    handle = await fs.open(real, constants.O_RDONLY | constants.O_NOFOLLOW);
    const stat = await handle.stat();
    if (!stat.isFile()) throw unavailable();
    if (stat.size > MAX_IMAGE_BYTES) throw tooLarge();
    if (stat.size !== Number(file.file_size)) throw imageError(503, 'CHAT_IMAGE_CHANGED', 'התמונה השתנתה ואינה זמינה כרגע');
    const bytes = Buffer.alloc(Number(file.file_size) + 1);
    let offset = 0;
    while (offset < bytes.length) {
      const result = await handle.read(bytes, offset, bytes.length - offset, offset);
      if (!result.bytesRead) break;
      offset += result.bytesRead;
    }
    return bytes.subarray(0, offset);
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  } finally { if (handle) await handle.close(); }
  return restore(db, uploadRoot, file, { skipLocal: true });
}

function checkedBytes(bytes, file) {
  if (!Buffer.isBuffer(bytes) || !bytes.length) throw unavailable();
  if (bytes.length > MAX_IMAGE_BYTES) throw tooLarge();
  if (bytes.length !== Number(file.file_size))
    throw imageError(503, 'CHAT_IMAGE_CHANGED', 'התמונה השתנתה ואינה זמינה כרגע');
  if (file.content_sha256 && (!/^[0-9a-f]{64}$/i.test(file.content_sha256) ||
      createHash('sha256').update(bytes).digest('hex') !== file.content_sha256.toLowerCase()))
    throw imageError(503, 'CHAT_IMAGE_CHANGED', 'התמונה השתנתה ואינה זמינה כרגע');
}

function registerChatListingImage(app, { auth, rateLimit, getPool, uploadRoot,
  projectHistory = projectFilteredHistory, personalizeMessages = personalizeReceivedMessages,
  projectRequests = projectOwnScans,
  readImage = readBoundedSourceMedia, logger = console }) {
  app.get('/api/messages/:id/listing-image-source', auth, rateLimit, async (req, res) => {
    res.set('Cache-Control', 'private, no-store, max-age=0');
    res.set('X-Content-Type-Options', 'nosniff');
    if (req.user.isTeen)
      return res.status(403).json({ error: 'לוח המודעות אינו זמין בחשבון נוער', code: 'TEEN_LISTINGS_DISABLED' });
    const reference = String(req.params.id || '');
    const isRequest = reference.startsWith('request_');
    const sourceId = isRequest ? reference.slice('request_'.length) : reference;
    if (!UUID.test(sourceId))
      return res.status(400).json({ error: 'מזהה ההודעה אינו תקין', code: 'INVALID_MESSAGE_ID' });
    try {
      const db = await getPool();
      const accessibleSource = () => isRequest
        ? accessibleRequestImage(db, req.user.id, sourceId, projectRequests)
        : accessibleImage(db, req.user.id, sourceId, projectHistory, personalizeMessages);
      const file = await accessibleSource();
      const bytes = await readImage(db, uploadRoot, file);
      checkedBytes(bytes, file);
      // Cloud restoration may be slow. Do not deliver if the image was hidden,
      // deleted, rejected or its conversation entitlement changed meanwhile.
      const current = await accessibleSource();
      if (current.id !== file.id || current.public_url !== file.public_url || current.mime_type !== file.mime_type ||
          Number(current.file_size) !== Number(file.file_size) || current.content_sha256 !== file.content_sha256)
        throw unavailable();
      res.set('Content-Type', current.mime_type);
      res.set('Content-Disposition', 'inline');
      res.set('X-Image-File-Name', encodeURIComponent(filename(current)));
      res.append('Access-Control-Expose-Headers', 'X-Image-File-Name');
      return res.send(bytes);
    } catch (error) {
      if (!error.status) logger.warn('Chat listing image unavailable:', error.code || error.name);
      return res.status(error.status || 503).json({
        error: error.status ? error.message : 'התמונה אינה זמינה כרגע; אפשר לנסות שוב בעוד רגע',
        code: error.code || 'CHAT_IMAGE_TEMPORARILY_UNAVAILABLE',
      });
    }
  });
}

module.exports = { MAX_IMAGE_BYTES, registerChatListingImage, readBoundedSourceMedia };
