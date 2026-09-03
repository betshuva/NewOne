'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const main = fs.readFileSync(
  path.join(__dirname, '..', 'flutter_app', 'lib', 'main.dart'), 'utf8');
const scanner = fs.readFileSync(
  path.join(__dirname, '..', 'flutter_app', 'lib', 'document_scanner.dart'),
  'utf8');

test('private and group menus offer document scanning by photo', () => {
  const labels = main.match(/label: 'סריקת מסמך בצילום'/g) || [];
  assert.equal(labels.length, 2);
  assert.match(main,
    /_recipientAllowsText[\s\S]*?_scanDocument\(\)/);
  assert.match(main,
    /_groupAllowsText[\s\S]*?_scanDocument\(\)/);
});

test('document scanner supports preview, removal and up to twenty PDF pages', () => {
  assert.match(scanner, /int maxPages = 20/);
  assert.match(scanner, /Image\.memory\(/);
  assert.match(scanner, /מחק עמוד/);
  assert.match(scanner, /צלם עמוד נוסף/);
  assert.match(scanner, /הכן PDF/);
  assert.match(scanner, /for \(final pageBytes in pages\)/);
  assert.match(scanner, /pw\.Document\(\)/);
  assert.match(scanner, /PdfPageFormat\.a4/);
  assert.match(scanner, /mimeType: 'application\/pdf'/);
});

test('scanned PDF requires destination confirmation and uses normal document upload', () => {
  assert.match(scanner, /המסמך יישלח אל \$destinationName כקובץ PDF/);
  assert.match(scanner, /צור ושלח/);
  assert.match(main,
    /scanDocumentToPdf\([\s\S]*?_uploadAndSend\(pdf, pdf\.name, 'document'\)/);
  assert.match(main,
    /scanDocumentToPdf\([\s\S]*?_uploadGroupFile\(pdf, pdf\.name, 'document'\)/);
});
