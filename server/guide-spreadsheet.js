'use strict';

const ExcelJS = require('exceljs');

const MIME_TYPE = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
const LIMITS = Object.freeze({
  tables: 5,
  columns: 20,
  rows: 10000,
  cellCharacters: 32000,
  inputBytes: 4 * 1024 * 1024,
  outputBytes: 10 * 1024 * 1024,
});

class SpreadsheetValidationError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'SpreadsheetValidationError';
    this.code = code;
  }
}

function invalid(code, message) {
  throw new SpreadsheetValidationError(code, message);
}

function plainText(value) {
  // XML cannot represent these control characters or unpaired surrogates.
  return value.replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\uFFFE\uFFFF]/g, '')
    .replace(/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/g, '\uFFFD');
}

function truncate(value, length) {
  return value.slice(0, length).replace(/[\uD800-\uDBFF]$/, '');
}

function excelText(value) {
  // Excel interprets these escapes even in string cells. Escape literal input
  // so a name such as "_x0041_" does not change when the workbook is opened.
  return value.replace(/_x[0-9a-fA-F]{4}_/g, token => `_x005F_${token.slice(1)}`);
}

function validateSpreadsheetInput(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input) ||
      (input.title !== undefined && typeof input.title !== 'string') ||
      !Array.isArray(input.tables) || !input.tables.length) {
    invalid('invalid_table', 'יש לספק לפחות טבלה אחת עם כותרות ושורות.');
  }
  if (input.tables.length > LIMITS.tables) invalid('too_many_tables', 'ניתן לייצא עד 5 טבלאות בקובץ אחד.');
  let rowCount = 0;
  let inputBytes = 0;
  const text = value => {
    if (value.length > LIMITS.cellCharacters) invalid('cell_too_long', 'אחד הערכים בטבלה ארוך מדי לייצוא ל־Excel.');
    inputBytes += Buffer.byteLength(value, 'utf8');
    if (inputBytes > LIMITS.inputBytes) invalid('input_too_large', 'המידע גדול מדי לקובץ אחד. יש לצמצם את הבקשה.');
    return plainText(value);
  };
  const title = text(input.title || 'טבלה');
  const tables = Array.from(input.tables, table => {
    if (!table || typeof table !== 'object' || Array.isArray(table) ||
        (table.title !== undefined && typeof table.title !== 'string') ||
        !Array.isArray(table.columns) || !table.columns.length || !Array.isArray(table.rows)) {
      invalid('invalid_table', 'לכל טבלה דרושות כותרות עמודות ורשימת שורות.');
    }
    if (table.columns.length > LIMITS.columns) invalid('too_many_columns', 'ניתן לייצא עד 20 עמודות בטבלה.');
    rowCount += table.rows.length;
    if (rowCount > LIMITS.rows) invalid('too_many_rows', 'ניתן לייצא עד 10,000 שורות בקובץ אחד. יש לצמצם את הבקשה.');
    const tableTitle = text(table.title || title);
    const columns = Array.from(table.columns, column => {
      if (typeof column !== 'string' || !column.trim()) invalid('invalid_columns', 'כל עמודה צריכה כותרת טקסט שאינה ריקה.');
      const heading = text(column);
      if (!heading.trim()) invalid('invalid_columns', 'כל עמודה צריכה כותרת טקסט שאינה ריקה.');
      return heading;
    });
    const rows = Array.from(table.rows, row => {
      if (!Array.isArray(row) || row.length !== columns.length) invalid('invalid_row', 'מספר הערכים בשורה אינו תואם למספר העמודות.');
      return Array.from(row, value => {
        if (value === null) return null;
        if (typeof value === 'string') return text(value);
        if (typeof value === 'number' && Number.isFinite(value)) {
          text(String(value));
          return value;
        }
        // Never pass caller-created formula, hyperlink or rich-text objects to
        // ExcelJS. Only primitive values can become workbook cells.
        invalid('invalid_cell', 'ערכי הטבלה צריכים להיות טקסט, מספר או תא ריק.');
      });
    });
    return { title: tableTitle, columns, rows };
  });
  return { title, tables, rowCount };
}

