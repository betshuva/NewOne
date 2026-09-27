'use strict';

const CHECK_TYPE_LABELS = Object.freeze({
  safe_search: 'תוכן למבוגרים, חשיפה, אלימות, רפואה וזיוף',
  object_localization: 'איתור אנשים באמצעות זיהוי אובייקטים',
  face_detection: 'איתור וספירת פנים',
  person_presence: 'אימות נוכחות אנשים וסיווג גברים, נשים וילדים',
  modesty: 'בדיקת צניעות הלבוש',
  modesty_format_repair: 'פענוח חוזר של תשובת בדיקת הצניעות',
  local_safety: 'בדיקת בטיחות מקומית להשוואה',
  local_explicit_content: 'בדיקה מקומית של עירום ותוכן מיני מפורש',
  local_classification: 'סיווג מקומי של אנשים וסוג התמונה',
  video_frames: 'בדיקת התמונות שנדגמו מהסרטון',
  audio_transcription: 'פענוח הדיבור ובדיקת תוכן ההקלטה',
  document_content: 'בדיקת הטקסט והתמונות במסמך',
  media_moderation: 'בדיקת תוכן הקובץ',
});
const CHECK_OUTCOME_LABELS = Object.freeze({
  passed: 'הבדיקה הושלמה', blocked: 'נמצא ממצא לחסימה',
  uncertain: 'תוצאה לא ודאית', failed: 'הבדיקה נכשלה', stopped: 'הבדיקה נעצרה',
  skipped: 'הבדיקה לא בוצעה', not_recorded: 'תוצאה לא תועדה',
});
const FINDING_LABELS = Object.freeze({
  person_detected: 'זוהה אדם', no_person_detected: 'לא זוהה אדם',
  faces_detected: 'זוהו פנים', no_faces_detected: 'לא זוהו פנים',
  men: 'גברים', women: 'נשים', children: 'ילדים', non_human: 'ללא אנשים',
  modest: 'לבוש צנוע', non_modest: 'לבוש לא צנוע', uncertain: 'לא ניתן לקבוע בוודאות',
  visible_violation: 'ממצא הלבוש נראה בבירור', unsupported_violation: 'אין ממצא ברור התומך בחסימה',
  provider_safety_block: 'הספק חסם את הבדיקה מטעמי בטיחות',
  credit_balance_exhausted: 'אין יתרת קרדיט אצל הספק', quota_exhausted: 'מכסת הספק מוצתה',
  request_timeout: 'זמן ההמתנה לספק הסתיים', request_failed: 'הבקשה לספק נכשלה',
  invalid_response: 'תשובת הספק לא ניתנת לפענוח', provider_not_configured: 'הספק אינו מוגדר',
  provider_suspended: 'הספק מושהה', provider_guard_unavailable: 'לא ניתן לאמת את מכסת הבדיקות',
  provider_disabled: 'הספק כבוי בהגדרות המערכת',
  fallback_review_used: 'המשך הבדיקה הועבר ל־Gemini',
  out_of_frame_ignored: 'נבדקו החלקים הנראים; חלקים מחוץ לתמונה אינם סיבה לחסימה',
  budget_exhausted: 'מכסת הבדיקות לסרטון מוצתה', deadline_exceeded: 'זמן הסריקה המרבי הסתיים',
  lease_lost: 'הסריקה מנוהלת כעת בתהליך אחר', operation_outcome_unknown: 'תוצאת בקשה קודמת אינה ידועה',
  speech_detected: 'זוהה דיבור', no_speech_detected: 'לא זוהה דיבור',
  harmful_text: 'זוהה תוכן מילולי אסור', comparison_only: 'להשוואה בלבד, ללא החלטת חסימה',
});
const SAFE_SEARCH_LABELS = { adult: 'תוכן למבוגרים', racy: 'חשיפה', violence: 'אלימות',
  medical: 'תוכן רפואי', spoof: 'זיוף או שינוי חזותי' };
const LIKELIHOOD_LABELS = { unknown: 'לא ידוע', very_unlikely: 'סבירות נמוכה מאוד',
  unlikely: 'סבירות נמוכה', possible: 'אפשרי', likely: 'סבירות גבוהה', very_likely: 'סבירות גבוהה מאוד' };
