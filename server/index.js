require('dotenv').config();
const express = require('express');
const { createServer } = require('http');
const { Server } = require('socket.io');
const cors = require('cors');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const nodemailer = require('nodemailer');
const crypto     = require('crypto');
const { getPool, sql } = require('./db');

const mailer = nodemailer.createTransport({
  host: 'smtp.gmail.com',
  port: 587,
  secure: false,
  auth: {
    user: process.env.EMAIL_FROM,
    pass: process.env.EMAIL_APP_PASSWORD,
  },
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

// Auto-migrate: create reset tokens table
(async () => {
  try {
    const pool = await getPool();
    await pool.request().query(`
      IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='password_reset_tokens' AND xtype='U')
      CREATE TABLE password_reset_tokens (
        token      NVARCHAR(64)     PRIMARY KEY,
        user_id    UNIQUEIDENTIFIER NOT NULL REFERENCES users(id),
        expires_at DATETIME         NOT NULL,
        used       BIT              DEFAULT 0
      )`);
  } catch (e) { console.error('Migration:', e.message); }
})();

const app = express();
const httpServer = createServer(app);
const io = new Server(httpServer, { cors: { origin: '*' } });

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
io.use((socket, next) => {
  try {
    socket.user = jwt.verify(socket.handshake.auth.token, JWT_SECRET);
    next();
  } catch {
    next(new Error('unauthorized'));
  }
});

io.on('connection', (socket) => {
  onlineUsers.set(socket.user.id, socket.id);
  io.emit('users:online', [...onlineUsers.keys()]);

  function relay(toUserId, event, data) {
    const sid = onlineUsers.get(toUserId);
    if (sid) io.to(sid).emit(event, data);
  }

  socket.on('game:invite',  ({ toUserId }) => relay(toUserId, 'game:invite',   { from: socket.user }));
  socket.on('game:accept',  ({ toUserId }) => relay(toUserId, 'game:accepted', { by: socket.user }));
  socket.on('game:decline', ({ toUserId }) => relay(toUserId, 'game:declined', {}));
  socket.on('game:cancel',  ({ toUserId }) => relay(toUserId, 'game:cancel',   {}));
  socket.on('game:move',    ({ toUserId, index }) => relay(toUserId, 'game:move', { index }));
  socket.on('game:rematch', ({ toUserId }) => relay(toUserId, 'game:rematch',  {}));
  socket.on('chat:message', ({ toUserId, text }) => relay(toUserId, 'chat:message', { from: socket.user.name, text }));

  socket.on('disconnect', () => {
    onlineUsers.delete(socket.user.id);
    io.emit('users:online', [...onlineUsers.keys()]);
  });
});

// ── Register ─────────────────────────────────────────────────────
app.post('/api/register', async (req, res) => {
  const { name, email, password } = req.body;
  if (!name || !email || !password) return res.status(400).json({ error: 'חסרים שדות' });
  try {
    const pool = await getPool();
    const exists = await pool.request()
      .input('email', sql.NVarChar, email)
      .query('SELECT id FROM users WHERE email = @email');
    if (exists.recordset.length) return res.status(400).json({ error: 'האימייל כבר רשום' });

    const hash = await bcrypt.hash(password, 10);
    const result = await pool.request()
      .input('name', sql.NVarChar, name)
      .input('email', sql.NVarChar, email)
      .input('hash', sql.NVarChar, hash)
      .query(`INSERT INTO users (name, email, password_hash)
              OUTPUT INSERTED.id, INSERTED.name, INSERTED.email, INSERTED.wins, INSERTED.games_played
              VALUES (@name, @email, @hash)`);
    const user = result.recordset[0];
    const token = jwt.sign({ id: user.id, name: user.name, email: user.email }, JWT_SECRET);
    res.json({ token, user });
    sendEmail({ to: user.email, subject: 'ברוכים הבאים לבתשובה!', html: welcomeEmail(user.name) }).catch(() => {});
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
    if (!user || !(await bcrypt.compare(password, user.password_hash)))
      return res.status(401).json({ error: 'אימייל או סיסמה שגויים' });

    const token = jwt.sign({ id: user.id, name: user.name, email: user.email }, JWT_SECRET);
    const { password_hash, ...safeUser } = user;
    res.json({ token, user: safeUser });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// ── Users ────────────────────────────────────────────────────────
app.get('/api/users', auth, async (req, res) => {
  try {
    const pool = await getPool();
    const result = await pool.request()
      .query('SELECT id, name, email, wins, games_played FROM users ORDER BY wins DESC');
    res.json(result.recordset);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
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

// ── Admin: all users ─────────────────────────────────────────────
app.get('/api/admin/users', auth, async (req, res) => {
  try {
    const pool = await getPool();
    const result = await pool.request()
      .query('SELECT id, name, email, wins, games_played, created_at FROM users ORDER BY created_at DESC');
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
  const { phone, name } = req.body;
  if (!phone) return res.status(400).json({ error: 'נדרש מספר טלפון' });
  const clean = phone.replace(/\D/g, '');
  if (clean.length < 9) return res.status(400).json({ error: 'מספר טלפון לא תקין' });
  const code    = Math.floor(100000 + Math.random() * 900000).toString();
  const expires = Date.now() + 5 * 60 * 1000; // 5 minutes
  otpStore.set(clean, { code, expires, name: name || '' });
  try {
    await sendEmail({
      to:      `${clean}@019sms.co.il`,
      subject: `קוד האימות שלך לבתשובה: ${code}`,
      html:    '',
    });
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: 'שגיאה בשליחת SMS' });
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
  const fakeMail = `${clean}@betshuva.app`;
  const userName = name || entry.name || `משתמש_${clean.slice(-4)}`;
  try {
    const pool = await getPool();
    const existing = await pool.request()
      .input('email', sql.NVarChar, fakeMail)
      .query('SELECT id, name, email, wins, games_played FROM users WHERE email = @email');
    let user;
    if (existing.recordset.length) {
      user = existing.recordset[0];
    } else {
      const hash   = await bcrypt.hash(`otp_${clean}`, 10);
      const result = await pool.request()
        .input('name',  sql.NVarChar, userName)
        .input('email', sql.NVarChar, fakeMail)
        .input('hash',  sql.NVarChar, hash)
        .query(`INSERT INTO users (name, email, password_hash)
                OUTPUT INSERTED.id, INSERTED.name, INSERTED.email, INSERTED.wins, INSERTED.games_played
                VALUES (@name, @email, @hash)`);
      user = result.recordset[0];
    }
    const token = jwt.sign({ id: user.id, name: user.name, email: user.email }, JWT_SECRET);
    res.json({ token, user });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// ── App Version ──────────────────────────────────────────────────
app.get('/api/version', (req, res) => {
  res.json({ version: '1.0.1', apkUrl: 'https://betshuva.com/app-release.apk' });
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

const PORT = process.env.PORT || 3000;
httpServer.listen(PORT, () => console.log(`Server running on port ${PORT}`));
