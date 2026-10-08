'use strict';

const CHECK_TYPES = Object.freeze(['safe_search', 'object_localization', 'face_detection',
  'person_presence', 'modesty', 'modesty_uncertainty_review', 'modesty_format_repair', 'local_safety', 'local_explicit_content',
  'local_classification', 'video_frames', 'audio_transcription', 'document_content', 'media_moderation']);
const CHECK_OUTCOMES = Object.freeze(['passed', 'blocked', 'uncertain', 'failed', 'stopped', 'skipped', 'not_recorded']);
const CATEGORIES = ['adult', 'racy', 'violence', 'medical', 'spoof'];
const LIKELIHOODS = ['unknown', 'very_unlikely', 'unlikely', 'possible', 'likely', 'very_likely'];
const CHECK_FINDINGS = Object.freeze([
  ...CATEGORIES.flatMap(category => LIKELIHOODS.map(likelihood => `${category}_${likelihood}`)),
  'person_detected', 'no_person_detected', 'faces_detected', 'no_faces_detected',
  'men', 'women', 'children', 'modest', 'non_modest', 'uncertain', 'visible_violation',
  'unsupported_violation', 'provider_safety_block', 'credit_balance_exhausted',
  'quota_exhausted', 'request_timeout', 'request_failed', 'invalid_response',
  'provider_not_configured', 'provider_suspended', 'provider_guard_unavailable',
  'budget_exhausted', 'deadline_exceeded', 'lease_lost', 'operation_outcome_unknown',
  'non_human', 'speech_detected', 'no_speech_detected', 'harmful_text', 'comparison_only', 'provider_disabled',
  'fallback_review_used', 'out_of_frame_ignored',
  'modesty_uncertain', 'provider_unavailable', 'provider_error', 'uncertainty_review_limit', 'uncertainty_review_disabled',
]);

function outcome(result, provider) {
  if (!result || typeof result !== 'object') return 'not_recorded';
  if (result.budgetStopped || result.scanStopped || result.videoScanStopped || result.status === 'stopped') return 'stopped';
  if (result.status === 'not_configured' || result.status === 'disabled' || result.required === false || result.status === 'skipped') return 'skipped';
  if (result.available === false || ['error', 'failed', 'timeout'].includes(result.status)) return 'failed';
  if (result.blocked === true || result.wouldBlock === true || result.decision === 'non_modest' || result.status === 'safety_blocked') return 'blocked';
  if (result.uncertain === true || result.classification?.uncertain === true || result.pending === true || result.decision === 'uncertain') return 'uncertain';
  if (['modest', 'person', 'non_human'].includes(result.decision) ||
      typeof result.personDetected === 'boolean' || typeof result.faceDetected === 'boolean' ||
      result.blocked === false || result.wouldBlock === false || result.status === 'passed' ||
      provider === 'local' && result.available === true) return 'passed';
  return 'not_recorded';
}

function moderationCheckSummary(provider, operation, result, tracking = {}) {
  if (!CHECK_TYPES.includes(operation)) return {};
  result = result && typeof result === 'object' ? result : {};
  const findings = [];
  const add = value => { if (CHECK_FINDINGS.includes(value) && !findings.includes(value)) findings.push(value); };
  const summary = { checkType: operation, checkOutcome: outcome(result, provider), cacheHit: result.cacheHit === true };
  for (const list of [result.findings, result.checkFindings])
    for (const finding of Array.isArray(list) ? list.slice(0, 16) : []) add(finding);
  if (result.category === 'nonHumanImages' || result.classification?.category === 'nonHumanImages') add('non_human');
  if (operation === 'safe_search' && result.available === true) {
    for (const category of CATEGORIES) {
      const likelihood = typeof result.categories?.[category] === 'string' ? result.categories[category].toLowerCase() : null;
      if (LIKELIHOODS.includes(likelihood)) add(`${category}_${likelihood}`);
    }
  }
  if (result.available !== false && summary.checkOutcome !== 'skipped') {
    if (typeof result.personDetected === 'boolean') add(result.personDetected ? 'person_detected' : 'no_person_detected');
    if (typeof result.faceDetected === 'boolean') add(result.faceDetected ? 'faces_detected' : 'no_faces_detected');
    if (result.decision === 'person') add('person_detected');
    if (result.decision === 'non_human') { add('no_person_detected'); add('non_human'); }
    if (['modest', 'non_modest', 'uncertain'].includes(result.decision)) add(result.decision);
    for (const category of Array.isArray(result.personCategories) ? result.personCategories.slice(0, 10) : [result.personCategory])
      if (['men', 'women', 'children'].includes(category)) add(category);
    if (result.violationClearlyVisible === true) add('visible_violation');
    if (result.unsupportedViolation === true) add('unsupported_violation');
    if (result.ignoredOutOfFrameUncertainty === true || result.decision === 'modest' &&
        result.visibleAreasDecision === 'compliant' && result.uncertaintyReason === 'out_of_frame_only') add('out_of_frame_ignored');
    if (result.status === 'safety_blocked') add('provider_safety_block');
    if (Number.isFinite(result.confidence)) summary.checkConfidencePct = Math.round(Math.max(0, Math.min(1, result.confidence)) * 100);
    if (Array.isArray(result.persons)) summary.checkPersonCount = Math.min(1000, result.persons.length);
    if (Number.isInteger(result.faceCount) && result.faceCount >= 0) summary.checkFaceCount = Math.min(1000, result.faceCount);
  }
  if (result.status === 'not_configured') add('provider_not_configured');
  const error = String(result.reasonCode || result.errorCode || '').toLowerCase();
  if (CHECK_FINDINGS.includes(error)) add(error);
  else if (['timeouterror', 'aborterror', 'etimedout'].includes(error)) add('request_timeout');
  else if (['resource_exhausted', '429', 'http_429', 'insufficient_quota'].includes(error)) add('quota_exhausted');
  else if (['missing_annotation', 'invalid_response', 'syntaxerror'].includes(error)) add('invalid_response');
  else if (summary.checkOutcome === 'failed') add('request_failed');
  if (result.providerSuspended) add('provider_suspended');
  if (findings.length) summary.checkFindings = findings.slice(0, 16);
  const frame = tracking?.videoBudget;
  if (Number.isInteger(frame?.frameIndex) && frame.frameIndex >= 0 && frame.frameIndex < 90) {
    summary.frameIndex = frame.frameIndex;
    const seconds = frame.timestampSeconds ?? frame.timeSeconds;
    if (typeof seconds === 'number' && Number.isFinite(seconds) && seconds >= 0 && seconds <= 86400)
      summary.frameTimestampMs = Math.round(seconds * 1000);
  }
  return summary;
}

module.exports = { CHECK_TYPES, CHECK_OUTCOMES, CHECK_FINDINGS, moderationCheckSummary };
