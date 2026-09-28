'use strict';
const jwt = require('jsonwebtoken');

function verifySession(token, secret) {
  const claims = jwt.verify(token, secret, { algorithms: ['HS256'] });
  if (!claims || typeof claims !== 'object' || claims.purpose != null ||
      typeof claims.id !== 'string' || !claims.id || claims.id.length > 128 ||
      !Number.isSafeInteger(claims.sessionVersion ?? 0) || (claims.sessionVersion ?? 0) < 0) {
    throw new Error('Invalid session token');
  }
  return claims;
}

function signSession(user, secret) {
  return jwt.sign({ id: user.id, name: user.name, email: user.email,
    sessionVersion: Number(user.session_version || 0) }, secret,
  { algorithm: 'HS256', expiresIn: '30d' });
}

function sessionCurrent(claims, user) {
  return !!user && (claims.sessionVersion ?? 0) === Number(user.session_version || 0);
}

module.exports = { verifySession, signSession, sessionCurrent };
