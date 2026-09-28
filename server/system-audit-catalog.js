'use strict';

const { CHECK_TYPES, CHECK_OUTCOMES, CHECK_FINDINGS } = require('./moderation-check-summary');

const COVERAGE = Object.freeze([
  {
    code: 'activity_log', label: 'יומן פעילות היישום', status: 'partial',
    description: 'אירועים חדשים מנקודות הרישום הקיימות מועתקים ליומן המערכת. הכיסוי חלקי ומתחיל בהפעלת התיעוד; לא נוצרים קישורים סיבתיים לאירועים ישנים.',
  },
  {
    code: 'filter_event', label: 'תיעוד הסינון', status: 'partial',
    description: 'אירועי סינון ותמונות מצב חדשים עם שיוך מפורש לפעולה מועתקים ליומן המערכת. הכיסוי חלקי; שמירה אינה מוכיחה הצגה ולא מסיקים קשרים סיבתיים היסטוריים.',
  },
  {
    code: 'client_report', label: 'דיווח הלקוח', status: 'reported',
    description: 'דיווחי תצוגה זמינים ביומן הסינון הקיים; אינם משויכים כרגע לשרשרת הפעולות ביומן זה ואינם הוכחת הצגה.',
  },
  {
    code: 'system_audit', label: 'יומן המערכת', status: 'instrumented',
    description: 'אירועים שנרשמים במפורש מאז הפעלת יומן המערכת. דיווחי ספקים נרשמים ככל האפשר; אין תור התראות עמיד, וקבלת בקשה אצל ספק אינה הוכחה למסירתה.',
  },
  {
    code: 'reserved', label: 'פעולה שמורה', status: 'unavailable',
    description: 'רשומה בקטלוג בלבד. אין לה כרגע מנגנון רישום או כיסוי היסטורי מוצהר.',
  },
].map(Object.freeze));

const STATUSES = Object.freeze([
  { code: 'running', label: 'בתהליך' },
  { code: 'pending', label: 'ממתין' },
  { code: 'queued', label: 'בתור' },
  { code: 'completed', label: 'הושלם' },
  { code: 'succeeded', label: 'הצליח' },
  { code: 'failed', label: 'נכשל' },
  { code: 'blocked', label: 'נחסם' },
  { code: 'rejected', label: 'נדחה' },
  { code: 'cancelled', label: 'בוטל' },
  { code: 'partial', label: 'חלקי' },
  { code: 'skipped', label: 'דולג' },
  { code: 'observed', label: 'תועד' },
].map(Object.freeze));

