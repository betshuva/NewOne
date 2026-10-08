'use strict';

const { createHash } = require('node:crypto');
const { recordProviderCheck, providerResultRecorded } = require('./provider-usage-log');
const { openAIModerationEnabled, disabledModerationProviderResult } = require('./moderation-provider-policy');

function credentialHash(apiKey) {
  return createHash('sha256').update(String(apiKey).trim()).digest('hex');
}

function stoppedResult(reason, result = {}) {
  return { ...result, configured: true, available: false, status: 'stopped',
    budgetStopped: true, retryable: false, reasonCode: reason };
}

function providerRequestSignal(options, timeoutMs) {
  const timeout = AbortSignal.timeout(timeoutMs);
  const signal = options.signal || options.tracking?.videoBudget?.signal;
  return signal ? AbortSignal.any([signal, timeout]) : timeout;
}

async function guardModerationProvider({ provider, operation, apiKey, options = {}, run }) {
  const budget = options.tracking?.videoBudget;
  const uncertaintyReview = operation === 'modesty_uncertainty_review';
  const signal = options.signal || budget?.signal;
  const dependencies = options.providerGuardDependencies || {};
  const auditResult = async result => {
    try {
      await (dependencies.recordProviderCheck || recordProviderCheck)({ provider, operation,
        tracking: options.tracking, result, cacheHit: result.cacheHit === true,
        model: result.model, durationMs: result.durationMs, auditOnly: true });
    } catch (_) { /* Audit availability never changes a moderation decision. */ }
    return result;
  };
  const runOnce = async () => {
    // A review is one provider attempt, including for images. Never begin it
    // after cancellation, even if obtaining a video reservation took time.
    if (uncertaintyReview && signal?.aborted)
      return auditResult(stoppedResult('deadline_exceeded'));
    let result;
    try { result = await run(); }
    catch (error) { result = { configured: true, available: false, status: 'error',
      errorCode: String(error?.code || error?.name || 'REQUEST_FAILED') }; }
    if (!providerResultRecorded(result)) await auditResult(result);
    return result;
  };
  if (uncertaintyReview) {
    if (!['gemini', 'openai'].includes(provider))
      return auditResult(stoppedResult('uncertainty_review_provider_not_allowed'));
    if (String(process.env.MODERATION_UNCERTAINTY_REVIEW_ENABLED || '').trim().toLowerCase() === 'false')
      return auditResult(stoppedResult('uncertainty_review_disabled'));
    if (signal?.aborted) return auditResult(stoppedResult('deadline_exceeded'));
  }
  if (provider === 'openai' && !openAIModerationEnabled())
    return auditResult(disabledModerationProviderResult());
  if (!apiKey) return budget || uncertaintyReview
    ? auditResult(stoppedResult('provider_not_configured')) : runOnce();
  const databaseConfigured = Boolean(process.env.DATABASE_URL || dependencies.pool ||
    dependencies.getPool);
  if (!budget && (provider !== 'openai' || !databaseConfigured)) return runOnce();
  if (!databaseConfigured) return auditResult(stoppedResult('provider_guard_unavailable'));

  let pool;
  let ledger;
  let reservation;
  const hash = provider === 'openai' ? credentialHash(apiKey) : null;
  try {
    pool = dependencies.pool || await (dependencies.getPool || require('./db').getPool)();
    ledger = dependencies.ledger || require('./video-scan-budget');
    if (provider === 'openai') {
      const suspension = await ledger.getProviderSuspension(pool, provider, hash);
      if (suspension) return auditResult(stoppedResult(suspension.reason || 'provider_suspended', {
        errorCode: suspension.reason || 'provider_suspended', providerSuspended: true,
      }));
    }
    if (budget) {
      reservation = await ledger.reserveVideoScanOperation(pool, {
        scanId: budget.scanId, leaseToken: budget.leaseToken,
        frameIndex: budget.frameIndex, provider, operation,
      });
      if (reservation.status === 'cached')
        return auditResult({ ...reservation.result, cacheHit: true });
      if (reservation.status !== 'reserved')
        return auditResult(stoppedResult(reservation.reason || 'video_operation_unavailable'));
    }
  } catch (_) {
    return auditResult(stoppedResult('provider_guard_unavailable'));
  }

  let result = await runOnce();

  try {
    if (provider === 'openai' && result.errorCode === 'credit_balance_exhausted') {
      await ledger.suspendProvider(pool, { provider, credentialHash: hash,
        reason: 'credit_balance_exhausted' });
      result = stoppedResult('credit_balance_exhausted', {
        ...result, providerSuspended: true,
      });
    }
    if (reservation) {
      // Persist only the provider response; runtime cancellation never enters JSON.
      const persistedResult = JSON.parse(JSON.stringify(result,
        (key, value) => key === 'signal' ? undefined : value));
      const finished = await ledger.finishVideoScanOperation(pool, {
        scanId: budget.scanId, leaseToken: budget.leaseToken,
        reservationId: reservation.reservationId, result: persistedResult,
      });
      if (finished.status !== 'completed')
        return stoppedResult(finished.reason || result.errorCode ||
          'video_operation_failed', result);
      if (result.available !== true)
        return stoppedResult(result.reasonCode || result.errorCode ||
          'video_operation_failed', result);
    }
    return result;
  } catch (_) {
    // A lost acknowledgement can still mean the request was billed.
    return stoppedResult('provider_guard_unavailable', result);
  }
}

module.exports = { credentialHash, guardModerationProvider, providerRequestSignal };
