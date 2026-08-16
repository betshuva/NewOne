require('dotenv').config();
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
const { getPool } = require('./db');

const UPLOAD_ROOT = path.join(__dirname, '..', 'uploads');
const UPLOAD_PUBLIC_BASE = '/betshuva-app/uploads';
const SCAN_BOT_ID = '00000000-0000-4000-8000-000000000001';
const SCAN_BOT_EMAIL = 'scan@betshuva.system';

// ── FCM via HTTP Legacy API (no service account key needed) ───────
async function sendPush(userId, title, body, data = {}) {
  const serverKey = process.env.FCM_SERVER_KEY;
  if (!serverKey) return;
  try {
    const pool   = await getPool();
    const result = await pool.query('SELECT token FROM fcm_tokens WHERE user_id = $1', [userId]);
    for (const { token } of result.rows) {
      const res = await fetch('https://fcm.googleapis.com/fcm/send', {
        method:  'POST',
        headers: {
          'Authorization': `key=${serverKey}`,
          'Content-Type':  'application/json',
        },
        body: JSON.stringify({
          to:           token,
          notification: { title, body, sound: 'default' },
          data:         Object.fromEntries(Object.entries(data).map(([k,v]) => [k, String(v)])),
          priority:     'high',
          android:      { priority: 'high' },
          apns:         { payload: { aps: { badge: 1, sound: 'default' } } },
        }),
      });
      const json = await res.json();
      if (json.failure && json.results?.[0]?.error === 'NotRegistered') {
        pool.query('DELETE FROM fcm_tokens WHERE token=$1', [token]).catch(() => {});
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

let FEMALE_LABELS = [...DEFAULT_FEMALE_LABELS];
let BLOCKED_WORDS = [...DEFAULT_BLOCKED_WORDS];

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
  const modesty = (scanResult?.labels || [])
    .filter(label => ['nudity', 'adult sexual content', 'lingerie or revealing clothing']
      .includes(label.name))
    .map(label => `${label.name} ${label.score}%`);
  if (modesty.length) lines.push(`בדיקת צניעות: ${modesty.join(' · ')}`);
  return lines.join('\n');
}

async function saveScanBotReport(pool, userId, file, fileUrl, scanResult, status) {
  if (status === 'approved') {
    await pool.query(
      `INSERT INTO messages(sender_id,recipient_id,type,body,file_url,file_name,file_size)
       VALUES($1,$2,$3,$4,$5,$4,$6)`,
      [userId, SCAN_BOT_ID, file.dbType, file.name, fileUrl, file.size]);
  }
  const body = formatScanBotReport(file.name, scanResult, status);
  const saved = await pool.query(
    `INSERT INTO messages(sender_id,recipient_id,type,body)
     VALUES($1,$2,'text',$3) RETURNING id,created_at`,
    [SCAN_BOT_ID, userId, body]);
  const sid = onlineUsers.get(userId);
  if (sid) io.to(sid).emit('chat:message', {
    id: saved.rows[0].id, fromUserId: SCAN_BOT_ID, fromName: 'סריקה',
    text: body, createdAt: saved.rows[0].created_at, fileType: 'text',
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
  if (subjectTop.label !== 'person or people' && subjectTop.score >= 0.70) {
    return {
      category: 'nonHumanImages', detectedCategories: ['nonHumanImages'],
      uncertain: false, life, subjects, people: null,
      stages: [lifeStage, subjectsStage],
      totalDurationMs: Math.round(performance.now() - startedAt),
    };
  }

  if (subjectTop.label !== 'person or people' || subjectTop.score < 0.70) {
    subjectsStage.uncertain = true;
    return {
      category: null, detectedCategories: [], uncertain: true,
      uncertainStage: 'subjects', life, subjects, people: null,
      stages: [lifeStage, subjectsStage],
      totalDurationMs: Math.round(performance.now() - startedAt),
    };
  }

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


async function scanImage(buffer) {
  const key = process.env.GOOGLE_VISION_API_KEY;
  if (!key) {
    // Free local fallback: the CLIP service is hosted on this server and does
    // not incur a per-request API charge.
    try {
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
      const [scores, classification] = await Promise.all([
        classifyClip(buffer, labels),
        classifyImageContent(buffer),
      ]);
      const labelsRaw = Object.entries(scores).map(([name, score]) => ({
        name,
        score: Math.round(Number(score) * 100),
      }));
      const blockedBy =
        Number(scores['adult sexual content'] || 0) >= 0.20 ||
        Number(scores.nudity || 0) >= 0.20 ||
        Number(scores['lingerie or revealing clothing'] || 0) >= 0.30
          ? 'safeSearch' : null;
      if (blockedBy) {
        return {
          blocked: true,
          blockedBy,
          reason: 'התמונה נחסמה — תוכן לא צנוע',
          labels: labelsRaw,
          faces: [],
          safeSearch: {},
          genderResults: null,
          classification,
        };
      }
      if (classification.uncertain) {
        return {
          pending: true,
          reason: 'הסיווג אינו ודאי ונדרשת בדיקה נוספת',
          labels: labelsRaw, faces: [], safeSearch: {}, genderResults: null,
          classification,
        };
      }
      return {
        blocked: false,
        blockedBy: null,
        labels: labelsRaw,
        faces: [],
        safeSearch: {},
        genderResults: null,
        classification,
      };
    } catch (error) {
      console.error('Local CLIP scan:', error.message);
      return { pending: true };
    }
  }

  let res;
  try {
    res = await fetch(
      `https://vision.googleapis.com/v1/images:annotate?key=${key}`,
      {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          requests: [{
            image:    { content: buffer.toString('base64') },
            features: [
              { type: 'SAFE_SEARCH_DETECTION' },
              { type: 'LABEL_DETECTION', maxResults: 20 },
              { type: 'FACE_DETECTION', maxResults: 5 },
            ],
          }],
        }),
      }
    );
  } catch { return { pending: true }; }

  const data = await res.json();
  if (!res.ok || data.error) return { pending: true };

  const ann = data.responses?.[0];
  if (!ann) return { pending: true };

  const ss  = ann.safeSearchAnnotation || {};
  const BAD = ['POSSIBLE', 'LIKELY', 'VERY_LIKELY'];
  const labelsRaw = (ann.labelAnnotations || []).map(l => ({ name: l.description, score: Math.round(l.score * 100) }));
  const labelNames = labelsRaw.map(l => l.name.toLowerCase());
  const faces = ann.faceAnnotations || [];
  let classification = null;
  try { classification = await classifyImageContent(buffer); } catch (_) {}

  if (BAD.includes(ss.adult) || BAD.includes(ss.racy))
    return { blocked: true, blockedBy: 'safeSearch', reason: 'התמונה נחסמה — תוכן לא צנוע', safeSearch: ss, labels: labelsRaw, faces, genderResults: null, classification };

  if (!classification || classification.uncertain)
    return { pending: true, reason: 'הסיווג אינו ודאי ונדרשת בדיקה נוספת', safeSearch: ss, labels: labelsRaw, faces, genderResults: null, classification };

  return { blocked: false, blockedBy: null, safeSearch: ss, labels: labelsRaw, faces, genderResults: null, classification };
}

async function scanDocument(buffer, mimetype) {
  if (!process.env.GOOGLE_VISION_API_KEY) return { pending: true };
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
      <p style="color:rgba(255,255,255,0.8);margin:8px 0 0">מסרים לקהילה החרדית</p>
    </div>
    <div style="background:#fff;padding:28px;border-radius:0 0 12px 12px;border:1px solid #e0e0e0">
      <h2 style="color:#1B4332;margin-top:0">ברוכים הבאים, ${name}!</h2>
      <p style="color:#444;line-height:1.6">חשבונך נרשם בהצלחה. אנו שמחים שהצטרפת לקהילת בתשובה.</p>
      <p style="color:#6C757D;font-size:13px;margin-top:24px;border-top:1px solid #eee;padding-top:16px">בתשובה — מסרים לקהילה החרדית</p>
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
      <p style="color:#6C757D;font-size:13px;margin-top:24px;border-top:1px solid #eee;padding-top:16px">בתשובה — מסרים לקהילה החרדית</p>
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
      <p style="color:#6C757D;font-size:13px;margin-top:24px;border-top:1px solid #eee;padding-top:16px">בתשובה — מסרים לקהילה החרדית</p>
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
        community           TEXT,
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
    await pool.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS community TEXT`);
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
    await pool.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS wins INTEGER NOT NULL DEFAULT 0`);
    await pool.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS games_played INTEGER NOT NULL DEFAULT 0`);
    await pool.query(`
      INSERT INTO users(id,name,email,phone,email_verified,phone_verified,city,community)
      VALUES($1,'סריקה',$2,'0000000000',TRUE,TRUE,'מערכת','בודק תמונות')
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

    await pool.query(`
      CREATE TABLE IF NOT EXISTS user_contacts (
        owner_id   UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        contact_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        created_at TIMESTAMPTZ DEFAULT now(),
        PRIMARY KEY (owner_id, contact_id),
        CHECK (owner_id <> contact_id)
      )`);
    await pool.query(`ALTER TABLE user_contacts ADD COLUMN IF NOT EXISTS filter_override JSONB`);
    await pool.query(`
      INSERT INTO user_contacts(owner_id,contact_id)
      SELECT id,$1 FROM users WHERE id<>$1 ON CONFLICT DO NOTHING`, [SCAN_BOT_ID]);
    await pool.query(`
      INSERT INTO user_contacts(owner_id,contact_id)
      SELECT $1,id FROM users WHERE id<>$1 ON CONFLICT DO NOTHING`, [SCAN_BOT_ID]);
    await pool.query(`
      CREATE OR REPLACE FUNCTION add_scan_bot_contact_for_new_user()
      RETURNS TRIGGER AS $$
      BEGIN
        IF NEW.id <> '${SCAN_BOT_ID}'::uuid THEN
          INSERT INTO user_contacts(owner_id,contact_id)
          VALUES(NEW.id,'${SCAN_BOT_ID}'::uuid) ON CONFLICT DO NOTHING;
          INSERT INTO user_contacts(owner_id,contact_id)
          VALUES('${SCAN_BOT_ID}'::uuid,NEW.id) ON CONFLICT DO NOTHING;
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql`);
    await pool.query(`DROP TRIGGER IF EXISTS users_add_scan_bot_contact ON users`);
    await pool.query(`
      CREATE TRIGGER users_add_scan_bot_contact AFTER INSERT ON users
      FOR EACH ROW EXECUTE FUNCTION add_scan_bot_contact_for_new_user()`);
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

const app = express();
const httpServer = createServer(app);
const io = new Server(httpServer, { cors: { origin: '*' } });
app.set('io', io);

app.use(cors());
app.use(express.json());
app.use(express.static(require('path').join(__dirname, '..')));
app.use('/app', express.static(require('path').join(__dirname, '..', 'flutter_web')));
app.get('/app', (req, res) => res.redirect('/app/'));
app.get('/public-home', (req, res) => res.sendFile(require('path').join(__dirname, '..', 'home.html')));
app.get('/privacy', (req, res) => res.sendFile(require('path').join(__dirname, '..', 'privacy.html')));
app.get('/terms', (req, res) => res.sendFile(require('path').join(__dirname, '..', 'terms.html')));
app.get('/delete-account', (req, res) => res.sendFile(require('path').join(__dirname, '..', 'delete-account.html')));

const JWT_SECRET = process.env.JWT_SECRET;
if (!JWT_SECRET) {
  throw new Error('JWT_SECRET is required; refusing to start with an insecure default');
}
const onlineUsers = new Map(); // userId → socketId
const otpStore    = new Map(); // phone → { code, expires, name }

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

io.on('connection', async (socket) => {
  onlineUsers.set(socket.user.id, socket.id);
  io.emit('users:online', [...onlineUsers.keys()]);

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
      // Push only if recipient is offline
      if (!onlineUsers.has(toUserId)) {
        const pushBody = fileUrl ? `📎 ${fileName || 'קובץ'}` : (text || '');
        sendPush(toUserId, socket.user.name, pushBody, { type: 'chat', fromUserId: socket.user.id });
      }
    } catch (e) {
      console.error('chat:message save:', e.message);
      relay(toUserId, 'chat:message', { fromUserId: socket.user.id, fromName: socket.user.name, text });
    }
  });

  socket.on('chat:typing', ({ toUserId }) =>
    relay(toUserId, 'chat:typing', { fromUserId: socket.user.id }));

  // ── Group messaging ──────────────────────────────────────────────
  socket.on('group:message', async ({ groupId, text, replyToId, fileUrl, fileName, fileType, clientMessageId }) => {
    if ((!text && !fileUrl) || !groupId) return;
    try {
      const pool = await getPool();
      const mem = await pool.query(
        `SELECT gm.role, g.send_permission FROM group_members gm
         JOIN groups g ON g.id = gm.group_id
         WHERE gm.group_id = $1 AND gm.user_id = $2`, [groupId, socket.user.id]);
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
      // Push to offline members
      const grpName = await pool.query('SELECT name FROM groups WHERE id = $1', [groupId]);
      const groupName = grpName.rows[0]?.name || 'קבוצה';
      const allMembers = await pool.query('SELECT user_id FROM group_members WHERE group_id = $1', [groupId]);
      const pushBody = fileUrl ? `📎 ${fileName || 'קובץ'}` : (text || '');
      for (const { user_id } of allMembers.rows) {
        if (user_id !== socket.user.id && !onlineUsers.has(user_id)) {
          sendPush(user_id, `${groupName} • ${socket.user.name}`,
            pushBody, { type: 'group', groupId });
        }
      }
    } catch (e) { console.error('group:message:', e.message); }
  });

  socket.on('group:typing', ({ groupId }) =>
    socket.to(`group:${groupId}`).emit('group:typing', {
      groupId,
      fromUserId: socket.user.id,
      fromName:   socket.user.name,
    }));

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

  socket.on('group:join', ({ groupId }) => socket.join(`group:${groupId}`));

  socket.on('disconnect', () => {
    onlineUsers.delete(socket.user.id);
    io.emit('users:online', [...onlineUsers.keys()]);
    logActivity(socket.user.id, 'disconnect', {});
  });

  logActivity(socket.user.id, 'connect', {});
});

// ── Register ─────────────────────────────────────────────────────
app.post('/api/register', async (req, res) => {
  const { name, password, phone, clientType, verificationMethod } = req.body;
  // Copying an address from RTL text can add invisible bidi controls. They
  // are formatting characters, not part of an email address.
  const email = typeof req.body.email === 'string'
    ? req.body.email.replace(/[\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]/g, '').trim().toLowerCase()
    : req.body.email;
  if (!name) return res.status(400).json({ error: 'חסר שם' });
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
      `INSERT INTO users (name, email, phone, password_hash)
       VALUES ($1, $2, $3, $4)
       RETURNING id, name, email`,
      [name, hasEmail ? email : null, hasPhone ? cleanPhone : null, hash]);
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
app.post('/api/login', async (req, res) => {
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
app.post('/api/resend-verification', async (req, res) => {
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
app.post('/api/auth/google', async (req, res) => {
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
    console.log(`[GOOGLE] new user — name:${name} email:${email}`);
    const inserted = await pool.query(
      `INSERT INTO users (name, email, email_verified, google_id, profile_pic_url)
       VALUES ($1, $2, TRUE, $3, $4)
       RETURNING *`,
      [name || (email ? email.split('@')[0] : 'משתמש'), email || null, googleId, picture || null]);
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
      `SELECT u.id, u.name, u.profile_pic_url, u.city, u.community, u.phone, u.email,
              c.filter_override,
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
       AND u.id NOT IN (
         SELECT blocked_id FROM blocked_users WHERE blocker_id = $1
       )
       ORDER BY last_msg.created_at DESC NULLS LAST, u.name`, [req.user.id]);
    res.json(result.rows);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

app.get('/api/users/directory', authWithDbCheck, async (req, res) => {
  try {
    const pool = await getPool();
    const result = await pool.query(
      `SELECT id, name, profile_pic_url, city, community, phone, email
       FROM users WHERE id != $1
       AND (email_verified = TRUE OR phone_verified = TRUE)
       AND id NOT IN (SELECT blocked_id FROM blocked_users WHERE blocker_id=$1)
       ORDER BY name`, [req.user.id]);
    res.json(result.rows);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.get('/api/users/search', authWithDbCheck, async (req, res) => {
  const q = String(req.query.q || '').trim();
  if (q.length < 2) return res.json([]);
  try {
    const pool = await getPool();
    const digits = q.replace(/\D/g, '');
    const result = await pool.query(
      `SELECT u.id, u.name, u.email, u.phone, u.profile_pic_url, u.city, u.community,
              EXISTS(SELECT 1 FROM user_contacts c
                     WHERE c.owner_id=$1 AND c.contact_id=u.id) AS saved
       FROM users u
       WHERE u.id != $1
         AND (u.email_verified = TRUE OR u.phone_verified = TRUE)
         AND u.id NOT IN (SELECT blocked_id FROM blocked_users WHERE blocker_id=$1)
         AND (u.email ILIKE $2 OR ($3 <> '' AND u.phone LIKE $4))
       ORDER BY u.name LIMIT 30`,
      [req.user.id, `%${q}%`, digits, `%${digits}%`]);
    res.json(result.rows);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.post('/api/contacts/save/:userId', authWithDbCheck, async (req, res) => {
  if (req.params.userId === req.user.id)
    return res.status(400).json({ error: 'לא ניתן לשמור את עצמך' });
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
  const { phones } = req.body;
  if (!Array.isArray(phones) || phones.length === 0)
    return res.status(400).json({ error: 'נדרש מערך phones' });

  // Normalize: keep digits only, handle Israeli prefix (972 → 0)
  const normalize = (p) => {
    let d = p.replace(/\D/g, '');
    if (d.startsWith('972') && d.length > 10) d = '0' + d.slice(3);
    return d;
  };
  const normalized = [...new Set(phones.map(normalize).filter(Boolean))];
  if (normalized.length === 0) return res.json([]);

  try {
    const pool = await getPool();
    // Build a values list for IN clause using parameterized placeholders
    const placeholders = normalized.map((_, i) => `$${i + 2}`).join(',');
    const result = await pool.query(
      `SELECT id, name, profile_pic_url, phone
       FROM users
       WHERE phone IN (${placeholders})
         AND (email_verified = TRUE OR phone_verified = TRUE)
         AND id != $1
         AND id NOT IN (SELECT blocked_id FROM blocked_users WHERE blocker_id = $1)`,
      [req.user.id, ...normalized]
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
app.post('/api/messages', auth, async (req, res) => {
  const senderId = req.user.id;
  const { toUserId, text, replyToId, fileUrl, fileName, fileType } = req.body || {};
  if (!toUserId || (!text && !fileUrl)) {
    return res.status(400).json({ error: 'חסר נמען או תוכן' });
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

    if (!onlineUsers.has(toUserId)) {
      const pushBody = fileUrl ? `📎 ${fileName || 'קובץ'}` : (text || '');
      sendPush(toUserId, req.user.name, pushBody, { type: 'chat', fromUserId: senderId });
    }

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

// ── Profile: get ──────────────────────────────────────────────────
app.get('/api/profile', auth, async (req, res) => {
  try {
    const pool = await getPool();
    const result = await pool.query(
      `SELECT id, name, email, phone, email_verified, phone_verified,
              city, community, country, street, house_number, apartment,
              profile_pic_url, privacy_pic, filter_level
       FROM users WHERE id = $1`, [req.user.id]);
    if (!result.rows.length) return res.status(404).json({ error: 'לא נמצא' });
    res.json(result.rows[0]);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Profile: update ───────────────────────────────────────────────
app.put('/api/profile', auth, async (req, res) => {
  const { name, city, community, privacy_pic, filter_level, profile_pic_url,
          country, street, house_number, apartment } = req.body;
  if (!name || !name.trim()) return res.status(400).json({ error: 'נדרש שם' });
  const validPrivacy = ['all', 'contacts', 'nobody'];
  const validFilter  = ['standard', 'strict'];
  try {
    const pool = await getPool();
    await pool.query(
      `UPDATE users
       SET name=$1, city=$2, community=$3,
           country=$4, street=$5, house_number=$6, apartment=$7,
           privacy_pic=$8, filter_level=$9,
           profile_pic_url=$10
       WHERE id=$11`,
      [name.trim(), city || null, community || null, country || 'ישראל', street || null,
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
  const allImages = image_urls?.length ? image_urls.slice(0, 4) : (image_url ? [image_url] : []);
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
             image_url, category, status, created_at,
             view_count, contact_count,
             seller_id, seller_name, seller_pic, dist AS distance_km
      FROM (
        SELECT l.id, l.type, l.title, l.description, l.price, l.city,
               l.image_url, l.category, l.status, l.created_at,
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
  const allImages  = Array.isArray(image_urls) ? image_urls.filter(Boolean).slice(0, 4) : [];
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
app.post('/api/upload', auth, upload.single('file'), async (req, res) => {
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
    // העלאה לאחסון תחילה (גם קבצים חסומים נשמרים לצורך ביקורת אדמין)
    const blobName = `${req.user.id}/${Date.now()}-${crypto.randomUUID()}-${file.originalname.replace(/[^\w.\-]/g, '_')}`;
    const url = await uploadToBlob(file.buffer, blobName, file.mimetype);
    await pool.query(
      `INSERT INTO stored_files
       (user_id, original_name, storage_path, public_url, mime_type, file_type,
        file_size, context_type, context_id, moderation_status)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,'pending')`,
      [req.user.id, file.originalname, blobName, url, file.mimetype, allowed.dbType,
       file.size, req.body.groupId ? 'group' : req.body.toUserId ? 'chat' : 'general',
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
          faces: scanResult.faces || [], genderResults: scanResult.genderResults || null }, req.ip);
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
      }, req.ip);
      await pool.query(
        `UPDATE stored_files SET moderation_status='rejected', moderation_details=$1 WHERE public_url=$2`,
        [JSON.stringify({ reason, classification: scanResult?.classification || null }), url]);
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
      const ins = await pool.query(
        `INSERT INTO pending_scans (user_id, to_user_id, group_id, file_url, file_name, file_type, mime_type)
         VALUES ($1, $2, $3, $4, $5, $6, $7)
         RETURNING id`,
        [req.user.id, toUserId, groupId, url, file.originalname, allowed.dbType, file.mimetype]);
      logActivity(req.user.id, 'upload_pending',
        { fileName: file.originalname, fileSize: file.size, fileType: allowed.dbType }, req.ip);
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
             gm.role, gm.status,
             (SELECT COUNT(*) FROM group_members WHERE group_id = g.id AND status='member') AS member_count,
             last_msg.body AS last_message,
             last_msg.type AS last_message_type,
             last_msg.created_at AS last_message_at,
             last_msg.sender_name AS last_message_sender_name,
             (last_msg.sender_id = $1) AS last_message_is_mine
      FROM groups g
      JOIN group_members gm ON g.id = gm.group_id AND gm.user_id = $1
      LEFT JOIN LATERAL (
        SELECT m.body, m.type, m.created_at, m.sender_id, u.name AS sender_name
        FROM messages m
        JOIN users u ON u.id=m.sender_id
        WHERE m.group_id = g.id AND m.deleted_for_everyone = FALSE
          AND m.created_at >= gm.joined_at
        ORDER BY m.created_at DESC
        LIMIT 1
      ) last_msg ON TRUE
      ORDER BY last_msg.created_at DESC NULLS LAST, g.created_at DESC
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
    res.json({ ...group, role: 'admin', member_count: 1, is_broadcast: false, send_permission: 'all' });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Groups: details + members ─────────────────────────────────────
app.get('/api/groups/:id', auth, async (req, res) => {
  try {
    const pool = await getPool();
    const mem = await pool.query(
      'SELECT role FROM group_members WHERE group_id=$1 AND user_id=$2', [req.params.id, req.user.id]);
    if (!mem.rows.length) return res.status(403).json({ error: 'לא חבר בקבוצה' });

    const [grp, members] = await Promise.all([
      pool.query('SELECT * FROM groups WHERE id=$1', [req.params.id]),
      pool.query(
        `SELECT u.id, u.name, u.profile_pic_url, gm.role, gm.joined_at, gm.last_viewed_at
         FROM group_members gm JOIN users u ON u.id=gm.user_id
         WHERE gm.group_id=$1 ORDER BY gm.role DESC, u.name`, [req.params.id]),
    ]);
    res.json({ ...grp.rows[0], members: members.rows, myRole: mem.rows[0].role });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Groups: messages ──────────────────────────────────────────────
app.get('/api/groups/:id/messages', auth, async (req, res) => {
  const before = req.query.before;
  try {
    const pool = await getPool();
    const check = await pool.query(
      'SELECT 1 FROM group_members WHERE group_id=$1 AND user_id=$2', [req.params.id, req.user.id]);
    if (!check.rows.length) return res.status(403).json({ error: 'לא חבר בקבוצה' });

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
    res.json(result.rows.reverse());
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Groups: add registered member directly (admin) ────────────────
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
      if (st === 'pending') {
        await pool.query(
          `UPDATE group_members SET status='member', pending_since=NULL
           WHERE group_id=$1 AND user_id=$2`,
          [req.params.id, userId]);
      }
    }

    // The group admin explicitly selected this registered user, matching the
    // familiar WhatsApp flow: membership becomes active immediately.
    await pool.query(
      `INSERT INTO group_members (group_id, user_id, status, added_by, pending_since)
       VALUES ($1, $2, 'member', $3, NULL)
       ON CONFLICT (group_id, user_id) DO UPDATE SET status='member', added_by=$3, pending_since=NULL`,
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
      const invitedSocket = ioInst.sockets.sockets.get(invitedSid);
      invitedSocket?.join(`group:${req.params.id}`);
      ioInst.to(invitedSid).emit('group:invited', {
        groupId: req.params.id, groupName, addedByName, addedById: req.user.id,
        status: 'member',
      });
    }

    // Send push notification
    sendPush(userId, groupName, `${addedByName} הוסיף אותך לקבוצה`,
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

    // Update status to member (or insert if not exists)
    await pool.query(
      `INSERT INTO group_members (group_id, user_id, status) VALUES ($1, $2, 'member')
       ON CONFLICT (group_id, user_id) DO UPDATE SET status='member'`,
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

// ── Groups: invite non-member via SMS (admin) ─────────────────────
app.post('/api/groups/:id/invite-sms', auth, async (req, res) => {
  const { phone, contactName } = req.body;
  if (!phone) return res.status(400).json({ error: 'נדרש מספר טלפון' });
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
    const msg = `${greeting} ${senderName} מזמין אותך להצטרף לקבוצה "${groupName}" באפליקציית בתשובה. הורד את האפליקציה: https://betshuva.com`;

    const cleanPhone = phone.replace(/\D/g, '');
    await mailer.sendMail({
      from:    `"בתשובה" <${process.env.EMAIL_FROM}>`,
      to:      `${cleanPhone}@019sms.co.il`,
      subject: msg,
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
app.get('/api/admin/activity', auth, async (req, res) => {
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

// ── Admin: all users ─────────────────────────────────────────────
app.get('/api/admin/users', auth, async (req, res) => {
  try {
    const pool = await getPool();
    const result = await pool.query(
      `SELECT id, name, email, phone, email_verified, phone_verified,
              google_id, profile_pic_url, city, community,
              filter_level, created_at
       FROM users ORDER BY created_at DESC`);
    res.json(result.rows);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Admin: all games ─────────────────────────────────────────────
app.get('/api/admin/games', auth, async (req, res) => {
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
app.post('/api/send-otp', async (req, res) => {
  const { phone, name, email } = req.body;
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
    if (!existingPhone.rows.length && !authenticatedUser && cleanName.length < 2) {
      return res.status(400).json({ error: 'משתמש חדש חייב להזין שם מלא' });
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
  otpStore.set(clean, { code, expires, name: cleanName, email: cleanEmail });
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
app.post('/api/verify-otp', async (req, res) => {
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
        if (userName.length < 2) {
          return res.status(400).json({ error: 'משתמש חדש חייב להזין שם מלא' });
        }
        otpStore.delete(clean);
        const hash   = await bcrypt.hash(`otp_${clean}`, 10);
        const result = await pool.query(
          `INSERT INTO users (name, email, phone, password_hash, phone_verified, email_verified)
           VALUES ($1, $2, $3, $4, TRUE, TRUE)
           RETURNING id, name, email`,
          [userName, userEmail, clean, hash]);
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
app.post('/api/link-phone', auth, async (req, res) => {
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
app.post('/api/verify-phone', async (req, res) => {
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
        SELECT a.id, a.created_at, a.ip, a.action,
               u.name AS user_name, u.email AS user_email,
               a.details->>'fileName' AS file_name,
               a.details->>'reason'   AS reason,
               a.details->>'fileType' AS file_type,
               a.details->>'fileUrl'  AS file_url
        FROM activity_log a
        LEFT JOIN users u ON u.id = a.user_id
        WHERE a.action IN ('blocked_upload','blocked_upload_delayed')
        ORDER BY a.created_at DESC
        OFFSET ${offset} ROWS FETCH NEXT ${limit} ROWS ONLY
      `);
      const cnt = await pool.query(`
        SELECT COUNT(*)::int AS n FROM activity_log
        WHERE action IN ('blocked_upload','blocked_upload_delayed')`);
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
app.post('/api/admin/vision/test', adminAuth, upload.single('file'), async (req, res) => {
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
                     : filter === 'approved' ? `AND a.action = 'upload_file'`
                     : `AND a.action IN ('upload_file','blocked_upload','blocked_upload_delayed')`;
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
               faces: d.faces || [] };
    });
    res.json(rows);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Admin: re-scan all files and save Vision results ─────────────
app.post('/api/admin/vision/rescan', adminAuth, async (req, res) => {
  if (req.adminPerm !== 'edit') return res.status(403).json({ error: 'נדרשת הרשאת עריכה' });
  try {
    const pool = await getPool();
    // Get all image uploads without Vision results saved
    const result = await pool.query(`
      SELECT id, details FROM activity_log
      WHERE action IN ('upload_file','blocked_upload')
        AND details @> '{"fileType":"image"}'::jsonb
      ORDER BY created_at DESC
    `);
    let scanned = 0, updated = 0, failed = 0;
    for (const row of result.rows) {
      const d = row.details || {};
      if (!d.fileUrl) { failed++; continue; }
      if (d.safeSearch) { scanned++; continue; } // already has results
      try {
        const imgRes = await fetch(d.fileUrl, { signal: AbortSignal.timeout(10000) });
        if (!imgRes.ok) { failed++; continue; }
        const buf = Buffer.from(await imgRes.arrayBuffer());
        const sr  = await scanImage(buf);
        if (sr.pending) { failed++; continue; }
        d.safeSearch = sr.safeSearch;
        d.labels     = sr.labels;
        await pool.query('UPDATE activity_log SET details=$1 WHERE id=$2', [JSON.stringify(d), row.id]);
        updated++;
      } catch { failed++; }
    }
    res.json({ total: result.rows.length, scanned, updated, failed });
  } catch (e) { res.status(500).json({ error: e.message }); }
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
  res.json({ version: '1.2.8', apkUrl: 'https://betshuva.com/betshuva-app/app-release.apk' });
});

// ── Forgot Password ──────────────────────────────────────────────
app.post('/api/forgot-password', async (req, res) => {
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
app.post('/api/reset-password', async (req, res) => {
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
  try {
    const pool = await getPool();
    const rows = await pool.query(`
      SELECT * FROM pending_scans
      WHERE retry_count < 20
        AND (last_retry IS NULL OR last_retry < now() - interval '2 minutes')
      ORDER BY created_at ASC
      LIMIT 10
    `);

    for (const row of rows.rows) {
      try {
        // Update last_retry immediately to avoid double-processing
        await pool.query(`UPDATE pending_scans SET retry_count=retry_count+1, last_retry=now() WHERE id=$1`, [row.id]);

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
          const fileRes = await fetch(row.file_url);
          if (!fileRes.ok) continue;
          buffer = Buffer.from(await fileRes.arrayBuffer());
        }

        let scanResult;
        if (row.file_type === 'image') scanResult = await scanImage(buffer);
        else                           scanResult = await scanDocument(buffer, row.mime_type);

        if (scanResult.pending) continue; // service still unavailable

        // Remove from pending regardless of outcome
        await pool.query(`DELETE FROM pending_scans WHERE id=$1`, [row.id]);

        if (scanResult.blocked) {
          await pool.query(
            `UPDATE stored_files SET moderation_status='rejected', moderation_details=$1 WHERE public_url=$2`,
            [JSON.stringify(scanResult), row.file_url]);
          logActivity(row.user_id, 'blocked_upload_delayed',
            { fileName: row.file_name, reason: scanResult.reason, fileUrl: row.file_url });
          // Notify sender that file was rejected
          const sid = onlineUsers.get(row.user_id);
          if (sid) io.to(sid).emit('scan:rejected', { fileName: row.file_name, reason: scanResult.reason });
          if (row.to_user_id === SCAN_BOT_ID)
            await saveScanBotReport(pool, row.user_id, {
              name: row.file_name, size: 0, dbType: row.file_type,
            }, row.file_url, scanResult, 'rejected');
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
            const sid = onlineUsers.get(row.user_id);
            if (sid) io.to(sid).emit('scan:rejected', { fileName: row.file_name, reason });
            await pool.query(
              `UPDATE stored_files SET moderation_status='rejected', moderation_details=$1 WHERE public_url=$2`,
              [JSON.stringify({ reason, classification: scanResult.classification || null }), row.file_url]);
            continue;
          }
        }

        await pool.query(
          `UPDATE stored_files SET moderation_status='approved', moderation_details=$1 WHERE public_url=$2`,
          [JSON.stringify(scanResult || {}), row.file_url]);

        if (row.to_user_id === SCAN_BOT_ID) {
          await saveScanBotReport(pool, row.user_id, {
            name: row.file_name, size: 0, dbType: row.file_type,
          }, row.file_url, scanResult, 'approved');
          continue;
        }

        // Scan passed — save message and deliver
        if (row.to_user_id) {
          const saved = await pool.query(
            `INSERT INTO messages (sender_id, recipient_id, type, body, file_url, file_name)
             VALUES ($1, $2, $3, $4, $5, $4)
             RETURNING id, created_at`,
            [row.user_id, row.to_user_id, row.file_type, row.file_name, row.file_url]);
          const msg = saved.rows[0];
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
            { toUserId: row.to_user_id, fileName: row.file_name, fileUrl: row.file_url, fileType: row.file_type });
        }
      } catch (e) { console.error('retry row', row.id, e.message); }
    }
  } catch (e) { console.error('retryPendingScans:', e.message); }
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