const ACTION_GROUPS = {
  authentication: [
    ['register', 'הרשמה'], ['login', 'כניסה לחשבון'], ['google_login', 'כניסה באמצעות גוגל'],
    ['google_register', 'הרשמה באמצעות גוגל'], ['otp_login', 'כניסה באמצעות קוד חד פעמי'],
    ['link_phone', 'קישור טלפון'], ['connect', 'חיבור לשרת'], ['disconnect', 'ניתוק מהשרת'],
  ],
  messaging: [
    ['send_message', 'שליחת הודעה'], ['send_group_message', 'שליחת הודעה לקבוצה'],
    ['send_file', 'שליחת קובץ'], ['send_file_delayed', 'מסירת קובץ שהמתין בתור'],
    ['send_group_file_delayed', 'מסירת קובץ לקבוצה לאחר המתנה בתור'],
    ['group_file_delivery_rejected', 'דחיית מסירת קובץ לקבוצה'],
    ['blocked_chat_text', 'חסימת טקסט בשיחה'], ['send_system_message', 'שליחת הודעת מערכת'],
  ],
  media: [
    ['save_media_progress', 'שמירת נקודת המשך בהקלטה או בווידאו'],
    ['repair_audio_type', 'תיקון סיווג קובץ קול'],
    ['upload_file', 'העלאת קובץ'], ['upload_pending', 'הוספת העלאה לתור הסריקה'],
    ['blocked_upload', 'חסימת העלאה'], ['blocked_upload_delayed', 'חסימת העלאה שהמתינה בתור'],
    ['blocked_listing_image', 'חסימת תמונה במודעה'],
    ['blocked_by_recipient_filter', 'חסימת מדיה לפי סינון הנמען'],
    ['media_full_rescan_approved', 'אישור מדיה לאחר סריקה מלאה חוזרת'],
    ['media_full_rescan_rejected', 'דחיית מדיה לאחר סריקה מלאה חוזרת'],
    ['media_classification_appealed', 'ערעור על סיווג מדיה'],
    ['delete_own_media', 'מחיקת מדיה אישית'], ['delete_own_media_selection', 'מחיקת מדיה אישית שנבחרה'],
    ['profile_photo_from_message', 'הגדרת תמונת פרופיל מתוך הודעה'],
    ['blocked_audio_purged', 'מחיקה סופית של שמע חסום'], ['blocked_image_purged', 'מחיקה סופית של תמונה חסומה'],
    ['pending_image_scan_expired', 'פקיעת המתנה לסריקת תמונה'],
    ['safe_local_media_release', 'פינוי מדיה מקומית מאושרת'],
  ],
  backup: [
    ['enable_automatic_backup', 'הפעלת גיבוי אוטומטי'],
    ['disable_automatic_backup', 'כיבוי גיבוי אוטומטי'],
    ['enable_automatic_backup_after_google_login', 'הפעלת גיבוי אוטומטי לאחר כניסה בגוגל'],
    ['connect_personal_drive', 'חיבור כונן אישי'],
    ['disconnect_personal_drive', 'ניתוק כונן אישי'],
    ['manual_encrypted_backup', 'יצירת גיבוי מוצפן ידני'],
    ['manual_encrypted_backup_failed', 'כישלון גיבוי מוצפן ידני'],
    ['verify_encrypted_restore', 'אימות שחזור מוצפן'],
    ['verify_encrypted_restore_failed', 'כישלון אימות שחזור מוצפן'],
    ['automatic_encrypted_backup', 'יצירת גיבוי מוצפן אוטומטי'],
    ['automatic_restore_verification', 'אימות שחזור אוטומטי'],
  ],
  account: [
    ['block_user', 'חסימת משתמש'], ['unblock_user', 'ביטול חסימת משתמש'],
    ['save_shared_contact_details', 'שמירת פרטי איש קשר ששותפו'],
    ['update_preferences', 'עדכון העדפות'], ['complete_birth_date', 'השלמת תאריך לידה'],
    ['update_profile', 'עדכון פרופיל'],
  ],
  groups: [
    ['create_group', 'יצירת קבוצה'], ['leave_group', 'עזיבת קבוצה'],
    ['delete_group', 'מחיקת קבוצה'], ['rename_group', 'שינוי שם קבוצה'],
  ],
  education: [
    ['education_form_create', 'יצירת טופס חינוכי'],
    ['education_response_change_request', 'בקשה לשינוי תשובה בטופס חינוכי'],
    ['education_response_change_decision', 'החלטה על שינוי תשובה בטופס חינוכי'],
    ['education_form_respond', 'מענה לטופס חינוכי'],
    ['education_form_remind', 'שליחת תזכורת למילוי טופס חינוכי'],
    ['education_form_assign_new_members', 'שיוך טופס חינוכי לחברים חדשים'],
    ['education_form_republish', 'פרסום חוזר של טופס חינוכי'],
  ],
  support: [
    ['submit_report', 'שליחת דיווח'], ['support_issue_created', 'פתיחת פניית תמיכה'],
    ['support_issue_updated', 'עדכון פניית תמיכה'],
  ],
  administration: [
    ['admin_google_play_description_update', 'עדכון התיאור בחנות גוגל'],
    ['admin_edit', 'עריכת רשומה'], ['admin_delete', 'מחיקת רשומה'],
    ['admin_moderation_action', 'ביצוע פעולת פיקוח'], ['admin_delete_user', 'מחיקת משתמש'],
    ['moderation_ground_truth_saved', 'שמירת סיווג ידני מאומת'],
  ],
  listings: [['edit_listing', 'עריכת מודעה']],
};

const FILTER_ACTIONS = [
  ['filter_baseline', 'תיעוד מצב סינון התחלתי'], ['filter_changed', 'שינוי סינון'],
  ['delivery_persisted', 'שמירת מסירה'], ['delivery_blocked_persisted', 'שמירת חסימת מסירה'],
  ['image_classified', 'תיעוד סיווג מדיה'],
  ['decision_allowed', 'אישור לפי החלטת סינון'], ['decision_blocked', 'חסימה לפי החלטת סינון'],
  ['history_action', 'ביצוע פעולה במדיה מההיסטוריה'], ['history_image_action', 'ביצוע פעולה בתמונה מההיסטוריה'],
  ['history_cleanup', 'ניקוי מדיה מההיסטוריה'], ['history_restored', 'שחזור מדיה מההיסטוריה'],
];

