'use strict';

const { createHash, randomUUID } = require('node:crypto');
const { moderationProviderPolicy } = require('./moderation-provider-policy');

const VIDEO_SCAN_MAX_FRAMES = 20;
const VIDEO_SCAN_DEADLINE_MS = 5 * 60 * 1000;
const VIDEO_SCAN_LEASE_MS = 30 * 1000;
const VIDEO_SCAN_MAX_UNCERTAINTY_REVIEWS = 3;
const MODESTY_UNCERTAINTY_REVIEW_OPERATION = 'modesty_uncertainty_review';
const MAX_OPERATION_RESULT_BYTES = 256 * 1024;
const MAX_SCAN_RESULT_BYTES = 2 * 1024 * 1024;
const PROVIDER_OPERATIONS = Object.freeze({
  google_vision: Object.freeze(['safe_search', 'object_localization', 'face_detection']),
  openai: Object.freeze(['person_presence', 'modesty']),
  gemini: Object.freeze(['modesty']),
});
const VIDEO_SCAN_PROVIDER_POLICIES = Object.freeze({
  google_openai_gemini: Object.freeze({
    operations: PROVIDER_OPERATIONS,
    limitsPerFrame: Object.freeze({ total: 6, google_vision: 3, openai: 2, gemini: 1 }),
  }),
  google_gemini: Object.freeze({
    operations: Object.freeze({
      google_vision: PROVIDER_OPERATIONS.google_vision,
      openai: Object.freeze([]),
      gemini: Object.freeze(['person_presence', 'modesty']),
    }),
    limitsPerFrame: Object.freeze({ total: 5, google_vision: 3, openai: 0, gemini: 2 }),
  }),
  google_gemini_optional_openai: Object.freeze({
    operations: Object.freeze({ ...PROVIDER_OPERATIONS,
      gemini: Object.freeze(['person_presence', 'modesty']) }),
    limitsPerFrame: Object.freeze({ total: 6, google_vision: 3, openai: 2, gemini: 2 }),
  }),
});

