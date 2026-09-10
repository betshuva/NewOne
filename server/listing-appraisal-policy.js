'use strict';

function isListingAppraisal(question, listingContext) {
  if (!listingContext) return false;
  const appraisalIntent = /חוות\s*דעת|(?<![\p{L}\p{N}])(?:כדאי|כדאיות|משתלם|שווה|תמחור|שווי)(?![\p{L}\p{N}])|\b(?:appraisal|worth|value)\b/iu.test(question);
  if (appraisalIntent) return true;
  // A price filter in a request for listings is not an appraisal. Likewise,
  // "השווה את התמונות" must not match the substring "שווה".
  if (/(?:חפש|מצא|תמצא|תציג|הצג|מחפש(?:ת)?)\s/u.test(question) &&
      !/betshuva:\/\/listing\//i.test(question)) return false;
  return /מחיר|\bprice\b/i.test(question);
}

function permitsComparisonResearch(question) {
  return !/(?:בלי|ללא|אין\s+צורך\s+ב?|אל\s+תבצע\s+|אל\s+תחפש\s+|לא\s+לחפש\s+)\s*(?:חיפוש\s+)?(?:ב?אינטרנט|ב?רשת|השווא(?:ה|ת)\s*מחירים?)|(?:רק|בלבד)\s+(?:בבתשובה|בתשובה|במודע(?:ה|ות)|מהתמונ(?:ה|ות))|(?:מודעות\s+)?בתשובה\s+בלבד|\b(?:no web|no internet|internal only|photos? only)\b/i.test(question);
}

const APPRAISAL_FORMAT = {
  type: 'json_schema', name: 'listing_appraisal', strict: true,
  schema: {
    type: 'object', additionalProperties: false,
    properties: {
      conclusion: { type: 'string' },
      checks: { type: 'array', items: { type: 'string' }, minItems: 2, maxItems: 2 },
    },
    required: ['conclusion', 'checks'],
  },
};

const APPRAISAL_INSTRUCTIONS = `
זוהי חוות דעת עניינית ומנומקת על מודעה. שאף לכ־60–90 מילים בסך הכול, בלי להאריך כשאין מידע נוסף. החזר JSON לפי המבנה המבוקש:
conclusion: פסקה של שניים עד שלושה משפטים, בדרך כלל 45–55 מילים. פתח בהערכת המחיר ונמק אותה לפי ההשוואה שבוצעה: עד כמה המוצרים דומים, ומה משמעות הפער במחיר אם אומת. קשר פרט משמעותי מהמודעה או תצפית ממשית מהתמונה להחלטה; אל תסתפק בחזרה על הנתונים. הסבר איזה פרט חסר עשוי לשנות את ההערכה. אם ההשוואה אינה מספיקה, הסבר בקצרה מדוע ומה נחוץ להכרעה; אל תמציא טווח, הנחה למשא ומתן או כדאיות. נתון מוצהר, כמו קילומטראז׳ או מצב, אינו הוכחה לתקינות.
checks: בדיוק שתי בדיקות חשובות וממוקדות למוצר הזה, עד 12 מילים לכל בדיקה. בחר בדיקות שנגזרות מהסיכונים או מהפרטים החסרים במודעה. כל בדיקה תעסוק בנושא אחד, בלי רשימות משנה ובלי ניסוחים כגון "כולל מנוע, גיר, שלדה, מיזוג וצמיגים". למשל ברכב: "אימות הגרסה ברישיון כדי להתאים את השוואת המחיר" ו-"בדיקת מנוע וגיר במוסך לפני החלטה".
אין לכתוב מחדש את כל פרטי המודעה, להוסיף הקדמה, משפטים כלליים למילוי, קישורים חיצוניים, שמות אתרים או רשימת מקורות.
לצורך השוואת מחיר השתמש בפרטי המודעה שנשלפו כעת: דגם, גרסה, שנתון, מצב ומפרט רלוונטיים. חפש מוצרים משומשים דומים; מחיר חדש אינו מחיר שוק של משומש. ברכב התחשב בגרסה, שנתון, מנוע ותיבת הילוכים; אם הגרסה חסרה, חפש את האפשרויות והבחן ביניהן במקום לוותר מראש על החיפוש. מחירון או מודעה לגרסה אחרת אינם הוכחה למחיר הדגם הנבדק. כאשר פרט חסר מונע התאמה להשוואות שנמצאו, נסח מסקנה מותנית וציין את הפרט החסר במקום לקבוע שהמחיר גבוה או כדאי בוודאות. בלי השוואה רלוונטית אין לקבוע שהמחיר כדאי.
`;

module.exports = { isListingAppraisal, permitsComparisonResearch, APPRAISAL_FORMAT,
  APPRAISAL_INSTRUCTIONS };