const FRAMEWORK_ACTIONS = [
  ['dispatch_context','messaging','פרטי שליחת הודעה'],
  ['dispatch_outcome','messaging','תוצאת שליחת הודעה'],
  ['api_mutation', 'account', 'עדכון דרך ממשק היישום'],
  ['delete_account', 'account', 'מחיקת חשבון'],
  ['delete_account_data', 'account', 'מחיקת נתוני חשבון'],
  ['message_reaction', 'messaging', 'תגובה להודעה'],
  ['socket_handler_failed', 'system', 'כישלון טיפול באירוע חיבור'],
  ['report_message_read', 'messaging', 'דיווח על קריאת הודעה'],
  ['manage_message_request', 'messaging', 'ניהול בקשת הודעה'],
  ['delete_message', 'messaging', 'מחיקת הודעה'],
  ['edit_message', 'messaging', 'עריכת הודעה'],
  ['manage_contacts', 'account', 'ניהול אנשי קשר'],
  ['manage_backup', 'backup', 'ניהול גיבוי'],
  ['manage_calendar', 'calendar', 'ניהול לוח השנה'],
  ['manage_education', 'education', 'ניהול פעולות חינוך'],
  ['manage_groups', 'groups', 'ניהול קבוצות'],
  ['manage_listings', 'listings', 'ניהול מודעות'],
  ['manage_media', 'media', 'ניהול מדיה'],
  ['change_location', 'account', 'שינוי מיקום'],
  ['manage_invites', 'account', 'ניהול הזמנות'],
  ['manage_support', 'support', 'ניהול פניות תמיכה'],
  ['register_device', 'account', 'רישום מכשיר'],
  ['operation_started', 'system', 'תחילת פעולה'],
  ['http_response', 'system', 'תשובת השרת לבקשה'],
  ['http_connection_closed', 'system', 'סגירת חיבור הבקשה'],
  ['request_completed', 'system', 'השלמת בקשה'],
  ['request_failed', 'system', 'כישלון בקשה'],
  ['request_aborted', 'system', 'ביטול בקשה'],
  ['upload_context', 'media', 'פרטי המדיה והנמען'],
  ['blob_upload_started', 'media', 'תחילת העלאה לאחסון'],
  ['blob_upload_finished', 'media', 'העלאה לאחסון הסתיימה'],
  ['media_stored', 'media', 'שמירת מדיה'],
  ['media_moderation_changed', 'media', 'שינוי מצב בדיקת המדיה'],
  ['scan_queued', 'media', 'הוספת סריקת מדיה לתור'],
  ['scan_attempt_started', 'media', 'תחילת ניסיון לסריקת מדיה'],
  ['scan_queue_removed', 'media', 'הסרת סריקת מדיה מהתור'],
  ['scan_workflow_finished', 'media', 'סיום תהליך הסריקה'],
  ['scan_waiting', 'media', 'המתנה להמשך סריקה'],
  ['scan_attempt_failed', 'media', 'כישלון ניסיון סריקה'],
  ['scan_cache_used', 'media', 'שימוש בתוצאת סריקה שמורה'],
  ['media_reused', 'media', 'שימוש חוזר במדיה קיימת'],
  ['provider_call_finished', 'system', 'סיום קריאה לספק'],
  ['moderation_check_finished', 'media', 'תוצאת בדיקת תוכן'],
  ['push_provider_result', 'messaging', 'תוצאת בקשת התראה לספק'],
  ['push_skipped', 'messaging', 'דילוג על שליחת התראה'],
  ['push_failed', 'messaging', 'כישלון שליחת התראה'],
  ['message_retry_reused', 'messaging', 'שימוש בהודעה קיימת בניסיון חוזר'],
  ['message_persisted', 'messaging', 'שמירת הודעה'],
  ['message_delivery_state_changed', 'messaging', 'שינוי מצב מסירת הודעה'],
  ['server_message_status_changed', 'messaging', 'שינוי מצב הודעה בשרת'],
  ['contact_request_pending', 'account', 'יצירת בקשת קשר ממתינה'],
  ['contact_request_removed', 'account', 'בקשת הודעה הוסרה'],
  ['message_request_accepted', 'messaging', 'בקשת הודעה אושרה'],
  ['contact_request_status_changed', 'account', 'שינוי מצב בקשת קשר'],
];