async function ensureVideoScanBudgetSchema(pool) {
  await pool.query(`CREATE TABLE IF NOT EXISTS video_scan_budgets (
    id uuid PRIMARY KEY,
    user_id text NOT NULL,
    content_sha256 text NOT NULL CHECK (content_sha256 ~ '^[a-f0-9]{64}$'),
    scan_version text NOT NULL,
    provider_policy text NOT NULL DEFAULT 'google_openai_gemini',
    policy_history jsonb NOT NULL DEFAULT '[]'::jsonb,
    stored_file_id text,
    status text NOT NULL CHECK (status IN ('active','completed','stopped')),
    reason text,
    frame_count integer CHECK (frame_count BETWEEN 0 AND 90),
    manifest_hash text,
    manifest jsonb,
    total_used integer NOT NULL DEFAULT 0 CHECK (total_used >= 0),
    google_vision_used integer NOT NULL DEFAULT 0 CHECK (google_vision_used >= 0),
    openai_used integer NOT NULL DEFAULT 0 CHECK (openai_used >= 0),
    gemini_used integer NOT NULL DEFAULT 0 CHECK (gemini_used >= 0),
    lease_token uuid NOT NULL,
    lease_expires_at timestamptz NOT NULL,
    started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    deadline_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    result jsonb,
    UNIQUE (user_id,content_sha256),
    CHECK ((frame_count IS NULL AND manifest_hash IS NULL AND manifest IS NULL)
      OR (frame_count IS NOT NULL AND manifest_hash IS NOT NULL AND manifest IS NOT NULL)),
    CHECK (total_used = google_vision_used + openai_used + gemini_used),
    CONSTRAINT video_scan_budget_policy_check CHECK (provider_policy IN ('google_openai_gemini','google_gemini','google_gemini_optional_openai')),
    CONSTRAINT video_scan_budget_policy_caps CHECK (frame_count IS NULL OR
      (google_vision_used <= 3 * frame_count AND
        ((provider_policy='google_openai_gemini' AND total_used <= 6 * frame_count
          AND openai_used <= 2 * frame_count AND gemini_used <= frame_count)
        OR (provider_policy='google_gemini' AND total_used <= 5 * frame_count
          AND openai_used=0 AND gemini_used <= 2 * frame_count)
        OR (provider_policy='google_gemini_optional_openai' AND total_used <= 6 * frame_count
          AND openai_used <= 2 * frame_count AND gemini_used <= 2 * frame_count))))
  );
  CREATE TABLE IF NOT EXISTS video_scan_operations (
    id uuid PRIMARY KEY,
    scan_id uuid NOT NULL REFERENCES video_scan_budgets(id),
    frame_index integer NOT NULL CHECK (frame_index BETWEEN 0 AND 89),
    provider text NOT NULL,
    operation text NOT NULL,
    status text NOT NULL CHECK (status IN ('reserved','completed','failed')),
    lease_token uuid NOT NULL,
    reserved_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    completed_at timestamptz,
    result jsonb,
    UNIQUE (scan_id,frame_index,provider,operation),
    CONSTRAINT video_scan_operation_kind_check CHECK ((provider='google_vision' AND operation IN ('safe_search','object_localization','face_detection'))
      OR (provider='openai' AND operation IN ('person_presence','modesty','modesty_uncertainty_review'))
      OR (provider='gemini' AND operation IN ('person_presence','modesty','modesty_uncertainty_review')))
  );
  CREATE TABLE IF NOT EXISTS moderation_provider_suspensions (
    provider text NOT NULL,
    credential_hash text NOT NULL CHECK (credential_hash ~ '^[a-f0-9]{64}$'),
    reason text NOT NULL,
    suspended_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    cleared_at timestamptz,
    cleared_by text,
    PRIMARY KEY (provider,credential_hash)
  );`);
  // Existing counters remain under their original limits. Only newly created or
  // provably unstarted credit stops may move to the OpenAI-free policy.
  await pool.query(`ALTER TABLE video_scan_budgets
    ADD COLUMN IF NOT EXISTS provider_policy text NOT NULL DEFAULT 'google_openai_gemini',
    ADD COLUMN IF NOT EXISTS policy_history jsonb NOT NULL DEFAULT '[]'::jsonb;
    DO $migration$
    DECLARE constraint_name text;
    BEGIN
      FOR constraint_name IN SELECT conname FROM pg_constraint
        WHERE conrelid='video_scan_budgets'::regclass AND contype='c'
          AND conname<>'video_scan_budget_policy_caps'
          AND pg_get_constraintdef(oid) LIKE '%total_used <=%'
          AND pg_get_constraintdef(oid) LIKE '%gemini_used <=%'
      LOOP EXECUTE format('ALTER TABLE video_scan_budgets DROP CONSTRAINT %I',constraint_name); END LOOP;
      IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='video_scan_budgets'::regclass
        AND conname='video_scan_budget_policy_check') THEN
        ALTER TABLE video_scan_budgets ADD CONSTRAINT video_scan_budget_policy_check
          CHECK (provider_policy IN ('google_openai_gemini','google_gemini','google_gemini_optional_openai'));
      END IF;
      IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='video_scan_budgets'::regclass
        AND conname='video_scan_budget_policy_caps') THEN
        ALTER TABLE video_scan_budgets ADD CONSTRAINT video_scan_budget_policy_caps
          CHECK (frame_count IS NULL OR (google_vision_used <= 3 * frame_count AND
            ((provider_policy='google_openai_gemini' AND total_used <= 6 * frame_count
              AND openai_used <= 2 * frame_count AND gemini_used <= frame_count)
            OR (provider_policy='google_gemini' AND total_used <= 5 * frame_count
              AND openai_used=0 AND gemini_used <= 2 * frame_count)
            OR (provider_policy='google_gemini_optional_openai' AND total_used <= 6 * frame_count
              AND openai_used <= 2 * frame_count AND gemini_used <= 2 * frame_count))));
      END IF;
      FOR constraint_name IN SELECT conname FROM pg_constraint
        WHERE conrelid='video_scan_operations'::regclass AND contype='c'
          AND conname<>'video_scan_operation_kind_check'
          AND pg_get_constraintdef(oid) LIKE '%provider%'
          AND pg_get_constraintdef(oid) LIKE '%operation%'
      LOOP EXECUTE format('ALTER TABLE video_scan_operations DROP CONSTRAINT %I',constraint_name); END LOOP;
      IF EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='video_scan_operations'::regclass
        AND conname='video_scan_operation_kind_check'
        AND pg_get_constraintdef(oid) NOT LIKE '%modesty_uncertainty_review%') THEN
        ALTER TABLE video_scan_operations DROP CONSTRAINT video_scan_operation_kind_check;
      END IF;
      IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='video_scan_operations'::regclass
        AND conname='video_scan_operation_kind_check') THEN
        ALTER TABLE video_scan_operations ADD CONSTRAINT video_scan_operation_kind_check
          CHECK ((provider='google_vision' AND operation IN ('safe_search','object_localization','face_detection'))
            OR (provider='openai' AND operation IN ('person_presence','modesty','modesty_uncertainty_review'))
            OR (provider='gemini' AND operation IN ('person_presence','modesty','modesty_uncertainty_review')));
      END IF;
    END $migration$;
    CREATE UNIQUE INDEX IF NOT EXISTS video_scan_one_uncertainty_review_per_frame
      ON video_scan_operations(scan_id,frame_index)
      WHERE operation='modesty_uncertainty_review';
    CREATE OR REPLACE FUNCTION enforce_video_scan_operation_policy() RETURNS trigger LANGUAGE plpgsql AS $policy$
    DECLARE scan_policy text;
    BEGIN
      SELECT provider_policy INTO scan_policy FROM video_scan_budgets WHERE id=NEW.scan_id;
      IF (NEW.provider='gemini' AND NEW.operation='person_presence' AND scan_policy='google_openai_gemini')
        OR (NEW.provider='openai' AND scan_policy='google_gemini') THEN
        RAISE EXCEPTION 'Operation is not permitted by video scan provider policy' USING ERRCODE='23514';
      END IF;
      RETURN NEW;
    END $policy$;
    DROP TRIGGER IF EXISTS video_scan_operation_policy ON video_scan_operations;
    CREATE TRIGGER video_scan_operation_policy BEFORE INSERT OR UPDATE OF scan_id,provider,operation
      ON video_scan_operations FOR EACH ROW EXECUTE FUNCTION enforce_video_scan_operation_policy();`);
}

