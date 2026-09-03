'use strict';

const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');

const server = fs.readFileSync(
  path.join(__dirname, '..', 'server', 'index.js'), 'utf8');
const client = fs.readFileSync(
  path.join(__dirname, '..', 'flutter_app', 'lib', 'main.dart'), 'utf8');

test('resolved and closed issue notices link directly to the issue', () => {
  const start = server.indexOf("app.patch('/api/admin/support-issues/:id'");
  const end = server.indexOf('// ── Admin: activity log', start);
  const route = server.slice(start, end);

  assert.match(route, /\['resolved', 'closed'\]\.includes\(status\)/);
  assert.match(route, /betshuva:\/\/app\/my-issues\/\$\{issue\.id\}/);
  assert.match(route, /לצפייה בפרטי הפנייה ובמה שבוצע/);
});

test('issue links render as an in-app button and open the exact issue', () => {
  assert.match(client, /initialIssueId: issueId/);
  assert.match(client, /issueId == null \? 'פתח את הפניות שלי' : 'פתח את הפנייה'/);
  assert.match(client, /issueId: guideIssueId/);
});
