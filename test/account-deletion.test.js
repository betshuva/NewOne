const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const root = path.join(__dirname, '..');
const server = fs.readFileSync(path.join(root, 'server', 'index.js'), 'utf8');
const deletionPage = fs.readFileSync(path.join(root, 'delete-account.html'), 'utf8');
const appSource = fs.readFileSync(
  path.join(root, 'flutter_app', 'lib', 'main.dart'), 'utf8');

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

test('deleted accounts are acknowledged before realtime disconnect and slow file cleanup', () => {
  const route = routeSource("app.delete('/api/account'", "app.delete('/api/account/data'");
  const acknowledgement = route.indexOf('res.json({ ok: true');
  assert.ok(acknowledgement > route.indexOf("await client.query('COMMIT')"));
  assert.ok(acknowledgement < route.indexOf("socket?.emit('force_logout'"));
  assert.ok(acknowledgement < route.indexOf('Promise.all([...new Set(fileUrls)]'));
  assert.match(route, /reason: 'החשבון נמחק'/);
  assert.match(appSource, /choice == 'account'\s*&&\s*await _accountWasDeleted\(\)/);
  assert.match(appSource,
    /Navigator\.of\(context, rootNavigator: true\)\.pushAndRemoveUntil/);
});

test('account deletion removes personal Drive backups before keys and identity', () => {
  const helper = routeSource('async function deleteUserPersonalDriveBackups',
    '// A signed-in user');
  const full = routeSource("app.delete('/api/account'", "app.delete('/api/account/data'");
  const dataOnly = routeSource("app.delete('/api/account/data'", "app.delete('/api/admin/users");
  assert.match(helper, /UPDATE user_backup_settings SET enabled=FALSE/);
  assert.match(helper, /status='uploading'/);
  assert.match(helper, /BACKUP_BUSY/);
  assert.match(helper, /encryption_metadata\?\.manifestRemoteId/);
  assert.match(helper, /personalDrive\.deleteAppDataFile/);
  assert.match(helper, /BACKUP_RECONNECT_REQUIRED/);
  assert.ok(full.indexOf('prepareAccountBackupDeletion') <
    full.indexOf("DELETE FROM users"));
  assert.match(full, /cloudBackupFilesDeleted/);
  assert.ok(dataOnly.indexOf('prepareAccountBackupDeletion') <
    dataOnly.indexOf('DELETE FROM user_backup_settings'));
  assert.match(dataOnly, /DELETE FROM cloud_backup_accounts/);
  assert.match(dataOnly, /cloudBackupFilesDeleted/);
});

test('public deletion instructions match the in-app deletion label', () => {
  assert.match(deletionPage, /מחיקת תוכן, פרופיל או חשבון/);
  assert.match(deletionPage, /מפעיל הבטא: יניב אליהו/);
  assert.doesNotMatch(deletionPage, /לא יאוחר מ־90 יום/);
});

test('deletion confirmation warns that encrypted Drive backups are deleted', () => {
  assert.match(appSource,
    /כולל הגיבויים המוצפנים ב־Google Drive/);
  assert.match(appSource,
    /פרטי הפרופיל והגיבויים המוצפנים ב־Google Drive יימחקו/);
});
