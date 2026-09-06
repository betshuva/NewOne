// Import the user's sticker atlases without redrawing their artwork or lettering.
const fs = require('node:fs/promises');
const path = require('node:path');
const sharp = require('sharp');
const root = path.resolve(__dirname, '..');
const input = process.argv[2] || '/home/yaniv/Emoji';
const output = path.join(root, 'expression-library', 'user-20260907');
const sheets = [
  ['WhatsApp Image 2026-09-07 at 00.01.32.jpeg', 8, 6,
    'שמחה|צחוק|חיוך|קריצה|נשיקה|שלווה|אהבה|התרגשות|עיניים נוצצות|הפתעה|ספק|מחשבה|רוגע|דאגה|בכי|תסכול|לב ורוד|לבבות|כל הכבוד|מצוין|מחיאות כפיים|תודה|שלום|כוח|אישור|נצנוצים|כוכב|זיקוקים|בלון|מתנה|חגיגה|דגלונים|שמש|זריחה|ירח|לילה|ענן|ענף|פרח|עלים|בית|דלת פתוחה|חלון|פנס|דרך|קפה|ספר|לב וענף'],
  ['WhatsApp Image 2026-09-07 at 00.02.00.jpeg', 8, 6,
    'שבת שלום|חג שמח|שבוע טוב|בוקר טוב|לילה טוב|יום טוב ומבורך|בשורות טובות|מזל טוב|הולדת בן|הולדת בת|חתן וכלה|שמחת תורה|סוכות שמח|חג סוכות שמח|גמר חתימה טובה|שנה טובה|חנוכה שמח|חג חנוכה שמח|חג פסח שמח|חג שבועות שמח|פורים שמח|ט״ו בשבט שמח|צום מועיל|עם ישראל חי|קפה טוב|תודה|שמחים לשמוע|כל הכבוד|בריאות טובה|פרנסה טובה|דלתות טובות|שמור על עצמך|שת״פ פורה|הצלחה גדולה|המשך כך|יום נעים|חג שמח בלונים|מתגעגעים|שלום|בתשובה|בהצלחה|מזל וברכה|גם זה יעבור|עוד נגיע|דרך צלחה|רגע של מנוחה|גוט שאבעס|'],
  ['WhatsApp Image 2026-09-07 at 00.02.27.jpeg', 9, 5,
    'רגע|מחכה לתשובה|קיבלתי|שלחתי|התקבל|התראה|בודק|קפה בדרך|בשורות טובות|תפילה בשבילך|לימוד פורה|תשובה בהצלחה|רעיון טוב|שאלה טובה|מעולה|תודה רבה|יישר כוח|הפתעה|מגיע|בדרך|הגעתי|נמצא בדרך|בהכוונה|כמעט שם|נטען|מתארגן|לילה טוב|יום נפלא|מזג אוויר נעים|הכול לטובה|צמיחה והצלחה|עוד צעד קדימה|מגיעים רחוק|הצלחה גדולה|יקר מפז|כוכב|שמור עליך|שלום|נתראה|אהבתי|מזל טוב|יום הולדת שמח|פינוק|תודה|דלתות טובות'],
  ['WhatsApp Image 2026-09-07 at 00.11.24.jpeg', 3, 2,
    'יום טוב|רק בשמחות|לילה טוב|תודה|הדרך טובה|תמיד יש אור'],
];
(async () => {
 await fs.mkdir(output, {recursive:true});
 const labels=[];
 async function emit(file, label, region) {
  let image=sharp(path.join(input,file));
  if(region) image=image.extract(region);
  const name=`sticker-${String(labels.length+1).padStart(2,'0')}.png`;
  await image.png().toFile(path.join(output,name));labels.push(label);
 }
 for(const [file,cols,rows,text] of sheets) {
  const {width,height}=await sharp(path.join(input,file)).metadata();
  const names=text.split('|');
  if(file.includes('00.02.00')) {
   for(let row=0;row<4;row++) for(let col=0;col<8;col++) {
    const left=col*192,top=Math.round(row*height/6);
    await emit(file,names[row*8+col],{left,top,width:192,height:Math.round((row+1)*height/6)-top});
   }
   const bottomLabels='שת״פ פורה|הצלחה גדולה|המשך כך|יום נעים|חג שמח בלונים|מתגעגעים|שלום|תמיד איתכם|בהצלחה|מזל וברכה|גם זה יעבור|עוד נגיע|דרך צלחה|רגע של מנוחה|גוט שאבעס|תמיד בבית'.split('|');
   for(let row=0;row<2;row++) for(let col=0;col<8;col++) {
    const top=row===0?684:848,bottom=row===0?848:1024;
    const edges=row===0?[0,195,380,550,705,865,1015,1170,1320]:[0,160,320,470,620,765,900,1060,1320];
    await emit(file,bottomLabels[row*8+col],{left:edges[col],top,width:edges[col+1]-edges[col],height:bottom-top});
   }
   await emit(file,'הבית של בתשובה',{left:1320,top:684,width:216,height:340});
   continue;
  }
  for(let row=0;row<rows;row++) for(let col=0;col<cols;col++) {
   const label=names[row*cols+col];if(!label)continue;
   const left=Math.round(col*width/cols),top=Math.round(row*height/rows);
   // The Betshuva house in this atlas spans the last two rows.
   const bottom=file.includes('00.02.00') && row===4 && col===7 ? height:Math.round((row+1)*height/rows);
   await emit(file,label,{left,top,width:Math.round((col+1)*width/cols)-left,height:bottom-top});
  }
 }
 await emit('User attachment.png','ישראל כאן בשבילך');
 await emit('WhatsApp Image 2026-09-06 at 23.59.11.jpeg','זהירות מקישור לא ידוע');
 const catalog={version:3,updatedAt:'2026-09-07T00:00:00+03:00',provenance:'User-provided original files in /home/yaniv/Emoji; atlas cells extracted without redrawing',categories:[{id:'user-stickers',title:'מדבקות בתשובה',path:'user-20260907',prefix:'sticker',extension:'png',labels}]};
 await fs.writeFile(path.join(root,'expression-library','catalog.json'),JSON.stringify(catalog,null,2)+'\n');
 console.log(`Imported ${labels.length} stickers`);
})().catch(e=>{console.error(e);process.exitCode=1});
