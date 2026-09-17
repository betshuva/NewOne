'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function servingFixture() {
  const source = fs.readFileSync(require.resolve('../server/index.js'), 'utf8');
  const start = source.indexOf('const serveReleasedDriveMedia = async');
  const end = source.indexOf('// Baseline protection for all API routes.', start);
  assert.ok(start > 0 && end > start);
  const mounts = new Map();
  const accesses = [];
  const queries = [];
  const db = { async query(sql, values) {
    queries.push(values[0]);
    if (sql.includes('deleted_media_sources')) {
      return { rows: values[0] === 'owner/deleted.png' ? [{ exists: 1 }] : [] };
    }
    if (sql.includes('SELECT moderation_status')) {
      return { rows: [{ moderation_status: 'approved', file_type: 'image' }] };
    }
    assert.fail('No Drive fallback should run for these local fixtures');
  } };
  vm.runInNewContext(source.slice(start, end), {
    app: { use(mount, callback) { if (typeof mount === 'string') mounts.set(mount, callback); } },
    express: { static() { return () => {}; } },
    require, __dirname: path.dirname(require.resolve('../server/index.js')),
    path, UPLOAD_ROOT: '/isolated-uploads', UPLOAD_PUBLIC_BASE: '/betshuva-app/uploads',
    getPool: async () => db,
    fs: { async access(file) { accesses.push(file); } },
    console: { error() { assert.fail('The public-media guard should not throw'); } },
  });
  const request = async (mount, file, method = 'GET') => {
    const response = { status: 200, headers: {}, ended: false, next: false };
    await mounts.get(mount)({ method, path: file, headers: {} }, {
      status(code) { response.status = code; return this; },
      set(key, value) { response.headers[key] = value; return this; },
      end() { response.ended = true; return this; },
      json() { assert.fail('Deleted media must return an empty 404'); },
    }, () => { response.next = true; });
    return response;
  };
  return { request, queries, accesses };
}

test('deleted sources never reach static delivery while cleanup bytes still exist', async () => {
  const fixture = servingFixture();
  for (const mount of ['/betshuva-app/uploads', '/uploads']) {
    for (const method of ['GET', 'HEAD']) {
      for (const file of ['/owner/deleted.png', '/owner/%64eleted.png', '/other/../owner/deleted.png']) {
        const response = await fixture.request(mount, file, method);
        assert.equal(response.status, 404);
        assert.equal(response.headers['Cache-Control'], 'private, no-store');
        assert.equal(response.ended, true);
        assert.equal(response.next, false);
      }
    }
  }
  assert.equal(fixture.accesses.length, 0);
  assert.ok(fixture.queries.every(value => value === 'owner/deleted.png'));
});

test('ready recipient copies retain their own static delivery path', async () => {
  const fixture = servingFixture();
  for (const mount of ['/betshuva-app/uploads', '/uploads']) {
    const response = await fixture.request(mount, '/received/recipient/own-copy.png');
    assert.equal(response.status, 200);
    assert.equal(response.next, true);
    assert.equal(response.ended, false);
  }
  assert.deepEqual(fixture.accesses, [
    '/isolated-uploads/received/recipient/own-copy.png',
    '/isolated-uploads/received/recipient/own-copy.png',
  ]);
});
