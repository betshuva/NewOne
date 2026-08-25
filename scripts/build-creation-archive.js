const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const projectRoot = path.join(__dirname, '..');
const sourceRoot = path.join(
  '/home/yaniv/.codex/generated_images',
  '01a0336f-7e10-74a2-9146-59ba9a1313aa');
const archiveRoot = path.join(projectRoot, 'creation-archive');
const archiveAssets = path.join(archiveRoot, 'assets');
const evidenceRoot = path.join(archiveRoot, 'evidence');

const groups = [
  {
    id: '00-original-expressions',
    title: 'ביטויים מקוריים ראשונים',
    description: 'מחקר חזותי מוקדם של סמיילים וסמלים יהודיים לפני בחירת דמות המותג.',
    items: [
      ['exec-31af8941-5808-4f3d-bfca-d3051ceb4c49.png', 'original-expression-sheet.png',
        'גיליון ראשוני של 25 ביטויים וסמלים מקוריים.'],
    ],
  },
  {
    id: '01-mascot-origin',
    title: 'מקור דמות הילד',
    description: 'הפיכת צילום מקורי שסיפקה וצילמה בעלת המיזם לדמות מאוירת ראשונה.',
    items: [
      ['exec-eb4b6a50-c012-4c86-b4fd-ec9bdeca7c32.png', 'first-child-mascot-sheet.png',
        'גיליון תשע הבעות ראשון שנוצר בהשראת צילום הילד.'],
    ],
  },
  {
    id: '02-sticker-sets',
    title: 'סטים של מדבקות',
    description: 'פיתוח הדמות למדבקות לבבות, ידיים, שבת, חגים וברכות חזותיות.',
    items: [
      ['exec-96f3af7f-ddef-4f2f-a853-56cca7c24e14.png', 'hearts-and-hands.png', 'לבבות וסימוני ידיים.'],
      ['exec-7c28d55e-ac3d-4e30-a75e-9e94072cbd76.png', 'shabbat-and-havdalah.png', 'שבת והבדלה.'],
      ['exec-f31764a3-eb08-4e8a-8088-bd09eeb6dc9a.png', 'jewish-holidays.png', 'חגים ומועדי ישראל.'],
      ['exec-6799e8f0-ae8a-4520-b71d-b5a4edb725f8.png', 'blessings-and-emotions.png', 'ברכות, עידוד ורגשות.'],
    ],
  },
  {
    id: '03-neutral-and-words',
    title: 'רגשות ניטרליים וברכות מילוליות',
    description: 'אפשרויות הבעה ללא ילד ולצדן ניסוי טיפוגרפי של ברכות בעברית.',
    items: [
      ['exec-de6acc19-a982-42a7-9dd3-5e9beaf1aae1.png', 'neutral-emotions.png', 'רגשות ניטרליים, לב, ידיים וכוכב.'],
      ['exec-852c5e1f-a4e8-417d-a27c-6c90597d72cf.png', 'hebrew-blessings-concept.png', 'טיוטת כיוון לברכות מילוליות בעברית.'],
    ],
  },
  {
    id: '04-animation',
    title: 'פיתוח אנימציה',
    description: 'לוחות פריימים והמחשות מונפשות עדינות בפורמטי WebP ו-GIF.',
    items: [
      ['exec-14e0d0ae-84d1-4cdf-b325-fbc51b126c2f.png', 'animation-storyboard-v1.png', 'לוח פריימים ראשון.'],
      ['exec-122a0830-5bd0-4bc2-97e1-bdc28eeb6c2f.png', 'animation-storyboard-v2.png', 'לוח פריימים מתוקן עם שוליים.'],
      ['betshuva-wave.webp', 'aviel-wave.webp', 'נפנוף עדין – WebP מונפש.'],
      ['betshuva-wave.gif', 'aviel-wave.gif', 'נפנוף עדין – GIF.'],
      ['betshuva-gentle-jump.webp', 'aviel-gentle-jump.webp', 'קפיצה עדינה – WebP מונפש.'],
      ['betshuva-gentle-jump.gif', 'aviel-gentle-jump.gif', 'קפיצה עדינה – GIF.'],
      ['betshuva-heart-glow.webp', 'aviel-heart-glow.webp', 'לב פועם ומנצנץ – WebP מונפש.'],
      ['betshuva-heart-glow.gif', 'aviel-heart-glow.gif', 'לב פועם ומנצנץ – GIF.'],
    ],
  },
  {
    id: '05-guide-development',
    title: 'התפתחות מדריך בתשובה',
    description: 'המעבר מדמות תלת־ממדית כללית לשפת גואש ודיו מקורית ולזהות אביאל.',
    items: [
      ['exec-5bf0b960-72f6-487c-9e19-6fe9b4e65603.png', 'guide-3d-exploration.png', 'מחקר מדריך ראשוני בסגנון תלת־ממד.'],
      ['exec-1f0a4ede-99ad-496f-b08b-8b6b851bd4b1.png', 'aviel-gouache-origin.png', 'הכיוון המקורי בגואש ודיו וחוט כחול־זהוב.'],
      ['exec-b1588d47-4ef5-4409-8378-1b060017fe94.png', 'aviel-signature-system.png', 'מערכת חתימות חזותיות: חוט, תפרים וצל־שביל.'],
      ['exec-d6d6a7c6-dea0-4674-8305-c5efeafbed0e.png', 'aviel-soft-refinement.png', 'עידון הדמות וחזרה למראה טבעי יותר.'],
    ],
  },
  {
    id: '06-official-guide',
    title: 'אביאל – הגרסה הרשמית למדריך',
    description: 'קובץ הפרופיל שהוכן מן האיור שנבחר וצורף על ידי בעלת המיזם.',
    items: [
      ['exec-ede47b48-9763-4980-90e3-3ea508d3d27c.png', 'aviel-official-guide.png',
        'אביאל מנופף, מותאם לתמונת פרופיל מרובעת.'],
    ],
  },
];

