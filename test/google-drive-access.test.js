const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const root = path.join(__dirname, '..');
const server = fs.readFileSync(path.join(root, 'server', 'index.js'), 'utf8');
const drive = fs.readFileSync(path.join(root, 'server', 'google-drive.js'), 'utf8');

test('Google Drive endpoints are restricted to administrators', () => {
  for (const route of [
    "app.get('/api/admin/drive/status', adminAuth",
    "app.get('/api/admin/drive/files', adminAuth",
    "app.get('/api/admin/drive/files/:fileId/download', adminAuth",
  ]) {
    assert.ok(server.includes(route), `missing protected route: ${route}`);
  }
});

test('Google Drive access is read-only and limited to the configured folder', () => {
  assert.match(drive, /drive\.readonly/);
  assert.match(drive, /configuredFolderId\(\)/);
  assert.match(drive, /metadata\.parents\.includes\(configuredFolderId\(\)\)/);
  assert.doesNotMatch(drive, /files\/[^`]*delete/);
  assert.doesNotMatch(drive, /upload\/drive/);
});

test('Google Drive folder access is verified before an empty list is returned', () => {
  assert.match(drive, /files\/\$\{encodeURIComponent\(folderId\)\}/);
  assert.match(drive, /if \(!folderResponse\.ok\) throw await driveError/);
  assert.match(drive, /application\/vnd\.google-apps\.folder/);
});

test('Google Drive credentials stay on the server', () => {
  assert.match(drive, /firebase-service-account\.json/);
  assert.doesNotMatch(server, /private_key/);
  assert.doesNotMatch(server, /client_secret/);
});
