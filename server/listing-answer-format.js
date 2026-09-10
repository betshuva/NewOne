'use strict';

function escapePattern(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function websiteNames(sources) {
  // Source metadata can supply Latin names while the answer uses Hebrew.
  const names = new Set(['Zap', 'זאפ', 'Yad2', 'יד2', 'יד 2', 'IKEA', 'איקאה']);
  for (const source of sources) {
    try {
      const labels = new URL(source.url).hostname.replace(/^www\./, '').split('.');
      const brand = labels.at(-2) === 'co' || labels.at(-2) === 'com'
        ? labels.at(-3) : labels.at(-2);
      if (brand?.length >= 3 && !['gov', 'org', 'example'].includes(brand)) names.add(brand);
      // Short source titles also supply multiword Hebrew site names. They are
      // matched only in attribution phrases, never removed from product names.
      const title = String(source.title || '').trim();
      for (const part of title.split(/\s+[|–—-]\s+/)) {
        if (part.length <= 45 && part.split(/\s+/).length <= 4 && !/\d/.test(part))
          names.add(part);
      }
    } catch (_) {}
  }
  return [...names].sort((a, b) => b.length - a.length);
}

function scrubListingAnswer(text, sources = []) {
  text = String(text || '');
  for (const name of websiteNames(sources).filter(Boolean)) {
    // An actual manufacturer/model in the listing is useful information. A
    // website name is omitted when used as a source or shopping destination.
    const sourceName = `["״']?${escapePattern(name)}["״']?(?![\\p{L}\\p{N}])`;
    const evidenceLabels = {
      'מחירי': 'המחירים שנמצאו', 'מחירים': 'המחירים שנמצאו', 'המחירים': 'המחירים שנמצאו',
      'מודעות': 'המודעות שנמצאו', 'המודעות': 'המודעות שנמצאו',
      'תוצאות': 'התוצאות שנמצאו', 'נתוני': 'הנתונים שנמצאו', 'הנתונים': 'הנתונים שנמצאו',
      'הצעות': 'ההצעות שנמצאו', 'ההצעות': 'ההצעות שנמצאו', 'מחירון': 'המחירון שנבדק',
    };
    text = text.replace(new RegExp(
      `(?<![\\p{L}\\p{N}])(${Object.keys(evidenceLabels).join('|')})\\s+(?:של\\s+)?(?:[במל][־-]?)?${sourceName}`,
      'giu'), (_, label) => evidenceLabels[label]);
    // A name acting as the reporter is an attribution too: “WinWin מציג
    // מחירים”. Keep the comparison and replace only that attribution, leaving
    // factual item names such as “Mercedes VITO” intact elsewhere in the text.
    text = text.replace(new RegExp(
      `(?<![\\p{L}\\p{N}])${sourceName}\\s+(?:מציג(?:ה|ים|ות)?|מציע(?:ה|ים|ות)?|מפרסמ(?:ת|ים|ות)?|מפרסם|מציינ(?:ת|ים|ות)?|מציין|מדווח(?:ת|ים|ות)?|מרא(?:ה|ים|ות))(?![\\p{L}\\p{N}])(?:\\s+על(?=\\s))?`,
      'giu'), 'ההשוואה מציגה');
    text = text.replace(new RegExp(
      `(?<![\\p{L}\\p{N}])(?:(?:לפי|על[־ -]פי|בדקתי)\\s+(?:(?:באתר|אתר)\\s+)?|(?:באתר|מהאתר|לאתר|אתר)\\s+(?:של\\s+)?|[בלמ][־-])?["״']?${escapePattern(name)}["״']?(?![\\p{L}\\p{N}])`, 'giu'), (match) => {
        // Bare brand names are product information; only remove an attribution.
        if (match.replace(/["״']/g, '').toLowerCase() === name.toLowerCase()) return match;
        return '';
      });
  }
  text = text
    // Strip attribution while retaining the price or observation after it.
    .replace(/(?:לפי\s+|על[־ -]פי\s+|בדקתי\s+)?(?:באתר|מהאתר|לאתר|אתר)\s+(?:של\s+)?["״']?(?:יד\s*2|[\p{L}\p{N}_.-]+)["״']?(?:\s+הרשמי)?[ \t]*[:,־-]?[ \t]*/gu, '')
    .replace(/\b(?:https?:\/\/|www\.)[^\s<>]+/gi, '')
    .replace(/\b(?:[a-z0-9-]+\.)+[a-z]{2,24}(?:\/[^\s<>]*)?/gi, '');
  // These marketplace names cannot describe the item's manufacturer/model.
  text = text.replace(/(?<![\p{L}\p{N}])(?:[בלמ][־-]?)?(?:Zap|זאפ|Yad2|יד\s*2)(?![\p{L}\p{N}])/giu, '');
  text = text
    .replace(/[([][ \t]*[)\]]/g, '')
    .replace(/^[ \t]*(?:קישור(?: לפתיחה)?|לפתיחת (?:המודעה|האתר)|למידע נוסף|לחצו? כאן)\s*[:：]?[ \t]*$/gm, '')
    .replace(/[ \t]+([.,;:!?])/g, '$1')
    .replace(/^[ \t]*[.,;:!?]+[ \t]*$/gm, '')
    .replace(/[ \t]{2,}/g, ' ')
    .replace(/\n{3,}/g, '\n\n').trim();
  return text;
}

function briefListingAnswer(text, sources = []) {
  text = scrubListingAnswer(text, sources);
  if (text.length <= 600 && text.split(/\s+/).length <= 80) return text;

  // Keep complete words and, where possible, complete sentences. Never cut a
  // listing URI halfway through and turn it into a broken card link.
  const words = text.match(/\S+\s*/g) || [];
  let short = '';
  for (const word of words.slice(0, 80)) {
    if ((short + word).trim().length > 600) break;
    short += word;
  }
  short = short.trim();
  const lastSentence = [...short.matchAll(/[.!?](?=\s|$)/g)].at(-1);
  if (lastSentence && lastSentence.index >= short.length / 2)
    short = short.slice(0, lastSentence.index + 1);
  return short;
}

const APPRAISAL_UNCERTAINTY = 'אין כרגע מספיק נתונים להשוואת מחיר כדי לקבוע אם המחיר כדאי.';
const DEFAULT_APPRAISAL_CHECKS = ['תקינות ומצב הפריט בבדיקה מעשית', 'התאמה לפרטי המודעה'];

function boundedAppraisalPart(text, maxChars, maxWords) {
  const words = String(text || '').trim().match(/\S+/g) || [];
  let result = '';
  for (const word of words.slice(0, maxWords)) {
    const next = result ? `${result} ${word}` : word;
    if (next.length > maxChars) break;
    result = next;
  }
  // Tokens are kept whole: decimal prices, dates and internal listing links
  // must never become different values or broken links when shortened.
  return result.replace(/[,:;\s]+$/u, '').trim();
}

function appraisalParts(value) {
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    return {
      conclusion: typeof value.conclusion === 'string' ? value.conclusion : '',
      checks: Array.isArray(value.checks) ? value.checks.filter(check => typeof check === 'string') : [],
    };
  }
  const text = String(value || '').trim().replace(/^```(?:json)?\s*|\s*```$/g, '');
  if (text.startsWith('{')) {
    try { return appraisalParts(JSON.parse(text)); } catch (_) {
      // A malformed structured response is not suitable user-facing prose.
      return { conclusion: '', checks: [] };
    }
  }
  const marker = /(?:לפני\s+(?:רכישה|קנייה)[^.!?\n:;]{0,30}(?:לבדוק|בדוק)|(?:חשוב|יש|כדאי|מומלץ)\s+(?:לבדוק|לוודא)|בדיקות?(?:\s+חשובות)?\s*:|בדוק(?:י)?\s*:)/u.exec(text);
  if (!marker) return { conclusion: text, checks: [] };
  const checkText = text.slice(marker.index + marker[0].length);
  return {
    conclusion: text.slice(0, marker.index),
    // A comma inside a price remains intact. Numbered/bulleted legacy answers
    // and the common comma-separated checklist both reduce to two items.
    checks: checkText.split(/\n+|[;•]|,\s+|(?:^|\s)\d+[.)]\s+/u),
  };
}

function formatListingAppraisal(text, sources = []) {
  const parts = appraisalParts(text);
  const cleanPart = value => scrubListingAnswer(String(value || '')
    .replace(/(?:^|\s)(?:מקורות(?:\s+מידע)?|קישורים(?:\s+למקורות)?|נבדק בתאריך|תאריך בדיקה)\s*[:：][\s\S]*$/u, ''), sources)
    .replace(/\*\*/g, '').replace(/^[\s•\-]+/u, '').trim();
  const originalConclusion = cleanPart(parts.conclusion)
    .replace(/^(?:מסקנה|הערכת מחיר)\s*[:：]\s*/u, '').replace(/[;:]\s*$/u, '');
  let conclusion = boundedAppraisalPart(originalConclusion, 500, 58);
  if (!conclusion) conclusion = APPRAISAL_UNCERTAINTY;
  // Never shorten an optimistic sentence while dropping a later qualification
  // about missing evidence, comparability or the item's unknown condition.
  const uncertainty = /(?:אין\s+(?:כרגע\s+)?(?:מספיק\s+)?(?:נתוני|נתונים|בסיס)|בלי\s+נתוני|ללא\s+(?:נתוני|השוואה)|לא\s+(?:ניתן|אפשר|ידוע|אומת|ברור)|איני\s+יכול|אי\s+אפשר|חסר(?:ים|ה)?\s|אך\s|אבל\s|בתנאי\s|בכפוף\s)/u;
  const qualification = uncertainty.exec(originalConclusion);
  if (qualification && conclusion.length < originalConclusion.length) {
    conclusion = APPRAISAL_UNCERTAINTY;
  }
  const checks = [];
  for (const value of [...parts.checks, ...DEFAULT_APPRAISAL_CHECKS]) {
    const check = boundedAppraisalPart(cleanPart(value)
      .replace(/^(?:\d+[.)]\s*|(?:ו?יש|ו?חשוב)\s+(?:לבדוק|לוודא)\s*|בדוק\s*)/u, ''), 125, 14)
      .replace(/[.!?]+$/u, '');
    if (check && !checks.includes(check)) checks.push(check);
    if (checks.length === 2) break;
  }
  return `${conclusion}\nבדוק: 1. ${checks[0]}. 2. ${checks[1]}.`;
}

function listingReplyWithoutComparison(listings, sources = [], { appraisal = false } = {}) {
  if (appraisal) {
    const listing = listings[0];
    const price = listing?.price == null || listing.price === '' ? null : Number(listing.price);
    const requestedPrice = listing?.type === 'free' ? 'המודעה מציעה מסירה ללא תשלום. '
      : price !== null && Number.isFinite(price) && price >= 0
        ? `המחיר המבוקש ${price.toLocaleString('he-IL')} ש״ח. ` : '';
    let vehicleDetails = listing?.vehicle_details;
    // Marketplace results serialize structured fields before provider input.
    if (typeof vehicleDetails === 'string') {
      try { vehicleDetails = JSON.parse(vehicleDetails); } catch (_) { vehicleDetails = null; }
    }
    const isVehicle = vehicleDetails && typeof vehicleDetails === 'object' &&
      !Array.isArray(vehicleDetails) && Object.keys(vehicleDetails).length > 0;
    return formatListingAppraisal({
      conclusion: `${requestedPrice}${APPRAISAL_UNCERTAINTY}`,
      checks: isVehicle ? ['מנוע וגיר בבדיקה מקצועית', 'היסטוריית טיפולים ותאונות'] : DEFAULT_APPRAISAL_CHECKS,
    }, sources);
  }
  if (!listings.length)
    return 'אין כרגע מספיק נתונים מאומתים להשוואת מחיר. אפשר לצרף מודעה מסוימת לבדיקה.';
  const conditions = { new: 'חדש', like_new: 'כמו חדש', good: 'טוב',
    fair: 'בינוני', for_parts: 'לחלקים' };
  const lines = listings.slice(0, 3).map(listing => {
    const price = listing.price == null || listing.price === '' ? null : Number(listing.price);
    const requestedPrice = listing.type === 'free' ? 'למסירה ללא תשלום'
      : price !== null && Number.isFinite(price) && price >= 0
        ? `המחיר המבוקש ${price.toLocaleString('he-IL')} ש״ח` : 'לא צוין מחיר';
    const condition = conditions[listing.item_condition];
    return `${String(listing.title || 'המודעה').slice(0, 100)}: ${requestedPrice}${condition ? `; המצב שצוין במודעה: ${condition}` : ''}.`;
  });
  // These facts come only from the authorized marketplace tool. None of the
  // provider's unverified comparison, photo claims or verdict is reused.
  lines.push('אין כרגע מספיק נתונים להשוואת מחיר; לפני קנייה בדוק תקינות והתאמה לתיאור.');
  return briefListingAnswer(lines.join('\n'), sources);
}

module.exports = { briefListingAnswer, formatListingAppraisal, listingReplyWithoutComparison };