function hashFile(filePath) {
  return crypto.createHash('sha256').update(fs.readFileSync(filePath)).digest('hex');
}

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, character => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  })[character]);
}

fs.mkdirSync(archiveAssets, { recursive: true });
fs.mkdirSync(evidenceRoot, { recursive: true });

const records = [];
for (const group of groups) {
  const destinationDirectory = path.join(archiveAssets, group.id);
  fs.mkdirSync(destinationDirectory, { recursive: true });
  for (const [sourceName, destinationName, description] of group.items) {
    const sourcePath = path.join(sourceRoot, sourceName);
    if (!fs.existsSync(sourcePath)) throw new Error(`Missing source: ${sourcePath}`);
    const destinationPath = path.join(destinationDirectory, destinationName);
    fs.copyFileSync(sourcePath, destinationPath);
    const sourceStat = fs.statSync(sourcePath);
    fs.utimesSync(destinationPath, sourceStat.atime, sourceStat.mtime);
    records.push({
      groupId: group.id,
      groupTitle: group.title,
      file: `assets/${group.id}/${destinationName}`,
      archivedFrom: sourceName,
      description,
      sourceMtimeUtc: sourceStat.mtime.toISOString(),
      sourceMtimeIsrael: new Intl.DateTimeFormat('he-IL', {
        timeZone: 'Asia/Jerusalem', dateStyle: 'full', timeStyle: 'medium',
      }).format(sourceStat.mtime),
      bytes: fs.statSync(destinationPath).size,
      sha256: hashFile(destinationPath),
    });
  }
}

let chain = 'BETSHUVA-CREATION-ARCHIVE-V1';
for (const record of records) {
  chain = crypto.createHash('sha256').update([
    chain, record.file, record.sha256, record.sourceMtimeUtc,
  ].join('|')).digest('hex');
  record.chainHash = chain;
}