const ACTION_CATALOG = Object.freeze([
  ...Object.entries(ACTION_GROUPS).flatMap(([category, actions]) =>
    actions.map(([action, label]) => ({ action, category, label, coverage: 'activity_log' }))),
  ...FILTER_ACTIONS.map(([action, label]) => ({ action, category: 'filter', label, coverage: 'filter_event' })),
  ...FRAMEWORK_ACTIONS.map(([action, category, label]) => ({ action, category, label, coverage: 'system_audit' })),
  { action: 'client_displayed', category: 'filter', label: 'דיווח הלקוח על הצגת מדיה', coverage: 'client_report' },
  { action: 'client_hidden', category: 'filter', label: 'דיווח הלקוח על הסתרת מדיה', coverage: 'client_report' },
  { action: 'filter_change', category: 'filter', label: 'שינוי סינון', coverage: 'system_audit' },
  { action: 'admin_action', category: 'administration', label: 'פעולת מנהל', coverage: 'system_audit' },
  { action: 'audit_export', category: 'administration', label: 'ייצוא רשומות היומן', coverage: 'system_audit' },
  { action: 'audit_delete_operation', category: 'administration', label: 'מחיקת פעולה מיומן המערכת', coverage: 'system_audit' },
  { action: 'audit_delete_records', category: 'administration', label: 'מחיקת רשומות מיומן המערכת', coverage: 'system_audit' },
  { action: 'audit_delete_event', category: 'administration', label: 'מחיקת פעולת משנה מיומן המערכת', coverage: 'system_audit' },
].map(row => Object.freeze({ ...row, code: row.action })));

const ACTION_BY_KEY = new Map(ACTION_CATALOG.map(row => [row.action, row]));
const EVENT_KIND_LABELS = Object.freeze({
  ...Object.fromEntries(ACTION_CATALOG.map(row => [row.action, row.label])),
  message_persisted:'הודעה נשמרה בשרת',delivery_persisted:'הודעה נשמרה בשרת',
  operation_started:'הפעולה החלה',operation_completed:'הפעולה הושלמה',operation_failed:'הפעולה נכשלה',
  client_displayed:'דיווח תצוגה מהמכשיר',media_stored:'מדיה נשמרה בשרת',
  media_moderation_changed:'מצב סינון המדיה עודכן',scan_queued:'סריקה נוספה לתור',
  scan_attempt_started:'ניסיון סריקה החל',scan_waiting:'סריקה ממתינה',scan_attempt_failed:'ניסיון סריקה נכשל',
  scan_workflow_finished:'תהליך הסריקה הסתיים',scan_queue_removed:'רשומת הסריקה הוסרה מהתור',
  http_response:'תגובת שרת לבקשה',http_connection_closed:'חיבור הבקשה נסגר',
  provider_call_finished:'קריאה לספק הסתיימה',scan_cache_used:'תוצאת סריקה מהמטמון',
  moderation_check_finished:'תוצאת בדיקת תוכן',
  push_provider_result:'תשובת ספק ההתראות',push_skipped:'שליחת התראה דולגה',
  message_retry_reused:'ניסיון חוזר השתמש בהודעה קיימת',server_message_status_changed:'מצב הודעה בשרת עודכן',
  message_delivery_state_changed:'מצב מסירת הודעה עודכן',contact_request_pending:'בקשת קשר ממתינה',
  contact_request_status_changed:'מצב בקשת קשר עודכן',
});
const CATEGORIES = Object.freeze([
  { code: 'authentication', label: 'הזדהות' },
  { code: 'messaging', label: 'הודעות' },
  { code: 'media', label: 'מדיה' },
  { code: 'backup', label: 'גיבוי' },
  { code: 'account', label: 'חשבון' },
  { code: 'groups', label: 'קבוצות' },
  { code: 'education', label: 'חינוך' },
  { code: 'calendar', label: 'לוח שנה' },
  { code: 'support', label: 'תמיכה' },
  { code: 'administration', label: 'ניהול' },
  { code: 'listings', label: 'מודעות' },
  { code: 'filter', label: 'סינון' },
  { code: 'system', label: 'מערכת' },
  { code: 'other', label: 'אחר' },
].map(Object.freeze));

