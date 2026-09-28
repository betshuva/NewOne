'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

test('all former manual rescan routes reject old clients without scanning', () => {
  const source = fs.readFileSync(require.resolve('../server/index'), 'utf8');
  const start = source.indexOf('function manualRescanRemoved(');
  const end = source.indexOf("app.post('/api/media/reclassify'", start);
  assert.ok(start >= 0 && end > start);
  const registered = [];
  const context = vm.createContext({
    auth() {}, adminAuth() {}, messageRateLimit() {},
    app: { post: (...args) => registered.push(args) },
    scanImage() { assert.fail('manual scan must never run'); },
    getPool() { assert.fail('retired handler must not access media'); },
  });
  vm.runInContext(source.slice(start, end), context);
  for (const route of [
    '/api/media/reclassify', '/api/media-library/:id/reclassify',
    '/api/admin/classification-stats/:id/rescan', '/api/admin/vision/rescan',
  ]) {
    const line = source.split('\n').find(line => line.startsWith(`app.post('${route}'`));
    assert.ok(line?.endsWith('manualRescanRemoved);'), route);
    vm.runInContext(line, context);
  }
  for (const [path, ...handlers] of registered) {
    assert.equal(handlers[0], path.includes('/admin/') ? context.adminAuth : context.auth);
    let status, body;
    handlers.at(-1)({}, { status(code) { status = code; return this; },
      json(value) { body = value; } });
    assert.equal(status, 410);
    assert.equal(body.code, 'MANUAL_RESCAN_REMOVED');
  }
  assert.doesNotMatch(source, /persistFullImageRescan|visionRescanRunning/);
});
