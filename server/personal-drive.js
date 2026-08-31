'use strict';

const crypto = require('crypto');
const { OAuth2Client } = require('google-auth-library');

const DRIVE_APPDATA_SCOPE = 'https://www.googleapis.com/auth/drive.appdata';
const DRIVE_API = 'https://www.googleapis.com/drive/v3';

function callbackUrl() {
  const appBase = String(process.env.APP_URL || 'https://betshuva.com/betshuva-app')
    .replace(/\/$/, '');
  return `${appBase}/api/backup/google/callback`;
}

function configured() {
  return Boolean(String(process.env.GOOGLE_DRIVE_OAUTH_CLIENT_ID || '').trim() &&
    String(process.env.GOOGLE_DRIVE_OAUTH_CLIENT_SECRET || '').trim());
}

function oauthClient() {
  if (!configured()) throw new Error('Personal Google Drive OAuth is not configured');
  return new OAuth2Client(process.env.GOOGLE_DRIVE_OAUTH_CLIENT_ID,
    process.env.GOOGLE_DRIVE_OAUTH_CLIENT_SECRET, callbackUrl());
}

function authorizationUrl(state) {
  return oauthClient().generateAuthUrl({ access_type: 'offline', prompt: 'consent',
    include_granted_scopes: true, scope: [DRIVE_APPDATA_SCOPE], state });
}

async function exchangeCode(code) {
  const client = oauthClient();
  const { tokens } = await client.getToken(code);
  if (!tokens.refresh_token) throw new Error('Google did not issue an offline refresh token');
  client.setCredentials(tokens);
  await verifyAppDataAccess(client);
  return tokens;
}

async function verifyAppDataAccess(clientOrRefreshToken) {
  const client = typeof clientOrRefreshToken === 'string' ? oauthClient() : clientOrRefreshToken;
  if (typeof clientOrRefreshToken === 'string')
    client.setCredentials({ refresh_token: clientOrRefreshToken });
  const headers = await client.getRequestHeaders();
  const query = new URLSearchParams({ spaces: 'appDataFolder', pageSize: '1', fields: 'files(id)' });
  const response = await fetch(`${DRIVE_API}/files?${query}`, { headers });
  if (!response.ok) throw new Error(`Google appDataFolder verification failed (${response.status})`);
  return true;
}

function clientForRefreshToken(refreshToken) {
  const client = oauthClient();
  client.setCredentials({ refresh_token: refreshToken });
  return client;
}

async function uploadAppDataFile(refreshToken, name, bytes, mimeType, appProperties = {}) {
  const client = clientForRefreshToken(refreshToken);
  const headers = await client.getRequestHeaders();
  const form = new FormData();
  form.append('metadata', new Blob([JSON.stringify({ name, parents: ['appDataFolder'],
    appProperties })], { type: 'application/json; charset=UTF-8' }));
  form.append('media', new Blob([bytes], { type: mimeType || 'application/octet-stream' }));
  const response = await fetch(
    'https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,size,md5Checksum',
    { method: 'POST', headers, body: form });
  if (!response.ok) throw new Error(`Google appDataFolder upload failed (${response.status})`);
  return response.json();
}

async function deleteAppDataFile(refreshToken, fileId) {
  const client = clientForRefreshToken(refreshToken);
  const headers = await client.getRequestHeaders();
  const response = await fetch(`${DRIVE_API}/files/${encodeURIComponent(fileId)}`,
    { method: 'DELETE', headers });
  if (!response.ok && response.status !== 404)
    throw new Error(`Google appDataFolder delete failed (${response.status})`);
}

async function downloadAppDataFile(refreshToken, fileId, maxBytes = 110 * 1024 * 1024) {
  const client = clientForRefreshToken(refreshToken);
  const headers = await client.getRequestHeaders();
  const response = await fetch(
    `${DRIVE_API}/files/${encodeURIComponent(fileId)}?alt=media`, { headers });
  if (!response.ok)
    throw new Error(`Google appDataFolder download failed (${response.status})`);
  const declared = Number(response.headers.get('content-length') || 0);
  if (declared > maxBytes) throw new Error('Google appDataFolder file exceeds size limit');
  const bytes = Buffer.from(await response.arrayBuffer());
  if (bytes.length > maxBytes) throw new Error('Google appDataFolder file exceeds size limit');
  return bytes;
}

function tokenKey() {
  const master = String(process.env.BACKUP_TOKEN_ENCRYPTION_KEY || process.env.JWT_SECRET || '');
  if (master.length < 32) throw new Error('Backup token encryption key is not configured securely');
  return crypto.hkdfSync('sha256', Buffer.from(master), Buffer.from('betshuva-backup-tokens-v1'),
    Buffer.from('google-drive-refresh-token'), 32);
}

function encryptRefreshToken(refreshToken, userId) {
  const nonce = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', tokenKey(), nonce);
  cipher.setAAD(Buffer.from(String(userId)));
  const encrypted = Buffer.concat([cipher.update(refreshToken, 'utf8'), cipher.final()]);
  return JSON.stringify({ v: 1, n: nonce.toString('base64'), t: cipher.getAuthTag().toString('base64'),
    c: encrypted.toString('base64') });
}

function decryptRefreshToken(value, userId) {
  const envelope = JSON.parse(value);
  if (envelope.v !== 1) throw new Error('Unsupported token envelope');
  const decipher = crypto.createDecipheriv('aes-256-gcm', tokenKey(), Buffer.from(envelope.n, 'base64'));
  decipher.setAAD(Buffer.from(String(userId)));
  decipher.setAuthTag(Buffer.from(envelope.t, 'base64'));
  return Buffer.concat([decipher.update(Buffer.from(envelope.c, 'base64')), decipher.final()])
    .toString('utf8');
}

async function revoke(refreshToken) {
  await oauthClient().revokeToken(refreshToken);
}

module.exports = { DRIVE_APPDATA_SCOPE, authorizationUrl, callbackUrl, configured,
  decryptRefreshToken, deleteAppDataFile, downloadAppDataFile, encryptRefreshToken,
  exchangeCode, revoke, uploadAppDataFile, verifyAppDataAccess };