function sha256(value, name) {
  if (typeof value !== 'string' || !/^[a-fA-F0-9]{64}$/.test(value))
    throw new TypeError(`${name} must be a SHA-256 hex digest`);
  return value.toLowerCase();
}

function boundedResult(result, maxBytes = MAX_OPERATION_RESULT_BYTES) {
  if (!result || typeof result !== 'object' || Array.isArray(result))
    throw new TypeError('A structured result is required');
  const json = JSON.stringify(result);
  if (Buffer.byteLength(json) > maxBytes) throw new RangeError('Scan result is too large');
  return JSON.parse(json);
}

function stoppedResult(reason) {
  return { available: false, status: 'stopped', reason, budgetStopped: true, videoScanStopped: true };
}

function budget(row) {
  const n = row.frame_count;
  const policy = VIDEO_SCAN_PROVIDER_POLICIES[row.provider_policy];
  return {
    frameCount: n, manifestHash: row.manifest_hash, manifest: row.manifest,
    providerPolicy: row.provider_policy,
    limits: n === null ? null : Object.fromEntries(Object.entries(policy.limitsPerFrame)
      .map(([provider, cap]) => [provider, cap * n])),
    used: { total: row.total_used, google_vision: row.google_vision_used,
      openai: row.openai_used, gemini: row.gemini_used },
    startedAt: row.started_at, deadlineAt: row.deadline_at,
    leaseExpiresAt: row.lease_expires_at, scanVersion: row.scan_version,
  };
}

function state(row) {
  return { id: row.id, status: row.status, reason: row.reason || undefined,
    result: row.result || undefined, budget: budget(row) };
}