function normalizeAction(action) {
  return typeof action === 'string' && /^[a-z][a-z0-9_]{0,79}$/.test(action) ? action : null;
}

function lookupAction(action) {
  const key = normalizeAction(action);
  return key ? ACTION_BY_KEY.get(key) || null : null;
}

const FILTER_CHANGE_KEYS = Object.freeze([
  'beforeText', 'afterText', 'beforeImage', 'afterImage', 'beforeVideo', 'afterVideo',
  'beforeAudio', 'afterAudio', 'beforeDocument', 'afterDocument',
  'beforeMen', 'afterMen', 'beforeWomen', 'afterWomen', 'beforeChildren', 'afterChildren',
  'beforeNonHumanImages', 'afterNonHumanImages', 'beforeEnforceGeneralFilter', 'afterEnforceGeneralFilter',
]);

const SAFE_DETAILS_KEYS = Object.freeze([
  'dispatchBody','dispatchFileName','dispatchReason',
  'reasonCode', 'blockedBy', 'messageType', 'fileType', 'mimeType', 'fileSize', 'maxBytes', 'clientReported',
  'durationMs', 'attempt', 'affectedCount', 'recipientCount', 'deliveredCount',
  'blockedCount', 'cacheHit', 'workflow', 'provider', 'model', 'operation', 'code',
  'policyRevisionId', 'providerCallId', 'storedFileId', 'messageId', 'requestId',
  'clientMessageId', 'groupId', 'recipientId',
  'moderationStatus', 'previousStatus', 'nextStatus', 'queueId', 'sourceFileId',
  'rootEventId', 'eventCount', 'truncated', 'count', 'byteCount', 'memberCount', 'scanAttempt',
  'acceptedCount', 'failedCount',
  'frameCount', 'providerCallsUsed', 'providerCallsLimit',
  'googleVisionCallsUsed', 'googleVisionCallsLimit', 'openAICallsUsed', 'openAICallsLimit',
  'geminiCallsUsed', 'geminiCallsLimit',
  'httpRoute', 'httpMethod',
  'mediaType', 'captureKind', 'recipientType',
  'auditOperationId', 'auditEventId',
  'checkType', 'checkOutcome', 'checkFindings', 'checkConfidencePct',
  'checkPersonCount', 'checkFaceCount', 'frameIndex', 'frameTimestampMs', 'auditOnly', 'scanPreviewId',
  ...FILTER_CHANGE_KEYS,
]);

const NUMERIC_KEYS = new Set([
  'fileSize', 'maxBytes', 'durationMs', 'attempt', 'affectedCount', 'recipientCount', 'deliveredCount', 'blockedCount',
  'eventCount', 'count', 'byteCount', 'memberCount', 'scanAttempt',
  'acceptedCount', 'failedCount',
  'frameCount', 'providerCallsUsed', 'providerCallsLimit',
  'googleVisionCallsUsed', 'googleVisionCallsLimit', 'openAICallsUsed', 'openAICallsLimit',
  'geminiCallsUsed', 'geminiCallsLimit',
]);
const IDENTIFIER_KEYS = new Set([
  'policyRevisionId', 'providerCallId', 'storedFileId', 'messageId', 'requestId',
  'clientMessageId', 'groupId', 'recipientId',
  'queueId', 'sourceFileId', 'rootEventId',
  'auditOperationId',
]);
const BOOLEAN_KEYS = new Set(['cacheHit', 'truncated', 'auditOnly', 'clientReported', ...FILTER_CHANGE_KEYS]);
const CHECK_NUMERIC_LIMITS = { checkConfidencePct: 100, checkPersonCount: 10000,
  checkFaceCount: 10000, frameIndex: 89, frameTimestampMs: 86400000 };
