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
const { getPool, sql } = require('./db');

// ── FCM via HTTP Legacy API (no service account key needed) ───────
async function sendPush(userId, title, body, data = {}) {
  const serverKey = process.env.FCM_SERVER_KEY;
  if (!serverKey) return;
  try {
    const pool   = await getPool();
    const result = await pool.request()
      .input('userId', sql.UniqueIdentifier, userId)
      .query('SELECT token FROM fcm_tokens WHERE user_id = @userId');
    for (const { token } of result.recordset) {
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
        pool.request().input('token', sql.NVarChar, token)
          .query('DELETE FROM fcm_tokens WHERE token=@token').catch(() => {});
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
};
const BLOCKED_TYPES = ['video/', 'application/x-mpegURL'];

const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 25 * 1024 * 1024 },
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
  const cdnBase = (process.env.CDN_BASE_URL || '').replace(/\/$/, '');
  const auth     = await b2Auth();
  const bucketId = await b2BucketId(auth);

  // Get one-time upload URL
  const urlRes  = await fetch(`${auth.apiUrl}/b2api/v2/b2_get_upload_url`, {
    method:  'POST',
    headers: { Authorization: auth.token, 'Content-Type': 'application/json' },
    body:    JSON.stringify({ bucketId }),
  });
  const urlData = await urlRes.json();
  if (!urlRes.ok) throw new Error(`b2_get_upload_url: ${urlData.message}`);

  // Upload
  const sha1   = crypto.createHash('sha1').update(buffer).digest('hex');
  const upRes  = await fetch(urlData.uploadUrl, {
    method:  'POST',
    headers: {
      Authorization:    urlData.authorizationToken,
      'X-Bz-File-Name': encodeURIComponent(key).replace(/%2F/g, '/'),
      'Content-Type':   contentType,
      'Content-Length': String(buffer.length),
      'X-Bz-Content-Sha1': sha1,
    },
    body: buffer,
  });
  const upData = await upRes.json();
  if (!upRes.ok) throw new Error(`b2_upload_file: ${upData.message}`);
  return `${cdnBase}/${key}`;
}

// ── Content Moderation ────────────────────────────────────────────

const FEMALE_LABELS = ['woman','women','girl','female','lady','ladies','bride','actress'];
const BLOCKED_WORDS = [
  'עירום','פורנו','סקס','ניאוף','תועבה','זנות','חשפנות',
  'porn','nude','naked','xxx','sex','erotic','adult content',
];

