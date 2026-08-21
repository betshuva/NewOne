require('dotenv').config();
require('dotenv').config({ path: require('path').join(__dirname, '..', '.env.turn') });
const express = require('express');
const { createServer } = require('http');
const { Server } = require('socket.io');
const cors = require('cors');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const nodemailer = require('nodemailer');
const crypto     = require('crypto');
const multer     = require('multer');
const path       = require('path');
const fs         = require('fs/promises');
const sharp      = require('sharp');
const { cert, getApps, initializeApp } = require('firebase-admin/app');
const { getMessaging } = require('firebase-admin/messaging');
const { getPool } = require('./db');
const {
  googleSafeSearchConfigured,
  normalizeBlockThreshold,
  scanGoogleSafeSearch,
} = require('./google-vision');

const UPLOAD_ROOT = path.join(__dirname, '..', 'uploads');
const UPLOAD_PUBLIC_BASE = '/betshuva-app/uploads';
const SCAN_BOT_ID = '00000000-0000-4000-8000-000000000001';
const SCAN_BOT_EMAIL = 'scan@betshuva.system';

// ── Firebase Cloud Messaging (HTTP v1 via Admin SDK) ──────────────
let firebaseMessaging = null;
function getFirebaseMessaging() {
  if (firebaseMessaging) return firebaseMessaging;
  const credentialsPath = path.join(__dirname, '..', 'firebase-service-account.json');
  const credentials = require(credentialsPath);
  const app = getApps()[0] || initializeApp({ credential: cert(credentials) });
  firebaseMessaging = getMessaging(app);
  return firebaseMessaging;
}

async function sendPush(userId, title, body, data = {}) {
  try {
    const pool   = await getPool();
    const result = await pool.query('SELECT token FROM fcm_tokens WHERE user_id = $1', [userId]);
    const tokens = result.rows.map(row => row.token).filter(Boolean);
    if (!tokens.length) return;
    const response = await getFirebaseMessaging().sendEachForMulticast({
      tokens,
      notification: { title: title || 'בתשובה', body: body || '' },
      data: Object.fromEntries(Object.entries(data).map(([key, value]) =>
        [key, String(value)])),
      android: {
        priority: 'high',
        notification: { sound: 'default', channelId: 'betshuva_messages' },
      },
      webpush: {
        notification: { icon: '/betshuva-app/icons/Icon-192.png' },
        fcmOptions: { link: '/betshuva-app/' },
      },
      apns: { payload: { aps: { badge: 1, sound: 'default' } } },
    });
    for (let index = 0; index < response.responses.length; index++) {
      const errorCode = response.responses[index].error?.code;
      if (errorCode === 'messaging/registration-token-not-registered' ||
          errorCode === 'messaging/invalid-registration-token') {
        pool.query('DELETE FROM fcm_tokens WHERE token=$1', [tokens[index]]).catch(() => {});
      }
    }
  } catch (e) { console.error('sendPush:', e.message); }
}

// ── File upload setup ─────────────────────────────────────────────
const ALLOWED_TYPES = {
  'image/jpeg':  { ext: 'jpg',  maxMB: 10, dbType: 'image' },
  'image/png':   { ext: 'png',  maxMB: 10, dbType: 'image' },
  'image/webp':  { ext: 'webp', maxMB: 10, dbType: 'image' },
  'image/gif':   { ext: 'gif',  maxMB: 10, dbType: 'image' },
  'application/pdf': { ext: 'pdf',  maxMB: 25, dbType: 'document' },
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document':
                 { ext: 'docx', maxMB: 25, dbType: 'document' },
  'audio/mpeg':  { ext: 'mp3',  maxMB: 25, dbType: 'audio' },
  'audio/aac':   { ext: 'aac',  maxMB: 25, dbType: 'audio' },
  'audio/mp4':   { ext: 'm4a',  maxMB: 25, dbType: 'audio' },
  'audio/webm':  { ext: 'webm', maxMB: 25, dbType: 'audio' },
  'audio/ogg':   { ext: 'ogg',  maxMB: 25, dbType: 'audio' },
  'audio/wav':   { ext: 'wav',  maxMB: 25, dbType: 'audio' },
};
const BLOCKED_TYPES = ['video/', 'application/x-mpegURL'];

const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 25 * 1024 * 1024 },
});

function normalizeUploadFileName(name) {
  if (!name || /[\u0590-\u05FF]/.test(name) || !/[\u00C0-\u00FF]/.test(name))
    return name;
  try {
    const decoded = Buffer.from(name, 'latin1').toString('utf8');
    return decoded.includes('\uFFFD') ? name : decoded;
  } catch (_) { return name; }
}

function isLoopbackAddress(address) {
  return address === '127.0.0.1' || address === '::1' || address === '::ffff:127.0.0.1';
}

function clientIp(req) {
  const remoteAddress = req.socket?.remoteAddress || '';
  const realIp = req.get?.('x-real-ip');
  // X-Real-IP is authoritative only when it was supplied by our local Nginx.
  if (isLoopbackAddress(remoteAddress) && realIp) return realIp.trim();
  return req.ip || remoteAddress || 'unknown';
}

function createRateLimiter({ windowMs, max, message, keyGenerator, maxBuckets = 50000 }) {
  const buckets = new Map();
  const cleanup = setInterval(() => {
    const now = Date.now();
    for (const [key, value] of buckets) {
      if (value.resetAt <= now) buckets.delete(key);
    }
  }, windowMs);
  cleanup.unref();
  return (req, res, next) => {
    const key = String(keyGenerator?.(req) || req.user?.id || clientIp(req));
    const now = Date.now();
    let bucket = buckets.get(key);
    if (!bucket || bucket.resetAt <= now) {
      // Bound memory use even when an attacker rotates source addresses/identifiers.
      if (!buckets.has(key) && buckets.size >= maxBuckets) {
        const oldestKey = buckets.keys().next().value;
        if (oldestKey !== undefined) buckets.delete(oldestKey);
      }
      bucket = { count: 0, resetAt: now + windowMs };
      buckets.set(key, bucket);
    }
    bucket.count++;
    res.set({
      'RateLimit-Limit': String(max),
      'RateLimit-Remaining': String(Math.max(0, max - bucket.count)),
      'RateLimit-Reset': String(Math.ceil(bucket.resetAt / 1000)),
    });
    if (bucket.count > max) {
      res.set('Retry-After', String(Math.max(1, Math.ceil((bucket.resetAt - now) / 1000))));
      return res.status(429).json({ error: message });
    }
    next();
  };
}

const normalizedCredential = req => {
  const value = req.body?.email || req.body?.phone || req.body?.identifier || '';
  return `${clientIp(req)}:${String(value).trim().toLowerCase().slice(0, 200)}`;
};

const apiRateLimit = createRateLimiter({
  windowMs: 5 * 60 * 1000,
  max: 600,
  keyGenerator: clientIp,
  message: 'בוצעו יותר מדי בקשות. נסה שוב בעוד מספר דקות',
});
const authRateLimit = createRateLimiter({
  windowMs: 15 * 60 * 1000,
  max: 30,
  keyGenerator: clientIp,
  message: 'בוצעו יותר מדי ניסיונות אימות מכתובת זו. נסה שוב מאוחר יותר',
});
const credentialRateLimit = createRateLimiter({
  windowMs: 15 * 60 * 1000,
  max: 10,
  keyGenerator: normalizedCredential,
  message: 'בוצעו יותר מדי ניסיונות עבור חשבון זה. נסה שוב מאוחר יותר',
});
const otpRateLimit = createRateLimiter({
  windowMs: 15 * 60 * 1000,
  max: 5,
  keyGenerator: normalizedCredential,
  message: 'נשלחו יותר מדי בקשות לקוד אימות. נסה שוב מאוחר יותר',
});
const messageRateLimit = createRateLimiter({
  windowMs: 60 * 1000,
  max: 120,
  message: 'נשלחו יותר מדי הודעות. נסה שוב בעוד דקה',
});
const searchRateLimit = createRateLimiter({
  windowMs: 60 * 1000,
  max: 60,
  message: 'בוצעו יותר מדי חיפושים. נסה שוב בעוד דקה',
});
const inviteRateLimit = createRateLimiter({
  windowMs: 60 * 60 * 1000,
  max: 10,
  message: 'נשלחו יותר מדי הזמנות. נסה שוב מאוחר יותר',
});
const reportRateLimit = createRateLimiter({
  windowMs: 60 * 60 * 1000,
  max: 20,
  message: 'נשלחו יותר מדי דיווחים. נסה שוב מאוחר יותר',
});

const uploadRateLimit = createRateLimiter({
  windowMs: 10 * 60 * 1000,
  max: 100,
  message: 'בוצעו יותר מדי העלאות. נסה שוב בעוד מספר דקות',
});
const visionTestRateLimit = createRateLimiter({
  windowMs: 10 * 60 * 1000,
  max: 30,
  message: 'בוצעו יותר מדי בדיקות תמונה. נסה שוב בעוד מספר דקות',
});
const visionRescanRateLimit = createRateLimiter({
  windowMs: 60 * 60 * 1000,
  max: 2,
  message: 'ניתן להפעיל בדיקת היסטוריה פעמיים בשעה בלבד',
});

// ── Backblaze B2 Native API ───────────────────────────────────────
// Env vars: B2_KEY_ID, B2_APP_KEY, B2_BUCKET, CDN_BASE_URL

let _b2Cache = null;

async function b2Auth() {
  if (_b2Cache && Date.now() < _b2Cache.exp) return _b2Cache;
  const keyId  = (process.env.B2_KEY_ID  || '').trim();
  const appKey = (process.env.B2_APP_KEY || '').trim().replace(/ /g, '+');
  if (!keyId || !appKey) throw new Error('B2_KEY_ID / B2_APP_KEY לא מוגדרים');
  const creds = Buffer.from(`${keyId}:${appKey}`).toString('base64');
  const res   = await fetch('https://api.backblazeb2.com/b2api/v2/b2_authorize_account', {
    headers: { Authorization: `Basic ${creds}` },
  });
  const data = await res.json();
  if (!res.ok) throw new Error(`B2 auth: ${data.message || res.status}`);
  _b2Cache = {
    token:   data.authorizationToken,
    apiUrl:  data.apiUrl,
    exp:     Date.now() + 22 * 3600 * 1000,
    bucketId: data.allowed?.bucketId || null,
    accountId: data.accountId,
  };
  return _b2Cache;
}

async function b2BucketId(auth) {
  if (auth.bucketId) return auth.bucketId;
  const bucket = process.env.B2_BUCKET;
  const res  = await fetch(
    `${auth.apiUrl}/b2api/v2/b2_list_buckets?accountId=${auth.accountId}&bucketName=${encodeURIComponent(bucket)}`,
    { headers: { Authorization: auth.token } });
  const data = await res.json();
  if (!data.buckets?.length) throw new Error(`Bucket "${bucket}" לא נמצא`);
  return data.buckets[0].bucketId;
}

async function uploadToBlob(buffer, key, contentType) {
  const safeParts = key.split('/').filter(Boolean).map(part =>
    part.replace(/[^\w.\-]/g, '_'));
  if (!safeParts.length) throw new Error('Invalid upload path');
  const relativePath = path.join(...safeParts);
  const absolutePath = path.resolve(UPLOAD_ROOT, relativePath);
  if (!absolutePath.startsWith(path.resolve(UPLOAD_ROOT) + path.sep))
    throw new Error('Invalid upload path');
  await fs.mkdir(path.dirname(absolutePath), { recursive: true });
  await fs.writeFile(absolutePath, buffer, { flag: 'wx' });
  return `${UPLOAD_PUBLIC_BASE}/${safeParts.map(encodeURIComponent).join('/')}`;
}

// ── Content Moderation ────────────────────────────────────────────

const DEFAULT_FEMALE_LABELS = [
  'woman','women','girl','female','lady','ladies','bride','actress',
  'child model','child modeling','child actor','child actress',
  'dress','skirt','gown','miniskirt','one-piece garment',
  'blouse','bridal clothing','wedding dress','ball gown',
];
const DEFAULT_BLOCKED_WORDS = [
  'עירום','פורנו','סקס','ניאוף','תועבה','זנות','חשפנות',
  'porn','nude','naked','xxx','sex','erotic','adult content',
];
const CHAT_HARMFUL_TERMS = [
  // Threats, harassment and common abusive language. Sexual terms are loaded
  // from BLOCKED_WORDS below so administrators can extend them at runtime.
  'אני אהרוג אותך','אני אפגע בך','מוות לך','תתאבד','תמות','מטומטם',
  'מפגר','שרמוטה','זונה','בן זונה','כלבה','מניאק',
  'kill yourself','i will kill you','death threat','idiot','moron','bitch',
  'whore','slut','fuck you','stupid','retard',
];

let FEMALE_LABELS = [...DEFAULT_FEMALE_LABELS];
let BLOCKED_WORDS = [...DEFAULT_BLOCKED_WORDS];

function normalizeModerationText(value) {
  return String(value || '')
    .normalize('NFKC')
    .toLowerCase()
    .replace(/[\u0591-\u05C7]/g, '')
    .replace(/[^\p{L}\p{N}]+/gu, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function moderateChatText(value) {
  const normalized = normalizeModerationText(value);
  if (!normalized) return { blocked: false };
  const terms = [...BLOCKED_WORDS, ...CHAT_HARMFUL_TERMS];
  for (const rawTerm of terms) {
    const term = normalizeModerationText(rawTerm);
    if (!term) continue;
    const escaped = term.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    if (new RegExp(`(^|\\s)${escaped}(?=\\s|$)`, 'u').test(normalized)) {
      return { blocked: true, category: 'harmful_language' };
    }
  }
  return { blocked: false };
}

function recordBlockedChat(userId, context, text, targetId, ip = null) {
  const digest = crypto.createHash('sha256').update(String(text || '')).digest('hex');
  logActivity(userId, 'blocked_chat_text', {
    context, targetId, category: 'harmful_language',
    textLength: String(text || '').length, textHash: digest,
  }, ip);
}

const DEFAULT_CONTENT_FILTER = Object.freeze({
  text: true,
  nonHumanImages: true,
  men: true,
  women: true,
  children: true,
});

function normalizeContentFilter(value, fallback = DEFAULT_CONTENT_FILTER) {
  const input = value && typeof value === 'object' && !Array.isArray(value) ? value : {};
  return Object.fromEntries(Object.keys(DEFAULT_CONTENT_FILTER).map(key => [
    key, typeof input[key] === 'boolean' ? input[key] : fallback[key],
  ]));
}

async function getEffectiveRecipientFilter(pool, recipientId, senderId) {
  const result = await pool.query(
    `SELECT u.content_filter, c.filter_override
     FROM users u
     LEFT JOIN user_contacts c ON c.owner_id=u.id AND c.contact_id=$2
     WHERE u.id=$1`, [recipientId, senderId]);
  if (!result.rows.length) return null;
  const general = normalizeContentFilter(result.rows[0].content_filter);
  return {
    isContact: !!result.rows[0].filter_override || (await pool.query(
      'SELECT 1 FROM user_contacts WHERE owner_id=$1 AND contact_id=$2',
      [recipientId, senderId])).rows.length > 0,
    filter: normalizeContentFilter(result.rows[0].filter_override, general),
  };
}

function imageAllowedByFilter(filter, classification) {
  const detected = classification?.detectedCategories;
  if (Array.isArray(detected) && detected.length)
    return detected.every(category => filter[category] === true);
  const category = classification?.category || 'people';
  if (category === 'people')
    return filter.men && filter.women && filter.children;
  return filter[category] === true;
}

async function validateApprovedFile(pool, userId, fileUrl, contextType, contextId) {
  if (!fileUrl) return true;
  const result = await pool.query(
    `SELECT 1 FROM stored_files
     WHERE user_id=$1 AND public_url=$2 AND moderation_status='approved'
       AND context_type=$3 AND context_id=$4`,
    [userId, fileUrl, contextType, contextId]);
  return result.rows.length > 0;
}

const scanLabelNames = {
  'person or people are visible': 'אדם',
  'animal or plant is visible': 'בעל חיים או צמח',
  'inanimate object landscape document or screenshot': 'דומם',
  'not a person': 'ללא אדם',
  'person or people': 'אדם או אנשים', animal: 'בעל חיים', plant: 'צמח',
  'inanimate object or landscape': 'חפץ, נוף או מסמך',
  men: 'גבר', women: 'אישה', children: 'ילד/ה',
};

function formatScanBotReport(fileName, scanResult, status) {
  const classification = scanResult?.classification || {};
  const statusText = status === 'rejected' ? '⛔ נחסמה'
    : status === 'pending' ? '⏳ לא ודאית — לא נשלחה' : '✅ אושרה';
  const lines = [`דוח סריקה: ${fileName}`, `תוצאה: ${statusText}`];
  if (scanResult?.reason) lines.push(`סיבה: ${scanResult.reason}`);
  const stageTitles = {
    life: 'שלב 1 — חי, דומם או אדם',
    subjects: 'שלב 2 — סוג התוכן',
    people: 'שלב 3 — סוגי האנשים',
  };
  for (const stage of classification.stages || []) {
    const decision = Array.isArray(stage.decision)
      ? stage.decision.map(value => scanLabelNames[value] || value).join(', ')
      : scanLabelNames[stage.decision] || stage.decision || 'לא ודאי';
    lines.push(`${stageTitles[stage.name] || stage.name}: ${decision} ` +
      `(${Math.round(Number(stage.confidence || 0) * 100)}%, ${stage.durationMs || 0}ms)`);
    if (stage.scores) {
      const scores = Object.entries(stage.scores).map(([label, score]) =>
        `${scanLabelNames[label] || label} ${Math.round(Number(score) * 100)}%`);
      lines.push(`ציונים: ${scores.join(' · ')}`);
    }
  }
  const detected = classification.detectedCategories || [];
  if (detected.length)
    lines.push(`זוהו: ${detected.map(value => scanLabelNames[value] || value).join(', ')}`);
  if (classification.totalDurationMs != null)
    lines.push(`זמן סיווג: ${classification.totalDurationMs}ms`);
  const strictModesty = scanResult?.strictModesty;
  if (strictModesty?.checked) {
    lines.push(`שלב 4 — לבוש מחמיר: ${strictModesty.blocked ? '⛔ לא עבר' : '✅ עבר'} ` +
      `(${strictModesty.totalDurationMs || 0}ms)`);
    for (const check of strictModesty.checks || []) {
      const category = scanLabelNames[check.category] || check.category;
      lines.push(`${category}${check.fallback ? ' (בדיקת גיבוי)' : ''}: ציון חריגה ${Math.round(Number(check.riskScore || 0) * 100)}% ` +
        `· סף ${Math.round(Number(check.threshold || 0) * 100)}%`);
    }
  } else if (strictModesty && !strictModesty.available) {
    lines.push('שלב 4 — לבוש מחמיר: לא זמין');
  }
  const modesty = (scanResult?.labels || [])
    .filter(label => ['nudity', 'adult sexual content', 'lingerie or revealing clothing']
      .includes(label.name))
    .map(label => `${label.name} ${label.score}%`);
  if (modesty.length) lines.push(`בדיקת צניעות: ${modesty.join(' · ')}`);
  const localSafety = scanResult?.localSafety;
  if (localSafety?.available) {
    const normal = Math.round(Number(localSafety.scores?.normal || 0) * 1000) / 10;
    const nsfw = Math.round(Number(localSafety.scores?.nsfw || 0) * 1000) / 10;
    const localDecision = localSafety.decision === 'nsfw' ? 'זוהה NSFW'
      : localSafety.decision === 'review' ? 'חשד ל־NSFW' : 'לא זוהה NSFW';
    lines.push(`בדיקת תוכן מיני מפורש FalconsAI: ${localDecision} · ללא NSFW ${normal}% · NSFW ${nsfw}% ` +
      `(${localSafety.durationMs || 0}ms)`);
    lines.push('מידע נוסף בלבד: המודל אינו קובע צניעות לבוש ואינו משפיע על ההחלטה');
  } else if (localSafety) {
    lines.push('בדיקת תוכן מיני מפורש FalconsAI: לא זמינה — לא השפיעה על ההחלטה');
  }
  const googleSafeSearch = scanResult?.googleSafeSearch;
  const likelihoodHe = {
    UNKNOWN: 'לא ידוע', VERY_UNLIKELY: 'לא סביר מאוד', UNLIKELY: 'לא סביר',
    POSSIBLE: 'אפשרי', LIKELY: 'סביר', VERY_LIKELY: 'סביר מאוד',
  };
  const categoryHe = { adult: 'תוכן למבוגרים', racy: 'תוכן מגרה', violence: 'אלימות',
    medical: 'רפואי', spoof: 'שינוי/זיוף' };
  if (googleSafeSearch?.configured && googleSafeSearch.available) {
    const scores = Object.entries(googleSafeSearch.categories || {}).map(([category, value]) =>
      `${categoryHe[category] || category}: ${likelihoodHe[value] || value}`);
    const decision = googleSafeSearch.blocked ? '⛔ לא עבר'
      : googleSafeSearch.uncertain ? '⏳ לא ודאי' : '✅ עבר';
    lines.push(`Google Vision SafeSearch: ${decision} · ${scores.join(' · ')} ` +
      `(${googleSafeSearch.durationMs || 0}ms)`);
  } else if (googleSafeSearch?.status === 'skipped_local_block') {
    lines.push('Google Vision SafeSearch: לא נשלחה בקשה — התמונה כבר נחסמה בבדיקה המקומית');
  } else if (String(googleSafeSearch?.status || '').startsWith('deferred_local_')) {
    lines.push('Google Vision SafeSearch: טרם נבדקה — ממתינה להשלמת הבדיקה המקומית');
  } else if (googleSafeSearch?.configured) {
    lines.push(`Google Vision SafeSearch: לא זמין — התמונה לא אושרה אוטומטית` +
      `${googleSafeSearch.errorCode ? ` (${googleSafeSearch.errorCode})` : ''}`);
  } else if (googleSafeSearch) {
    lines.push('Google Vision SafeSearch: טרם הוגדר בשרת');
  }
  return lines.join('\n');
}

async function saveScanBotReport(pool, userId, file, fileUrl, scanResult, status) {
  const body = formatScanBotReport(file.name, scanResult, status);
  const saved = await pool.query(
    `INSERT INTO messages(sender_id,recipient_id,type,body,file_url,file_name,file_size)
     VALUES($1,$2,$3,$4,$5,$6,$7) RETURNING id,created_at`,
    [SCAN_BOT_ID, userId, file.dbType, body, fileUrl, file.name, file.size]);
  const sid = onlineUsers.get(userId);
  if (sid) io.to(sid).emit('chat:message', {
    id: saved.rows[0].id, fromUserId: SCAN_BOT_ID, fromName: 'סריקה',
    text: body, createdAt: saved.rows[0].created_at, fileType: file.dbType,
    fileUrl, fileName: file.name, fileSize: file.size,
  });
  return body;
}

async function classifyClip(buffer, labels) {
  const form = new FormData();
  form.append('image', new Blob([buffer]), 'upload.jpg');
  form.append('labels', labels.join(','));
  const response = await fetch(
    process.env.CLIP_URL || 'http://127.0.0.1:5000/classify',
    { method: 'POST', body: form, signal: AbortSignal.timeout(30000) },
  );
  if (!response.ok) throw new Error(`CLIP ${response.status}`);
  return response.json();
}

async function classifyLocalSafety(buffer) {
  const startedAt = performance.now();
  try {
    const form = new FormData();
    form.append('image', new Blob([buffer]), 'upload.jpg');
    const response = await fetch(
      process.env.LOCAL_MODERATION_URL || 'http://127.0.0.1:5004/moderate',
      { method: 'POST', body: form, signal: AbortSignal.timeout(45000) },
    );
    if (!response.ok) throw new Error(`Local moderation ${response.status}`);
    const result = await response.json();
    return {
      ...result,
      available: true,
      mode: 'comparison',
      durationMs: Number(result.durationMs) || Math.round(performance.now() - startedAt),
    };
  } catch (error) {
    console.warn('Local moderation comparison:', error.message);
    return {
      available: false,
      mode: 'comparison',
      durationMs: Math.round(performance.now() - startedAt),
      error: error.message,
    };
  }
}

async function classifyImageContent(buffer) {
  const startedAt = performance.now();
  const timed = async (name, labels) => {
    const stageStartedAt = performance.now();
    const scores = await classifyClip(buffer, labels);
    return {
      name,
      scores,
      durationMs: Math.round(performance.now() - stageStartedAt),
    };
  };
  const topResult = scores => Object.entries(scores)
    .map(([label, score]) => ({ label, score: Number(score) || 0 }))
    .sort((a, b) => b.score - a.score)[0] || { label: '', score: 0 };

  const lifeStage = await timed('life', [
    'person or people are visible',
    'animal or plant is visible',
    'inanimate object landscape document or screenshot',
  ]);
  const life = lifeStage.scores;
  const lifeTop = topResult(life);
  const personScore = Number(life['person or people are visible'] || 0);
  const nonPersonScore = Number(life['animal or plant is visible'] || 0) +
    Number(life['inanimate object landscape document or screenshot'] || 0);
  lifeStage.decision = nonPersonScore >= 0.70 && nonPersonScore > personScore
    ? 'not a person' : lifeTop.label;
  lifeStage.confidence = nonPersonScore >= 0.70 && nonPersonScore > personScore
    ? nonPersonScore : lifeTop.score;
  lifeStage.personScore = personScore;
  lifeStage.nonPersonScore = nonPersonScore;

  if (nonPersonScore >= 0.70 && nonPersonScore > personScore) {
    return {
      category: 'nonHumanImages', detectedCategories: ['nonHumanImages'],
      uncertain: false, life, subjects: null, people: null,
      stages: [lifeStage], totalDurationMs: Math.round(performance.now() - startedAt),
    };
  }

  const subjectsStage = await timed('subjects', [
    'person or people', 'animal', 'plant', 'inanimate object or landscape',
  ]);
  const subjects = subjectsStage.scores;
  const subjectTop = topResult(subjects);
  subjectsStage.decision = subjectTop.label;
  subjectsStage.confidence = subjectTop.score;
  const personConfirmed = subjectTop.label === 'person or people' &&
    (subjectTop.score >= 0.70 || (personScore >= 0.70 && subjectTop.score >= 0.60));
  if (subjectTop.label !== 'person or people' && subjectTop.score >= 0.70) {
    return {
      category: 'nonHumanImages', detectedCategories: ['nonHumanImages'],
      uncertain: false, life, subjects, people: null,
      stages: [lifeStage, subjectsStage],
      totalDurationMs: Math.round(performance.now() - startedAt),
    };
  }

  if (!personConfirmed) {
    subjectsStage.uncertain = true;
    return {
      category: null, detectedCategories: [], uncertain: true,
      uncertainStage: 'subjects', life, subjects, people: null,
      stages: [lifeStage, subjectsStage],
      totalDurationMs: Math.round(performance.now() - startedAt),
    };
  }
  subjectsStage.confirmedByLifeStage = subjectTop.score < 0.70;

  const peopleStartedAt = performance.now();
  const checks = [
    ['men', 'a photo containing an adult man',
      'a photo containing only women children objects or scenery'],
    ['women', 'a photo containing an adult woman',
      'a photo containing only men children objects or scenery'],
    ['children', 'a photo containing a child or teenager',
      'a photo containing only adults objects or scenery'],
  ];
  const results = await Promise.all(checks.map(async ([category, present, absent]) => {
    const scores = await classifyClip(buffer, [present, absent]);
    return { category, present, absent, scores,
      confidence: Number(scores[present] || 0),
      detected: Number(scores[present] || 0) >= 0.70 &&
        Number(scores[present] || 0) > Number(scores[absent] || 0) };
  }));
  const detectedCategories = results.filter(result => result.detected)
    .map(result => result.category);
  const people = Object.fromEntries(results.map(result => [result.category, {
    detected: result.detected, confidence: result.confidence, scores: result.scores,
  }]));
  const peopleStage = {
    name: 'people', decision: detectedCategories,
    confidence: detectedCategories.length
      ? Math.min(...results.filter(result => result.detected).map(result => result.confidence))
      : Math.max(...results.map(result => result.confidence)),
    durationMs: Math.round(performance.now() - peopleStartedAt),
    uncertain: detectedCategories.length === 0,
  };
  return {
    category: detectedCategories.length === 1 ? detectedCategories[0]
      : detectedCategories.length > 1 ? 'people' : null,
    detectedCategories,
    uncertain: detectedCategories.length === 0,
    uncertainStage: detectedCategories.length === 0 ? 'people' : null,
    life, subjects, people,
    stages: [lifeStage, subjectsStage, peopleStage],
    totalDurationMs: Math.round(performance.now() - startedAt),
  };
}

const STRICT_MODESTY_CHECKS = {
  men: {
    safe: 'all men and boys are wearing modest long sleeved shirts and long pants',
    risk: 'a man or boy is shirtless or wearing shorts or short sleeves with exposed arms or legs',
    threshold: 0.90,
  },
  women: {
    safe: 'all women and girls are wearing modest long sleeves a high neckline and a long skirt',
    risk: 'a woman or girl is wearing short sleeves pants a short skirt a low neckline or revealing clothing',
    threshold: 0.90,
  },
  children: {
    safe: 'all children are wearing modest long sleeved clothing that covers their arms and legs',
    risk: 'a child is wearing shorts or short sleeves or has exposed arms legs or chest',
    threshold: 0.90,
  },
};

async function scanStrictModesty(buffer, classification) {
  const detectedCategories = (classification?.detectedCategories || [])
    .filter(category => STRICT_MODESTY_CHECKS[category]);
  const isConfidentNonHuman = classification?.category === 'nonHumanImages' &&
    classification?.uncertain !== true;
  if (!detectedCategories.length && !isConfidentNonHuman) return {
    available: true, checked: false, blocked: false, checks: [], totalDurationMs: 0,
  };
  // A category classifier can miss a small or secondary person. Once any
  // person is detected, screen all person types; for a confident non-human
  // result, use a high-threshold fallback to catch obvious classification
  // mistakes such as a small shirtless person in a landscape.
  const categories = Object.keys(STRICT_MODESTY_CHECKS);
  const startedAt = performance.now();
  try {
    const checks = await Promise.all(categories.map(async category => {
      const config = STRICT_MODESTY_CHECKS[category];
      const fallback = !detectedCategories.includes(category);
      const threshold = fallback
        ? (isConfidentNonHuman ? 0.95 : 0.90)
        : config.threshold;
      const checkStartedAt = performance.now();
      const scores = await classifyClip(buffer, [config.safe, config.risk]);
      const riskScore = Number(scores[config.risk] || 0);
      return {
        category,
        scores,
        riskScore,
        safeScore: Number(scores[config.safe] || 0),
        threshold,
        fallback,
        blocked: riskScore >= threshold,
        durationMs: Math.round(performance.now() - checkStartedAt),
      };
    }));
    return {
      available: true,
      checked: true,
      blocked: checks.some(check => check.blocked),
      blockedCategories: checks.filter(check => check.blocked).map(check => check.category),
      checks,
      totalDurationMs: Math.round(performance.now() - startedAt),
    };
  } catch (error) {
    console.warn('Strict modesty scan:', error.message);
    return {
      available: false,
      checked: false,
      blocked: false,
      checks: [],
      error: error.message,
      totalDurationMs: Math.round(performance.now() - startedAt),
    };
  }
}

function isPotentiallyAnimatedImage(buffer) {
  if (!Buffer.isBuffer(buffer) || buffer.length < 12) return false;
  const magic = buffer.subarray(0, 12).toString('ascii');
  // GIF scanning in the current model stack only evaluates the first frame,
  // so reject GIF files rather than allow later frames to bypass moderation.
  if (magic.startsWith('GIF87a') || magic.startsWith('GIF89a')) return true;
  if (magic.startsWith('RIFF') && magic.slice(8, 12) === 'WEBP')
    return buffer.indexOf(Buffer.from('ANIM')) >= 0 || buffer.indexOf(Buffer.from('ANMF')) >= 0;
  if (buffer.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])))
    return buffer.indexOf(Buffer.from('acTL')) >= 0;
  return false;
}


