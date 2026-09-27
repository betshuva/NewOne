'use strict';

const path = require('node:path');
const { credentialHash } = require('../server/moderation-provider-guard');
const { clearProviderSuspension } = require('../server/video-scan-budget');
const { beginOperation, recordAuditEvent } = require('../server/system-audit');

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const USAGE = 'Usage: node scripts/clear-moderation-provider-suspension.js --provider openai --actor <userUUID> --reason <reason_code> [--confirm]';
const ERRORS = {
  INVALID_ARGUMENTS: USAGE,
  PROVIDER_KEY_MISSING: 'The configured OpenAI credential is missing.',
  DATABASE_MISSING: 'The server database connection is not configured.',
  ADMIN_EDIT_REQUIRED: 'The actor must be an existing user with admin edit permission.',
  CLEARANCE_FAILED: 'The locked provider suspension could not be cleared.',
};

function fail(code) {
  return Object.assign(new Error(ERRORS[code]), { code });
}

function validateOptions(options) {
  if (options.provider !== 'openai' || !UUID.test(options.actor || '') ||
      !/^[a-z][a-z0-9_]{2,79}$/.test(options.reason || '') ||
      typeof options.confirmed !== 'boolean') throw fail('INVALID_ARGUMENTS');
}

function parseArguments(argv) {
  if (argv.length === 1 && (argv[0] === '--help' || argv[0] === '-h')) return { help: true };
  const options = { confirmed: false };
  const seen = new Set();
  for (let index = 0; index < argv.length; index++) {
    const flag = argv[index];
    if (seen.has(flag)) throw fail('INVALID_ARGUMENTS');
    seen.add(flag);
    if (flag === '--confirm') { options.confirmed = true; continue; }
    const key = { '--provider': 'provider', '--actor': 'actor', '--reason': 'reason' }[flag];
    const value = argv[++index];
    if (typeof key !== 'string' || !value || value.startsWith('--')) throw fail('INVALID_ARGUMENTS');
    options[key] = value;
  }
  validateOptions(options);
  options.actor = options.actor.toLowerCase();
  return options;
}

async function executeClearCommand({ pool, options, apiKey,
  audit = { beginOperation, recordAuditEvent }, clear = clearProviderSuspension }) {
  validateOptions(options);
  if (typeof apiKey !== 'string' || !apiKey.trim()) throw fail('PROVIDER_KEY_MISSING');
  const hash = credentialHash(apiKey);
  const output = { provider: options.provider, credential: `sha256:${hash.slice(0, 12)}...`,
    mode: options.confirmed ? 'confirmed' : 'dry_run' };
  const db = await pool.connect();
  try {
    await db.query(options.confirmed ? 'BEGIN' : 'BEGIN READ ONLY');
    const actor = await db.query(`SELECT u.id,ap.permission FROM users u
      JOIN admin_permissions ap ON ap.user_id=u.id
      WHERE u.id=$1 AND ap.permission='edit'${options.confirmed ? ' FOR SHARE OF u,ap' : ''}`,
    [options.actor]);
    if (actor.rowCount !== 1 || actor.rows[0].permission !== 'edit') throw fail('ADMIN_EDIT_REQUIRED');
    const current = await db.query(`SELECT reason,suspended_at FROM moderation_provider_suspensions
      WHERE provider=$1 AND credential_hash=$2 AND cleared_at IS NULL${options.confirmed ? ' FOR UPDATE' : ''}`,
    [options.provider, hash]);
    if (!options.confirmed || !current.rowCount) {
      await db.query('ROLLBACK');
      return { ...output, status: current.rowCount ? 'suspended' : 'not_suspended' };
    }

    const operation = await audit.beginOperation(db, {
      action: 'admin_provider_suspension_clear', category: 'administration',
      initiatorId: options.actor, executorType: 'admin', executorId: options.actor,
      source: 'admin_cli', status: 'running', reasonCode: options.reason,
      details: { provider: options.provider, operation: 'suspension_clear',
        code: `credential_${hash.slice(0, 12)}` },
    });
    const result = await clear(db, { provider: options.provider, credentialHash: hash,
      actorId: options.actor, confirmed: true });
    if (!result.cleared) throw fail('CLEARANCE_FAILED');
    await audit.recordAuditEvent(db, {
      operationId: operation.id, parentEventId: operation.root_event_id,
      kind: 'provider_suspension_cleared', executorType: 'admin', executorId: options.actor,
      source: 'admin_cli', status: 'completed', operationStatus: 'completed', reasonCode: options.reason,
      details: { provider: options.provider, operation: 'suspension_clear',
        code: `credential_${hash.slice(0, 12)}`, affectedCount: 1 },
    });
    await db.query('COMMIT');
    return { ...output, status: 'cleared', auditOperationId: operation.id };
  } catch (error) {
    try { await db.query('ROLLBACK'); } catch (_) { /* Keep the original failure. */ }
    throw error;
  } finally { db.release(); }
}

async function main(argv = process.argv.slice(2)) {
  const options = parseArguments(argv);
  if (options.help) {
    console.log(`${USAGE}\nDry run is the default. --confirm clears only the configured credential's suspension.\nExample reason code: credits_restored. Video budgets and stopped scans are unchanged.`);
    return;
  }
  const dotenv = require('dotenv');
  dotenv.config({ path: path.join(__dirname, '..', '.env'), quiet: true });
  dotenv.config({ path: path.join(__dirname, '..', '.env.turn'), quiet: true });
  if (!process.env.DATABASE_URL) throw fail('DATABASE_MISSING');
  if (!process.env.OPENAI_API_KEY?.trim()) throw fail('PROVIDER_KEY_MISSING');
  const { Pool } = require('pg');
  const pool = new Pool({ connectionString: process.env.DATABASE_URL,
    ssl: process.env.DB_SSL === 'true'
      ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' } : false,
    max: 1, connectionTimeoutMillis: 10000, statement_timeout: 15000,
    query_timeout: 20000, idleTimeoutMillis: 1000 });
  try {
    console.log(JSON.stringify(await executeClearCommand({ pool, options, apiKey: process.env.OPENAI_API_KEY })));
  } finally { await pool.end(); }
}

if (require.main === module) {
  main().catch(error => {
    // Connection errors may contain configuration details; never print the raw error.
    console.error(ERRORS[error.code] || 'No confirmed completion was received. Check the audit log before retrying.');
    process.exitCode = 1;
  });
}

module.exports = { parseArguments, executeClearCommand, main };
