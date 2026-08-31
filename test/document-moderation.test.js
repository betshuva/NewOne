'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const ExcelJS = require('exceljs');
const sharp = require('sharp');
const { documentLimits, extractXlsx, mergedClassification, scanDocument,
  scanVisuals } =
  require('../server/document-moderation');

test('document limits reject invalid environment values', () => {
  const limits = documentLimits({
    DOCUMENT_MAX_PDF_PAGES: '-1',
    DOCUMENT_MAX_DOCX_IMAGES: '12',
    DOCUMENT_MAX_EXTRACTED_MB: '0',
    DOCUMENT_MAX_RENDER_PIXELS: '1000000',
  });
  assert.equal(limits.maxPdfPages, 40);
  assert.equal(limits.maxDocxImages, 12);
  assert.equal(limits.maxExtractedBytes, 50 * 1024 * 1024);
  assert.equal(limits.maxRenderPixels, 1_000_000);
});

test('embedded visuals merge all detected categories', () => {
  assert.deepEqual(mergedClassification([
    { classification: { category: 'men', detectedCategories: ['men'] } },
    { classification: { category: 'children', detectedCategories: ['children'] } },
  ]), {
    category: 'people',
    detectedCategories: ['men', 'children'],
    uncertain: false,
  });
});

test('document scan stops and identifies the blocked visual', async () => {
  let calls = 0;
  const result = await scanVisuals([Buffer.from('a'), Buffer.from('b'),
    Buffer.from('c')], async () => {
    calls++;
    return calls === 2
      ? { blocked: true, blockedBy: 'testPolicy', reason: 'blocked' }
      : { blocked: false, classification: { detectedCategories: ['men'] } };
  }, 'עמוד');
  assert.equal(calls, 2);
  assert.equal(result.blocked, true);
  assert.equal(result.blockedBy, 'testPolicy');
  assert.equal(result.documentVisualScan.failedAt, 'עמוד 2');
});

test('pending embedded visual keeps the whole document pending', async () => {
  const result = await scanVisuals([Buffer.from('a')],
    async () => ({ pending: true }), 'תמונה');
  assert.equal(result.pending, true);
  assert.equal(result.documentVisualScan.pendingAt, 'תמונה 1');
});

test('XLSX scans hidden sheets, formulas, notes, links and embedded images', async () => {
  const workbook = new ExcelJS.Workbook();
  const visible = workbook.addWorksheet('Visible');
  visible.getCell('A1').value = { formula: 'SUM(1,2)', result: 3 };
  visible.getCell('A1').note = 'review note';
  visible.getCell('A2').value = { text: 'safe link',
    hyperlink: 'https://example.test/path' };
  const hidden = workbook.addWorksheet('Secret', { state: 'veryHidden' });
  hidden.getCell('B2').value = 'hidden marker';
  const png = await sharp({ create: { width: 8, height: 8, channels: 3,
    background: '#ffffff' } }).png().toBuffer();
  const imageId = workbook.addImage({ buffer: png, extension: 'png' });
  visible.addImage(imageId, 'C1:D3');
  const bytes = Buffer.from(await workbook.xlsx.writeBuffer());

  const extracted = await extractXlsx(bytes, documentLimits({}));
  assert.match(extracted.text, /sum\(1,2\)/i);
  assert.match(extracted.text, /review note/i);
  assert.match(extracted.text, /example\.test/i);
  assert.match(extracted.text, /hidden marker/i);
  assert.equal(extracted.images.length, 1);

  let imagesScanned = 0;
  const result = await scanDocument(bytes,
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', {
      scanImage: async () => {
        imagesScanned++;
        return { blocked: false, classification: {
          category: 'nonHumanImages', detectedCategories: ['nonHumanImages'] } };
      },
    });
  assert.equal(result.blocked, false);
  assert.equal(imagesScanned, 1);
  assert.equal(result.documentVisualScan.total, 1);
});
