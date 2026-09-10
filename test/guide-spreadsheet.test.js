'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const ExcelJS = require('exceljs');
const { createGuideSpreadsheet, validateSpreadsheetInput, SpreadsheetValidationError, LIMITS, MIME_TYPE } =
  require('../server/guide-spreadsheet');

const table = (overrides = {}) => ({ columns: ['שם', 'טלפון', 'עיר מגורים'],
  rows: [['חבר לדוגמה', '0500000012', 'ירושלים']], ...overrides });
const input = (overrides = {}) => ({ title: 'חברי קבוצת המטיילים', tables: [table()], ...overrides });

test('produces readable RTL Excel with Hebrew, leading-zero phones and frozen headers', async () => {
  const result = await createGuideSpreadsheet(input());
  assert.ok(Buffer.isBuffer(result.buffer));
  assert.equal(result.buffer.subarray(0, 2).toString(), 'PK');
  assert.equal(result.fileName, 'חברי קבוצת המטיילים.xlsx');
  assert.equal(result.mimeType, MIME_TYPE);
  assert.equal(result.rowCount, 1);
  const book = await new ExcelJS.Workbook().xlsx.load(result.buffer);
  assert.equal(book.worksheets.length, 1);
  const sheet = book.worksheets[0];
  assert.equal(sheet.views[0].rightToLeft, true);
  assert.equal(sheet.views[0].state, 'frozen');
  assert.equal(sheet.views[0].ySplit, 1);
  assert.equal(sheet.getCell('A1').value, 'שם');
  assert.equal(sheet.getCell('A1').font.bold, true);
  assert.equal(sheet.getCell('A2').value, 'חבר לדוגמה');
  assert.equal(sheet.getCell('B2').value, '0500000012');
  assert.equal(sheet.getCell('B2').numFmt, '@');
  assert.equal(sheet.getCell('B2').alignment.readingOrder, 'ltr');
  assert.equal(sheet.getCell('C2').value, 'ירושלים');
  assert.ok(sheet.getColumn(2).width >= 14);
  assert.equal(sheet.autoFilter, 'A1:C2');
});

test('data stays literal text without formulas, hyperlinks or XML interpretation', async () => {
  const values = ['=HYPERLINK("https://example.com", "open")', '+SUM(A1:A2)', '-1+2', '@SUM(A1)',
    'https://example.com', '<tag>& "חבר" 😀', '_x0041_', '_x005F_', ' שורה\nשנייה '];
  const result = await createGuideSpreadsheet(input({ tables: [table({ columns: ['ערך'], rows: values.map(value => [value]) })] }));
  const sheet = (await new ExcelJS.Workbook().xlsx.load(result.buffer)).worksheets[0];
  values.forEach((value, index) => {
    const cell = sheet.getCell(index + 2, 1);
    assert.equal(cell.type, ExcelJS.ValueType.String);
    assert.equal(cell.value, value);
    assert.equal(cell.formula, undefined);
    assert.equal(cell.hyperlink, undefined);
  });
});

test('supports multiple tables, numeric counts and empty rows with unique safe sheet names', async () => {
  const result = await createGuideSpreadsheet(input({ title: '../../טבלה.xlsx', tables: [
    table({ title: "'קבוצה/[א]*?'", columns: ['שם', 'כמות'], rows: [['דוגמה', 12], [null, 0]] }),
    table({ title: "'קבוצה/[א]*?'", rows: [] }),
    table({ title: 'History', rows: [] }),
    table({ title: '😀'.repeat(30), rows: [] }),
    table({ title: '😀'.repeat(30), rows: [] }),
  ] }));
  assert.equal(result.rowCount, 2);
  assert.ok(!/[\\/]/.test(result.fileName));
  assert.ok(!result.fileName.startsWith('.'));
  assert.ok(result.fileName.endsWith('.xlsx'));
  assert.ok(!result.fileName.endsWith('.xlsx.xlsx'));
  const sheets = (await new ExcelJS.Workbook().xlsx.load(result.buffer)).worksheets;
  assert.equal(sheets.length, 5);
  assert.equal(new Set(sheets.map(sheet => sheet.name)).size, 5);
  for (const sheet of sheets) {
    assert.ok(sheet.name.length <= 31);
    assert.ok(!/[\[\]*?:\\/]/.test(sheet.name));
    assert.ok(!sheet.name.startsWith("'") && !sheet.name.endsWith("'"));
  }
  assert.equal(sheets[0].getCell('B2').value, 12);
  assert.equal(sheets[0].getCell('B3').value, 0);
  assert.equal(sheets[0].getCell('A3').value, null);
  assert.equal(sheets[1].rowCount, 1);
});

