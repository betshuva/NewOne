'use strict';

function consumeOtp(store, phone, code) {
  const entry = store.get(phone);
  if (!entry) return null;
  if (Date.now() > entry.expires) { store.delete(phone); return null; }
  if (typeof code !== 'string' || entry.code !== code) {
    entry.attempts = (entry.attempts || 0) + 1;
    if (entry.attempts >= 5) store.delete(phone);
    return null;
  }
  // Consume synchronously, before the first database await in any route.
  store.delete(phone);
  return entry;
}

module.exports = { consumeOtp };
