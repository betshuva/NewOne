const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const source = fs.readFileSync(path.join(__dirname, '..', 'server', 'index.js'), 'utf8');

test('database objects are initialized in dependency order', () => {
  const users = source.indexOf('CREATE TABLE IF NOT EXISTS users');
  const groups = source.indexOf('CREATE TABLE IF NOT EXISTS groups');
  const members = source.indexOf('CREATE TABLE IF NOT EXISTS group_members');
  const alterMembers = source.indexOf('ALTER TABLE group_members');

  assert.ok(users >= 0, 'users table migration is missing');
  assert.ok(groups > users, 'groups must be created after users');
  assert.ok(members > groups, 'group_members must be created after groups');
  assert.ok(alterMembers > members, 'group_members must exist before it is altered');
});

test('server startup waits for all database initialization', () => {
  const migrate = source.indexOf('await migrateDatabase()');
  const pending = source.indexOf('await initPendingTable()');
  const listen = source.indexOf('httpServer.listen');

  assert.ok(migrate >= 0 && pending > migrate && listen > pending);
});

test('JWT authentication has no built-in default secret', () => {
  assert.doesNotMatch(source, /JWT_SECRET\s*\|\|\s*['"][^'"]+['"]/);
  assert.match(source, /if \(!JWT_SECRET\)/);
});

test('SMTP verifies the remote TLS certificate', () => {
  assert.doesNotMatch(source, /rejectUnauthorized\s*:\s*false/);
  assert.match(source, /rejectUnauthorized\s*:\s*true/);
});

test('server publishes the child safety standards page', () => {
  assert.match(source, /app\.get\('\/child-safety'/);
  assert.match(source, /child-safety\.html/);
});
