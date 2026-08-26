const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const root = path.join(__dirname, '..');
const index = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
const script = fs.readFileSync(path.join(root, 'scripts', 'build-web-release.sh'), 'utf8');
const workflow = fs.readFileSync(path.join(root, '.github', 'workflows', 'build-web.yml'), 'utf8');

test('deployed Flutter web index uses the application subpath', () => {
  assert.match(index, /<base href="\/betshuva-app\/">/);
});

test('every automated web build uses and validates the application subpath', () => {
  assert.match(script, /--base-href "\$web_base"/);
  assert.match(script, /incorrect base href/);
  assert.match(script, /cp "\$build_dir\/index\.html"/);
  assert.match(workflow, /scripts\/build-web-release\.sh/);
  assert.match(workflow, /git add -A index\.html/);
  assert.doesNotMatch(workflow, /flutter build web/);
});
