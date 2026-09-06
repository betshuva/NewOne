'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const server = fs.readFileSync(path.join(__dirname, '..', 'server', 'index.js'), 'utf8');
const client = fs.readFileSync(path.join(__dirname, '..', 'flutter_app', 'lib', 'main.dart'), 'utf8');
const screenshot = fs.readFileSync(path.join(__dirname, '..', 'flutter_app', 'lib', 'app_screenshot.dart'), 'utf8');

test('Israel and Safe Information use separate immutable system identities', () => {
  assert.match(server, /SYSTEM_USER_ID = '00000000-0000-4000-8000-000000000002'/);
  assert.match(server, /SAFE_INFORMATION_USER_ID = '00000000-0000-4000-8000-000000000003'/);
  assert.match(server, /SYSTEM_USER_NAME = 'ישראל מדריך בתשובה'/);
  assert.match(server, /SYSTEM_USER_PROFILE_PIC =[\s\S]*?'\/betshuva-app\/assets\/assets\/guide\/israel-profile-20260907\.png'/);
  assert.match(client, /'profile_pic_url':\s*'\/betshuva-app\/assets\/assets\/guide\/israel-profile-20260907\.png'/);
  assert.match(server, /SAFE_INFORMATION_USER_NAME = 'מידע בטוח · AI'/);
  assert.match(client, /const kSafeInformationAiId = '00000000-0000-4000-8000-000000000003'/);
});

test('each assistant has its own history and answer generator', () => {
  assert.match(server, /recipient_id=\$2[\s\S]*?SAFE_INFORMATION_USER_ID/);
  assert.match(server, /assistantId === SAFE_INFORMATION_USER_ID[\s\S]*?generateSafeInformationSystemAnswer/);
  assert.match(server, /generateSystemAnswer\(pool, userId, question\)/);
  assert.match(server, /createSystemExchange\([\s\S]*?assistantId = SYSTEM_USER_ID/);
});

test('existing accounts receive both assistants while screenshots remain with Israel', () => {
  assert.match(server, /INSERT INTO user_contacts\(owner_id,contact_id\)[\s\S]*?SAFE_INFORMATION_USER_ID/);
  assert.match(server, /SAFE_INFORMATION_WELCOME_MESSAGE/);
  assert.match(screenshot, /צילום המסך נשלח לישראל/);
  assert.match(client, /AppScreenshotDestination\.user\(kSystemGuideId\)/);
  assert.match(client, /widget\.recipient\['id'\] == kSafeInformationAiId/);
});
