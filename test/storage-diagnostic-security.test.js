const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const server = fs.readFileSync(
  path.join(__dirname, '..', 'server', 'index.js'),
  'utf8',
);

test('storage diagnostic requires an authenticated administrator', () => {
  assert.match(
    server,
    /app\.get\('\/api\/test-storage', adminAuth, async \(req, res\) =>/,
  );
});