const generatedAt = new Date();
const manifest = {
  archiveVersion: 1,
  generatedAtUtc: generatedAt.toISOString(),
  generatedAtIsrael: new Intl.DateTimeFormat('he-IL', {
    timeZone: 'Asia/Jerusalem', dateStyle: 'full', timeStyle: 'long',
  }).format(generatedAt),
  finalChainSha256: chain,
  provenance: {
    ownerStatement: 'בעלת המיזם מסרה כי צילום המקור צולם על ידה ובו מופיע בנה.',
    sourcePrivacy: 'צילום הילד המקורי אינו מפורסם בארכיון הציבורי.',
    generationMethod: 'OpenAI built-in image generation/editing tool, followed by deterministic local animation assembly where noted.',
    promptRecordStatus: 'תיאורי הקבצים הם סיכומי תהליך; תמליל השיחה המקורי הוא המקור המלא לנוסחי ההנחיות.',
    legalNotice: 'הארכיון מספק תיעוד טכני וגיבובים ואינו חותמת זמן מוסמכת או חוות דעת משפטית.',
  },
  records,
};

fs.writeFileSync(path.join(evidenceRoot, 'manifest.json'),
  `${JSON.stringify(manifest, null, 2)}\n`);
fs.writeFileSync(path.join(evidenceRoot, 'SHA256SUMS.txt'),
  `${records.map(record => `${record.sha256}  ${record.file}`).join('\n')}\n`);
fs.writeFileSync(path.join(evidenceRoot, 'ARCHIVE_ROOT_SHA256.txt'),
  `${chain}  BETSHUVA-CREATION-ARCHIVE-V1\n`);
fs.writeFileSync(path.join(evidenceRoot, 'CREATION_RECORD.txt'), `ארכיון יצירת אביאל וביטויי בתשובה
====================================
מועד איסוף (ישראל): ${manifest.generatedAtIsrael}
מועד איסוף (UTC): ${manifest.generatedAtUtc}
גיבוב שורש SHA-256: ${chain}

הצהרת מקור שנמסרה בשיחה:
בעלת המיזם צילמה בעצמה את צילום בנה ששימש השראה לדמות.
שם הילד אינו משמש כשם הדמות; הדמות נקראת "אביאל".

שיטת התיעוד:
הקבצים הועתקו ללא שינוי מתיקיית הפלט המקורית, זמן השינוי שלהם נשמר,
ולכל קובץ חושב SHA-256. בנוסף נבנתה שרשרת גיבובים לפי סדר הרשומות.

הסתייגות:
זמן מערכת וגיבוב הם ראיות טכניות שימושיות אך אינם חותמת זמן מוסמכת,
אישור נוטריוני או חוות דעת משפטית. צילום המקור אינו מפורסם בדף הציבורי.
`);

const cardsByGroup = groups.map(group => {
  const cards = records.filter(record => record.groupId === group.id).map(record => `
    <article class="card">
      <a href="${escapeHtml(record.file)}" target="_blank" rel="noopener">
        <img src="${escapeHtml(record.file)}" alt="${escapeHtml(record.description)}" loading="lazy">
      </a>
      <div class="card-body">
        <h3>${escapeHtml(path.basename(record.file))}</h3>
        <p>${escapeHtml(record.description)}</p>
        <dl>
          <dt>מועד מקור</dt><dd>${escapeHtml(record.sourceMtimeIsrael)}</dd>
          <dt>SHA-256</dt><dd><code>${escapeHtml(record.sha256)}</code></dd>
        </dl>
        <a class="download" href="${escapeHtml(record.file)}" download>הורדת קובץ המקור</a>
      </div>
    </article>`).join('');
  return `<section id="${group.id}"><h2>${escapeHtml(group.title)}</h2>
    <p class="section-description">${escapeHtml(group.description)}</p>
    <div class="grid">${cards}</div></section>`;
}).join('\n');

