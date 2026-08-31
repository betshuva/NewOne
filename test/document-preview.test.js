'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const ExcelJS = require('exceljs');
const { createDocumentPreview } = require('../server/document-preview');

test('Excel preview returns sheets and stored formula results without evaluation', async () => {
  const workbook = new ExcelJS.Workbook();
  const first = workbook.addWorksheet('ראשי');
  first.addRow(['שם', 'סכום']);
  first.addRow(['בדיקה', { formula: '1+1', result: 2 }]);
  workbook.addWorksheet('נוסף').addRow(['ערך']);
  const buffer = Buffer.from(await workbook.xlsx.writeBuffer());
  const preview = await createDocumentPreview(buffer, 'report.xlsx',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
  assert.equal(preview.kind, 'excel');
  assert.deepEqual(preview.sheets.map(sheet => sheet.name), ['ראשי', 'נוסף']);
  assert.equal(preview.sheets[0].rows[1][1], '2');
});

test('document preview endpoint is authenticated, access-scoped and approved-only', () => {
  const source = fs.readFileSync(path.join(__dirname, '..', 'server', 'index.js'), 'utf8');
  const start = source.indexOf("app.post('/api/document-preview'");
  const endpoint = source.slice(start, start + 3500);
  assert.notEqual(start, -1);
  assert.match(endpoint, /auth, messageRateLimit/);
  assert.match(endpoint, /moderation_status='approved'/);
  assert.match(endpoint, /m\.sender_id=\$1 OR m\.recipient_id=\$1/);
  assert.match(endpoint, /group_members/);
});

test('Word and Excel viewers are available in private, group and media screens', () => {
  const source = fs.readFileSync(
    path.join(__dirname, '..', 'flutter_app', 'lib', 'main.dart'), 'utf8');
  assert.match(source, /class _OfficeDocumentScreen/);
  assert.match(source, /class _OfficeDocumentPreview/);
  assert.ok((source.match(/_openOfficeInsideApp\(/g) || []).length >= 5);
  assert.match(source, /_OfficeDocumentPreview\([\s\S]{0,180}token: token/);
  assert.match(source, /_OfficeDocumentPreview\([\s\S]*?token: widget\.token/);
});
