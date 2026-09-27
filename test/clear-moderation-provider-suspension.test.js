'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const { parseArguments, executeClearCommand } = require('../scripts/clear-moderation-provider-suspension');

function fixture(overrides = {}) {
  const options = { provider: 'openai', actor: randomUUID(), reason: 'credits_restored', confirmed: true };
  const state = { suspended: true, released: false, queries: [], audit: [], committed: false, pendingClear: false };
  const db = {
    async query(sql, values) {
      state.queries.push({ sql, values });
      if (sql.includes('FROM users')) return overrides.actorResult ?? { rowCount: 1, rows: [{ id: options.actor, permission: 'edit' }] };
      if (sql.includes('FROM moderation_provider_suspensions'))
        return { rowCount: state.suspended ? 1 : 0, rows: state.suspended ? [{ reason: 'credit_balance_exhausted' }] : [] };
      if (sql === 'COMMIT') { state.committed = true; if (state.pendingClear) state.suspended = false; }
      if (sql === 'ROLLBACK') state.pendingClear = false;
      return { rowCount: 0, rows: [] };
    },
    release() { state.released = true; },
  };
  const pool = { connect: async () => db };
  const audit = {
    async beginOperation(client, data) {
      assert.equal(client, db);
      state.audit.push(data);
      return { id: randomUUID(), root_event_id: '123' };
    },
    async recordAuditEvent(client, data) {
      assert.equal(client, db);
      state.audit.push(data);
      if (overrides.auditFailure) throw new Error('audit unavailable');
    },
  };
  const clear = async (client, data) => {
    assert.equal(client, db);
    assert.equal(data.confirmed, true);
    assert.equal(data.actorId, options.actor);
    assert.match(data.credentialHash, /^[a-f0-9]{64}$/);
    state.pendingClear = true;
    return { cleared: true };
  };
  const run = extra => executeClearCommand({ pool, options, apiKey: 'synthetic-test-credential', audit, clear, ...extra });
  return { options, state, run };
}

test('CLI defaults to dry run and accepts only explicit bounded administrative arguments', () => {
  const actor = randomUUID();
  const args = ['--provider', 'openai', '--actor', actor, '--reason', 'credits_restored'];
  assert.deepEqual(parseArguments(args), { provider: 'openai', actor, reason: 'credits_restored', confirmed: false });
  assert.equal(parseArguments([...args, '--confirm']).confirmed, true);
  assert.deepEqual(parseArguments(['--help']), { help: true });
  for (const invalid of [[], args.slice(0, -2), [...args, '--api-key', 'secret'], [...args, '--confirm', '--confirm'],
    [...args, '__proto__', 'ignored'], [...args, 'constructor', 'ignored'],
    ['--provider', 'gemini', '--actor', actor, '--reason', 'credits_restored'],
    ['--provider', 'openai', '--actor', 'invalid', '--reason', 'credits_restored'],
    ['--provider', 'openai', '--actor', actor, '--reason', 'free text']])
    assert.throws(() => parseArguments(invalid), { code: 'INVALID_ARGUMENTS' });
});

test('dry run opens a read-only transaction and reports only masked credential state', async () => {
  const f = fixture();
  f.options.confirmed = false;
  const result = await f.run();
  assert.equal(result.mode, 'dry_run');
  assert.equal(result.status, 'suspended');
  assert.match(result.credential, /^sha256:[a-f0-9]{12}\.\.\.$/);
  assert.equal(JSON.stringify(result).includes('synthetic-test-credential'), false);
  assert.equal(f.state.queries[0].sql, 'BEGIN READ ONLY');
  assert.equal(f.state.queries.at(-1).sql, 'ROLLBACK');
  assert.equal(f.state.audit.length, 0);
  assert.equal(f.state.suspended, true);
  assert.equal(f.state.pendingClear, false);
  assert.equal(f.state.released, true);
});

test('a nonexistent actor or view-only administrator cannot clear a suspension', async () => {
  for (const actorResult of [{ rowCount: 0, rows: [] }, { rowCount: 1, rows: [{ permission: 'view' }] }]) {
    const f = fixture({ actorResult });
    await assert.rejects(f.run(), { code: 'ADMIN_EDIT_REQUIRED' });
    assert.equal(f.state.suspended, true);
    assert.equal(f.state.committed, false);
    assert.equal(f.state.audit.length, 0);
    assert.equal(f.state.released, true);
  }
});

test('confirmed clear locks authority and suspension and commits clearance with its audit records', async () => {
  const f = fixture();
  const result = await f.run();
  assert.equal(result.status, 'cleared');
  assert.equal(f.state.suspended, false);
  assert.equal(f.state.committed, true);
  assert.equal(f.state.queries[0].sql, 'BEGIN');
  assert.ok(f.state.queries.some(query => query.sql.includes('FOR SHARE OF u,ap')));
  assert.ok(f.state.queries.some(query => query.sql.includes('FOR UPDATE')));
  assert.equal(f.state.audit.length, 2);
  assert.ok(f.state.audit.every(event => event.reasonCode === 'credits_restored' && event.executorId === f.options.actor));
  assert.equal(f.state.audit[1].operationId, result.auditOperationId);
  assert.equal(f.state.audit[1].parentEventId, '123');
  assert.equal(f.state.audit[1].kind, 'provider_suspension_cleared');
  assert.equal(f.state.audit[1].operationStatus, 'completed');
  assert.equal(f.state.queries.at(-1).sql, 'COMMIT');
  assert.equal(f.state.queries.some(query => /video_scan|pending_scans/.test(query.sql)), false);
});

test('audit failure rolls back clearance and leaves the provider suspended', async () => {
  const f = fixture({ auditFailure: true });
  await assert.rejects(f.run(), /audit unavailable/);
  assert.equal(f.state.suspended, true);
  assert.equal(f.state.pendingClear, false);
  assert.equal(f.state.committed, false);
  assert.equal(f.state.queries.at(-1).sql, 'ROLLBACK');
  assert.equal(f.state.released, true);
});

test('confirmed clearance of an unsuspended credential performs no writes', async () => {
  const f = fixture();
  f.state.suspended = false;
  const result = await f.run();
  assert.equal(result.status, 'not_suspended');
  assert.equal(f.state.audit.length, 0);
  assert.equal(f.state.pendingClear, false);
  assert.equal(f.state.committed, false);
  assert.equal(f.state.queries.at(-1).sql, 'ROLLBACK');
});

test('missing configuration fails before opening a database connection', async () => {
  let connected = false;
  const f = fixture();
  await assert.rejects(f.run({ pool: { connect: () => { connected = true; } }, apiKey: '' }), { code: 'PROVIDER_KEY_MISSING' });
  assert.equal(connected, false);
});
