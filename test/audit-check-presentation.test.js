'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { CHECK_TYPE_LABELS, CHECK_OUTCOME_LABELS, FINDING_LABELS,
  checkType, findingLabel, presentAuditCheck } = require('../server/audit-check-presentation');
const { sanitizeAuditDetails } = require('../server/system-audit-catalog');
const { CHECK_TYPES, CHECK_OUTCOMES, CHECK_FINDINGS } = require('../server/moderation-check-summary');

test('every allowed check type, outcome and finding has a localized display label', () => {
  assert.deepEqual(Object.keys(CHECK_TYPE_LABELS), [...CHECK_TYPES]);
  assert.deepEqual(Object.keys(CHECK_OUTCOME_LABELS), [...CHECK_OUTCOMES]);
  for (const checkType of CHECK_TYPES) {
    const row = presentAuditCheck({ details: { checkType, checkOutcome: 'passed' } });
    assert.equal(row.check_type, checkType);
    assert.match(row.checkLabel, /[\u0590-\u05ff]/);
    assert.equal(row.checkResultLabel, CHECK_OUTCOME_LABELS.passed);
  }
  for (const finding of CHECK_FINDINGS) assert.match(findingLabel(finding), /[\u0590-\u05ff]/, finding);
  assert.equal(findingLabel('constructor'), null);
  assert.equal(findingLabel('adult_private'), null);
  assert.equal(findingLabel({ value: 'modest' }), null);
});

test('legacy provider purpose is inferred only for known check events and never invents a passed result', () => {
  const operations = { safe_search: 'safe_search', google_safe_search_reuse: 'safe_search',
    object_localization: 'object_localization', face_detection: 'face_detection',
    person_presence: 'person_presence', modesty: 'modesty', modesty_format_repair: 'modesty_format_repair' };
  for (const kind of ['provider_call_finished', 'scan_cache_used', 'moderation_check_finished']) {
    for (const [operation, expected] of Object.entries(operations)) {
      const original = { kind, status: 'completed', details: { operation, provider: 'google_vision' } };
      const result = presentAuditCheck(original);
      assert.equal(checkType(original), expected);
      assert.equal(result.check_outcome, 'not_recorded');
      assert.equal(result.checkResultLabel, 'תוצאה לא תועדה');
      assert.equal(original.checkLabel, undefined);
    }
  }
  for (const row of [{ action: 'upload_file', status: 'completed' },
    { kind: 'push_provider_result', status: 'completed', details: { operation: 'modesty' } },
    { kind: 'provider_call_finished', details: { operation: 'constructor' } }]) {
    assert.equal(checkType(row), null);
    assert.equal(presentAuditCheck(row), row);
  }
});

test('SafeSearch likelihoods are localized completely without displaying arbitrary findings', () => {
  const details = { checkType: 'safe_search', checkOutcome: 'passed', checkFindings: [
    'adult_very_unlikely', 'racy_unlikely', 'violence_possible', 'medical_likely',
    'spoof_very_likely', 'adult_very_unlikely', '<script>private</script>',
  ] };
  const row = presentAuditCheck({ details });
  for (const finding of ['תוכן למבוגרים: סבירות נמוכה מאוד', 'חשיפה: סבירות נמוכה',
    'אלימות: אפשרי', 'תוכן רפואי: סבירות גבוהה', 'זיוף או שינוי חזותי: סבירות גבוהה מאוד'])
    assert.ok(row.checkResultLabel.includes(finding), finding);
  assert.equal(row.checkResultLabel.split('תוכן למבוגרים:').length, 2);
  assert.doesNotMatch(row.checkResultLabel, /private|script|adult_|very_unlikely/);
  assert.equal(details.checkFindings.length, 7);
});

test('counts, confidence and cached results preserve the actual check outcome', () => {
  const row = presentAuditCheck({ status: 'completed', details: {
    checkType: 'person_presence', checkOutcome: 'blocked',
    checkFindings: ['person_detected', 'women', 'children'], checkPersonCount: 3,
    checkFaceCount: 0, checkConfidencePct: 97, cacheHit: true,
  } });
  assert.equal(row.check_outcome, 'blocked');
  for (const text of [CHECK_OUTCOME_LABELS.blocked, FINDING_LABELS.women,
    FINDING_LABELS.children, 'מספר אנשים: 3', 'מספר פנים: 0', 'רמת ביטחון: 97%', 'מתוצאה שמורה'])
    assert.ok(row.checkResultLabel.includes(text), text);
  const legacy = presentAuditCheck({ kind: 'scan_cache_used', status: 'completed', details: {
    operation: 'modesty', cacheHit: true, checkFindings: ['modest'], checkConfidencePct: 100,
  } });
  assert.equal(legacy.check_outcome, 'not_recorded');
  assert.equal(legacy.checkResultLabel, 'תוצאה לא תועדה · מתוצאה שמורה');
});

