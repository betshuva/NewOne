'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const ExcelJS = require('exceljs');
const JSZip = require('jszip');
const sharp = require('sharp');
const { documentLimits, extractXlsx, isPasswordProtectedDocumentError,
  mergedClassification, scanDocument, scanVisuals } =
  require('../server/document-moderation');

test('password-protected documents fail closed instead of retrying forever', () => {
  assert.equal(isPasswordProtectedDocumentError(
    new Error('No password given')), true);
  assert.equal(isPasswordProtectedDocumentError(
    new Error('File is encrypted')), true);
  assert.equal(isPasswordProtectedDocumentError(
    new Error('Temporary renderer unavailable')), false);
});

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
  assert.equal(result.documentVisualResults.length, 2);
  assert.equal(result.documentVisualResults[1].blockedBy, 'testPolicy');
});

test('pending embedded visual keeps the whole document pending', async () => {
  const result = await scanVisuals([Buffer.from('a')],
    async () => ({ pending: true }), 'תמונה');
  assert.equal(result.pending, true);
  assert.equal(result.documentVisualScan.pendingAt, 'תמונה 1');
  assert.deepEqual(result.documentVisualResults, [{ pending: true }]);
});

test('approved documents preserve original uncertainty and review evidence from every visual', async () => {
  const original = { available: true, decision: 'uncertain',
    visibleAreasDecision: 'uncertain', uncertaintyReason: 'visible_area_ambiguous' };
  const review = { provider: 'gemini', attempted: true, resolution: 'approved',
    result: { available: true, decision: 'modest', confidence: 0.96,
      visibleAreasDecision: 'compliant', uncertaintyReason: 'none' } };
  const visuals = [
    { blocked: false, classification: { category: 'men', detectedCategories: ['men'], uncertain: false } },
    { blocked: false, classification: { category: 'men', detectedCategories: ['men'], uncertain: false },
      geminiModestyVerification: original, modestyUncertaintyReview: review },
    { blocked: false, classification: { category: 'children', detectedCategories: ['children'], uncertain: false } },
  ];
  let calls = 0;
  const result = await scanVisuals([Buffer.from('a'), Buffer.from('b'), Buffer.from('c')],
    async () => visuals[calls++], 'עמוד');
  assert.equal(calls, 3);
  assert.equal(result.blocked, false);
  assert.equal(result.classification.uncertain, false);
  assert.deepEqual(result.documentVisualResults, visuals);
  assert.equal(result.documentVisualResults[1].geminiModestyVerification.decision, 'uncertain');
  assert.equal(result.documentVisualResults[1].modestyUncertaintyReview.resolution, 'approved');
});

test('a stopped visual is terminal even without classification or pending flags', async () => {
  let calls = 0;
  const stopped = { scanStopped: true, reasonCode: 'operation_outcome_unknown',
    reason: 'previous review result is unknown' };
  const result = await scanVisuals([Buffer.from('a'), Buffer.from('b')], async () => {
    calls++;
    return stopped;
  }, 'עמוד');
  assert.equal(calls, 1);
  assert.equal(result.scanStopped, true);
  assert.equal(result.stopped, true);
  assert.equal(result.blocked, false);
  assert.equal(result.pending, false);
  assert.equal(result.retryable, false);
  assert.equal(result.reasonCode, stopped.reasonCode);
  assert.equal(result.documentVisualScan.stoppedAt, 'עמוד 1');
  assert.deepEqual(result.documentVisualResults, [stopped]);
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
  assert.deepEqual(result.classification.documentVisualScan,
    { scanned: 1, total: 1 });
});

test('document messages expose a visible classification summary', () => {
  const source = require('node:fs').readFileSync(
    require('node:path').join(__dirname, '..', 'flutter_app', 'lib', 'main.dart'),
    'utf8');
  assert.match(source, /class _DocumentClassificationSummary/);
  assert.match(source, /סיווג: \$classificationText\$scanText/);
  assert.match(source,
    /if \(isFile && fileType == 'document'\)[\s\S]{0,180}_DocumentClassificationSummary/);
});

