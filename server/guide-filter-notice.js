'use strict';

const { createHash } = require('node:crypto');
const { normalizeContentFilter } = require('./content-filter-policy');

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const FILE_TYPES = new Set(['image', 'video', 'audio', 'document']);
const CATEGORY_LABELS = {
  men: 'גברים', women: 'נשים', children: 'ילדים',
  nonHumanImages: 'נוף או חפצים',
};

function oneLine(value, maximum) {
  return String(value || '').replace(/[\u0000-\u001f\u007f\u202a-\u202e\u2066-\u2069]/g, ' ')
    .replace(/\s+/g, ' ').trim().slice(0, maximum).trim();
}

function shortFilterReason({ filter, fileType, classification, reason } = {}) {
  const labels = [];
  if (filter && typeof filter === 'object' && !Array.isArray(filter)) {
    const policy = normalizeContentFilter(filter);
    if (fileType === 'video' && !policy.video) labels.push('סרטונים חסומים');
    if (!policy.text) {
      if (fileType === 'audio') labels.push('הקלטות חסומות');
      if (fileType === 'document') labels.push('מסמכים חסומים');
      if (fileType === 'text' || fileType === 'sticker') labels.push('הודעות טקסט חסומות');
    }
    if (['image', 'gif', 'video', 'document'].includes(fileType)) {
      const detected = classification?.detectedCategories;
      const categories = Array.isArray(detected) && detected.length
        ? detected : classification?.category ? [classification.category] : [];
      const blocked = [...new Set(categories.map(category =>
        category === 'landscape' ? 'nonHumanImages' : category))]
        .filter(category => CATEGORY_LABELS[category] && !policy[category]);
      if (blocked.length) {
        labels.push(`תוכן הכולל ${blocked.map(category => CATEGORY_LABELS[category]).join(', ')} חסום`);
      } else if (categories.includes('people') &&
          !categories.some(category => ['men', 'women', 'children'].includes(category)) &&
          ['men', 'women', 'children'].some(category => !policy[category])) {
        labels.push('תמונות אנשים חסומות לפי הגדרות הסינון');
      } else if (classification?.uncertain === true &&
          Object.keys(CATEGORY_LABELS).some(category => !policy[category])) {
        labels.push('סיווג התמונה אינו ודאי ביחס להגדרות הסינון');
      }
    }
  }
  return oneLine(labels.join('; ') || reason || 'סוג התוכן חסום בהגדרות הסינון', 160);
}

function formatGroupFilterNotice(groupName, blockedNotices) {
  const group = oneLine(groupName, 100) || 'קבוצה';
  const lines = [...blockedNotices].sort((a, b) =>
    String(a.id).localeCompare(String(b.id))).map(blocked => {
    const name = oneLine(blocked.name, 100) || 'חבר בקבוצה';
    const reason = shortFilterReason({ filter: blocked.filter,
      fileType: blocked.fileType, classification: blocked.classification });
    return `• ${name} — ${reason}`;
  });
  return [`בקבוצה ״${group}״ נחסם ל:`, ...lines].join('\n');
}

function normalizeNoticeText(value) {
  // Keep the generated row boundaries. Names/reasons are sanitized separately,
  // and every recipient must survive even when the full report exceeds 600 chars.
  return String(value || '').split(/\r\n?|\n/)
    .map(line => oneLine(line, 300)).filter(Boolean).join('\n');
}

function formatLegacyGroupFilterNotice(text) {
  if (typeof text !== 'string' || /[\r\n]/.test(text)) return text;
  const match = /^בקבוצה ״([^״\r\n]+)״ — (נחסם ל.+)$/u.exec(text);
  if (!match) return text;
  const clauses = match[2].split(/; (?=נחסם ל)/u);
  // Old reports did not escape names. Keep each original clause intact rather
  // than guessing whether a comma in a name represented multiple recipients.
  if (clauses.some(clause => {
    const parts = clause.split(': ');
    return !clause.startsWith('נחסם ל') || parts.length !== 2 ||
      !parts[0].slice('נחסם ל'.length).trim() || !parts[1].trim();
  })) return text;
  return [`בקבוצה ״${match[1]}״ נחסם ל:`,
    ...clauses.map(clause => `• ${clause}`)].join('\n');
}

function projectGuideFilterNotice(row, viewerId, guideUserId) {
  const { _guide_filter_notice, ...safe } = row;
  if (_guide_filter_notice === true && safe.sender_id === guideUserId &&
      safe.recipient_id === viewerId && safe.type === 'text' && !safe.filter_hidden) {
    safe.body = formatLegacyGroupFilterNotice(safe.body);
  }
  return safe;
}

/**
 * The caller must first authorize approved, nonpurged, sender-readable media
 * against the sender's policy. This helper never grants access or rescans files.
 * Use the protected application pool: its normal INSERT placeholders encrypt
 * message bodies at rest. Dedupe metadata contains a hash, never plaintext body.
 */