test('presentation ignores invalid numeric evidence and caps deduplicated findings', () => {
  for (const invalid of [-1, 0.5, 10001, Infinity, NaN, '2', null, {}, []]) {
    const row = presentAuditCheck({ details: { checkType: 'face_detection', checkOutcome: 'passed',
      checkFaceCount: invalid, checkPersonCount: invalid, checkConfidencePct: invalid } });
    assert.equal(row.checkResultLabel, CHECK_OUTCOME_LABELS.passed);
  }
  assert.equal(presentAuditCheck({ details: { checkType: 'modesty', checkOutcome: 'passed',
    checkConfidencePct: 101 } }).checkResultLabel, CHECK_OUTCOME_LABELS.passed);
  const row = presentAuditCheck({ details: { checkType: 'modesty', checkOutcome: 'passed',
    checkFindings: [...Array(16).fill('modest'), 'non_modest'] } });
  assert.equal(row.checkResultLabel, `${CHECK_OUTCOME_LABELS.passed} · ${FINDING_LABELS.modest}`);
});

test('audit sanitizer retains only bounded typed check fields and safe finding codes', () => {
  const expected = { checkType: 'safe_search', checkOutcome: 'uncertain',
    checkFindings: ['adult_possible', 'request_timeout'], checkConfidencePct: 100,
    checkPersonCount: 0, checkFaceCount: 10000, frameIndex: 89,
    frameTimestampMs: 86400000, auditOnly: true, cacheHit: false };
  assert.deepEqual(sanitizeAuditDetails({ ...expected,
    checkFindings: ['adult_possible', 'adult_possible', 'private provider message',
      'constructor', { code: 'modest' }, 'request_timeout'],
    checkSummary: 'private response', prompt: 'private prompt',
    transcript: 'private speech', rawOutput: { text: 'private output' },
  }), expected);
  const limits = { checkConfidencePct: 100, checkPersonCount: 10000,
    checkFaceCount: 10000, frameIndex: 89, frameTimestampMs: 86400000 };
  for (const [key, max] of Object.entries(limits)) {
    assert.deepEqual(sanitizeAuditDetails({ [key]: 0 }), { [key]: 0 });
    for (const invalid of [-1, 0.5, max + 1, '1', true, null, {}, [], Infinity])
      assert.deepEqual(sanitizeAuditDetails({ [key]: invalid }), {});
  }
  assert.deepEqual(sanitizeAuditDetails({ checkType: 'private_type', checkOutcome: 'completed',
    checkFindings: 'modest', auditOnly: 1, cacheHit: 'true' }), {});
});

test('check sanitization ignores inherited and getter fields and bounds findings before inclusion', () => {
  const details = Object.create({ checkType: 'modesty', checkOutcome: 'passed' });
  Object.defineProperty(details, 'checkFindings', { get() { throw new Error('Getter must not run'); } });
  assert.deepEqual(sanitizeAuditDetails(details), {});
  assert.deepEqual(sanitizeAuditDetails({ checkFindings: [...Array(16).fill('unknown'), 'modest'] }),
    { checkFindings: [] });
  for (const checkType of CHECK_TYPES) assert.equal(sanitizeAuditDetails({ checkType }).checkType, checkType);
  for (const checkOutcome of CHECK_OUTCOMES) assert.equal(sanitizeAuditDetails({ checkOutcome }).checkOutcome, checkOutcome);
});

test('scan previews expose only event-bound private endpoints with validated identifiers', () => {
  const details = { checkType: 'safe_search', checkOutcome: 'passed',
    scanPreviewId: 'be20c6c5-cf1e-408d-a131-c7297d71ec97' };
  const row = presentAuditCheck({ id: '9223372036854775807', details });
  assert.equal(row.checkPreviewUrl, '/api/admin/audit/events/9223372036854775807/preview?size=thumb');
  assert.equal(row.checkPreviewFullUrl, '/api/admin/audit/events/9223372036854775807/preview?size=full');
  for (const id of [undefined, 0, -1, '01', '1/other', '9223372036854775808']) {
    assert.equal(presentAuditCheck({ id, details }).checkPreviewUrl, undefined);
  }
  for (const scanPreviewId of [null, '', 'https://example.com/private.jpg', 'token=secret']) {
    assert.equal(presentAuditCheck({ id: '1', details: { ...details, scanPreviewId } }).checkPreviewUrl, undefined);
  }
  assert.deepEqual(sanitizeAuditDetails({ scanPreviewId: details.scanPreviewId }),
    { scanPreviewId: details.scanPreviewId });
  assert.deepEqual(sanitizeAuditDetails({ scanPreviewId: 'https://example.com/private.jpg' }), {});
});
