'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vault = require('../server/backup-vault-key');

test('server-managed vault keys are random, encrypted and owner-bound', () => {
  const previous = process.env.BACKUP_TOKEN_ENCRYPTION_KEY;
  process.env.BACKUP_TOKEN_ENCRYPTION_KEY = 'test-master-key-with-at-least-thirty-two-characters';
  try {
    const key = vault.createVaultKey();
    const wrapped = vault.wrapVaultKey(key, 'user-a');
    assert.equal(wrapped.includes(key.toString('base64')), false);
    assert.deepEqual(vault.unwrapVaultKey(wrapped, 'user-a'), key);
    assert.throws(() => vault.unwrapVaultKey(wrapped, 'user-b'));
    assert.notDeepEqual(vault.createVaultKey(), key);
  } finally {
    if (previous === undefined) delete process.env.BACKUP_TOKEN_ENCRYPTION_KEY;
    else process.env.BACKUP_TOKEN_ENCRYPTION_KEY = previous;
  }
});

test('automatic backup opt-in never returns or logs the wrapped key', () => {
  const source = fs.readFileSync(path.join(__dirname, '..', 'server', 'index.js'), 'utf8');
  const route = source.slice(source.indexOf("app.post('/api/backup/automatic'"),
    source.indexOf("app.get('/api/backup/google/connect'"));
  assert.match(route, /encrypted_data_key IS NOT NULL AS server_key_ready/);
  assert.match(route, /wrapVaultKey\(createVaultKey\(\), req\.user\.id\)/);
  assert.doesNotMatch(route, /res\.json\([^)]*encrypted_data_key[^)]*\)/s);
});

test('automatic queue uses four safely claimed workers and never deletes local media', () => {
  const source = fs.readFileSync(path.join(__dirname, '..', 'server', 'index.js'), 'utf8');
  const queue = source.slice(source.indexOf('const AUTOMATIC_BACKUP_CONCURRENCY'),
    source.indexOf('async function runSafeReleaseQueue'));
  const startup = source.slice(source.indexOf('async function startServer'));
  assert.match(queue, /AUTOMATIC_BACKUP_CONCURRENCY = 4/);
  assert.match(startup, /fork\(__filename/);
  assert.match(startup, /BACKUP_WORKER_ONLY: '1'/);
  assert.match(startup, /BACKUP_WORKER_INDEX/);
  assert.match(queue, /pg_try_advisory_lock/);
  assert.match(queue, /FOR UPDATE OF sf SKIP LOCKED/);
  assert.match(queue, /MAX\(done\.verified_at\)[\s\S]*?NULLS FIRST[\s\S]*?sf\.created_at ASC[\s\S]*?LIMIT 1/);
  assert.match(queue, /mbi\.attempt_count<5/);
  assert.match(queue, /keySource: 'server_vault'/);
  assert.match(queue, /sf\.moderation_status='approved'/);
  assert.doesNotMatch(queue, /fs\.(unlink|rm)\(/);
});
