'use strict';

// Called only after all explicit safety/modesty checks. An unresolved category
// is retried, never converted into an approval or a final destination rejection.
function imageClassificationOutcome(result) {
  if (result.blocked || result.pending) return result;
  if (result.classification?.uncertain === true || !result.classification?.category) {
    return { ...result, pending: true,
      reason: 'סיווג התמונה אינו ודאי; מתבצעת בדיקת אימות נוספת לפני השליחה' };
  }
  return { ...result, blocked: false, blockedBy: null };
}
module.exports = { imageClassificationOutcome };
