'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const express = require('express');
const jwt = require('jsonwebtoken');
const { publicStatic, publishedPath } = require('../server/public-static');
const { securityHeaders, trustedProxyAddress } = require('../server/http-security');
const { verifySession, signSession, sessionCurrent } = require('../server/session-security');
const { consumeOtp } = require('../server/otp-security');
const { validResetInput } = require('../server/password-reset');

test('public HTTP files use an allowlist, including encoded paths and active uploads', async t => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'public-security-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  for (const name of ['index.html', 'firebase-service-account.json', 'server.log',
    'deploy-web-local.sh', 'package.json', 'main.dart.js', 'version.json',
    'betshuva-1.3.37.apk', 'server/index.js', 'backups/secret.json',
    'assets/font.ttf', 'uploads/example.html', 'uploads/audio.mp3', 'uploads/.guide-files/private.pdf']) {
    await fs.mkdir(path.dirname(path.join(root, name)), { recursive: true });
    await fs.writeFile(path.join(root, name), 'isolated fixture');
  }
  const app = express(); app.use(securityHeaders); app.use(publicStatic(root));
  const server = app.listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const request = target => new Promise((resolve, reject) => {
    http.get({ hostname: '127.0.0.1', port: server.address().port, path: target }, res => {
      res.resume(); res.on('end', () => resolve(res));
    }).on('error', reject);
  });
  for (const target of ['/firebase-service-account.json', '/%66irebase-service-account.json',
    '/server.log', '/deploy-web-local.sh', '/package.json', '/server/index.js',
    '/backups/secret.json', '/%2573erver/index.js', '/assets/%2e%2e/server/index.js',
    '/assets/..%2fserver/index.js', '/assets/%2e%2e%5cserver/index.js',
    '/uploads/.guide-files/private.pdf']) {
    assert.equal((await request(target)).statusCode, 404, target);
  }
  for (const target of ['/', '/main.dart.js', '/version.json', '/betshuva-1.3.37.apk',
    '/assets/font.ttf', '/uploads/audio.mp3']) {
    const res = await request(target);
    assert.equal(res.statusCode, 200, target);
    assert.equal(res.headers['x-frame-options'], 'SAMEORIGIN');
  }
  const html = await request('/uploads/example.html');
  assert.equal(html.headers['content-disposition'], 'attachment');
  assert.match(html.headers['content-security-policy'], /sandbox/);
  assert.equal(publishedPath('/assets/%ZZ'), false);
});

test('trusted proxy replaces spoofed forwarded headers and ignores external X-Real-IP', () => {
  const make = (remote, real) => ({ socket: { remoteAddress: remote },
    headers: { 'x-forwarded-for': '198.51.100.4' }, get: () => real });
  const local = make('127.0.0.1', '203.0.113.5');
  trustedProxyAddress(local, {}, () => {});
  assert.equal(local.headers['x-forwarded-for'], '203.0.113.5');
  const external = make('203.0.113.10', '192.0.2.1');
  trustedProxyAddress(external, {}, () => {});
  assert.equal(external.headers['x-forwarded-for'], '198.51.100.4');
});

test('sessions restrict algorithm and purpose, expire, and become invalid after reset', () => {
  const secret = 'isolated-test-key';
  const claims = verifySession(signSession({ id: 'user', session_version: 2 }, secret), secret);
  assert.equal(claims.exp - claims.iat, 30 * 24 * 60 * 60);
  assert.equal(sessionCurrent(claims, { session_version: 2 }), true);
  assert.equal(sessionCurrent(claims, { session_version: 3 }), false);
  for (const token of [jwt.sign({ id: 'user', purpose: 'registration' }, secret),
    jwt.sign({ id: 'user' }, secret, { algorithm: 'HS384' }),
    jwt.sign({ id: 'user' }, secret, { expiresIn: -1 }),
    jwt.sign({ id: {} }, secret), jwt.sign({ id: 'user' }, 'wrong-key')]) {
    assert.throws(() => verifySession(token, secret));
  }
  const legacy = verifySession(jwt.sign({ id: 'user' }, secret), secret);
  assert.equal(sessionCurrent(legacy, { session_version: 0 }), true);
  assert.equal(sessionCurrent(legacy, { session_version: 1 }), false);
});

test('OTP is consumed before asynchronous work, with five guesses at most', () => {
  const store = new Map([['phone', { code: '123456', expires: Date.now() + 60000 }]]);
  assert.ok(consumeOtp(store, 'phone', '123456'));
  assert.equal(consumeOtp(store, 'phone', '123456'), null);
  store.set('phone', { code: '123456', expires: Date.now() + 60000 });
  for (let n = 0; n < 5; n++) assert.equal(consumeOtp(store, 'phone', 'wrong'), null);
  assert.equal(consumeOtp(store, 'phone', '123456'), null);
  store.set('phone', { code: '123456', expires: Date.now() - 1 });
  assert.equal(consumeOtp(store, 'phone', '123456'), null);
});

test('reset rejects malformed values and bcrypt truncation before database access', () => {
  const token = 'a'.repeat(64);
  assert.equal(validResetInput(token, 'normal password'), true);
  for (const password of [null, {}, [], 'short', 'a'.repeat(73), 'א'.repeat(37)])
    assert.equal(validResetInput(token, password), false);
  for (const bad of [null, {}, [], 'invalid', '<script>', 'a'.repeat(65)])
    assert.equal(validResetInput(bad, 'normal password'), false);
});
