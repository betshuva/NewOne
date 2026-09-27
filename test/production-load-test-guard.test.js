'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

const scripts = [
  'full-production-load-test.js',
  'six-hour-production-load-test.js',
  'safe-public-load-test.js',
];

for (const script of scripts) {
  for (const context of ['child-v8', '']) {
    test(`${script} rejects test discovery before effects (context ${JSON.stringify(context)})`, () => {
      const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'production-load-guard-'));
      try {
        const preload = path.join(directory, 'reject-effects.cjs');
        // Keep this regression harmless even if a production guard is removed.
        fs.writeFileSync(preload, `
const Module = require('node:module');
Module.prototype.require = function () {
  throw new Error('DEPENDENCY_LOADED_BEFORE_GUARD');
};
globalThis.fetch = function () {
  throw new Error('NETWORK_STARTED_BEFORE_GUARD');
};
`);
        const result = spawnSync(process.execPath, [
          '--require', preload, path.join(__dirname, '..', 'scripts', script),
        ], {
          cwd: directory,
          env: { NODE_TEST_CONTEXT: context },
          encoding: 'utf8',
          timeout: 5000,
        });

        assert.equal(result.error, undefined);
        assert.equal(result.signal, null);
        assert.equal(result.status, 1);
        assert.equal(result.stdout, '');
        assert.match(result.stderr, /Production load scripts must be run explicitly, not through test discovery\./);
        assert.doesNotMatch(result.stderr, /DEPENDENCY_LOADED_BEFORE_GUARD|NETWORK_STARTED_BEFORE_GUARD|MODULE_NOT_FOUND|"event"\s*:\s*"start"/);
        assert.deepEqual(fs.readdirSync(directory), ['reject-effects.cjs']);
      } finally {
        fs.rmSync(directory, { recursive: true, force: true });
      }
    });
  }
}
