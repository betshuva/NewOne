const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const root = path.join(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');

test('public home identifies the free beta and its operator', () => {
  const home = read('home.html');

  assert.match(home, /בטא פתוחה ללא תשלום/);
  assert.match(home, /מופעל על ידי בתשובה פתרונות דיגיטליים בע״מ/);
  assert.match(home, /517401238/);
  assert.match(home, /\/betshuva-app\/terms/);
  assert.match(home, /\/betshuva-app\/privacy/);
});

test('legal pages consistently identify the company as operator', () => {
  for (const file of ['terms.html', 'privacy.html', 'delete-account.html']) {
    assert.match(read(file), /בתשובה פתרונות דיגיטליים בע״מ/, `${file} does not identify the operator`);
    assert.match(read(file), /517401238/, `${file} does not include the company number`);
  }
});

test('Google Play Data Safety declares required gender collection as other info', () => {
  const dataSafety = read('google-play-data-safety-corrected.csv');

  assert.match(
    dataSafety,
    /PSL_DATA_TYPES_PERSONAL,PSL_OTHER_PERSONAL,true,/,
  );
  assert.match(
    dataSafety,
    /PSL_OTHER_PERSONAL:DATA_USAGE_USER_CONTROL,PSL_DATA_USAGE_USER_CONTROL_REQUIRED,true,/,
  );
});

test('public child safety standards include the required protections and contact', () => {
  const childSafety = read('child-safety.html');

  assert.match(childSafety, /BETSHUVA/);
  assert.match(childSafety, /CSAE/);
  assert.match(childSafety, /CSAM/);
  assert.match(childSafety, /דיווח בתוך האפליקציה/);
  assert.match(childSafety, /support@betshuva\.com/);
  assert.match(childSafety, /מוקד 105/);
});

test('every registration flow exposes the full legal documents before acceptance', () => {
  const app = read('flutter_app/lib/main.dart');
  const usages = app.match(/_TermsAgreementTile\(/g) || [];

  // One constructor declaration and three registration-flow usages.
  assert.equal(usages.length, 4);
  assert.match(app, /_LegalDocumentLink\(label: 'תנאי השימוש', path: '\/terms'\)/);
  assert.match(app, /_LegalDocumentLink\(label: 'מדיניות הפרטיות', path: '\/privacy'\)/);
  assert.match(app, /decoration: TextDecoration\.underline/);
  assert.doesNotMatch(
    app,
    /Text\('קראתי ואני מסכים\/ה לתנאי השימוש ולמדיניות הפרטיות'/,
  );
});