async function notifyGuideFilterBlock({ pool, guideUserId, guideUserName = 'ישראל מדריך בתשובה',
  userId, targetType, targetId, targetName, fileUrl, fileName, fileType,
  classification, reason, noticeText, authorize, relay }) {
  const kind = targetType === 'user' ? 'chat' : targetType;
  const type = fileType === 'gif' ? 'image' : fileType;
  const name = oneLine(targetName, 100);
  if (!pool || typeof pool.connect !== 'function' || typeof relay !== 'function' ||
      (authorize !== undefined && typeof authorize !== 'function') ||
      ![guideUserId, userId, targetId].every(value => typeof value === 'string' && UUID.test(value)) ||
      guideUserId === userId || !['chat', 'group'].includes(kind) || !name ||
      !FILE_TYPES.has(type) || typeof fileUrl !== 'string' || fileUrl.length > 2048 ||
      !/^\/(?!\/)[^\s\\?#]+$/.test(fileUrl)) {
    throw new TypeError('Invalid sender-only guide filter notice');
  }
  let path;
  try { path = decodeURIComponent(fileUrl); } catch (_) {
    throw new TypeError('Invalid guide notice file URL');
  }
  if (/[\u0000-\u001f\u007f\\]/.test(path) || path.split('/').some(part => part === '.' || part === '..'))
    throw new TypeError('Invalid guide notice file URL');
  const briefReason = shortFilterReason({ reason });
  const text = normalizeNoticeText(noticeText) ||
    `נחסם ל${kind === 'group' ? 'קבוצה ' : ''}${name}: ${briefReason}`;
  const safeFileName = oneLine(fileName, 255) || 'קובץ';
  const key = createHash('sha256').update(JSON.stringify([
    userId.toLowerCase(), kind, targetId.toLowerCase(), fileUrl, text,
  ])).digest('hex');
  const client = await pool.connect();
  let file;
  let notice;
  let duplicate;
  try {
    await client.query('BEGIN');
    await client.query("SET LOCAL statement_timeout='10s'");
    await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))',
      [`guide-filter-notice:${key}`]);
    if (authorize && !await authorize(client)) {
      await client.query('ROLLBACK');
      return null;
    }
    const existing = await client.query(`SELECT n.id AS notice_id,f.id AS file_id
      FROM messages n JOIN messages f ON f.id=n.reply_to_id
      WHERE n.sender_id=$1 AND n.recipient_id=$2 AND n.group_id IS NULL
        AND f.sender_id=$1 AND f.recipient_id=$2 AND f.group_id IS NULL
        AND f.file_url=$3 AND n.type='text'
        AND n.delivery_summary->'guideFilterNotice'->>'key'=$4
        AND n.created_at>clock_timestamp()-interval '60 seconds'
        AND n.deleted_for_everyone=FALSE AND f.deleted_for_everyone=FALSE
      ORDER BY n.created_at DESC LIMIT 1`, [guideUserId, userId, fileUrl, key]);
    if (existing.rows.length) {
      duplicate = existing.rows[0];
    } else {
      const savedFile = await client.query(`INSERT INTO messages
        (sender_id,recipient_id,type,body,file_url,file_name,created_at)
        VALUES($1,$2,$3,NULL,$4,$5,clock_timestamp()) RETURNING id,created_at`,
      [guideUserId, userId, type, fileUrl, safeFileName]);
      file = savedFile.rows[0];
      const savedNotice = await client.query(`INSERT INTO messages
        (sender_id,recipient_id,type,body,reply_to_id,delivery_summary,created_at)
        VALUES($1,$2,'text',$3,$4,$5::jsonb,
          GREATEST(clock_timestamp(),
            (SELECT created_at+interval '1 millisecond' FROM messages WHERE id=$4)))
        RETURNING id,created_at`,
      [guideUserId, userId, text, file.id, JSON.stringify({ guideFilterNotice: { key } })]);
      notice = savedNotice.rows[0];
    }
    await client.query('COMMIT');
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    throw error;
  } finally {
    client.release();
  }
  if (duplicate) {
    return { duplicate: true, fileMessageId: duplicate.file_id, noticeMessageId: duplicate.notice_id };
  }
  const fromName = oneLine(guideUserName, 100) || 'ישראל מדריך בתשובה';
  await relay(userId, 'chat:message', {
    id: file.id, fromUserId: guideUserId, fromName, text: null,
    fileType: type, fileUrl, fileName: safeFileName,
    classification: classification || null, createdAt: file.created_at,
  });
  await relay(userId, 'chat:message', {
    id: notice.id, fromUserId: guideUserId, fromName, text,
    fileType: 'text', replyToId: file.id, replyBody: safeFileName,
    createdAt: notice.created_at,
  });
  return { duplicate: false, fileMessageId: file.id, noticeMessageId: notice.id };
}

module.exports = { notifyGuideFilterBlock, shortFilterReason, formatGroupFilterNotice,
  formatLegacyGroupFilterNotice, projectGuideFilterNotice };
