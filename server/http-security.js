'use strict';
const net = require('node:net');

function trustedProxyAddress(req, _res, next) {
  const remote = req.socket?.remoteAddress;
  const real = req.get('x-real-ip')?.trim();
  if (['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(remote) && net.isIP(real || '')) {
    // Nginx overwrites X-Real-IP. Never prefer a client's forwarded header.
    req.headers['x-forwarded-for'] = real;
  }
  next();
}

function securityHeaders(_req, res, next) {
  res.set({
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'SAMEORIGIN',
    'Content-Security-Policy': "frame-ancestors 'self'; object-src 'none'; base-uri 'self'",
    'Referrer-Policy': 'strict-origin-when-cross-origin',
    'Permissions-Policy': 'camera=(self), microphone=(self), geolocation=(self)',
  });
  next();
}

module.exports = { trustedProxyAddress, securityHeaders };
