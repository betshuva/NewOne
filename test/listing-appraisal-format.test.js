'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  briefListingAnswer, formatListingAppraisal, listingReplyWithoutComparison,
} = require('../server/listing-answer-format');

function assertBriefAppraisal(answer) {
  assert.ok(answer.length <= 800, `${answer.length} characters`);
  assert.ok(answer.split(/\s+/).length <= 90, `${answer.split(/\s+/).length} words`);
  assert.match(answer, /\nבדוק: 1\. .+\. 2\. .+\.$/u);
  assert.doesNotMatch(answer, /(?:^|\s)3\.\s/u);
}

test('structured appraisal retains the conclusion and only the first two checks', () => {
  const answer = formatListingAppraisal({
    conclusion: '70,000 ש״ח עשוי להיות מחיר סביר, אך בלי זיהוי הגרסה אין השוואה מספקת.',
    checks: ['גרסת נוסעים או מסחרית ברישיון', 'מנוע וגיר בבדיקה מקצועית', 'צמיגים'],
  });
  assert.match(answer, /70,000/);
  assert.match(answer, /בלי זיהוי הגרסה אין השוואה מספקת/);
  assert.match(answer, /גרסת נוסעים או מסחרית ברישיון/);
  assert.match(answer, /מנוע וגיר בבדיקה מקצועית/);
  assert.doesNotMatch(answer, /צמיגים/);
  assertBriefAppraisal(answer);
});

test('a substantive appraisal retains its comparison rationale and qualification with two focused checks', () => {
  // Synthetic provider output: the formatter must retain the reasoning and its
  // limits together, rather than replace a useful assessment with a fallback.
  const conclusion = 'המחיר המבוקש, 70,000 ש״ח, נמצא בטווח ההצעות שנבדקו לרכבים מאותו שנתון, אך ההשוואה חלקית משום שהגרסה במודעה אינה מצוינת. הקילומטראז׳ המוצהר, 138,000 ק״מ, עשוי להשפיע על ההתאמה להשוואות רק לאחר אימות בתיעוד הטיפולים. לפני קביעה שהמחיר כדאי צריך לדעת אם מדובר בגרסת נוסעים או מסחרית ובמצב מכני דומה.';
  const checks = ['גרסת הרכב ברישיון מול הגרסאות ששימשו להשוואה',
    'מצב המנוע והגיר בבדיקה מקצועית לפני החלטה'];
  const answer = formatListingAppraisal(JSON.stringify({ conclusion, checks }));
  assert.ok(answer.startsWith(`${conclusion}\n`));
  assert.match(answer, /נמצא בטווח ההצעות שנבדקו לרכבים מאותו שנתון/);
  assert.match(answer, /ההשוואה חלקית משום שהגרסה במודעה אינה מצוינת/);
  assert.match(answer, /לפני קביעה שהמחיר כדאי צריך לדעת אם מדובר בגרסת נוסעים או מסחרית ובמצב מכני דומה/);
  for (const check of checks) assert.ok(answer.includes(check));
  assert.doesNotMatch(answer, /אין כרגע מספיק נתונים להשוואת מחיר/);
  assertBriefAppraisal(answer);
});

test('serialized and fenced JSON use the same appraisal contract', () => {
  const appraisal = { conclusion: 'המחיר נמוך מההצעות שנמצאו; המצב בפועל טרם נבדק.',
    checks: ['מצב הפריט', 'התאמה לתיאור'] };
  assert.equal(formatListingAppraisal(JSON.stringify(appraisal)), formatListingAppraisal(appraisal));
  assert.equal(formatListingAppraisal(`\x60\x60\x60json\n${JSON.stringify(appraisal)}\n\x60\x60\x60`),
    formatListingAppraisal(appraisal));
});

test('appraisal strips external links and source names while preserving product manufacturers', () => {
  const answer = formatListingAppraisal({
    conclusion: 'לפי יד2 המחיר 70,000 ש״ח. באתר Mercedes נמצאו דגמי Mercedes VITO דומים https://cars.example.test/a.',
    checks: ['רישיון באתר זאפ www.zap.co.il', 'מנוע וגיר'],
  }, [{ url: 'https://www.mercedes.test/', title: 'Mercedes' }]);
  assert.match(answer, /Mercedes VITO/);
  assert.doesNotMatch(answer, /לפי|אתר|יד2|זאפ|https?:|www\.|example\.test|zap\.co\.il/);
  assertBriefAppraisal(answer);
});

