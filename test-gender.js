// סקריפט בדיקה: node test-gender.js <path-to-image>
// דוגמה:        node test-gender.js /tmp/photo.jpg

// patch: util.isNullOrUndefined הוסר ב-Node.js 24 אבל tfjs-node עדיין משתמש בו
const util = require('util');
if (!util.isNullOrUndefined) util.isNullOrUndefined = (v) => v == null;

const tf      = require('@tensorflow/tfjs-node');
const faceapi = require('@vladmandic/face-api');
const path    = require('path');
const fs      = require('fs');

async function main() {
  const imgPath = process.argv[2];
  if (!imgPath) {
    console.error('שימוש: node test-gender.js <נתיב-לתמונה>');
    process.exit(1);
  }
  if (!fs.existsSync(imgPath)) {
    console.error('קובץ לא נמצא:', imgPath);
    process.exit(1);
  }

  console.log('טוען מודלים...');
  const dir = path.join(__dirname, 'server', 'models');
  await faceapi.nets.ssdMobilenetv1.loadFromDisk(dir);
  await faceapi.nets.faceLandmark68Net.loadFromDisk(dir);
  await faceapi.nets.ageGenderNet.loadFromDisk(dir);
  console.log('מודלים נטענו ✓\n');

  const buffer     = fs.readFileSync(imgPath);
  const tensor     = tf.node.decodeImage(buffer, 3);
  const detections = await faceapi.detectAllFaces(tensor)
    .withFaceLandmarks()
    .withAgeAndGender();
  tensor.dispose();

  if (detections.length === 0) {
    console.log('לא זוהו פנים בתמונה.');
    return;
  }

  console.log(`זוהו ${detections.length} פנים:\n`);
  detections.forEach((d, i) => {
    const isFemale  = d.gender === 'female';
    const pct       = Math.round(d.genderProbability * 100);
    const blocked   = isFemale && d.genderProbability >= 0.75;
    console.log(`פנים ${i + 1}:`);
    console.log(`  מין:    ${isFemale ? '👩 אישה' : '👨 גבר'} (${pct}% ביטחון)`);
    console.log(`  גיל:    ~${Math.round(d.age)}`);
    console.log(`  תוצאה: ${blocked ? '⛔ תיחסם' : '✅ תעבור'}`);
    console.log();
  });
}

main().catch(e => { console.error(e); process.exit(1); });
