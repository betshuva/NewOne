'use strict';
const MODESTY_IMAGE_MESSAGE = 'התמונה נחסמה מטעמי צניעות';
const NON_VIOLATION_CODES = new Set([
  'modesty_uncertain', 'provider_unavailable', 'provider_error', 'uncertainty_review_limit', 'uncertainty_review_disabled',
  'budget_exhausted', 'deadline_exceeded', 'scan_incomplete', 'required_provider_unavailable',
  'provider_not_configured', 'provider_suspended', 'provider_guard_unavailable',
  'credit_balance_exhausted', 'operation_outcome_unknown',
]);
function imageBlockReason(reason, fileType = 'image', blockedBy = null, reasonCode = null) {
  if (fileType !== 'image') return reason;
  // An incomplete check is not evidence of a clothing violation, even if its
  // explanation mentions the modesty stage or a provider's preliminary flag.
  if (NON_VIOLATION_CODES.has(reasonCode) || NON_VIOLATION_CODES.has(blockedBy)) return reason;
  const modestyViolation = ['dualModesty', 'modesty', 'geminiModesty', 'modestyUncertaintyReview'].includes(blockedBy);
  if (!modestyViolation && /לא ודאי|אינ[הו] ודאי|אינן מסכימות|לא ניתן.*(?:לקבוע|לאמת|להשלים)|אינ[הו] זמי[ןנה]|תקלה|שגיאה|מכסת|חריגה.*זמן/.test(String(reason || '')))
    return reason;
  if (modestyViolation ||
      /צניעות|לא צנוע|אינ[וה] צנוע|כללי הלבוש/.test(String(reason || '')))
    return MODESTY_IMAGE_MESSAGE;
  return reason;
}
module.exports = { imageBlockReason, MODESTY_IMAGE_MESSAGE };