const CHECK_KINDS = ['provider_call_finished', 'scan_cache_used', 'moderation_check_finished'];
const LEGACY_OPERATIONS = { safe_search: 'safe_search', google_safe_search_reuse: 'safe_search',
  object_localization: 'object_localization', face_detection: 'face_detection',
  person_presence: 'person_presence', modesty: 'modesty', modesty_format_repair: 'modesty_format_repair' };
const own = (map, key) => typeof key === 'string' && Object.hasOwn(map, key);

function checkType(row) {
  const details = row?.details || {};
  if (own(CHECK_TYPE_LABELS, details.checkType)) return details.checkType;
  if (CHECK_KINDS.includes(row?.kind) && own(LEGACY_OPERATIONS, details.operation))
    return LEGACY_OPERATIONS[details.operation];
  return null;
}

function findingLabel(value) {
  if (own(FINDING_LABELS, value)) return FINDING_LABELS[value];
  if (typeof value !== 'string') return null;
  const match = /^(adult|racy|violence|medical|spoof)_(unknown|very_unlikely|unlikely|possible|likely|very_likely)$/.exec(value);
  return match ? `${SAFE_SEARCH_LABELS[match[1]]}: ${LIKELIHOOD_LABELS[match[2]]}` : null;
}

function presentAuditCheck(row) {
  const type = checkType(row);
  if (!type) return row;
  const details = row.details || {};
  const outcome = own(CHECK_OUTCOME_LABELS, details.checkOutcome) ? details.checkOutcome : 'not_recorded';
  const parts = [CHECK_OUTCOME_LABELS[outcome]];
  if (outcome !== 'not_recorded') {
    const findings = Array.isArray(details.checkFindings) ? details.checkFindings.slice(0, 16) : [];
    parts.push(...[...new Set(findings)].map(findingLabel).filter(Boolean));
    for (const [key, label] of [['checkPersonCount', 'מספר אנשים'], ['checkFaceCount', 'מספר פנים']]) {
      if (Number.isSafeInteger(details[key]) && details[key] >= 0 && details[key] <= 10000)
        parts.push(`${label}: ${details[key]}`);
    }
    if (Number.isInteger(details.checkConfidencePct) && details.checkConfidencePct >= 0 && details.checkConfidencePct <= 100)
      parts.push(`רמת ביטחון: ${details.checkConfidencePct}%`);
  }
  if (details.cacheHit === true) parts.push('מתוצאה שמורה');
  const hasPreview = typeof details.scanPreviewId === 'string' &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(details.scanPreviewId) &&
    /^[1-9]\d{0,18}$/.test(String(row.id || '')) && BigInt(row.id) <= 9223372036854775807n;
  return { ...row, check_type: type, check_outcome: outcome,
    checkLabel: CHECK_TYPE_LABELS[type], checkResultLabel: parts.join(' · '),
    ...(hasPreview ? {
      checkPreviewUrl: `/api/admin/audit/events/${row.id}/preview?size=thumb`,
      checkPreviewFullUrl: `/api/admin/audit/events/${row.id}/preview?size=full`,
    } : {}) };
}

// All interpolated codes below come from fixed internal maps, never a request.
const literals = values => values.map(value => `'${value}'`).join(',');
function checkTypeSql(alias) {
  return `(CASE WHEN ${alias}.details->>'checkType' IN (${literals(Object.keys(CHECK_TYPE_LABELS))})
    THEN ${alias}.details->>'checkType' WHEN ${alias}.kind IN (${literals(CHECK_KINDS)})
    THEN CASE ${alias}.details->>'operation' ${Object.entries(LEGACY_OPERATIONS)
      .map(([operation, type]) => `WHEN '${operation}' THEN '${type}'`).join(' ')} END END)`;
}
function checkOutcomeSql(alias) {
  return `(CASE WHEN ${checkTypeSql(alias)} IS NOT NULL THEN
    CASE WHEN ${alias}.details->>'checkOutcome' IN (${literals(Object.keys(CHECK_OUTCOME_LABELS))})
      THEN ${alias}.details->>'checkOutcome' ELSE 'not_recorded' END END)`;
}

module.exports = { CHECK_TYPE_LABELS, CHECK_OUTCOME_LABELS, FINDING_LABELS,
  checkType, findingLabel, presentAuditCheck, checkTypeSql, checkOutcomeSql };