async function transaction(pool, callback) {
  const db = await pool.connect();
  try {
    await db.query('BEGIN');
    await db.query("SET LOCAL statement_timeout='5s'; SET LOCAL lock_timeout='2s'");
    const result = await callback(db);
    await db.query('COMMIT');
    return result;
  } catch (error) {
    try { await db.query('ROLLBACK'); } catch (_) { /* Preserve the original failure. */ }
    throw error;
  } finally { db.release(); }
}

async function lockedRow(db, context) {
  const row = (await db.query(`SELECT * FROM video_scan_budgets WHERE id=$1 FOR UPDATE`,
    [context.scanId || context.id])).rows[0];
  if (row) row.server_now = (await db.query('SELECT clock_timestamp() AS now')).rows[0].now;
  return row;
}

async function stopLocked(db, row, reason, result) {
  if (row.status !== 'active' && !(row.status === 'completed' && reason === 'scan_version_changed')) return state(row);
  const terminal = boundedResult({ ...(result || stoppedResult(reason)),
    available: false, status: 'stopped', reason, budgetStopped: true, videoScanStopped: true }, MAX_SCAN_RESULT_BYTES);
  const saved = (await db.query(`UPDATE video_scan_budgets SET status='stopped',reason=$2,
    result=$3::jsonb,updated_at=clock_timestamp() WHERE id=$1 RETURNING *`,
  [row.id, String(reason).slice(0, 120), JSON.stringify(terminal)])).rows[0];
  return state(saved);
}

async function writable(db, row, context, { allowExpiredLease = false } = {}) {
  if (!row) return { status: 'stopped', reason: 'scan_not_found', result: stoppedResult('scan_not_found') };
  if (row.status !== 'active') return state(row);
  if (row.lease_token !== context.leaseToken) return { status: 'busy', reason: 'lease_lost', budget: budget(row) };
  if (row.server_now >= row.deadline_at) return stopLocked(db, row, 'deadline_exceeded');
  if (!allowExpiredLease && row.server_now >= row.lease_expires_at)
    return { status: 'busy', reason: 'lease_expired', budget: budget(row) };
  return null;
}

