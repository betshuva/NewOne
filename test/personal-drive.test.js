'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const personalDrive = require('../server/personal-drive');

test('personal Drive refresh tokens are encrypted and bound to their owner', () => {
  const previous = process.env.BACKUP_TOKEN_ENCRYPTION_KEY;
  process.env.BACKUP_TOKEN_ENCRYPTION_KEY = 'test-only-master-key-that-is-longer-than-32-bytes';
  try {
    const encrypted = personalDrive.encryptRefreshToken('refresh-token-secret', 'user-a');
    assert.equal(encrypted.includes('refresh-token-secret'), false);
    assert.equal(personalDrive.decryptRefreshToken(encrypted, 'user-a'), 'refresh-token-secret');
    assert.throws(() => personalDrive.decryptRefreshToken(encrypted, 'user-b'));
  } finally {
    if (previous === undefined) delete process.env.BACKUP_TOKEN_ENCRYPTION_KEY;
    else process.env.BACKUP_TOKEN_ENCRYPTION_KEY = previous;
  }
});

test('personal Drive uses only the hidden appDataFolder scope and offline access', () => {
  const previousId = process.env.GOOGLE_DRIVE_OAUTH_CLIENT_ID;
  const previousSecret = process.env.GOOGLE_DRIVE_OAUTH_CLIENT_SECRET;
  process.env.GOOGLE_DRIVE_OAUTH_CLIENT_ID = 'client-id.apps.googleusercontent.com';
  process.env.GOOGLE_DRIVE_OAUTH_CLIENT_SECRET = 'client-secret';
  try {
    const url = new URL(personalDrive.authorizationUrl('csrf-state'));
    assert.equal(url.searchParams.get('scope'), personalDrive.DRIVE_APPDATA_SCOPE);
    assert.equal(url.searchParams.get('access_type'), 'offline');
    assert.equal(url.searchParams.get('state'), 'csrf-state');
    assert.equal(url.searchParams.get('prompt'), 'consent');
  } finally {
    if (previousId === undefined) delete process.env.GOOGLE_DRIVE_OAUTH_CLIENT_ID;
    else process.env.GOOGLE_DRIVE_OAUTH_CLIENT_ID = previousId;
    if (previousSecret === undefined) delete process.env.GOOGLE_DRIVE_OAUTH_CLIENT_SECRET;
    else process.env.GOOGLE_DRIVE_OAUTH_CLIENT_SECRET = previousSecret;
  }
});

test('OAuth callback never accepts a user id directly from its query string', () => {
  const source = fs.readFileSync(path.join(__dirname, '..', 'server', 'index.js'), 'utf8');
  const callback = source.slice(source.indexOf("app.get('/api/backup/google/callback'"),
    source.indexOf("app.get('/api/backup/google/status'"));
  assert.match(callback, /purpose !== 'personal_drive_oauth'/);
  assert.match(callback, /jwt\.verify\(String\(req\.query\.state\), JWT_SECRET\)/);
  assert.doesNotMatch(callback, /req\.query\.userId/);
});

test('Google-login backup offer carries consent through OAuth and enables backup only then', () => {
  const source = fs.readFileSync(path.join(__dirname, '..', 'server', 'index.js'), 'utf8');
  const flow = source.slice(source.indexOf("app.get('/api/backup/google/connect'"),
    source.indexOf("app.get('/api/backup/google/status'"));
  assert.match(flow, /autoEnable: req\.query\.autoEnable === 'true'/);
  assert.match(flow, /state\.autoEnable === true/);
  assert.match(flow, /enabled=TRUE/);
  assert.match(flow, /wrapVaultKey\(createVaultKey\(\), state\.userId\)/);
});

test('Google Drive offer skips repeat consent when backup is already enabled', () => {
  const source = fs.readFileSync(
    path.join(__dirname, '..', 'flutter_app', 'lib', 'main.dart'), 'utf8');
  const screen = source.slice(
    source.indexOf('class GoogleDriveBackupOfferScreen'),
    source.indexOf('class GooglePhoneSetupScreen'));
  assert.match(screen, /Uri\.parse\('\$kApi\/backup'\)/);
  assert.match(screen, /settings\['enabled'\] == true/);
  assert.match(screen, /if \(connected && enabled\)/);
  assert.match(screen, /await _continue\(\)/);
  assert.match(screen, /_statusLoading/);
});

