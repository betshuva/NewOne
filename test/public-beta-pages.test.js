const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const root = path.join(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');

test('public home identifies the free beta and its operator', () => {
  const home = read('home.html');

  assert.match(home, /בטא פתוחה ללא תשלום/);
  assert.match(home, /מופעלת על ידי יניב אליהו/);
  assert.match(home, /\/betshuva-app\/terms/);
  assert.match(home, /\/betshuva-app\/privacy/);
});

test('legal pages consistently identify the beta operator', () => {
  for (const file of ['terms.html', 'privacy.html', 'delete-account.html']) {
    assert.match(read(file), /יניב אליהו/, `${file} does not identify the operator`);
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
