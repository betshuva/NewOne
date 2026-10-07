'use strict';

const { createHash } = require('node:crypto');
const { sourceHash } = require('./upload-file-source');
const ledger = require('./video-scan-budget');
const { credentialHash } = require('./moderation-provider-guard');
const { moderationProviderPolicy } = require('./moderation-provider-policy');

function stoppedVideoResult(reasonCode = 'scan_incomplete', budget, previous = {}) {
  const reasons = {
    budget_exhausted: 'מכסת הבדיקות לסרטון מוצתה',
    deadline_exceeded: 'הסריקה חרגה מחמש דקות',
    credit_balance_exhausted: 'אין יתרת קרדיט אצל ספק הבדיקה',
    provider_suspended: 'ספק הבדיקה מושהה',
    provider_not_configured: 'ספק בדיקה נדרש אינו מוגדר',
    legacy_budget_unknown: 'לא ניתן לאמת את מספר הבדיקות הקודמות של הסרטון',
    frame_manifest_changed: 'התמונות שנדגמו אינן תואמות לסריקה הקודמת',
    scan_version_changed: 'השתנתה גרסת הסריקה; נדרש אישור מנהל לבדיקה נוספת',
    operation_outcome_unknown: 'הסריקה הופסקה ותוצאת בקשה קודמת אינה ידועה',
    provider_guard_unavailable: 'לא ניתן לאמת את מכסת הבדיקות',
    source_unavailable: 'לא ניתן לקרוא את קובץ הסרטון',
  };
  // Never let a partial provider response become an approved moderation result.
  return { ...previous, stopped: true, scanStopped: true, blocked: false,
    pending: false, retryable: false, reasonCode,
    reason: `הסריקה נעצרה: ${reasons[reasonCode] || 'בדיקה נדרשת לא הושלמה'}`,
    classification: { ...(previous.classification || {}), category: 'video',
      uncertain: true }, budget: publicBudget(budget || previous.budget) };
}

function publicBudget(budget) {
  if (!budget) return undefined;
  const { frameCount, limits, used, startedAt, deadlineAt, scanVersion, providerPolicy } = budget;
  return { frameCount, limits, used, startedAt, deadlineAt, scanVersion, providerPolicy };
}

function pendingVideoResult(budget) {
  return { pending: true, blocked: false, reason: 'סריקת הסרטון כבר מתבצעת',
    budget: publicBudget(budget) };
}

function reconcileVideoState(state, fallbackReason = 'scan_incomplete', previous) {
  if (state?.status === 'completed')
    return { ...state.result, budget: publicBudget(state.budget) };
  if (state?.status === 'busy') return pendingVideoResult(state.budget);
  return stoppedVideoResult(state?.reason || fallbackReason, state?.budget,
    previous || state?.result);
}

function videoProviderStop(...results) {
  for (const result of results) {
    if (!result || typeof result !== 'object') continue;
    if (result.budgetStopped || result.scanStopped || result.videoScanStopped)
      return result.reasonCode || result.errorCode || result.reason || 'required_provider_unavailable';
    const nested = videoProviderStop(...Object.entries(result.providers || {})
      .filter(([provider]) => provider !== 'openai' || moderationProviderPolicy() === 'google_openai_gemini')
      .map(([, value]) => value));
    if (nested) return nested;
  }
  return null;
}

async function freezeVideoFrames(pool, context, samples, sampledFrames, api = ledger) {
  if (!Array.isArray(samples) || samples.length < 1 ||
      samples.length > ledger.VIDEO_SCAN_MAX_FRAMES ||
      !Number.isInteger(Number(sampledFrames)) || Number(sampledFrames) !== samples.length)
    throw new Error('invalid_frame_manifest');
  const manifest = samples.map((sample, frameIndex) => {
    const bytes = Buffer.from(String(sample?.jpeg_base64 || ''), 'base64');
    const timeSeconds = Number(sample?.timestamp_seconds);
    if (bytes.length < 32 || !Number.isFinite(timeSeconds) || timeSeconds < 0)
      throw new Error('invalid_frame_manifest');
    return { frameIndex, sha256: createHash('sha256').update(bytes).digest('hex'), timeSeconds };
  });
  const result = await api.setVideoScanManifest(pool, context, manifest);
  if (result.status !== 'ready') return stoppedVideoResult(result.reason, result.budget);
  return null;
}