test('pending documents cannot be previewed or downloaded before approval', () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const client = fs.readFileSync(
    path.join(__dirname, '..', 'flutter_app', 'lib', 'main.dart'), 'utf8');
  const server = fs.readFileSync(
    path.join(__dirname, '..', 'server', 'index.js'), 'utf8');
  assert.match(client,
    /class _DocumentModerationCard[\s\S]*?לא ניתן לפתוח או להוריד אותו לפני אישור/);
  assert.match(client,
    /uploadFileType == 'document'[\s\S]{0,180}uploadStatus == 'pending_scan'/);
  assert.match(server,
    /moderation_status === 'pending'[\s\S]{0,220}status\(423\)/);
});

// This ordinary cross-reference-table PDF is accepted by pdf.js but rejected
// with "bad XRef entry" by the legacy parser previously used for text.
function makePdf(pageCount = 1) {
  const stream = 'BT /F1 18 Tf 50 750 Td (Document sending test) Tj ET\n';
  const objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    `<< /Type /Pages /Kids [${Array.from({ length: pageCount }, (_, i) => `${i + 5} 0 R`).join(' ')}] /Count ${pageCount} >>`,
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    `<< /Length ${Buffer.byteLength(stream)} >>\nstream\n${stream}endstream`,
    ...Array.from({ length: pageCount }, () =>
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 3 0 R >> >> /Contents 4 0 R >>'),
  ];
  let pdf = '%PDF-1.4\n';
  const offsets = [0];
  objects.forEach((object, index) => {
    offsets.push(Buffer.byteLength(pdf));
    pdf += `${index + 1} 0 obj\n${object}\nendobj\n`;
  });
  const xref = Buffer.byteLength(pdf);
  pdf += `xref\n0 ${offsets.length}\n0000000000 65535 f \n`;
  pdf += offsets.slice(1).map(offset =>
    `${String(offset).padStart(10, '0')} 00000 n \n`).join('');
  pdf += `trailer\n<< /Size ${offsets.length} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return Buffer.from(pdf);
}

function stoppedModestyResult() {
  return { blocked: false, pending: false, stopped: true, scanStopped: true,
    retryable: false, reasonCode: 'modesty_uncertain', reason: 'visible pixels remain ambiguous',
    classification: { category: 'men', detectedCategories: ['men'], uncertain: true },
    geminiModestyVerification: { available: true, decision: 'uncertain',
      visibleAreasDecision: 'uncertain', uncertaintyReason: 'visible_area_ambiguous' },
    modestyUncertaintyReview: { provider: 'gemini', attempted: true, resolution: 'unresolved',
      result: { available: true, decision: 'uncertain', confidence: 0.5 } } };
}

test('a stopped PDF page preserves its review evidence and stops the entire document', async () => {
  const stopped = stoppedModestyResult();
  let scans = 0;
  const result = await scanDocument(makePdf(3), 'application/pdf', {
    scanImage: async bytes => {
      assert.equal((await sharp(bytes).metadata()).format, 'jpeg');
      scans++;
      return scans === 2 ? stopped : { blocked: false,
        classification: { category: 'nonHumanImages', detectedCategories: ['nonHumanImages'] } };
    },
  });
  assert.equal(scans, 2);
  assert.equal(result.scanStopped, true);
  assert.equal(result.pending, false);
  assert.equal(result.retryable, false);
  assert.equal(result.reasonCode, 'modesty_uncertain');
  assert.deepEqual(result.documentVisualScan, { scanned: 2, total: 3, stoppedAt: 'עמוד 2' });
  assert.equal(result.classification.uncertain, true);
  assert.equal(result.documentVisualResults.length, 2);
  assert.deepEqual(result.documentVisualResults[1], stopped);
  assert.deepEqual(result.geminiModestyVerification, stopped.geminiModestyVerification);
  assert.deepEqual(result.modestyUncertaintyReview, stopped.modestyUncertaintyReview);
  assert.match(result.reason, /עמוד 2/);
});

async function makeDocxWithImages(imageCount = 2) {
  const zip = new JSZip();
  const png = await sharp({ create: { width: 8, height: 8, channels: 3,
    background: '#ffffff' } }).png().toBuffer();
  zip.file('[Content_Types].xml', '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>');
  zip.file('_rels/.rels', '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>');
  const images = Array.from({ length: imageCount }, (_, index) => {
    zip.file(`word/media/image${index + 1}.png`, png);
    return `<w:p><w:r><w:drawing><wp:inline><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:blipFill><a:blip r:embed="rIdImage${index + 1}"/></pic:blipFill></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>`;
  }).join('');
  zip.file('word/document.xml', `<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body><w:p><w:r><w:t>Ordinary safe document text</w:t></w:r></w:p>${images}</w:body></w:document>`);
  zip.file('word/_rels/document.xml.rels', `<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">${Array.from({ length: imageCount }, (_, index) => `<Relationship Id="rIdImage${index + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image${index + 1}.png"/>`).join('')}</Relationships>`);
  return zip.generateAsync({ type: 'nodebuffer' });
}

test('safe DOCX text cannot approve a stopped embedded visual', async () => {
  const stopped = stoppedModestyResult();
  let scans = 0;
  const result = await scanDocument(await makeDocxWithImages(),
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document', {
      scanImage: async bytes => {
        assert.equal((await sharp(bytes).metadata()).format, 'png');
        scans++;
        return stopped;
      },
      blockedWords: ['forbidden text'],
    });
  assert.equal(scans, 1);
  assert.equal(result.scanStopped, true);
  assert.equal(result.stopped, true);
  assert.equal(result.blocked, false);
  assert.equal(result.pending, false);
  assert.equal(result.reasonCode, stopped.reasonCode);
  assert.deepEqual(result.documentVisualScan,
    { scanned: 1, total: 2, stoppedAt: 'תמונה 1' });
  assert.deepEqual(result.documentVisualResults, [stopped]);
  assert.equal(result.classification.uncertain, true);
});

