const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const source = fs.readFileSync(
  path.join(__dirname, '..', 'server', 'index.js'),
  'utf8',
);

test('insult variants are included in harmful chat moderation', () => {
  for (const term of ['טמבל', 'טמבלים', 'טמבלית']) {
    assert.match(source, new RegExp(`'${term}'`));
  }
});

test('reports to Israel remain available and redact the insult in storage and replies', () => {
  assert.match(source, /\[SYSTEM_USER_ID, SAFE_INFORMATION_USER_ID\]\.includes\(toUserId\)[\s\S]*?moderateChatText\(text\)\.blocked/);
  assert.match(source, /const safeQuestion = redactHarmfulLanguageForDisplay\(question\)/);
  assert.match(source, /const answer = redactHarmfulLanguageForDisplay\(/);
  assert.match(source, /const description = redactHarmfulLanguageForDisplay\(/);
});