function sheetName(title, usedNames) {
  let base = title.replace(/[\[\]*?:\\/]/g, ' ').replace(/\s+/g, ' ').trim()
    .replace(/^'+|'+$/g, '').trim() || 'טבלה';
  if (base.toLowerCase() === 'history') base = 'History 1';
  base = truncate(base, 31).replace(/'+$/g, '').trim() || 'טבלה';
  let name = base;
  let suffix = 2;
  while (usedNames.has(name.toLowerCase())) {
    const ending = ` (${suffix++})`;
    name = truncate(base, 31 - ending.length) + ending;
  }
  usedNames.add(name.toLowerCase());
  return name;
}

function fileName(title) {
  const base = truncate(title.replace(/[<>:"/\\|?*\u0000-\u001F\u007F]/g, ' ')
    .replace(/\s+/g, ' ').replace(/^[.\s]+|[.\s]+$/g, ''), 80) || 'טבלה';
  return `${base.replace(/\.xlsx$/i, '') || 'טבלה'}.xlsx`;
}

/** Pure generation: no filesystem, database, network or ownership decisions. */
async function createGuideSpreadsheet(input) {
  const { title, tables, rowCount } = validateSpreadsheetInput(input);
  const workbook = new ExcelJS.Workbook();
  workbook.creator = 'בתשובה';
  workbook.title = title;
  const usedNames = new Set();
  for (const table of tables) {
    const sheet = workbook.addWorksheet(sheetName(table.title, usedNames), {
      views: [{ rightToLeft: true, state: 'frozen', ySplit: 1 }],
      properties: { defaultRowHeight: 20 },
      pageSetup: { orientation: 'landscape', fitToPage: true, fitToWidth: 1, fitToHeight: 0 },
    });
    sheet.addRow(table.columns.map(excelText));
    for (const values of table.rows) {
      const row = sheet.addRow(values.map(value => typeof value === 'string' ? excelText(value) : value));
      row.eachCell(cell => {
        cell.alignment = { horizontal: 'right', vertical: 'top', wrapText: true, readingOrder: 'rtl' };
        cell.font = { name: 'Arial', size: 11 };
        // Strings, including phone numbers and formula-looking text, stay text.
        if (cell.type === ExcelJS.ValueType.String) cell.numFmt = '@';
      });
    }
    sheet.getRow(1).eachCell(cell => {
      cell.font = { name: 'Arial', size: 11, bold: true, color: { argb: 'FFFFFFFF' } };
      cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FF1D6DA8' } };
      cell.alignment = { horizontal: 'right', vertical: 'middle', wrapText: true, readingOrder: 'rtl' };
      cell.numFmt = '@';
    });
    sheet.getRow(1).height = 28;
    table.columns.forEach((heading, index) => {
      let width = Math.max(heading.length + 3, 14);
      for (const row of table.rows) {
        width = Math.max(width, Math.min(String(row[index] ?? '').length + 2, 52));
      }
      const column = sheet.getColumn(index + 1);
      column.width = Math.min(width, 52);
      if (/טלפון|phone/i.test(heading)) {
        column.eachCell({ includeEmpty: false }, (cell, rowNumber) => {
          if (rowNumber > 1) cell.alignment = { ...cell.alignment, readingOrder: 'ltr' };
        });
      }
    });
    if (table.rows.length) sheet.autoFilter = {
      from: { row: 1, column: 1 }, to: { row: table.rows.length + 1, column: table.columns.length },
    };
  }
  const buffer = Buffer.from(await workbook.xlsx.writeBuffer());
  if (buffer.length > LIMITS.outputBytes) invalid('file_too_large', 'קובץ ה־Excel גדול מדי. יש לצמצם את הבקשה.');
  return { buffer, fileName: fileName(title), mimeType: MIME_TYPE, rowCount };
}

module.exports = { createGuideSpreadsheet, validateSpreadsheetInput, SpreadsheetValidationError, LIMITS, MIME_TYPE };