async function acquireVideoScan(pool, { userId, contentSha256, scanVersion, storedFileId, legacyUnsafe = false,
  providerPolicy = moderationProviderPolicy() }) {
  const digest = sha256(contentSha256, 'contentSha256');
  if (!userId || !scanVersion) throw new TypeError('userId and scanVersion are required');
  if (!Object.hasOwn(VIDEO_SCAN_PROVIDER_POLICIES, providerPolicy)) throw new TypeError('Unknown video scan provider policy');
  return transaction(pool, async db => {
    await db.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))', ['scan-cache:' + digest]);
    const id = randomUUID(), leaseToken = randomUUID();
    // The unique constraint serializes concurrent creation of the same canonical video.
    const inserted = await db.query(`INSERT INTO video_scan_budgets
      (id,user_id,content_sha256,scan_version,stored_file_id,status,lease_token,started_at,lease_expires_at,deadline_at,provider_policy)
      VALUES($1,$2,$3,$4,$5,'active',$6,statement_timestamp(),statement_timestamp()+($7*interval '1 millisecond'),
        statement_timestamp()+($8*interval '1 millisecond'),$9)
      ON CONFLICT(user_id,content_sha256) DO NOTHING RETURNING id`,
    [id, String(userId), digest, String(scanVersion), storedFileId || null, leaseToken,
      VIDEO_SCAN_LEASE_MS, VIDEO_SCAN_DEADLINE_MS, providerPolicy]);
    const row = (await db.query(`SELECT * FROM video_scan_budgets
      WHERE user_id=$1 AND content_sha256=$2 FOR UPDATE`, [String(userId), digest])).rows[0];
    row.server_now = (await db.query('SELECT clock_timestamp() AS now')).rows[0].now;
    if (!legacyUnsafe && providerPolicy !== 'google_openai_gemini' && row.provider_policy === 'google_openai_gemini'
        && row.status === 'stopped' && row.reason === 'credit_balance_exhausted'
        && row.frame_count === null && row.total_used === 0) {
      const operations = await db.query('SELECT 1 FROM video_scan_operations WHERE scan_id=$1 LIMIT 1', [row.id]);
      if (!operations.rowCount) {
        const transitioned = (await db.query(`UPDATE video_scan_budgets
          SET policy_history=policy_history || jsonb_build_array(jsonb_build_object(
            'providerPolicy',provider_policy,'scanVersion',scan_version,'status',status,'reason',reason,
            'startedAt',started_at,'deadlineAt',deadline_at,'stoppedAt',updated_at)),
            provider_policy=$2,scan_version=$3,status='active',reason=NULL,result=NULL,lease_token=$4,
            started_at=statement_timestamp(),deadline_at=statement_timestamp()+($5*interval '1 millisecond'),
            lease_expires_at=statement_timestamp()+($6*interval '1 millisecond'),
            stored_file_id=COALESCE($7,stored_file_id),updated_at=clock_timestamp()
          WHERE id=$1 RETURNING *`, [row.id, providerPolicy, String(scanVersion), leaseToken,
        VIDEO_SCAN_DEADLINE_MS, VIDEO_SCAN_LEASE_MS, storedFileId || null])).rows[0];
        return { ...state(transitioned), status: 'acquired', leaseToken };
      }
    }
    if (row.status === 'completed' && (row.scan_version !== String(scanVersion) || row.provider_policy !== providerPolicy))
      return stopLocked(db, row, 'scan_version_changed');
    if (row.status !== 'active') return state(row);
    if (inserted.rowCount && legacyUnsafe) return stopLocked(db, row, 'legacy_budget_unknown');
    if (row.server_now >= row.deadline_at) return stopLocked(db, row, 'deadline_exceeded');
    if (inserted.rowCount) return { ...state(row), status: 'acquired', leaseToken };
    if (row.server_now < row.lease_expires_at) return { ...state(row), status: 'busy', reason: 'lease_active' };
    if (row.scan_version !== String(scanVersion) || row.provider_policy !== providerPolicy)
      return stopLocked(db, row, 'scan_version_changed');
    const outstanding = await db.query(`SELECT 1 FROM video_scan_operations
      WHERE scan_id=$1 AND (status='reserved' OR (status='failed' AND NOT
        ($2='google_gemini_optional_openai' AND provider='openai'))) LIMIT 1`, [row.id, row.provider_policy]);
    if (outstanding.rowCount) return stopLocked(db, row, 'operation_outcome_unknown');
    const recovered = (await db.query(`UPDATE video_scan_budgets SET lease_token=$2,
      lease_expires_at=LEAST(deadline_at,clock_timestamp()+($3*interval '1 millisecond')),
      stored_file_id=COALESCE($4,stored_file_id),updated_at=clock_timestamp() WHERE id=$1 RETURNING *`,
    [row.id, leaseToken, VIDEO_SCAN_LEASE_MS, storedFileId || null])).rows[0];
    return { ...state(recovered), status: 'acquired', leaseToken };
  });
}

function normalizeManifest(frames) {
  if (!Array.isArray(frames) || frames.length > VIDEO_SCAN_MAX_FRAMES)
    throw new RangeError('A manifest must contain 0 to 20 frames');
  return frames.map((frame, index) => {
    if (!frame || typeof frame !== 'object' || (frame.frameIndex ?? frame.index ?? index) !== index)
      throw new TypeError('Frame indexes must be contiguous and start at zero');
    const timeSeconds = frame.timeSeconds ?? frame.timestampSeconds ?? null;
    if (timeSeconds !== null && (typeof timeSeconds !== 'number' || !Number.isFinite(timeSeconds) || timeSeconds < 0))
      throw new TypeError('Frame timestamps must be finite and nonnegative');
    return { frameIndex: index, sha256: sha256(frame.sha256 ?? frame.contentSha256, 'frame.sha256'), timeSeconds };
  });
}

