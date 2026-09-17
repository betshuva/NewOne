'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { mediaLibraryName } = require('../server/media-library-name');

test('rename preserves the exact original extension for full names and basenames', () => {
  assert.equal(mediaLibraryName('שם חדש', 'photo.JPG'), 'שם חדש.JPG');
  assert.equal(mediaLibraryName('שם חדש.jpg', 'photo.JPG'), 'שם חדש.JPG');
  assert.equal(mediaLibraryName('שם חדש.JPG', 'photo.JPG'), 'שם חדש.JPG');
  assert.equal(mediaLibraryName('report.PDF', 'original.pdf'), 'report.pdf');
  assert.equal(mediaLibraryName('  קובץ חדש  ', 'original.PnG'), 'קובץ חדש.PnG');
});

test('dots in a basename cannot change or remove the stored extension', () => {
  assert.equal(mediaLibraryName('photo.v2', 'original.JPG'), 'photo.v2.JPG');
  assert.equal(mediaLibraryName('photo.pdf', 'original.JPG'), 'photo.pdf.JPG');
  assert.equal(mediaLibraryName('photo.v2.jpg', 'original.JPG'), 'photo.v2.JPG');
  assert.equal(mediaLibraryName('report', 'original'), 'report');
});

test('rename rejects empty basenames, paths and control characters', () => {
  for (const name of [null, 7, '', ' ', '.', '..', '.jpg', '.JPG', '..jpg',
    '../photo', 'folder/photo', 'folder\\photo', 'bad\u0000name', 'bad\nname']) {
    assert.equal(mediaLibraryName(name, 'original.JPG'), null, String(name));
  }
});

test('rename normalizes Unicode and includes the fixed extension in the length limit', () => {
  assert.equal(mediaLibraryName('cafe\u0301', 'original.PNG'), 'café.PNG');
  const maximum = 'א'.repeat(251);
  assert.equal(mediaLibraryName(maximum, 'original.PNG'), maximum + '.PNG');
  assert.equal(mediaLibraryName('א'.repeat(252), 'original.PNG'), null);
  const supplementary = '😀'.repeat(251);
  assert.equal(mediaLibraryName(supplementary, 'original.PNG'), supplementary + '.PNG');
});