test('manual backup accepts only approved owned files and never deletes the local copy', () => {
  const source = fs.readFileSync(path.join(__dirname, '..', 'server', 'index.js'), 'utf8');
  const route = source.slice(source.indexOf("app.post('/api/backup/next'"),
    source.indexOf("app.delete('/api/backup/google'"));
  assert.match(route, /sf\.user_id=\$1 AND sf\.moderation_status='approved'/);
  assert.match(route, /encryptBackupBuffer\(plain, key, associatedData\)/);
  assert.match(route, /\.manifest\.json/);
  assert.match(route, /automaticDeletion: false/);
  assert.match(route, /replaceLatest/);
  assert.match(route, /old backup cleanup/);
  assert.doesNotMatch(route, /fs\.(unlink|rm)\(/);
});

test('restore verification decrypts in memory and never overwrites local media', () => {
  const source = fs.readFileSync(path.join(__dirname, '..', 'server', 'index.js'), 'utf8');
  const route = source.slice(source.indexOf("app.post('/api/backup/verify-restore'"),
    source.indexOf("app.delete('/api/backup/google'"));
  assert.match(route, /decryptBackupBuffer/);
  assert.match(route, /unwrapVaultKey\(row\.encrypted_data_key, req\.user\.id\)/);
  assert.match(route, /keySource === 'server_vault'/);
  assert.match(route, /restoredHash !== row\.plaintext_sha256/);
  assert.match(route, /matchesLocalCopy = local\.equals\(restored\)/);
  assert.match(route, /wroteToDisk: false/);
  assert.doesNotMatch(route, /fs\.writeFile\(/);
});

test('release readiness reports automatic deletion with backup', () => {
  const source = fs.readFileSync(path.join(__dirname, '..', 'server', 'index.js'), 'utf8');
  const route = source.slice(source.indexOf("app.get('/api/backup'"),
    source.indexOf("app.patch('/api/backup/settings'"));
  assert.match(route, /restore_verified_at IS NOT NULL/);
  assert.match(route, /active_reference/);
  assert.match(route, /automatic_deletion_enabled: settings\.rows\[0\]\?\.enabled === true/);
  assert.doesNotMatch(route, /fs\.(unlink|rm)\(/);
});

test('safe release is immediate after verification and protects active references', () => {
  const source = fs.readFileSync(path.join(__dirname, '..', 'server', 'index.js'), 'utf8');
  const queue = source.slice(source.indexOf('async function runSafeReleaseQueue'),
    source.indexOf('const PORT'));
  assert.match(queue, /s\.enabled=TRUE/);
  assert.match(queue, /restore_verified_at IS NOT NULL/);
  assert.doesNotMatch(queue, /INTERVAL '48 hours'/);
  assert.match(queue, /deleted_for_everyone=FALSE/);
  assert.match(queue, /profile_pic_url=sf\.public_url/);
  assert.match(queue, /listing_images li WHERE li\.url=sf\.public_url/);
});

test('released media uses an encrypted adaptive LRU Drive cache', () => {
  const source = fs.readFileSync(path.join(__dirname, '..', 'server', 'index.js'), 'utf8');
  const route = source.slice(source.indexOf('const serveReleasedDriveMedia'),
    source.indexOf("app.use(express.static"));
  assert.match(source, /DRIVE_MEDIA_CACHE_MAX_BYTES[\s\S]*?20 \* 1024 \* 1024 \* 1024/);
  assert.match(source, /accessCount >= 10[\s\S]*?72 \* 60 \* 60/);
  assert.match(source, /accessCount >= 4[\s\S]*?48 \* 60 \* 60/);
  assert.match(source, /accessCount >= 2[\s\S]*?24 \* 60 \* 60/);
  assert.match(source, /return 6 \* 60 \* 60/);
  assert.match(source, /retained\.sort\(\(a, b\) => a\.lastAccessAt - b\.lastAccessAt\)/);
  assert.match(route, /\.enc`/);
  assert.match(route, /accessCount \+= 1/);
  assert.match(route, /downloadAppDataFile/);
  assert.match(route, /decryptBackupBuffer/);
  assert.match(route, /plainHash !== row\.content_sha256/);
  assert.match(route, /Content-Range/);
  assert.doesNotMatch(route, /writeFile\([^,]+, plain/);
  assert.match(route, /app\.use\(UPLOAD_PUBLIC_BASE, serveReleasedDriveMedia\)/);
  assert.match(route, /app\.use\('\/uploads', serveReleasedDriveMedia\)/);
});

test('automatic restore queue verifies cloud bytes before release eligibility', () => {
  const source = fs.readFileSync(path.join(__dirname, '..', 'server', 'index.js'), 'utf8');
  const queue = source.slice(source.indexOf('async function runAutomaticRestoreQueue'),
    source.indexOf('async function runSafeReleaseQueue'));
  assert.match(queue, /downloadAppDataFile/);
  assert.match(queue, /decryptBackupBuffer/);
  assert.match(queue, /restoredHash !== row\.plaintext_sha256/);
  assert.match(queue, /restore_verified_at=now\(\)/);
  assert.doesNotMatch(queue, /fs\.writeFile/);
});

test('opting out cancels every pending release still in its grace period', () => {
  const source = fs.readFileSync(path.join(__dirname, '..', 'server', 'index.js'), 'utf8');
  const route = source.slice(source.indexOf("app.patch('/api/backup/settings'"),
    source.indexOf("app.post('/api/backup/automatic'"));
  assert.match(route, /storageMode === 'backup_only'/);
  assert.match(route, /SET release_scheduled_at=NULL/);
  assert.match(route, /released_at IS NULL/);
});