async function setVideoScanManifest(pool, context, frames) {
  const manifest = normalizeManifest(frames);
  const json = JSON.stringify(manifest), hash = createHash('sha256').update(json).digest('hex');
  return transaction(pool, async db => {
    const row = await lockedRow(db, context), blocked = await writable(db, row, context);
    if (blocked) return blocked;
    if (row.manifest_hash && row.manifest_hash !== hash) return stopLocked(db, row, 'frame_manifest_changed');
    const saved = row.manifest_hash ? row : (await db.query(`UPDATE video_scan_budgets
      SET frame_count=$2,manifest_hash=$3,manifest=$4::jsonb,updated_at=clock_timestamp()
      WHERE id=$1 RETURNING *`, [row.id, manifest.length, hash, json])).rows[0];
    return { ...state(saved), status: 'ready' };
  });
}

async function reserveVideoScanOperation(pool, context) {
  const { frameIndex, provider, operation } = context;
  return transaction(pool, async db => {
    const row = await lockedRow(db, context), blocked = await writable(db, row, context);
    if (blocked) return blocked;
    const operations = VIDEO_SCAN_PROVIDER_POLICIES[row.provider_policy].operations;
    const uncertaintyReview = ['gemini', 'openai'].includes(provider) &&
      operation === MODESTY_UNCERTAINTY_REVIEW_OPERATION &&
      operations[provider].length > 0;
    if (!Object.hasOwn(operations, provider) ||
        !operations[provider].includes(operation) && !uncertaintyReview)
      return stopLocked(db, row, 'operation_not_allowed');
    if (row.frame_count === null) return stopLocked(db, row, 'frame_manifest_missing');
    if (!Number.isInteger(frameIndex) || frameIndex < 0 || frameIndex >= row.frame_count)
      return stopLocked(db, row, 'frame_index_invalid');
    const existing = (await db.query(uncertaintyReview
      ? `SELECT * FROM video_scan_operations WHERE scan_id=$1 AND frame_index=$2 AND operation=$3`
      : `SELECT * FROM video_scan_operations
        WHERE scan_id=$1 AND frame_index=$2 AND provider=$3 AND operation=$4`,
    uncertaintyReview ? [row.id, frameIndex, operation]
      : [row.id, frameIndex, provider, operation])).rows[0];
    if (uncertaintyReview && existing && existing.provider !== provider)
      return stopLocked(db, row, 'uncertainty_review_limit');
    if (existing?.status === 'completed' || existing?.status === 'failed' &&
        row.provider_policy === 'google_gemini_optional_openai' && provider === 'openai')
      return { status: 'cached', result: existing.result, budget: budget(row) };
    if (existing?.status === 'reserved') return { status: 'busy', reason: 'operation_in_flight', budget: budget(row) };
    if (existing) return stopLocked(db, row, 'operation_failed');
    if (uncertaintyReview) {
      // The scan row remains locked while counting all attempts and reserving;
      // failed or unfinished calls still consume one of the three reviews.
      const used = (await db.query(`SELECT count(*)::int AS used FROM video_scan_operations
        WHERE scan_id=$1 AND operation=$2`,
      [row.id, MODESTY_UNCERTAINTY_REVIEW_OPERATION])).rows[0].used;
      if (used >= VIDEO_SCAN_MAX_UNCERTAINTY_REVIEWS)
        return stopLocked(db, row, 'uncertainty_review_limit');
    }
    const limits = budget(row).limits;
    if (row.total_used >= limits.total || row[`${provider}_used`] >= limits[provider])
      return stopLocked(db, row, 'budget_exhausted');
    if (uncertaintyReview) {
      const baseCalls = (await db.query(`SELECT provider,count(DISTINCT frame_index)::int AS used
        FROM video_scan_operations WHERE scan_id=$1 AND operation='modesty'
          AND provider IN ('gemini','openai') GROUP BY provider`, [row.id])).rows;
      const called = Object.fromEntries(baseCalls.map(item => [item.provider, item.used]));
      const geminiFloor = Math.max(0, row.frame_count - (called.gemini || 0));
      const openaiFloor = row.provider_policy === 'google_openai_gemini'
        ? Math.max(0, row.frame_count - (called.openai || 0)) : 0;
      // Do not spend another frame's first modesty call on this review. The
      // separate provider floor is conservative even for optional OpenAI.
      const providerFloor = Math.max(0, row.frame_count - (called[provider] || 0));
      if (row.total_used + 1 + geminiFloor + openaiFloor > limits.total ||
          row[`${provider}_used`] + 1 + providerFloor > limits[provider])
        return stopLocked(db, row, 'budget_exhausted');
    }
    const reservationId = randomUUID();
    const saved = (await db.query(`UPDATE video_scan_budgets SET total_used=total_used+1,
      ${provider}_used=${provider}_used+1,updated_at=clock_timestamp()
      WHERE id=$1 AND deadline_at>clock_timestamp() RETURNING *`, [row.id])).rows[0];
    if (!saved) return stopLocked(db, row, 'deadline_exceeded');
    await db.query(`INSERT INTO video_scan_operations(id,scan_id,frame_index,provider,operation,status,lease_token)
      VALUES($1,$2,$3,$4,$5,'reserved',$6)`,
    [reservationId, row.id, frameIndex, provider, operation, context.leaseToken]);
    return { status: 'reserved', reservationId, budget: budget(saved) };
  });
}