const STATUS_KEYS = new Set(['moderationStatus', 'previousStatus', 'nextStatus']);
const DETAIL_STATUSES = new Set([
  ...STATUSES.map(row => row.code),
  'approved', 'accepted', 'declined', 'delivered', 'read', 'sent', 'expired', 'removed', 'stopped',
]);
const MEDIA_TYPES = new Set([
  'text', 'image', 'video', 'audio', 'voice', 'document', 'file', 'sticker', 'gif',
  'location', 'contact', 'system', 'poll', 'application', 'other', 'unknown',
]);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SENSITIVE_VALUE = /(?:bearer|password|passwd|secret|token|api[_-]?key)|^(?:sk|pk)[_-]|^eyJ/i;

function safeString(key, value) {
  if(key==='dispatchBody'||key==='dispatchFileName')return typeof value==='string'&&value.length<=12000&&/^enc:v1:[A-Za-z0-9+/=]+:[A-Za-z0-9+/=]+:[A-Za-z0-9+/=]*$/.test(value);
  if(key==='dispatchReason')return typeof value==='string'&&value.length>0&&value.length<=500;
  if (key === 'scanPreviewId') return typeof value === 'string' && UUID.test(value);
  if (key === 'checkType') return CHECK_TYPES.includes(value);
  if (key === 'checkOutcome') return CHECK_OUTCOMES.includes(value);
  if (key === 'httpRoute') return typeof value === 'string' && /^\/api\/[A-Za-z0-9_:/-]{1,150}$/.test(value);
  if (key === 'httpMethod') return ['POST', 'PUT', 'PATCH', 'DELETE'].includes(value);
  if (key === 'mediaType') return ['video', 'image', 'audio', 'document'].includes(value);
  if (key === 'captureKind') return ['camera_video', 'camera_image', 'microphone'].includes(value);
  if (key === 'recipientType') return ['user', 'group'].includes(value);
  if (key === 'auditEventId') return typeof value==='string' && /^[1-9]\d{0,18}$/.test(value) && BigInt(value)<=9223372036854775807n;
  if (typeof value !== 'string' || !value || value.length > 128 || value !== value.trim()) return false;
  if (SENSITIVE_VALUE.test(value) || /[\s@\\?#=&%]/.test(value)) return false;
  // Reject likely phone numbers while preserving UUIDs and short revision IDs.
  if (!UUID.test(value) && /^[+\d().-]+$/.test(value) && value.replace(/\D/g, '').length >= 7) return false;
  if (IDENTIFIER_KEYS.has(key)) return /^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/.test(value);
  if (STATUS_KEYS.has(key)) return DETAIL_STATUSES.has(value);
  if (key === 'messageType' || key === 'fileType') return MEDIA_TYPES.has(value);
  if (key === 'mimeType') return value.length <= 100 && /^(?:application|audio|font|image|text|video)\/[A-Za-z0-9][A-Za-z0-9.+-]{0,79}$/.test(value);
  return value.length <= 80 && /^[A-Za-z][A-Za-z0-9_.-]{0,79}$/.test(value) && !value.includes('..');
}

function sanitizeAuditDetails(details) {
  if (!details || typeof details !== 'object' || Array.isArray(details)) return {};
  const clean = {};
  for (const key of SAFE_DETAILS_KEYS) {
    const descriptor = Object.getOwnPropertyDescriptor(details, key);
    if (!descriptor || !Object.prototype.hasOwnProperty.call(descriptor, 'value')) continue;
    const value = descriptor.value;
    if (key === 'checkFindings') {
      if (Array.isArray(value)) clean[key] = [...new Set(value.slice(0, 16)
        .filter(item => typeof item === 'string' && CHECK_FINDINGS.includes(item)))];
    } else if (Object.hasOwn(CHECK_NUMERIC_LIMITS, key)) {
      if (Number.isInteger(value) && value >= 0 && value <= CHECK_NUMERIC_LIMITS[key]) clean[key] = value;
    } else if (NUMERIC_KEYS.has(key)) {
      if (typeof value === 'number' && Number.isSafeInteger(value) && value >= 0) clean[key] = value;
    } else if (BOOLEAN_KEYS.has(key)) {
      if (typeof value === 'boolean') clean[key] = value;
    } else if (safeString(key, value)) {
      clean[key] = value;
    }
  }
  return clean;
}

module.exports = {
  ACTION_CATALOG,
  ACTION_BY_KEY,
  EVENT_KIND_LABELS,
  COVERAGE,
  STATUSES,
  CATEGORIES,
  SAFE_DETAILS_KEYS,
  normalizeAction,
  lookupAction,
  sanitizeAuditDetails,
};
