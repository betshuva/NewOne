const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const root = path.join(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const server = read('server/index.js');

function routeSource(startMarker, endMarker) {
  const start = server.indexOf(startMarker);
  const end = server.indexOf(endMarker, start + startMarker.length);
  assert.ok(start >= 0 && end > start, `missing route section: ${startMarker}`);
  return server.slice(start, end);
}

test('registration requires a valid birth date and rejects users under 13', () => {
  assert.match(server, /function validateRegistrationAge/);
  assert.match(server, /if \(age < 13\)/);
  assert.match(server, /birth_date DATE/);
  assert.match(routeSource("app.post('/api/register'", "app.post('/api/login'"),
    /validateRegistrationAge\(req\.body\.birthDate\)/);
  assert.match(read('flutter_app/lib/main.dart'), /'birthDate': _formatBirthDate\(_birthDate!\)/);
});

test('teen conversations require mutual saved contacts on every content path', () => {
  assert.match(server, /async function teenContactAllowed/);
  assert.match(routeSource("app.get('/api/messages/:userId'", "app.post('/api/messages'"),
    /teenContactAllowed/);
  assert.match(routeSource("app.post('/api/messages'", "app.get('/api/message-requests'"),
    /teenContactAllowed/);
  assert.match(routeSource("app.post('/api/upload'", '// ── Groups: list mine'),
    /teenContactAllowed/);
  assert.match(server, /socket\.on\('chat:message'[\s\S]*teenContactAllowed/);
  assert.match(server, /socket\.on\('call:start'[\s\S]*teenContactAllowed/);
});

test('teen mode disables location, groups, public listings and open discovery', () => {
  for (const code of [
    'TEEN_LOCATION_DISABLED',
    'TEEN_GROUPS_DISABLED',
    'TEEN_LISTINGS_DISABLED',
  ]) assert.match(server, new RegExp(code));
  assert.match(routeSource("app.get('/api/users/directory'", "app.get('/api/users/search'"),
    /birth_date[\s\S]*user_contacts/);
  assert.match(routeSource("app.get('/api/users/search'", "app.post('/api/contacts/save"),
    /birth_date[\s\S]*user_contacts/);
});

test('legacy accounts without a birth date fail safe instead of being treated as adults', () => {
  assert.match(server, /birth_date IS NULL OR birth_date > CURRENT_DATE - INTERVAL '18 years'/);
  const directory = routeSource("app.get('/api/users/directory'", "app.get('/api/users/search'");
  assert.doesNotMatch(directory, /birth_date IS NULL\s+OR/);
});

test('legacy accounts can complete an immutable validated birth date', () => {
  const route = routeSource("app.put('/api/profile/birth-date'", '// ── Profile: update');
  assert.match(route, /validateRegistrationAge/);
  assert.match(route, /birth_date IS NULL/);
  assert.match(route, /BIRTH_DATE_ALREADY_SET/);
  assert.match(server, /birthDateMissing: !user\.birth_date/);
  const flutter = read('flutter_app/lib/main.dart');
  assert.match(flutter, /class _CompleteBirthDateScreen/);
  assert.match(flutter, /profile\/birth-date/);
});

test('teen sockets cannot join, send to, or receive pushes from group rooms', () => {
  assert.match(server, /if \(socket\.user\.isTeen\) throw new Error\('teen_groups_disabled'\)/);
  assert.match(server, /socket\.on\('group:message'[\s\S]*socket\.user\.isTeen/);
  assert.match(server, /socket\.on\('group:join'[\s\S]*socket\.user\.isTeen/);
  assert.match(server, /u\.birth_date <= CURRENT_DATE - INTERVAL '18 years'/);
});

test('legal pages explain birth-date processing and teen protections', () => {
  assert.match(read('terms.html'), /חשבון נוער/);
  assert.match(read('privacy.html'), /תאריך לידה/);
  assert.match(read('privacy.html'), /13–17/);
});
