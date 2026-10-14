'use strict';
const sharp = require('sharp');
const { randomUUID } = require('node:crypto');
const MAX_STICKER_EDGE = 160;
const MAX_STICKER_BYTES = 4 * 1024 * 1024;
function sharedStickerDetails(body, fileType) {
  if (body.sharedSticker !== 'true') return null;
  if (fileType !== 'image' || body.rightsConfirmed !== 'true' || body.groupId || body.toUserId)
    throw new Error('שמירת מדבקה דורשת תמונה או GIF ואישור שיתוף עם כל המשתמשים');
  const title = String(body.sharedStickerTitle || '').replace(/[\u0000-\u001f]/g, ' ').trim().slice(0, 80);
  if (!title) throw new Error('נדרש שם למדבקה');
  const tags = String(body.sharedStickerTags || '').split(',').map(tag => tag.trim().slice(0, 30)).filter(Boolean).slice(0, 10);
  return { title, tags };
}
async function resizeSharedSticker(buffer) {
  const metadata = await sharp(buffer).metadata();
  if (!['gif','png','jpeg','webp'].includes(metadata.format)) throw new Error('סוג תמונה לא נתמך למדבקה');
  const animated = (metadata.pages || 1) > 1;
  const gif = metadata.format === 'gif' || animated;
  const image = sharp(buffer, { animated: true }).rotate().resize({ width: MAX_STICKER_EDGE, height: MAX_STICKER_EDGE, fit: 'inside', withoutEnlargement: true });
  const bytes = await (gif ? image.gif({ loop: metadata.loop || 0, delay: metadata.delay }) : image.png()).toBuffer();
  if (bytes.length > MAX_STICKER_BYTES) throw new Error('המדבקה גדולה מדי; יש לבחור אנימציה קצרה יותר');
  return { bytes, mime: gif ? 'image/gif' : 'image/png', name: `betshuva-shared-sticker-${randomUUID()}.${gif ? 'gif' : 'png'}` };
}
async function appendSharedStickers(pool, catalog) {
  const found = await pool.query(`SELECT sg.id,sg.title,sf.public_url,sf.original_name,sf.mime_type
    FROM shared_gifs sg JOIN stored_files sf ON sf.id=sg.stored_file_id
    WHERE sg.is_sticker=TRUE AND sg.status='active' AND sf.moderation_status='approved'
      AND sf.content_purged_at IS NULL
      AND COALESCE(sf.moderation_details->>'pending','false')<>'true'
      AND COALESCE(sf.moderation_details->>'blocked','false')<>'true'
      AND COALESCE(sf.moderation_details->>'senderFilterRejected','false')<>'true'
    ORDER BY sg.created_at DESC LIMIT 300`);
  const items = found.rows.map(row => ({ id: `shared-sticker-${row.id}`, label: row.title,
    url: row.public_url, animated: row.mime_type === 'image/gif',
    sharedSticker: { id: row.id, title: row.title, preview_url: row.public_url, file_name: row.original_name } }));
  return { ...catalog, categories: catalog.categories.map(category => category.id === 'user-stickers'
    ? { ...category, items: [...items, ...category.items] } : category) };
}
module.exports = { sharedStickerDetails, resizeSharedSticker, appendSharedStickers, MAX_STICKER_EDGE };
