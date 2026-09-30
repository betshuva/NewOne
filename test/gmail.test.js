'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const express = require('express');
const { OAuth2Client } = require('google-auth-library');
const gmail = require('../server/gmail');
const { signSession } = require('../server/session-security');

const message = { id: 'abc123', threadId: 'def456', payload: { headers: [
  { name: 'From', value: 'Sender <sender@example.com>' },
  { name: 'Reply-To', value: 'Reply <reply@example.com>' },
  { name: 'Subject', value: 'בדיקה' }, { name: 'Message-ID', value: '<original@example.com>' },
] } };

test('Gmail connection failures expose fixed reasons without leaking Google secrets', () => {
  const error = { response: { data: { error: { details: [{ reason: 'SERVICE_DISABLED',
    metadata: { service: 'gmail.googleapis.com', sensitive: 'secret-token' } }] } } } };
  assert.equal(gmail.connectionError(error), 'api_disabled');
  error.response.data.error.details[0].metadata.service = 'unrelated.googleapis.com';
  assert.equal(gmail.connectionError(error), 'error');
  error.response.data.error = { details: [{ reason: 'ACCESS_TOKEN_SCOPE_INSUFFICIENT' }] };
  assert.equal(gmail.connectionError(error), 'missing_permissions');
  error.response.data.error = 'invalid_grant';
  assert.equal(gmail.connectionError(error), 'expired_authorization');
  assert.equal(gmail.connectionError(new Error('secret-token')), 'error');
});

test('Gmail tokens are encrypted, authenticated and bound to their owner', t => {
  const previous = process.env.GMAIL_TOKEN_ENCRYPTION_KEY;
  process.env.GMAIL_TOKEN_ENCRYPTION_KEY = 'test-only-gmail-encryption-key-longer-than-32';
  t.after(() => { if (previous === undefined) delete process.env.GMAIL_TOKEN_ENCRYPTION_KEY;
    else process.env.GMAIL_TOKEN_ENCRYPTION_KEY = previous; });
  const encrypted = gmail.encrypt('refresh-secret', 'owner');
  assert.equal(gmail.decrypt(encrypted, 'owner'), 'refresh-secret');
  assert.throws(() => gmail.decrypt(encrypted, 'other'));
  const changed = Buffer.from(encrypted, 'base64url'); changed[30] ^= 1;
  assert.throws(() => gmail.decrypt(changed.toString('base64url'), 'owner'));
  assert.ok(!encrypted.includes('refresh-secret'));
});

test('replies preserve threading, encode Hebrew, use Reply-To and reject injected recipients', async () => {
  const reply = await gmail.buildReply(message, 'שלום וברכה', 'yanive8@gmail.com');
  assert.equal(reply.threadId, message.threadId);
  const mime = Buffer.from(reply.raw, 'base64url').toString('utf8');
  assert.match(mime, /To: reply@example.com/);
  assert.match(mime, /In-Reply-To: <original@example.com>/);
  assert.match(mime, /References: <original@example.com>/);
  assert.match(mime, /charset=utf-8/i);
  await assert.rejects(gmail.buildReply(message, '', 'yanive8@gmail.com'));
  const injected = structuredClone(message);
  injected.payload.headers[1].value = 'a@example.com, victim@example.com';
  await assert.rejects(gmail.buildReply(injected, 'text', 'yanive8@gmail.com'));
  injected.payload.headers[1].value = 'attacker@example.com\r\nBcc: victim@example.com';
  await assert.rejects(gmail.buildReply(injected, 'text', 'yanive8@gmail.com'));
});

test('multipart mail prefers plain text, decodes legacy charsets and ignores attached text', () => {
  const mail = structuredClone(message);
  mail.payload.parts = [
    { mimeType: 'text/html', body: { data: Buffer.from('<b>html</b>').toString('base64url') } },
    { mimeType: 'text/plain', headers: [{ name: 'Content-Type', value: 'text/plain; charset=windows-1255' }],
      body: { data: Buffer.from([0xf9, 0xec, 0xe5, 0xed]).toString('base64url') } },
    { mimeType: 'text/plain', filename: 'private.txt', body: { data: Buffer.from('attachment').toString('base64url') } },
  ];
  assert.equal(gmail.messageView(mail).text, 'שלום');
  assert.equal(gmail.messageView(mail).html, '');
});

