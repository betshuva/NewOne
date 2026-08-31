'use strict';

const mammoth = require('mammoth');
const ExcelJS = require('exceljs');

const DEFAULT_MAX_PDF_PAGES = 40;
const DEFAULT_MAX_DOCX_IMAGES = 40;
const DEFAULT_MAX_EXTRACTED_BYTES = 50 * 1024 * 1024;
const DEFAULT_MAX_RENDER_PIXELS = 2_500_000;
const DEFAULT_MAX_XLSX_SHEETS = 100;
const DEFAULT_MAX_XLSX_CELLS = 100_000;

function positiveLimit(value, fallback) {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function documentLimits(environment = process.env) {
  return {
    maxPdfPages: positiveLimit(environment.DOCUMENT_MAX_PDF_PAGES,
      DEFAULT_MAX_PDF_PAGES),
    maxDocxImages: positiveLimit(environment.DOCUMENT_MAX_DOCX_IMAGES,
      DEFAULT_MAX_DOCX_IMAGES),
    maxExtractedBytes: positiveLimit(environment.DOCUMENT_MAX_EXTRACTED_MB, 50) *
      1024 * 1024,
    maxRenderPixels: positiveLimit(environment.DOCUMENT_MAX_RENDER_PIXELS,
      DEFAULT_MAX_RENDER_PIXELS),
    maxXlsxSheets: positiveLimit(environment.DOCUMENT_MAX_XLSX_SHEETS,
      DEFAULT_MAX_XLSX_SHEETS),
    maxXlsxCells: positiveLimit(environment.DOCUMENT_MAX_XLSX_CELLS,
      DEFAULT_MAX_XLSX_CELLS),
  };
}

function mergedClassification(results) {
  const detected = new Set();
  let uncertain = false;
  for (const result of results) {
    const classification = result?.classification;
    const categories = classification?.detectedCategories ||
      (classification?.category ? [classification.category] : []);
    categories.forEach(category => detected.add(category));
    uncertain ||= classification?.uncertain === true;
  }
  const detectedCategories = [...detected];
  return detectedCategories.length ? {
    category: detectedCategories.length === 1 ? detectedCategories[0] : 'people',
    detectedCategories,
    uncertain,
  } : null;
}

function visualFailure({ blockedBy, reason, location, scanned, total, results }) {
  return {
    blocked: true,
    blockedBy,
    reason,
    documentVisualScan: { scanned, total, failedAt: location },
    classification: mergedClassification(results),
  };
}

async function scanVisuals(visuals, scanImage, kind) {
  const results = [];
  for (let index = 0; index < visuals.length; index++) {
    const location = `${kind} ${index + 1}`;
    const result = await scanImage(visuals[index]);
    results.push(result);
    if (result?.blocked) return visualFailure({
      blockedBy: result.blockedBy || 'documentEmbeddedImage',
      reason: `המסמך נחסם — ${location} מכיל תוכן שלא אושר: ${result.reason || 'תוכן לא מאושר'}`,
      location,
      scanned: index + 1,
      total: visuals.length,
      results,
    });
    // Fail closed: a document is not delivered while one of its visuals has
    // not completed every required moderation stage.
    if (!result || result.pending) return {
      pending: true,
      reason: `סריקת המסמך ממתינה — לא ניתן להשלים את בדיקת ${location}`,
      documentVisualScan: { scanned: index + 1, total: visuals.length,
        pendingAt: location },
      classification: mergedClassification(results),
    };
  }
  return {
    blocked: false,
    documentVisualScan: { scanned: visuals.length, total: visuals.length },
    classification: mergedClassification(results),
  };
}

async function renderPdfPages(buffer, limits) {
  const [{ getDocument }, { createCanvas, DOMMatrix, ImageData, Path2D }] =
    await Promise.all([
      import('pdfjs-dist/legacy/build/pdf.mjs'),
      import('@napi-rs/canvas'),
    ]);
  // pdf.js checks these browser primitives while rendering some PDFs.
  globalThis.DOMMatrix ||= DOMMatrix;
  globalThis.ImageData ||= ImageData;
  globalThis.Path2D ||= Path2D;
  const loadingTask = getDocument({ data: new Uint8Array(buffer),
    isEvalSupported: false, useSystemFonts: false });
  const pdf = await loadingTask.promise;
  if (pdf.numPages > limits.maxPdfPages)
    throw Object.assign(new Error(`PDF contains ${pdf.numPages} pages`),
      { code: 'DOCUMENT_VISUAL_LIMIT' });
  const pages = [];
  try {
    for (let pageNumber = 1; pageNumber <= pdf.numPages; pageNumber++) {
      const page = await pdf.getPage(pageNumber);
      const base = page.getViewport({ scale: 1 });
      const scale = Math.min(2,
        Math.sqrt(limits.maxRenderPixels / Math.max(1, base.width * base.height)));
      const viewport = page.getViewport({ scale });
      const canvas = createCanvas(Math.max(1, Math.ceil(viewport.width)),
        Math.max(1, Math.ceil(viewport.height)));
      await page.render({ canvasContext: canvas.getContext('2d'), viewport }).promise;
      pages.push(await canvas.encode('jpeg', 88));
      page.cleanup();
    }
  } finally {
    await pdf.destroy();
  }
  return pages;
}

async function extractDocx(buffer, limits) {
  const images = [];
  let extractedBytes = 0;
  const converted = await mammoth.convertToHtml({ buffer }, {
    convertImage: mammoth.images.imgElement(async image => {
      if (images.length >= limits.maxDocxImages)
        throw Object.assign(new Error('DOCX image count limit exceeded'),
          { code: 'DOCUMENT_VISUAL_LIMIT' });
      const bytes = await image.read('base64');
      const imageBuffer = Buffer.from(bytes, 'base64');
      extractedBytes += imageBuffer.length;
      if (extractedBytes > limits.maxExtractedBytes)
        throw Object.assign(new Error('DOCX extracted image size limit exceeded'),
          { code: 'DOCUMENT_VISUAL_LIMIT' });
      images.push(imageBuffer);
      return { src: 'data:,' };
    }),
  });
  const text = converted.value.replace(/<[^>]*>/g, ' ').toLowerCase();
  return { text, images };
}

function excelCellText(cell) {
  const value = cell.value;
  const parts = [];
  if (value != null) {
    if (typeof value === 'object') {
      if (value.formula) parts.push(value.formula, value.result);
      else if (value.sharedFormula) parts.push(value.sharedFormula, value.result);
      else if (value.richText) parts.push(...value.richText.map(item => item.text));
      else if (value.text) parts.push(value.text);
      else parts.push(JSON.stringify(value));
    } else parts.push(value);
  }
  if (cell.note) parts.push(typeof cell.note === 'string'
    ? cell.note : JSON.stringify(cell.note));
  if (cell.hyperlink) parts.push(cell.hyperlink);
  return parts.filter(part => part != null).join(' ');
}

async function extractXlsx(buffer, limits) {
  const workbook = new ExcelJS.Workbook();
  // ExcelJS reads formula text/results but never evaluates formulas. This is
  // important: document moderation must not execute spreadsheet content.
  await workbook.xlsx.load(buffer, { ignoreNodes: ['dataValidations'] });
  if (workbook.worksheets.length > limits.maxXlsxSheets)
    throw Object.assign(new Error('XLSX sheet count limit exceeded'),
      { code: 'DOCUMENT_VISUAL_LIMIT' });
  const text = [];
  let cells = 0;
  for (const worksheet of workbook.worksheets) {
    // Hidden and veryHidden sheets are intentionally included.
    text.push(worksheet.name, worksheet.state || 'visible');
    worksheet.eachRow({ includeEmpty: false }, row => {
      row.eachCell({ includeEmpty: false }, cell => {
        cells++;
        if (cells > limits.maxXlsxCells)
          throw Object.assign(new Error('XLSX cell count limit exceeded'),
            { code: 'DOCUMENT_VISUAL_LIMIT' });
        text.push(excelCellText(cell));
      });
    });
  }
  const images = [];
  let extractedBytes = 0;
  for (const media of workbook.model.media || []) {
    if (media.type !== 'image' || !media.buffer) continue;
    if (images.length >= limits.maxDocxImages)
      throw Object.assign(new Error('XLSX image count limit exceeded'),
        { code: 'DOCUMENT_VISUAL_LIMIT' });
    const image = Buffer.from(media.buffer);
    extractedBytes += image.length;
    if (extractedBytes > limits.maxExtractedBytes)
      throw Object.assign(new Error('XLSX extracted image size limit exceeded'),
        { code: 'DOCUMENT_VISUAL_LIMIT' });
    images.push(image);
  }
  return { text: text.join(' ').toLowerCase(), images,
    sheetCount: workbook.worksheets.length, cellCount: cells };
}

async function scanDocument(buffer, mimetype, { scanImage, blockedWords = [],
  environment = process.env } = {}) {
  if (typeof scanImage !== 'function')
    throw new TypeError('scanImage is required');
  const limits = documentLimits(environment);
  try {
    let text = '';
    let visuals = [];
    let kind = 'תמונה';
    if (mimetype === 'application/pdf') {
      const pdfParse = require('pdf-parse');
      const parsed = await pdfParse(buffer);
      text = String(parsed.text || '').toLowerCase();
      visuals = await renderPdfPages(buffer, limits);
      kind = 'עמוד';
    } else if (mimetype ===
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet') {
      const xlsx = await extractXlsx(buffer, limits);
      text = xlsx.text;
      visuals = xlsx.images;
      kind = 'תמונה בגיליון';
    } else {
      const docx = await extractDocx(buffer, limits);
      text = docx.text;
      visuals = docx.images;
    }
    const found = blockedWords.find(word => text.includes(String(word).toLowerCase()));
    if (found) return {
      blocked: true,
      blockedBy: 'documentText',
      reason: 'המסמך נחסם — תוכן טקסטואלי לא הולם',
      documentVisualScan: { scanned: 0, total: visuals.length },
    };
    return scanVisuals(visuals, scanImage, kind);
  } catch (error) {
    if (error?.code === 'DOCUMENT_VISUAL_LIMIT') return {
      blocked: true,
      blockedBy: 'documentVisualLimit',
      reason: 'המסמך גדול או מורכב מדי לסריקה בטוחה',
      error: error.message,
    };
    return {
      pending: true,
      blockedBy: 'documentDecode',
      reason: 'לא ניתן לפענח ולסרוק את כל תוכן המסמך כרגע',
      error: error?.message || String(error),
    };
  }
}

module.exports = { documentLimits, excelCellText, extractXlsx,
  mergedClassification, scanDocument, scanVisuals };
