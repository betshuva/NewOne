'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const source = fs.readFileSync(
  path.join(__dirname, '..', 'server', 'index.js'),
  'utf8',
);

const imageFilterStart = source.indexOf('function imageAllowedByFilter');
const imageFilterEnd = source.indexOf('function contentAllowedByFilter', imageFilterStart);
const imageAllowedByFilter = Function(
  `return (${source.slice(imageFilterStart, imageFilterEnd).trim()})`,
)();

test('people umbrella does not override a permitted specific classification', () => {
  const filter = {
    video: true,
    men: true,
    women: false,
    children: false,
    nonHumanImages: false,
  };
  assert.equal(imageAllowedByFilter(filter, {
    detectedCategories: ['video', 'men', 'people'],
  }), true);
  assert.equal(imageAllowedByFilter({ ...filter, men: false }, {
    detectedCategories: ['video', 'men', 'people'],
  }), false);
});

test('people-only classification remains conservative', () => {
  const partial = { men: true, women: true, children: false };
  assert.equal(imageAllowedByFilter(partial, {
    detectedCategories: ['people'],
  }), false);
  assert.equal(imageAllowedByFilter({ ...partial, children: true }, {
    detectedCategories: ['people'],
  }), true);
});

test('unresolved image classifications require every image category', () => {
  const start = source.indexOf('function imageAllowedByFilter');
  const end = source.indexOf('function contentAllowedByFilter', start);
  const filterSource = source.slice(start, end);
  assert.match(filterSource, /classification\?\.uncertain === true/);
  assert.match(filterSource, /\['men', 'women', 'children', 'nonHumanImages'\]/);
  assert.match(filterSource, /\.every\(category => filter\[category\] === true\)/);
  assert.doesNotMatch(filterSource, /uncertain[\s\S]*return true/);
});

test('uncertain destination-filter rejections explain the conservative decision', () => {
  assert.match(
    source,
    /הסיווג אינו ודאי ולכן התמונה נחסמה בהתאם להגדרות הסינון/,
  );
});
