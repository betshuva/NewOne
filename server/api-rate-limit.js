const jwt = require('jsonwebtoken');

// This identity is used only to allocate request budgets. Route authentication
// still verifies that the account exists and may access the requested data.
function verifiedSessionId(req, secret) {
  const authorization = req.headers?.authorization;
  const match = typeof authorization === 'string' &&
    authorization.match(/^Bearer ([^\s]+)$/i);
  if (!match) return null;
  try {
    const session = jwt.verify(match[1], secret, { algorithms: ['HS256'] });
    if (!session || typeof session !== 'object' || session.purpose != null ||
        typeof session.id !== 'string' || !session.id.trim() || session.id.length > 128)
      return null;
    return session.id;
  } catch (_) {
    return null;
  }
}

function createApiRateLimit({ createRateLimiter, clientIp, getSecret }) {
  const sessionId = Symbol('rateLimitSessionId');
  const keyGenerator = req => req[sessionId]
    ? `account:${req[sessionId]}` : `ip:${clientIp(req)}`;
  const options = {
    windowMs: 5 * 60 * 1000,
    keyGenerator,
    message: 'בוצעו יותר מדי בקשות. נסה שוב בעוד מספר דקות',
  };
  const general = createRateLimiter({ ...options, name: 'api', max: 600 });
  const registrationStatus = createRateLimiter({
    ...options, name: 'registration-status', max: 60,
  });
  const birthDate = createRateLimiter({
    ...options, name: 'birth-date', max: 10,
  });

  return (req, res, next) => {
    req[sessionId] = verifiedSessionId(req, getSecret());
    // Keep account setup reachable when conversation polling exhausts the
    // general budget. These routes retain their own limits and authentication.
    if (req[sessionId]) {
      if (req.method === 'GET' && req.path === '/registration-status')
        return registrationStatus(req, res, next);
      if (req.method === 'PUT' && req.path === '/profile/birth-date')
        return birthDate(req, res, next);
    }
    return general(req, res, next);
  };
}

module.exports = { createApiRateLimit, verifiedSessionId };