async function scanStaticImage(buffer, options = {}) {
  const localSafetyPromise = classifyLocalSafety(buffer);
  const capture = promise => promise.then(
    value => ({ ok: true, value }),
    error => ({ ok: false, error }),
  );
  const labels = [
    'safe everyday photo',
    'computer screen',
    'document or screenshot',
    'landscape or object',
    'man or boy',
    'woman or girl',
    'nudity',
    'adult sexual content',
    'lingerie or revealing clothing',
  ];
  const [scoresResult, classificationResult, localSafety] =
    await Promise.all([
      capture(classifyClip(buffer, labels)),
      capture(classifyImageContent(buffer)),
      localSafetyPromise,
    ]);

  const scores = scoresResult.ok ? scoresResult.value : {};
  const classification = classificationResult.ok ? classificationResult.value : null;
  const labelsRaw = Object.entries(scores).map(([name, score]) => ({
    name,
    score: Math.round(Number(score) * 100),
  }));
  const strictModesty = classificationResult.ok
    ? await scanStrictModesty(buffer, classification)
    : {
        available: false,
        checked: false,
        blocked: false,
        checks: [],
        error: classificationResult.error?.message || 'Image classification unavailable',
        totalDurationMs: 0,
      };
  const googleConfigured = googleSafeSearchConfigured();
  const googleThreshold = normalizeBlockThreshold(
    process.env.GOOGLE_SAFESEARCH_BLOCK_THRESHOLD,
  );
  const googleNotRun = status => ({
    provider: 'google-cloud-vision',
    configured: googleConfigured,
    available: false,
    enforced: googleConfigured,
    threshold: googleThreshold,
    categories: null,
    blocked: false,
    blockedCategories: [],
    uncertain: false,
    status,
    durationMs: 0,
  });
  const common = googleSafeSearch => ({
    safeSearch: googleSafeSearch?.available ? googleSafeSearch.categories : {},
    googleSafeSearch,
    labels: labelsRaw,
    faces: [],
    genderResults: null,
    classification,
    strictModesty,
    localSafety,
  });

  const adultScore = Number(scores['adult sexual content'] || 0);
  const nudityScore = Number(scores.nudity || 0);
  const revealingScore = Number(scores['lingerie or revealing clothing'] || 0);
  // Zero-shot CLIP scores are useful as supporting evidence, but low scores
  // must not override a strongly normal NSFW result. Require a strong signal
  // for explicit content and corroboration before enforcing clothing checks.
  const localExplicitContent = scoresResult.ok && (
    adultScore >= 0.75 || nudityScore >= 0.65 || revealingScore >= 0.70
  );
  const strictModestyCorroborated = strictModesty.blocked && scoresResult.ok && (
    adultScore >= 0.35 || nudityScore >= 0.20 || revealingScore >= 0.25
  );
  const localBlockedBy = strictModestyCorroborated ? 'strictModesty'
    : localExplicitContent ? 'localExplicitContent' : null;
  if (localBlockedBy) {
    return {
      ...common(googleNotRun('skipped_local_block')),
      blocked: true,
      blockedBy: localBlockedBy,
      reason: 'התמונה נחסמה — תוכן לא צנוע',
    };
  }

  if (!scoresResult.ok || !classificationResult.ok) {
    const error = scoresResult.error || classificationResult.error;
    console.error('Local CLIP scan:', error?.message || 'unknown error');
    return {
      ...common(googleNotRun('deferred_local_error')),
      pending: true,
      reason: 'בדיקת הסינון המקומית אינה זמינה כרגע',
    };
  }

  if (!strictModesty.available) {
    return {
      ...common(googleNotRun('deferred_local_error')),
      pending: true,
      reason: 'בדיקת הלבוש המחמירה אינה זמינה כרגע',
    };
  }

  const priorGoogleSafeSearch = options.googleSafeSearch;
  const canReuseGoogle = googleConfigured && priorGoogleSafeSearch?.available &&
    priorGoogleSafeSearch.provider === 'google-cloud-vision' &&
    priorGoogleSafeSearch.threshold === googleThreshold;
  const googleSafeSearch = canReuseGoogle
    ? { ...priorGoogleSafeSearch, reused: true, durationMs: 0 }
    : await scanGoogleSafeSearch(buffer);
  const finalCommon = common(googleSafeSearch);

  if (googleSafeSearch.blocked) {
    return {
      ...finalCommon,
      blocked: true,
      blockedBy: 'googleSafeSearch',
      reason: 'התמונה נחסמה — Google SafeSearch זיהה תוכן לא צנוע',
    };
  }

  if (googleSafeSearch.uncertain) {
    return {
      ...finalCommon,
      blocked: true,
      blockedBy: 'googleSafeSearchUncertain',
      reason: 'התמונה לא אושרה — Google SafeSearch החזיר תוצאה לא ידועה',
    };
  }

  if (googleSafeSearch.configured && !googleSafeSearch.available &&
      googleSafeSearch.retryable === false) {
    return {
      ...finalCommon,
      blocked: true,
      blockedBy: 'googleSafeSearchUnsupported',
      reason: 'התמונה לא אושרה — לא ניתן להכין אותה לבדיקת Google SafeSearch',
    };
  }

  // Once a server key is configured, Google is an enforced stage. A timeout,
  // quota/auth error or incomplete response can never approve an image; the
  // retry queue will run the scan again. Available results are
  // reused on retry so a separate local uncertainty does not create charges.
  if (googleSafeSearch.configured && !googleSafeSearch.available) {
    return {
      ...finalCommon,
      pending: true,
      reason: 'Google SafeSearch אינו זמין כרגע',
    };
  }

  return { ...finalCommon, blocked: false, blockedBy: null };
}

async function scanImage(buffer, options = {}) {
  if (!isPotentiallyAnimatedImage(buffer))
    return scanStaticImage(buffer, options);

  let metadata;
  try {
    metadata = await sharp(buffer, { animated: true }).metadata();
  } catch (error) {
    return {
      blocked: true,
      blockedBy: 'animatedImageDecode',
      reason: 'לא ניתן לפענח את התמונה המונפשת לצורך סריקה',
      error: error.message,
    };
  }
  const frameCount = Number(metadata.pages || 1);
  const maxScannableFrames = 12;
  if (frameCount > maxScannableFrames) {
    return {
      blocked: true,
      blockedBy: 'animatedImageTooManyFrames',
      reason: `GIF יכול להכיל עד ${maxScannableFrames} פריימים כדי שכל התמונה תיסרק`,
      frameCount,
      framesScanned: 0,
    };
  }

  const frameResults = [];
  for (let page = 0; page < frameCount; page++) {
    let frame;
    try {
      frame = await sharp(buffer, { animated: true, page, pages: 1 })
        .png()
        .toBuffer();
    } catch (error) {
      return {
        blocked: true,
        blockedBy: 'animatedImageDecode',
        reason: `לא ניתן לסרוק את פריים ${page + 1} בתמונה המונפשת`,
        frameCount,
        framesScanned: page,
        error: error.message,
      };
    }
    const result = await scanStaticImage(frame);
    frameResults.push(result);
    if (result.blocked) return {
      ...result,
      reason: `GIF נחסם בפריים ${page + 1}: ${result.reason || 'תוכן לא מאושר'}`,
      frameCount,
      framesScanned: page + 1,
    };
    if (result.pending) return {
      ...result,
      reason: `סריקת GIF ממתינה בפריים ${page + 1}: ${result.reason || 'שירות הסריקה אינו זמין'}`,
      frameCount,
      framesScanned: page + 1,
    };
  }
  return {
    ...frameResults[0],
    blocked: false,
    blockedBy: null,
    animated: true,
    frameCount,
    framesScanned: frameCount,
  };
}

async function scanDocument(buffer, mimetype) {
  try {
    let text = '';
    if (mimetype === 'application/pdf') {
      const pdfParse = require('pdf-parse');
      const d = await pdfParse(buffer);
      text = d.text.toLowerCase();
    } else {
      const mammoth = require('mammoth');
      const r = await mammoth.extractRawText({ buffer });
      text = r.value.toLowerCase();
    }
    const found = BLOCKED_WORDS.find(w => text.includes(w.toLowerCase()));
    if (found) return { blocked: true, reason: 'המסמך נחסם — תוכן לא הולם' };
    return { blocked: false };
  } catch { return { pending: true }; }
}

const mailer = nodemailer.createTransport({
  host: 'smtp.gmail.com',
  port: 587,
  secure: false, // STARTTLS — port 465 (implicit TLS) is firewalled on this host
  auth: {
    user: process.env.EMAIL_FROM,
    pass: process.env.EMAIL_APP_PASSWORD,
  },
  tls: { rejectUnauthorized: false },
});

async function sendEmail({ to, subject, html }) {
  return mailer.sendMail({
    from: `"BETSHUVA" <${process.env.EMAIL_FROM}>`,
    to,
    subject,
    html,
  });
}

function welcomeEmail(name) {
  return `<div dir="rtl" style="font-family:Arial,sans-serif;max-width:600px;margin:0 auto;padding:20px">
    <div style="background:#1B4332;padding:24px;border-radius:12px 12px 0 0;text-align:center">
      <h1 style="color:white;margin:0;font-size:24px">בתשובה</h1>
      <p style="color:rgba(255,255,255,0.8);margin:8px 0 0">מסרים לקהילה הישראלית</p>
    </div>
    <div style="background:#fff;padding:28px;border-radius:0 0 12px 12px;border:1px solid #e0e0e0">
      <h2 style="color:#1B4332;margin-top:0">ברוכים הבאים, ${name}!</h2>
      <p style="color:#444;line-height:1.6">חשבונך נרשם בהצלחה. אנו שמחים שהצטרפת לקהילת בתשובה.</p>
      <p style="color:#6C757D;font-size:13px;margin-top:24px;border-top:1px solid #eee;padding-top:16px">בתשובה — מסרים לקהילה הישראלית</p>
    </div>
  </div>`;
}

function emailVerificationEmail(name, verifyUrl) {
  return `<div dir="rtl" style="font-family:Arial,sans-serif;max-width:600px;margin:0 auto;padding:20px">
    <div style="background:#1B4332;padding:24px;border-radius:12px 12px 0 0;text-align:center">
      <h1 style="color:white;margin:0;font-size:24px">בתשובה</h1>
    </div>
    <div style="background:#fff;padding:28px;border-radius:0 0 12px 12px;border:1px solid #e0e0e0">
      <h2 style="color:#1B4332;margin-top:0">אימות כתובת האימייל</h2>
      <p style="color:#444;line-height:1.6">שלום ${name}, לחץ על הכפתור הבא לאימות האימייל שלך:</p>
      <div style="text-align:center;margin:28px 0">
        <a href="${verifyUrl}" style="background:#1B4332;color:white;padding:14px 32px;text-decoration:none;border-radius:8px;font-size:16px;font-weight:bold">אמת אימייל</a>
      </div>
      <p style="color:#888;font-size:12px">הקישור תקף ל-24 שעות. אם לא נרשמת, התעלם מהודעה זו.</p>
      <p style="color:#6C757D;font-size:13px;margin-top:24px;border-top:1px solid #eee;padding-top:16px">בתשובה — מסרים לקהילה הישראלית</p>
    </div>
  </div>`;
}

function resetPasswordEmail(resetUrl) {
  return `<div dir="rtl" style="font-family:Arial,sans-serif;max-width:600px;margin:0 auto;padding:20px">
    <div style="background:#1B4332;padding:24px;border-radius:12px 12px 0 0;text-align:center">
      <h1 style="color:white;margin:0;font-size:24px">בתשובה</h1>
    </div>
    <div style="background:#fff;padding:28px;border-radius:0 0 12px 12px;border:1px solid #e0e0e0">
      <h2 style="color:#1B4332;margin-top:0">איפוס סיסמה</h2>
      <p style="color:#444;line-height:1.6">קיבלנו בקשה לאיפוס הסיסמה שלך. לחץ על הכפתור הבא לאיפוס:</p>
      <div style="text-align:center;margin:28px 0">
        <a href="${resetUrl}" style="background:#1B4332;color:white;padding:14px 32px;text-decoration:none;border-radius:8px;font-size:16px;font-weight:bold">איפוס סיסמה</a>
      </div>
      <p style="color:#888;font-size:12px">הקישור תקף ל-1 שעה בלבד. אם לא ביקשת איפוס, התעלם מהודעה זו.</p>
      <p style="color:#6C757D;font-size:13px;margin-top:24px;border-top:1px solid #eee;padding-top:16px">בתשובה — מסרים לקהילה הישראלית</p>
    </div>
  </div>`;
}

// Auto-migrate: create all messenger tables. Startup awaits this function so
// the API can never accept traffic against a partially initialized database.
async function migrateDatabase() {
    const pool = await getPool();

    await pool.query(`CREATE EXTENSION IF NOT EXISTS pgcrypto`);

    // ── Users (the root table referenced by most of the schema) ────
    await pool.query(`
      CREATE TABLE IF NOT EXISTS users (
        id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        name                TEXT NOT NULL,
        email               TEXT UNIQUE,
        password_hash       TEXT,
        phone               TEXT,
        email_verified      BOOLEAN NOT NULL DEFAULT FALSE,
        phone_verified      BOOLEAN NOT NULL DEFAULT FALSE,
        city                TEXT,
        country             TEXT,
        street              TEXT,
        house_number        TEXT,
        apartment           TEXT,
        profile_pic_url     TEXT,
        privacy_pic         TEXT NOT NULL DEFAULT 'all',
        filter_level        TEXT NOT NULL DEFAULT 'standard',
        google_id           TEXT,
        latitude            DOUBLE PRECISION,
        longitude           DOUBLE PRECISION,
        location_updated_at TIMESTAMPTZ,
        wins                INTEGER NOT NULL DEFAULT 0,
        games_played        INTEGER NOT NULL DEFAULT 0,
        created_at          TIMESTAMPTZ DEFAULT now()
      )`);

    // ── Auth tokens ────────────────────────────────────────────────
    await pool.query(`
      CREATE TABLE IF NOT EXISTS password_reset_tokens (
        token      TEXT PRIMARY KEY,
        user_id    UUID NOT NULL REFERENCES users(id),
        expires_at TIMESTAMPTZ NOT NULL,
        used       BOOLEAN DEFAULT FALSE
      )`);

    await pool.query(`
      CREATE TABLE IF NOT EXISTS email_verification_tokens (
        token      TEXT PRIMARY KEY,
        user_id    UUID NOT NULL REFERENCES users(id),
        expires_at TIMESTAMPTZ NOT NULL,
        used       BOOLEAN DEFAULT FALSE
      )`);

    // ── Users – new columns ────────────────────────────────────────
    await pool.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS email_verified BOOLEAN NOT NULL DEFAULT FALSE`);
    await pool.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS phone TEXT`);
    await pool.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS phone_verified BOOLEAN NOT NULL DEFAULT FALSE`);
    await pool.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS city TEXT`);
    // This profile field was removed to avoid collecting religious/community
    // affiliation. Dropping it also deletes values collected by older builds.
    await pool.query(`ALTER TABLE users DROP COLUMN IF EXISTS community`);
    await pool.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS profile_pic_url TEXT`);
    await pool.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS privacy_pic TEXT NOT NULL DEFAULT 'all'`);
    await pool.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS filter_level TEXT NOT NULL DEFAULT 'standard'`);
    await pool.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS content_filter JSONB NOT NULL DEFAULT '{"text":true,"nonHumanImages":true,"men":true,"women":true,"children":true}'::jsonb`);

    // ── Allow phone-only / email-only accounts ─────────────────────
    await pool.query(`ALTER TABLE users ALTER COLUMN email DROP NOT NULL`);
    await pool.query(`ALTER TABLE users ALTER COLUMN password_hash DROP NOT NULL`);
    await pool.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS google_id TEXT`);
    await pool.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS country TEXT`);
    await pool.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS street TEXT`);
    await pool.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS house_number TEXT`);
    await pool.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS apartment TEXT`);
    await pool.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS latitude DOUBLE PRECISION`);
    await pool.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS longitude DOUBLE PRECISION`);
    await pool.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS location_updated_at TIMESTAMPTZ`);
    await pool.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS terms_accepted_at TIMESTAMPTZ`);
    await pool.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS terms_version TEXT`);
    await pool.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS age_confirmed BOOLEAN NOT NULL DEFAULT FALSE`);
    await pool.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS gender TEXT`);
    await pool.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS wins INTEGER NOT NULL DEFAULT 0`);
    await pool.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS games_played INTEGER NOT NULL DEFAULT 0`);
    await pool.query(`
      INSERT INTO users(id,name,email,phone,email_verified,phone_verified,city)
      VALUES($1,'סריקה',$2,'0000000000',TRUE,TRUE,'מערכת')
      ON CONFLICT (id) DO UPDATE SET name='סריקה', email=$2,
        email_verified=TRUE, phone_verified=TRUE`, [SCAN_BOT_ID, SCAN_BOT_EMAIL]);

    // Only one verified identity may own a phone number or email address.
    // Unverified drafts may coexist, but a second one can never be verified.
    await pool.query(`
      CREATE UNIQUE INDEX IF NOT EXISTS users_verified_phone_unique
      ON users (phone)
      WHERE phone_verified = TRUE AND phone IS NOT NULL`);
    await pool.query(`
      CREATE UNIQUE INDEX IF NOT EXISTS users_verified_email_unique
      ON users (lower(email))
      WHERE email_verified = TRUE AND email IS NOT NULL`);

    // ── Admin permissions ──────────────────────────────────────────
    await pool.query(`
      CREATE TABLE IF NOT EXISTS admin_permissions (
        user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        permission TEXT NOT NULL DEFAULT 'view',
        granted_at TIMESTAMPTZ DEFAULT now(),
        PRIMARY KEY (user_id)
      )`);
    // Seed betshuva@betshuva.com as edit admin
    await pool.query(`
      INSERT INTO admin_permissions (user_id, permission)
      SELECT id, 'edit' FROM users WHERE email = 'betshuva@betshuva.com'
      ON CONFLICT (user_id) DO NOTHING`);

    // ── Groups ─────────────────────────────────────────────────────
    await pool.query(`
      CREATE TABLE IF NOT EXISTS groups (
        id              UUID DEFAULT gen_random_uuid() PRIMARY KEY,
        name            TEXT NOT NULL,
        description     TEXT,
        creator_id      UUID REFERENCES users(id),
        is_broadcast    BOOLEAN NOT NULL DEFAULT FALSE,
        send_permission TEXT NOT NULL DEFAULT 'all',
        filter_level    TEXT NOT NULL DEFAULT 'standard',
        created_at      TIMESTAMPTZ DEFAULT now()
      )`);
    await pool.query(`ALTER TABLE groups ADD COLUMN IF NOT EXISTS profile_pic_url TEXT`);

    // ── Messages ───────────────────────────────────────────────────
    await pool.query(`
      CREATE TABLE IF NOT EXISTS messages (
        id                   UUID DEFAULT gen_random_uuid() PRIMARY KEY,
        sender_id            UUID NOT NULL REFERENCES users(id),
        recipient_id         UUID REFERENCES users(id),
        group_id             UUID REFERENCES groups(id),
        type                 TEXT NOT NULL DEFAULT 'text',
        body                 TEXT,
        file_url             TEXT,
        file_name            TEXT,
        file_size            INTEGER,
        reply_to_id          UUID REFERENCES messages(id),
        deleted_for_sender   BOOLEAN NOT NULL DEFAULT FALSE,
        deleted_for_everyone BOOLEAN NOT NULL DEFAULT FALSE,
        created_at           TIMESTAMPTZ DEFAULT now()
      )`);

    // ── Messages: edit columns ─────────────────────────────────────
    await pool.query(`ALTER TABLE messages ADD COLUMN IF NOT EXISTS is_edited BOOLEAN NOT NULL DEFAULT FALSE`);
    await pool.query(`ALTER TABLE messages ADD COLUMN IF NOT EXISTS edited_at TIMESTAMPTZ`);

    // ── Message Status ─────────────────────────────────────────────
    await pool.query(`
      CREATE TABLE IF NOT EXISTS message_status (
        message_id UUID NOT NULL REFERENCES messages(id),
        user_id    UUID NOT NULL REFERENCES users(id),
        status     TEXT NOT NULL DEFAULT 'delivered',
        updated_at TIMESTAMPTZ DEFAULT now(),
        PRIMARY KEY (message_id, user_id)
      )`);

    // ── Group Members ──────────────────────────────────────────────
    await pool.query(`
      CREATE TABLE IF NOT EXISTS group_members (
        group_id  UUID NOT NULL REFERENCES groups(id),
        user_id   UUID NOT NULL REFERENCES users(id),
        role      TEXT NOT NULL DEFAULT 'member',
        joined_at TIMESTAMPTZ DEFAULT now(),
        PRIMARY KEY (group_id, user_id)
      )`);
    await pool.query(`ALTER TABLE group_members ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'member'`);
    await pool.query(`ALTER TABLE group_members ADD COLUMN IF NOT EXISTS added_by UUID`);
    await pool.query(`ALTER TABLE group_members ADD COLUMN IF NOT EXISTS pending_since TIMESTAMPTZ`);
    await pool.query(`ALTER TABLE group_members ADD COLUMN IF NOT EXISTS last_viewed_at TIMESTAMPTZ`);
    await pool.query(`ALTER TABLE group_members ADD COLUMN IF NOT EXISTS pinned_at TIMESTAMPTZ`);
    await pool.query(`
      CREATE TABLE IF NOT EXISTS external_group_invites (
        id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        group_id UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
        invited_by UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        email TEXT,
        phone TEXT,
        contact_name TEXT,
        status TEXT NOT NULL DEFAULT 'pending',
        claimed_by UUID REFERENCES users(id) ON DELETE SET NULL,
        created_at TIMESTAMPTZ DEFAULT now(),
        CHECK (email IS NOT NULL OR phone IS NOT NULL)
      )`);
    await pool.query(`CREATE INDEX IF NOT EXISTS external_group_invites_email_idx ON external_group_invites(lower(email)) WHERE status='pending'`);
    await pool.query(`CREATE INDEX IF NOT EXISTS external_group_invites_phone_idx ON external_group_invites(phone) WHERE status='pending'`);

    await pool.query(`
      CREATE TABLE IF NOT EXISTS user_contacts (
        owner_id   UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        contact_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        created_at TIMESTAMPTZ DEFAULT now(),
        PRIMARY KEY (owner_id, contact_id),
        CHECK (owner_id <> contact_id)
      )`);
    await pool.query(`ALTER TABLE user_contacts ADD COLUMN IF NOT EXISTS filter_override JSONB`);
    await pool.query(`ALTER TABLE user_contacts ADD COLUMN IF NOT EXISTS pinned_at TIMESTAMPTZ`);
    await pool.query(`DROP TRIGGER IF EXISTS users_add_scan_bot_contact ON users`);
    await pool.query(`DROP FUNCTION IF EXISTS add_scan_bot_contact_for_new_user()`);
    // The scanner remains an internal FK identity for moderation reports, but
    // must never appear as a contact or a user-facing conversation.
    await pool.query(
      `DELETE FROM user_contacts WHERE owner_id=$1 OR contact_id=$1`,
      [SCAN_BOT_ID]);
    await pool.query(`
      CREATE TABLE IF NOT EXISTS message_requests (
        id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        sender_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        recipient_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        body TEXT,
        type TEXT NOT NULL DEFAULT 'text',
        file_url TEXT,
        file_name TEXT,
        created_at TIMESTAMPTZ DEFAULT now(),
        UNIQUE(sender_id, recipient_id)
      )`);
    const contactsInitialized = await pool.query(
      `SELECT 1 FROM app_settings WHERE key_name='contacts_initialized'`);
    if (!contactsInitialized.rows.length) {
      // Preserve the list existing accounts had before contacts were added.
      // Accounts created after this migration start with an empty list.
      await pool.query(`
        INSERT INTO user_contacts(owner_id, contact_id)
        SELECT owner.id, contact.id FROM users owner CROSS JOIN users contact
        WHERE owner.id <> contact.id ON CONFLICT DO NOTHING`);
      await pool.query(
        `INSERT INTO app_settings(key_name,value) VALUES('contacts_initialized','true')
         ON CONFLICT (key_name) DO NOTHING`);
    }

    // ── Blocked Users ──────────────────────────────────────────────
    await pool.query(`
      CREATE TABLE IF NOT EXISTS blocked_users (
        blocker_id UUID NOT NULL REFERENCES users(id),
        blocked_id UUID NOT NULL REFERENCES users(id),
        created_at TIMESTAMPTZ DEFAULT now(),
        PRIMARY KEY (blocker_id, blocked_id)
      )`);

    // ── User reports (Google Play UGC moderation) ─────────────────
    await pool.query(`
      CREATE TABLE IF NOT EXISTS user_reports (
        id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        reporter_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        target_type TEXT NOT NULL CHECK (target_type IN ('user','message','group','listing')),
        target_id   UUID NOT NULL,
        reason      TEXT NOT NULL,
        details     TEXT,
        status      TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','reviewed','resolved','dismissed')),
        reviewed_by UUID REFERENCES users(id) ON DELETE SET NULL,
        reviewed_at TIMESTAMPTZ,
        created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
        UNIQUE (reporter_id, target_type, target_id)
      )`);
    await pool.query(`CREATE INDEX IF NOT EXISTS user_reports_status_created_idx
      ON user_reports(status, created_at DESC)`);

    // ── Audit Log ──────────────────────────────────────────────────
    await pool.query(`
      CREATE TABLE IF NOT EXISTS audit_log (
        id         UUID DEFAULT gen_random_uuid() PRIMARY KEY,
        user_id    UUID REFERENCES users(id),
        file_name  TEXT,
        file_type  TEXT,
        file_size  INTEGER,
        reason     TEXT,
        appealed   BOOLEAN NOT NULL DEFAULT FALSE,
        created_at TIMESTAMPTZ DEFAULT now()
      )`);

    // ── FCM Tokens ─────────────────────────────────────────────────
    await pool.query(`
      CREATE TABLE IF NOT EXISTS fcm_tokens (
        user_id    UUID NOT NULL REFERENCES users(id),
        token      TEXT NOT NULL,
        device_id  TEXT NOT NULL DEFAULT 'default',
        updated_at TIMESTAMPTZ DEFAULT now(),
        PRIMARY KEY (user_id, device_id)
      )`);

    // ── Activity Log ───────────────────────────────────────────────
    await pool.query(`
      CREATE TABLE IF NOT EXISTS activity_log (
        id         UUID DEFAULT gen_random_uuid() PRIMARY KEY,
        user_id    UUID REFERENCES users(id),
        action     TEXT NOT NULL,
        details    JSONB,
        ip         TEXT,
        created_at TIMESTAMPTZ DEFAULT now()
      )`);

    await pool.query(`
      CREATE TABLE IF NOT EXISTS stored_files (
        id            UUID DEFAULT gen_random_uuid() PRIMARY KEY,
        user_id       UUID REFERENCES users(id) ON DELETE SET NULL,
        original_name TEXT NOT NULL,
        storage_path  TEXT NOT NULL UNIQUE,
        public_url    TEXT NOT NULL UNIQUE,
        mime_type     TEXT,
        file_type     TEXT,
        file_size     BIGINT NOT NULL DEFAULT 0,
        context_type  TEXT,
        context_id    UUID,
        created_at    TIMESTAMPTZ DEFAULT now()
      )`);
    await pool.query(`ALTER TABLE stored_files ADD COLUMN IF NOT EXISTS moderation_status TEXT NOT NULL DEFAULT 'pending'`);
    await pool.query(`ALTER TABLE stored_files ALTER COLUMN moderation_status SET DEFAULT 'pending'`);
    await pool.query(`ALTER TABLE stored_files ADD COLUMN IF NOT EXISTS moderation_details JSONB`);
    // Legacy rows predate moderation_status. Trust only files that were already
    // delivered in the same sender/recipient or sender/group context.
    await pool.query(`
      UPDATE stored_files sf SET moderation_status='pending'
      WHERE sf.moderation_details IS NULL AND NOT EXISTS (
        SELECT 1 FROM messages m
        WHERE m.sender_id=sf.user_id AND m.file_url=sf.public_url
          AND ((sf.context_type='chat' AND m.recipient_id=sf.context_id)
            OR (sf.context_type='group' AND m.group_id=sf.context_id))
      )`);
    await pool.query(`
      UPDATE stored_files sf SET moderation_status='approved'
      WHERE sf.moderation_status='pending' AND EXISTS (
        SELECT 1 FROM messages m
        WHERE m.sender_id=sf.user_id AND m.file_url=sf.public_url
          AND ((sf.context_type='chat' AND m.recipient_id=sf.context_id)
            OR (sf.context_type='group' AND m.group_id=sf.context_id))
      )`);

    await pool.query(`
      CREATE TABLE IF NOT EXISTS app_settings (
        key_name   TEXT PRIMARY KEY,
        value      TEXT NOT NULL,
        updated_at TIMESTAMPTZ DEFAULT now()
      )`);

    // ── Games ──────────────────────────────────────────────────────
    await pool.query(`
      CREATE TABLE IF NOT EXISTS games (
        id         UUID DEFAULT gen_random_uuid() PRIMARY KEY,
        player1_id UUID NOT NULL REFERENCES users(id),
        player2_id UUID NOT NULL REFERENCES users(id),
        winner_id  UUID REFERENCES users(id),
        result     TEXT NOT NULL,
        board      TEXT NOT NULL,
        played_at  TIMESTAMPTZ DEFAULT now()
      )`);

    console.log('Migration: all tables ready');

    // Load moderation lists from DB (if saved), else seed defaults
    try {
      const r = await pool.query(
        `SELECT key_name, value FROM app_settings WHERE key_name IN ('female_labels','blocked_words')`
      );
      const map = {};
      for (const row of r.rows) map[row.key_name] = JSON.parse(row.value);
      if (map.female_labels) FEMALE_LABELS = map.female_labels;
      if (map.blocked_words) BLOCKED_WORDS = map.blocked_words;
      if (!map.female_labels) await pool.query(
        `INSERT INTO app_settings (key_name,value) VALUES ($1,$2)`,
        ['female_labels', JSON.stringify(DEFAULT_FEMALE_LABELS)]);
      if (!map.blocked_words) await pool.query(
        `INSERT INTO app_settings (key_name,value) VALUES ($1,$2)`,
        ['blocked_words', JSON.stringify(DEFAULT_BLOCKED_WORDS)]);
    } catch (e) { console.error('Moderation list load error:', e.message); }

}

// ── Activity logger ───────────────────────────────────────────────
async function logActivity(userId, action, details = {}, ip = null) {
  try {
    const pool = await getPool();
    await pool.query(
      `INSERT INTO activity_log (user_id, action, details, ip) VALUES ($1, $2, $3, $4)`,
      [userId || null, action, JSON.stringify(details), ip || null]);
  } catch (_) {}
}

const allowedOrigins = new Set((process.env.CORS_ORIGINS ||
  'https://betshuva.com,https://www.betshuva.com')
  .split(',').map(value => value.trim()).filter(Boolean));
const corsOptions = {
  origin(origin, callback) {
    if (!origin || allowedOrigins.has(origin)) return callback(null, true);
    callback(new Error('Origin is not allowed'));
  },
};

const app = express();
const httpServer = createServer(app);
const io = new Server(httpServer, { cors: corsOptions });
app.set('io', io);

app.disable('x-powered-by');
// Nginx runs on the same host. Trust only the local reverse proxy when resolving req.ip.
app.set('trust proxy', 'loopback');
app.use(cors(corsOptions));
app.use(express.json({ limit: '1mb' }));
app.use((req, res, next) => {
  res.set({
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'strict-origin-when-cross-origin',
    'Permissions-Policy': 'camera=(self), microphone=(self), geolocation=(self)',
  });
  next();
});
app.use((req, res, next) => {
  const requestPath = req.path.toLowerCase();
  const blockedDirectories = [
    '/server', '/flutter_app', '/test', '/docs', '/local_moderation', '/.git',
  ];
  const blockedFiles = [
    '/package.json', '/package-lock.json', '/readme.md',
    '/docker-compose.local-moderation.yml', '/.env',
  ];
  if (blockedDirectories.some(prefix =>
      requestPath === prefix || requestPath.startsWith(`${prefix}/`)) ||
      blockedFiles.includes(requestPath) || requestPath.endsWith('/.env')) {
    return res.status(404).end();
  }
  next();
});
app.use(express.static(require('path').join(__dirname, '..')));
app.use('/app', express.static(require('path').join(__dirname, '..', 'flutter_web')));

// Baseline protection for all API routes. Sensitive/write-heavy routes below
// receive additional, stricter per-account or per-user limits.
app.use('/api', apiRateLimit);

app.get('/app', (req, res) => res.redirect('/app/'));
app.get('/public-home', (req, res) => res.sendFile(require('path').join(__dirname, '..', 'home.html')));
app.get('/privacy', (req, res) => res.sendFile(require('path').join(__dirname, '..', 'privacy.html')));
app.get('/terms', (req, res) => res.sendFile(require('path').join(__dirname, '..', 'terms.html')));
app.get('/delete-account', (req, res) => res.sendFile(require('path').join(__dirname, '..', 'delete-account.html')));
app.get('/accessibility', (req, res) => res.sendFile(require('path').join(__dirname, '..', 'accessibility.html')));