const html = `<!doctype html>
<html lang="he" dir="rtl"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>ארכיון יצירת אביאל – בתשובה</title>
<style>
:root{--blue:#075b91;--deep:#063c63;--gold:#d99a22;--cream:#fffaf0;--ink:#183247}
*{box-sizing:border-box}body{margin:0;background:#eef5fa;color:var(--ink);font-family:Arial,"Noto Sans Hebrew",sans-serif;line-height:1.55}
header{background:linear-gradient(135deg,var(--deep),var(--blue));color:white;padding:42px 20px;text-align:center;border-bottom:5px solid var(--gold)}
header h1{margin:0 0 8px;font-size:clamp(28px,5vw,46px)}header p{margin:5px auto;max-width:850px}
main{width:min(1180px,94%);margin:28px auto 60px}.evidence{background:var(--cream);border:1px solid #e7d6af;border-radius:18px;padding:22px;box-shadow:0 8px 24px #164b7015}
.evidence strong{color:var(--deep)}.root{direction:ltr;overflow-wrap:anywhere;background:#fff;border:1px solid #d8e2e8;padding:10px;border-radius:9px;font-family:monospace;font-size:12px}
.evidence-links{display:flex;gap:10px;flex-wrap:wrap;margin-top:16px}.evidence-links a,.download{display:inline-block;background:var(--blue);color:white;text-decoration:none;padding:9px 14px;border-radius:10px;font-weight:700}
section{margin-top:38px}h2{color:var(--deep);margin-bottom:4px;border-right:5px solid var(--gold);padding-right:11px}.section-description{margin-top:0;color:#526b7c}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:18px}.card{background:white;border-radius:16px;overflow:hidden;border:1px solid #d8e6ef;box-shadow:0 8px 22px #164b7012}
.card>a{display:block;background:linear-gradient(45deg,#f7fafc,#e9f2f7)}.card img{display:block;width:100%;height:260px;object-fit:contain}.card-body{padding:16px}.card h3{direction:ltr;text-align:left;font-size:14px;overflow-wrap:anywhere;margin:0 0 8px}.card p{min-height:48px}
dl{font-size:12px}dt{font-weight:700;color:#587184}dd{margin:0 0 8px}code{display:block;direction:ltr;overflow-wrap:anywhere;background:#f2f6f8;padding:7px;border-radius:7px}
footer{text-align:center;padding:25px;color:#5c7282;background:white;border-top:1px solid #d9e5ec}
</style></head><body>
<header><h1>ארכיון יצירת אביאל</h1><p>תיעוד כרונולוגי של פיתוח דמות מדריך בתשובה, המדבקות והאנימציות.</p><p>צילום המקור הפרטי אינו מוצג בדף זה.</p></header>
<main><section class="evidence"><h2>רשומת ראיות טכנית</h2>
<p><strong>נאסף:</strong> ${escapeHtml(manifest.generatedAtIsrael)}</p>
<p><strong>גיבוב שורש SHA-256:</strong></p><div class="root">${chain}</div>
<p>כל קובץ מתועד עם זמן מערכת וגיבוב SHA-256. שינוי של בית אחד בקובץ ייצור גיבוב שונה. התיעוד אינו מחליף חותמת זמן מוסמכת או ייעוץ משפטי.</p>
<div class="evidence-links"><a href="evidence/manifest.json">Manifest מלא</a><a href="evidence/SHA256SUMS.txt">רשימת SHA-256</a><a href="evidence/CREATION_RECORD.txt">רשומת יצירה</a><a href="evidence/ARCHIVE_ROOT_SHA256.txt">גיבוב שורש</a></div></section>
${cardsByGroup}</main><footer>בתשובה · תוכן יהודי נקי · ארכיון יצירה</footer></body></html>`;
fs.writeFileSync(path.join(archiveRoot, 'index.html'), html);

console.log(JSON.stringify({ records: records.length, finalChainSha256: chain }, null, 2));