async function scanImage(buffer) {
  const key = process.env.GOOGLE_VISION_API_KEY;
  if (!key) return { pending: true };

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

  if (BAD.includes(ss.adult) || BAD.includes(ss.racy))
    return { blocked: true, reason: 'התמונה נחסמה — תוכן לא צנוע' };

  const labels = (ann.labelAnnotations || []).map(l => l.description.toLowerCase());
  if (labels.some(l => FEMALE_LABELS.some(f => l.includes(f))))
    return { blocked: true, reason: 'התמונה נחסמה — תמונות של נשים אינן מורשות' };

  return { blocked: false };
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
  port: 465,
  secure: true,
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

// Auto-migrate: create all messenger tables
(async () => {
  try {
    const pool = await getPool();

    // ── Auth tokens ────────────────────────────────────────────────
    await pool.request().query(`
      IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='password_reset_tokens' AND xtype='U')
      CREATE TABLE password_reset_tokens (
        token      NVARCHAR(64)     PRIMARY KEY,
        user_id    UNIQUEIDENTIFIER NOT NULL REFERENCES users(id),
        expires_at DATETIME         NOT NULL,
        used       BIT              DEFAULT 0
      )`);

    await pool.request().query(`
      IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='email_verification_tokens' AND xtype='U')
      CREATE TABLE email_verification_tokens (
        token      NVARCHAR(64)     PRIMARY KEY,
        user_id    UNIQUEIDENTIFIER NOT NULL REFERENCES users(id),
        expires_at DATETIME         NOT NULL,
        used       BIT              DEFAULT 0
      )`);

    // ── Users – new columns ────────────────────────────────────────
    await pool.request().query(`
      IF NOT EXISTS (SELECT * FROM sys.columns WHERE object_id=OBJECT_ID('users') AND name='email_verified')
        ALTER TABLE users ADD email_verified BIT NOT NULL DEFAULT 0`);
    await pool.request().query(`
      IF NOT EXISTS (SELECT * FROM sys.columns WHERE object_id=OBJECT_ID('users') AND name='phone')
        ALTER TABLE users ADD phone NVARCHAR(20)`);
    await pool.request().query(`
      IF NOT EXISTS (SELECT * FROM sys.columns WHERE object_id=OBJECT_ID('users') AND name='phone_verified')
        ALTER TABLE users ADD phone_verified BIT NOT NULL DEFAULT 0`);
    await pool.request().query(`
      IF NOT EXISTS (SELECT * FROM sys.columns WHERE object_id=OBJECT_ID('users') AND name='city')
        ALTER TABLE users ADD city NVARCHAR(100)`);
    await pool.request().query(`
      IF NOT EXISTS (SELECT * FROM sys.columns WHERE object_id=OBJECT_ID('users') AND name='community')
        ALTER TABLE users ADD community NVARCHAR(100)`);
    await pool.request().query(`
      IF NOT EXISTS (SELECT * FROM sys.columns WHERE object_id=OBJECT_ID('users') AND name='profile_pic_url')
        ALTER TABLE users ADD profile_pic_url NVARCHAR(500)`);
    await pool.request().query(`
      IF NOT EXISTS (SELECT * FROM sys.columns WHERE object_id=OBJECT_ID('users') AND name='privacy_pic')
        ALTER TABLE users ADD privacy_pic NVARCHAR(20) NOT NULL DEFAULT 'all'`);
    await pool.request().query(`
      IF NOT EXISTS (SELECT * FROM sys.columns WHERE object_id=OBJECT_ID('users') AND name='filter_level')
        ALTER TABLE users ADD filter_level NVARCHAR(20) NOT NULL DEFAULT 'standard'`);

    // ── Allow phone-only / email-only accounts ─────────────────────
    await pool.request().query(`
      IF COLUMNPROPERTY(OBJECT_ID('users'), 'email', 'AllowsNull') = 0
        ALTER TABLE users ALTER COLUMN email NVARCHAR(255) NULL`);
    await pool.request().query(`
      IF COLUMNPROPERTY(OBJECT_ID('users'), 'password_hash', 'AllowsNull') = 0
        ALTER TABLE users ALTER COLUMN password_hash NVARCHAR(255) NULL`);
    await pool.request().query(`
      IF NOT EXISTS (SELECT * FROM sys.columns WHERE object_id=OBJECT_ID('users') AND name='google_id')
        ALTER TABLE users ADD google_id NVARCHAR(128)`);
    await pool.request().query(`
      IF NOT EXISTS (SELECT * FROM sys.columns WHERE object_id=OBJECT_ID('users') AND name='country')
        ALTER TABLE users ADD country NVARCHAR(100)`);
    await pool.request().query(`
      IF NOT EXISTS (SELECT * FROM sys.columns WHERE object_id=OBJECT_ID('users') AND name='street')
        ALTER TABLE users ADD street NVARCHAR(200)`);
    await pool.request().query(`
      IF NOT EXISTS (SELECT * FROM sys.columns WHERE object_id=OBJECT_ID('users') AND name='house_number')
        ALTER TABLE users ADD house_number NVARCHAR(20)`);
    await pool.request().query(`
      IF NOT EXISTS (SELECT * FROM sys.columns WHERE object_id=OBJECT_ID('users') AND name='apartment')
        ALTER TABLE users ADD apartment NVARCHAR(20)`);

    // ── group_members: pending membership columns ──────────────────
    await pool.request().query(`
      IF NOT EXISTS (SELECT * FROM sys.columns WHERE object_id=OBJECT_ID('group_members') AND name='status')
        ALTER TABLE group_members ADD status NVARCHAR(20) NOT NULL DEFAULT 'member'`);
    await pool.request().query(`
      IF NOT EXISTS (SELECT * FROM sys.columns WHERE object_id=OBJECT_ID('group_members') AND name='added_by')
        ALTER TABLE group_members ADD added_by UNIQUEIDENTIFIER`);
    await pool.request().query(`
      IF NOT EXISTS (SELECT * FROM sys.columns WHERE object_id=OBJECT_ID('group_members') AND name='pending_since')
        ALTER TABLE group_members ADD pending_since DATETIME`);

    // ── Admin permissions ──────────────────────────────────────────
    await pool.request().query(`
      IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='admin_permissions' AND xtype='U')
      CREATE TABLE admin_permissions (
        user_id    UNIQUEIDENTIFIER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        permission NVARCHAR(10) NOT NULL DEFAULT 'view',
        granted_at DATETIME DEFAULT GETDATE(),
        PRIMARY KEY (user_id)
      )`);
    // Seed betshuva@betshuva.com as edit admin
    await pool.request().query(`
      IF NOT EXISTS (
        SELECT 1 FROM admin_permissions ap
        JOIN users u ON u.id = ap.user_id
        WHERE u.email = 'betshuva@betshuva.com'
      )
      INSERT INTO admin_permissions (user_id, permission)
      SELECT id, 'edit' FROM users WHERE email = 'betshuva@betshuva.com'`);

    // ── Groups ─────────────────────────────────────────────────────
    await pool.request().query(`
      IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='groups' AND xtype='U')
      CREATE TABLE groups (
        id              UNIQUEIDENTIFIER DEFAULT NEWID() PRIMARY KEY,
        name            NVARCHAR(100) NOT NULL,
        description     NVARCHAR(500),
        creator_id      UNIQUEIDENTIFIER REFERENCES users(id),
        is_broadcast    BIT          NOT NULL DEFAULT 0,
        send_permission NVARCHAR(20) NOT NULL DEFAULT 'all',
        filter_level    NVARCHAR(20) NOT NULL DEFAULT 'standard',
        created_at      DATETIME     DEFAULT GETDATE()
      )`);

    // ── Messages ───────────────────────────────────────────────────
    await pool.request().query(`
      IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='messages' AND xtype='U')
      CREATE TABLE messages (
        id                   UNIQUEIDENTIFIER DEFAULT NEWID() PRIMARY KEY,
        sender_id            UNIQUEIDENTIFIER NOT NULL REFERENCES users(id),
        recipient_id         UNIQUEIDENTIFIER REFERENCES users(id),
        group_id             UNIQUEIDENTIFIER REFERENCES groups(id),
        type                 NVARCHAR(20)  NOT NULL DEFAULT 'text',
        body                 NVARCHAR(MAX),
        file_url             NVARCHAR(500),
        file_name            NVARCHAR(255),
        file_size            INT,
        reply_to_id          UNIQUEIDENTIFIER REFERENCES messages(id),
        deleted_for_sender   BIT NOT NULL DEFAULT 0,
        deleted_for_everyone BIT NOT NULL DEFAULT 0,
        created_at           DATETIME DEFAULT GETDATE()
      )`);

    // ── Message Status ─────────────────────────────────────────────
    await pool.request().query(`
      IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='message_status' AND xtype='U')
      CREATE TABLE message_status (
        message_id UNIQUEIDENTIFIER NOT NULL REFERENCES messages(id),
        user_id    UNIQUEIDENTIFIER NOT NULL REFERENCES users(id),
        status     NVARCHAR(20)     NOT NULL DEFAULT 'delivered',
        updated_at DATETIME         DEFAULT GETDATE(),
        PRIMARY KEY (message_id, user_id)
      )`);

    // ── Group Members ──────────────────────────────────────────────
    await pool.request().query(`
      IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='group_members' AND xtype='U')
      CREATE TABLE group_members (
        group_id  UNIQUEIDENTIFIER NOT NULL REFERENCES groups(id),
        user_id   UNIQUEIDENTIFIER NOT NULL REFERENCES users(id),
        role      NVARCHAR(20)     NOT NULL DEFAULT 'member',
        joined_at DATETIME         DEFAULT GETDATE(),
        PRIMARY KEY (group_id, user_id)
      )`);

    // ── Blocked Users ──────────────────────────────────────────────
    await pool.request().query(`
      IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='blocked_users' AND xtype='U')
      CREATE TABLE blocked_users (
        blocker_id UNIQUEIDENTIFIER NOT NULL REFERENCES users(id),
        blocked_id UNIQUEIDENTIFIER NOT NULL REFERENCES users(id),
        created_at DATETIME         DEFAULT GETDATE(),
        PRIMARY KEY (blocker_id, blocked_id)
      )`);

    // ── Audit Log ──────────────────────────────────────────────────
    await pool.request().query(`
      IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='audit_log' AND xtype='U')
      CREATE TABLE audit_log (
        id         UNIQUEIDENTIFIER DEFAULT NEWID() PRIMARY KEY,
        user_id    UNIQUEIDENTIFIER REFERENCES users(id),
        file_name  NVARCHAR(255),
        file_type  NVARCHAR(50),
        file_size  INT,
        reason     NVARCHAR(500),
        appealed   BIT NOT NULL DEFAULT 0,
        created_at DATETIME DEFAULT GETDATE()
      )`);

    // ── FCM Tokens ─────────────────────────────────────────────────
    await pool.request().query(`
      IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='fcm_tokens' AND xtype='U')
      CREATE TABLE fcm_tokens (
        user_id    UNIQUEIDENTIFIER NOT NULL REFERENCES users(id),
        token      NVARCHAR(500)    NOT NULL,
        device_id  NVARCHAR(255)    NOT NULL DEFAULT 'default',
        updated_at DATETIME         DEFAULT GETDATE(),
        PRIMARY KEY (user_id, device_id)
      )`);

    // ── Activity Log ───────────────────────────────────────────────
    await pool.request().query(`
      IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='activity_log' AND xtype='U')
      CREATE TABLE activity_log (
        id         UNIQUEIDENTIFIER DEFAULT NEWID() PRIMARY KEY,
        user_id    UNIQUEIDENTIFIER REFERENCES users(id),
        action     NVARCHAR(50)     NOT NULL,
        details    NVARCHAR(MAX),
        ip         NVARCHAR(50),
        created_at DATETIME         DEFAULT GETDATE()
      )`);

    console.log('Migration: all tables ready');
  } catch (e) { console.error('Migration error:', e.message); }
})();

// ── Activity logger ───────────────────────────────────────────────
async function logActivity(userId, action, details = {}, ip = null) {
  try {
    const pool = await getPool();
    await pool.request()
      .input('userId',  sql.UniqueIdentifier, userId || null)
      .input('action',  sql.NVarChar,         action)
      .input('details', sql.NVarChar,         JSON.stringify(details))
      .input('ip',      sql.NVarChar,         ip || null)
      .query(`INSERT INTO activity_log (user_id, action, details, ip)
              VALUES (@userId, @action, @details, @ip)`);
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

const JWT_SECRET = process.env.JWT_SECRET || 'change-this-secret';
const onlineUsers = new Map(); // userId → socketId
const otpStore    = new Map(); // phone → { code, expires, name }

function auth(req, res, next) {
  const token = req.headers.authorization?.split(' ')[1];
  if (!token) return res.status(401).json({ error: 'לא מחובר' });
  try {
    req.user = jwt.verify(token, JWT_SECRET);
    next();
  } catch {
    res.status(401).json({ error: 'טוקן לא תקין' });
  }
}

// ── Socket.io ────────────────────────────────────────────────────
io.use(async (socket, next) => {
  try {
    socket.user = jwt.verify(socket.handshake.auth.token, JWT_SECRET);
    // וידוא שהמשתמש עדיין קיים בבסיס הנתונים
    const pool = await getPool();
    const exists = await pool.request()
      .input('id', sql.UniqueIdentifier, socket.user.id)
      .query('SELECT 1 FROM users WHERE id = @id');
    if (!exists.recordset.length) return next(new Error('user_not_found'));
    next();
  } catch {
    next(new Error('unauthorized'));
  }
});

io.on('connection', async (socket) => {
  onlineUsers.set(socket.user.id, socket.id);
  io.emit('users:online', [...onlineUsers.keys()]);

  // Join all group rooms this user belongs to
  try {
    const pool = await getPool();
    const grps = await pool.request()
      .input('userId', sql.UniqueIdentifier, socket.user.id)
      .query("SELECT group_id FROM group_members WHERE user_id = @userId AND status = 'member'");
    for (const { group_id } of grps.recordset) socket.join(`group:${group_id}`);
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
      const blocked = await pool.request()
        .input('blocker', sql.UniqueIdentifier, toUserId)
        .input('blocked', sql.UniqueIdentifier, socket.user.id)
        .query('SELECT 1 FROM blocked_users WHERE blocker_id=@blocker AND blocked_id=@blocked');
      if (blocked.recordset.length) return;
      const saved = await pool.request()
        .input('senderId',    sql.UniqueIdentifier, socket.user.id)
        .input('recipientId', sql.UniqueIdentifier, toUserId)
        .input('body',        sql.NVarChar,         text     || null)
        .input('type',        sql.NVarChar,         fileType || 'text')
        .input('fileUrl',     sql.NVarChar,         fileUrl  || null)
        .input('fileName',    sql.NVarChar,         fileName || null)
        .input('replyToId',   sql.UniqueIdentifier, replyToId || null)
        .query(`INSERT INTO messages (sender_id, recipient_id, body, type, file_url, file_name, reply_to_id)
                OUTPUT INSERTED.id, INSERTED.created_at
                VALUES (@senderId, @recipientId, @body, @type, @fileUrl, @fileName, @replyToId)`);
      const row = saved.recordset[0];
      relay(toUserId, 'chat:message', {
        id: row.id, fromUserId: socket.user.id, fromName: socket.user.name,
        text, replyToId: replyToId || null, createdAt: row.created_at,
        fileUrl, fileName, fileType,
      });
      // שליפת שם הנמען לרישום קריא בפעילות
      const recip = await pool.request()
        .input('id', sql.UniqueIdentifier, toUserId)
        .query('SELECT name FROM users WHERE id=@id');
      const toName = recip.recordset[0]?.name || toUserId;
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
  socket.on('group:message', async ({ groupId, text, replyToId }) => {
    if (!text || !groupId) return;
    try {
      const pool = await getPool();
      const mem = await pool.request()
        .input('groupId', sql.UniqueIdentifier, groupId)
        .input('userId',  sql.UniqueIdentifier, socket.user.id)
        .query(`SELECT gm.role, g.send_permission FROM group_members gm
                JOIN groups g ON g.id = gm.group_id
                WHERE gm.group_id = @groupId AND gm.user_id = @userId`);
      const member = mem.recordset[0];
      if (!member) return;
      if (member.send_permission === 'admin' && member.role !== 'admin') return;

      const saved = await pool.request()
        .input('senderId',  sql.UniqueIdentifier, socket.user.id)
        .input('groupId',   sql.UniqueIdentifier, groupId)
        .input('body',      sql.NVarChar,         text)
        .input('replyToId', sql.UniqueIdentifier, replyToId || null)
        .query(`INSERT INTO messages (sender_id, group_id, body, reply_to_id)
                OUTPUT INSERTED.id, INSERTED.created_at
                VALUES (@senderId, @groupId, @body, @replyToId)`);
      const row = saved.recordset[0];
      io.to(`group:${groupId}`).emit('group:message', {
        id:         row.id,
        groupId,
        fromUserId: socket.user.id,
        fromName:   socket.user.name,
        text,
        replyToId:  replyToId || null,
        createdAt:  row.created_at,
      });
      logActivity(socket.user.id, 'send_group_message', { groupId, messageId: row.id });
      // Push to offline members
      const grpName = await pool.request()
        .input('id', sql.UniqueIdentifier, groupId)
        .query('SELECT name FROM groups WHERE id = @id');
      const groupName = grpName.recordset[0]?.name || 'קבוצה';
      const allMembers = await pool.request()
        .input('groupId', sql.UniqueIdentifier, groupId)
        .query('SELECT user_id FROM group_members WHERE group_id = @groupId');
      for (const { user_id } of allMembers.recordset) {
        if (user_id !== socket.user.id && !onlineUsers.has(user_id)) {
          sendPush(user_id, `${groupName} • ${socket.user.name}`,
            text || '', { type: 'group', groupId });
        }
      }
    } catch (e) { console.error('group:message:', e.message); }
  });

  socket.on('group:typing', ({ groupId }) =>
    socket.to(`group:${groupId}`).emit('group:typing', {
      fromUserId: socket.user.id,
      fromName:   socket.user.name,
    }));

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
  const { name, email, password, phone } = req.body;
  if (!name) return res.status(400).json({ error: 'חסר שם' });
  const hasEmail = !!(email && password);
  const hasPhone = !!phone;
  if (!hasEmail && !hasPhone)
    return res.status(400).json({ error: 'יש לספק אימייל עם סיסמה, מספר טלפון, או שניהם' });

  const cleanPhone = hasPhone ? phone.replace(/\D/g, '') : null;
  if (hasPhone && cleanPhone.length < 9)
    return res.status(400).json({ error: 'מספר טלפון לא תקין' });
  try {
    const pool = await getPool();
    if (hasEmail) {
      const emailExists = await pool.request()
        .input('email', sql.NVarChar, email)
        .query('SELECT id FROM users WHERE email = @email');
      if (emailExists.recordset.length) return res.status(400).json({ error: 'האימייל כבר רשום' });
    }
    if (hasPhone) {
      const phoneExists = await pool.request()
        .input('phone', sql.NVarChar, cleanPhone)
        .query('SELECT id FROM users WHERE phone = @phone');
      if (phoneExists.recordset.length) return res.status(400).json({ error: 'מספר הטלפון כבר רשום' });
    }

    const hash = hasEmail ? await bcrypt.hash(password, 10) : null;
    const result = await pool.request()
      .input('name',  sql.NVarChar, name)
      .input('email', sql.NVarChar, hasEmail ? email : null)
      .input('phone', sql.NVarChar, hasPhone ? cleanPhone : null)
      .input('hash',  sql.NVarChar, hash)
      .query(`INSERT INTO users (name, email, phone, password_hash)
              OUTPUT INSERTED.id, INSERTED.name, INSERTED.email
              VALUES (@name, @email, @phone, @hash)`);
    const user = result.recordset[0];

    if (hasEmail) {
      const emailToken = crypto.randomBytes(32).toString('hex');
      const expires24h = new Date(Date.now() + 24 * 60 * 60 * 1000);
      await pool.request()
        .input('token',   sql.NVarChar,        emailToken)
        .input('userId',  sql.UniqueIdentifier, user.id)
        .input('expires', sql.DateTime,         expires24h)
        .query('INSERT INTO email_verification_tokens (token, user_id, expires_at) VALUES (@token, @userId, @expires)');
      const base = process.env.APP_URL || 'https://xo-app-betshuva.azurewebsites.net';
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
    res.json({ pending: true, phone: cleanPhone, hasEmail, hasPhone });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// ── Login ────────────────────────────────────────────────────────
app.post('/api/login', async (req, res) => {
  const { email, password } = req.body;
  try {
    const pool = await getPool();
    const result = await pool.request()
      .input('email', sql.NVarChar, email)
      .query('SELECT * FROM users WHERE email = @email');
    const user = result.recordset[0];
    if (!user || !user.password_hash || !(await bcrypt.compare(password, user.password_hash)))
      return res.status(401).json({ error: 'אימייל או סיסמה שגויים' });
    if (!user.email_verified)
      return res.status(403).json({ error: 'יש לאמת את כתובת האימייל תחילה — בדוק את תיבת הדואר שלך', code: 'EMAIL_UNVERIFIED' });

    const token = jwt.sign({ id: user.id, name: user.name, email: user.email }, JWT_SECRET);
    const { password_hash, ...safeUser } = user;
    logActivity(user.id, 'login', { email: user.email }, req.ip);
    res.json({ token, user: safeUser });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// ── Google Sign-In ────────────────────────────────────────────────
app.post('/api/auth/google', async (req, res) => {
  const { idToken } = req.body;
  if (!idToken) return res.status(400).json({ error: 'חסר idToken' });
  try {
    const tokenRes = await fetch(`https://oauth2.googleapis.com/tokeninfo?id_token=${encodeURIComponent(idToken)}`);
    const payload  = await tokenRes.json();
    if (payload.error_description || !payload.sub)
      return res.status(401).json({ error: 'טוקן גוגל לא תקין' });

    const clientId = process.env.GOOGLE_CLIENT_ID;
    if (clientId && payload.aud !== clientId)
      return res.status(401).json({ error: 'Client ID לא תואם' });

    const { sub: googleId, email, name, picture } = payload;
    const pool = await getPool();

    // 1. Find by google_id
    let byGoogle = await pool.request()
      .input('googleId', sql.NVarChar, googleId)
      .query('SELECT * FROM users WHERE google_id = @googleId');

    if (byGoogle.recordset.length) {
      const user  = byGoogle.recordset[0];
      const token = jwt.sign({ id: user.id, name: user.name, email: user.email }, JWT_SECRET);
      logActivity(user.id, 'google_login', { email: user.email }, req.ip);
      const { password_hash, ...safeUser } = user;
      return res.json({ token, user: safeUser });
    }

    // 2. Find by email — link google_id
    if (email) {
      const byEmail = await pool.request()
        .input('email', sql.NVarChar, email)
        .query('SELECT * FROM users WHERE email = @email');
      if (byEmail.recordset.length) {
        const user = byEmail.recordset[0];
        await pool.request()
          .input('id',       sql.UniqueIdentifier, user.id)
          .input('googleId', sql.NVarChar,         googleId)
          .input('picture',  sql.NVarChar,         picture || null)
          .query(`UPDATE users
                  SET google_id=@googleId, email_verified=1,
                      profile_pic_url=COALESCE(profile_pic_url, @picture)
                  WHERE id=@id`);
        const token = jwt.sign({ id: user.id, name: user.name, email: user.email }, JWT_SECRET);
        logActivity(user.id, 'google_login', { email: user.email }, req.ip);
        const { password_hash, ...safeUser } = user;
        return res.json({ token, user: safeUser });
      }
    }

    // 3. Create new user
    const inserted = await pool.request()
      .input('name',     sql.NVarChar, name || (email ? email.split('@')[0] : 'משתמש'))
      .input('email',    sql.NVarChar, email || null)
      .input('googleId', sql.NVarChar, googleId)
      .input('picture',  sql.NVarChar, picture || null)
      .query(`INSERT INTO users (name, email, email_verified, google_id, profile_pic_url)
              OUTPUT INSERTED.*
              VALUES (@name, @email, 1, @googleId, @picture)`);
    const user  = inserted.recordset[0];
    const token = jwt.sign({ id: user.id, name: user.name, email: user.email }, JWT_SECRET);
    logActivity(user.id, 'google_register', { email: user.email }, req.ip);
    const { password_hash, ...safeUser } = user;
    res.json({ token, user: safeUser });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// ── Users ─────────────────────────────────────────────────────────
app.get('/api/users', auth, async (req, res) => {
  try {
    const pool = await getPool();
    const result = await pool.request()
      .input('myId', sql.UniqueIdentifier, req.user.id)
      .query(`SELECT id, name, profile_pic_url, city, community, phone
              FROM users
              WHERE id != @myId
              AND id NOT IN (
                SELECT blocked_id FROM blocked_users WHERE blocker_id = @myId
              )
              ORDER BY name`);
    res.json(result.recordset);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
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
    // Build a values list for IN clause using parameterized inputs
    const inputs = normalized.map((p, i) => `@p${i}`).join(',');
    const req2 = pool.request().input('myId', sql.UniqueIdentifier, req.user.id);
    normalized.forEach((p, i) => req2.input(`p${i}`, sql.NVarChar, p));
    const result = await req2.query(
      `SELECT id, name, profile_pic_url, phone
       FROM users
       WHERE phone IN (${inputs})
         AND id != @myId
         AND id NOT IN (SELECT blocked_id FROM blocked_users WHERE blocker_id = @myId)`
    );
    res.json(result.recordset);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Messages: load history ─────────────────────────────────────────
app.get('/api/messages/:userId', auth, async (req, res) => {
  const otherId = req.params.userId;
  const myId    = req.user.id;
  const before  = req.query.before; // ISO date for pagination
  try {
    const pool = await getPool();
    const req2 = pool.request()
      .input('myId',    sql.UniqueIdentifier, myId)
      .input('otherId', sql.UniqueIdentifier, otherId);
    if (before) req2.input('before', sql.DateTime, new Date(before));

    const result = await req2.query(`
      SELECT TOP 50
        m.id, m.sender_id, m.recipient_id, m.type,
        m.body, m.file_url, m.file_name, m.file_size,
        m.reply_to_id, m.created_at,
        r.body        AS reply_body,
        ru.name       AS reply_sender_name,
        CASE WHEN ms.status = 'read' THEN 1 ELSE 0 END AS is_read
      FROM messages m
      LEFT JOIN messages r  ON m.reply_to_id = r.id
      LEFT JOIN users ru    ON r.sender_id = ru.id
      LEFT JOIN message_status ms ON ms.message_id = m.id AND ms.user_id = @myId
      WHERE m.deleted_for_everyone = 0
        AND (
          (m.sender_id = @myId    AND m.recipient_id = @otherId AND m.deleted_for_sender = 0)
          OR
          (m.sender_id = @otherId AND m.recipient_id = @myId)
        )
        ${before ? 'AND m.created_at < @before' : ''}
      ORDER BY m.created_at DESC
    `);
    res.json(result.recordset.reverse());
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// ── Messages: mark as read ─────────────────────────────────────────
app.put('/api/messages/read', auth, async (req, res) => {
  const { senderId } = req.body;
  if (!senderId) return res.status(400).json({ error: 'חסר senderId' });
  try {
    const pool = await getPool();
    const msgs = await pool.request()
      .input('recipientId', sql.UniqueIdentifier, req.user.id)
      .input('senderId',    sql.UniqueIdentifier, senderId)
      .query(`SELECT id FROM messages
              WHERE recipient_id = @recipientId AND sender_id = @senderId
              AND deleted_for_everyone = 0`);

    for (const { id } of msgs.recordset) {
      await pool.request()
        .input('msgId',  sql.UniqueIdentifier, id)
        .input('userId', sql.UniqueIdentifier, req.user.id)
        .query(`IF NOT EXISTS (SELECT 1 FROM message_status WHERE message_id=@msgId AND user_id=@userId)
                  INSERT INTO message_status (message_id, user_id, status) VALUES (@msgId, @userId, 'read')
                ELSE
                  UPDATE message_status SET status='read', updated_at=GETDATE()
                  WHERE message_id=@msgId AND user_id=@userId`);
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
    const found = await pool.request()
      .input('id', sql.UniqueIdentifier, req.params.id)
      .query('SELECT sender_id, recipient_id FROM messages WHERE id = @id');
    const msg = found.recordset[0];
    if (!msg) return res.status(404).json({ error: 'הודעה לא נמצאה' });

    if (forEveryone && msg.sender_id === req.user.id) {
      await pool.request()
        .input('id', sql.UniqueIdentifier, req.params.id)
        .query('UPDATE messages SET deleted_for_everyone=1, body=NULL WHERE id=@id');
      const sid = onlineUsers.get(msg.recipient_id);
      if (sid) io.to(sid).emit('message:deleted', { id: req.params.id });
    } else {
      await pool.request()
        .input('id',     sql.UniqueIdentifier, req.params.id)
        .input('userId', sql.UniqueIdentifier, req.user.id)
        .query('UPDATE messages SET deleted_for_sender=1 WHERE id=@id AND sender_id=@userId');
    }
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// ── Block: block user ─────────────────────────────────────────────
app.post('/api/block/:userId', auth, async (req, res) => {
  if (req.params.userId === req.user.id) return res.status(400).json({ error: 'לא ניתן לחסום את עצמך' });
  try {
    const pool = await getPool();
    await pool.request()
      .input('blocker', sql.UniqueIdentifier, req.user.id)
      .input('blocked', sql.UniqueIdentifier, req.params.userId)
      .query(`IF NOT EXISTS (SELECT 1 FROM blocked_users WHERE blocker_id=@blocker AND blocked_id=@blocked)
              INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (@blocker, @blocked)`);
    logActivity(req.user.id, 'block_user', { blockedUserId: req.params.userId }, req.ip);
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Block: unblock user ───────────────────────────────────────────
app.delete('/api/block/:userId', auth, async (req, res) => {
  try {
    const pool = await getPool();
    await pool.request()
      .input('blocker', sql.UniqueIdentifier, req.user.id)
      .input('blocked', sql.UniqueIdentifier, req.params.userId)
      .query('DELETE FROM blocked_users WHERE blocker_id=@blocker AND blocked_id=@blocked');
    logActivity(req.user.id, 'unblock_user', { unblockedUserId: req.params.userId }, req.ip);
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Block: list blocked users ─────────────────────────────────────
app.get('/api/blocked', auth, async (req, res) => {
  try {
    const pool = await getPool();
    const result = await pool.request()
      .input('blocker', sql.UniqueIdentifier, req.user.id)
      .query(`SELECT u.id, u.name, u.profile_pic_url
              FROM blocked_users b
              JOIN users u ON u.id = b.blocked_id
              WHERE b.blocker_id = @blocker
              ORDER BY u.name`);
    res.json(result.recordset);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Profile: get ──────────────────────────────────────────────────
app.get('/api/profile', auth, async (req, res) => {
  try {
    const pool = await getPool();
    const result = await pool.request()
      .input('id', sql.UniqueIdentifier, req.user.id)
      .query(`SELECT id, name, email, phone, email_verified, phone_verified,
                     city, community, country, street, house_number, apartment,
                     profile_pic_url, privacy_pic, filter_level
              FROM users WHERE id = @id`);
    if (!result.recordset.length) return res.status(404).json({ error: 'לא נמצא' });
    res.json(result.recordset[0]);
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
    await pool.request()
      .input('id',          sql.UniqueIdentifier, req.user.id)
      .input('name',        sql.NVarChar,         name.trim())
      .input('city',        sql.NVarChar,         city         || null)
      .input('community',   sql.NVarChar,         community    || null)
      .input('country',     sql.NVarChar,         country      || 'ישראל')
      .input('street',      sql.NVarChar,         street       || null)
      .input('houseNum',    sql.NVarChar,         house_number || null)
      .input('apartment',   sql.NVarChar,         apartment    || null)
      .input('privacyPic',  sql.NVarChar,         validPrivacy.includes(privacy_pic) ? privacy_pic  : 'all')
      .input('filterLevel', sql.NVarChar,         validFilter.includes(filter_level) ? filter_level : 'standard')
      .input('picUrl',      sql.NVarChar,         profile_pic_url || null)
      .query(`UPDATE users
              SET name=@name, city=@city, community=@community,
                  country=@country, street=@street, house_number=@houseNum, apartment=@apartment,
                  privacy_pic=@privacyPic, filter_level=@filterLevel,
                  profile_pic_url=@picUrl
              WHERE id=@id`);
    logActivity(req.user.id, 'update_profile', { name: name.trim(), city, country }, req.ip);
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── FCM Token: register / refresh ────────────────────────────────
app.post('/api/fcm-token', auth, async (req, res) => {
  const { token, deviceId } = req.body;
  if (!token) return res.status(400).json({ error: 'נדרש token' });
  try {
    const pool = await getPool();
    await pool.request()
      .input('userId',   sql.UniqueIdentifier, req.user.id)
      .input('token',    sql.NVarChar,         token)
      .input('deviceId', sql.NVarChar,         deviceId || 'default')
      .query(`IF EXISTS (SELECT 1 FROM fcm_tokens WHERE user_id=@userId AND device_id=@deviceId)
                UPDATE fcm_tokens SET token=@token, updated_at=GETDATE()
                WHERE user_id=@userId AND device_id=@deviceId
              ELSE
                INSERT INTO fcm_tokens (user_id, token, device_id) VALUES (@userId, @token, @deviceId)`);
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── File Upload ───────────────────────────────────────────────────
app.post('/api/upload', auth, upload.single('file'), async (req, res) => {
  const file = req.file;
  if (!file) return res.status(400).json({ error: 'לא נשלח קובץ' });

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
    // Content moderation scan
    let scanResult;
    if (allowed.dbType === 'image')
      scanResult = await scanImage(file.buffer);
    else if (allowed.dbType === 'document')
      scanResult = await scanDocument(file.buffer, file.mimetype);

    if (scanResult?.blocked) {
      logActivity(req.user.id, 'blocked_upload',
        { fileName: file.originalname, reason: scanResult.reason }, req.ip);
      return res.status(400).json({ error: scanResult.reason });
    }

    const blobName = `${req.user.id}/${Date.now()}-${file.originalname.replace(/[^\w.\-]/g, '_')}`;
    const url = await uploadToBlob(file.buffer, blobName, file.mimetype);

    if (scanResult?.pending) {
      // Scan service unavailable — save for retry
      const toUserId = req.body.toUserId || null;
      const groupId  = req.body.groupId  || null;
      const pool = await getPool();
      const ins = await pool.request()
        .input('userId',   sql.UniqueIdentifier, req.user.id)
        .input('toUserId', sql.UniqueIdentifier, toUserId)
        .input('groupId',  sql.UniqueIdentifier, groupId)
        .input('fileUrl',  sql.NVarChar,         url)
        .input('fileName', sql.NVarChar,         file.originalname)
        .input('fileType', sql.NVarChar,         allowed.dbType)
        .input('mimeType', sql.NVarChar,         file.mimetype)
        .query(`INSERT INTO pending_scans (user_id, to_user_id, group_id, file_url, file_name, file_type, mime_type)
                OUTPUT INSERTED.id
                VALUES (@userId, @toUserId, @groupId, @fileUrl, @fileName, @fileType, @mimeType)`);
      logActivity(req.user.id, 'upload_pending',
        { fileName: file.originalname, fileSize: file.size, fileType: allowed.dbType }, req.ip);
      return res.json({
        url, fileName: file.originalname, fileSize: file.size,
        fileType: allowed.dbType, status: 'pending', pendingId: ins.recordset[0].id,
      });
    }

    logActivity(req.user.id, 'upload_file',
      { fileName: file.originalname, fileSize: file.size, fileType: allowed.dbType,
        fileUrl: url, toUserId: req.body.toUserId || null }, req.ip);
    res.json({ url, fileName: file.originalname, fileSize: file.size, fileType: allowed.dbType });
  } catch (e) {
    console.error('upload:', e.message);
    res.status(500).json({ error: e.message });
  }
});

// ── Groups: list mine ─────────────────────────────────────────────
app.get('/api/groups', auth, async (req, res) => {
  try {
    const pool = await getPool();
    const result = await pool.request()
      .input('userId', sql.UniqueIdentifier, req.user.id)
      .query(`
        SELECT g.id, g.name, g.description, g.is_broadcast, g.send_permission, g.filter_level,
               gm.role, gm.status,
               (SELECT COUNT(*) FROM group_members WHERE group_id = g.id AND status='member') AS member_count
        FROM groups g
        JOIN group_members gm ON g.id = gm.group_id AND gm.user_id = @userId
        ORDER BY g.created_at DESC
      `);
    res.json(result.recordset);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Groups: create ────────────────────────────────────────────────
app.post('/api/groups', auth, async (req, res) => {
  const { name, description } = req.body;
  if (!name) return res.status(400).json({ error: 'נדרש שם קבוצה' });
  try {
    const pool = await getPool();
    const result = await pool.request()
      .input('name',    sql.NVarChar,        name)
      .input('desc',    sql.NVarChar,        description || '')
      .input('creator', sql.UniqueIdentifier, req.user.id)
      .query(`INSERT INTO groups (name, description, creator_id)
              OUTPUT INSERTED.id, INSERTED.name, INSERTED.description
              VALUES (@name, @desc, @creator)`);
    const group = result.recordset[0];
    await pool.request()
      .input('groupId', sql.UniqueIdentifier, group.id)
      .input('userId',  sql.UniqueIdentifier, req.user.id)
      .query(`INSERT INTO group_members (group_id, user_id, role) VALUES (@groupId, @userId, 'admin')`);
    logActivity(req.user.id, 'create_group', { groupId: group.id, name }, req.ip);
    res.json({ ...group, role: 'admin', member_count: 1, is_broadcast: false, send_permission: 'all' });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Groups: details + members ─────────────────────────────────────
app.get('/api/groups/:id', auth, async (req, res) => {
  try {
    const pool = await getPool();
    const mem = await pool.request()
      .input('groupId', sql.UniqueIdentifier, req.params.id)
      .input('userId',  sql.UniqueIdentifier, req.user.id)
      .query('SELECT role FROM group_members WHERE group_id=@groupId AND user_id=@userId');
    if (!mem.recordset.length) return res.status(403).json({ error: 'לא חבר בקבוצה' });

    const [grp, members] = await Promise.all([
      pool.request().input('id', sql.UniqueIdentifier, req.params.id)
        .query('SELECT * FROM groups WHERE id=@id'),
      pool.request().input('groupId', sql.UniqueIdentifier, req.params.id)
        .query(`SELECT u.id, u.name, u.profile_pic_url, gm.role, gm.joined_at
                FROM group_members gm JOIN users u ON u.id=gm.user_id
                WHERE gm.group_id=@groupId ORDER BY gm.role DESC, u.name`),
    ]);
    res.json({ ...grp.recordset[0], members: members.recordset, myRole: mem.recordset[0].role });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Groups: messages ──────────────────────────────────────────────
app.get('/api/groups/:id/messages', auth, async (req, res) => {
  const before = req.query.before;
  try {
    const pool = await getPool();
    const check = await pool.request()
      .input('groupId', sql.UniqueIdentifier, req.params.id)
      .input('userId',  sql.UniqueIdentifier, req.user.id)
      .query('SELECT 1 FROM group_members WHERE group_id=@groupId AND user_id=@userId');
    if (!check.recordset.length) return res.status(403).json({ error: 'לא חבר בקבוצה' });

    const req2 = pool.request().input('groupId', sql.UniqueIdentifier, req.params.id);
    if (before) req2.input('before', sql.DateTime, new Date(before));
    const result = await req2.query(`
      SELECT TOP 50
        m.id, m.sender_id, m.type, m.body, m.file_url, m.file_name, m.reply_to_id, m.created_at,
        u.name AS sender_name,
        r.body AS reply_body
      FROM messages m
      JOIN users u ON m.sender_id = u.id
      LEFT JOIN messages r ON m.reply_to_id = r.id
      WHERE m.group_id = @groupId AND m.deleted_for_everyone = 0
      ${before ? 'AND m.created_at < @before' : ''}
      ORDER BY m.created_at DESC
    `);
    res.json(result.recordset.reverse());
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Groups: add member as pending (admin) ─────────────────────────
app.post('/api/groups/:id/members', auth, async (req, res) => {
  const { userId } = req.body;
  if (!userId) return res.status(400).json({ error: 'נדרש userId' });
  try {
    const pool = await getPool();
    // Check caller is admin
    const isAdmin = await pool.request()
      .input('groupId', sql.UniqueIdentifier, req.params.id)
      .input('myId',    sql.UniqueIdentifier, req.user.id)
      .query(`SELECT 1 FROM group_members WHERE group_id=@groupId AND user_id=@myId AND role='admin'`);
    if (!isAdmin.recordset.length) return res.status(403).json({ error: 'אין הרשאה' });

    // Check existing membership
    const existing = await pool.request()
      .input('groupId', sql.UniqueIdentifier, req.params.id)
      .input('userId',  sql.UniqueIdentifier, userId)
      .query(`SELECT status FROM group_members WHERE group_id=@groupId AND user_id=@userId`);
    if (existing.recordset.length) {
      const st = existing.recordset[0].status;
      if (st === 'member')  return res.json({ ok: true, alreadyMember: true });
      if (st === 'pending') return res.json({ ok: true, alreadyPending: true });
    }

    // Insert/update as pending
    await pool.request()
      .input('groupId',  sql.UniqueIdentifier, req.params.id)
      .input('userId',   sql.UniqueIdentifier, userId)
      .input('addedBy',  sql.UniqueIdentifier, req.user.id)
      .query(`IF NOT EXISTS (SELECT 1 FROM group_members WHERE group_id=@groupId AND user_id=@userId)
                INSERT INTO group_members (group_id, user_id, status, added_by, pending_since)
                VALUES (@groupId, @userId, 'pending', @addedBy, GETDATE())
              ELSE
                UPDATE group_members SET status='pending', added_by=@addedBy, pending_since=GETDATE()
                WHERE group_id=@groupId AND user_id=@userId`);

    // Fetch group name and adder name
    const [grpRes, adderRes] = await Promise.all([
      pool.request().input('id', sql.UniqueIdentifier, req.params.id)
        .query('SELECT name FROM groups WHERE id=@id'),
      pool.request().input('id', sql.UniqueIdentifier, req.user.id)
        .query('SELECT name FROM users WHERE id=@id'),
    ]);
    const groupName   = grpRes.recordset[0]?.name   || 'קבוצה';
    const addedByName = adderRes.recordset[0]?.name || 'מנהל';

    // Emit socket event to invited user
    const ioInst = req.app.get('io');
    const invitedSid = onlineUsers.get(userId);
    if (invitedSid) {
      ioInst.to(invitedSid).emit('group:invited', {
        groupId: req.params.id, groupName, addedByName, addedById: req.user.id,
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
    const isAdmin = await pool.request()
      .input('groupId', sql.UniqueIdentifier, req.params.id)
      .input('myId',    sql.UniqueIdentifier, req.user.id)
      .query(`SELECT 1 FROM group_members WHERE group_id=@groupId AND user_id=@myId AND role='admin'`);
    if (!isAdmin.recordset.length) return res.status(403).json({ error: 'אין הרשאה' });
    await pool.request()
      .input('groupId', sql.UniqueIdentifier, req.params.id)
      .input('userId',  sql.UniqueIdentifier, req.params.userId)
      .query('DELETE FROM group_members WHERE group_id=@groupId AND user_id=@userId');
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
    const isAdmin = await pool.request()
      .input('groupId', sql.UniqueIdentifier, req.params.id)
      .input('myId',    sql.UniqueIdentifier, req.user.id)
      .query(`SELECT 1 FROM group_members WHERE group_id=@groupId AND user_id=@myId AND role='admin'`);
    if (!isAdmin.recordset.length) return res.status(403).json({ error: 'אין הרשאה' });

    const existing = await pool.request()
      .input('groupId', sql.UniqueIdentifier, req.params.id)
      .input('userId',  sql.UniqueIdentifier, userId)
      .query(`SELECT status FROM group_members WHERE group_id=@groupId AND user_id=@userId`);
    if (existing.recordset.length) {
      const st = existing.recordset[0].status;
      if (st === 'member')  return res.json({ ok: true, alreadyMember: true });
      if (st === 'pending') return res.json({ ok: true, alreadyPending: true });
    }

    await pool.request()
      .input('groupId',  sql.UniqueIdentifier, req.params.id)
      .input('userId',   sql.UniqueIdentifier, userId)
      .input('addedBy',  sql.UniqueIdentifier, req.user.id)
      .query(`IF NOT EXISTS (SELECT 1 FROM group_members WHERE group_id=@groupId AND user_id=@userId)
                INSERT INTO group_members (group_id, user_id, status, added_by, pending_since)
                VALUES (@groupId, @userId, 'pending', @addedBy, GETDATE())
              ELSE
                UPDATE group_members SET status='pending', added_by=@addedBy, pending_since=GETDATE()
                WHERE group_id=@groupId AND user_id=@userId`);

    const [grpRes, adderRes] = await Promise.all([
      pool.request().input('id', sql.UniqueIdentifier, req.params.id)
        .query('SELECT name FROM groups WHERE id=@id'),
      pool.request().input('id', sql.UniqueIdentifier, req.user.id)
        .query('SELECT name FROM users WHERE id=@id'),
    ]);
    const groupName   = grpRes.recordset[0]?.name   || 'קבוצה';
    const addedByName = adderRes.recordset[0]?.name || 'מנהל';

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
    const pendingRow = await pool.request()
      .input('groupId', sql.UniqueIdentifier, req.params.id)
      .input('userId',  sql.UniqueIdentifier, req.user.id)
      .query(`SELECT status, pending_since FROM group_members
              WHERE group_id=@groupId AND user_id=@userId`);

    const wasPending = pendingRow.recordset[0]?.status === 'pending';
    const pendingSince = pendingRow.recordset[0]?.pending_since || null;

    // Update status to member (or insert if not exists)
    await pool.request()
      .input('groupId', sql.UniqueIdentifier, req.params.id)
      .input('userId',  sql.UniqueIdentifier, req.user.id)
      .query(`IF NOT EXISTS (SELECT 1 FROM group_members WHERE group_id=@groupId AND user_id=@userId)
                INSERT INTO group_members (group_id, user_id, status) VALUES (@groupId, @userId, 'member')
              ELSE
                UPDATE group_members SET status='member'
                WHERE group_id=@groupId AND user_id=@userId`);

    // Fetch missed messages since pending_since
    let missedMessages = [];
    if (wasPending && pendingSince) {
      const missedRes = await pool.request()
        .input('groupId', sql.UniqueIdentifier, req.params.id)
        .input('since',   sql.DateTime,         new Date(pendingSince))
        .query(`SELECT m.id, m.sender_id, m.type, m.body, m.file_url, m.file_name,
                       m.reply_to_id, m.created_at,
                       u.name AS sender_name,
                       r.body AS reply_body
                FROM messages m
                JOIN users u ON m.sender_id = u.id
                LEFT JOIN messages r ON m.reply_to_id = r.id
                WHERE m.group_id = @groupId AND m.deleted_for_everyone = 0
                  AND m.created_at >= @since
                ORDER BY m.created_at ASC`);
      missedMessages = missedRes.recordset;
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
    await pool.request()
      .input('groupId', sql.UniqueIdentifier, req.params.id)
      .input('userId',  sql.UniqueIdentifier, req.user.id)
      .query(`DELETE FROM group_members WHERE group_id=@groupId AND user_id=@userId AND status='pending'`);
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
      pool.request()
        .input('groupId', sql.UniqueIdentifier, req.params.id)
        .input('myId',    sql.UniqueIdentifier, req.user.id)
        .query(`SELECT 1 FROM group_members WHERE group_id=@groupId AND user_id=@myId AND role='admin'`),
      pool.request()
        .input('id', sql.UniqueIdentifier, req.params.id)
        .query('SELECT name FROM groups WHERE id=@id'),
    ]);
    if (!adminCheck.recordset.length) return res.status(403).json({ error: 'אין הרשאה' });

    const groupName  = grp.recordset[0]?.name || 'הקבוצה';
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
    await pool.request()
      .input('groupId', sql.UniqueIdentifier, req.params.id)
      .input('userId',  sql.UniqueIdentifier, req.user.id)
      .query('DELETE FROM group_members WHERE group_id=@groupId AND user_id=@userId');
    logActivity(req.user.id, 'leave_group', { groupId: req.params.id }, req.ip);
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Groups: update settings (admin) ──────────────────────────────
app.put('/api/groups/:id', auth, async (req, res) => {
  const { name, description, send_permission, filter_level, is_broadcast } = req.body;
  if (!name) return res.status(400).json({ error: 'נדרש שם' });
  try {
    const pool = await getPool();
    const isAdmin = await pool.request()
      .input('groupId', sql.UniqueIdentifier, req.params.id)
      .input('userId',  sql.UniqueIdentifier, req.user.id)
      .query(`SELECT 1 FROM group_members WHERE group_id=@groupId AND user_id=@userId AND role='admin'`);
    if (!isAdmin.recordset.length) return res.status(403).json({ error: 'אין הרשאה' });
    await pool.request()
      .input('id',        sql.UniqueIdentifier, req.params.id)
      .input('name',      sql.NVarChar,         name)
      .input('desc',      sql.NVarChar,         description || '')
      .input('perm',      sql.NVarChar,         send_permission || 'all')
      .input('filter',    sql.NVarChar,         filter_level || 'standard')
      .input('broadcast', sql.Bit,              is_broadcast ? 1 : 0)
      .query(`UPDATE groups SET name=@name, description=@desc,
              send_permission=@perm, filter_level=@filter, is_broadcast=@broadcast
              WHERE id=@id`);
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Save game ────────────────────────────────────────────────────
app.post('/api/games', auth, async (req, res) => {
  const { player1_id, player2_id, winner_id, result, board } = req.body;
  try {
    const pool = await getPool();
    await pool.request()
      .input('p1', sql.UniqueIdentifier, player1_id)
      .input('p2', sql.UniqueIdentifier, player2_id)
      .input('winner', sql.UniqueIdentifier, winner_id || null)
      .input('result', sql.NVarChar, result)
      .input('board', sql.NVarChar, board.join(','))
      .query(`INSERT INTO games (player1_id, player2_id, winner_id, result, board)
              VALUES (@p1, @p2, @winner, @result, @board)`);

    if (result === 'win' && winner_id) {
      await pool.request()
        .input('id', sql.UniqueIdentifier, winner_id)
        .query('UPDATE users SET wins = wins + 1, games_played = games_played + 1 WHERE id = @id');
      const loserId = winner_id === player1_id ? player2_id : player1_id;
      await pool.request()
        .input('id', sql.UniqueIdentifier, loserId)
        .query('UPDATE users SET games_played = games_played + 1 WHERE id = @id');
    } else if (result === 'tie') {
      await pool.request()
        .input('p1', sql.UniqueIdentifier, player1_id)
        .input('p2', sql.UniqueIdentifier, player2_id)
        .query('UPDATE users SET games_played = games_played + 1 WHERE id IN (@p1, @p2)');
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
  try {
    const pool = await getPool();
    const req2 = pool.request()
      .input('limit',  sql.Int, limit)
      .input('offset', sql.Int, offset);
    if (userId) req2.input('userId', sql.UniqueIdentifier, userId);
    if (action) req2.input('action', sql.NVarChar, action);
    if (search) req2.input('search', sql.NVarChar, `%${search}%`);
    const result = await req2.query(`
      SELECT a.id, a.action, a.details, a.ip, a.created_at,
             u.name AS user_name, u.email AS user_email
      FROM activity_log a
      LEFT JOIN users u ON u.id = a.user_id
      WHERE 1=1
        ${userId ? 'AND a.user_id = @userId' : ''}
        ${action ? 'AND a.action  = @action'  : ''}
        ${search ? 'AND (u.name LIKE @search OR u.email LIKE @search)' : ''}
      ORDER BY a.created_at DESC
      OFFSET @offset ROWS FETCH NEXT @limit ROWS ONLY
    `);
    res.json(result.recordset);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Admin: all users ─────────────────────────────────────────────
app.get('/api/admin/users', auth, async (req, res) => {
  try {
    const pool = await getPool();
    const result = await pool.request()
      .query(`SELECT id, name, email, phone, email_verified, phone_verified,
                     google_id, profile_pic_url, city, community,
                     filter_level, created_at
              FROM users ORDER BY created_at DESC`);
    res.json(result.recordset);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Admin: all games ─────────────────────────────────────────────
app.get('/api/admin/games', auth, async (req, res) => {
  try {
    const pool = await getPool();
    const result = await pool.request().query(`
      SELECT g.id, g.result, g.board, g.played_at,
             p1.name AS player1, p2.name AS player2,
             w.name AS winner
      FROM games g
      JOIN users p1 ON g.player1_id = p1.id
      JOIN users p2 ON g.player2_id = p2.id
      LEFT JOIN users w ON g.winner_id = w.id
      ORDER BY g.played_at DESC
    `);
    res.json(result.recordset);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Leaderboard ──────────────────────────────────────────────────
app.get('/api/leaderboard', auth, async (req, res) => {
  try {
    const pool = await getPool();
    const result = await pool.request()
      .query('SELECT name, email, wins, games_played FROM users ORDER BY wins DESC');
    res.json(result.recordset);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// ── Send OTP via SMS (019 email gateway) ────────────────────────
app.post('/api/send-otp', async (req, res) => {
  const { phone, name, email } = req.body;
  if (!phone) return res.status(400).json({ error: 'נדרש מספר טלפון' });
  const clean      = phone.replace(/\D/g, '');
  const cleanEmail = (email || '').toLowerCase().trim();
  if (clean.length < 9) return res.status(400).json({ error: 'מספר טלפון לא תקין' });
  if (cleanEmail.includes('@')) {
    try {
      const pool = await getPool();
      const emailExists = await pool.request()
        .input('email', sql.NVarChar, cleanEmail)
        .input('phone', sql.NVarChar, clean)
        .query('SELECT id FROM users WHERE email=@email AND phone != @phone');
      if (emailExists.recordset.length)
        return res.status(400).json({ error: 'כתובת האימייל כבר רשומה' });
    } catch (_) {}
  }
  const code    = Math.floor(100000 + Math.random() * 900000).toString();
  const expires = Date.now() + 5 * 60 * 1000;
  otpStore.set(clean, { code, expires, name: name || '', email: cleanEmail });
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
  otpStore.delete(clean);
  const userName  = name || entry.name || `משתמש_${clean.slice(-4)}`;
  const userEmail = entry.email || `${clean}@betshuva.app`;
  try {
    const pool = await getPool();
    // Check existing user by phone
    const byPhone = await pool.request()
      .input('phone', sql.NVarChar, clean)
      .query('SELECT id, name, email FROM users WHERE phone=@phone');
    let user;
    if (byPhone.recordset.length) {
      user = byPhone.recordset[0];
      await pool.request()
        .input('id', sql.UniqueIdentifier, user.id)
        .query('UPDATE users SET phone_verified=1, email_verified=1 WHERE id=@id');
    } else {
      // Check by email
      const byEmail = await pool.request()
        .input('email', sql.NVarChar, userEmail)
        .query('SELECT id, name, email FROM users WHERE email=@email');
      if (byEmail.recordset.length) {
        user = byEmail.recordset[0];
        await pool.request()
          .input('id',    sql.UniqueIdentifier, user.id)
          .input('phone', sql.NVarChar,         clean)
          .query('UPDATE users SET phone_verified=1, email_verified=1, phone=@phone WHERE id=@id');
      } else {
        // New user — verified by OTP
        const hash   = await bcrypt.hash(`otp_${clean}`, 10);
        const result = await pool.request()
          .input('name',  sql.NVarChar, userName)
          .input('email', sql.NVarChar, userEmail)
          .input('phone', sql.NVarChar, clean)
          .input('hash',  sql.NVarChar, hash)
          .query(`INSERT INTO users (name, email, phone, password_hash, phone_verified, email_verified)
                  OUTPUT INSERTED.id, INSERTED.name, INSERTED.email
                  VALUES (@name, @email, @phone, @hash, 1, 1)`);
        user = result.recordset[0];
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
  if (!code) return res.status(400).json({ error: 'נדרש קוד אימות' });
  const entry = otpStore.get(clean);
  if (!entry || entry.code !== code || Date.now() > entry.expires)
    return res.status(400).json({ error: 'קוד שגוי או פג תוקף' });
  otpStore.delete(clean);
  try {
    const pool = await getPool();
    const taken = await pool.request()
      .input('phone', sql.NVarChar, clean)
      .input('id',    sql.UniqueIdentifier, req.user.id)
      .query('SELECT id FROM users WHERE phone=@phone AND id != @id');
    if (taken.recordset.length)
      return res.status(400).json({ error: 'מספר הטלפון כבר רשום למשתמש אחר' });
    await pool.request()
      .input('id',    sql.UniqueIdentifier, req.user.id)
      .input('phone', sql.NVarChar,         clean)
      .query('UPDATE users SET phone=@phone, phone_verified=1 WHERE id=@id');
    logActivity(req.user.id, 'link_phone', { phone: clean }, req.ip);
    res.json({ ok: true });
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
    await pool.request()
      .input('phone', sql.NVarChar, cleanPhone)
      .query('UPDATE users SET phone_verified = 1 WHERE phone = @phone');
    const result = await pool.request()
      .input('phone', sql.NVarChar, cleanPhone)
      .query('SELECT id, name, email, email_verified FROM users WHERE phone = @phone');
    const user = result.recordset[0];
    if (!user) return res.status(400).json({ error: 'משתמש לא נמצא' });
    if (!user.email || user.email_verified) {
      const token = jwt.sign({ id: user.id, name: user.name, email: user.email }, JWT_SECRET);
      return res.json({ ok: true, token });
    }
    res.json({ ok: true, waitingEmail: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Verify Email (HTML page) ─────────────────────────────────────
app.get('/verify-email', async (req, res) => {
  const token = (req.query.token || '').replace(/[^a-f0-9]/g, '');
  const ok = (msg) => res.send(`<!DOCTYPE html><html dir="rtl" lang="he"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>אימות אימייל – בתשובה</title><style>body{font-family:Arial,sans-serif;background:#F0F4F0;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0}.card{background:#fff;padding:36px;border-radius:16px;box-shadow:0 4px 24px rgba(0,0,0,.1);max-width:400px;text-align:center}h2{color:#1B4332}</style></head><body><div class="card">${msg}</div></body></html>`);
  try {
    const pool = await getPool();
    const result = await pool.request()
      .input('token', sql.NVarChar, token)
      .query('SELECT user_id FROM email_verification_tokens WHERE token = @token AND used = 0 AND expires_at > GETDATE()');
    if (!result.recordset.length)
      return ok('<h2>❌ הקישור לא תקין או פג תוקף</h2><p>נסה להירשם מחדש.</p>');
    const { user_id } = result.recordset[0];
    await pool.request()
      .input('id', sql.UniqueIdentifier, user_id)
      .query('UPDATE users SET email_verified = 1 WHERE id = @id');
    await pool.request()
      .input('token', sql.NVarChar, token)
      .query('UPDATE email_verification_tokens SET used = 1 WHERE token = @token');
    ok('<h2>✅ האימייל אומת בהצלחה!</h2><p>כעת תוכל להתחבר לאפליקציה.</p>');
  } catch (e) { ok('<h2>❌ שגיאה</h2><p>' + e.message + '</p>'); }
});

// ── Admin DB Dashboard ────────────────────────────────────────────

const ADMIN_TABLES = {
  users:             { label: 'משתמשים',     pk: 'id',        hide: ['password_hash'] },
  groups:            { label: 'קבוצות',       pk: 'id',        hide: [] },
  group_members:     { label: 'חברי קבוצות', pk: null,        hide: [] },
  messages:          { label: 'הודעות',       pk: 'id',        hide: [] },
  message_status:    { label: 'סטטוס הודעות', pk: null,       hide: [] },
  blocked_users:     { label: 'חסומים',       pk: null,        hide: [] },
  fcm_tokens:        { label: 'FCM Tokens',  pk: 'id',        hide: ['token'] },
  activity_log:      { label: 'פעילות',       pk: 'id',        hide: [] },
  audit_log:         { label: 'אודיט',        pk: 'id',        hide: [] },
  admin_permissions: { label: 'הרשאות מנהל', pk: 'user_id',  hide: [] },
};

async function adminAuth(req, res, next) {
  const header = req.headers.authorization || '';
  const token  = header.replace('Bearer ', '');
  if (!token) return res.status(401).json({ error: 'לא מחובר' });
  try {
    req.user = jwt.verify(token, JWT_SECRET);
    const pool   = await getPool();
    const result = await pool.request()
      .input('userId', sql.UniqueIdentifier, req.user.id)
      .query('SELECT permission FROM admin_permissions WHERE user_id = @userId');
    if (!result.recordset.length)
      return res.status(403).json({ error: 'אין הרשאת גישה לדשבורד' });
    req.adminPerm = result.recordset[0].permission; // 'view' or 'edit'
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
        const r = await pool.request().query(`SELECT COUNT(*) AS n FROM ${t}`);
        return { table: t, label: ADMIN_TABLES[t].label, count: r.recordset[0].n };
      } catch { return { table: t, label: ADMIN_TABLES[t].label, count: 0 }; }
    }));
    res.json({ tables: counts, permission: req.adminPerm });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// Get table data (paginated)
app.get('/api/admin/db/:table', adminAuth, async (req, res) => {
  const cfg = ADMIN_TABLES[req.params.table];
  if (!cfg) return res.status(400).json({ error: 'טבלה לא מורשית' });
  const limit  = Math.min(parseInt(req.query.limit)  || 200, 500);
  const offset = parseInt(req.query.offset) || 0;
  const search = (req.query.search || '').trim();
  try {
    const pool   = await getPool();
    const tbl    = req.params.table;
    const filter = search
      ? `WHERE CAST((SELECT * FROM ${tbl} FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS NVARCHAR(MAX)) LIKE @s`
      : '';
    const request = pool.request().input('s', sql.NVarChar, `%${search}%`);
    const result  = await request.query(
      `SELECT * FROM (SELECT *, ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) rn FROM ${tbl}) t
       WHERE rn > ${offset} AND rn <= ${offset + limit}`);
    const countR  = await pool.request().query(`SELECT COUNT(*) AS n FROM ${tbl}`);
    const rows    = result.recordset.map(r => {
      const row = { ...r }; delete row.rn;
      cfg.hide.forEach(h => delete row[h]);
      return row;
    });
    res.json({ rows, total: countR.recordset[0].n, permission: req.adminPerm });
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
    const schema = await pool.request()
      .input('tbl', sql.NVarChar, req.params.table)
      .query(`SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = @tbl`);
    const validCols = new Set(schema.recordset.map(r => r.COLUMN_NAME));
    const filtered  = safe.filter(k => validCols.has(k));
    if (!filtered.length) return res.status(400).json({ error: 'עמודות לא תקינות' });
    const setClause = filtered.map(k => `[${k}]=@${k}`).join(',');
    const req2 = pool.request().input('pk', sql.NVarChar, req.params.id);
    filtered.forEach(k => req2.input(k, sql.NVarChar, updates[k] == null ? null : String(updates[k])));
    await req2.query(`UPDATE ${req.params.table} SET ${setClause} WHERE [${cfg.pk}]=@pk`);
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
    await pool.request()
      .input('pk', sql.NVarChar, req.params.id)
      .query(`DELETE FROM ${req.params.table} WHERE [${cfg.pk}]=@pk`);
    logActivity(req.user.id, 'admin_delete', { table: req.params.table, id: req.params.id }, req.ip);
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// Manage permissions
app.get('/api/admin/permissions', adminAuth, async (req, res) => {
  try {
    const pool = await getPool();
    const r = await pool.request().query(
      `SELECT ap.user_id, u.name, u.email, ap.permission, ap.granted_at
       FROM admin_permissions ap JOIN users u ON u.id = ap.user_id
       ORDER BY ap.granted_at`);
    res.json(r.recordset);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.post('/api/admin/permissions', adminAuth, async (req, res) => {
  if (req.adminPerm !== 'edit') return res.status(403).json({ error: 'נדרשת הרשאת עריכה' });
  const { email, permission } = req.body;
  if (!['view','edit'].includes(permission)) return res.status(400).json({ error: 'הרשאה לא תקינה' });
  try {
    const pool = await getPool();
    const user = await pool.request()
      .input('email', sql.NVarChar, email)
      .query('SELECT id FROM users WHERE email = @email');
    if (!user.recordset.length) return res.status(404).json({ error: 'משתמש לא נמצא' });
    const userId = user.recordset[0].id;
    await pool.request()
      .input('userId', sql.UniqueIdentifier, userId)
      .input('perm',   sql.NVarChar,         permission)
      .query(`MERGE admin_permissions AS t USING (SELECT @userId AS user_id) AS s
              ON t.user_id = s.user_id
              WHEN MATCHED THEN UPDATE SET permission = @perm
              WHEN NOT MATCHED THEN INSERT (user_id, permission) VALUES (@userId, @perm);`);
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.delete('/api/admin/permissions/:userId', adminAuth, async (req, res) => {
  if (req.adminPerm !== 'edit') return res.status(403).json({ error: 'נדרשת הרשאת עריכה' });
  if (req.params.userId === req.user.id) return res.status(400).json({ error: 'לא ניתן להסיר את עצמך' });
  try {
    const pool = await getPool();
    await pool.request()
      .input('userId', sql.UniqueIdentifier, req.params.userId)
      .query('DELETE FROM admin_permissions WHERE user_id = @userId');
    res.json({ ok: true });
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
      const result = await pool.request().query(`
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
      const cnt = await pool.request().query('SELECT COUNT(*) AS n FROM pending_scans');
      res.json({ rows: result.recordset, total: cnt.recordset[0].n });
    } else if (type === 'approved') {
      const result = await pool.request().query(`
        SELECT a.id, a.created_at, a.action,
               u.name AS user_name, u.email AS user_email,
               JSON_VALUE(a.details, '$.fileName') AS file_name,
               JSON_VALUE(a.details, '$.fileUrl')  AS file_url,
               JSON_VALUE(a.details, '$.fileType') AS file_type,
               ru.name AS recipient_name
        FROM activity_log a
        LEFT JOIN users u  ON u.id = a.user_id
        LEFT JOIN users ru ON ru.id = TRY_CAST(JSON_VALUE(a.details, '$.toUserId') AS UNIQUEIDENTIFIER)
        WHERE a.action IN ('upload_file', 'upload_pending', 'send_file_delayed')
        ORDER BY a.created_at DESC
        OFFSET ${offset} ROWS FETCH NEXT ${limit} ROWS ONLY
      `);
      const cnt = await pool.request().query(`
        SELECT COUNT(*) AS n FROM activity_log
        WHERE action IN ('upload_file', 'upload_pending', 'send_file_delayed')`);
      res.json({ rows: result.recordset, total: cnt.recordset[0].n });
    } else {
      const result = await pool.request().query(`
        SELECT a.id, a.created_at, a.ip, a.action,
               u.name AS user_name, u.email AS user_email,
               JSON_VALUE(a.details, '$.fileName') AS file_name,
               JSON_VALUE(a.details, '$.reason')   AS reason,
               JSON_VALUE(a.details, '$.fileType')  AS file_type,
               JSON_VALUE(a.details, '$.fileUrl')   AS file_url
        FROM activity_log a
        LEFT JOIN users u ON u.id = a.user_id
        WHERE a.action IN ('blocked_upload','blocked_upload_delayed')
        ORDER BY a.created_at DESC
        OFFSET ${offset} ROWS FETCH NEXT ${limit} ROWS ONLY
      `);
      const cnt = await pool.request().query(`
        SELECT COUNT(*) AS n FROM activity_log
        WHERE action IN ('blocked_upload','blocked_upload_delayed')`);
      res.json({ rows: result.recordset, total: cnt.recordset[0].n });
    }
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.delete('/api/admin/scans/pending/:id', adminAuth, async (req, res) => {
  if (req.adminPerm !== 'edit') return res.status(403).json({ error: 'נדרשת הרשאת עריכה' });
  try {
    const pool = await getPool();
    await pool.request()
      .input('id', sql.Int, parseInt(req.params.id))
      .query('DELETE FROM pending_scans WHERE id = @id');
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Admin: create group + add members directly ───────────────────
app.post('/api/admin/groups', adminAuth, async (req, res) => {
  if (req.adminPerm !== 'edit') return res.status(403).json({ error: 'נדרשת הרשאת עריכה' });
  const { name, description, memberIds = [], isBroadcast = false, sendPermission = 'all' } = req.body;
  if (!name) return res.status(400).json({ error: 'נדרש שם קבוצה' });
  try {
    const pool = await getPool();
    const result = await pool.request()
      .input('name',    sql.NVarChar, name)
      .input('desc',    sql.NVarChar, description || '')
      .input('creator', sql.UniqueIdentifier, req.user.id)
      .input('isBroadcast',    sql.Bit,      isBroadcast ? 1 : 0)
      .input('sendPermission', sql.NVarChar, sendPermission)
      .query(`INSERT INTO groups (name, description, creator_id, is_broadcast, send_permission)
              OUTPUT INSERTED.id, INSERTED.name
              VALUES (@name, @desc, @creator, @isBroadcast, @sendPermission)`);
    const group = result.recordset[0];
    // Add creator as admin
    await pool.request()
      .input('groupId', sql.UniqueIdentifier, group.id)
      .input('userId',  sql.UniqueIdentifier, req.user.id)
      .query(`INSERT INTO group_members (group_id, user_id, role, status)
              VALUES (@groupId, @userId, 'admin', 'member')`);
    // Add members directly as 'member' (no pending)
    for (const uid of memberIds) {
      try {
        await pool.request()
          .input('groupId', sql.UniqueIdentifier, group.id)
          .input('userId',  sql.UniqueIdentifier, uid)
          .query(`INSERT INTO group_members (group_id, user_id, role, status)
                  VALUES (@groupId, @userId, 'member', 'member')`);
      } catch (_) {}
    }
    logActivity(req.user.id, 'create_group', { groupId: group.id, name, members: memberIds.length }, req.ip);
    res.json({ ok: true, groupId: group.id, name: group.name, memberCount: memberIds.length + 1 });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Storage diagnostic ───────────────────────────────────────────
app.get('/api/test-storage', async (req, res) => {
  const rawKey = process.env.B2_APP_KEY || '';
  const vars = {
    B2_KEY_ID:       !!process.env.B2_KEY_ID,
    B2_APP_KEY_len:  rawKey.length,
    B2_APP_KEY_spaces: rawKey.includes(' '),
    B2_BUCKET:       process.env.B2_BUCKET    || '(לא מוגדר)',
    CDN_BASE_URL:    process.env.CDN_BASE_URL || '(לא מוגדר)',
  };
  try {
    const testKey = `test/ping-${Date.now()}.txt`;
    const url = await uploadToBlob(Buffer.from('ping'), testKey, 'text/plain');
    res.json({ ok: true, testUrl: url, vars });
  } catch (e) {
    res.json({ ok: false, error: e.message, vars });
  }
});

// ── App Version (also wakes up DB on cold start) ─────────────────
app.get('/api/version', async (req, res) => {
  try { const pool = await getPool(); await pool.request().query('SELECT 1'); } catch (_) {}
  res.json({ version: '1.2.5', apkUrl: 'https://betshuva.com/app-release.apk' });
});

// ── Forgot Password ──────────────────────────────────────────────
app.post('/api/forgot-password', async (req, res) => {
  const { email } = req.body;
  if (!email) return res.status(400).json({ error: 'נדרש אימייל' });
  res.json({ ok: true }); // respond immediately — don't reveal if email exists
  try {
    const pool = await getPool();
    const result = await pool.request()
      .input('email', sql.NVarChar, email)
      .query('SELECT id, name FROM users WHERE email = @email');
    if (!result.recordset.length) return;
    const user  = result.recordset[0];
    const token = crypto.randomBytes(32).toString('hex');
    const expires = new Date(Date.now() + 60 * 60 * 1000); // 1 hour
    await pool.request()
      .input('token',   sql.NVarChar,        token)
      .input('userId',  sql.UniqueIdentifier, user.id)
      .input('expires', sql.DateTime,         expires)
      .query('INSERT INTO password_reset_tokens (token, user_id, expires_at) VALUES (@token, @userId, @expires)');
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
    const result = await pool.request()
      .input('token', sql.NVarChar, token)
      .query('SELECT user_id FROM password_reset_tokens WHERE token = @token AND used = 0 AND expires_at > GETDATE()');
    if (!result.recordset.length) return res.status(400).json({ error: 'הקישור לא תקין או פג תוקף' });
    const { user_id } = result.recordset[0];
    const hash = await bcrypt.hash(password, 10);
    await pool.request()
      .input('hash', sql.NVarChar,        hash)
      .input('id',   sql.UniqueIdentifier, user_id)
      .query('UPDATE users SET password_hash = @hash WHERE id = @id');
    await pool.request()
      .input('token', sql.NVarChar, token)
      .query('UPDATE password_reset_tokens SET used = 1 WHERE token = @token');
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
      const r=await fetch('/api/reset-password',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({token:'${token}',password:p1})});
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
  try {
    const pool = await getPool();
    await pool.request().query(`
      IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME='pending_scans')
      CREATE TABLE pending_scans (
        id          INT IDENTITY(1,1) PRIMARY KEY,
        user_id     UNIQUEIDENTIFIER NOT NULL,
        to_user_id  UNIQUEIDENTIFIER NULL,
        group_id    UNIQUEIDENTIFIER NULL,
        file_url    NVARCHAR(500)    NOT NULL,
        file_name   NVARCHAR(255)    NOT NULL,
        file_type   NVARCHAR(50)     NOT NULL,
        mime_type   NVARCHAR(100)    NOT NULL,
        retry_count INT              NOT NULL DEFAULT 0,
        last_retry  DATETIME         NULL,
        created_at  DATETIME         DEFAULT GETDATE()
      )
    `);
    console.log('pending_scans table ready');
  } catch (e) { console.error('initPendingTable:', e.message); }
}

async function retryPendingScans() {
  try {
    const pool = await getPool();
    const rows = await pool.request().query(`
      SELECT TOP 10 * FROM pending_scans
      WHERE retry_count < 20
        AND (last_retry IS NULL OR last_retry < DATEADD(MINUTE, -2, GETDATE()))
      ORDER BY created_at ASC
    `);

    for (const row of rows.recordset) {
      try {
        // Update last_retry immediately to avoid double-processing
        await pool.request()
          .input('id', sql.Int, row.id)
          .query(`UPDATE pending_scans SET retry_count=retry_count+1, last_retry=GETDATE() WHERE id=@id`);

        // Download file from B2 for re-scan
        const fileRes = await fetch(row.file_url);
        if (!fileRes.ok) continue;
        const buffer = Buffer.from(await fileRes.arrayBuffer());

        let scanResult;
        if (row.file_type === 'image') scanResult = await scanImage(buffer);
        else                           scanResult = await scanDocument(buffer, row.mime_type);

        if (scanResult.pending) continue; // service still unavailable

        // Remove from pending regardless of outcome
        await pool.request()
          .input('id', sql.Int, row.id)
          .query(`DELETE FROM pending_scans WHERE id=@id`);

        if (scanResult.blocked) {
          logActivity(row.user_id, 'blocked_upload_delayed',
            { fileName: row.file_name, reason: scanResult.reason, fileUrl: row.file_url });
          // Notify sender that file was rejected
          const sid = onlineUsers.get(row.user_id);
          if (sid) io.to(sid).emit('scan:rejected', { fileName: row.file_name, reason: scanResult.reason });
          continue;
        }

        // Scan passed — save message and deliver
        if (row.to_user_id) {
          const saved = await pool.request()
            .input('senderId',    sql.UniqueIdentifier, row.user_id)
            .input('recipientId', sql.UniqueIdentifier, row.to_user_id)
            .input('type',        sql.NVarChar,         row.file_type)
            .input('fileUrl',     sql.NVarChar,         row.file_url)
            .input('fileName',    sql.NVarChar,         row.file_name)
            .query(`INSERT INTO messages (sender_id, recipient_id, type, body, file_url, file_name)
                    OUTPUT INSERTED.id, INSERTED.created_at
                    VALUES (@senderId, @recipientId, @type, @fileName, @fileUrl, @fileName)`);
          const msg = saved.recordset[0];
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

initPendingTable();
setInterval(retryPendingScans, 2 * 60 * 1000); // every 2 minutes

const PORT = process.env.PORT || 3000;
httpServer.listen(PORT, () => console.log(`Server running on port ${PORT}`));
