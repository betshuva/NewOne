const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const root = path.join(__dirname, '..');
const server = fs.readFileSync(path.join(root, 'server', 'index.js'), 'utf8');
const deletionPage = fs.readFileSync(path.join(root, 'delete-account.html'), 'utf8');

function routeSource(startMarker, endMarker) {
  const start = server.indexOf(startMarker);
  const end = server.indexOf(endMarker, start + startMarker.length);
  assert.ok(start >= 0 && end > start, `missing route section: ${startMarker}`);
  return server.slice(start, end);
}

test('full account deletion requires explicit confirmation and removes active data', () => {
  const route = routeSource("app.delete('/api/account'", "app.delete('/api/account/data'");

  assert.match(route, /confirmation !== 'DELETE'/);
  for (const statement of [
    'DELETE FROM messages',
    'DELETE FROM listings',
    'DELETE FROM fcm_tokens',
    'DELETE FROM activity_log',
    'DELETE FROM audit_log',
    'DELETE FROM users',
  ]) {
    assert.ok(route.includes(statement), `full deletion is missing: ${statement}`);
  }
});

test('physical file metadata is retained until deletion succeeds', () => {
  const helper = routeSource('async function deleteStoredFile', '// A signed-in user');
  const route = routeSource("app.delete('/api/account'", "app.delete('/api/account/data'");

  assert.ok(helper.indexOf('await fs.unlink') < helper.indexOf("DELETE FROM stored_files"));
  assert.doesNotMatch(route, /DELETE FROM stored_files WHERE user_id/);
  assert.match(route, /filesPending/);
});

test('public deletion instructions match the in-app deletion label', () => {
  assert.match(deletionPage, /מחיקת תוכן, פרופיל או חשבון/);
  assert.match(deletionPage, /מפעיל הבטא: יניב אליהו/);
  assert.doesNotMatch(deletionPage, /לא יאוחר מ־90 יום/);
});
