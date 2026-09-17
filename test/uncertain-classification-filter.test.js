'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const source = fs.readFileSync(
  path.join(__dirname, '..', 'server', 'index.js'), 'utf8');
const { imageAllowedByFilter } = require('../server/content-filter-policy');

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

test('unresolved image classifications require every people category, even a tentative landscape', () => {
  const allowed = { men: true, women: true, children: true, nonHumanImages: false };
  for (const classification of [{ uncertain: true }, { category: 'nonHumanImages', uncertain: true }]) {
    assert.equal(imageAllowedByFilter(allowed, classification), true);
    for (const category of ['men', 'women', 'children'])
      assert.equal(imageAllowedByFilter({ ...allowed, [category]: false }, classification), false);
  }
});

test('raw legacy filters permit landscapes while preserving mixed-image restrictions', () => {
  const filter = { men: false, women: false, children: false, nonHumanImages: false };
  for (const classification of [
    { category: 'nonHumanImages' },
    { detectedCategories: ['nonHumanImages'] },
  ]) assert.equal(imageAllowedByFilter(filter, classification), true);
  for (const category of ['men', 'women', 'children', 'people'])
    assert.equal(imageAllowedByFilter(filter, {
      detectedCategories: ['nonHumanImages', category],
    }), false);
});

test('uncertain destination-filter rejections explain the conservative decision', () => {
  assert.match(
    source,
    /הסיווג אינו ודאי ולכן התמונה נחסמה בהתאם להגדרות הסינון/,
  );
});