test('rejects malformed data and ExcelJS formula or hyperlink objects before generation', async () => {
  for (const malformed of [null, [], {}, input({ tables: [] }), input({ title: {} }),
    input({ tables: [null] }), input({ tables: [table({ title: {} })] }),
    input({ tables: [table({ columns: [] })] }), input({ tables: [table({ columns: [''] })] }),
    input({ tables: [table({ columns: ['\u0000'] })] }), input({ tables: [table({ rows: Array(1) })] }),
    input({ tables: [table({ rows: [Array(3)] })] }), input({ tables: Array(1) }),
    input({ tables: [table({ columns: [7] })] }), input({ tables: [table({ rows: [['short']] })] }),
    ...[{ formula: '1+1' }, { text: 'click', hyperlink: 'https://example.com' }, undefined, true, Infinity, NaN]
      .map(value => input({ tables: [table({ columns: ['ערך'], rows: [[value]] })] }))]) {
    await assert.rejects(createGuideSpreadsheet(malformed), error => error instanceof SpreadsheetValidationError && !!error.code);
  }
});

test('enforces table, column, total row, cell and total input limits without silently truncating records', () => {
  const cases = [
    [input({ tables: Array.from({ length: LIMITS.tables + 1 }, () => table({ rows: [] })) }), 'too_many_tables'],
    [input({ tables: [table({ columns: Array(LIMITS.columns + 1).fill('שם'), rows: [] })] }), 'too_many_columns'],
    [input({ tables: [table({ columns: ['שם'], rows: Array(LIMITS.rows + 1).fill(['א']) })] }), 'too_many_rows'],
    [input({ tables: [table({ columns: ['שם'], rows: Array(LIMITS.rows).fill(['א']) }),
      table({ columns: ['שם'], rows: [['א']] })] }), 'too_many_rows'],
    [input({ tables: [table({ columns: ['שם'], rows: [['א'.repeat(LIMITS.cellCharacters + 1)]] })] }), 'cell_too_long'],
    [input({ tables: [table({ columns: ['שם'], rows: Array(100).fill(['א'.repeat(30000)]) })] }), 'input_too_large'],
  ];
  for (const [value, code] of cases) assert.throws(() => validateSpreadsheetInput(value), { code });
  const value = input();
  const copy = validateSpreadsheetInput(value);
  copy.tables[0].rows[0][0] = 'שונה';
  assert.equal(value.tables[0].rows[0][0], 'חבר לדוגמה');
});

test('removes XML-forbidden controls while retaining normal whitespace and emoji', async () => {
  const result = await createGuideSpreadsheet(input({ tables: [table({ columns: ['שם'], rows: [['א\u0000\u0001\uFFFFב\n😀\uD800']] })] }));
  const sheet = (await new ExcelJS.Workbook().xlsx.load(result.buffer)).worksheets[0];
  assert.equal(sheet.getCell('A2').value, 'אב\n😀\uFFFD');
});

test('rejects a generated workbook above the download size limit', async t => {
  const XLSX = require('exceljs/lib/xlsx/xlsx');
  t.mock.method(XLSX.prototype, 'writeBuffer', async () => Buffer.alloc(LIMITS.outputBytes + 1));
  await assert.rejects(createGuideSpreadsheet(input()), { code: 'file_too_large' });
});