test('PDF scans rendered pages and extracts text with the same parser', async () => {
  let scans = 0;
  const scanImage = async bytes => {
    const metadata = await sharp(bytes).metadata();
    assert.equal(metadata.format, 'jpeg');
    assert.ok(metadata.width > 0 && metadata.height > 0);
    scans++;
    return { blocked: false };
  };
  const result = await scanDocument(makePdf(2), 'application/pdf', { scanImage });
  assert.equal(result.blocked, false);
  assert.equal(scans, 2);
  assert.deepEqual(result.documentVisualScan, { scanned: 2, total: 2 });
  const blocked = await scanDocument(makePdf(), 'application/pdf', {
    scanImage, blockedWords: ['DOCUMENT SENDING'],
  });
  assert.equal(blocked.blockedBy, 'documentText');
  assert.equal(scans, 2);
});

test('PDF limits and incomplete visual scans cannot release the document', async () => {
  const limited = await scanDocument(makePdf(2), 'application/pdf', {
    environment: { DOCUMENT_MAX_PDF_PAGES: '1' },
    scanImage: async () => assert.fail('over-limit PDF must not be scanned'),
  });
  assert.equal(limited.blockedBy, 'documentVisualLimit');
  const pending = await scanDocument(makePdf(), 'application/pdf', {
    scanImage: async () => ({ pending: true }),
  });
  assert.equal(pending.pending, true);
  const invalid = await scanDocument(Buffer.from('not a PDF'), 'application/pdf', {
    scanImage: async () => assert.fail('invalid PDF must not be scanned'),
  });
  assert.equal(invalid.blocked, true);
  assert.equal(invalid.blockedBy, 'documentInvalid');
  assert.notEqual(invalid.pending, true);
});

test('a truncated PDF is rejected while temporary image scan failures stay pending', async () => {
  const invalid = await scanDocument(Buffer.from(
    '%PDF-1.7\nIntentional invalid PDF test - no document objects.\n'), 'application/pdf', {
    scanImage: async () => assert.fail('corrupt PDF must not reach image scanning'),
  });
  assert.equal(invalid.blockedBy, 'documentInvalid');
  assert.equal(invalid.blocked, true);
  assert.notEqual(invalid.pending, true);
  const transient = await scanDocument(makePdf(), 'application/pdf', {
    scanImage: async () => { throw new Error('temporary scan service outage'); },
  });
  assert.equal(transient.pending, true);
  assert.notEqual(transient.blocked, true);
});