const JWT_SECRET = process.env.JWT_SECRET;
if (!JWT_SECRET) {
  throw new Error('JWT_SECRET is required; refusing to start with an insecure default');
}
const onlineUsers = new Map(); // userId → socketId
const otpStore    = new Map(); // phone → { code, expires, name }
const socketRateBuckets = new Map();
const activeVoiceCalls = new Map(); // callId → { callerId, calleeId, timeout }
const userVoiceCalls = new Map();   // userId → callId

function finishVoiceCall(callId, endedBy, reason = 'ended') {
  const call = activeVoiceCalls.get(callId);
  if (!call) return;
  clearTimeout(call.timeout);
  activeVoiceCalls.delete(callId);
  userVoiceCalls.delete(call.callerId);
  userVoiceCalls.delete(call.calleeId);
  for (const userId of [call.callerId, call.calleeId]) {
    if (userId === endedBy) continue;
    const sid = onlineUsers.get(userId);
    if (sid) io.to(sid).emit('call:end', { callId, reason });
  }
}

function allowSocketEvent(socket, category, max, windowMs) {
  const now = Date.now();
  const key = `${socket.user.id}:${category}`;
  let bucket = socketRateBuckets.get(key);
  if (!bucket || bucket.resetAt <= now) {
    bucket = { count: 0, resetAt: now + windowMs };
    socketRateBuckets.set(key, bucket);
  }
  bucket.count++;
  if (bucket.count <= max) return true;
  socket.emit('rate:limited', {
    category,
    retryAfter: Math.max(1, Math.ceil((bucket.resetAt - now) / 1000)),
  });
  return false;
}

const socketRateCleanup = setInterval(() => {
  const now = Date.now();
  for (const [key, bucket] of socketRateBuckets) {
    if (bucket.resetAt <= now) socketRateBuckets.delete(key);
  }
}, 5 * 60 * 1000);
socketRateCleanup.unref();

async function auth(req, res, next) {
  const token = req.headers.authorization?.split(' ')[1];
  if (!token) return res.status(401).json({ error: 'לא מחובר' });
  try {
    req.user = jwt.verify(token, JWT_SECRET);
    const pool = await getPool();
    const result = await pool.query(
      'SELECT phone, email_verified, phone_verified FROM users WHERE id = $1', [req.user.id]);
    if (!result.rows.length)
      return res.status(401).json({ error: 'המשתמש אינו קיים — נא להתחבר מחדש' });
    const registrationComplete = !!result.rows[0].phone &&
      (result.rows[0].email_verified === true || result.rows[0].phone_verified === true);
    if (!registrationComplete && !req.path.endsWith('/link-phone'))
      return res.status(403).json({ error: 'יש להשלים אימות טלפון או אימייל', code: 'VERIFICATION_REQUIRED' });
    next();
  } catch {
    res.status(401).json({ error: 'טוקן לא תקין — נא להתחבר מחדש' });
  }
}

// Allows a saved session to finish phone setup before entering the app.
app.get('/api/registration-status', async (req, res) => {
  const token = req.headers.authorization?.split(' ')[1];
  if (!token) return res.status(401).json({ error: 'לא מחובר' });
  try {
    const tokenUser = jwt.verify(token, JWT_SECRET);
    const pool = await getPool();
    const result = await pool.query(
      'SELECT phone, email_verified, phone_verified FROM users WHERE id=$1', [tokenUser.id]);
    if (!result.rows.length)
      return res.status(401).json({ error: 'המשתמש אינו קיים' });
    const user = result.rows[0];
    res.json({
      phoneMissing: !user.phone,
      verificationRequired:
        user.email_verified !== true && user.phone_verified !== true,
    });
  } catch (_) {
    res.status(401).json({ error: 'טוקן לא תקין' });
  }
});

// Short-lived TURN REST credentials. The shared secret never leaves the
// server; clients receive credentials valid for ten minutes only.
app.get('/api/calls/ice-servers', auth, (req, res) => {
  const secret = process.env.TURN_SECRET;
  if (!secret) {
    return res.json({ iceServers: [
      { urls: ['stun:stun.l.google.com:19302', 'stun:stun1.l.google.com:19302'] },
    ] });
  }
  const expires = Math.floor(Date.now() / 1000) + 10 * 60;
  const username = `${expires}:${req.user.id}`;
  const credential = crypto.createHmac('sha1', secret).update(username).digest('base64');
  res.set('Cache-Control', 'no-store');
  res.json({
    expires,
    iceServers: [
      { urls: ['stun:stun.l.google.com:19302', 'stun:stun1.l.google.com:19302'] },
      {
        urls: [
          'turn:178.105.240.236:3478?transport=udp',
          'turn:178.105.240.236:3478?transport=tcp',
        ],
        username,
        credential,
      },
    ],
  });
});

// middleware שבודק שהמשתמש קיים ב-DB (למניעת ghost sessions)
async function authWithDbCheck(req, res, next) {
  const token = req.headers.authorization?.split(' ')[1];
  if (!token) return res.status(401).json({ error: 'לא מחובר' });
  try {
    req.user = jwt.verify(token, JWT_SECRET);
    const pool = await getPool();
    const exists = await pool.query(
      'SELECT phone, email_verified, phone_verified FROM users WHERE id = $1', [req.user.id]);
    if (!exists.rows.length) {
      console.warn(`[AUTH] ghost session — id:${req.user.id} email:${req.user.email}`);
      return res.status(401).json({ error: 'המשתמש אינו קיים — נא להתחבר מחדש' });
    }
    if (!exists.rows[0].phone)
      return res.status(403).json({ error: 'יש להזין מספר טלפון', code: 'PHONE_REQUIRED' });
    if (exists.rows[0].email_verified !== true &&
        exists.rows[0].phone_verified !== true)
      return res.status(403).json({ error: 'יש להשלים אימות טלפון או אימייל', code: 'VERIFICATION_REQUIRED' });
    next();
  } catch {
    res.status(401).json({ error: 'טוקן לא תקין' });
  }
}

// ── Socket.io ────────────────────────────────────────────────────
io.use(async (socket, next) => {
  try {
    socket.user = jwt.verify(socket.handshake.auth.token, JWT_SECRET);
    const pool = await getPool();
    const exists = await pool.query(
      'SELECT phone, email_verified, phone_verified FROM users WHERE id = $1', [socket.user.id]);
    if (!exists.rows.length) {
      console.warn(`[SOCKET] user_not_found — id:${socket.user.id} email:${socket.user.email} name:${socket.user.name}`);
      return next(new Error('user_not_found'));
    }
    if (!exists.rows[0].phone) return next(new Error('phone_required'));
    if (exists.rows[0].email_verified !== true &&
        exists.rows[0].phone_verified !== true)
      return next(new Error('verification_required'));
    next();
  } catch (e) {
    console.warn(`[SOCKET] unauthorized — ${e.message}`);
    next(new Error('unauthorized'));
  }
});

async function claimExternalGroupInvites(userId) {
  const pool = await getPool();
  const userResult = await pool.query(
    'SELECT lower(email) AS email, phone FROM users WHERE id=$1', [userId]);
  const user = userResult.rows[0];
  if (!user) return;
  const invites = await pool.query(
    `SELECT id, group_id, invited_by FROM external_group_invites
     WHERE status='pending'
       AND (($1 <> '' AND lower(email)=$1) OR ($2 <> '' AND phone=$2))`,
    [user.email || '', user.phone || '']);
  for (const invite of invites.rows) {
    await pool.query(
      `INSERT INTO group_members(group_id,user_id,status,added_by,pending_since)
       VALUES($1,$2,'pending',$3,now()) ON CONFLICT DO NOTHING`,
      [invite.group_id, userId, invite.invited_by]);
    await pool.query(
      `UPDATE external_group_invites SET status='claimed', claimed_by=$1 WHERE id=$2`,
      [userId, invite.id]);
  }
}

io.on('connection', async (socket) => {
  onlineUsers.set(socket.user.id, socket.id);
  io.emit('users:online', [...onlineUsers.keys()]);
  claimExternalGroupInvites(socket.user.id).catch(e =>
    console.error('claimExternalGroupInvites:', e.message));

  // Register call signaling before asynchronous chat initialization so a
  // client can safely call as soon as it receives the call:ready event.
  socket.on('call:start', async ({ toUserId } = {}) => {
    if (!toUserId || toUserId === socket.user.id) return;
    if (!allowSocketEvent(socket, 'call', 10, 60 * 1000)) return;
    if (userVoiceCalls.has(socket.user.id)) {
      return socket.emit('call:error', { code: 'CALLER_BUSY', message: 'כבר מתקיימת שיחה' });
    }
    const targetSid = onlineUsers.get(toUserId);
    if (userVoiceCalls.has(toUserId)) {
      return socket.emit('call:unavailable', { toUserId, reason: 'busy' });
    }
    try {
      const pool = await getPool();
      const allowed = await pool.query(
        `SELECT 1 FROM user_contacts
         WHERE owner_id=$1 AND contact_id=$2
           AND NOT EXISTS (
             SELECT 1 FROM blocked_users
             WHERE (blocker_id=$1 AND blocked_id=$2)
                OR (blocker_id=$2 AND blocked_id=$1))`,
        [toUserId, socket.user.id]);
      if (!allowed.rows.length) {
        return socket.emit('call:unavailable', { toUserId, reason: 'not_allowed' });
      }
      const callId = crypto.randomUUID();
      const timeout = setTimeout(() => finishVoiceCall(callId, null, 'no_answer'), 30 * 1000);
      activeVoiceCalls.set(callId, {
        callerId: socket.user.id,
        callerName: socket.user.name || 'משתמש',
        calleeId: toUserId,
        timeout,
      });
      userVoiceCalls.set(socket.user.id, callId);
      userVoiceCalls.set(toUserId, callId);
      socket.emit('call:ringing', { callId, toUserId });
      if (targetSid) {
        io.to(targetSid).emit('call:incoming', {
          callId, fromUserId: socket.user.id, fromName: socket.user.name || 'משתמש',
        });
      }
      sendPush(toUserId, 'שיחה נכנסת', `${socket.user.name || 'משתמש'} מתקשר אליך`, {
        type: 'call', callId, fromUserId: socket.user.id,
        fromName: socket.user.name || 'משתמש',
      });
    } catch (e) {
      console.error('call:start:', e.message);
      socket.emit('call:error', { code: 'SERVER_ERROR', message: 'לא ניתן להתחיל שיחה' });
    }
  });

  socket.on('call:accept', ({ callId } = {}) => {
    const call = activeVoiceCalls.get(callId);
    if (!call || call.calleeId !== socket.user.id) return;
    clearTimeout(call.timeout);
    const callerSid = onlineUsers.get(call.callerId);
    if (callerSid) io.to(callerSid).emit('call:accepted', { callId, byUserId: socket.user.id });
  });

  socket.on('call:reject', ({ callId } = {}) => {
    const call = activeVoiceCalls.get(callId);
    if (!call || call.calleeId !== socket.user.id) return;
    finishVoiceCall(callId, socket.user.id, 'rejected');
  });

  socket.on('call:signal', ({ callId, signal } = {}) => {
    const call = activeVoiceCalls.get(callId);
    if (!call || !signal ||
        (call.callerId !== socket.user.id && call.calleeId !== socket.user.id)) return;
    if (!allowSocketEvent(socket, 'call_signal', 240, 60 * 1000)) return;
    const otherId = call.callerId === socket.user.id ? call.calleeId : call.callerId;
    const sid = onlineUsers.get(otherId);
    if (sid) io.to(sid).emit('call:signal', { callId, signal });
  });

  socket.on('call:diagnostic', (data = {}) => {
    if (!allowSocketEvent(socket, 'call_diagnostic', 120, 60 * 1000)) return;
    const callId = typeof data.callId === 'string' ? data.callId : '-';
    const event = typeof data.event === 'string' ? data.event.slice(0, 40) : 'unknown';
    const safe = {
      event,
      state: typeof data.state === 'string' ? data.state.slice(0, 80) : undefined,
      candidateType: typeof data.candidateType === 'string' ? data.candidateType : undefined,
      count: Number.isFinite(data.count) ? data.count : undefined,
      localCandidates: Number.isFinite(data.localCandidates) ? data.localCandidates : undefined,
      remoteCandidates: Number.isFinite(data.remoteCandidates) ? data.remoteCandidates : undefined,
      serverCount: Number.isFinite(data.serverCount) ? data.serverCount : undefined,
      hasTurn: typeof data.hasTurn === 'boolean' ? data.hasTurn : undefined,
    };
    console.info(`[CALL_DIAG] call=${callId} user=${socket.user.id} ${JSON.stringify(safe)}`);
  });

  socket.on('call:end', ({ callId, reason } = {}) => {
    const call = activeVoiceCalls.get(callId);
    if (!call || (call.callerId !== socket.user.id && call.calleeId !== socket.user.id)) return;
    const safeReason = reason === 'connection_failed' ? reason : 'ended';
    console.info(`[CALL] end call=${callId} by=${socket.user.id} reason=${safeReason}`);
    finishVoiceCall(callId, socket.user.id, safeReason);
  });

  socket.on('call:client-ready', () => {
    socket.emit('call:ready');
    const callId = userVoiceCalls.get(socket.user.id);
    const call = callId ? activeVoiceCalls.get(callId) : null;
    if (call && call.calleeId === socket.user.id) {
      io.to(socket.id).emit('call:incoming', {
        callId,
        fromUserId: call.callerId,
        fromName: call.callerName || 'משתמש',
      });
    }
  });

  socket.emit('call:ready');

  // Messages waiting for this user are now delivered to a connected device.
  try {
    const pool = await getPool();
    const pending = await pool.query(
      `SELECT m.id, m.sender_id FROM messages m
       LEFT JOIN message_status ms
         ON ms.message_id=m.id AND ms.user_id=$1
       WHERE m.recipient_id=$1 AND m.deleted_for_everyone=FALSE
         AND (ms.status IS NULL OR ms.status='sent')`, [socket.user.id]);
    for (const message of pending.rows) {
      await pool.query(
        `INSERT INTO message_status (message_id, user_id, status)
         VALUES ($1, $2, 'delivered')
         ON CONFLICT (message_id, user_id) DO UPDATE SET status='delivered', updated_at=now()
         WHERE message_status.status != 'read'`,
        [message.id, socket.user.id]);
    }
    for (const senderId of new Set(pending.rows.map(row => row.sender_id))) {
      const senderSid = onlineUsers.get(senderId);
      if (senderSid) io.to(senderSid).emit('messages:delivered', { by: socket.user.id });
    }
  } catch (e) {
    console.error('mark delivered on connect:', e.message);
  }

  // Join all group rooms this user belongs to
  try {
    const pool = await getPool();
    const grps = await pool.query(
      "SELECT group_id FROM group_members WHERE user_id = $1 AND status = 'member'", [socket.user.id]);
    for (const { group_id } of grps.rows) socket.join(`group:${group_id}`);
  } catch (_) {}

  function relay(toUserId, event, data) {
    const sid = onlineUsers.get(toUserId);
    if (sid) io.to(sid).emit(event, data);
  }

  socket.on('chat:message', async ({ toUserId, text, replyToId, fileUrl, fileName, fileType }) => {
    if (!toUserId || (!text && !fileUrl)) return;
    if (!allowSocketEvent(socket, 'message', 120, 60 * 1000)) return;
    if (text && moderateChatText(text).blocked) {
      recordBlockedChat(socket.user.id, 'private_socket', text, toUserId,
        socket.handshake.address);
      socket.emit('message:rejected', { toUserId,
        reason: 'ההודעה נחסמה משום שהיא כוללת תוכן פוגעני או אסור' });
      return;
    }
    try {
      const pool = await getPool();
      // Check if blocked
      const blocked = await pool.query(
        'SELECT 1 FROM blocked_users WHERE blocker_id=$1 AND blocked_id=$2', [toUserId, socket.user.id]);
      if (blocked.rows.length) return;
      const msgType = (() => {
        if (fileType && fileType !== 'text') return fileType;
        if (fileUrl && fileName && /\.(jpg|jpeg|png|gif|webp)$/i.test(fileName)) return 'image';
        if (fileUrl && fileName && /\.(pdf|docx?)$/i.test(fileName)) return 'document';
        return 'text';
      })();
      if (fileUrl && !await validateApprovedFile(
          pool, socket.user.id, fileUrl, 'chat', toUserId)) {
        socket.emit('message:rejected', { toUserId,
          reason: 'הקובץ לא עבר סריקה ואישור עבור נמען זה' });
        return;
      }
      const accepted = await pool.query(
        'SELECT 1 FROM user_contacts WHERE owner_id=$1 AND contact_id=$2',
        [toUserId, socket.user.id]);
      if (!accepted.rows.length) {
        if (msgType !== 'text' || fileUrl) {
          socket.emit('message:rejected', { toUserId, reason: 'מי שאינו חבר יכול לשלוח בקשת טקסט בלבד' });
          return;
        }
        const request = await pool.query(
          `INSERT INTO message_requests
             (sender_id, recipient_id, body, type, file_url, file_name)
           VALUES ($1,$2,$3,$4,$5,$6)
           ON CONFLICT(sender_id, recipient_id) DO UPDATE SET
             body=EXCLUDED.body, type=EXCLUDED.type, file_url=EXCLUDED.file_url,
             file_name=EXCLUDED.file_name, created_at=now()
           RETURNING id, created_at`,
          [socket.user.id, toUserId, text || null, msgType,
           fileUrl || null, fileName || null]);
        relay(toUserId, 'message:request', {
          id: request.rows[0].id, senderId: socket.user.id,
          senderName: socket.user.name, text, fileName,
          createdAt: request.rows[0].created_at,
        });
        sendPush(toUserId, 'בקשת הודעה חדשה',
          `${socket.user.name} רוצה לשלוח לך הודעה`,
          { type: 'message_request', senderId: socket.user.id });
        socket.emit('message:request-pending', { toUserId });
        return;
      }
      if (msgType === 'text' && !fileUrl) {
        const policy = await getEffectiveRecipientFilter(pool, toUserId, socket.user.id);
        if (policy && !policy.filter.text) {
          socket.emit('message:rejected', { toUserId, reason: 'הודעות טקסט חסומות בהגדרות הנמען' });
          return;
        }
      }
      const saved = await pool.query(
        `INSERT INTO messages (sender_id, recipient_id, body, type, file_url, file_name, reply_to_id)
         VALUES ($1, $2, $3, $4, $5, $6, $7)
         RETURNING id, created_at`,
        [socket.user.id, toUserId, text || null, msgType, fileUrl || null, fileName || null, replyToId || null]);
      const row = saved.rows[0];
      if (onlineUsers.has(toUserId)) {
        await pool.query(
          `INSERT INTO message_status (message_id, user_id, status)
           VALUES ($1, $2, 'delivered')
           ON CONFLICT (message_id, user_id) DO UPDATE SET status='delivered', updated_at=now()
           WHERE message_status.status != 'read'`, [row.id, toUserId]);
        socket.emit('message:delivered', { id: row.id });
      }
      relay(toUserId, 'chat:message', {
        id: row.id, fromUserId: socket.user.id, fromName: socket.user.name,
        text, replyToId: replyToId || null, createdAt: row.created_at,
        fileUrl, fileName, fileType,
      });
      // שליפת שם הנמען לרישום קריא בפעילות
      const recip = await pool.query('SELECT name FROM users WHERE id=$1', [toUserId]);
      const toName = recip.rows[0]?.name || toUserId;
      logActivity(socket.user.id, fileUrl ? 'send_file' : 'send_message',
        { to: toName, toUserId, messageId: row.id, type: fileType || 'text', fileName: fileName || null });
      const pushBody = fileUrl ? `📎 ${fileName || 'קובץ'}` : (text || '');
      sendPush(toUserId, socket.user.name, pushBody,
        { type: 'chat', fromUserId: socket.user.id });
    } catch (e) {
      console.error('chat:message save:', e.message);
      relay(toUserId, 'chat:message', { fromUserId: socket.user.id, fromName: socket.user.name, text });
    }
  });

  socket.on('chat:typing', ({ toUserId }) => {
    if (!allowSocketEvent(socket, 'typing', 180, 60 * 1000)) return;
    relay(toUserId, 'chat:typing', { fromUserId: socket.user.id });
  });

  // ── Group messaging ──────────────────────────────────────────────
  socket.on('group:message', async ({ groupId, text, replyToId, fileUrl, fileName, fileType, clientMessageId }) => {
    if ((!text && !fileUrl) || !groupId) return;
    if (!allowSocketEvent(socket, 'message', 120, 60 * 1000)) return;
    if (text && moderateChatText(text).blocked) {
      recordBlockedChat(socket.user.id, 'group_socket', text, groupId,
        socket.handshake.address);
      socket.emit('message:rejected', { groupId, clientMessageId,
        reason: 'ההודעה נחסמה משום שהיא כוללת תוכן פוגעני או אסור' });
      return;
    }
    try {
      const pool = await getPool();
      const mem = await pool.query(
        `SELECT gm.role, g.send_permission FROM group_members gm
         JOIN groups g ON g.id = gm.group_id
         WHERE gm.group_id = $1 AND gm.user_id = $2 AND gm.status='member'`,
        [groupId, socket.user.id]);
      const member = mem.rows[0];
      if (!member) return;
      if (member.send_permission === 'admin' && member.role !== 'admin') return;

      const msgType = fileType && fileType !== 'text'
        ? fileType
        : (fileUrl && fileName && /\.(jpg|jpeg|png|gif|webp)$/i.test(fileName) ? 'image'
          : fileUrl ? 'document' : 'text');

      if (fileUrl && !await validateApprovedFile(
          pool, socket.user.id, fileUrl, 'group', groupId)) {
        socket.emit('message:rejected', { groupId,
          reason: 'הקובץ לא עבר סריקה ואישור עבור קבוצה זו' });
        return;
      }

      const saved = await pool.query(
        `INSERT INTO messages (sender_id, group_id, body, type, file_url, file_name, reply_to_id)
         VALUES ($1, $2, $3, $4, $5, $6, $7)
         RETURNING id, created_at`,
        [socket.user.id, groupId, text || null, msgType, fileUrl || null, fileName || null, replyToId || null]);
      const row = saved.rows[0];
      const outgoingGroupMessage = {
        id:         row.id,
        groupId,
        fromUserId: socket.user.id,
        fromName:   socket.user.name,
        text,
        fileUrl, fileName, fileType: msgType,
        replyToId:  replyToId || null,
        clientMessageId: clientMessageId || null,
        createdAt:  row.created_at,
      };
      // Always acknowledge the sender directly. This also covers the creator
      // of a brand-new group before their socket has joined the group room.
      socket.emit('group:message', outgoingGroupMessage);
      socket.to(`group:${groupId}`).emit('group:message', outgoingGroupMessage);
      logActivity(socket.user.id, fileUrl ? 'send_file' : 'send_group_message',
        { groupId, messageId: row.id, fileName: fileName || null });
      // Push reaches backgrounded apps as well as fully offline devices.
      const grpName = await pool.query('SELECT name FROM groups WHERE id = $1', [groupId]);
      const groupName = grpName.rows[0]?.name || 'קבוצה';
      const allMembers = await pool.query(
        `SELECT user_id FROM group_members
         WHERE group_id=$1 AND status='member'`, [groupId]);
      const pushBody = fileUrl ? `📎 ${fileName || 'קובץ'}` : (text || '');
      for (const { user_id } of allMembers.rows) {
        if (user_id !== socket.user.id) {
          sendPush(user_id, `${groupName} • ${socket.user.name}`,
            pushBody, { type: 'group', groupId });
        }
      }
    } catch (e) { console.error('group:message:', e.message); }
  });

  socket.on('group:typing', ({ groupId }) => {
    const room = `group:${groupId}`;
    if (!groupId || !socket.rooms.has(room)) return;
    if (!allowSocketEvent(socket, 'typing', 180, 60 * 1000)) return;
    socket.to(room).emit('group:typing', {
      groupId,
      fromUserId: socket.user.id,
      fromName:   socket.user.name,
    });
  });

  socket.on('group:viewed', async ({ groupId }) => {
    if (!groupId) return;
    try {
      const pool = await getPool();
      const updated = await pool.query(
        `UPDATE group_members SET last_viewed_at=now()
         WHERE group_id=$1 AND user_id=$2 AND status='member'
         RETURNING last_viewed_at`,
        [groupId, socket.user.id]);
      if (!updated.rows.length) return;
      socket.join(`group:${groupId}`);
      io.to(`group:${groupId}`).emit('group:viewed', {
        groupId,
        userId: socket.user.id,
        userName: socket.user.name,
        viewedAt: updated.rows[0].last_viewed_at,
      });
    } catch (e) {
      console.error('group:viewed:', e.message);
    }
  });

  socket.on('group:join', async ({ groupId }) => {
    if (!groupId) return;
    try {
      const pool = await getPool();
      const member = await pool.query(
        `SELECT 1 FROM group_members
         WHERE group_id=$1 AND user_id=$2 AND status='member'`,
        [groupId, socket.user.id]);
      if (member.rows.length) socket.join(`group:${groupId}`);
    } catch (e) {
      console.error('group:join:', e.message);
    }
  });

  socket.on('disconnect', () => {
    // A reconnect can establish a replacement socket before the old socket's
    // disconnect callback runs. Never let that stale callback remove the new
    // connection from presence.
    if (onlineUsers.get(socket.user.id) === socket.id) {
      const callId = userVoiceCalls.get(socket.user.id);
      if (callId) finishVoiceCall(callId, socket.user.id, 'disconnected');
      onlineUsers.delete(socket.user.id);
    }
    io.emit('users:online', [...onlineUsers.keys()]);
    logActivity(socket.user.id, 'disconnect', {});
  });

  logActivity(socket.user.id, 'connect', {});
});

