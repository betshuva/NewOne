'use strict';

const crypto = require('node:crypto');
const { OAuth2Client } = require('google-auth-library');
const MailComposer = require('nodemailer/lib/mail-composer');
const addressParser = require('nodemailer/lib/addressparser');
const { verifySession, sessionCurrent } = require('./session-security');

const SCOPES = ['https://www.googleapis.com/auth/gmail.readonly',
  'https://www.googleapis.com/auth/gmail.send'];
const API = 'https://gmail.googleapis.com/gmail/v1/users/me';
const COOKIE = '__Secure-betshuva_gmail';
const SCHEMA = `
  CREATE TABLE IF NOT EXISTS private_gmail_accounts (
    user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    email TEXT NOT NULL, encrypted_token TEXT NOT NULL,
    connected_at TIMESTAMPTZ NOT NULL DEFAULT now()
  );
  CREATE TABLE IF NOT EXISTS private_gmail_oauth (
    state_hash TEXT PRIMARY KEY, user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    session_version INTEGER NOT NULL, browser_hash TEXT NOT NULL,
    encrypted_verifier TEXT NOT NULL, expires_at TIMESTAMPTZ NOT NULL
  );
  CREATE TABLE IF NOT EXISTS private_gmail_replies (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    request_id UUID NOT NULL, content_hash TEXT NOT NULL,
    status TEXT NOT NULL, result JSONB, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY(user_id, request_id)
  );`;