async function finishVideoScanOperation(pool, context) {
  const result = boundedResult(context.result);
  return transaction(pool, async db => {
    const row = await lockedRow(db, context);
    if (!row) return { status: 'stopped', reason: 'scan_not_found' };
    if (row.status !== 'active') return state(row);
    if (row.lease_token !== context.leaseToken) return { status: 'busy', reason: 'lease_lost' };
    const operation = (await db.query(`SELECT * FROM video_scan_operations
      WHERE id=$1 AND scan_id=$2 AND lease_token=$3`,
    [context.reservationId, row.id, context.leaseToken])).rows[0];
    if (!operation) return stopLocked(db, row, 'reservation_not_found');
    if (operation.status === 'completed' || operation.status === 'failed' &&
        row.provider_policy === 'google_gemini_optional_openai' && operation.provider === 'openai')
      return { status: 'completed', result: operation.result, budget: budget(row) };
    if (operation.status !== 'reserved') return stopLocked(db, row, 'operation_failed');
    await db.query(`UPDATE video_scan_operations SET status=$2,result=$3::jsonb,
      completed_at=clock_timestamp() WHERE id=$1`,
    [operation.id, result.available === true ? 'completed' : 'failed', JSON.stringify(result)]);
    if (result.available !== true && !(row.provider_policy === 'google_gemini_optional_openai' &&
        operation.provider === 'openai')) return stopLocked(db, row,
      result.reason === 'credit_balance_exhausted' || result.errorCode === 'credit_balance_exhausted'
        ? 'credit_balance_exhausted' : 'required_provider_unavailable');
    const now = (await db.query('SELECT clock_timestamp() AS now')).rows[0].now;
    if (now >= row.deadline_at) return stopLocked(db, row, 'deadline_exceeded');
    return { status: 'completed', result, budget: budget(row) };
  });
}

async function renewVideoScanLease(pool, context) {
  return transaction(pool, async db => {
    const row = await lockedRow(db, context), blocked = await writable(db, row, context);
    if (blocked) return blocked;
    const saved = (await db.query(`UPDATE video_scan_budgets
      SET lease_expires_at=LEAST(deadline_at,clock_timestamp()+($2*interval '1 millisecond')),
      updated_at=clock_timestamp() WHERE id=$1 RETURNING *`, [row.id, VIDEO_SCAN_LEASE_MS])).rows[0];
    return { ...state(saved), status: 'renewed', leaseToken: context.leaseToken };
  });
}

async function stopVideoScan(pool, context, reason, result) {
  return transaction(pool, async db => {
    const row = await lockedRow(db, context);
    if (!row) return { status: 'stopped', reason: 'scan_not_found' };
    if (row.status !== 'active') return state(row);
    if (row.lease_token !== context.leaseToken) return { status: 'busy', reason: 'lease_lost' };
    return stopLocked(db, row, reason || 'scan_stopped', result);
  });
}