test('private Gmail routes enforce owner access, browser-bound OAuth, permissions and send deduplication', {
  skip: process.env.RUN_DB_TESTS !== '1',
}, async t => {
  const { Pool, Client } = require('pg');
  const old = process.env.GMAIL_TOKEN_ENCRYPTION_KEY;
  process.env.GMAIL_TOKEN_ENCRYPTION_KEY = 'test-only-gmail-encryption-key-longer-than-32';
  t.after(() => { if (old === undefined) delete process.env.GMAIL_TOKEN_ENCRYPTION_KEY;
    else process.env.GMAIL_TOKEN_ENCRYPTION_KEY = old; });
  const schema = `gmail_test_${crypto.randomBytes(8).toString('hex')}`;
  const options = { connectionString: process.env.DATABASE_URL,
    ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: true } : false };
  const db = new Client(options); await db.connect();
  let pool, server;
  t.after(async () => {
    if (server) { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
    if (pool) await pool.end();
    await db.query(`DROP SCHEMA IF EXISTS "${schema}" CASCADE`); await db.end();
  });
  await db.query(`CREATE SCHEMA "${schema}"`);
  pool = new Pool({ ...options, options: `-c search_path=${schema}` });
  await pool.query(`CREATE TABLE users(id UUID PRIMARY KEY,email TEXT,email_verified BOOLEAN,
    session_version INTEGER DEFAULT 0,moderation_state TEXT,moderation_reason TEXT,moderation_until TIMESTAMPTZ);
    CREATE TABLE admin_permissions(user_id UUID PRIMARY KEY,permission TEXT);`);
  await pool.query(gmail.SCHEMA);
  const owner = crypto.randomUUID(), other = crypto.randomUUID();
  await pool.query(`INSERT INTO users(id,email,email_verified) VALUES($1,'yanive8@gmail.com',true),($2,'other@example.com',true);
  `, [owner, other]);
  await pool.query(`INSERT INTO admin_permissions VALUES($1,'edit'),($2,'edit')`, [owner, other]);
  let sends = 0, failSend = false, wrongAccount = false, apiDisabled = false, scopes = gmail.SCOPES.join(' '), exchanges = 0;
  const fakeClient = { request: async options => {
    if (apiDisabled) throw { response: { data: { error: { details: [{ reason: 'SERVICE_DISABLED',
      metadata: { service: 'gmail.googleapis.com' } }] } } } };
    if (options.url.endsWith('/profile')) return { data: { emailAddress: wrongAccount ? 'other@example.com' : 'yanive8@gmail.com' } };
    if (options.url.includes('/messages/send')) {
      sends++; if (failSend) throw new Error('timeout SECRET');
      await new Promise(resolve => setTimeout(resolve, 30));
      return { data: { id: 'sent123', threadId: message.threadId } };
    }
    if (options.url.includes('/messages/abc123')) return { data: message };
    return { data: { messages: [{ id: 'abc123' }] } };
  } };
  function makeOauth() {
    const client = new OAuth2Client('test.apps.googleusercontent.com', 'test-secret', gmail.callbackUrl());
    client.getToken = async options => { exchanges++; assert.ok(options.codeVerifier);
      return { tokens: { refresh_token: 'refresh-secret', scope: scopes } }; };
    client.request = fakeClient.request;
    return client;
  }
  const app = express(); app.use(express.json());
  const secret = 'test-only-session-key-longer-than-32-bytes';
  gmail.registerGmailRoutes(app, { secret, getPool: async () => pool, makeClient: () => fakeClient, makeOauth,
    accountModerationError: user => user.moderation_state === 'blocked',
    rateLimit: (_req, _res, next) => next() });
  app.get('/api/backup/google/callback', (_req, res) => res.json({ driveCallback: true }));
  server = await new Promise(resolve => { const s = app.listen(0, '127.0.0.1', () => resolve(s)); });
  const root = `http://127.0.0.1:${server.address().port}/api/admin/gmail`;
  const call = (path, body, user = owner) => fetch(root + path, {
    method: body ? 'POST' : 'GET', headers: { Authorization: user ? `Bearer ${signSession({ id: user }, secret)}` : '', 'Content-Type': 'application/json' },
    ...(body ? { body: JSON.stringify(body) } : {}) });
  for (const [path, body] of [['/status'], ['/messages'], ['/messages/abc123'], ['/connect', {}],
    ['/messages/abc123/reply', { requestId: crypto.randomUUID(), text: 'text' }]]) {
    assert.equal((await call(path, body, '')).status, 401);
    assert.equal((await call(path, body, other)).status, 403);
  }
  await pool.query('UPDATE users SET email_verified=false WHERE id=$1', [owner]);
  assert.equal((await call('/status')).status, 403);
  await pool.query('UPDATE users SET email_verified=true WHERE id=$1', [owner]);
  await pool.query('DELETE FROM admin_permissions WHERE user_id=$1', [owner]);
  assert.equal((await call('/status')).status, 200, 'the mailbox owner needs no site admin privilege');
  assert.equal((await call('/messages')).status, 409);
  async function begin() {
    const response = await call('/connect', {}); assert.equal(response.status, 200);
    const cookie = response.headers.get('set-cookie').split(';')[0];
    const url = new URL((await response.json()).authorizationUrl);
    assert.equal(url.searchParams.get('code_challenge_method'), 'S256');
    assert.equal(url.searchParams.get('scope'), gmail.SCOPES.join(' '));
    return { cookie, state: url.searchParams.get('state') };
  }
  assert.equal((await (await fetch(root.replace('/api/admin/gmail', '/api/backup/google/callback') + '?state=drive-state')).json()).driveCallback, true);
  const callback = ({ state, cookie }) => fetch(`${root.replace('/api/admin/gmail', '/api/backup/google/callback')}?state=${state}&code=test-code`, {
    redirect: 'manual', headers: { Cookie: cookie } });
  apiDisabled = true;
  assert.match((await callback(await begin())).headers.get('location'), /api_disabled$/);
  assert.equal((await pool.query('SELECT * FROM private_gmail_accounts')).rowCount, 0);
  apiDisabled = false; exchanges = 0;
  const flow = await begin();
  assert.match((await callback({ ...flow, cookie: 'invalid=1' })).headers.get('location'), /invalid_state$/);
  assert.equal(exchanges, 0);
  assert.match((await callback(flow)).headers.get('location'), /connected$/);
  assert.match((await callback(flow)).headers.get('location'), /invalid_state$/);
  assert.equal(exchanges, 1);
  assert.equal((await (await call('/status')).json()).connected, true);
  assert.equal((await call('/status')).headers.get('cache-control'), 'no-store');
  wrongAccount = true;
  assert.match((await callback(await begin())).headers.get('location'), /wrong_account$/);
  wrongAccount = false; scopes = gmail.SCOPES[0];
  assert.match((await callback(await begin())).headers.get('location'), /missing_permissions$/);
  scopes = gmail.SCOPES.join(' ');
  const stale = await begin();
  await pool.query('UPDATE users SET session_version=1 WHERE id=$1', [owner]);
  assert.match((await callback(stale)).headers.get('location'), /invalid_state$/);
  await pool.query('UPDATE users SET session_version=0 WHERE id=$1', [owner]);
  const list = await (await call('/messages')).json(); assert.equal(list.messages[0].id, message.id);
  const body = { requestId: crypto.randomUUID(), text: 'שלום' };
  const results = await Promise.all([call('/messages/abc123/reply', body), call('/messages/abc123/reply', body)]);
  assert.equal(results.filter(r => r.status === 200).length, 1); assert.equal(sends, 1);
  assert.equal((await call('/messages/abc123/reply', body)).status, 200); assert.equal(sends, 1);
  assert.equal((await call('/messages/abc123/reply', { ...body, text: 'changed' })).status, 409);
  failSend = true;
  const uncertain = { requestId: crypto.randomUUID(), text: 'uncertain' };
  const failed = await call('/messages/abc123/reply', uncertain);
  assert.equal(failed.status, 409); assert.ok(!(await failed.text()).includes('SECRET'));
  assert.equal((await call('/messages/abc123/reply', uncertain)).status, 409); assert.equal(sends, 2);
});