function ownerEmail() { return String(process.env.GMAIL_ACCOUNT_EMAIL || 'yanive8@gmail.com').trim().toLowerCase(); }
function baseUrl() { return String(process.env.APP_URL || 'https://betshuva.com/betshuva-app').replace(/\/$/, ''); }
function callbackUrl() {
  if (process.env.GMAIL_OAUTH_REDIRECT_URI) return process.env.GMAIL_OAUTH_REDIRECT_URI;
  const dedicated = process.env.GMAIL_OAUTH_CLIENT_ID || process.env.GMAIL_OAUTH_CLIENT_SECRET;
  return `${baseUrl()}${dedicated ? '/api/admin/gmail/callback' : '/api/backup/google/callback'}`;
}
function credentials() {
  // Reuse the existing web OAuth application unless a separate Gmail client is configured.
  const dedicated = process.env.GMAIL_OAUTH_CLIENT_ID || process.env.GMAIL_OAUTH_CLIENT_SECRET;
  return dedicated ? [process.env.GMAIL_OAUTH_CLIENT_ID, process.env.GMAIL_OAUTH_CLIENT_SECRET]
    : [process.env.GOOGLE_DRIVE_OAUTH_CLIENT_ID, process.env.GOOGLE_DRIVE_OAUTH_CLIENT_SECRET];
}
function tokenKey() {
  const key = process.env.GMAIL_TOKEN_ENCRYPTION_KEY || process.env.BACKUP_TOKEN_ENCRYPTION_KEY || '';
  if (key.length < 32) throw problem(503, 'חסר מפתח הצפנה לחיבור Gmail');
  return crypto.hkdfSync('sha256', Buffer.from(key), Buffer.from('betshuva-gmail-v1'), Buffer.from('private-mail'), 32);
}
function configured() {
  try { tokenKey(); return credentials().every(value => typeof value === 'string' && value.trim()); }
  catch { return false; }
}
function encrypt(value, owner) {
  const nonce = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', tokenKey(), nonce);
  cipher.setAAD(Buffer.from(String(owner)));
  const encrypted = Buffer.concat([cipher.update(value, 'utf8'), cipher.final()]);
  return Buffer.concat([nonce, cipher.getAuthTag(), encrypted]).toString('base64url');
}
function decrypt(value, owner) {
  const bytes = Buffer.from(value, 'base64url');
  const cipher = crypto.createDecipheriv('aes-256-gcm', tokenKey(), bytes.subarray(0, 12));
  cipher.setAAD(Buffer.from(String(owner)));
  cipher.setAuthTag(bytes.subarray(12, 28));
  return Buffer.concat([cipher.update(bytes.subarray(28)), cipher.final()]).toString('utf8');
}
function problem(status, message) { return Object.assign(new Error(message), { status, publicMessage: message }); }
function hash(value) { return crypto.createHash('sha256').update(value).digest('hex'); }
function setupUrl() {
  const project = String(credentials()[0] || '').split('-')[0];
  return /^\d+$/.test(project)
    ? `https://console.cloud.google.com/apis/library/gmail.googleapis.com?project=${project}` : null;
}
function connectionError(error) {
  const body = error?.response?.data?.error;
  if (body?.details?.some(detail => detail.reason === 'SERVICE_DISABLED' &&
    detail.metadata?.service === 'gmail.googleapis.com') ||
    body?.errors?.some(detail => detail.reason === 'accessNotConfigured')) return 'api_disabled';
  if (body?.details?.some(detail => detail.reason === 'ACCESS_TOKEN_SCOPE_INSUFFICIENT')) return 'missing_permissions';
  if (body === 'invalid_grant') return 'expired_authorization';
  if (body === 'invalid_client') return 'oauth_configuration';
  return 'error';
}
function oauth() {
  if (!configured()) throw problem(503, 'חיבור Gmail עדיין לא הוגדר בשרת');
  return new OAuth2Client(...credentials(), callbackUrl());
}
function clientForToken(token) {
  const client = oauth(); client.setCredentials({ refresh_token: token }); return client;
}
async function request(client, resource, options = {}) {
  const { data } = await client.request({ url: `${API}${resource}`, timeout: 20000,
    retry: false, responseType: 'json', ...options });
  return data;
}
function header(message, name) {
  return String(message.payload?.headers?.find(h => h.name.toLowerCase() === name.toLowerCase())?.value || '');
}
function replyAddress(message) {
  const source = header(message, 'Reply-To') || header(message, 'From');
  if (/[\r\n\x00]/.test(source)) throw problem(422, 'כתובת המענה אינה תקינה');
  const addresses = addressParser(source, { flatten: true });
  if (addresses.length !== 1 || !/^[^\s<>@,;]+@[^\s<>@,;]+$/.test(addresses[0].address || ''))
    throw problem(422, 'לא נמצאה כתובת יחידה ותקינה למענה');
  return addresses[0].address;
}
function messageView(message) {
  const plain = [], html = [];
  function visit(part, depth = 0) {
    if (!part || depth > 25 || part.filename || /^attachment/i.test(
      part.headers?.find(h => h.name.toLowerCase() === 'content-disposition')?.value || '')) return;
    if (['text/plain', 'text/html'].includes(part.mimeType) && part.body?.data) {
      const type = part.headers?.find(h => h.name.toLowerCase() === 'content-type')?.value || '';
      const charset = /charset=["']?([^\s;"']+)/i.exec(type)?.[1] || 'utf-8';
      const bytes = Buffer.from(part.body.data, 'base64url');
      let text;
      try { text = new TextDecoder(charset).decode(bytes); }
      catch { text = bytes.toString('utf8'); }
      (part.mimeType === 'text/plain' ? plain : html).push(text);
    }
    for (const child of part.parts || []) visit(child, depth + 1);
  }
  visit(message.payload);
  let replyTo = null; try { replyTo = replyAddress(message); } catch (_) {}
  return { id: message.id, threadId: message.threadId, subject: header(message, 'Subject'),
    from: header(message, 'From'), to: header(message, 'To'), date: header(message, 'Date'),
    snippet: message.snippet || '', unread: message.labelIds?.includes('UNREAD') || false,
    text: plain.join('\n'), html: plain.length ? '' : html.join('\n'), replyTo };
}
async function buildReply(message, text, from) {
  if (typeof text !== 'string' || !text.trim() || text.length > 50000)
    throw problem(400, 'יש להזין תשובה באורך של עד 50,000 תווים');
  const messageId = header(message, 'Message-ID').trim();
  if (!/^<[^<>\s]+>$/.test(messageId)) throw problem(422, 'להודעה חסר מזהה תקין למענה בשרשור');
  const references = header(message, 'References').match(/<[^<>\s]+>/g) || [];
  const subject = header(message, 'Subject').replace(/[\r\n]/g, ' ');
  const mime = await new MailComposer({ from, to: replyAddress(message),
    subject: /^re:/i.test(subject) ? subject : `Re: ${subject}`, text,
    inReplyTo: messageId, references: [...references.slice(-20), messageId],
    disableFileAccess: true, disableUrlAccess: true }).compile().build();
  return { threadId: message.threadId, raw: mime.toString('base64url') };
}

function registerGmailRoutes(app, { secret, getPool, accountModerationError, rateLimit,
  makeClient = clientForToken, makeOauth = oauth }) {
  const cookieOptions = { httpOnly: true, secure: true, sameSite: 'lax', path: new URL(callbackUrl()).pathname };
  function noStore(_req, res, next) {
    res.set({ 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer' }); next();
  }
  async function owner(pool, id, claims) {
    const { rows } = await pool.query(`SELECT u.email,u.email_verified,u.session_version,
      u.moderation_state,u.moderation_reason,u.moderation_until
      FROM users u WHERE u.id=$1`, [id]);
    const user = rows[0];
    return user && user.email?.toLowerCase() === ownerEmail() && user.email_verified === true &&
      sessionCurrent(claims, user) && !accountModerationError(user);
  }
  async function ownerOnly(req, res, next) {
    try {
      const token = /^Bearer (\S+)$/i.exec(req.headers.authorization || '')?.[1];
      if (!token) throw new Error('Missing session');
      req.user = verifySession(token, secret);
    } catch { return res.status(401).json({ error: 'יש להתחבר לחשבון שלך' }); }
    try {
      if (!await owner(await getPool(), req.user.id, req.user))
        return res.status(403).json({ error: 'תיבת המייל זמינה רק לבעל החשבון' });
      next();
    } catch { res.status(503).json({ error: 'לא ניתן לאמת גישה לתיבת המייל' }); }
  }
  function handle(fn) { return async (req, res) => {
    try { await fn(req, res); }
    catch (error) {
      // OAuth/Gaxios errors can contain tokens and message bodies; never log/return them.
      res.status(error.status || 502).json({ error: error.publicMessage ||
        'הפעולה מול Gmail נכשלה. בדוק את החיבור ונסה שוב' });
    }
  }; }
  const guarded = [noStore, ownerOnly];
  async function account(req) {
    const pool = await getPool();
    const { rows } = await pool.query('SELECT email,encrypted_token FROM private_gmail_accounts WHERE user_id=$1', [req.user.id]);
    if (!rows[0] || rows[0].email !== ownerEmail()) throw problem(409, 'יש לחבר תחילה את חשבון Gmail');
    return { pool, client: makeClient(decrypt(rows[0].encrypted_token, req.user.id)) };
  }
  app.get('/api/admin/gmail/status', ...guarded, handle(async (req, res) => {
    const pool = await getPool();
    const { rows } = await pool.query('SELECT email,connected_at FROM private_gmail_accounts WHERE user_id=$1', [req.user.id]);
    res.json({ configured: configured(), connected: rows[0]?.email === ownerEmail(),
      email: ownerEmail(), connectedAt: rows[0]?.connected_at || null, setupUrl: setupUrl() });
  }));
  app.post('/api/admin/gmail/connect', ...guarded, rateLimit, handle(async (req, res) => {
    const client = makeOauth();
    const state = `gmail_${crypto.randomBytes(32).toString('base64url')}`;
    const browser = crypto.randomBytes(32).toString('base64url');
    const { codeVerifier, codeChallenge } = await client.generateCodeVerifierAsync();
    const pool = await getPool();
    await pool.query('DELETE FROM private_gmail_oauth WHERE expires_at<now() OR user_id=$1', [req.user.id]);
    await pool.query(`INSERT INTO private_gmail_oauth
      (state_hash,user_id,session_version,browser_hash,encrypted_verifier,expires_at)
      VALUES($1,$2,$3,$4,$5,now()+interval '10 minutes')`,
    [hash(state), req.user.id, req.user.sessionVersion || 0, hash(browser), encrypt(codeVerifier, req.user.id)]);
    res.cookie(COOKIE, browser, { ...cookieOptions, maxAge: 600000 });
    res.json({ authorizationUrl: client.generateAuthUrl({ access_type: 'offline', prompt: 'consent',
      scope: SCOPES, login_hint: ownerEmail(), state, code_challenge: codeChallenge,
      code_challenge_method: 'S256' }) });
  }));
  const callback = async (req, res) => {
    const finish = result => res.redirect(303, `${baseUrl()}/admin-gmail.html?gmail=${result}`);
    res.clearCookie(COOKIE, cookieOptions);
    let stage = 'validate_state';
    try {
      const browser = req.headers.cookie?.split(';').map(v => v.trim()).find(v => v.startsWith(`${COOKIE}=`))?.slice(COOKIE.length + 1);
      if (typeof req.query.state !== 'string' || !/^gmail_[\w-]{43}$/.test(req.query.state) || !browser)
        return finish('invalid_state');
      const pool = await getPool();
      const { rows } = await pool.query(`DELETE FROM private_gmail_oauth
        WHERE state_hash=$1 AND browser_hash=$2 AND expires_at>now() RETURNING *`, [hash(req.query.state), hash(browser)]);
      const state = rows[0];
      if (!state || !await owner(pool, state.user_id, { sessionVersion: state.session_version })) return finish('invalid_state');
      if (req.query.error || typeof req.query.code !== 'string') return finish('cancelled');
      const client = makeOauth();
      stage = 'exchange_code';
      const { tokens } = await client.getToken({ code: req.query.code,
        codeVerifier: decrypt(state.encrypted_verifier, state.user_id) });
      client.setCredentials(tokens);
      stage = 'read_profile';
      const profile = await request(client, '/profile');
      if (profile.emailAddress?.toLowerCase() !== ownerEmail()) return finish('wrong_account');
      const granted = new Set(String(tokens.scope || '').split(' '));
      if (!tokens.refresh_token || !SCOPES.every(scope => granted.has(scope))) return finish('missing_permissions');
      stage = 'save_connection';
      await pool.query(`INSERT INTO private_gmail_accounts(user_id,email,encrypted_token)
        VALUES($1,$2,$3) ON CONFLICT(user_id) DO UPDATE SET email=EXCLUDED.email,
        encrypted_token=EXCLUDED.encrypted_token,connected_at=now()`,
      [state.user_id, ownerEmail(), encrypt(tokens.refresh_token, state.user_id)]);
      return finish('connected');
    } catch (error) {
      const reason = connectionError(error);
      // Log only local, fixed labels: Google errors may embed credentials and auth codes.
      console.warn('[gmail-connection]', JSON.stringify({ stage, reason }));
      return finish(reason);
    }
  };
  app.get('/api/admin/gmail/callback', noStore, callback);
  // The existing web OAuth client already authorizes the Drive callback URI.
  // Only our namespaced states enter Gmail; all Drive callbacks continue unchanged.
  app.get('/api/backup/google/callback', (req, res, next) => {
    if (typeof req.query.state !== 'string' || !req.query.state.startsWith('gmail_')) return next();
    noStore(req, res, () => callback(req, res));
  });
  app.get('/api/admin/gmail/messages', ...guarded, handle(async (req, res) => {
    const { client } = await account(req);
    const q = typeof req.query.q === 'string' ? req.query.q : 'in:inbox';
    const pageToken = typeof req.query.pageToken === 'string' ? req.query.pageToken : '';
    if (q.length > 500 || pageToken.length > 2000) throw problem(400, 'חיפוש לא תקין');
    const query = new URLSearchParams({ maxResults: '20', q, ...(pageToken ? { pageToken } : {}) });
    const result = await request(client, `/messages?${query}`);
    const messages = [];
    // Small batches bound both Gmail quota usage and simultaneous requests.
    for (let i = 0; i < (result.messages || []).length; i += 5) {
      messages.push(...await Promise.all(result.messages.slice(i, i + 5).map(async item => {
        const data = await request(client, `/messages/${encodeURIComponent(item.id)}?format=metadata`);
        return messageView(data);
      })));
    }
    res.json({ messages, nextPageToken: result.nextPageToken || null });
  }));
  function messageId(req) {
    if (!/^[a-f0-9]{1,64}$/i.test(req.params.id || '')) throw problem(400, 'מזהה הודעה לא תקין');
    return req.params.id;
  }
  app.get('/api/admin/gmail/messages/:id', ...guarded, handle(async (req, res) => {
    const id = messageId(req), { client } = await account(req);
    res.json(messageView(await request(client, `/messages/${id}?format=full`)));
  }));
  app.post('/api/admin/gmail/messages/:id/reply', ...guarded, rateLimit, handle(async (req, res) => {
    const id = messageId(req), { requestId, text } = req.body || {};
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(requestId || '') ||
      typeof text !== 'string' || !text.trim() || text.length > 50000) throw problem(400, 'תשובה לא תקינה');
    const { pool, client } = await account(req);
    const fingerprint = hash(JSON.stringify([id, text]));
    const previous = await pool.query('SELECT * FROM private_gmail_replies WHERE user_id=$1 AND request_id=$2', [req.user.id, requestId]);
    if (previous.rows.length) {
      const saved = previous.rows[0];
      if (saved.content_hash !== fingerprint) throw problem(409, 'מזהה השליחה כבר משמש לתשובה אחרת');
      if (saved.status === 'sent') return res.json(saved.result);
      throw problem(409, 'מצב השליחה טרם אומת. בדוק את תיקיית נשלחו ב־Gmail לפני שליחה נוספת');
    }
    const original = await request(client, `/messages/${id}?format=metadata`);
    const data = await buildReply(original, text, ownerEmail());
    const claim = await pool.query(`INSERT INTO private_gmail_replies(user_id,request_id,content_hash,status)
      VALUES($1,$2,$3,'pending') ON CONFLICT DO NOTHING RETURNING request_id`, [req.user.id, requestId, fingerprint]);
    if (!claim.rows.length) throw problem(409, 'השליחה כבר בטיפול');
    try {
      const sent = await request(client, '/messages/send', { method: 'POST', data });
      const result = { id: sent.id, threadId: sent.threadId };
      await pool.query(`UPDATE private_gmail_replies SET status='sent',result=$3 WHERE user_id=$1 AND request_id=$2`,
        [req.user.id, requestId, result]);
      res.json(result);
    } catch {
      // A timeout may occur after Google accepts the mail. Never automatically resend.
      throw problem(409, 'לא ניתן לאמת אם התשובה נשלחה. בדוק את תיקיית נשלחו ב־Gmail לפני שליחה נוספת');
    }
  }));
}

module.exports = { SCHEMA, SCOPES, registerGmailRoutes, configured, callbackUrl,
  encrypt, decrypt, messageView, buildReply, replyAddress, connectionError };
