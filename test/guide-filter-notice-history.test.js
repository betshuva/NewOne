'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { formatLegacyGroupFilterNotice, projectGuideFilterNotice } = require('../server/guide-filter-notice');

const GUIDE = '00000000-0000-4000-8000-000000000002';
const VIEWER = '11111111-1111-4111-8111-111111111111';
const OTHER = '22222222-2222-4222-8222-222222222222';
const HEADER = 'בקבוצה ״קבוצת בדיקה״';
const LEGACY = `${HEADER} — נחסם לאביב, מור: תוכן הכולל גברים חסום; נחסם לנאור: סרטונים חסומים`;
const FORMATTED = `${HEADER} נחסם ל:\n• נחסם לאביב, מור: תוכן הכולל גברים חסום\n• נחסם לנאור: סרטונים חסומים`;

test('legacy group notification gets a header and one line per complete stored clause', () => {
  assert.equal(formatLegacyGroupFilterNotice(LEGACY), FORMATTED);
  const single = `${HEADER} — נחסם לאביב: תוכן הכולל גברים חסום`;
  assert.equal(formatLegacyGroupFilterNotice(single),
    `${HEADER} נחסם ל:\n• נחסם לאביב: תוכן הכולל גברים חסום`);
});

test('comma-containing names and omitted-member summaries stay intact', () => {
  const clause = 'נחסם לדני, כהן, אביב ועוד 3 חברים: תמונות אנשים חסומות לפי הגדרות הסינון';
  const result = formatLegacyGroupFilterNotice(`${HEADER} — ${clause}`);
  assert.equal(result, `${HEADER} נחסם ל:\n• ${clause}`);
  assert.equal(result.split('\n').length, 2, 'legacy text cannot establish how many people a comma represents');
  assert.match(result, /ועוד 3 חברים/);
});

test('semicolons within a reason are preserved and only exact clause delimiters split', () => {
  const first = 'נחסם לאביב: סרטונים חסומים; תוכן הכולל גברים חסום';
  const second = 'נחסם למור: תוכן הכולל נשים חסום';
  assert.equal(formatLegacyGroupFilterNotice(`${HEADER} — ${first}; ${second}`),
    `${HEADER} נחסם ל:\n• ${first}\n• ${second}`);
});

test('already multiline, ordinary messages and unknown headers remain byte-for-byte unchanged', () => {
  const unchanged = [FORMATTED, `${HEADER} — נחסם לאביב: סיבה\nשורה שנייה`,
    `${HEADER} — נחסם לאביב: סיבה\rשורה שנייה`, 'נחסם לאביב: סרטונים חסומים',
    `מבוא ${LEGACY}`, 'בקבוצה בדיקה — נחסם לאביב: סיבה',
    'בקבוצה ״בדיקה״ - נחסם לאביב: סיבה', 'בקבוצה ״בדיקה״ — הודעה רגילה',
    'בקבוצה ״שם ״מורכב״״ — נחסם לאביב: סיבה', '', null, undefined];
  for (const text of unchanged) assert.equal(formatLegacyGroupFilterNotice(text), text);
});

test('ambiguous or incomplete clauses preserve the entire original notification', () => {
  const clauses = ['נחסם לאביב', 'נחסם ל: סיבה', 'נחסם ל : סיבה',
    'נחסם לאביב: ', 'נחסם לאביב:    ', 'נחסם לאביב: סיבה: נוספת',
    'נחסם לצוות: משנה: סיבה', 'נחסם לאביב: סיבה; נחסם ל',
    'נחסם לאביב; נחסם למור: סיבה', 'נחסם לאביב: סיבה; נחסם למור'];
  for (const clause of clauses) {
    const text = `${HEADER} — ${clause}`;
    assert.equal(formatLegacyGroupFilterNotice(text), text, clause);
  }
});

function row(extra = {}) {
  return { id: 'notice-id', sender_id: GUIDE, recipient_id: VIEWER,
    type: 'text', body: LEGACY, _guide_filter_notice: true,
    reply_to_id: 'file-id', reply_body: 'תמונה.png',
    created_at: '2026-09-17T12:00:00.000Z', ...extra };
}

test('projection formats only the authenticated recipient guide notice and strips its internal marker', () => {
  const original = Object.freeze(row());
  const result = projectGuideFilterNotice(original, VIEWER, GUIDE);
  const { _guide_filter_notice, ...expected } = original;
  assert.deepEqual(result, { ...expected, body: FORMATTED });
  assert.equal(Object.hasOwn(result, '_guide_filter_notice'), false);
  assert.equal(original.body, LEGACY);
  assert.equal(original._guide_filter_notice, true);
  assert.notEqual(result, original, 'read projection must not mutate database rows');
});

test('foreign senders, foreign recipients, nontext and hidden rows are never reformatted', () => {
  for (const extra of [{ sender_id: OTHER }, { recipient_id: OTHER }, { type: 'image' },
    { filter_hidden: true }, { _guide_filter_notice: false },
    { _guide_filter_notice: 1 }, { _guide_filter_notice: 'true' },
    { _guide_filter_notice: null }, { _guide_filter_notice: undefined }]) {
    const original = Object.freeze(row(extra));
    const { _guide_filter_notice, ...expected } = original;
    const result = projectGuideFilterNotice(original, VIEWER, GUIDE);
    assert.deepEqual(result, expected);
    assert.equal(Object.hasOwn(result, '_guide_filter_notice'), false,
      'the internal marker must be stripped even when formatting is forbidden');
    assert.equal(original.body, LEGACY);
  }
});

test('hidden placeholders and missing metadata remain intact without restoring message content', () => {
  const hidden = Object.freeze(row({ filter_hidden: true, body: null, file_url: null }));
  const hiddenResult = projectGuideFilterNotice(hidden, VIEWER, GUIDE);
  assert.equal(hiddenResult.body, null);
  assert.equal(hiddenResult.file_url, null);
  assert.equal(hiddenResult.filter_hidden, true);
  assert.equal(Object.hasOwn(hiddenResult, '_guide_filter_notice'), false);
  const ordinary = Object.freeze({ id: 'plain', sender_id: GUIDE, recipient_id: VIEWER,
    type: 'text', body: LEGACY });
  assert.deepEqual(projectGuideFilterNotice(ordinary, VIEWER, GUIDE), ordinary);
});

test('projection is idempotent and preserves message identity, ordering and quoted content', () => {
  const original = row();
  const once = projectGuideFilterNotice(original, VIEWER, GUIDE);
  assert.deepEqual(projectGuideFilterNotice(once, VIEWER, GUIDE), once);
  for (const key of ['id', 'sender_id', 'recipient_id', 'type', 'reply_to_id', 'reply_body', 'created_at'])
    assert.equal(once[key], original[key]);
  assert.equal(projectGuideFilterNotice(row({ body: FORMATTED }), VIEWER, GUIDE).body, FORMATTED);
});