test('price evidence attribution omits the site name and retains the price assessment', () => {
  const answer = formatListingAppraisal({
    conclusion: 'מחירי WinWin מצביעים על מחיר מבוקש סביר של 70,000 ש״ח.',
    checks: ['גרסת הרכב ברישיון', 'מנוע וגיר בבדיקה'],
  }, [{ url: 'https://www.winwin.co.il/cars', title: 'WinWin' }]);
  assert.doesNotMatch(answer, /WinWin/i);
  assert.match(answer, /המחירים שנמצאו מצביעים על מחיר מבוקש סביר של 70,000 ש״ח/);
  assertBriefAppraisal(answer);
});

test('reporting-site names are omitted without removing a factual manufacturer and model', () => {
  const sources = [{ url: 'https://www.winwin.co.il/cars', title: 'WinWin' },
    { url: 'https://www.mercedes.test/vito', title: 'Mercedes' }];
  for (const report of ['WinWin מציג מחירים דומים.', 'WinWin מציעים מחיר דומה.',
    'נתוני WinWin מצביעים על מחיר דומה.', 'המחירים ב־WinWin דומים.',
    'הנתונים של WinWin מצביעים על מחיר דומה.', 'Mercedes מציגה טווח מחירים דומה.']) {
    const answer = formatListingAppraisal({
      conclusion: `Mercedes VITO מוצעת ב־70,000 ש״ח. ${report}`,
      checks: ['רישיון', 'מנוע'],
    }, sources);
    assert.doesNotMatch(answer, /WinWin/i);
    assert.equal((answer.match(/Mercedes/g) || []).length, 1);
    assert.match(answer, /Mercedes VITO מוצעת ב־70,000 ש״ח/);
    assertBriefAppraisal(answer);
  }
});

test('legacy vehicle paragraph becomes a conclusion and two checks', () => {
  const answer = formatListingAppraisal('מרצדס VITO מוצעת ב־70,000 ש״ח; אין נתוני השוואה עדכניים לגרסה.\nלפני רכישה חשוב לבדוק רישיון ורישום בעלים, היסטוריית טיפולים ותאונות, בדיקה במכון, מיזוג וצמיגים.');
  assert.match(answer, /אין נתוני השוואה/);
  assert.match(answer, /1\. רישיון ורישום בעלים\. 2\. היסטוריית טיפולים ותאונות/);
  assert.doesNotMatch(answer, /בדיקה במכון|מיזוג|צמיגים/);
  assertBriefAppraisal(answer);
});

test('source footers inside structured fields do not leak into the appraisal', () => {
  const answer = formatListingAppraisal({
    conclusion: 'המחיר המבוקש דומה להצעות שנמצאו.\nמקורות: חנות לדוגמה https://example.test/a',
    checks: ['תקינות הפריט\nנבדק בתאריך: 10/09/2026', 'התאמה לתיאור'],
  });
  assert.match(answer, /המחיר המבוקש דומה/);
  assert.doesNotMatch(answer, /מקורות|חנות לדוגמה|https?:|נבדק בתאריך|10\/09\/2026/);
  assertBriefAppraisal(answer);
});

test('legacy numbered checks preserve decimals, thousands and dates', () => {
  const answer = formatListingAppraisal('המחיר המבוקש 1,200.50 ש״ח.\nבדיקות: 1. תוקף אחריות עד 11.8.2027\n2. עלות תיקון של 1,000 ש״ח\n3. משלוח');
  assert.match(answer, /1,200\.50 ש״ח/);
  assert.match(answer, /11\.8\.2027/);
  assert.match(answer, /1,000 ש״ח/);
  assert.doesNotMatch(answer, /משלוח/);
  assertBriefAppraisal(answer);
});

test('long appraisals have a bounded conclusion and two bounded checks', () => {
  const answer = formatListingAppraisal({
    conclusion: `לפי ההשוואה המחיר המבוקש גבוה. ${'פרט ארוך נוסף '.repeat(50)}`,
    checks: [`תקינות המנוע ${'ומידע נוסף '.repeat(50)}`, `טיפולים קודמים ${'ומידע נוסף '.repeat(50)}`, 'צבע'],
  });
  assert.match(answer, /המחיר המבוקש גבוה/);
  assertBriefAppraisal(answer);
});

