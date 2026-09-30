'use strict';
const path = require('node:path');
require('dotenv').config({ path: path.join(__dirname, '..', '.env'), quiet: true });
const { Pool } = require('pg');
const central = require('../server/central-drive');
const { readSourceMedia } = require('../server/received-media');
const pool = new Pool({ connectionString: process.env.DATABASE_URL, max: 4,
  ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' } : false });

(async () => {
  const command = process.argv[2] || 'status';
  if (command === 'configure') {
    await pool.query(central.SCHEMA);
    console.log(JSON.stringify(await central.configure(pool, false)));
  } else if (command === 'enable' || command === 'pause') {
    const updated = await pool.query('UPDATE central_drive_account SET enabled=$1,updated_at=now() WHERE id=1 RETURNING email,enabled', [command === 'enable']);
    if (!updated.rows.length) throw new Error('Not configured');
    console.log(JSON.stringify(updated.rows[0]));
  } else if (command === 'migrate') {
    const args = Object.fromEntries(process.argv.slice(3).map(arg => arg.replace(/^--/, '').split('=')));
    const limit = Number(args.limit || 5);
    if (!Number.isInteger(limit) || limit < 1 || limit > 1000) throw new Error('Invalid batch limit');
    if (args.file && !/^[a-f0-9-]{36}$/i.test(args.file)) throw new Error('Invalid file ID');
    const worker = central.createCentralStorage({ getPool: async () => pool,
      uploadRoot: path.join(__dirname, '..', 'uploads'), readSource: readSourceMedia });
    console.log(JSON.stringify(await worker.runBatch({ limit, fileId: args.file || null,
      releaseLocal: !Object.hasOwn(args, 'keep-local'), allowPaused: Object.hasOwn(args, 'allow-paused') })));
  } else if (command === 'status') console.log(JSON.stringify(await central.status(pool)));
  else throw new Error('Unknown command');
})().catch(error => {
  console.error('Central storage operation failed', error.response?.status || error.code || 'check_configuration');
  process.exitCode = 1;
}).finally(() => pool.end());
