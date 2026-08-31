'use strict';

const mammoth = require('mammoth');
const ExcelJS = require('exceljs');

const MAX_WORD_CHARS = 200_000;
const MAX_SHEETS = 20;
const MAX_ROWS_PER_SHEET = 300;
const MAX_COLUMNS = 60;
const MAX_CELLS = 12_000;

function cellDisplayValue(cell) {
  const value = cell.value;
  if (value == null) return '';
  if (value instanceof Date) return value.toISOString();
  if (typeof value !== 'object') return String(value).slice(0, 2000);
  if (Array.isArray(value.richText)) {
    return value.richText.map(part => part.text || '').join('').slice(0, 2000);
  }
  if (value.formula || value.sharedFormula) {
    return (value.result == null
      ? `=${value.formula || value.sharedFormula}` : String(value.result)).slice(0, 2000);
  }
  if (value.text != null) return String(value.text).slice(0, 2000);
  if (value.hyperlink != null)
    return String(value.text || value.hyperlink).slice(0, 2000);
  return String(value.result ?? '').slice(0, 2000);
}

async function previewDocx(buffer) {
  const converted = await mammoth.extractRawText({ buffer });
  const fullText = String(converted.value || '').replace(/\r\n?/g, '\n').trim();
  return { kind: 'word', text: fullText.slice(0, MAX_WORD_CHARS),
    truncated: fullText.length > MAX_WORD_CHARS };
}

async function previewXlsx(buffer) {
  const workbook = new ExcelJS.Workbook();
  await workbook.xlsx.load(buffer, { ignoreNodes: ['dataValidations'] });
  let cells = 0;
  let truncated = workbook.worksheets.length > MAX_SHEETS;
  const sheets = [];
  for (const worksheet of workbook.worksheets.slice(0, MAX_SHEETS)) {
    const rows = [];
    const sourceRows = worksheet.actualRowCount || worksheet.rowCount;
    const sourceColumns = worksheet.actualColumnCount || worksheet.columnCount;
    const lastRow = Math.min(sourceRows, MAX_ROWS_PER_SHEET);
    const columnCount = Math.min(Math.max(sourceColumns, 1), MAX_COLUMNS);
    if (sourceRows > lastRow || sourceColumns > columnCount) truncated = true;
    for (let rowNumber = 1; rowNumber <= lastRow; rowNumber++) {
      if (cells + columnCount > MAX_CELLS) { truncated = true; break; }
      const row = worksheet.getRow(rowNumber);
      rows.push(Array.from({ length: columnCount }, (_, index) =>
        cellDisplayValue(row.getCell(index + 1))));
      cells += columnCount;
    }
    sheets.push({ name: worksheet.name, rows, columnCount });
    if (cells >= MAX_CELLS) break;
  }
  return { kind: 'excel', sheets, truncated };
}

async function createDocumentPreview(buffer, fileName, mimeType) {
  const lower = String(fileName || '').toLowerCase();
  if (lower.endsWith('.docx') || mimeType ===
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document') {
    return previewDocx(buffer);
  }
  if (lower.endsWith('.xlsx') || mimeType ===
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet') {
    return previewXlsx(buffer);
  }
  throw Object.assign(new Error('Unsupported document preview type'),
    { code: 'UNSUPPORTED_PREVIEW' });
}

module.exports = { createDocumentPreview };