test('shortening cannot remove a late uncertainty and leave an unsupported positive verdict', () => {
  const answer = formatListingAppraisal({
    conclusion: `המחיר כדאי מאוד. ${'פרטי המודעה זמינים '.repeat(25)} אבל אין נתוני השוואה לגרסה המדויקת.`,
    checks: ['גרסה מדויקת', 'מצב המנוע'],
  });
  assert.doesNotMatch(answer, /המחיר כדאי מאוד/);
  assert.match(answer, /אין כרגע מספיק נתונים להשוואת מחיר/);
  assertBriefAppraisal(answer);
});

test('long tokens including internal links are omitted whole instead of damaged', () => {
  const uri = 'betshuva://listing/11111111-1111-4111-8111-111111111111';
  const answer = formatListingAppraisal({
    conclusion: `${'תיאור '.repeat(28)}${uri}`,
    checks: [`${'בדיקה '.repeat(14)}${uri}`, '11.8.2027'],
  });
  const tokens = answer.match(/betshuva:\/\/\S+/g) || [];
  for (const token of tokens) assert.equal(token.replace(/\.$/, ''), uri);
  assertBriefAppraisal(answer);
});

test('missing, duplicate and malformed checks receive two distinct useful checks', () => {
  for (const value of [null, '{broken JSON', { conclusion: 'אין השוואה מספקת.', checks: ['תקינות', 'תקינות', null] }]) {
    const answer = formatListingAppraisal(value);
    assertBriefAppraisal(answer);
    assert.doesNotMatch(answer, /undefined|null|broken JSON/);
  }
});

test('appraisal fallback uses only requested price and two vehicle checks', () => {
  const answer = listingReplyWithoutComparison([{
    title: 'מרצדס VITO', price: 70000, vehicle_details: { year: 2012 },
    description: 'מחיר מציאה ללא תאונות',
  }], [], { appraisal: true });
  assert.match(answer, /המחיר המבוקש 70,000 ש״ח/);
  assert.match(answer, /אין כרגע מספיק נתונים להשוואת מחיר/);
  assert.match(answer, /1\. מנוע וגיר בבדיקה מקצועית\. 2\. היסטוריית טיפולים ותאונות/);
  assert.doesNotMatch(answer, /מחיר מציאה|ללא תאונות/);
  assertBriefAppraisal(answer);
});

test('appraisal fallback handles free and absent listings without inventing a price', () => {
  const free = listingReplyWithoutComparison([{ type: 'free', price: 100 }], [], { appraisal: true });
  assert.match(free, /מסירה ללא תשלום/);
  assert.doesNotMatch(free, /100/);
  assertBriefAppraisal(free);
  const absent = listingReplyWithoutComparison([], [], { appraisal: true });
  assert.doesNotMatch(absent, /המחיר המבוקש|ש״ח/);
  assertBriefAppraisal(absent);
});

test('vehicle fallback accepts the serialized details returned by the marketplace tool', () => {
  const answer = listingReplyWithoutComparison([{
    title: 'מרצדס VITO', price: 70000,
    vehicle_details: JSON.stringify({ year: 2012, mileage: 138000, fuel: 'דיזל' }),
  }], [], { appraisal: true });
  assert.match(answer, /המחיר המבוקש 70,000 ש״ח/);
  assert.match(answer, /1\. מנוע וגיר בבדיקה מקצועית\. 2\. היסטוריית טיפולים ותאונות/);
  assertBriefAppraisal(answer);
});

test('unusable serialized vehicle details retain a safe general fallback', () => {
  for (const details of ['{"year":', '{}', '[]', 'null']) {
    const answer = listingReplyWithoutComparison([{
      title: 'פריט', price: 500, vehicle_details: details,
    }], [], { appraisal: true });
    assert.match(answer, /המחיר המבוקש 500 ש״ח/);
    assert.doesNotMatch(answer, /מנוע|טיפולים|year|null/);
    assertBriefAppraisal(answer);
  }
});

test('ordinary listing search formatting and fallback keep their existing behavior', () => {
  const listingLink = 'betshuva://listing/11111111-1111-4111-8111-111111111111';
  const text = `מקרר Samsung מוצע ב־500 ש״ח.\n${listingLink}`;
  assert.equal(briefListingAnswer(text), text);
  const fallback = listingReplyWithoutComparison([{ title: 'מקרר', price: 500 }]);
  assert.match(fallback, /מקרר: המחיר המבוקש 500 ש״ח/);
  assert.doesNotMatch(fallback, /בדוק: 1\./);
});