async function finishVideoScan(pool, context, result) {
  const finalResult = boundedResult(result, MAX_SCAN_RESULT_BYTES);
  return transaction(pool, async db => {
    const row = await lockedRow(db, context), blocked = await writable(db, row, context);
    if (blocked) return blocked;
    if (row.frame_count === null) return stopLocked(db, row, 'frame_manifest_missing');
    const outstanding = await db.query(`SELECT 1 FROM video_scan_operations
      WHERE scan_id=$1 AND status<>'completed' AND NOT
        ($2='google_gemini_optional_openai' AND provider='openai' AND status='failed') LIMIT 1`,
    [row.id, row.provider_policy]);
    if (outstanding.rowCount) return stopLocked(db, row, 'operation_outcome_unknown');
    const saved = (await db.query(`UPDATE video_scan_budgets SET status='completed',result=$2::jsonb,
      updated_at=clock_timestamp() WHERE id=$1 AND deadline_at>clock_timestamp() RETURNING *`,
    [row.id, JSON.stringify(finalResult)])).rows[0];
    if (!saved) return stopLocked(db, row, 'deadline_exceeded');
    return state(saved);
  });
}

async function getVideoScanBudget(pool, context) {
  return transaction(pool, async db => {
    const row = await lockedRow(db, context);
    if (!row) return { status: 'stopped', reason: 'scan_not_found' };
    if (row.status === 'active' && row.server_now >= row.deadline_at) return stopLocked(db, row, 'deadline_exceeded');
    return state(row);
  });
}

function validateProvider(provider) {
  if (!Object.hasOwn(PROVIDER_OPERATIONS, provider)) throw new TypeError('Unknown moderation provider');
}

function suspension(row) {
  return row ? { provider: row.provider, credentialHash: row.credential_hash,
    reason: row.reason, suspendedAt: row.suspended_at } : null;
}

async function getProviderSuspension(pool, provider, credentialHash) {
  validateProvider(provider);
  const hash = sha256(credentialHash, 'credentialHash');
  return suspension((await pool.query(`SELECT * FROM moderation_provider_suspensions
    WHERE provider=$1 AND credential_hash=$2 AND cleared_at IS NULL`, [provider, hash])).rows[0]);
}

async function suspendProvider(pool, { provider, credentialHash, reason = 'credit_balance_exhausted' }) {
  validateProvider(provider);
  const hash = sha256(credentialHash, 'credentialHash');
  return suspension((await pool.query(`INSERT INTO moderation_provider_suspensions(provider,credential_hash,reason)
    VALUES($1,$2,$3) ON CONFLICT(provider,credential_hash) DO UPDATE SET
    reason=EXCLUDED.reason,suspended_at=CASE WHEN moderation_provider_suspensions.cleared_at IS NULL
      THEN moderation_provider_suspensions.suspended_at ELSE clock_timestamp() END,
    cleared_at=NULL,cleared_by=NULL RETURNING *`, [provider, hash, String(reason).slice(0, 120)])).rows[0]);
}

// Deliberately has no route or automatic caller; administrative clearance must be explicit.
async function clearProviderSuspension(pool, { provider, credentialHash, actorId, confirmed = false }) {
  validateProvider(provider);
  const hash = sha256(credentialHash, 'credentialHash');
  if (!confirmed || !actorId) throw new TypeError('Explicit confirmation and actorId are required');
  const result = await pool.query(`UPDATE moderation_provider_suspensions SET cleared_at=clock_timestamp(),
    cleared_by=$3 WHERE provider=$1 AND credential_hash=$2 AND cleared_at IS NULL`, [provider, hash, String(actorId)]);
  return { cleared: result.rowCount === 1 };
}

module.exports = { VIDEO_SCAN_MAX_FRAMES, VIDEO_SCAN_DEADLINE_MS, VIDEO_SCAN_LEASE_MS,
  VIDEO_SCAN_MAX_UNCERTAINTY_REVIEWS, MODESTY_UNCERTAINTY_REVIEW_OPERATION,
  PROVIDER_OPERATIONS, VIDEO_SCAN_PROVIDER_POLICIES, ensureVideoScanBudgetSchema, acquireVideoScan, setVideoScanManifest,
  reserveVideoScanOperation, finishVideoScanOperation, renewVideoScanLease, stopVideoScan,
  finishVideoScan, getVideoScanBudget, getProviderSuspension, suspendProvider, clearProviderSuspension };
