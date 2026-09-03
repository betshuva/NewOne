'use strict';

const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');

const source = fs.readFileSync(
  path.join(__dirname, '..', 'flutter_app', 'lib', 'main.dart'), 'utf8');

test('issue image attachments open in the in-app gallery', () => {
  const start = source.indexOf('class OpenIssuesScreen');
  const end = source.indexOf('class SettingsScreen', start);
  const issues = source.slice(start, end);

  assert.match(issues, /Future<void> _openIssueImage/);
  assert.match(issues, /ImagePreviewScreen\([\s\S]*?urls: urls,[\s\S]*?initialIndex: initialIndex/);
  assert.match(issues,
    /isImage\s*\? \(\) => _openIssueImage\(imageAttachments,[\s\S]*?imageAttachments\.indexOf\(attachment\)\)/);
});

test('non-image issue attachments retain their normal file action', () => {
  const start = source.indexOf('class OpenIssuesScreen');
  const end = source.indexOf('class SettingsScreen', start);
  const issues = source.slice(start, end);
  assert.match(issues,
    /: \(\) => launchUrl\(Uri\.parse\(_absoluteMediaUrl\(url\)\),[\s\S]*?LaunchMode\.externalApplication/);
});
