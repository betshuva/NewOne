'use strict';

const path = require('node:path');
const express = require('express');

// The project directory also holds credentials, logs, backups and source code.
// Only files deliberately published by the web application may be served.
const publicFiles = new Set([
  '/', '/index.html', '/home.html', '/privacy.html', '/terms.html',
  '/delete-account.html', '/child-safety.html', '/accessibility.html',
  '/open-source-licenses.html', '/admin.html', '/admin-audit.html', '/admin-gmail.html', '/admin-storage.html',
  '/admin-members.html', '/groups.html', '/invite-v2.html', '/public-users.html',
  '/play-store-description.html', '/image-links.html', '/logo.html',
  '/demo-conversations.html', '/favicon.png', '/manifest.json', '/version.json',
  '/flutter.js', '/flutter_bootstrap.js', '/flutter_service_worker.js',
  '/firebase-messaging-sw.js', '/main.dart.js', '/whatsapp-card-v2.jpg',
]);
const publicDirectories = ['/assets/', '/canvaskit/', '/icons/',
  '/expression-library/', '/store-assets/', '/uploads/'];

function publishedPath(urlPath) {
  let decoded;
  try { decoded = decodeURIComponent(urlPath); } catch { return false; }
  // Reject ambiguous encodings, traversal and hidden files before sendFile decodes.
  if (/[\\\x00%]/.test(decoded) || decoded.split('/').some(part =>
    part.startsWith('.') || part === '..')) return false;
  if (decoded !== path.posix.normalize(decoded)) return false;
  return publicFiles.has(decoded) ||
    /^\/(?:betshuva-\d+\.\d+\.\d+|app-release)\.apk(?:\.sha256)?$/.test(decoded) ||
    /^\/google-play-feature-graphic-[\w-]+\.png$/.test(decoded) ||
    publicDirectories.some(prefix => decoded.startsWith(prefix));
}

function publicStatic(root) {
  const serve = express.static(root, { dotfiles: 'deny', setHeaders(res, file) {
    if (file.startsWith(path.join(root, 'uploads') + path.sep)) {
      // Uploaded active content must never execute with the application's origin.
      res.setHeader('Content-Security-Policy', "sandbox; default-src 'none'; frame-ancestors 'self'");
      if (/\.(?:html?|xhtml|svg|xml|m?js|css)$/i.test(file))
        res.setHeader('Content-Disposition', 'attachment');
    }
  } });
  return (req, res, next) => {
    if (!publishedPath(req.path)) return next();
    return serve(req, res, next);
  };
}

module.exports = { publicStatic, publishedPath };