async function runBoundedVideoScan(buffer, fileName, mimeType, options) {
  const { pool, scan, tracking, scanVersion, legacyUnsafe = false } = options;
  const api = options.ledger || ledger;
  const providerPolicy = moderationProviderPolicy();
  let context;
  let state;
  let timer;
  let heartbeat;
  const abort = new AbortController();
  try {
    state = await api.acquireVideoScan(pool, {
      userId: tracking.userId, storedFileId: tracking.storedFileId,
      contentSha256: await sourceHash(buffer),
      scanVersion, legacyUnsafe, providerPolicy,
    });
    if (state.status !== 'acquired') {
      // Link retained evidence only; never decode media or call a classifier here.
      if (state.status !== 'busy' && state.result && options.attachCachedPreview)
        await options.attachCachedPreview(state).catch(() => {});
      return { ...reconcileVideoState(state), ...(state.status === 'completed' ? { cacheHit:true } : {}) };
    }
    context = { scanId: state.id, leaseToken: state.leaseToken };
    if (state.budget.providerPolicy && state.budget.providerPolicy !== providerPolicy) {
      state = await api.stopVideoScan(pool, context, 'scan_version_changed');
      return reconcileVideoState(state);
    }

    // A known exhausted account must not start another video's paid pipeline.
    const requiredProvider = providerPolicy === 'google_openai_gemini' ? 'openai' : 'gemini';
    const key = String(requiredProvider === 'gemini'
      ? options.geminiKey ?? process.env.GEMINI_API_KEY ?? ''
      : options.openaiKey ?? process.env.OPENAI_API_KEY ?? '').trim();
    if (requiredProvider === 'gemini' && !key) {
      state = await api.stopVideoScan(pool, context, 'provider_not_configured');
      return reconcileVideoState(state);
    }
    const suspended = key && await api.getProviderSuspension(pool, requiredProvider, credentialHash(key));
    if (suspended) {
      state = await api.stopVideoScan(pool, context, suspended.reason);
      return reconcileVideoState(state);
    }
    const remaining = new Date(state.budget.deadlineAt).getTime() - Date.now();
    if (remaining <= 0) throw new Error('deadline_exceeded');
    const deadline = AbortSignal.timeout(Math.min(remaining, ledger.VIDEO_SCAN_DEADLINE_MS));
    const signal = AbortSignal.any([abort.signal, deadline]);
    const renew = () => {
      timer = setTimeout(() => {
        heartbeat = api.renewVideoScanLease(pool, context).then(updated => {
          if (updated.status !== 'renewed') {
            abort.abort(new Error(updated.reason || 'lease_lost'));
            return;
          }
          if (!abort.signal.aborted) renew();
        }).catch(() => abort.abort(new Error('provider_guard_unavailable')));
      }, 10000);
      timer.unref?.();
    };
    renew();
    let onAbort;
    let result;
    try {
      const cancelled = new Promise(resolve => {
        onAbort = () => resolve(stoppedVideoResult(deadline.aborted
          ? 'deadline_exceeded' : abort.signal.reason?.message || 'scan_incomplete'));
        signal.addEventListener('abort', onAbort, { once: true });
        if (signal.aborted) onAbort();
      });
      result = await Promise.race([scan(buffer, fileName, mimeType, {
        tracking: { ...tracking, videoBudget: { ...context, signal } },
        signal,
        freezeFrames: (samples, count) => freezeVideoFrames(pool, context, samples, count, api),
      }), cancelled]);
    } finally {
      signal.removeEventListener('abort', onAbort);
    }
    const reason = signal.aborted
      ? deadline.aborted ? 'deadline_exceeded' : abort.signal.reason?.message
      : videoProviderStop(result) || (result?.pending || !result ? 'scan_incomplete' : null);
    if (reason) state = await api.stopVideoScan(pool, context, reason, result);
    else {
      // Duration rejection needs no provider calls, but still has a frozen zero-frame budget.
      if (result.blockedBy === 'video_duration')
        await api.setVideoScanManifest(pool, context, []);
      state = await api.finishVideoScan(pool, context, result);
    }
    return reconcileVideoState(state, 'scan_incomplete', result);
  } catch (error) {
    const reason = error.message === 'deadline_exceeded' ? error.message : 'provider_guard_unavailable';
    if (context) {
      try { state = await api.stopVideoScan(pool, context, reason); } catch (_) {}
    }
    return reconcileVideoState(state, reason);
  } finally {
    abort.abort();
    clearTimeout(timer);
    if (heartbeat) await heartbeat;
    clearTimeout(timer);
  }
}

module.exports = { stoppedVideoResult, publicBudget, videoProviderStop,
  freezeVideoFrames, runBoundedVideoScan };