// ── Register ─────────────────────────────────────────────────────
app.post('/api/register', authRateLimit, credentialRateLimit, async (req, res) => {
  const { name, password, phone, clientType, verificationMethod, gender } = req.body;
  if (req.body.acceptedTerms !== true || req.body.ageConfirmed !== true)
    return res.status(400).json({ error: 'יש לאשר את תנאי השימוש, מדיניות הפרטיות וגיל 13 ומעלה' });
  // Copying an address from RTL text can add invisible bidi controls. They
  // are formatting characters, not part of an email address.
  const email = typeof req.body.email === 'string'
    ? req.body.email.replace(/[\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]/g, '').trim().toLowerCase()
    : req.body.email;
  if (!name) return res.status(400).json({ error: 'חסר שם' });
  if (!['male', 'female'].includes(gender))
    return res.status(400).json({ error: 'יש לבחור מגדר' });
  const hasEmail = !!(email && password);
  const hasPhone = !!phone;
  const verifyByEmail = verificationMethod !== 'phone';
  const verifyByPhone = verificationMethod === 'phone';
  if (clientType === 'desktop' && (!hasEmail || !hasPhone))
    return res.status(400).json({ error: 'בהרשמה ממחשב חובה להזין אימייל ומספר טלפון' });
  if (!hasEmail && !hasPhone)
    return res.status(400).json({ error: 'יש לספק אימייל עם סיסמה, מספר טלפון, או שניהם' });

  const cleanPhone = hasPhone ? phone.replace(/\D/g, '') : null;
  if (hasPhone && cleanPhone.length < 9)
    return res.status(400).json({ error: 'מספר טלפון לא תקין' });
  try {
    const pool = await getPool();
    if (hasEmail && verifyByEmail) {
      const emailExists = await pool.query('SELECT id FROM users WHERE email = $1', [email]);
      if (emailExists.rows.length) return res.status(400).json({ error: 'האימייל כבר רשום' });
    }
    if (hasPhone && verifyByPhone) {
      const phoneExists = await pool.query('SELECT id FROM users WHERE phone = $1', [cleanPhone]);
      if (phoneExists.rows.length) return res.status(400).json({ error: 'מספר הטלפון כבר רשום' });
    }

    const hash = hasEmail ? await bcrypt.hash(password, 10) : null;
    const result = await pool.query(
      `INSERT INTO users (name, email, phone, password_hash, terms_accepted_at, terms_version, age_confirmed, gender)
       VALUES ($1, $2, $3, $4, now(), '2026-08-18', TRUE, $5)
       RETURNING id, name, email`,
      [name, hasEmail ? email : null, hasPhone ? cleanPhone : null, hash, gender]);
    const user = result.rows[0];

    if (hasEmail) {
      const emailToken = crypto.randomBytes(32).toString('hex');
      const expires24h = new Date(Date.now() + 24 * 60 * 60 * 1000);
      await pool.query(
        'INSERT INTO email_verification_tokens (token, user_id, expires_at) VALUES ($1, $2, $3)',
        [emailToken, user.id, expires24h]);
      const base = process.env.APP_URL || 'https://betshuva.com/betshuva-app';
      sendEmail({
        to: user.email,
        subject: 'אמת את כתובת האימייל שלך – בתשובה',
        html: emailVerificationEmail(user.name, `${base}/verify-email?token=${emailToken}`),
      }).catch(() => {});
    }

    if (hasPhone) {
      const smsCode = Math.floor(100000 + Math.random() * 900000).toString();
      otpStore.set(cleanPhone, { code: smsCode, expires: Date.now() + 10 * 60 * 1000, name });
      sendEmail({
        to: `${cleanPhone}@019sms.co.il`,
        subject: `קוד אימות הטלפון שלך לבתשובה: ${smsCode}`,
        html: '',
      }).catch(() => {});
    }

    logActivity(user.id, 'register', { email: email || null, phone: cleanPhone }, req.ip);
    res.json({ pending: true, phone: cleanPhone, hasEmail, hasPhone,
      verificationMethod: verifyByPhone ? 'phone' : 'email' });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// ── Login ────────────────────────────────────────────────────────
app.post('/api/login', authRateLimit, credentialRateLimit, async (req, res) => {
  const { password } = req.body;
  const email = typeof req.body.email === 'string'
    ? req.body.email.replace(/[\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]/g, '').trim().toLowerCase()
    : req.body.email;
  try {
    const pool = await getPool();
    const result = await pool.query('SELECT * FROM users WHERE email = $1', [email]);
    const user = result.rows[0];
    if (!user || !user.password_hash || !(await bcrypt.compare(password, user.password_hash)))
      return res.status(401).json({ error: 'אימייל או סיסמה שגויים' });
    if (!user.phone) {
      const token = jwt.sign({ id: user.id, name: user.name, email: user.email }, JWT_SECRET);
      return res.status(403).json({ error: 'יש להזין מספר טלפון', code: 'PHONE_REQUIRED', token });
    }
    if (!user.email_verified && !user.phone_verified)
      return res.status(403).json({ error: 'יש לאמת את הטלפון או האימייל תחילה', code: 'VERIFICATION_REQUIRED' });

    const token = jwt.sign({ id: user.id, name: user.name, email: user.email }, JWT_SECRET);
    const { password_hash, ...safeUser } = user;
    logActivity(user.id, 'login', { email: user.email }, req.ip);
    res.json({ token, user: safeUser });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Resend verification after the user has proven the account password.
app.post('/api/resend-verification', authRateLimit, otpRateLimit, async (req, res) => {
  const { password, method } = req.body;
  const email = typeof req.body.email === 'string'
    ? req.body.email.trim().toLowerCase() : '';
  if (!['email', 'phone'].includes(method))
    return res.status(400).json({ error: 'שיטת אימות לא תקינה' });
  try {
    const pool = await getPool();
    const result = await pool.query('SELECT * FROM users WHERE email=$1', [email]);
    const user = result.rows[0];
    if (!user || !user.password_hash || !(await bcrypt.compare(password || '', user.password_hash)))
      return res.status(401).json({ error: 'אימייל או סיסמה שגויים' });

    if (method === 'phone') {
      if (!user.phone) return res.status(400).json({ error: 'לא הוזן מספר טלפון לחשבון' });
      const smsCode = Math.floor(100000 + Math.random() * 900000).toString();
      otpStore.set(user.phone, {
        code: smsCode, expires: Date.now() + 10 * 60 * 1000, name: user.name,
      });
      await sendEmail({
        to: `${user.phone}@019sms.co.il`,
        subject: `קוד אימות הטלפון שלך לבתשובה: ${smsCode}`,
        html: '',
      });
      return res.json({ ok: true, method: 'phone', phone: user.phone });
    }

    const emailToken = crypto.randomBytes(32).toString('hex');
    const expires24h = new Date(Date.now() + 24 * 60 * 60 * 1000);
    await pool.query(
      'INSERT INTO email_verification_tokens (token, user_id, expires_at) VALUES ($1, $2, $3)',
      [emailToken, user.id, expires24h]);
    const base = process.env.APP_URL || 'https://betshuva.com/betshuva-app';
    await sendEmail({
      to: user.email,
      subject: 'אמת את כתובת האימייל שלך – בתשובה',
      html: emailVerificationEmail(user.name, `${base}/verify-email?token=${emailToken}`),
    });
    res.json({ ok: true, method: 'email' });
  } catch (e) {
    console.error('resend-verification:', e.message);
    res.status(500).json({ error: 'שליחת האימות נכשלה' });
  }
});

// ── Google Sign-In ────────────────────────────────────────────────
app.post('/api/auth/google', authRateLimit, async (req, res) => {
  const { idToken } = req.body;
  if (!idToken) return res.status(400).json({ error: 'חסר idToken' });
  try {
    const tokenRes = await fetch(`https://oauth2.googleapis.com/tokeninfo?id_token=${encodeURIComponent(idToken)}`);
    const payload  = await tokenRes.json();
    console.log(`[GOOGLE] tokeninfo — email:${payload.email} sub:${payload.sub} aud:${payload.aud} err:${payload.error_description||'-'}`);
    if (payload.error_description || !payload.sub)
      return res.status(401).json({ error: 'טוקן גוגל לא תקין' });

    // Google issues the web client audience in browsers and may issue one of
    // the Android OAuth client audiences in the native app. Accept only client
    // IDs that belong to this Firebase/Google Cloud project.
    const configuredClientIds = (process.env.GOOGLE_CLIENT_IDS || process.env.GOOGLE_CLIENT_ID || '')
      .split(',')
      .map(value => value.trim())
      .filter(Boolean);
    const googleClientIds = new Set([
      ...configuredClientIds,
      '862738339788-0o8jv308efqdhb0q21eo9ut74oqcff80.apps.googleusercontent.com',
      '862738339788-4ogau0m9c0nh2h8jh7k6fosj2i3tah28.apps.googleusercontent.com',
      '862738339788-umebs5qrpaaikhdr3uuu259hufc65l98.apps.googleusercontent.com',
    ]);
    if (!googleClientIds.has(payload.aud)) {
      console.warn(`[GOOGLE] rejected audience: ${payload.aud || '-'}`);
      return res.status(401).json({ error: 'Client ID לא תואם' });
    }
    if (payload.email_verified !== 'true' && payload.email_verified !== true)
      return res.status(401).json({ error: 'חשבון Google ללא אימייל מאומת' });

    const { sub: googleId, email, name, picture } = payload;
    const pool = await getPool();

    // 1. Find by google_id
    let byGoogle = await pool.query('SELECT * FROM users WHERE google_id = $1', [googleId]);

    if (byGoogle.rows.length) {
      const user  = byGoogle.rows[0];
      console.log(`[GOOGLE] login by google_id — user:${user.name} email:${user.email}`);
      const token = jwt.sign({ id: user.id, name: user.name, email: user.email }, JWT_SECRET);
      logActivity(user.id, 'google_login', { email: user.email }, req.ip);
      const { password_hash, ...safeUser } = user;
      return res.json({ token, user: safeUser });
    }

    // 2. Find by email — link google_id
    if (email) {
      const byEmail = await pool.query(
        'SELECT * FROM users WHERE lower(email) = lower($1) ORDER BY email_verified DESC LIMIT 1',
        [email]);
      if (byEmail.rows.length) {
        const user = byEmail.rows[0];
        await pool.query(
          `UPDATE users
           SET google_id=$1, email_verified=TRUE,
               profile_pic_url=COALESCE(profile_pic_url, $2)
           WHERE id=$3`,
          [googleId, picture || null, user.id]);
        const token = jwt.sign({ id: user.id, name: user.name, email: user.email }, JWT_SECRET);
        logActivity(user.id, 'google_login', { email: user.email }, req.ip);
        const { password_hash, ...safeUser } = user;
        return res.json({ token, user: safeUser });
      }
    }

    // 3. Create new user
    if (req.body.acceptedTerms !== true || req.body.ageConfirmed !== true)
      return res.status(400).json({ error: 'ליצירת חשבון חדש יש לעבור למסך הרשמה ולאשר תנאים וגיל 13 ומעלה' });
    if (!['male', 'female'].includes(req.body.gender))
      return res.status(400).json({ error: 'יש לבחור מגדר בהרשמה' });
    console.log(`[GOOGLE] new user — name:${name} email:${email}`);
    const inserted = await pool.query(
      `INSERT INTO users (name, email, email_verified, google_id, profile_pic_url,
                          terms_accepted_at, terms_version, age_confirmed, gender)
       VALUES ($1, $2, TRUE, $3, $4, now(), '2026-08-18', TRUE, $5)
       RETURNING *`,
      [name || (email ? email.split('@')[0] : 'משתמש'), email || null, googleId, picture || null,
       req.body.gender]);
    const user  = inserted.rows[0];
    const token = jwt.sign({ id: user.id, name: user.name, email: user.email }, JWT_SECRET);
    logActivity(user.id, 'google_register', { email: user.email }, req.ip);
    // הודע לכל המחוברים על משתמש חדש
    req.app.get('io').emit('users:new', {
      id: user.id, name: user.name, email: user.email, profile_pic_url: user.profile_pic_url || null
    });
    const { password_hash, ...safeUser } = user;
    res.json({ token, user: safeUser });
  } catch (e) {
    console.error(`[GOOGLE] ERROR — ${e.message}`);
    res.status(500).json({ error: e.message });
  }
});

// ── Users ─────────────────────────────────────────────────────────
app.get('/api/users', authWithDbCheck, async (req, res) => {
  try {
    const pool = await getPool();
    const result = await pool.query(
      `SELECT u.id, u.name, u.profile_pic_url, u.city, u.phone, u.email,
              c.filter_override, c.pinned_at,
              last_msg.body AS last_message,
              last_msg.type AS last_message_type,
              last_msg.created_at AS last_message_at,
              (last_msg.sender_id = $1) AS last_message_is_mine,
              last_msg.status AS last_message_status
       FROM user_contacts c
       JOIN users u ON u.id = c.contact_id
       LEFT JOIN LATERAL (
         SELECT m.body, m.type, m.created_at, m.sender_id, ms.status
         FROM messages m
         LEFT JOIN message_status ms ON ms.message_id=m.id
           AND ms.user_id=CASE WHEN m.sender_id=$1 THEN u.id ELSE $1 END
         WHERE ((m.sender_id = $1 AND m.recipient_id = u.id)
             OR (m.sender_id = u.id AND m.recipient_id = $1))
           AND m.group_id IS NULL
           AND m.deleted_for_everyone = FALSE
           AND NOT (m.sender_id = $1 AND m.deleted_for_sender = TRUE)
         ORDER BY m.created_at DESC
         LIMIT 1
       ) last_msg ON TRUE
       WHERE c.owner_id = $1
       AND u.id <> $2
       AND u.id NOT IN (
         SELECT blocked_id FROM blocked_users WHERE blocker_id = $1
       )
       ORDER BY c.pinned_at DESC NULLS LAST,
                last_msg.created_at DESC NULLS LAST, u.name`,
      [req.user.id, SCAN_BOT_ID]);
    res.json(result.rows);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

app.get('/api/users/directory', authWithDbCheck, async (req, res) => {
  try {
    const pool = await getPool();
    const result = await pool.query(
      `SELECT id, name, profile_pic_url, city, phone, email
       FROM users WHERE id != $1 AND id != $2
       AND (email_verified = TRUE OR phone_verified = TRUE)
       AND id NOT IN (SELECT blocked_id FROM blocked_users WHERE blocker_id=$1)
       ORDER BY name`, [req.user.id, SCAN_BOT_ID]);
    res.json(result.rows);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.get('/api/users/search', authWithDbCheck, searchRateLimit, async (req, res) => {
  const q = String(req.query.q || '').trim();
  if (!q) return res.json([]);
  try {
    const pool = await getPool();
    const digits = q.replace(/\D/g, '');
    const result = await pool.query(
      `SELECT u.id, u.name, u.email, u.phone, u.profile_pic_url, u.city,
              EXISTS(SELECT 1 FROM user_contacts c
                     WHERE c.owner_id=$1 AND c.contact_id=u.id) AS saved
       FROM users u
       WHERE u.id != $1
         AND u.id != $5
         AND (u.email_verified = TRUE OR u.phone_verified = TRUE)
         AND u.id NOT IN (SELECT blocked_id FROM blocked_users WHERE blocker_id=$1)
         AND (u.name ILIKE $2 OR u.email ILIKE $2 OR ($3 <> '' AND u.phone LIKE $4))
       ORDER BY u.name LIMIT 30`,
      [req.user.id, `%${q}%`, digits, `%${digits}%`, SCAN_BOT_ID]);
    res.json(result.rows);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.post('/api/contacts/save/:userId', authWithDbCheck, async (req, res) => {
  if (req.params.userId === req.user.id)
    return res.status(400).json({ error: 'לא ניתן לשמור את עצמך' });
  if (req.params.userId === SCAN_BOT_ID)
    return res.status(404).json({ error: 'משתמש לא נמצא' });
  try {
    const pool = await getPool();
    const exists = await pool.query(
      'SELECT 1 FROM users WHERE id=$1 AND (email_verified=TRUE OR phone_verified=TRUE)',
      [req.params.userId]);
    if (!exists.rows.length) return res.status(404).json({ error: 'משתמש לא נמצא' });
    await pool.query(
      `INSERT INTO user_contacts(owner_id, contact_id) VALUES($1,$2)
       ON CONFLICT DO NOTHING`, [req.user.id, req.params.userId]);
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.put('/api/pins/:type/:targetId', authWithDbCheck, async (req, res) => {
  const pinnedAt = req.body.pinned === true ? new Date() : null;
  try {
    const pool = await getPool();
    let result;
    if (req.params.type === 'chat') {
      result = await pool.query(
        `UPDATE user_contacts SET pinned_at=$1
         WHERE owner_id=$2 AND contact_id=$3 RETURNING pinned_at`,
        [pinnedAt, req.user.id, req.params.targetId]);
    } else if (req.params.type === 'group') {
      result = await pool.query(
        `UPDATE group_members SET pinned_at=$1
         WHERE user_id=$2 AND group_id=$3 AND status='member' RETURNING pinned_at`,
        [pinnedAt, req.user.id, req.params.targetId]);
    } else {
      return res.status(400).json({ error: 'סוג הצמדה לא תקין' });
    }
    if (!result.rows.length)
      return res.status(404).json({ error: 'השיחה לא נמצאה' });
    res.json({ pinned_at: result.rows[0].pinned_at });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// ── Per-user and per-contact content filters ─────────────────────
app.get('/api/filter-settings', authWithDbCheck, async (req, res) => {
  try {
    const pool = await getPool();
    const result = await pool.query('SELECT content_filter FROM users WHERE id=$1', [req.user.id]);
    res.json(normalizeContentFilter(result.rows[0]?.content_filter));
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.put('/api/filter-settings', authWithDbCheck, async (req, res) => {
  try {
    const filter = normalizeContentFilter(req.body);
    const pool = await getPool();
    await pool.query('UPDATE users SET content_filter=$1 WHERE id=$2', [JSON.stringify(filter), req.user.id]);
    res.json(filter);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.get('/api/contacts/:userId/filter-settings', authWithDbCheck, async (req, res) => {
  try {
    const pool = await getPool();
    const result = await pool.query(
      `SELECT c.filter_override, u.content_filter AS owner_filter
       FROM user_contacts c JOIN users u ON u.id=c.owner_id
       WHERE c.owner_id=$1 AND c.contact_id=$2`,
      [req.user.id, req.params.userId]);
    if (!result.rows.length) return res.status(404).json({ error: 'איש הקשר לא נמצא' });
    const inherited = normalizeContentFilter(result.rows[0].owner_filter);
    const override = result.rows[0].filter_override;
    res.json({ inherited: !override, filter: normalizeContentFilter(override, inherited) });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.put('/api/contacts/:userId/filter-settings', authWithDbCheck, async (req, res) => {
  try {
    const pool = await getPool();
    if (req.body?.inherit === true) {
      const result = await pool.query(
        'UPDATE user_contacts SET filter_override=NULL WHERE owner_id=$1 AND contact_id=$2 RETURNING owner_id',
        [req.user.id, req.params.userId]);
      if (!result.rows.length) return res.status(404).json({ error: 'איש הקשר לא נמצא' });
      return res.json({ inherited: true });
    }
    const filter = normalizeContentFilter(req.body?.filter || req.body);
    const result = await pool.query(
      'UPDATE user_contacts SET filter_override=$1 WHERE owner_id=$2 AND contact_id=$3 RETURNING owner_id',
      [JSON.stringify(filter), req.user.id, req.params.userId]);
    if (!result.rows.length) return res.status(404).json({ error: 'איש הקשר לא נמצא' });
    res.json({ inherited: false, filter });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Contacts: match phone numbers with registered users ───────────
app.post('/api/contacts/match', auth, async (req, res) => {
  const phones = Array.isArray(req.body.phones) ? req.body.phones : [];
  const emails = Array.isArray(req.body.emails) ? req.body.emails : [];

  // Normalize: keep digits only, handle Israeli prefix (972 → 0)
  const normalize = (p) => {
    let d = p.replace(/\D/g, '');
    if (d.startsWith('972') && d.length > 10) d = '0' + d.slice(3);
    return d;
  };
  const normalized = [...new Set(phones.map(normalize).filter(Boolean))];
  const normalizedEmails = [...new Set(emails.map(e => String(e).trim().toLowerCase()).filter(e => e.includes('@')))];
  if (normalized.length === 0 && normalizedEmails.length === 0) return res.json([]);

  try {
    const pool = await getPool();
    const result = await pool.query(
      `SELECT id, name, profile_pic_url, phone, email
       FROM users
       WHERE (phone = ANY($2::text[]) OR lower(email) = ANY($3::text[]))
         AND (email_verified = TRUE OR phone_verified = TRUE)
         AND id != $1
         AND id NOT IN (SELECT blocked_id FROM blocked_users WHERE blocker_id = $1)`,
      [req.user.id, normalized, normalizedEmails]
    );
    res.json(result.rows);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Messages: unread counts per sender ───────────────────────────
app.get('/api/messages/unread', auth, async (req, res) => {
  try {
    const pool = await getPool();
    const result = await pool.query(`
      SELECT m.sender_id AS "senderId", COUNT(*)::int AS cnt
      FROM messages m
      LEFT JOIN message_status ms
        ON ms.message_id = m.id AND ms.user_id = $1
      WHERE m.recipient_id = $1
        AND m.deleted_for_everyone = FALSE
        AND (ms.status IS NULL OR ms.status != 'read')
      GROUP BY m.sender_id
    `, [req.user.id]);
    const counts = {};
    for (const row of result.rows) counts[row.senderId] = row.cnt;
    res.json(counts);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// ── Group messages: unread counts ────────────────────────────────
app.get('/api/groups/unread', auth, async (req, res) => {
  try {
    const pool = await getPool();
    const result = await pool.query(`
      SELECT m.group_id, COUNT(*)::int AS cnt
      FROM messages m
      JOIN group_members gm
        ON gm.group_id=m.group_id AND gm.user_id=$1 AND gm.status='member'
      LEFT JOIN message_status ms
        ON ms.message_id=m.id AND ms.user_id=$1
      WHERE m.group_id IS NOT NULL
        AND m.sender_id != $1
        AND m.created_at >= gm.joined_at
        AND (ms.status IS NULL OR ms.status != 'read')
      GROUP BY m.group_id
    `, [req.user.id]);
    const counts = {};
    for (const row of result.rows) counts[row.group_id] = row.cnt;
    res.json(counts);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.put('/api/groups/:id/read', auth, async (req, res) => {
  try {
    const pool = await getPool();
    await pool.query(`
      INSERT INTO message_status (message_id, user_id, status)
      SELECT m.id, $1, 'read' FROM messages m
      WHERE m.group_id=$2 AND m.sender_id != $1
        AND m.created_at >= (
          SELECT gm.joined_at FROM group_members gm
          WHERE gm.group_id=$2 AND gm.user_id=$1
        )
      ON CONFLICT (message_id, user_id) DO UPDATE SET status='read'
    `, [req.user.id, req.params.id]);
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Messages: load history ─────────────────────────────────────────
app.get('/api/messages/:userId', auth, async (req, res) => {
  const otherId = req.params.userId;
  const myId    = req.user.id;
  const before  = req.query.before; // ISO date for pagination
  try {
    const pool = await getPool();
    const params = [myId, otherId];
    if (before) params.push(new Date(before));

    const result = await pool.query(`
      SELECT
        m.id, m.sender_id, m.recipient_id, m.type,
        m.body, m.file_url, m.file_name, m.file_size,
        m.reply_to_id, m.created_at,
        r.body        AS reply_body,
        ru.name       AS reply_sender_name,
        CASE WHEN ms.status = 'read' THEN 1 ELSE 0 END AS is_read,
        ms.status AS message_status
      FROM messages m
      LEFT JOIN messages r  ON m.reply_to_id = r.id
      LEFT JOIN users ru    ON r.sender_id = ru.id
      LEFT JOIN message_status ms ON ms.message_id = m.id
        AND ms.user_id = CASE WHEN m.sender_id=$1 THEN $2 ELSE $1 END
      WHERE m.deleted_for_everyone = FALSE
        AND (
          (m.sender_id = $1 AND m.recipient_id = $2 AND m.deleted_for_sender = FALSE)
          OR
          (m.sender_id = $2 AND m.recipient_id = $1)
        )
        ${before ? 'AND m.created_at < $3' : ''}
      ORDER BY m.created_at DESC
      LIMIT 50
    `, params);
    // Pending/rejected uploads are visible only to their sender. They are not
    // messages yet, but must survive refresh so a scanned image never appears
    // to vanish from the sender's conversation.
    const scanParams = [myId, otherId];
    if (before) scanParams.push(new Date(before));
    const scans = await pool.query(`
      SELECT
        'scan_' || sf.id::text AS id,
        sf.user_id AS sender_id,
        sf.context_id AS recipient_id,
        sf.file_type AS type,
        sf.original_name AS body,
        sf.public_url AS file_url,
        sf.original_name AS file_name,
        sf.file_size,
        sf.created_at,
        sf.moderation_status = 'rejected' AS scan_rejected,
        sf.moderation_details->>'reason' AS scan_reason,
        CASE WHEN sf.moderation_status='rejected'
          THEN 'rejected_scan' ELSE 'pending_scan' END AS message_status
      FROM stored_files sf
      WHERE sf.user_id=$1 AND sf.context_type='chat' AND sf.context_id=$2
        AND sf.moderation_status IN ('pending','rejected')
        ${before ? 'AND sf.created_at < $3' : ''}
      ORDER BY sf.created_at DESC
      LIMIT 50
    `, scanParams);
    const combined = [...result.rows, ...scans.rows]
      .sort((a, b) => new Date(a.created_at) - new Date(b.created_at))
      .slice(-50);
    res.json(combined);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// ── Messages: send (HTTP fallback / always-on path) ───────────────
// משכפל את הלוגיקה של ה-socket handler 'chat:message', כדי שהודעות
// יישמרו גם כש-socket לא מחובר (למשל כשפותחים צ'אט ממסך מודעה).
app.post('/api/messages', auth, messageRateLimit, async (req, res) => {
  const senderId = req.user.id;
  const { toUserId, text, replyToId, fileUrl, fileName, fileType } = req.body || {};
  if (!toUserId || (!text && !fileUrl)) {
    return res.status(400).json({ error: 'חסר נמען או תוכן' });
  }
  if (text && moderateChatText(text).blocked) {
    recordBlockedChat(senderId, 'private_http', text, toUserId, clientIp(req));
    return res.status(422).json({
      error: 'ההודעה נחסמה משום שהיא כוללת תוכן פוגעני או אסור',
      code: 'CHAT_CONTENT_BLOCKED',
    });
  }
  try {
    const pool = await getPool();
    const blocked = await pool.query(
      'SELECT 1 FROM blocked_users WHERE blocker_id=$1 AND blocked_id=$2', [toUserId, senderId]);
    if (blocked.rows.length) return res.status(403).json({ error: 'נחסמת על ידי הנמען' });

    const type = (() => {
      if (fileType && fileType !== 'text') return fileType;
      if (fileUrl && fileName && /\.(jpg|jpeg|png|gif|webp)$/i.test(fileName)) return 'image';
      if (fileUrl && fileName && /\.(pdf|docx?)$/i.test(fileName)) return 'document';
      return 'text';
    })();
    if (fileUrl && !await validateApprovedFile(
        pool, senderId, fileUrl, 'chat', toUserId)) {
      return res.status(403).json({ error: 'הקובץ לא עבר סריקה ואישור עבור נמען זה' });
    }

    const accepted = await pool.query(
      'SELECT 1 FROM user_contacts WHERE owner_id=$1 AND contact_id=$2',
      [toUserId, senderId]);
    if (!accepted.rows.length) {
      if (type !== 'text' || fileUrl)
        return res.status(403).json({ error: 'מי שאינו חבר יכול לשלוח בקשת טקסט בלבד' });
      const request = await pool.query(
        `INSERT INTO message_requests
           (sender_id, recipient_id, body, type, file_url, file_name)
         VALUES ($1,$2,$3,$4,$5,$6)
         ON CONFLICT(sender_id, recipient_id) DO UPDATE SET
           body=EXCLUDED.body, type=EXCLUDED.type, file_url=EXCLUDED.file_url,
           file_name=EXCLUDED.file_name, created_at=now()
         RETURNING id, created_at`,
        [senderId, toUserId, text || null, type, fileUrl || null, fileName || null]);
      const requestRow = request.rows[0];
      const sid = onlineUsers.get(toUserId);
      if (sid) io.to(sid).emit('message:request', {
        id: requestRow.id, senderId, senderName: req.user.name,
        text, fileName, createdAt: requestRow.created_at,
      });
      sendPush(toUserId, 'בקשת הודעה חדשה',
        `${req.user.name} רוצה לשלוח לך הודעה`,
        { type: 'message_request', senderId });
      return res.json({ requestPending: true, id: requestRow.id });
    }

    if (type === 'text' && !fileUrl) {
      const policy = await getEffectiveRecipientFilter(pool, toUserId, senderId);
      if (policy && !policy.filter.text)
        return res.status(403).json({ error: 'הודעות טקסט חסומות בהגדרות הנמען' });
    }

    const saved = await pool.query(
      `INSERT INTO messages (sender_id, recipient_id, body, type, file_url, file_name, reply_to_id)
       VALUES ($1, $2, $3, $4, $5, $6, $7)
       RETURNING id, created_at`,
      [senderId, toUserId, text || null, type, fileUrl || null, fileName || null, replyToId || null]);
    const row = saved.rows[0];

    // אם יש תגובה, נשלח גם את טקסט ההודעה הקודמת
    let replyBody = null;
    if (replyToId) {
      const replyMsg = await pool.query('SELECT body FROM messages WHERE id = $1', [replyToId]);
      replyBody = replyMsg.rows[0]?.body || '';
    }

    const sid = onlineUsers.get(toUserId);
    if (sid) {
      await pool.query(
        `INSERT INTO message_status (message_id, user_id, status)
         VALUES ($1, $2, 'delivered')
         ON CONFLICT (message_id, user_id) DO UPDATE SET status='delivered', updated_at=now()
         WHERE message_status.status != 'read'`, [row.id, toUserId]);
      io.to(sid).emit('chat:message', {
        id: row.id, fromUserId: senderId, fromName: req.user.name,
        text, replyToId: replyToId || null, replyBody, createdAt: row.created_at,
        fileUrl, fileName, fileType: type,
      });
    }

    const recip = await pool.query('SELECT name FROM users WHERE id=$1', [toUserId]);
    const toName = recip.rows[0]?.name || toUserId;
    logActivity(senderId, fileUrl ? 'send_file' : 'send_message',
      { to: toName, toUserId, messageId: row.id, type, fileName: fileName || null });

    const pushBody = fileUrl ? `📎 ${fileName || 'קובץ'}` : (text || '');
    sendPush(toUserId, req.user.name, pushBody,
      { type: 'chat', fromUserId: senderId });

    res.json({ id: row.id, createdAt: row.created_at,
      status: sid ? 'delivered' : 'sent' });
  } catch (e) {
    console.error('POST /api/messages:', e.message);
    res.status(500).json({ error: e.message });
  }
});

app.get('/api/message-requests', authWithDbCheck, async (req, res) => {
  try {
    const pool = await getPool();
    const result = await pool.query(
      `SELECT mr.id, mr.sender_id, u.name AS sender_name,
              u.profile_pic_url, mr.body, mr.type, mr.file_url,
              mr.file_name, mr.created_at
       FROM message_requests mr
       JOIN users u ON u.id=mr.sender_id
       WHERE mr.recipient_id=$1
       ORDER BY mr.created_at`, [req.user.id]);
    res.json(result.rows);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.post('/api/message-requests/:id/accept', authWithDbCheck, async (req, res) => {
  const pool = await getPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const found = await client.query(
      `SELECT * FROM message_requests WHERE id=$1 AND recipient_id=$2 FOR UPDATE`,
      [req.params.id, req.user.id]);
    if (!found.rows.length) {
      await client.query('ROLLBACK');
      return res.status(404).json({ error: 'הבקשה לא נמצאה' });
    }
    const request = found.rows[0];
    await client.query(
      `INSERT INTO user_contacts(owner_id, contact_id) VALUES($1,$2),($2,$1)
       ON CONFLICT DO NOTHING`, [req.user.id, request.sender_id]);
    const saved = await client.query(
      `INSERT INTO messages(sender_id, recipient_id, body, type, file_url, file_name)
       VALUES($1,$2,$3,$4,$5,$6) RETURNING id, created_at`,
      [request.sender_id, req.user.id, request.body, request.type,
       request.file_url, request.file_name]);
    await client.query('DELETE FROM message_requests WHERE id=$1', [request.id]);
    await client.query('COMMIT');
    const row = saved.rows[0];
    const payload = {
      id: row.id, fromUserId: request.sender_id,
      text: request.body, createdAt: row.created_at,
      fileUrl: request.file_url, fileName: request.file_name,
      fileType: request.type,
    };
    const recipientSid = onlineUsers.get(req.user.id);
    if (recipientSid) io.to(recipientSid).emit('chat:message', payload);
    const senderSid = onlineUsers.get(request.sender_id);
    if (senderSid) io.to(senderSid).emit('message:request-accepted', {
      byUserId: req.user.id, messageId: row.id,
    });
    res.json({ ok: true, messageId: row.id });
  } catch (e) {
    await client.query('ROLLBACK');
    res.status(500).json({ error: e.message });
  } finally { client.release(); }
});

app.delete('/api/message-requests/:id', authWithDbCheck, async (req, res) => {
  try {
    const pool = await getPool();
    const result = await pool.query(
      'DELETE FROM message_requests WHERE id=$1 AND recipient_id=$2 RETURNING sender_id',
      [req.params.id, req.user.id]);
    if (!result.rows.length) return res.status(404).json({ error: 'הבקשה לא נמצאה' });
    const senderSid = onlineUsers.get(result.rows[0].sender_id);
    if (senderSid) io.to(senderSid).emit('message:request-declined', {
      byUserId: req.user.id,
    });
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Messages: mark as read ─────────────────────────────────────────
app.put('/api/messages/read', auth, async (req, res) => {
  const { senderId } = req.body;
  if (!senderId) return res.status(400).json({ error: 'חסר senderId' });
  try {
    const pool = await getPool();
    const msgs = await pool.query(
      `SELECT id FROM messages
       WHERE recipient_id = $1 AND sender_id = $2
       AND deleted_for_everyone = FALSE`, [req.user.id, senderId]);

    for (const { id } of msgs.rows) {
      await pool.query(
        `INSERT INTO message_status (message_id, user_id, status) VALUES ($1, $2, 'read')
         ON CONFLICT (message_id, user_id) DO UPDATE SET status='read', updated_at=now()`,
        [id, req.user.id]);
    }

    const sid = onlineUsers.get(senderId);
    if (sid) io.to(sid).emit('messages:read', { by: req.user.id });
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// ── Messages: delete ──────────────────────────────────────────────
app.delete('/api/messages/:id', auth, async (req, res) => {
  const { forEveryone } = req.body;
  try {
    const pool = await getPool();
    const found = await pool.query(
      'SELECT sender_id, recipient_id, group_id FROM messages WHERE id = $1',
      [req.params.id]);
    const msg = found.rows[0];
    if (!msg) return res.status(404).json({ error: 'הודעה לא נמצאה' });

    if (forEveryone && msg.sender_id === req.user.id) {
      await pool.query('UPDATE messages SET deleted_for_everyone=TRUE, body=NULL WHERE id=$1', [req.params.id]);
      const sid = onlineUsers.get(msg.recipient_id);
      if (sid) io.to(sid).emit('message:deleted', { id: req.params.id });
      if (msg.group_id) {
        io.to(`group:${msg.group_id}`).emit('message:deleted', {
          id: req.params.id,
          groupId: msg.group_id,
        });
      }
    } else {
      await pool.query(
        'UPDATE messages SET deleted_for_sender=TRUE WHERE id=$1 AND sender_id=$2',
        [req.params.id, req.user.id]);
    }
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// ── Edit message ─────────────────────────────────────────────────
app.patch('/api/messages/:id', auth, async (req, res) => {
  const newBody = (req.body.body || '').trim();
  if (!newBody) return res.status(400).json({ error: 'תוכן ההודעה ריק' });
  if (moderateChatText(newBody).blocked) {
    recordBlockedChat(req.user.id, 'message_edit', newBody, req.params.id,
      clientIp(req));
    return res.status(422).json({
      error: 'ההודעה נחסמה משום שהיא כוללת תוכן פוגעני או אסור',
      code: 'CHAT_CONTENT_BLOCKED',
    });
  }
  try {
    const pool = await getPool();
    const found = await pool.query(
      'SELECT sender_id, recipient_id, group_id, type FROM messages WHERE id=$1 AND deleted_for_everyone=FALSE',
      [req.params.id]);
    const msg = found.rows[0];
    if (!msg) return res.status(404).json({ error: 'הודעה לא נמצאה' });
    if (msg.sender_id !== req.user.id) return res.status(403).json({ error: 'אין הרשאה לערוך' });
    if (msg.type !== 'text') return res.status(400).json({ error: 'ניתן לערוך הודעות טקסט בלבד' });
    await pool.query(
      'UPDATE messages SET body=$1, is_edited=TRUE, edited_at=now() WHERE id=$2',
      [newBody, req.params.id]);
    // Notify recipient (private chat)
    if (msg.recipient_id) {
      const sid = onlineUsers.get(msg.recipient_id);
      if (sid) io.to(sid).emit('message:edited', { id: req.params.id, body: newBody });
    }
    // Notify group members
    if (msg.group_id) {
      const members = await pool.query('SELECT user_id FROM group_members WHERE group_id=$1', [msg.group_id]);
      for (const { user_id } of members.rows) {
        if (user_id === req.user.id) continue;
        const sid = onlineUsers.get(user_id);
        if (sid) io.to(sid).emit('message:edited', { id: req.params.id, body: newBody, groupId: msg.group_id });
      }
    }
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Block: block user ─────────────────────────────────────────────
app.post('/api/block/:userId', auth, async (req, res) => {
  if (req.params.userId === req.user.id) return res.status(400).json({ error: 'לא ניתן לחסום את עצמך' });
  try {
    const pool = await getPool();
    await pool.query(
      `INSERT INTO blocked_users (blocker_id, blocked_id) VALUES ($1, $2)
       ON CONFLICT (blocker_id, blocked_id) DO NOTHING`,
      [req.user.id, req.params.userId]);
    logActivity(req.user.id, 'block_user', { blockedUserId: req.params.userId }, req.ip);
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Block: unblock user ───────────────────────────────────────────
app.delete('/api/block/:userId', auth, async (req, res) => {
  try {
    const pool = await getPool();
    await pool.query(
      'DELETE FROM blocked_users WHERE blocker_id=$1 AND blocked_id=$2', [req.user.id, req.params.userId]);
    logActivity(req.user.id, 'unblock_user', { unblockedUserId: req.params.userId }, req.ip);
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Block: list blocked users ─────────────────────────────────────
app.get('/api/blocked', auth, async (req, res) => {
  try {
    const pool = await getPool();
    const result = await pool.query(
      `SELECT u.id, u.name, u.profile_pic_url
       FROM blocked_users b
       JOIN users u ON u.id = b.blocked_id
       WHERE b.blocker_id = $1
       ORDER BY u.name`, [req.user.id]);
    res.json(result.rows);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Reports: users, messages, groups and listings ─────────────────
app.post('/api/reports', auth, reportRateLimit, async (req, res) => {
  const targetType = String(req.body.targetType || '').trim();
  const targetId = String(req.body.targetId || '').trim();
  const reason = String(req.body.reason || '').trim();
  const details = String(req.body.details || '').trim().slice(0, 1000) || null;
  const allowedReasons = new Set([
    'spam', 'harassment', 'inappropriate', 'fraud', 'illegal', 'other',
  ]);
  if (!['user', 'message', 'group', 'listing'].includes(targetType) ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(targetId) ||
      !allowedReasons.has(reason)) {
    return res.status(400).json({ error: 'פרטי הדיווח אינם תקינים' });
  }
  if (targetType === 'user' && targetId === req.user.id)
    return res.status(400).json({ error: 'לא ניתן לדווח על עצמך' });
  try {
    const pool = await getPool();
    let visible = false;
    if (targetType === 'user') {
      visible = !!(await pool.query('SELECT 1 FROM users WHERE id=$1', [targetId])).rows.length;
    } else if (targetType === 'listing') {
      visible = !!(await pool.query('SELECT 1 FROM listings WHERE id=$1', [targetId])).rows.length;
    } else if (targetType === 'group') {
      visible = !!(await pool.query(
        `SELECT 1 FROM group_members WHERE group_id=$1 AND user_id=$2`,
        [targetId, req.user.id])).rows.length;
    } else {
      visible = !!(await pool.query(
        `SELECT 1 FROM messages m
         WHERE m.id=$1 AND (
           m.sender_id=$2 OR m.recipient_id=$2 OR
           EXISTS (SELECT 1 FROM group_members gm
                   WHERE gm.group_id=m.group_id AND gm.user_id=$2)
         )`, [targetId, req.user.id])).rows.length;
    }
    if (!visible) return res.status(404).json({ error: 'התוכן לא נמצא או אינו נגיש' });
    const inserted = await pool.query(
      `INSERT INTO user_reports(reporter_id,target_type,target_id,reason,details)
       VALUES($1,$2,$3,$4,$5)
       ON CONFLICT(reporter_id,target_type,target_id) DO UPDATE SET
         reason=EXCLUDED.reason, details=EXCLUDED.details,
         status='pending', reviewed_by=NULL, reviewed_at=NULL, created_at=now()
       RETURNING id,status`,
      [req.user.id, targetType, targetId, reason, details]);
    logActivity(req.user.id, 'submit_report',
      { reportId: inserted.rows[0].id, targetType, targetId }, clientIp(req));
    res.status(201).json({ ok: true, ...inserted.rows[0] });
  } catch (e) {
    console.error('submit report:', e.message);
    res.status(500).json({ error: 'לא ניתן היה לשמור את הדיווח' });
  }
});

// ── Profile: get ──────────────────────────────────────────────────
app.get('/api/profile', auth, async (req, res) => {
  try {
    const pool = await getPool();
    const result = await pool.query(
      `SELECT id, name, email, phone, email_verified, phone_verified,
              city, country, street, house_number, apartment,
              profile_pic_url, privacy_pic, filter_level
       FROM users WHERE id = $1`, [req.user.id]);
    if (!result.rows.length) return res.status(404).json({ error: 'לא נמצא' });
    res.json(result.rows[0]);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Profile: update ───────────────────────────────────────────────
app.put('/api/profile', auth, async (req, res) => {
  const { name, city, privacy_pic, filter_level, profile_pic_url,
          country, street, house_number, apartment } = req.body;
  if (!name || !name.trim()) return res.status(400).json({ error: 'נדרש שם' });
  const validPrivacy = ['all', 'contacts', 'nobody'];
  const validFilter  = ['standard', 'strict'];
  try {
    const pool = await getPool();
    await pool.query(
      `UPDATE users
       SET name=$1, city=$2,
           country=$3, street=$4, house_number=$5, apartment=$6,
           privacy_pic=$7, filter_level=$8,
           profile_pic_url=$9
       WHERE id=$10`,
      [name.trim(), city || null, country || 'ישראל', street || null,
       house_number || null, apartment || null,
       validPrivacy.includes(privacy_pic) ? privacy_pic : 'all',
       validFilter.includes(filter_level) ? filter_level : 'standard',
       profile_pic_url || null, req.user.id]);
    logActivity(req.user.id, 'update_profile', { name: name.trim(), city, country }, req.ip);
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Location: update precise location ────────────────────────────
async function reverseGeocodeHebrew(lat, lng) {
  try {
    const url = `https://nominatim.openstreetmap.org/reverse?lat=${lat}&lon=${lng}&format=json&accept-language=he`;
    const res  = await fetch(url, { headers: { 'User-Agent': 'betshuva-app/1.0' } });
    const data = await res.json();
    const addr = data.address || {};
    const city = addr.city || addr.town || addr.village || addr.municipality || addr.suburb || null;
    const country = addr.country || null;
    return { city, country };
  } catch { return { city: null, country: null }; }
}

app.put('/api/location', auth, async (req, res) => {
  const { latitude, longitude } = req.body;
  if (latitude == null || longitude == null) return res.status(400).json({ error: 'נדרש מיקום' });
  if (Math.abs(latitude) > 90 || Math.abs(longitude) > 180) return res.status(400).json({ error: 'מיקום לא תקין' });
  try {
    const { city, country } = await reverseGeocodeHebrew(latitude, longitude);
    const pool = await getPool();
    await pool.query(
      `UPDATE users SET latitude=$1, longitude=$2,
       city=$3, country=$4,
       location_updated_at=now() WHERE id=$5`,
      [latitude, longitude, city || null, country || null, req.user.id]);
    res.json({ ok: true, city, country });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.delete('/api/location', auth, async (req, res) => {
  try {
    const pool = await getPool();
    await pool.query(
      `UPDATE users SET latitude=NULL, longitude=NULL, location_updated_at=NULL
       WHERE id=$1`, [req.user.id]);
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: 'לא ניתן למחוק את המיקום' }); }
});

// ── Location: get nearby users (by radius and/or city) ───────────
app.get('/api/users/nearby', auth, async (req, res) => {
  const { city, radius } = req.query;
  if (!city && !radius) return res.status(400).json({ error: 'נדרש עיר או רדיוס' });
  try {
    const pool = await getPool();

    // city-only search
    if (city && !radius) {
      const result = await pool.query(
        `SELECT id, name, profile_pic_url, city, country
         FROM users
         WHERE id != $1 AND city = $2
           AND (email_verified = TRUE OR phone_verified = TRUE)
         ORDER BY name ASC`, [req.user.id, city]);
      return res.json(result.rows);
    }

    // radius search — use caller's stored coordinates
    const me = await pool.query('SELECT latitude, longitude FROM users WHERE id=$1', [req.user.id]);
    const { latitude: myLat, longitude: myLng } = me.rows[0] || {};
    if (myLat == null || myLng == null)
      return res.status(400).json({ error: 'המיקום שלך אינו מוגדר' });

    // optionally also filter by city
    const cityFilter = city ? 'AND city = $5' : '';
    const params = [myLat, myLng, req.user.id, parseFloat(radius)];
    if (city) params.push(city);

    const result = await pool.query(`
      SELECT id, name, profile_pic_url, city, country,
        ROUND((6371 * ACOS(
          COS(RADIANS($1)) * COS(RADIANS(latitude)) *
          COS(RADIANS(longitude) - RADIANS($2)) +
          SIN(RADIANS($1)) * SIN(RADIANS(latitude))
        ))::numeric, 1) AS distance_km
      FROM users
      WHERE id != $3
        AND (email_verified = TRUE OR phone_verified = TRUE)
        AND latitude IS NOT NULL AND longitude IS NOT NULL
        ${cityFilter}
        AND (6371 * ACOS(
          COS(RADIANS($1)) * COS(RADIANS(latitude)) *
          COS(RADIANS(longitude) - RADIANS($2)) +
          SIN(RADIANS($1)) * SIN(RADIANS(latitude))
        )) <= $4
      ORDER BY distance_km ASC`, params);

    res.json(result.rows);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Location: list cities with users ─────────────────────────────
app.get('/api/cities', auth, async (req, res) => {
  try {
    const pool = await getPool();
    const result = await pool.query(
      `SELECT DISTINCT city, COUNT(*) AS user_count
       FROM users WHERE city IS NOT NULL
       GROUP BY city ORDER BY user_count DESC`);
    res.json(result.rows);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Listings ──────────────────────────────────────────────────────

app.post('/api/listings', auth, async (req, res) => {
  const { type, title, description, price, city, latitude, longitude, image_url, image_urls, category } = req.body;
  const allImages = image_urls?.length ? image_urls.slice(0, 8) : (image_url ? [image_url] : []);
  if (!title?.trim()) return res.status(400).json({ error: 'נדרשת כותרת' });
  const validTypes = ['free', 'sale'];
  const validCats  = ['רהיטים','אלקטרוניקה','בגדים','ספרים','כלי בית','צעצועים','אחר'];
  try {
    const pool = await getPool();
    // use user's stored location if not provided
    let lat = latitude, lng = longitude, listCity = city;
    if (!lat || !lng) {
      const me = await pool.query('SELECT latitude, longitude, city FROM users WHERE id=$1', [req.user.id]);
      lat      = me.rows[0]?.latitude  ?? lat;
      lng      = me.rows[0]?.longitude ?? lng;
      listCity = listCity || me.rows[0]?.city;
    }
    const result = await pool.query(
      `INSERT INTO listings (user_id,type,title,description,price,city,latitude,longitude,image_url,category)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)
       RETURNING id`,
      [req.user.id, validTypes.includes(type) ? type : 'free', title.trim(), description || null,
       type === 'sale' ? (price ?? 0) : null, listCity || null, lat || null, lng || null,
       allImages[0] || null, validCats.includes(category) ? category : 'אחר']);
    const listingId = result.rows[0].id;
    if (allImages.length) {
      for (let i = 0; i < allImages.length; i++) {
        await pool.query(
          `INSERT INTO listing_images (listing_id, url, sort_order) VALUES ($1, $2, $3)`,
          [listingId, allImages[i], i]);
      }
    }
    res.json({ id: listingId });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.get('/api/listings', auth, async (req, res) => {
  const { type, category, city, radius, status, page = 1, mine } = req.query;
  const pageSize = 20;
  const offset   = (parseInt(page) - 1) * pageSize;
  const rowFrom  = offset + 1;
  const rowTo    = offset + pageSize;
  try {
    const pool = await getPool();
    const params = [];
    const addParam = (v) => { params.push(v); return `$${params.length}`; };

    let where = mine === 'true'
      ? `l.user_id = ${addParam(req.user.id)}`
      : (status
        ? (status === 'active' ? `l.status='active' AND l.expires_at > now()` : `l.status=${addParam(status)}`)
        : `l.status = 'active' AND l.expires_at > now()`);

    if (type)     where += ` AND l.type=${addParam(type)}`;
    if (category) where += ` AND l.category=${addParam(category)}`;
    if (city)     where += ` AND l.city=${addParam(city)}`;

    let distExpr = 'NULL';
    if (radius) {
      const me = await pool.query('SELECT latitude, longitude FROM users WHERE id=$1', [req.user.id]);
      const { latitude: myLat, longitude: myLng } = me.rows[0] || {};
      if (myLat && myLng) {
        const pLat = addParam(myLat), pLng = addParam(myLng), pRadius = addParam(parseFloat(radius));
        const distFormula = `ROUND((6371*ACOS(COS(RADIANS(${pLat}))*COS(RADIANS(l.latitude))*COS(RADIANS(l.longitude)-RADIANS(${pLng}))+SIN(RADIANS(${pLat}))*SIN(RADIANS(l.latitude))))::numeric,1)`;
        where += ` AND l.latitude IS NOT NULL AND (${distFormula}) <= ${pRadius}`;
        distExpr = distFormula;
      }
    }

    const result = await pool.query(`
      SELECT id, type, title, description, price, city,
             image_url, images, category, status, created_at,
             view_count, contact_count,
             seller_id, seller_name, seller_pic, dist AS distance_km
      FROM (
        SELECT l.id, l.type, l.title, l.description, l.price, l.city,
               l.image_url,
               COALESCE(
                 (SELECT ARRAY_AGG(li.url ORDER BY li.sort_order)
                  FROM listing_images li WHERE li.listing_id=l.id),
                 CASE WHEN l.image_url IS NOT NULL THEN ARRAY[l.image_url]
                      ELSE ARRAY[]::text[] END
               ) AS images,
               l.category, l.status, l.created_at,
               l.view_count, l.contact_count, l.latitude, l.longitude,
               u.id AS seller_id, u.name AS seller_name, u.profile_pic_url AS seller_pic,
               ${distExpr} AS dist,
               ROW_NUMBER() OVER (ORDER BY l.created_at DESC) AS _rn
        FROM listings l JOIN users u ON u.id = l.user_id
        WHERE ${where}
      ) AS _q
      WHERE _q._rn >= ${rowFrom} AND _q._rn <= ${rowTo}
      ORDER BY _q._rn`, params);
    res.json(result.rows);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.get('/api/listings/:id', auth, async (req, res) => {
  try {
    const pool = await getPool();
    // register unique view (ignore if already viewed) — only bump the counter when the insert actually happened
    try {
      await pool.query(`
        WITH ins AS (
          INSERT INTO listing_views (listing_id, user_id) VALUES ($1, $2)
          ON CONFLICT (listing_id, user_id) DO NOTHING
          RETURNING 1
        )
        UPDATE listings SET view_count = view_count + 1
        WHERE id = $1 AND EXISTS (SELECT 1 FROM ins)`,
        [req.params.id, req.user.id]);
    } catch (_) {}
    const result = await pool.query(
      `SELECT l.*, u.name AS seller_name, u.profile_pic_url AS seller_pic, u.id AS seller_id
       FROM listings l JOIN users u ON u.id = l.user_id WHERE l.id=$1`, [req.params.id]);
    if (!result.rows.length) return res.status(404).json({ error: 'לא נמצא' });
    const item = result.rows[0];
    const imgs = await pool.query('SELECT url FROM listing_images WHERE listing_id=$1 ORDER BY sort_order', [req.params.id]);
    item.images = imgs.rows.length
      ? imgs.rows.map(r => r.url)
      : (item.image_url ? [item.image_url] : []);
    res.json(item);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.post('/api/listings/:id/contact', auth, async (req, res) => {
  try {
    const pool = await getPool();
    await pool.query('UPDATE listings SET contact_count = contact_count + 1 WHERE id=$1', [req.params.id]);
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.put('/api/listings/:id/status', auth, async (req, res) => {
  const { status } = req.body;
  const valid = ['active', 'sold', 'expired'];
  if (!valid.includes(status)) return res.status(400).json({ error: 'סטטוס לא תקין' });
  try {
    const pool = await getPool();
    await pool.query(
      'UPDATE listings SET status=$1 WHERE id=$2 AND user_id=$3', [status, req.params.id, req.user.id]);
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.put('/api/listings/:id', auth, async (req, res) => {
  const { type, title, description, price, city, category, image_urls } = req.body;
  if (!title?.trim()) return res.status(400).json({ error: 'נדרשת כותרת' });
  const validTypes = ['free', 'sale'];
  const validCats  = ['רהיטים','אלקטרוניקה','בגדים','ספרים','כלי בית','צעצועים','אחר'];
  const safeType   = validTypes.includes(type) ? type : 'free';
  const safeCat    = validCats.includes(category) ? category : 'אחר';
  const allImages  = Array.isArray(image_urls) ? image_urls.filter(Boolean).slice(0, 8) : [];
  try {
    const pool = await getPool();
    const upd = await pool.query(
      `UPDATE listings SET type=$1, title=$2, description=$3,
       price=$4, city=$5, category=$6, image_url=$7
       WHERE id=$8 AND user_id=$9`,
      [safeType, title.trim(), description || null, safeType === 'sale' ? (price ?? 0) : null,
       city || null, safeCat, allImages[0] || null, req.params.id, req.user.id]);
    if (upd.rowCount === 0) return res.status(404).json({ error: 'לא נמצא' });
    await pool.query('DELETE FROM listing_images WHERE listing_id=$1', [req.params.id]);
    for (let i = 0; i < allImages.length; i++) {
      await pool.query(
        'INSERT INTO listing_images (listing_id, url, sort_order) VALUES ($1, $2, $3)',
        [req.params.id, allImages[i], i]);
    }
    logActivity(req.user.id, 'edit_listing', { id: req.params.id }, req.ip);
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.delete('/api/listings/:id', auth, async (req, res) => {
  try {
    const pool = await getPool();
    await pool.query('DELETE FROM listings WHERE id=$1 AND user_id=$2', [req.params.id, req.user.id]);
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── FCM Token: register / refresh ────────────────────────────────
app.post('/api/fcm-token', auth, async (req, res) => {
  const { token, deviceId } = req.body;
  if (!token) return res.status(400).json({ error: 'נדרש token' });
  try {
    const pool = await getPool();
    await pool.query(
      `INSERT INTO fcm_tokens (user_id, token, device_id) VALUES ($1, $2, $3)
       ON CONFLICT (user_id, device_id) DO UPDATE SET token=$2, updated_at=now()`,
      [req.user.id, token, deviceId || 'default']);
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── File Upload ───────────────────────────────────────────────────
app.get('/api/gifs/search', auth, searchRateLimit, async (req, res) => {
  const apiKey = process.env.TENOR_API_KEY;
  if (!apiKey)
    return res.status(503).json({ error: 'חיפוש GIF טרם הוגדר בשרת' });
  const query = String(req.query.q || '').trim().slice(0, 80);
  if (!query) return res.status(400).json({ error: 'יש להזין מילת חיפוש' });
  try {
    const url = new URL('https://tenor.googleapis.com/v2/search');
    url.searchParams.set('key', apiKey);
    url.searchParams.set('client_key', 'betshuva_messenger');
    url.searchParams.set('q', query);
    url.searchParams.set('limit', '20');
    url.searchParams.set('locale', 'he_IL');
    url.searchParams.set('country', 'IL');
    url.searchParams.set('contentfilter', 'high');
    url.searchParams.set('media_filter', 'gif,tinygif');
    const response = await fetch(url, { signal: AbortSignal.timeout(10000) });
    if (!response.ok) throw new Error(`Tenor ${response.status}`);
    const payload = await response.json();
    const results = (payload.results || []).flatMap(item => {
      const full = item.media_formats?.gif;
      const preview = item.media_formats?.tinygif || full;
      if (!full?.url || !preview?.url) return [];
      const token = jwt.sign(
        { purpose: 'gif-download', url: full.url, id: String(item.id || '') },
        JWT_SECRET,
        { expiresIn: '10m' },
      );
      return [{
        id: String(item.id || ''),
        description: String(item.content_description || ''),
        previewUrl: preview.url,
        width: Number(preview.dims?.[0] || 1),
        height: Number(preview.dims?.[1] || 1),
        downloadToken: token,
      }];
    });
    res.json({ results, attribution: 'Tenor' });
  } catch (error) {
    console.error('gif search:', error.message);
    res.status(502).json({ error: 'חיפוש ה-GIF נכשל' });
  }
});

app.get('/api/gifs/download', auth, async (req, res) => {
  try {
    const decoded = jwt.verify(String(req.query.token || ''), JWT_SECRET);
    if (decoded.purpose !== 'gif-download') throw new Error('invalid purpose');
    const gifUrl = new URL(decoded.url);
    if (gifUrl.protocol !== 'https:' ||
        !(gifUrl.hostname === 'tenor.com' || gifUrl.hostname.endsWith('.tenor.com')))
      return res.status(400).json({ error: 'מקור GIF אינו מורשה' });
    const response = await fetch(gifUrl, { signal: AbortSignal.timeout(15000) });
    if (!response.ok) throw new Error(`GIF download ${response.status}`);
    const contentType = response.headers.get('content-type') || '';
    if (!contentType.toLowerCase().startsWith('image/gif'))
      return res.status(415).json({ error: 'הקובץ שהתקבל אינו GIF' });
    const declaredSize = Number(response.headers.get('content-length') || 0);
    if (declaredSize > 10 * 1024 * 1024)
      return res.status(413).json({ error: 'קובץ ה-GIF גדול מדי' });
    const buffer = Buffer.from(await response.arrayBuffer());
    if (buffer.length > 10 * 1024 * 1024)
      return res.status(413).json({ error: 'קובץ ה-GIF גדול מדי' });
    res.set('Content-Type', 'image/gif');
    res.set('Cache-Control', 'private, no-store');
    res.send(buffer);
  } catch (error) {
    console.error('gif download:', error.message);
    res.status(400).json({ error: 'קישור ה-GIF אינו תקין או שפג תוקפו' });
  }
});

app.post('/api/upload', auth, uploadRateLimit, upload.single('file'), async (req, res) => {
  const file = req.file;
  if (!file) return res.status(400).json({ error: 'לא נשלח קובץ' });
  file.originalname = normalizeUploadFileName(file.originalname);

  // Block video types
  if (BLOCKED_TYPES.some(t => file.mimetype.startsWith(t)))
    return res.status(400).json({ error: 'שליחת סרטוני וידאו אינה מותרת' });

  const allowed = ALLOWED_TYPES[file.mimetype];
  if (!allowed) return res.status(400).json({ error: 'סוג קובץ לא נתמך' });

  // Size check
  const maxBytes = allowed.maxMB * 1024 * 1024;
  if (file.size > maxBytes)
    return res.status(400).json({ error: `גודל קובץ מקסימלי: ${allowed.maxMB}MB` });

  try {
    const pool = await getPool();
    const scanBotUpload = req.body.toUserId === SCAN_BOT_ID;
    const reportImageScan = allowed.dbType === 'image' &&
      (scanBotUpload || req.body.scanReport === 'true');
    let recipientPolicy = null;
    if (req.body.toUserId) {
      recipientPolicy = await getEffectiveRecipientFilter(pool, req.body.toUserId, req.user.id);
      if (!recipientPolicy) return res.status(404).json({ error: 'הנמען לא נמצא' });
      if (!recipientPolicy.isContact)
        return res.status(403).json({ error: 'מי שאינו חבר יכול לשלוח בקשת טקסט בלבד' });
    }
    if (req.body.groupId) {
      const groupAccess = await pool.query(
        `SELECT gm.role, g.send_permission FROM group_members gm
         JOIN groups g ON g.id=gm.group_id
         WHERE gm.group_id=$1 AND gm.user_id=$2 AND gm.status='member'`,
        [req.body.groupId, req.user.id]);
      const member = groupAccess.rows[0];
      if (!member)
        return res.status(403).json({ error: 'לא חבר פעיל בקבוצה' });
      if (member.send_permission === 'admin' && member.role !== 'admin')
        return res.status(403).json({ error: 'רק מנהלי הקבוצה רשאים לשלוח הודעות' });
    }
    // העלאה לאחסון תחילה (גם קבצים חסומים נשמרים לצורך ביקורת אדמין)
    const blobName = `${req.user.id}/${Date.now()}-${crypto.randomUUID()}-${file.originalname.replace(/[^\w.\-]/g, '_')}`;
    const url = await uploadToBlob(file.buffer, blobName, file.mimetype);
    await pool.query(
      `INSERT INTO stored_files
       (user_id, original_name, storage_path, public_url, mime_type, file_type,
        file_size, context_type, context_id, moderation_status)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,'pending')`,
      [req.user.id, file.originalname, blobName, url, file.mimetype, allowed.dbType,
       file.size, req.body.groupId ? 'group' : req.body.toUserId ? 'chat' :
         req.body.listingImage === 'true' ? 'listing' : 'general',
       req.body.groupId || req.body.toUserId || null]);

    // Content moderation scan
    let scanResult;
    if (allowed.dbType === 'image')
      scanResult = await scanImage(file.buffer);
    else if (allowed.dbType === 'document')
      scanResult = await scanDocument(file.buffer, file.mimetype);

    if (scanResult) {
      const ss = scanResult.safeSearch || {};
      console.log(`[Vision] ${file.originalname} | ${scanResult.blocked ? '⛔ BLOCKED by ' + scanResult.blockedBy : scanResult.pending ? '⏳ PENDING' : '✅ APPROVED'} | faces:${scanResult.faces?.length || 0} | adult:${ss.adult || '—'} | racy:${ss.racy || '—'} | labels:${(scanResult.labels || []).slice(0, 3).map(l => l.name).join(',')}`);
    }

    if (scanResult?.blocked) {
      await pool.query(
        `UPDATE stored_files SET moderation_status='rejected', moderation_details=$1 WHERE public_url=$2`,
        [JSON.stringify(scanResult), url]);
      logActivity(req.user.id, 'blocked_upload',
        { fileName: file.originalname, fileSize: file.size, fileType: allowed.dbType,
          fileUrl: url, reason: scanResult.reason, blockedBy: scanResult.blockedBy,
          safeSearch: scanResult.safeSearch, labels: scanResult.labels,
          faces: scanResult.faces || [], genderResults: scanResult.genderResults || null,
          strictModesty: scanResult.strictModesty || null,
          localSafety: scanResult.localSafety || null,
          googleSafeSearch: scanResult.googleSafeSearch || null }, req.ip);
      let scanReport = null;
      if (reportImageScan)
        scanReport = await saveScanBotReport(pool, req.user.id, {
          name: file.originalname, size: file.size, dbType: allowed.dbType,
        }, url, scanResult, 'rejected');
      return res.json({ url, fileName: file.originalname, fileSize: file.size,
        fileType: allowed.dbType, status: 'rejected', reason: scanResult.reason,
        classification: scanResult.classification || null,
        handledByScanBot: scanBotUpload, scanReport });
    }

    // Listings deliberately allow product/object photos only. A listing image
    // must be confidently classified as non-human; people and uncertain
    // classifications are rejected instead of being published accidentally.
    if (req.body.listingImage === 'true' && allowed.dbType === 'image' &&
        !scanResult?.pending) {
      const classification = scanResult?.classification || null;
      const categories = classification?.detectedCategories || [];
      const hasPeople = (scanResult?.faces?.length || 0) > 0 ||
        categories.some(category => ['men', 'women', 'children', 'people'].includes(category));
      const confidentNonHuman = classification?.category === 'nonHumanImages' &&
        classification?.uncertain !== true && !hasPeople;
      if (!confidentNonHuman) {
        const reason = hasPeople
          ? 'במודעות מותרות רק תמונות ללא אנשים'
          : 'לא ניתן לאשר שזו תמונה ללא אנשים';
        const details = { ...scanResult, reason, listingImage: true };
        await pool.query(
          `UPDATE stored_files SET moderation_status='rejected', moderation_details=$1
           WHERE public_url=$2`,
          [JSON.stringify(details), url]);
        logActivity(req.user.id, 'blocked_listing_image', {
          fileName: file.originalname, fileUrl: url, reason, classification,
          faces: scanResult?.faces || [],
        }, req.ip);
        return res.json({
          url, fileName: file.originalname, fileSize: file.size,
          fileType: allowed.dbType, status: 'rejected', reason, classification,
        });
      }
    }

    if (!scanBotUpload && !scanResult?.pending && allowed.dbType === 'image' && recipientPolicy &&
        !imageAllowedByFilter(recipientPolicy.filter, scanResult?.classification)) {
      const categories = scanResult?.classification?.detectedCategories ||
        [scanResult?.classification?.category || 'people'];
      const labels = { nonHumanImages: 'תמונות ללא בני אדם', men: 'תמונות גברים',
        women: 'תמונות נשים', children: 'תמונות ילדים', people: 'תמונות עם מספר אנשים' };
      const blockedCategories = categories.filter(category =>
        recipientPolicy.filter[category] !== true);
      const reason = `${blockedCategories.map(category => labels[category] || category).join(', ') || 'סוג התמונה'} חסומות בהגדרות הנמען`;
      logActivity(req.user.id, 'blocked_by_recipient_filter', {
        toUserId: req.body.toUserId, fileName: file.originalname, fileUrl: url,
        categories, classification: scanResult?.classification || null,
        strictModesty: scanResult?.strictModesty || null,
        localSafety: scanResult?.localSafety || null,
        googleSafeSearch: scanResult?.googleSafeSearch || null,
      }, req.ip);
      await pool.query(
        `UPDATE stored_files SET moderation_status='rejected', moderation_details=$1 WHERE public_url=$2`,
        [JSON.stringify({ reason, classification: scanResult?.classification || null,
          safeSearch: scanResult?.safeSearch || null,
          strictModesty: scanResult?.strictModesty || null,
          localSafety: scanResult?.localSafety || null,
          googleSafeSearch: scanResult?.googleSafeSearch || null }), url]);
      let scanReport = null;
      if (reportImageScan)
        scanReport = await saveScanBotReport(pool, req.user.id, {
          name: file.originalname, size: file.size, dbType: allowed.dbType,
        }, url, { ...scanResult, reason }, 'rejected');
      return res.json({ url, fileName: file.originalname, fileSize: file.size,
        fileType: allowed.dbType, status: 'rejected', reason,
        classification: scanResult?.classification || null,
        handledByScanBot: scanBotUpload, scanReport });
    }

    if (scanResult?.pending) {
      // Scan service unavailable — save for retry
      const toUserId = req.body.toUserId || null;
      const groupId  = req.body.groupId  || null;
      await pool.query(
        `UPDATE stored_files SET moderation_details=$1 WHERE public_url=$2`,
        [JSON.stringify(scanResult), url]);
      const ins = await pool.query(
        `INSERT INTO pending_scans (user_id, to_user_id, group_id, file_url, file_name, file_type, mime_type)
         VALUES ($1, $2, $3, $4, $5, $6, $7)
         RETURNING id`,
        [req.user.id, toUserId, groupId, url, file.originalname, allowed.dbType, file.mimetype]);
      logActivity(req.user.id, 'upload_pending',
        { fileName: file.originalname, fileSize: file.size, fileType: allowed.dbType,
          fileUrl: url, safeSearch: scanResult.safeSearch || null,
          googleSafeSearch: scanResult.googleSafeSearch || null }, req.ip);
      let scanReport = null;
      if (reportImageScan)
        scanReport = await saveScanBotReport(pool, req.user.id, {
          name: file.originalname, size: file.size, dbType: allowed.dbType,
        }, url, scanResult, 'pending');
      return res.json({
        url, fileName: file.originalname, fileSize: file.size,
        fileType: allowed.dbType, status: 'pending', pendingId: ins.rows[0].id,
        reason: scanResult.reason || 'שירות הסריקה אינו זמין כרגע',
        classification: scanResult.classification || null,
        handledByScanBot: scanBotUpload, scanReport,
      });
    }

    await pool.query(
      `UPDATE stored_files SET moderation_status='approved', moderation_details=$1 WHERE public_url=$2`,
      [JSON.stringify(scanResult || {}), url]);

    let scanReport = null;
    if (reportImageScan)
      scanReport = await saveScanBotReport(pool, req.user.id, {
        name: file.originalname, size: file.size, dbType: allowed.dbType,
      }, url, scanResult, 'approved');

    logActivity(req.user.id, 'upload_file',
      { fileName: file.originalname, fileSize: file.size, fileType: allowed.dbType,
        fileUrl: url, toUserId: req.body.toUserId || null,
        safeSearch: scanResult?.safeSearch || null,
        labels: scanResult?.labels || null,
        faces: scanResult?.faces || [],
        genderResults: scanResult?.genderResults || null,
        strictModesty: scanResult?.strictModesty || null,
        localSafety: scanResult?.localSafety || null,
        googleSafeSearch: scanResult?.googleSafeSearch || null,
        blockedBy: null }, req.ip);
    res.json({ url, fileName: file.originalname, fileSize: file.size,
      fileType: allowed.dbType, handledByScanBot: scanBotUpload, scanReport });
  } catch (e) {
    console.error('upload:', e.message);
    res.status(500).json({ error: e.message });
  }
});

// ── Groups: list mine ─────────────────────────────────────────────
app.get('/api/groups', auth, async (req, res) => {
  try {
    const pool = await getPool();
    const result = await pool.query(`
      SELECT g.id, g.name, g.description, g.profile_pic_url, g.is_broadcast, g.send_permission, g.filter_level,
             gm.role, gm.status, gm.pinned_at,
             group_admin.id AS admin_id, group_admin.name AS admin_name,
             (SELECT COUNT(*) FROM group_members WHERE group_id = g.id AND status='member') AS member_count,
             last_msg.body AS last_message,
             last_msg.type AS last_message_type,
             last_msg.created_at AS last_message_at,
             last_msg.sender_name AS last_message_sender_name,
             (last_msg.sender_id = $1) AS last_message_is_mine
      FROM groups g
      JOIN group_members gm ON g.id = gm.group_id AND gm.user_id = $1
      LEFT JOIN LATERAL (
        SELECT u.id, u.name
        FROM group_members admin_member
        JOIN users u ON u.id = admin_member.user_id
        WHERE admin_member.group_id = g.id
          AND admin_member.role = 'admin'
          AND admin_member.status = 'member'
        ORDER BY admin_member.joined_at
        LIMIT 1
      ) group_admin ON TRUE
      LEFT JOIN LATERAL (
        SELECT m.body, m.type, m.created_at, m.sender_id, u.name AS sender_name
        FROM messages m
        JOIN users u ON u.id=m.sender_id
        WHERE m.group_id = g.id AND m.deleted_for_everyone = FALSE
          AND gm.status='member'
          AND m.created_at >= gm.joined_at
        ORDER BY m.created_at DESC
        LIMIT 1
      ) last_msg ON TRUE
      ORDER BY gm.pinned_at DESC NULLS LAST,
               last_msg.created_at DESC NULLS LAST, g.created_at DESC
    `, [req.user.id]);
    res.json(result.rows);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Groups: create ────────────────────────────────────────────────
app.post('/api/groups', auth, async (req, res) => {
  const { name, description } = req.body;
  if (!name) return res.status(400).json({ error: 'נדרש שם קבוצה' });
  try {
    const pool = await getPool();
    const result = await pool.query(
      `INSERT INTO groups (name, description, creator_id)
       VALUES ($1, $2, $3)
       RETURNING id, name, description`,
      [name, description || '', req.user.id]);
    const group = result.rows[0];
    await pool.query(
      `INSERT INTO group_members (group_id, user_id, role) VALUES ($1, $2, 'admin')`,
      [group.id, req.user.id]);
    logActivity(req.user.id, 'create_group', { groupId: group.id, name }, req.ip);
    res.json({
      ...group,
      role: 'admin',
      admin_id: req.user.id,
      admin_name: req.user.name,
      member_count: 1,
      is_broadcast: false,
      send_permission: 'all',
    });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Groups: details + members ─────────────────────────────────────
app.get('/api/groups/:id', auth, async (req, res) => {
  try {
    const pool = await getPool();
    const mem = await pool.query(
      `SELECT role FROM group_members
       WHERE group_id=$1 AND user_id=$2 AND status='member'`,
      [req.params.id, req.user.id]);
    if (!mem.rows.length)
      return res.status(403).json({ error: 'לא חבר פעיל בקבוצה' });

    const [grp, members] = await Promise.all([
      pool.query('SELECT * FROM groups WHERE id=$1', [req.params.id]),
      pool.query(
        `SELECT u.id, u.name, u.profile_pic_url, gm.role, gm.joined_at, gm.last_viewed_at
         FROM group_members gm JOIN users u ON u.id=gm.user_id
         WHERE gm.group_id=$1 AND gm.status='member'
         ORDER BY gm.role DESC, u.name`, [req.params.id]),
    ]);
    res.json({ ...grp.rows[0], members: members.rows, myRole: mem.rows[0].role });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Groups: messages ──────────────────────────────────────────────
app.post('/api/groups/:id/messages', auth, messageRateLimit, async (req, res) => {
  const groupId = req.params.id;
  const senderId = req.user.id;
  const { text, replyToId, fileUrl, fileName, fileType, clientMessageId } = req.body || {};
  if (text && moderateChatText(text).blocked) {
    recordBlockedChat(senderId, 'group_http', text, groupId, clientIp(req));
    return res.status(422).json({
      error: 'ההודעה נחסמה משום שהיא כוללת תוכן פוגעני או אסור',
      code: 'CHAT_CONTENT_BLOCKED',
    });
  }
  if (!text && !fileUrl)
    return res.status(400).json({ error: 'חסר תוכן להודעה' });
  try {
    const pool = await getPool();
    const access = await pool.query(
      `SELECT gm.role, g.send_permission, g.name AS group_name
       FROM group_members gm JOIN groups g ON g.id=gm.group_id
       WHERE gm.group_id=$1 AND gm.user_id=$2 AND gm.status='member'`,
      [groupId, senderId]);
    const member = access.rows[0];
    if (!member) return res.status(403).json({ error: 'לא חבר פעיל בקבוצה' });
    if (member.send_permission === 'admin' && member.role !== 'admin')
      return res.status(403).json({ error: 'רק מנהלי הקבוצה רשאים לשלוח הודעות' });

    const type = fileType && fileType !== 'text'
      ? fileType
      : (fileUrl && fileName && /\.(jpg|jpeg|png|gif|webp)$/i.test(fileName)
        ? 'image' : fileUrl ? 'document' : 'text');
    if (fileUrl && !await validateApprovedFile(
        pool, senderId, fileUrl, 'group', groupId)) {
      return res.status(403).json({
        error: 'הקובץ לא עבר סריקה ואישור עבור קבוצה זו',
      });
    }

    const saved = await pool.query(
      `INSERT INTO messages (sender_id, group_id, body, type, file_url, file_name, reply_to_id)
       VALUES ($1, $2, $3, $4, $5, $6, $7)
       RETURNING id, created_at`,
      [senderId, groupId, text || null, type, fileUrl || null,
       fileName || null, replyToId || null]);
    const row = saved.rows[0];
    const payload = {
      id: row.id,
      groupId,
      fromUserId: senderId,
      fromName: req.user.name,
      text: text || null,
      fileUrl: fileUrl || null,
      fileName: fileName || null,
      fileType: type,
      replyToId: replyToId || null,
      clientMessageId: clientMessageId || null,
      createdAt: row.created_at,
    };
    io.to(`group:${groupId}`).emit('group:message', payload);

    const allMembers = await pool.query(
      `SELECT user_id FROM group_members
       WHERE group_id=$1 AND status='member'`, [groupId]);
    const pushBody = fileUrl ? `📎 ${fileName || 'קובץ'}` : (text || '');
    for (const { user_id } of allMembers.rows) {
      if (user_id !== senderId) {
        sendPush(user_id, `${member.group_name} • ${req.user.name}`,
          pushBody, { type: 'group', groupId });
      }
    }
    logActivity(senderId, fileUrl ? 'send_file' : 'send_group_message', {
      groupId, messageId: row.id, fileName: fileName || null,
    }, req.ip);
    res.json({ id: row.id, createdAt: row.created_at, status: 'sent' });
  } catch (e) {
    console.error('POST /api/groups/:id/messages:', e.message);
    res.status(500).json({ error: e.message });
  }
});

app.get('/api/groups/:id/messages', auth, async (req, res) => {
  const before = req.query.before;
  try {
    const pool = await getPool();
    const check = await pool.query(
      `SELECT 1 FROM group_members
       WHERE group_id=$1 AND user_id=$2 AND status='member'`,
      [req.params.id, req.user.id]);
    if (!check.rows.length)
      return res.status(403).json({ error: 'לא חבר פעיל בקבוצה' });

    const result = await pool.query(`
      SELECT
        m.id, m.sender_id, m.type, m.body, m.file_url, m.file_name, m.reply_to_id, m.created_at,
        u.name AS sender_name,
        r.body AS reply_body,
        CASE WHEN ms.status = 'read' THEN 1 ELSE 0 END AS is_read
      FROM messages m
      JOIN users u ON m.sender_id = u.id
      LEFT JOIN messages r ON m.reply_to_id = r.id
      LEFT JOIN message_status ms ON ms.message_id=m.id AND ms.user_id=$2
      WHERE m.group_id = $1 AND m.deleted_for_everyone = FALSE
        AND m.created_at >= (
          SELECT gm.joined_at FROM group_members gm
          WHERE gm.group_id=$1 AND gm.user_id=$2
        )
      ${before ? 'AND m.created_at < $3' : ''}
      ORDER BY m.created_at DESC
      LIMIT 50
    `, before ? [req.params.id, req.user.id, new Date(before)] :
       [req.params.id, req.user.id]);
    const scanParams = [req.params.id, req.user.id];
    if (before) scanParams.push(new Date(before));
    const scans = await pool.query(`
      SELECT
        'scan_' || sf.id::text AS id,
        sf.user_id AS sender_id,
        sf.file_type AS type,
        sf.original_name AS body,
        sf.public_url AS file_url,
        sf.original_name AS file_name,
        NULL::uuid AS reply_to_id,
        sf.created_at,
        u.name AS sender_name,
        NULL::text AS reply_body,
        0 AS is_read,
        CASE WHEN sf.moderation_status='rejected'
          THEN 'rejected_scan' ELSE 'pending_scan' END AS message_status,
        sf.moderation_details->>'reason' AS scan_reason
      FROM stored_files sf
      JOIN users u ON u.id=sf.user_id
      WHERE sf.context_type='group' AND sf.context_id=$1
        AND sf.user_id=$2
        AND sf.moderation_status IN ('pending','rejected')
        ${before ? 'AND sf.created_at < $3' : ''}
      ORDER BY sf.created_at DESC
      LIMIT 50
    `, scanParams);
    const combined = [...result.rows, ...scans.rows]
      .sort((a, b) => new Date(a.created_at) - new Date(b.created_at))
      .slice(-50);
    res.json(combined);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Groups: invite a registered user (admin) ─────────────────
app.post('/api/groups/:id/members', auth, async (req, res) => {
  const { userId } = req.body;
  if (!userId) return res.status(400).json({ error: 'נדרש userId' });
  try {
    const pool = await getPool();
    // Check caller is admin
    const isAdmin = await pool.query(
      `SELECT 1 FROM group_members WHERE group_id=$1 AND user_id=$2 AND role='admin'`,
      [req.params.id, req.user.id]);
    if (!isAdmin.rows.length) return res.status(403).json({ error: 'אין הרשאה' });

    // Check existing membership
    const existing = await pool.query(
      `SELECT status FROM group_members WHERE group_id=$1 AND user_id=$2`, [req.params.id, userId]);
    if (existing.rows.length) {
      const st = existing.rows[0].status;
      if (st === 'member')  return res.json({ ok: true, alreadyMember: true });
      if (st === 'pending') return res.json({ ok: true, alreadyPending: true });
    }

    // Selecting a user only creates an invitation. Membership becomes active
    // after the invited user explicitly accepts it via POST /groups/:id/join.
    await pool.query(
      `INSERT INTO group_members (group_id, user_id, status, added_by, pending_since)
       VALUES ($1, $2, 'pending', $3, now())
       ON CONFLICT (group_id, user_id) DO UPDATE SET status='pending', added_by=$3, pending_since=now()`,
      [req.params.id, userId, req.user.id]);

    // Fetch group name and adder name
    const [grpRes, adderRes] = await Promise.all([
      pool.query('SELECT name FROM groups WHERE id=$1', [req.params.id]),
      pool.query('SELECT name FROM users WHERE id=$1', [req.user.id]),
    ]);
    const groupName   = grpRes.rows[0]?.name   || 'קבוצה';
    const addedByName = adderRes.rows[0]?.name || 'מנהל';

    // Emit socket event to invited user
    const ioInst = req.app.get('io');
    const invitedSid = onlineUsers.get(userId);
    if (invitedSid) {
      ioInst.to(invitedSid).emit('group:invited', {
        groupId: req.params.id, groupName, addedByName, addedById: req.user.id,
        status: 'pending',
      });
    }

    // Send push notification
    sendPush(userId, groupName, `${addedByName} הזמין אותך לקבוצה`,
      { type: 'group_invite', groupId: req.params.id });

    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Groups: remove member (admin) ────────────────────────────────
app.delete('/api/groups/:id/members/:userId', auth, async (req, res) => {
  try {
    const pool = await getPool();
    const isAdmin = await pool.query(
      `SELECT 1 FROM group_members WHERE group_id=$1 AND user_id=$2 AND role='admin'`,
      [req.params.id, req.user.id]);
    if (!isAdmin.rows.length) return res.status(403).json({ error: 'אין הרשאה' });
    await pool.query(
      'DELETE FROM group_members WHERE group_id=$1 AND user_id=$2', [req.params.id, req.params.userId]);
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Groups: invite registered user (redirect to pending logic) ─────
app.post('/api/groups/:id/invite-message', auth, async (req, res) => {
  // Delegate to the same add-as-pending logic as POST /members
  req.url = `/api/groups/${req.params.id}/members`;
  // Just forward by calling the members handler inline
  const { userId } = req.body;
  if (!userId) return res.status(400).json({ error: 'נדרש userId' });
  try {
    const pool = await getPool();
    const isAdmin = await pool.query(
      `SELECT 1 FROM group_members WHERE group_id=$1 AND user_id=$2 AND role='admin'`,
      [req.params.id, req.user.id]);
    if (!isAdmin.rows.length) return res.status(403).json({ error: 'אין הרשאה' });

    const existing = await pool.query(
      `SELECT status FROM group_members WHERE group_id=$1 AND user_id=$2`, [req.params.id, userId]);
    if (existing.rows.length) {
      const st = existing.rows[0].status;
      if (st === 'member')  return res.json({ ok: true, alreadyMember: true });
      if (st === 'pending') return res.json({ ok: true, alreadyPending: true });
    }

    await pool.query(
      `INSERT INTO group_members (group_id, user_id, status, added_by, pending_since)
       VALUES ($1, $2, 'pending', $3, now())
       ON CONFLICT (group_id, user_id) DO UPDATE SET status='pending', added_by=$3, pending_since=now()`,
      [req.params.id, userId, req.user.id]);

    const [grpRes, adderRes] = await Promise.all([
      pool.query('SELECT name FROM groups WHERE id=$1', [req.params.id]),
      pool.query('SELECT name FROM users WHERE id=$1', [req.user.id]),
    ]);
    const groupName   = grpRes.rows[0]?.name   || 'קבוצה';
    const addedByName = adderRes.rows[0]?.name || 'מנהל';

    const ioInst = req.app.get('io');
    const invitedSid = onlineUsers.get(userId);
    if (invitedSid) {
      ioInst.to(invitedSid).emit('group:invited', {
        groupId: req.params.id, groupName, addedByName, addedById: req.user.id,
      });
    }
    sendPush(userId, groupName, `${addedByName} הוסיף אותך לקבוצה`,
      { type: 'group_invite', groupId: req.params.id });
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Groups: accept pending invite (join) ──────────────────────────
app.post('/api/groups/:id/join', auth, async (req, res) => {
  try {
    const pool = await getPool();

    // Get pending_since timestamp before updating
    const pendingRow = await pool.query(
      `SELECT status, pending_since FROM group_members
       WHERE group_id=$1 AND user_id=$2`, [req.params.id, req.user.id]);

    const wasPending = pendingRow.rows[0]?.status === 'pending';
    const pendingSince = pendingRow.rows[0]?.pending_since || null;

    if (!wasPending) {
      if (pendingRow.rows[0]?.status === 'member')
        return res.json({ ok: true, missedMessages: [] });
      return res.status(403).json({ error: 'לא קיימת הזמנה פעילה לקבוצה' });
    }

    // Only an existing invitation can become an active membership.
    await pool.query(
      `UPDATE group_members SET status='member'
       WHERE group_id=$1 AND user_id=$2 AND status='pending'`,
      [req.params.id, req.user.id]);

    // Fetch missed messages since pending_since
    let missedMessages = [];
    if (wasPending && pendingSince) {
      const missedRes = await pool.query(
        `SELECT m.id, m.sender_id, m.type, m.body, m.file_url, m.file_name,
                m.reply_to_id, m.created_at,
                u.name AS sender_name,
                r.body AS reply_body
         FROM messages m
         JOIN users u ON m.sender_id = u.id
         LEFT JOIN messages r ON m.reply_to_id = r.id
         WHERE m.group_id = $1 AND m.deleted_for_everyone = FALSE
           AND m.created_at >= $2
         ORDER BY m.created_at ASC`, [req.params.id, new Date(pendingSince)]);
      missedMessages = missedRes.rows;
    }

    // Emit group:member_joined to the group room
    const ioInst = req.app.get('io');
    ioInst.to(`group:${req.params.id}`).emit('group:member_joined', {
      groupId: req.params.id, userId: req.user.id, name: req.user.name,
    });

    res.json({ ok: true, missedMessages });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Groups: decline pending invite ───────────────────────────────
app.delete('/api/groups/:id/decline', auth, async (req, res) => {
  try {
    const pool = await getPool();
    await pool.query(
      `DELETE FROM group_members WHERE group_id=$1 AND user_id=$2 AND status='pending'`,
      [req.params.id, req.user.id]);
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Groups: invite an unregistered contact (email preferred, SMS fallback) ──
app.post('/api/groups/:id/invite-sms', auth, inviteRateLimit, async (req, res) => {
  const { phone, email, contactName } = req.body;
  const cleanPhone = String(phone || '').replace(/\D/g, '');
  const cleanEmail = String(email || '').trim().toLowerCase();
  if (!cleanPhone && !cleanEmail.includes('@'))
    return res.status(400).json({ error: 'נדרש אימייל או מספר טלפון' });
  try {
    const pool = await getPool();
    const [adminCheck, grp] = await Promise.all([
      pool.query(
        `SELECT 1 FROM group_members WHERE group_id=$1 AND user_id=$2 AND role='admin'`,
        [req.params.id, req.user.id]),
      pool.query('SELECT name FROM groups WHERE id=$1', [req.params.id]),
    ]);
    if (!adminCheck.rows.length) return res.status(403).json({ error: 'אין הרשאה' });

    const groupName  = grp.rows[0]?.name || 'הקבוצה';
    const senderName = req.user.name || 'חבר';
    const greeting   = contactName ? `שלום ${contactName}!` : 'שלום!';
    const msg = `${greeting} ${senderName} מזמין אותך להצטרף לקבוצה "${groupName}" באפליקציית בתשובה. לפרטים ולהצטרפות: https://betshuva.com/betshuva-app/home.html`;

    const existing = await pool.query(
      `SELECT id FROM external_group_invites WHERE group_id=$1 AND status='pending'
       AND (($2 <> '' AND lower(email)=$2) OR ($3 <> '' AND phone=$3)) LIMIT 1`,
      [req.params.id, cleanEmail.includes('@') ? cleanEmail : '', cleanPhone]);
    if (!existing.rows.length) {
      await pool.query(
        `INSERT INTO external_group_invites(group_id,invited_by,email,phone,contact_name)
         VALUES($1,$2,$3,$4,$5)`,
        [req.params.id, req.user.id, cleanEmail.includes('@') ? cleanEmail : null,
         cleanPhone || null, contactName || null]);
    }
    await mailer.sendMail({
      from:    `"בתשובה" <${process.env.EMAIL_FROM}>`,
      to:      cleanEmail.includes('@') ? cleanEmail : `${cleanPhone}@019sms.co.il`,
      subject: cleanEmail.includes('@') ? `הזמנה לקבוצה "${groupName}" בבתשובה` : msg,
      text:    msg,
    });

    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Groups: leave ─────────────────────────────────────────────────
app.delete('/api/groups/:id/leave', auth, async (req, res) => {
  try {
    const pool = await getPool();
    await pool.query('DELETE FROM group_members WHERE group_id=$1 AND user_id=$2', [req.params.id, req.user.id]);
    logActivity(req.user.id, 'leave_group', { groupId: req.params.id }, req.ip);
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Groups: delete group permanently (admin only) ────────────────
app.delete('/api/groups/:id', auth, async (req, res) => {
  const groupId = req.params.id;
  let client;
  try {
    const pool = await getPool();
    client = await pool.connect();
    const admin = await client.query(
      `SELECT g.name FROM groups g
       JOIN group_members gm ON gm.group_id=g.id
       WHERE g.id=$1 AND gm.user_id=$2 AND gm.role='admin'`,
      [groupId, req.user.id]);
    if (!admin.rows.length)
      return res.status(403).json({ error: 'רק מנהל הקבוצה יכול למחוק אותה' });

    const members = await client.query(
      'SELECT user_id FROM group_members WHERE group_id=$1', [groupId]);
    await client.query('BEGIN');
    await client.query(
      `DELETE FROM message_status WHERE message_id IN
       (SELECT id FROM messages WHERE group_id=$1)`, [groupId]);
    await client.query('DELETE FROM messages WHERE group_id=$1', [groupId]);
    await client.query('DELETE FROM pending_scans WHERE group_id=$1', [groupId]);
    await client.query('DELETE FROM group_members WHERE group_id=$1', [groupId]);
    await client.query('DELETE FROM groups WHERE id=$1', [groupId]);
    await client.query('COMMIT');

    for (const { user_id } of members.rows) {
      const sid = onlineUsers.get(user_id);
      if (sid) io.to(sid).emit('group:deleted', {
        groupId,
        groupName: admin.rows[0].name,
      });
    }
    logActivity(req.user.id, 'delete_group', {
      groupId, name: admin.rows[0].name,
    }, req.ip);
    res.json({ ok: true });
  } catch (e) {
    if (client) try { await client.query('ROLLBACK'); } catch (_) {}
    res.status(500).json({ error: e.message });
  } finally {
    client?.release();
  }
});

// ── Groups: update settings (admin) ──────────────────────────────
app.put('/api/groups/:id', auth, async (req, res) => {
  const { name, description, send_permission, filter_level, is_broadcast, profile_pic_url } = req.body;
  if (!name) return res.status(400).json({ error: 'נדרש שם' });
  try {
    const pool = await getPool();
    const isAdmin = await pool.query(
      `SELECT 1 FROM group_members WHERE group_id=$1 AND user_id=$2 AND role='admin'`,
      [req.params.id, req.user.id]);
    if (!isAdmin.rows.length) return res.status(403).json({ error: 'אין הרשאה' });
    await pool.query(
      `UPDATE groups SET name=$1, description=$2,
       send_permission=$3, filter_level=$4, is_broadcast=$5, profile_pic_url=$6
       WHERE id=$7`,
      [name, description || '', send_permission || 'all', filter_level || 'standard',
       !!is_broadcast, profile_pic_url || null, req.params.id]);
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Groups: update profile picture (admin) ───────────────────────
app.put('/api/groups/:id/photo', auth, async (req, res) => {
  try {
    const pool = await getPool();
    const updated = await pool.query(
      `UPDATE groups g SET profile_pic_url=$1
       WHERE g.id=$2 AND EXISTS (
         SELECT 1 FROM group_members gm
         WHERE gm.group_id=g.id AND gm.user_id=$3 AND gm.role='admin'
       ) RETURNING profile_pic_url`,
      [req.body.profile_pic_url || null, req.params.id, req.user.id]);
    if (!updated.rows.length) return res.status(403).json({ error: 'אין הרשאה' });
    res.json(updated.rows[0]);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Save game ────────────────────────────────────────────────────
app.post('/api/games', auth, async (req, res) => {
  const { player1_id, player2_id, winner_id, result, board } = req.body;
  try {
    const pool = await getPool();
    await pool.query(
      `INSERT INTO games (player1_id, player2_id, winner_id, result, board)
       VALUES ($1, $2, $3, $4, $5)`,
      [player1_id, player2_id, winner_id || null, result, board.join(',')]);

    if (result === 'win' && winner_id) {
      await pool.query('UPDATE users SET wins = wins + 1, games_played = games_played + 1 WHERE id = $1', [winner_id]);
      const loserId = winner_id === player1_id ? player2_id : player1_id;
      await pool.query('UPDATE users SET games_played = games_played + 1 WHERE id = $1', [loserId]);
    } else if (result === 'tie') {
      await pool.query('UPDATE users SET games_played = games_played + 1 WHERE id IN ($1, $2)', [player1_id, player2_id]);
    }

    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// ── Admin: activity log ───────────────────────────────────────────
app.get('/api/admin/activity', adminAuth, async (req, res) => {
  const limit  = Math.min(parseInt(req.query.limit  || 100), 500);
  const offset = parseInt(req.query.offset || 0);
  const userId = req.query.userId || null;
  const action = req.query.action || null;
  const search = req.query.search || null;
  const rowFrom = offset + 1;
  const rowTo   = offset + limit;
  try {
    const pool = await getPool();
    const params = [];
    const addParam = (v) => { params.push(v); return `$${params.length}`; };
    const userIdFilter = userId ? `AND a.user_id = ${addParam(userId)}` : '';
    const actionFilter = action ? `AND a.action  = ${addParam(action)}` : '';
    const searchFilter = search ? `AND (u.name ILIKE ${addParam(`%${search}%`)} OR u.email ILIKE $${params.length})` : '';
    const result = await pool.query(`
      SELECT id, action, details, ip, created_at, user_name, user_email
      FROM (
        SELECT a.id, a.action, a.details, a.ip, a.created_at,
               u.name AS user_name, u.email AS user_email,
               ROW_NUMBER() OVER (ORDER BY a.created_at DESC) AS _rn
        FROM activity_log a
        LEFT JOIN users u ON u.id = a.user_id
        WHERE 1=1 ${userIdFilter} ${actionFilter} ${searchFilter}
      ) AS _q
      WHERE _q._rn >= ${rowFrom} AND _q._rn <= ${rowTo}
      ORDER BY _q._rn
    `, params);
    res.json(result.rows);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.get('/api/admin/reports', adminAuth, async (req, res) => {
  const status = String(req.query.status || 'pending');
  const allowed = new Set(['pending', 'reviewed', 'resolved', 'dismissed', 'all']);
  if (!allowed.has(status)) return res.status(400).json({ error: 'סטטוס לא תקין' });
  try {
    const pool = await getPool();
    const result = await pool.query(
      `SELECT r.*, u.name AS reporter_name, u.email AS reporter_email
       FROM user_reports r JOIN users u ON u.id=r.reporter_id
       WHERE ($1='all' OR r.status=$1)
       ORDER BY r.created_at DESC LIMIT 500`, [status]);
    res.json(result.rows);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.put('/api/admin/reports/:id', adminAuth, async (req, res) => {
  const status = String(req.body.status || '');
  if (!['reviewed', 'resolved', 'dismissed'].includes(status))
    return res.status(400).json({ error: 'סטטוס לא תקין' });
  try {
    const pool = await getPool();
    const result = await pool.query(
      `UPDATE user_reports SET status=$1,reviewed_by=$2,reviewed_at=now()
       WHERE id=$3 RETURNING *`, [status, req.user.id, req.params.id]);
    if (!result.rows.length) return res.status(404).json({ error: 'דיווח לא נמצא' });
    res.json(result.rows[0]);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Admin: all users ─────────────────────────────────────────────
app.get('/api/admin/users', adminAuth, async (req, res) => {
  try {
    const pool = await getPool();
    const result = await pool.query(
      `SELECT id, name, email, phone, email_verified, phone_verified,
              google_id, profile_pic_url, city,
              filter_level, created_at
       FROM users ORDER BY created_at DESC`);
    res.json(result.rows);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Admin: all games ─────────────────────────────────────────────
app.get('/api/admin/games', adminAuth, async (req, res) => {
  try {
    const pool = await getPool();
    const result = await pool.query(`
      SELECT g.id, g.result, g.board, g.played_at,
             p1.name AS player1, p2.name AS player2,
             w.name AS winner
      FROM games g
      JOIN users p1 ON g.player1_id = p1.id
      JOIN users p2 ON g.player2_id = p2.id
      LEFT JOIN users w ON g.winner_id = w.id
      ORDER BY g.played_at DESC
    `);
    res.json(result.rows);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Leaderboard ──────────────────────────────────────────────────
app.get('/api/leaderboard', auth, async (req, res) => {
  try {
    const pool = await getPool();
    const result = await pool.query('SELECT name, email, wins, games_played FROM users ORDER BY wins DESC');
    res.json(result.rows);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// ── Send OTP via SMS (019 email gateway) ────────────────────────
app.post('/api/send-otp', authRateLimit, otpRateLimit, async (req, res) => {
  const { phone, name, email, gender } = req.body;
  if (!phone) return res.status(400).json({ error: 'נדרש מספר טלפון' });
  const clean      = phone.replace(/\D/g, '');
  const cleanName = typeof name === 'string'
    ? name.replace(/[\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]/g, '').trim()
    : '';
  const cleanEmail = (email || '').toLowerCase().trim();
  if (clean.length < 9) return res.status(400).json({ error: 'מספר טלפון לא תקין' });
  try {
    const pool = await getPool();
    const existingPhone = await pool.query(
      'SELECT 1 FROM users WHERE phone=$1', [clean]);
    let authenticatedUser = false;
    const bearer = req.headers.authorization?.split(' ')[1];
    if (bearer) {
      try {
        const tokenUser = jwt.verify(bearer, JWT_SECRET);
        const exists = await pool.query('SELECT 1 FROM users WHERE id=$1', [tokenUser.id]);
        authenticatedUser = exists.rows.length > 0;
      } catch (_) {}
    }
    if (!existingPhone.rows.length && !authenticatedUser) {
      if (cleanName.length < 2)
        return res.status(400).json({ error: 'משתמש חדש חייב להזין שם מלא' });
      if (req.body.acceptedTerms !== true || req.body.ageConfirmed !== true)
        return res.status(400).json({ error: 'יש לאשר תנאים וגיל 13 ומעלה' });
      if (!['male', 'female'].includes(gender))
        return res.status(400).json({ error: 'יש לבחור מגדר' });
    }
  } catch (e) {
    return res.status(500).json({ error: e.message });
  }
  if (cleanEmail.includes('@')) {
    try {
      const pool = await getPool();
      const emailExists = await pool.query(
        'SELECT id FROM users WHERE email=$1 AND phone != $2', [cleanEmail, clean]);
      if (emailExists.rows.length)
        return res.status(400).json({ error: 'כתובת האימייל כבר רשומה' });
    } catch (_) {}
  }
  const code    = Math.floor(100000 + Math.random() * 900000).toString();
  const expires = Date.now() + 5 * 60 * 1000;
  otpStore.set(clean, { code, expires, name: cleanName, email: cleanEmail,
    acceptedTerms: req.body.acceptedTerms === true,
    ageConfirmed: req.body.ageConfirmed === true,
    gender: ['male', 'female'].includes(gender) ? gender : null });
  try {
    await sendEmail({
      to:      `${clean}@019sms.co.il`,
      subject: `קוד האימות שלך לבתשובה: ${code}`,
      html:    '',
    });
    res.json({ ok: true });
  } catch (e) {
    console.error('SMS error:', e.message);
    res.status(500).json({ error: 'שגיאה בשליחת SMS: ' + e.message });
  }
});

// ── Verify OTP ───────────────────────────────────────────────────
app.post('/api/verify-otp', authRateLimit, credentialRateLimit, async (req, res) => {
  const { phone, code, name } = req.body;
  const clean = (phone || '').replace(/\D/g, '');
  const entry = otpStore.get(clean);
  if (!entry || entry.code !== code || Date.now() > entry.expires)
    return res.status(400).json({ error: 'קוד שגוי או פג תוקף' });
  const requestedName = typeof name === 'string' ? name.trim() : '';
  const userName  = requestedName || entry.name || '';
  const userEmail = entry.email || `${clean}@betshuva.app`;
  try {
    const pool = await getPool();
    // Check existing user by phone
    const byPhone = await pool.query(
      `SELECT id, name, email FROM users WHERE phone=$1
       ORDER BY phone_verified DESC, created_at DESC LIMIT 1`, [clean]);
    let user;
    if (byPhone.rows.length) {
      otpStore.delete(clean);
      user = byPhone.rows[0];
      await pool.query('UPDATE users SET phone_verified=TRUE, email_verified=TRUE WHERE id=$1', [user.id]);
    } else {
      // Check by email
      const byEmail = await pool.query(
        'SELECT id, name, email FROM users WHERE lower(email)=lower($1) ORDER BY email_verified DESC LIMIT 1',
        [userEmail]);
      if (byEmail.rows.length) {
        otpStore.delete(clean);
        user = byEmail.rows[0];
        await pool.query(
          'UPDATE users SET phone_verified=TRUE, email_verified=TRUE, phone=$1 WHERE id=$2', [clean, user.id]);
      } else {
        // New user — verified by OTP
        if (entry.acceptedTerms !== true || entry.ageConfirmed !== true)
          return res.status(400).json({ error: 'יש לאשר תנאים וגיל 13 ומעלה' });
        if (userName.length < 2) {
          return res.status(400).json({ error: 'משתמש חדש חייב להזין שם מלא' });
        }
        if (!['male', 'female'].includes(entry.gender))
          return res.status(400).json({ error: 'יש לבחור מגדר' });
        otpStore.delete(clean);
        const hash   = await bcrypt.hash(`otp_${clean}`, 10);
        const result = await pool.query(
          `INSERT INTO users (name, email, phone, password_hash, phone_verified, email_verified,
                              terms_accepted_at, terms_version, age_confirmed, gender)
           VALUES ($1, $2, $3, $4, TRUE, TRUE, now(), '2026-08-18', TRUE, $5)
           RETURNING id, name, email`,
          [userName, userEmail, clean, hash, entry.gender]);
        user = result.rows[0];
        // הודע לכל המחוברים על משתמש חדש
        req.app.get('io').emit('users:new', {
          id: user.id, name: user.name, email: user.email, profile_pic_url: null
        });
      }
    }
    const token = jwt.sign({ id: user.id, name: user.name, email: user.email }, JWT_SECRET);
    logActivity(user.id, 'otp_login', { phone: clean }, null);
    res.json({ token, user });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// ── Link Phone to existing account (after Google sign-in) ───────
app.post('/api/link-phone', auth, otpRateLimit, async (req, res) => {
  const { phone, code } = req.body;
  const clean = (phone || '').replace(/\D/g, '');
  if (clean.length < 9) return res.status(400).json({ error: 'מספר טלפון לא תקין' });
  try {
    const pool = await getPool();
    const account = await pool.query(
      'SELECT email_verified FROM users WHERE id=$1', [req.user.id]);
    const canSkipSms = account.rows[0]?.email_verified === true;
    if (!canSkipSms) {
      if (!code) return res.status(400).json({ error: 'נדרש קוד אימות' });
      const entry = otpStore.get(clean);
      if (!entry || entry.code !== code || Date.now() > entry.expires)
        return res.status(400).json({ error: 'קוד שגוי או פג תוקף' });
      otpStore.delete(clean);
    }
    const taken = await pool.query('SELECT id FROM users WHERE phone=$1 AND id != $2', [clean, req.user.id]);
    if (taken.rows.length)
      return res.status(400).json({ error: 'מספר הטלפון כבר רשום למשתמש אחר' });
    await pool.query(
      `UPDATE users SET phone=$1,
       phone_verified=CASE WHEN $3 THEN phone_verified ELSE TRUE END
       WHERE id=$2`, [clean, req.user.id, canSkipSms]);
    logActivity(req.user.id, 'link_phone', { phone: clean }, req.ip);
    const userResult = await pool.query('SELECT id, name, email FROM users WHERE id=$1', [req.user.id]);
    const user = userResult.rows[0];
    const token = jwt.sign({ id: user.id, name: user.name, email: user.email }, JWT_SECRET);
    res.json({ ok: true, token });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Verify Phone (after registration) ───────────────────────────
app.post('/api/verify-phone', authRateLimit, credentialRateLimit, async (req, res) => {
  const { phone, code } = req.body;
  const cleanPhone = (phone || '').replace(/\D/g, '');
  const entry = otpStore.get(cleanPhone);
  if (!entry || entry.code !== code || Date.now() > entry.expires)
    return res.status(400).json({ error: 'קוד שגוי או פג תוקף' });
  otpStore.delete(cleanPhone);
  try {
    const pool = await getPool();
    const candidates = await pool.query(
      `SELECT id, name, email, email_verified, phone_verified
       FROM users WHERE phone=$1
       ORDER BY phone_verified DESC, created_at DESC`, [cleanPhone]);
    const verified = candidates.rows.find(user => user.phone_verified === true);
    const user = verified || candidates.rows[0];
    if (!user) return res.status(400).json({ error: 'משתמש לא נמצא' });
    await pool.query('UPDATE users SET phone_verified=TRUE WHERE id=$1', [user.id]);
    const result = await pool.query(
      'SELECT id, name, email, email_verified FROM users WHERE id=$1', [user.id]);
    const verifiedUser = result.rows[0];
    const token = jwt.sign({ id: verifiedUser.id, name: verifiedUser.name, email: verifiedUser.email }, JWT_SECRET);
    res.json({ ok: true, token });
  } catch (e) {
    if (e.code === '23505')
      return res.status(409).json({ error: 'מספר הטלפון כבר משויך למשתמש מאומת אחר' });
    res.status(500).json({ error: e.message });
  }
});

// ── Verify Email (HTML page) ─────────────────────────────────────
app.get('/verify-email', async (req, res) => {
  const token = (req.query.token || '').replace(/[^a-f0-9]/g, '');
  const ok = (msg, redirectUrl = null) => res.send(`<!DOCTYPE html><html dir="rtl" lang="he"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>אימות אימייל – בתשובה</title><style>body{font-family:Arial,sans-serif;background:#F0F4F0;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0}.card{background:#fff;padding:36px;border-radius:16px;box-shadow:0 4px 24px rgba(0,0,0,.1);max-width:400px;text-align:center}h2{color:#1B4332}</style></head><body><div class="card">${msg}</div>${redirectUrl ? `<script>setTimeout(function(){location.href=${JSON.stringify(redirectUrl)}},1200)</script>` : ''}</body></html>`);
  try {
    const pool = await getPool();
    const result = await pool.query(
      'SELECT user_id FROM email_verification_tokens WHERE token = $1 AND used = FALSE AND expires_at > now()',
      [token]);
    if (!result.rows.length)
      return ok('<h2>❌ הקישור לא תקין או פג תוקף</h2><p>נסה להירשם מחדש.</p>');
    const { user_id } = result.rows[0];
    const target = await pool.query('SELECT email FROM users WHERE id=$1', [user_id]);
    const emailToVerify = target.rows[0]?.email;
    const owner = await pool.query(
      `SELECT id FROM users
       WHERE email_verified=TRUE AND lower(email)=lower($1) AND id<>$2`,
      [emailToVerify, user_id]);
    if (owner.rows.length)
      return ok('<h2>❌ האימייל כבר משויך למשתמש מאומת אחר</h2>');
    await pool.query('UPDATE users SET email_verified = TRUE WHERE id = $1', [user_id]);
    await pool.query('UPDATE email_verification_tokens SET used = TRUE WHERE token = $1', [token]);
    const userResult = await pool.query('SELECT email FROM users WHERE id=$1', [user_id]);
    const email = userResult.rows[0]?.email || '';
    const base = process.env.APP_URL || 'https://betshuva.com/betshuva-app';
    const redirectUrl = `${base}/?verifiedEmail=${encodeURIComponent(email)}`;
    ok('<h2>✅ האימייל אומת בהצלחה!</h2><p>מעבירים אותך למסך הכניסה...</p>', redirectUrl);
  } catch (e) { ok('<h2>❌ שגיאה</h2><p>' + e.message + '</p>'); }
});

// ── Admin DB Dashboard ────────────────────────────────────────────

const ADMIN_TABLES = {
  users:             { label: 'משתמשים',     pk: 'id',        hide: ['password_hash'], sort: 'created_at DESC' },
  groups:            { label: 'קבוצות',       pk: 'id',        hide: [],                sort: 'created_at DESC' },
  group_members:     { label: 'חברי קבוצות', pk: null,        hide: [],                sort: null },
  messages:          { label: 'הודעות',       pk: 'id',        hide: [],                sort: 'created_at DESC' },
  message_status:    { label: 'סטטוס הודעות', pk: null,       hide: [],                sort: null },
  blocked_users:     { label: 'חסומים',       pk: null,        hide: [],                sort: null },
  fcm_tokens:        { label: 'FCM Tokens',  pk: 'id',        hide: ['token'],          sort: null },
  activity_log:      { label: 'פעילות',       pk: 'id',        hide: [],                sort: 'created_at DESC' },
  audit_log:         { label: 'אודיט',        pk: 'id',        hide: [],                sort: 'created_at DESC' },
  admin_permissions: { label: 'הרשאות מנהל', pk: 'user_id',  hide: [],                sort: 'granted_at DESC' },
};

async function adminAuth(req, res, next) {
  const header = req.headers.authorization || '';
  const token  = header.replace('Bearer ', '');
  if (!token) return res.status(401).json({ error: 'לא מחובר' });
  try {
    req.user = jwt.verify(token, JWT_SECRET);
    const pool   = await getPool();
    const result = await pool.query('SELECT permission FROM admin_permissions WHERE user_id = $1', [req.user.id]);
    if (!result.rows.length)
      return res.status(403).json({ error: 'אין הרשאת גישה לדשבורד' });
    req.adminPerm = result.rows[0].permission; // 'view' or 'edit'
    next();
  } catch {
    res.status(401).json({ error: 'טוקן לא תקין' });
  }
}

app.get('/admin-members', (_req, res) => res.sendFile(
  require('path').join(__dirname, '..', 'admin-members.html')));
app.get('/api/admin/members-directory', adminAuth, async (req, res) => {
  try {
    const pool = await getPool();
    const result = await pool.query(`
      SELECT id, name, email, phone, city,
             email_verified, phone_verified, created_at, profile_pic_url
      FROM users
      WHERE id <> $1
      ORDER BY name COLLATE "C" ASC`, [SCAN_BOT_ID]);
    res.set('Cache-Control', 'no-store, private');
    res.json({ users: result.rows, total: result.rowCount, permission: req.adminPerm });
  } catch (e) {
    res.status(500).json({ error: 'לא ניתן לטעון את רשימת המשתמשים' });
  }
});

// List tables + row counts
app.get('/api/admin/db', adminAuth, async (req, res) => {
  try {
    const pool = await getPool();
    const names = Object.keys(ADMIN_TABLES);
    const counts = await Promise.all(names.map(async t => {
      try {
        const r = await pool.query(`SELECT COUNT(*)::int AS n FROM ${t}`);
        return { table: t, label: ADMIN_TABLES[t].label, count: r.rows[0].n };
      } catch { return { table: t, label: ADMIN_TABLES[t].label, count: 0 }; }
    }));
    res.json({ tables: counts, permission: req.adminPerm });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// Get table data (paginated) — search is done in JS since there's no cheap Postgres
// equivalent to T-SQL's FOR JSON PATH row-to-text search across an arbitrary table.
app.get('/api/admin/db/:table', adminAuth, async (req, res) => {
  const cfg = ADMIN_TABLES[req.params.table];
  if (!cfg) return res.status(400).json({ error: 'טבלה לא מורשית' });
  const limit  = Math.min(parseInt(req.query.limit)  || 200, 500);
  const offset = parseInt(req.query.offset) || 0;
  const search = (req.query.search || '').trim().toLowerCase();
  try {
    const pool    = await getPool();
    const tbl     = req.params.table;
    const orderBy = cfg.sort ? `ORDER BY ${cfg.sort}` : '';
    const all = await pool.query(`SELECT * FROM ${tbl} ${orderBy}`);
    const filtered = search
      ? all.rows.filter(r => JSON.stringify(r).toLowerCase().includes(search))
      : all.rows;
    const rows = filtered.slice(offset, offset + limit).map(r => {
      const row = { ...r };
      cfg.hide.forEach(h => delete row[h]);
      return row;
    });
    res.json({ rows, total: filtered.length, permission: req.adminPerm });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// Update a row
app.put('/api/admin/db/:table/:id', adminAuth, async (req, res) => {
  if (req.adminPerm !== 'edit') return res.status(403).json({ error: 'נדרשת הרשאת עריכה' });
  const cfg = ADMIN_TABLES[req.params.table];
  if (!cfg || !cfg.pk) return res.status(400).json({ error: 'לא ניתן לערוך טבלה זו' });
  const updates = req.body;
  const safe = Object.keys(updates).filter(k => k !== cfg.pk && !cfg.hide.includes(k));
  if (!safe.length) return res.status(400).json({ error: 'אין שדות לעדכון' });
  // Validate column names against DB schema
  try {
    const pool = await getPool();
    const schema = await pool.query(
      `SELECT column_name FROM information_schema.columns WHERE table_name = $1`, [req.params.table]);
    const validCols = new Set(schema.rows.map(r => r.column_name));
    const filtered  = safe.filter(k => validCols.has(k));
    if (!filtered.length) return res.status(400).json({ error: 'עמודות לא תקינות' });
    const params = filtered.map(k => updates[k] == null ? null : String(updates[k]));
    const setClause = filtered.map((k, i) => `${k}=$${i + 1}`).join(',');
    params.push(req.params.id);
    await pool.query(`UPDATE ${req.params.table} SET ${setClause} WHERE ${cfg.pk}=$${params.length}`, params);
    logActivity(req.user.id, 'admin_edit', { table: req.params.table, id: req.params.id }, req.ip);
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// Delete a row
app.delete('/api/admin/db/:table/:id', adminAuth, async (req, res) => {
  if (req.adminPerm !== 'edit') return res.status(403).json({ error: 'נדרשת הרשאת עריכה' });
  const cfg = ADMIN_TABLES[req.params.table];
  if (!cfg || !cfg.pk) return res.status(400).json({ error: 'לא ניתן למחוק מטבלה זו' });
  try {
    const pool = await getPool();
    await pool.query(`DELETE FROM ${req.params.table} WHERE ${cfg.pk}=$1`, [req.params.id]);
    logActivity(req.user.id, 'admin_delete', { table: req.params.table, id: req.params.id }, req.ip);
    // אם נמחק משתמש — נתק אותו מיד מה-Socket
    if (req.params.table === 'users') {
      const sid = onlineUsers.get(req.params.id);
      if (sid) {
        req.app.get('io').to(sid).emit('force_logout', { reason: 'החשבון נמחק' });
        req.app.get('io').sockets.sockets.get(sid)?.disconnect(true);
        onlineUsers.delete(req.params.id);
      }
    }
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// Manage permissions
app.get('/api/admin/permissions', adminAuth, async (req, res) => {
  try {
    const pool = await getPool();
    const r = await pool.query(
      `SELECT ap.user_id, u.name, u.email, ap.permission, ap.granted_at
       FROM admin_permissions ap JOIN users u ON u.id = ap.user_id
       ORDER BY ap.granted_at`);
    res.json(r.rows);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.post('/api/admin/permissions', adminAuth, async (req, res) => {
  if (req.adminPerm !== 'edit') return res.status(403).json({ error: 'נדרשת הרשאת עריכה' });
  const { email, permission } = req.body;
  if (!['view','edit'].includes(permission)) return res.status(400).json({ error: 'הרשאה לא תקינה' });
  try {
    const pool = await getPool();
    const user = await pool.query('SELECT id FROM users WHERE email = $1', [email]);
    if (!user.rows.length) return res.status(404).json({ error: 'משתמש לא נמצא' });
    const userId = user.rows[0].id;
    await pool.query(
      `INSERT INTO admin_permissions (user_id, permission) VALUES ($1, $2)
       ON CONFLICT (user_id) DO UPDATE SET permission = $2`,
      [userId, permission]);
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.delete('/api/admin/permissions/:userId', adminAuth, async (req, res) => {
  if (req.adminPerm !== 'edit') return res.status(403).json({ error: 'נדרשת הרשאת עריכה' });
  if (req.params.userId === req.user.id) return res.status(400).json({ error: 'לא ניתן להסיר את עצמך' });
  try {
    const pool = await getPool();
    await pool.query('DELETE FROM admin_permissions WHERE user_id = $1', [req.params.userId]);
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Admin: Full User Delete ──────────────────────────────────────
async function deleteStoredFile(url) {
  try {
    const marker = `${UPLOAD_PUBLIC_BASE}/`;
    const pos = url.indexOf(marker);
    if (pos < 0) return;
    const relativePath = url.slice(pos + marker.length).split('/').map(decodeURIComponent).join(path.sep);
    const absolutePath = path.resolve(UPLOAD_ROOT, relativePath);
    if (!absolutePath.startsWith(path.resolve(UPLOAD_ROOT) + path.sep)) return;
    await fs.unlink(absolutePath).catch(e => { if (e.code !== 'ENOENT') throw e; });
    const pool = await getPool();
    await pool.query('DELETE FROM stored_files WHERE public_url=$1', [url]);
  } catch (e) {
    console.error('deleteStoredFile:', url, e.message);
  }
}

// A signed-in user can permanently delete their own account. The confirmation
// phrase protects against accidental requests and CSRF-like client mistakes.
app.delete('/api/account', auth, async (req, res) => {
  if (req.body?.confirmation !== 'DELETE')
    return res.status(400).json({ error: 'נדרש אישור מחיקה מפורש' });
  const uid = req.user.id;
  const pool = await getPool();
  const client = await pool.connect();
  let fileUrls = [];
  try {
    await client.query('BEGIN');
    const files = await client.query(
      'SELECT public_url FROM stored_files WHERE user_id=$1', [uid]);
    fileUrls = files.rows.map(row => row.public_url).filter(Boolean);
    const profile = await client.query(
      'SELECT profile_pic_url FROM users WHERE id=$1 FOR UPDATE', [uid]);
    if (!profile.rows.length) {
      await client.query('ROLLBACK');
      return res.status(404).json({ error: 'החשבון אינו קיים' });
    }
    if (profile.rows[0].profile_pic_url) fileUrls.push(profile.rows[0].profile_pic_url);

    await client.query('DELETE FROM message_status WHERE user_id=$1', [uid]);
    await client.query(`UPDATE messages SET reply_to_id=NULL WHERE reply_to_id IN
      (SELECT id FROM messages WHERE sender_id=$1 OR recipient_id=$1)`, [uid]);
    await client.query(`DELETE FROM message_status WHERE message_id IN
      (SELECT id FROM messages WHERE sender_id=$1 OR recipient_id=$1)`, [uid]);
    await client.query('DELETE FROM messages WHERE sender_id=$1 OR recipient_id=$1', [uid]);
    await client.query('DELETE FROM message_requests WHERE sender_id=$1 OR recipient_id=$1', [uid]);
    await client.query('DELETE FROM pending_scans WHERE user_id=$1 OR to_user_id=$1', [uid]);
    await client.query('DELETE FROM listing_views WHERE user_id=$1 OR listing_id IN (SELECT id FROM listings WHERE user_id=$1)', [uid]);
    await client.query('DELETE FROM listing_images WHERE listing_id IN (SELECT id FROM listings WHERE user_id=$1)', [uid]);
    await client.query('DELETE FROM listings WHERE user_id=$1', [uid]);
    await client.query('DELETE FROM fcm_tokens WHERE user_id=$1', [uid]);
    await client.query('DELETE FROM password_reset_tokens WHERE user_id=$1', [uid]);
    await client.query('DELETE FROM email_verification_tokens WHERE user_id=$1', [uid]);
    await client.query('DELETE FROM group_members WHERE user_id=$1', [uid]);
    await client.query('UPDATE groups SET creator_id=NULL WHERE creator_id=$1', [uid]);
    await client.query('DELETE FROM external_group_invites WHERE invited_by=$1', [uid]);
    await client.query('UPDATE external_group_invites SET claimed_by=NULL WHERE claimed_by=$1', [uid]);
    await client.query('DELETE FROM blocked_users WHERE blocker_id=$1 OR blocked_id=$1', [uid]);
    await client.query('DELETE FROM user_contacts WHERE owner_id=$1 OR contact_id=$1', [uid]);
    await client.query('DELETE FROM admin_permissions WHERE user_id=$1', [uid]);
    await client.query('DELETE FROM games WHERE player1_id=$1 OR player2_id=$1', [uid]);
    await client.query('UPDATE games SET winner_id=NULL WHERE winner_id=$1', [uid]);
    await client.query('DELETE FROM activity_log WHERE user_id=$1', [uid]);
    await client.query('DELETE FROM audit_log WHERE user_id=$1', [uid]);
    await client.query('DELETE FROM user_reports WHERE reporter_id=$1', [uid]);
    await client.query('UPDATE user_reports SET reviewed_by=NULL WHERE reviewed_by=$1', [uid]);
    await client.query('DELETE FROM stored_files WHERE user_id=$1', [uid]);
    await client.query('DELETE FROM users WHERE id=$1', [uid]);
    await client.query('COMMIT');
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    console.error('self account delete:', e.message);
    return res.status(500).json({ error: 'מחיקת החשבון נכשלה' });
  } finally {
    client.release();
  }

  await Promise.all([...new Set(fileUrls)].map(url => deleteStoredFile(url)));
  const sid = onlineUsers.get(uid);
  if (sid) io.sockets.sockets.get(sid)?.disconnect(true);
  onlineUsers.delete(uid);
  res.json({ ok: true });
});

// Delete the user's content and personal profile while keeping the login
// identity active. Credentials are intentionally retained so the account can
// still be used after this operation.
app.delete('/api/account/data', auth, async (req, res) => {
  if (req.body?.confirmation !== 'DELETE_DATA')
    return res.status(400).json({ error: 'נדרש אישור מחיקת נתונים מפורש' });
  const uid = req.user.id;
  const pool = await getPool();
  const client = await pool.connect();
  let fileUrls = [];
  try {
    await client.query('BEGIN');
    const files = await client.query(
      'SELECT public_url FROM stored_files WHERE user_id=$1', [uid]);
    fileUrls = files.rows.map(row => row.public_url).filter(Boolean);
    const profile = await client.query(
      'SELECT profile_pic_url FROM users WHERE id=$1 FOR UPDATE', [uid]);
    if (!profile.rows.length) {
      await client.query('ROLLBACK');
      return res.status(404).json({ error: 'החשבון אינו קיים' });
    }
    if (profile.rows[0].profile_pic_url) fileUrls.push(profile.rows[0].profile_pic_url);

    await client.query('DELETE FROM message_status WHERE user_id=$1', [uid]);
    await client.query(`UPDATE messages SET reply_to_id=NULL WHERE reply_to_id IN
      (SELECT id FROM messages WHERE sender_id=$1 OR recipient_id=$1)`, [uid]);
    await client.query(`DELETE FROM message_status WHERE message_id IN
      (SELECT id FROM messages WHERE sender_id=$1 OR recipient_id=$1)`, [uid]);
    await client.query('DELETE FROM messages WHERE sender_id=$1 OR recipient_id=$1', [uid]);
    await client.query('DELETE FROM message_requests WHERE sender_id=$1 OR recipient_id=$1', [uid]);
    await client.query('DELETE FROM pending_scans WHERE user_id=$1 OR to_user_id=$1', [uid]);
    await client.query('DELETE FROM listing_views WHERE user_id=$1 OR listing_id IN (SELECT id FROM listings WHERE user_id=$1)', [uid]);
    await client.query('DELETE FROM listing_images WHERE listing_id IN (SELECT id FROM listings WHERE user_id=$1)', [uid]);
    await client.query('DELETE FROM listings WHERE user_id=$1', [uid]);
    await client.query('DELETE FROM fcm_tokens WHERE user_id=$1', [uid]);
    await client.query('DELETE FROM group_members WHERE user_id=$1', [uid]);
    await client.query('UPDATE groups SET creator_id=NULL WHERE creator_id=$1', [uid]);
    await client.query('DELETE FROM external_group_invites WHERE invited_by=$1', [uid]);
    await client.query('UPDATE external_group_invites SET claimed_by=NULL WHERE claimed_by=$1', [uid]);
    await client.query('DELETE FROM blocked_users WHERE blocker_id=$1 OR blocked_id=$1', [uid]);
    await client.query('DELETE FROM user_contacts WHERE owner_id=$1 OR contact_id=$1', [uid]);
    await client.query('DELETE FROM games WHERE player1_id=$1 OR player2_id=$1', [uid]);
    await client.query('UPDATE games SET winner_id=NULL WHERE winner_id=$1', [uid]);
    await client.query('DELETE FROM activity_log WHERE user_id=$1', [uid]);
    await client.query('DELETE FROM audit_log WHERE user_id=$1', [uid]);
    await client.query('DELETE FROM user_reports WHERE reporter_id=$1', [uid]);
    await client.query('UPDATE user_reports SET reviewed_by=NULL WHERE reviewed_by=$1', [uid]);
    await client.query('DELETE FROM stored_files WHERE user_id=$1', [uid]);
    await client.query(`UPDATE users SET
      name='משתמש', city=NULL, country=NULL,
      street=NULL, house_number=NULL, apartment=NULL, profile_pic_url=NULL,
      latitude=NULL, longitude=NULL, location_updated_at=NULL, gender=NULL,
      wins=0, games_played=0
      WHERE id=$1`, [uid]);
    await client.query('COMMIT');
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    console.error('self data delete:', e.message);
    return res.status(500).json({ error: 'מחיקת הנתונים נכשלה' });
  } finally {
    client.release();
  }

  await Promise.all([...new Set(fileUrls)].map(url => deleteStoredFile(url)));
  res.json({ ok: true });
});

app.delete('/api/admin/users/:userId/full', adminAuth, async (req, res) => {
  if (req.adminPerm !== 'edit') return res.status(403).json({ error: 'נדרשת הרשאת עריכה' });
  const uid = req.params.userId;
  const { messages: delMsg, files: delFiles, listings: delListings,
          profilePic: delPic, fcm: delFcm, account: delAccount } = req.body;

  try {
    const pool = await getPool();
    const userRes = await pool.query('SELECT id, name, email, profile_pic_url FROM users WHERE id=$1', [uid]);
    if (!userRes.rows.length) return res.status(404).json({ error: 'משתמש לא נמצא' });
    const user = userRes.rows[0];

    const b2Urls = [];

    // Collect B2 URLs before deletion
    if (delPic && user.profile_pic_url) b2Urls.push(user.profile_pic_url);
    if (delFiles || (delAccount && delFiles)) {
      const rows = await pool.query(
        `SELECT file_url FROM messages WHERE sender_id=$1 AND file_url IS NOT NULL`, [uid]);
      rows.rows.forEach(r => b2Urls.push(r.file_url));
    }
    if (delListings && delFiles) {
      const imgs = await pool.query(
        `SELECT li.url FROM listing_images li
         JOIN listings l ON l.id=li.listing_id WHERE l.user_id=$1`, [uid]);
      imgs.rows.forEach(r => b2Urls.push(r.url));
      const main = await pool.query(
        `SELECT image_url FROM listings WHERE user_id=$1 AND image_url IS NOT NULL`, [uid]);
      main.rows.forEach(r => b2Urls.push(r.image_url));
    }

    // Helper to run a query safely
    const run = q => pool.query(q, [uid]);

    if (delMsg || delAccount) {
      // Clear reply references to messages being deleted
      await run(`UPDATE messages SET reply_to_id=NULL
                 WHERE reply_to_id IN (SELECT id FROM messages WHERE sender_id=$1 OR recipient_id=$1)`);
      await run(`DELETE FROM message_status
                 WHERE message_id IN (SELECT id FROM messages WHERE sender_id=$1 OR recipient_id=$1)`);
      await run(`DELETE FROM pending_scans WHERE user_id=$1`);
      await run(`DELETE FROM messages WHERE sender_id=$1 OR recipient_id=$1`);
    }

    if (delListings || delAccount) {
      await run(`DELETE FROM listing_views WHERE listing_id IN (SELECT id FROM listings WHERE user_id=$1)`);
      await run(`DELETE FROM listing_images WHERE listing_id IN (SELECT id FROM listings WHERE user_id=$1)`);
      await run(`DELETE FROM listings WHERE user_id=$1`);
    }

    if (delFcm || delAccount) {
      await run(`DELETE FROM fcm_tokens WHERE user_id=$1`);
    }

    if (delAccount) {
      await run(`DELETE FROM group_members WHERE user_id=$1`);
      await run(`DELETE FROM blocked_users WHERE blocker_id=$1 OR blocked_id=$1`);
      // Null nullable FKs for audit trail
      await run(`UPDATE activity_log SET user_id=NULL WHERE user_id=$1`);
      await run(`UPDATE audit_log SET user_id=NULL WHERE user_id=$1`);
      // Games: null references (no FK enforced)
      try { await run(`UPDATE games SET winner_id=NULL WHERE winner_id=$1`); } catch (_) {}
      try {
        await run(`DELETE FROM games WHERE player1_id=$1 OR player2_id=$1`);
      } catch (_) {}
      // Delete user (admin_permissions cascades)
      await run(`DELETE FROM users WHERE id=$1`);
      // Disconnect socket
      const sid = onlineUsers.get(uid);
      if (sid) {
        req.app.get('io').to(sid).emit('force_logout', { reason: 'החשבון נמחק' });
        req.app.get('io').sockets.sockets.get(sid)?.disconnect(true);
        onlineUsers.delete(uid);
      }
    }

    // Delete B2 files in background (fire-and-forget)
    const uniqueUrls = [...new Set(b2Urls.filter(Boolean))];
    uniqueUrls.forEach(url => deleteStoredFile(url).catch(() => {}));

    logActivity(req.user.id, 'admin_delete_user', {
      targetUserId: uid, name: user.name, email: user.email,
      options: { delMsg, delFiles, delListings, delPic, delFcm, delAccount },
      b2FilesQueued: uniqueUrls.length,
    }, req.ip);

    res.json({ ok: true, name: user.name, filesDeleted: uniqueUrls.length });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Admin: Scan results (blocked + pending) ──────────────────────
app.get('/api/admin/scans', adminAuth, async (req, res) => {
  const type   = ['pending','approved'].includes(req.query.type) ? req.query.type : 'blocked';
  const limit  = Math.min(parseInt(req.query.limit)  || 100, 500);
  const offset = parseInt(req.query.offset) || 0;
  try {
    const pool = await getPool();
    if (type === 'pending') {
      const result = await pool.query(`
        SELECT ps.id, ps.file_name, ps.file_type, ps.file_url,
               ps.retry_count, ps.created_at, ps.last_retry,
               u.name  AS sender_name,  u.email  AS sender_email,
               ru.name AS recipient_name
        FROM pending_scans ps
        LEFT JOIN users u  ON u.id  = ps.user_id
        LEFT JOIN users ru ON ru.id = ps.to_user_id
        ORDER BY ps.created_at DESC
        OFFSET ${offset} ROWS FETCH NEXT ${limit} ROWS ONLY
      `);
      const cnt = await pool.query('SELECT COUNT(*)::int AS n FROM pending_scans');
      res.json({ rows: result.rows, total: cnt.rows[0].n });
    } else if (type === 'approved') {
      const result = await pool.query(`
        SELECT a.id, a.created_at, a.action,
               u.name AS user_name, u.email AS user_email,
               a.details->>'fileName' AS file_name,
               a.details->>'fileUrl'  AS file_url,
               a.details->>'fileType' AS file_type,
               ru.name AS recipient_name
        FROM activity_log a
        LEFT JOIN users u  ON u.id = a.user_id
        LEFT JOIN users ru ON ru.id = (
          CASE WHEN (a.details->>'toUserId') ~ '^[0-9a-fA-F-]{36}$'
               THEN (a.details->>'toUserId')::uuid ELSE NULL END
        )
        WHERE a.action IN ('upload_file', 'upload_pending', 'send_file_delayed')
        ORDER BY a.created_at DESC
        OFFSET ${offset} ROWS FETCH NEXT ${limit} ROWS ONLY
      `);
      const cnt = await pool.query(`
        SELECT COUNT(*)::int AS n FROM activity_log
        WHERE action IN ('upload_file', 'upload_pending', 'send_file_delayed')`);
      res.json({ rows: result.rows, total: cnt.rows[0].n });
    } else {
      const result = await pool.query(`
        SELECT sf.id, sf.created_at, matched.ip,
               COALESCE(matched.action, 'blocked_upload') AS action,
               u.name AS user_name, u.email AS user_email,
               sf.original_name AS file_name,
               COALESCE(sf.moderation_details->>'reason',
                        matched.details->>'reason', 'הקובץ נדחה בסריקה') AS reason,
               sf.file_type, sf.public_url AS file_url
        FROM stored_files sf
        LEFT JOIN users u ON u.id = sf.user_id
        LEFT JOIN LATERAL (
          SELECT a.action, a.ip, a.details
          FROM activity_log a
          WHERE a.details->>'fileUrl' = sf.public_url
          ORDER BY a.created_at DESC
          LIMIT 1
        ) matched ON TRUE
        WHERE sf.moderation_status = 'rejected'
        ORDER BY sf.created_at DESC
        OFFSET ${offset} ROWS FETCH NEXT ${limit} ROWS ONLY
      `);
      const cnt = await pool.query(`
        SELECT COUNT(*)::int AS n FROM stored_files
        WHERE moderation_status = 'rejected'`);
      res.json({ rows: result.rows, total: cnt.rows[0].n });
    }
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.delete('/api/admin/scans/pending/:id', adminAuth, async (req, res) => {
  if (req.adminPerm !== 'edit') return res.status(403).json({ error: 'נדרשת הרשאת עריכה' });
  try {
    const pool = await getPool();
    await pool.query('DELETE FROM pending_scans WHERE id = $1', [parseInt(req.params.id)]);
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Admin: files stored on this Hetzner server ───────────────────
app.get('/api/admin/files', adminAuth, async (req, res) => {
  const limit = Math.min(parseInt(req.query.limit) || 100, 500);
  const offset = Math.max(parseInt(req.query.offset) || 0, 0);
  const search = String(req.query.search || '').trim();
  try {
    const pool = await getPool();
    const params = [];
    let where = '';
    if (search) {
      params.push(`%${search}%`);
      where = `WHERE sf.original_name ILIKE $1 OR u.name ILIKE $1 OR u.email ILIKE $1`;
    }
    const count = await pool.query(
      `SELECT COUNT(*)::int AS n, COALESCE(SUM(sf.file_size),0)::bigint AS bytes
       FROM stored_files sf LEFT JOIN users u ON u.id=sf.user_id ${where}`, params);
    params.push(limit, offset);
    const rows = await pool.query(
      `SELECT sf.id, sf.original_name, sf.public_url, sf.mime_type, sf.file_type,
              sf.file_size, sf.context_type, sf.context_id, sf.created_at,
              u.id AS user_id, u.name AS user_name, u.email AS user_email
       FROM stored_files sf LEFT JOIN users u ON u.id=sf.user_id
       ${where}
       ORDER BY sf.created_at DESC
       LIMIT $${params.length - 1} OFFSET $${params.length}`,
      params);
    res.json({ rows: rows.rows, total: count.rows[0].n,
      totalBytes: Number(count.rows[0].bytes), permission: req.adminPerm });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Admin: create group + add members directly ───────────────────
app.post('/api/admin/groups', adminAuth, async (req, res) => {
  if (req.adminPerm !== 'edit') return res.status(403).json({ error: 'נדרשת הרשאת עריכה' });
  const { name, description, memberIds = [], isBroadcast = false, sendPermission = 'all' } = req.body;
  if (!name) return res.status(400).json({ error: 'נדרש שם קבוצה' });
  try {
    const pool = await getPool();
    const result = await pool.query(
      `INSERT INTO groups (name, description, creator_id, is_broadcast, send_permission)
       VALUES ($1, $2, $3, $4, $5)
       RETURNING id, name`,
      [name, description || '', req.user.id, !!isBroadcast, sendPermission]);
    const group = result.rows[0];
    // Add creator as admin
    await pool.query(
      `INSERT INTO group_members (group_id, user_id, role, status) VALUES ($1, $2, 'admin', 'member')`,
      [group.id, req.user.id]);
    // Add members directly as 'member' (no pending)
    for (const uid of memberIds) {
      try {
        await pool.query(
          `INSERT INTO group_members (group_id, user_id, role, status) VALUES ($1, $2, 'member', 'member')`,
          [group.id, uid]);
      } catch (_) {}
    }
    logActivity(req.user.id, 'create_group', { groupId: group.id, name, members: memberIds.length }, req.ip);
    res.json({ ok: true, groupId: group.id, name: group.name, memberCount: memberIds.length + 1 });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Admin: Vision scan results ───────────────────────────────────
app.get('/api/admin/vision/status', adminAuth, (req, res) => {
  const configured = googleSafeSearchConfigured();
  res.json({
    googleSafeSearch: {
      configured,
      enforced: configured,
      provider: 'google-cloud-vision',
      threshold: normalizeBlockThreshold(process.env.GOOGLE_SAFESEARCH_BLOCK_THRESHOLD),
      timeoutMs: Number(process.env.GOOGLE_VISION_TIMEOUT_MS) || 15000,
    },
  });
});

app.post('/api/admin/vision/test', adminAuth, visionTestRateLimit,
  upload.single('file'), async (req, res) => {
  if (!req.file) return res.status(400).json({ error: 'יש לבחור תמונה' });
  const allowed = ALLOWED_TYPES[req.file.mimetype];
  if (!allowed || allowed.dbType !== 'image')
    return res.status(400).json({ error: 'ניתן לבדוק תמונות JPG, PNG, WebP או GIF בלבד' });
  if (req.file.size > 10 * 1024 * 1024)
    return res.status(400).json({ error: 'התמונה גדולה מ־10MB' });
  try {
    const result = await scanImage(req.file.buffer);
    res.json({
      fileName: req.file.originalname,
      fileSize: req.file.size,
      mimeType: req.file.mimetype,
      ...result,
    });
  } catch (e) {
    res.status(500).json({ error: e.message || 'בדיקת התמונה נכשלה' });
  }
});

app.get('/api/admin/vision', adminAuth, async (req, res) => {
  const limit  = Math.min(parseInt(req.query.limit || 50), 200);
  const offset = parseInt(req.query.offset || 0);
  const filter = req.query.filter || 'all';
  const actionFilter = filter === 'blocked'  ? `AND a.action IN ('blocked_upload','blocked_upload_delayed')`
                     : filter === 'approved' ? `AND a.action IN ('upload_file','send_file_delayed','send_group_file_delayed')`
                     : `AND a.action IN ('upload_file','send_file_delayed','send_group_file_delayed','blocked_upload','blocked_upload_delayed')`;
  try {
    const pool = await getPool();
    const result = await pool.query(`
      SELECT a.id, a.details, a.created_at, a.action,
             u.name AS user_name, u.email AS user_email
      FROM activity_log a
      LEFT JOIN users u ON u.id = a.user_id
      WHERE 1=1 ${actionFilter}
      ORDER BY a.created_at DESC
      OFFSET $1 ROWS FETCH NEXT $2 ROWS ONLY
    `, [offset, limit]);
    const rows = result.rows.map(r => {
      const d = r.details || {};
      return { id: r.id, action: r.action, created_at: r.created_at,
               user_name: r.user_name, user_email: r.user_email,
               fileName: d.fileName, fileType: d.fileType, fileSize: d.fileSize,
               fileUrl: d.fileUrl, reason: d.reason, blockedBy: d.blockedBy || null,
               safeSearch: d.safeSearch || null, labels: d.labels || null,
               faces: d.faces || [], strictModesty: d.strictModesty || null,
               localSafety: d.localSafety || null,
               googleSafeSearch: d.googleSafeSearch || null,
               rescanResult: d.rescanResult || null };
    });
    res.json(rows);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Admin: re-scan all files and save Vision results ─────────────
let visionRescanRunning = false;
app.post('/api/admin/vision/rescan', adminAuth, visionRescanRateLimit, async (req, res) => {
  if (req.adminPerm !== 'edit') return res.status(403).json({ error: 'נדרשת הרשאת עריכה' });
  if (visionRescanRunning)
    return res.status(409).json({ error: 'בדיקת היסטוריה אחרת כבר פועלת' });
  visionRescanRunning = true;
  try {
    const pool = await getPool();
    // Get all image uploads without Vision results saved
    const result = await pool.query(`
      SELECT id, action, details FROM activity_log
      WHERE action IN ('upload_file','send_file_delayed','send_group_file_delayed',
                       'blocked_upload','blocked_upload_delayed')
        AND details @> '{"fileType":"image"}'::jsonb
      ORDER BY created_at DESC
    `);
    let scanned = 0, updated = 0, failed = 0;
    for (const row of result.rows) {
      const d = row.details || {};
      if (!d.fileUrl) { failed++; continue; }
      const existingStrictComplete = d.strictModesty?.available &&
        (d.strictModesty.checked || ['googleSafeSearch', 'localExplicitContent', 'safeSearch']
          .includes(d.blockedBy));
      const existingGoogleComplete = !googleSafeSearchConfigured() ||
        (d.googleSafeSearch?.available &&
         d.googleSafeSearch.threshold ===
           normalizeBlockThreshold(process.env.GOOGLE_SAFESEARCH_BLOCK_THRESHOLD)) ||
        d.googleSafeSearch?.status === 'skipped_local_block';
      const existingLocalTerminal = d.rescanResult?.blocked &&
        ['strictModesty', 'localExplicitContent', 'animatedImage',
          'googleSafeSearchUncertain', 'googleSafeSearchUnsupported']
          .includes(d.rescanResult.blockedBy);
      if (existingLocalTerminal ||
          (d.localSafety?.available && existingStrictComplete && existingGoogleComplete)) {
        scanned++;
        continue;
      }
      try {
        let buf;
        if (d.fileUrl.startsWith(`${UPLOAD_PUBLIC_BASE}/`)) {
          const encodedPath = d.fileUrl.slice(UPLOAD_PUBLIC_BASE.length + 1);
          const relativePath = encodedPath.split('/').map(decodeURIComponent).join(path.sep);
          const absolutePath = path.resolve(UPLOAD_ROOT, relativePath);
          if (!absolutePath.startsWith(path.resolve(UPLOAD_ROOT) + path.sep)) {
            failed++;
            continue;
          }
          buf = await fs.readFile(absolutePath);
        } else {
          const imgRes = await fetch(d.fileUrl, { signal: AbortSignal.timeout(10000) });
          if (!imgRes.ok) { failed++; continue; }
          buf = Buffer.from(await imgRes.arrayBuffer());
        }
        const sr  = await scanImage(buf);
        const strictComplete = sr.strictModesty?.available &&
          (sr.strictModesty.checked || ['googleSafeSearch', 'localExplicitContent', 'safeSearch']
            .includes(sr.blockedBy));
        const googleComplete = !googleSafeSearchConfigured() ||
          sr.googleSafeSearch?.available;
        const reportComplete = !!sr.blocked ||
          (!sr.pending && sr.localSafety?.available && strictComplete && googleComplete);
        if (!reportComplete) {
          failed++;
          continue;
        }
        d.safeSearch = sr.safeSearch;
        d.labels     = sr.labels;
        d.strictModesty = sr.strictModesty || null;
        d.localSafety = sr.localSafety;
        d.googleSafeSearch = sr.googleSafeSearch || null;
        d.rescanResult = {
          reportOnly: true,
          blocked: !!sr.blocked,
          pending: !!sr.pending,
          blockedBy: sr.blockedBy || null,
          reason: sr.reason || null,
          scannedAt: new Date().toISOString(),
        };
        await pool.query('UPDATE activity_log SET details=$1 WHERE id=$2', [JSON.stringify(d), row.id]);
        updated++;
      } catch { failed++; }
    }
    res.json({ total: result.rows.length, scanned, updated, failed });
  } catch (e) { res.status(500).json({ error: e.message }); }
  finally { visionRescanRunning = false; }
});

// ── Moderation Lists ─────────────────────────────────────────────
app.get('/api/admin/moderation', adminAuth, (req, res) => {
  res.json({ female_labels: FEMALE_LABELS, blocked_words: BLOCKED_WORDS });
});

app.post('/api/admin/moderation', adminAuth, async (req, res) => {
  if (req.adminPerm !== 'edit') return res.status(403).json({ error: 'נדרשת הרשאת עריכה' });
  const { female_labels, blocked_words } = req.body;
  if (!Array.isArray(female_labels) || !Array.isArray(blocked_words))
    return res.status(400).json({ error: 'נתונים לא תקינים' });
  try {
    const pool = await getPool();
    await pool.query(
      `UPDATE app_settings SET value=$1, updated_at=now() WHERE key_name='female_labels'`,
      [JSON.stringify(female_labels)]);
    await pool.query(
      `UPDATE app_settings SET value=$1, updated_at=now() WHERE key_name='blocked_words'`,
      [JSON.stringify(blocked_words)]);
    FEMALE_LABELS = female_labels;
    BLOCKED_WORDS = blocked_words;
    res.json({ ok: true, female_labels, blocked_words });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Storage diagnostic ───────────────────────────────────────────
app.get('/api/test-storage', async (req, res) => {
  try {
    const testKey = `test/ping-${Date.now()}.txt`;
    const url = await uploadToBlob(Buffer.from('ping'), testKey, 'text/plain');
    await deleteStoredFile(url);
    res.json({ ok: true, storage: 'local-hetzner', uploadRoot: UPLOAD_ROOT });
  } catch (e) {
    res.json({ ok: false, error: e.message, storage: 'local-hetzner' });
  }
});

// ── App Version (also wakes up DB on cold start) ─────────────────
app.get('/api/version', async (req, res) => {
  try { const pool = await getPool(); await pool.query('SELECT 1'); } catch (_) {}
  let version = '1.2.26';
  try {
    const info = JSON.parse(await fs.readFile(
      path.join(__dirname, '..', 'version.json'), 'utf8'));
    if (info.version) version = String(info.version);
  } catch (_) {}
  res.json({
    version,
    apkUrl: `https://betshuva.com/betshuva-app/betshuva-${version}.apk`,
  });
});

// ── Forgot Password ──────────────────────────────────────────────
app.post('/api/forgot-password', authRateLimit, otpRateLimit, async (req, res) => {
  const { email } = req.body;
  if (!email) return res.status(400).json({ error: 'נדרש אימייל' });
  res.json({ ok: true }); // respond immediately — don't reveal if email exists
  try {
    const pool = await getPool();
    const result = await pool.query('SELECT id, name FROM users WHERE email = $1', [email]);
    if (!result.rows.length) return;
    const user  = result.rows[0];
    const token = crypto.randomBytes(32).toString('hex');
    const expires = new Date(Date.now() + 60 * 60 * 1000); // 1 hour
    await pool.query(
      'INSERT INTO password_reset_tokens (token, user_id, expires_at) VALUES ($1, $2, $3)',
      [token, user.id, expires]);
    const base = process.env.APP_URL || 'https://xo-app-betshuva.azurewebsites.net';
    await sendEmail({
      to: email,
      subject: 'איפוס סיסמה – בתשובה',
      html: resetPasswordEmail(`${base}/reset-password?token=${token}`),
    });
  } catch (e) { console.error('forgot-password:', e.message); }
});

// ── Reset Password API ───────────────────────────────────────────
app.post('/api/reset-password', authRateLimit, credentialRateLimit, async (req, res) => {
  const { token, password } = req.body;
  if (!token || !password) return res.status(400).json({ error: 'חסרים שדות' });
  if (password.length < 6) return res.status(400).json({ error: 'הסיסמה חייבת להיות לפחות 6 תווים' });
  try {
    const pool = await getPool();
    const result = await pool.query(
      'SELECT user_id FROM password_reset_tokens WHERE token = $1 AND used = FALSE AND expires_at > now()',
      [token]);
    if (!result.rows.length) return res.status(400).json({ error: 'הקישור לא תקין או פג תוקף' });
    const { user_id } = result.rows[0];
    const hash = await bcrypt.hash(password, 10);
    await pool.query('UPDATE users SET password_hash = $1 WHERE id = $2', [hash, user_id]);
    await pool.query('UPDATE password_reset_tokens SET used = TRUE WHERE token = $1', [token]);
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Reset Password HTML page ─────────────────────────────────────
app.get('/reset-password', (req, res) => {
  const token = (req.query.token || '').replace(/[^a-f0-9]/g, '');
  res.send(`<!DOCTYPE html>
<html dir="rtl" lang="he">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>איפוס סיסמה – בתשובה</title>
  <style>
    body{font-family:Arial,sans-serif;background:#F0F4F0;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0}
    .card{background:#fff;padding:36px;border-radius:16px;box-shadow:0 4px 24px rgba(0,0,0,.1);width:100%;max-width:400px}
    h2{color:#1B4332;margin-top:0}
    label{color:#6C757D;font-size:14px;display:block;margin-top:12px}
    input{width:100%;padding:12px 16px;border:1.5px solid #D8E4D8;border-radius:10px;font-size:16px;box-sizing:border-box;margin-top:6px}
    button{width:100%;background:#1B4332;color:#fff;border:none;padding:14px;border-radius:10px;font-size:16px;cursor:pointer;margin-top:20px}
    button:hover{background:#2D6A4F}
    .msg{margin-top:16px;padding:12px;border-radius:8px;text-align:center}
    .ok{background:#D8F5E4;color:#1B4332}
    .err{background:#FFE5E5;color:#c00}
  </style>
</head>
<body>
  <div class="card">
    <h2>🔐 איפוס סיסמה</h2>
    <p style="color:#6C757D">הזן סיסמה חדשה עבור חשבונך בבתשובה</p>
    <div id="frm">
      <label>סיסמה חדשה</label>
      <input type="password" id="p1" placeholder="לפחות 6 תווים">
      <label>אימות סיסמה</label>
      <input type="password" id="p2" placeholder="הזן שוב">
      <button onclick="go()">אפס סיסמה</button>
    </div>
    <div id="msg"></div>
  </div>
  <script>
    async function go(){
      const p1=document.getElementById('p1').value,p2=document.getElementById('p2').value,m=document.getElementById('msg');
      if(p1.length<6){m.className='msg err';m.textContent='הסיסמה חייבת להיות לפחות 6 תווים';return}
      if(p1!==p2){m.className='msg err';m.textContent='הסיסמאות אינן תואמות';return}
      const r=await fetch('api/reset-password',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({token:'${token}',password:p1})});
      const d=await r.json();
      if(d.ok){document.getElementById('frm').style.display='none';m.className='msg ok';m.innerHTML='✅ הסיסמה אופסה בהצלחה!<br><small>תוכל להתחבר כעת באפליקציה</small>'}
      else{m.className='msg err';m.textContent=d.error||'שגיאה באיפוס הסיסמה'}
    }
  </script>
</body>
</html>`);
});

// ── Pending Scans — table init + background retry ─────────────────

async function initPendingTable() {
    const pool = await getPool();
    await pool.query(`
      CREATE TABLE IF NOT EXISTS listings (
        id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        user_id      UUID NOT NULL,
        type         TEXT NOT NULL DEFAULT 'free',
        title        TEXT NOT NULL,
        description  TEXT NULL,
        price        DOUBLE PRECISION NULL,
        city         TEXT NULL,
        latitude     DOUBLE PRECISION NULL,
        longitude    DOUBLE PRECISION NULL,
        image_url    TEXT NULL,
        category     TEXT NULL,
        status       TEXT NOT NULL DEFAULT 'active',
        created_at   TIMESTAMPTZ DEFAULT now(),
        expires_at   TIMESTAMPTZ DEFAULT now() + interval '30 days'
      )
    `);
    await pool.query(`ALTER TABLE listings ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ DEFAULT now() + interval '30 days'`);
    await pool.query(`ALTER TABLE listings ADD COLUMN IF NOT EXISTS view_count INTEGER NOT NULL DEFAULT 0`);
    await pool.query(`ALTER TABLE listings ADD COLUMN IF NOT EXISTS contact_count INTEGER NOT NULL DEFAULT 0`);
    await pool.query(`
      CREATE TABLE IF NOT EXISTS listing_views (
        listing_id  UUID NOT NULL,
        user_id     UUID NOT NULL,
        viewed_at   TIMESTAMPTZ DEFAULT now(),
        PRIMARY KEY (listing_id, user_id)
      )
    `);
    await pool.query(`
      CREATE TABLE IF NOT EXISTS listing_images (
        id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        listing_id  UUID NOT NULL,
        url         TEXT NOT NULL,
        sort_order  INTEGER NOT NULL DEFAULT 0
      )
    `);
    await pool.query(`
      CREATE TABLE IF NOT EXISTS pending_scans (
        id          INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        user_id     UUID NOT NULL,
        to_user_id  UUID NULL,
        group_id    UUID NULL,
        file_url    TEXT NOT NULL,
        file_name   TEXT NOT NULL,
        file_type   TEXT NOT NULL,
        mime_type   TEXT NOT NULL,
        retry_count INTEGER NOT NULL DEFAULT 0,
        last_retry  TIMESTAMPTZ NULL,
        created_at  TIMESTAMPTZ DEFAULT now()
      )
    `);
    console.log('tables ready');
}

async function retryPendingScans() {
  if (retryPendingScans.running) return;
  retryPendingScans.running = true;
  try {
    const pool = await getPool();
    const completePending = async (rowId, persistOutcome) => {
      const client = await pool.connect();
      try {
        await client.query('BEGIN');
        const result = await persistOutcome(client);
        const deleted = await client.query(
          `DELETE FROM pending_scans WHERE id=$1 RETURNING id`, [rowId]);
        if (!deleted.rowCount) throw new Error(`Pending scan ${rowId} no longer exists`);
        await client.query('COMMIT');
        return result;
      } catch (error) {
        try { await client.query('ROLLBACK'); } catch (_) {}
        throw error;
      } finally {
        client.release();
      }
    };

    const rows = await pool.query(`
      SELECT ps.*, sf.moderation_details AS prior_moderation_details
      FROM pending_scans ps
      LEFT JOIN stored_files sf
        ON sf.public_url=ps.file_url AND sf.user_id=ps.user_id
      WHERE (ps.retry_count < 20
             AND (ps.last_retry IS NULL OR ps.last_retry < now() - interval '2 minutes'))
         OR (ps.retry_count >= 20
             AND ps.last_retry < now() - interval '30 minutes')
      ORDER BY ps.created_at ASC
      LIMIT 10
    `);

    for (const row of rows.rows) {
      let attempt = Number(row.retry_count) || 0;
      let scanCompleted = false;
      let outcomePersisted = false;
      try {
        // The conditional update also prevents another server process from
        // claiming the same row after both processes selected it.
        const claimed = await pool.query(
          `UPDATE pending_scans
           SET retry_count=retry_count+1, last_retry=now()
           WHERE id=$1 AND retry_count=$2
           RETURNING retry_count`, [row.id, attempt]);
        if (!claimed.rows.length) continue;
        attempt = Number(claimed.rows[0].retry_count) || attempt + 1;

        // Local uploads use a public relative URL. Read those directly from
        // disk; only remote absolute URLs should be fetched over HTTP.
        let buffer;
        if (row.file_url.startsWith(`${UPLOAD_PUBLIC_BASE}/`)) {
          const encodedPath = row.file_url.slice(UPLOAD_PUBLIC_BASE.length + 1);
          const relativePath = encodedPath.split('/').map(decodeURIComponent).join(path.sep);
          const absolutePath = path.resolve(UPLOAD_ROOT, relativePath);
          if (!absolutePath.startsWith(path.resolve(UPLOAD_ROOT) + path.sep))
            throw new Error('Invalid pending file path');
          buffer = await fs.readFile(absolutePath);
        } else {
          const fileRes = await fetch(row.file_url, {
            signal: AbortSignal.timeout(15000),
          });
          if (!fileRes.ok) throw new Error(`Pending file download ${fileRes.status}`);
          buffer = Buffer.from(await fileRes.arrayBuffer());
        }

        let scanResult;
        if (row.file_type === 'image') {
          scanResult = await scanImage(buffer, {
            googleSafeSearch: row.prior_moderation_details?.googleSafeSearch || null,
          });
        }
        else                           scanResult = await scanDocument(buffer, row.mime_type);

        if (!scanResult || scanResult.pending) {
          if (scanResult) {
            await pool.query(
              `UPDATE stored_files SET moderation_details=$1 WHERE public_url=$2`,
              [JSON.stringify(scanResult), row.file_url]);
          }
          continue;
        }
        scanCompleted = true;

        if (scanResult.blocked) {
          await completePending(row.id, async client => {
            await client.query(
              `UPDATE stored_files SET moderation_status='rejected', moderation_details=$1 WHERE public_url=$2`,
              [JSON.stringify(scanResult), row.file_url]);
            if (row.to_user_id === SCAN_BOT_ID) {
              await saveScanBotReport(client, row.user_id, {
                name: row.file_name, size: 0, dbType: row.file_type,
              }, row.file_url, scanResult, 'rejected');
            }
          });
          outcomePersisted = true;
          logActivity(row.user_id, 'blocked_upload_delayed',
            { fileName: row.file_name, reason: scanResult.reason, fileUrl: row.file_url,
              blockedBy: scanResult.blockedBy || null,
              safeSearch: scanResult.safeSearch || null,
              labels: scanResult.labels || null,
              strictModesty: scanResult.strictModesty || null,
              localSafety: scanResult.localSafety || null,
              googleSafeSearch: scanResult.googleSafeSearch || null });
          // Notify sender that file was rejected
          const sid = onlineUsers.get(row.user_id);
          if (sid) io.to(sid).emit('scan:rejected', {
            fileName: row.file_name, fileUrl: row.file_url,
            groupId: row.group_id || null, toUserId: row.to_user_id || null,
            reason: scanResult.reason,
          });
          continue;
        }

        if (row.file_type === 'image' && row.to_user_id && row.to_user_id !== SCAN_BOT_ID) {
          const policy = await getEffectiveRecipientFilter(pool, row.to_user_id, row.user_id);
          if (!policy?.isContact || !imageAllowedByFilter(policy.filter, scanResult.classification)) {
            const reason = !policy?.isContact
              ? 'הנמען עדיין לא אישר אותך כחבר'
              : 'סוג התמונה חסום בהגדרות הנמען';
            logActivity(row.user_id, 'blocked_by_recipient_filter', {
              toUserId: row.to_user_id, fileName: row.file_name,
              fileUrl: row.file_url, category: scanResult.classification?.category,
            });
            await completePending(row.id, async client => {
              await client.query(
                `UPDATE stored_files SET moderation_status='rejected', moderation_details=$1 WHERE public_url=$2`,
                [JSON.stringify({ reason, classification: scanResult.classification || null,
                  safeSearch: scanResult.safeSearch || null,
                  strictModesty: scanResult.strictModesty || null,
                  localSafety: scanResult.localSafety || null,
                  googleSafeSearch: scanResult.googleSafeSearch || null }), row.file_url]);
            });
            outcomePersisted = true;
            const sid = onlineUsers.get(row.user_id);
            if (sid) io.to(sid).emit('scan:rejected', {
              fileName: row.file_name, fileUrl: row.file_url,
              groupId: null, toUserId: row.to_user_id, reason,
            });
            continue;
          }
        }

        let pendingGroup = null;
        if (row.group_id) {
          const groupAccess = await pool.query(
            `SELECT gm.role, g.send_permission, g.name AS group_name,
                    u.name AS sender_name
             FROM group_members gm
             JOIN groups g ON g.id=gm.group_id
             JOIN users u ON u.id=gm.user_id
             WHERE gm.group_id=$1 AND gm.user_id=$2 AND gm.status='member'`,
            [row.group_id, row.user_id]);
          pendingGroup = groupAccess.rows[0] || null;
          if (!pendingGroup ||
              (pendingGroup.send_permission === 'admin' && pendingGroup.role !== 'admin')) {
            const reason = !pendingGroup
              ? 'אין לך עוד הרשאה לשלוח לקבוצה זו'
              : 'רק מנהלי הקבוצה רשאים לשלוח הודעות';
            await completePending(row.id, async client => {
              await client.query(
                `UPDATE stored_files SET moderation_status='rejected', moderation_details=$1 WHERE public_url=$2`,
                [JSON.stringify({ ...scanResult, reason, deliveryRejected: true }), row.file_url]);
            });
            outcomePersisted = true;
            const sid = onlineUsers.get(row.user_id);
            if (sid) io.to(sid).emit('scan:rejected', {
              groupId: row.group_id, toUserId: null,
              fileName: row.file_name, fileUrl: row.file_url, reason,
            });
            logActivity(row.user_id, 'group_file_delivery_rejected', {
              groupId: row.group_id, fileName: row.file_name,
              fileUrl: row.file_url, reason,
            });
            continue;
          }
        }

        if (row.to_user_id === SCAN_BOT_ID) {
          await completePending(row.id, async client => {
            await client.query(
              `UPDATE stored_files SET moderation_status='approved', moderation_details=$1 WHERE public_url=$2`,
              [JSON.stringify(scanResult), row.file_url]);
            await saveScanBotReport(client, row.user_id, {
              name: row.file_name, size: 0, dbType: row.file_type,
            }, row.file_url, scanResult, 'approved');
          });
          outcomePersisted = true;
          continue;
        }

        // Scan passed — save message and deliver
        if (row.to_user_id) {
          const msg = await completePending(row.id, async client => {
            await client.query(
              `UPDATE stored_files SET moderation_status='approved', moderation_details=$1 WHERE public_url=$2`,
              [JSON.stringify(scanResult), row.file_url]);
            const saved = await client.query(
              `INSERT INTO messages (sender_id, recipient_id, type, body, file_url, file_name)
               VALUES ($1, $2, $3, $4, $5, $4)
               RETURNING id, created_at`,
              [row.user_id, row.to_user_id, row.file_type, row.file_name, row.file_url]);
            return saved.rows[0];
          });
          outcomePersisted = true;
          const payload = {
            id: msg.id, fromUserId: row.user_id, createdAt: msg.created_at,
            fileUrl: row.file_url, fileName: row.file_name, fileType: row.file_type,
          };
          const senderSid    = onlineUsers.get(row.user_id);
          const recipientSid = onlineUsers.get(row.to_user_id);
          if (senderSid)    io.to(senderSid).emit('chat:message', payload);
          if (recipientSid) io.to(recipientSid).emit('chat:message', payload);
          if (!recipientSid)
            sendPush(row.to_user_id, '', `📎 ${row.file_name}`, { type: 'chat', fromUserId: row.user_id });
          logActivity(row.user_id, 'send_file_delayed',
            { toUserId: row.to_user_id, fileName: row.file_name,
              fileUrl: row.file_url, fileType: row.file_type,
              safeSearch: scanResult.safeSearch || null,
              labels: scanResult.labels || null,
              strictModesty: scanResult.strictModesty || null,
              localSafety: scanResult.localSafety || null,
              googleSafeSearch: scanResult.googleSafeSearch || null,
              blockedBy: null });
          continue;
        }

        if (row.group_id && pendingGroup) {
          const msg = await completePending(row.id, async client => {
            await client.query(
              `UPDATE stored_files SET moderation_status='approved', moderation_details=$1 WHERE public_url=$2`,
              [JSON.stringify(scanResult), row.file_url]);
            const saved = await client.query(
              `INSERT INTO messages (sender_id, group_id, type, body, file_url, file_name)
               VALUES ($1, $2, $3, $4, $5, $4)
               RETURNING id, created_at`,
              [row.user_id, row.group_id, row.file_type, row.file_name, row.file_url]);
            return saved.rows[0];
          });
          outcomePersisted = true;
          const payload = {
            id: msg.id,
            groupId: row.group_id,
            fromUserId: row.user_id,
            fromName: pendingGroup.sender_name,
            text: null,
            fileUrl: row.file_url,
            fileName: row.file_name,
            fileType: row.file_type,
            replyToId: null,
            clientMessageId: null,
            createdAt: msg.created_at,
          };
          const room = `group:${row.group_id}`;
          io.to(room).emit('group:message', payload);
          const senderSid = onlineUsers.get(row.user_id);
          const senderSocket = senderSid ? io.sockets.sockets.get(senderSid) : null;
          if (senderSid && !senderSocket?.rooms.has(room))
            io.to(senderSid).emit('group:message', payload);

          const allMembers = await pool.query(
            `SELECT user_id FROM group_members
             WHERE group_id=$1 AND status='member'`, [row.group_id]);
          for (const { user_id } of allMembers.rows) {
            if (user_id !== row.user_id) {
              sendPush(user_id,
                `${pendingGroup.group_name} • ${pendingGroup.sender_name}`,
                `📎 ${row.file_name}`,
                { type: 'group', groupId: row.group_id });
            }
          }
          logActivity(row.user_id, 'send_group_file_delayed', {
            groupId: row.group_id, fileName: row.file_name,
            fileUrl: row.file_url, fileType: row.file_type,
            safeSearch: scanResult.safeSearch || null,
            labels: scanResult.labels || null,
            strictModesty: scanResult.strictModesty || null,
            localSafety: scanResult.localSafety || null,
            googleSafeSearch: scanResult.googleSafeSearch || null,
            blockedBy: null,
          });
          continue;
        }

        await completePending(row.id, async client => {
          await client.query(
            `UPDATE stored_files SET moderation_status='approved', moderation_details=$1 WHERE public_url=$2`,
            [JSON.stringify(scanResult), row.file_url]);
        });
        outcomePersisted = true;
      } catch (e) {
        console.error('retry row', row.id, e.message);
        if (!outcomePersisted && scanCompleted) {
          // A persistence failure after a successful scan must not consume the
          // final scan attempt. Leave the row eligible for a later retry.
          try {
            await pool.query(
              `UPDATE pending_scans
               SET retry_count=GREATEST(retry_count-1, 0)
               WHERE id=$1`, [row.id]);
          } catch (_) {}
        }
      }
    }
  } catch (e) {
    console.error('retryPendingScans:', e.message);
  } finally {
    retryPendingScans.running = false;
  }
}

const PORT = process.env.PORT || 3000;

async function startServer() {
  await fs.mkdir(UPLOAD_ROOT, { recursive: true });
  await migrateDatabase();
  await initPendingTable();
  setTimeout(retryPendingScans, 1000); // process queued files after startup
  setInterval(retryPendingScans, 2 * 60 * 1000); // every 2 minutes
  httpServer.listen(PORT, '127.0.0.1', () => console.log(`Server running on port ${PORT}`));
}

startServer().catch((error) => {
  console.error('Startup failed:', error);
  process.exitCode = 1;
});
