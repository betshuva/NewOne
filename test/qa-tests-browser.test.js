'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const express = require('express');
const { publicStatic } = require('../server/public-static');

const ROOT = path.join(__dirname, '..');
const TOTAL = 353;
const STORAGE_KEY = 'bt_qa_run_v1';

// Parse exported RFC 4180 data independently of the browser's serializer.
function readCsv(text) {
  const rows = [];
  let row = [], field = '', quoted = false;
  for (let index = 0; index < text.length; index++) {
    const char = text[index];
    if (char === '"') {
      if (quoted && text[index + 1] === '"') { field += '"'; index++; }
      else quoted = !quoted;
    } else if (char === ',' && !quoted) { row.push(field); field = ''; }
    else if (char === '\n' && !quoted) {
      row.push(field.replace(/\r$/, '')); rows.push(row); row = []; field = '';
    } else field += char;
  }
  if (field || row.length) { row.push(field.replace(/\r$/, '')); rows.push(row); }
  assert.equal(quoted, false, 'CSV quoting is balanced');
  return rows;
}

test('manual QA catalog behaves as a safe, persistent and exportable checklist', {
  skip: process.env.RUN_BROWSER_TESTS !== '1', timeout: 180000,
}, async t => {
  const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
  const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
  t.after(() => browser.close());
  const requests = [];
  const app = express();
  app.use((req, res, next) => { requests.push({ method: req.method, path: req.path }); next(); });
  app.use('/betshuva-app', publicStatic(ROOT));
  const server = app.listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const url = `http://127.0.0.1:${server.address().port}/betshuva-app/qa-tests.html`;

  async function open(options = {}, init) {
    const context = await browser.newContext({ acceptDownloads: true,
      viewport: { width: 1280, height: 900 }, locale: 'he-IL', ...options });
    t.after(() => context.close());
    const page = await context.newPage(), errors = [];
    page.on('pageerror', error => errors.push(error.message));
    if (init) await page.addInitScript(init);
    await page.goto(url);
    await page.waitForFunction(() =>
      document.querySelector('#test-list').getAttribute('aria-busy') === 'false');
    assert.equal(await page.locator('.test-card').count(), TOTAL);
    assert.equal(await page.locator('#load-error').isVisible(), false);
    return { page, context, errors };
  }

  async function exportFile(page, selector) {
    const pending = page.waitForEvent('download');
    await page.locator(selector).click();
    const download = await pending;
    assert.equal(await download.failure(), null);
    const bytes = await fs.readFile(await download.path());
    await download.delete();
    return { bytes, filename: download.suggestedFilename() };
  }
  const exportJson = async page => JSON.parse((await exportFile(page, '#export-json')).bytes.toString('utf8'));
  async function visibleCount(page, count) {
    await page.waitForFunction(expected => document.querySelectorAll('.test-card:not([hidden])').length === expected, count);
    assert.equal(await page.locator('.test-card:visible').count(), count);
  }
  async function fillResult(page, id, values) {
    const card = page.locator(`details.test-card[data-id="${id}"]`);
    if (!(await card.evaluate(element => element.open))) await card.locator('summary').first().click();
    // Notes are entered first: a result-status filter can legitimately hide the card on change.
    if (values.notes !== undefined) await card.locator('textarea[data-result-notes]').fill(values.notes);
    if (values.issueId !== undefined) await card.locator('input[data-result-issue]').fill(values.issueId);
    if (values.status !== undefined) await card.locator('select[data-result-status]').selectOption(values.status);
  }

  await t.test('all manual entries start unrun; search and combined filters describe actual rows', async () => {
    const { page, errors } = await open();
    const initial = await exportJson(page);
    assert.equal(initial.schemaVersion, 1);
    assert.equal(initial.app, 'betshuva-operational-qa');
    assert.equal(initial.results.length, TOTAL);
    assert.equal(new Set(initial.results.map(result => result.id)).size, TOTAL);
    assert.ok(initial.results.every(result => result.status === 'not-run'));
    assert.match(await page.locator('#catalog-baseline').textContent(), /1\.3\.62/);
    await page.locator('#search').fill('CHAT-001');
    await visibleCount(page, 1);
    assert.equal(await page.locator('.test-card:visible').getAttribute('data-id'), 'CHAT-001');
    await page.locator('#category-filter').selectOption({ label: 'שיחות והודעות' });
    await page.locator('#platform-filter').selectOption('web');
    await page.locator('#role-filter').selectOption('user');
    await page.locator('#status-filter').selectOption('not-run');
    await page.locator('#kind-filter').selectOption('operation');
    await visibleCount(page, 1);
    await page.locator('#role-filter').selectOption('adminEdit');
    await visibleCount(page, 0);
    assert.equal(await page.locator('#empty-results').isVisible(), true);
    await page.locator('#clear-filters').click();
    await visibleCount(page, TOTAL);
    await page.locator('#kind-filter').selectOption('workflow');
    await visibleCount(page, 8);
    await page.locator('#clear-filters').click();
    await page.locator('#search').fill('PDF');
    await page.waitForFunction(() => {
      const count = document.querySelectorAll('.test-card:not([hidden])').length;
      return count > 1 && count < 353;
    });
    const pdfCount = await page.locator('.test-card:visible').count();
    assert.ok(pdfCount > 1 && pdfCount < TOTAL);
    await page.locator('#search').fill('אין תרחיש כזה 782349873');
    await visibleCount(page, 0);
    assert.deepEqual(errors, []);
  });

  await t.test('filtered edits survive reload; JSON and UTF-8 CSV export all entries without injection', async () => {
    const { page, errors } = await open();
    const hostileNote = '=HYPERLINK("https://invalid.test","בדיקה")\nשורה, "מצוטטת" <img src=x onerror="window.qaInjected=true">';
    const hostileIssue = '<svg onload="window.qaInjected=true">';
    await page.locator('#tested-version').fill('1.3.62+283 · בדיקה');
    await page.locator('#run-date').fill('2026-10-08');
    await page.locator('#tester').fill('בודק, "א"');
    await page.locator('#search').fill('CHAT-001');
    await visibleCount(page, 1);
    await fillResult(page, 'CHAT-001', { notes: hostileNote, issueId: hostileIssue, status: 'failed' });
    await page.locator('#clear-filters').click();
    await page.locator('#status-filter').selectOption('failed');
    await visibleCount(page, 1);
    const edited = await exportJson(page);
    assert.equal(edited.results.length, TOTAL, 'export includes entries hidden by filters');
    const result = edited.results.find(value => value.id === 'CHAT-001');
    assert.equal(result.status, 'failed');
    assert.equal(result.notes, hostileNote);
    assert.equal(result.issueId, hostileIssue);
    assert.ok(Number.isFinite(Date.parse(result.updatedAt)));
    assert.equal(edited.run.testedVersion, '1.3.62+283 · בדיקה');
    assert.equal(edited.run.date, '2026-10-08');
    assert.equal(edited.run.tester, 'בודק, "א"');
    assert.equal(await page.evaluate(() => window.qaInjected), undefined);
    assert.equal(await page.locator('#test-list img, #test-list svg, #test-list script').count(), 0);

    const csv = (await exportFile(page, '#export-csv')).bytes;
    assert.equal(csv.subarray(0, 3).toString('hex'), 'efbbbf', 'Excel CSV has a UTF-8 BOM');
    const rows = readCsv(csv.toString('utf8').slice(1));
    assert.equal(rows.length, TOTAL + 1);
    assert.ok(rows.every(row => row.length === rows[0].length), 'newlines and quotes do not split fields');
    const exportedRow = rows.find(row => row.includes('CHAT-001'));
    assert.ok(exportedRow.includes("'" + hostileNote), 'CSV formula-looking notes are escaped');
    assert.ok(exportedRow.includes(hostileIssue));
    assert.ok(exportedRow.includes('בודק, "א"'));

    await page.reload();
    await page.waitForFunction(() => document.querySelector('#test-list').getAttribute('aria-busy') === 'false');
    await page.locator('#search').fill('CHAT-001');
    await visibleCount(page, 1);
    const card = page.locator('[data-id="CHAT-001"]');
    await card.locator('summary').first().click();
    assert.equal(await card.locator('select[data-result-status]').inputValue(), 'failed');
    assert.equal(await card.locator('textarea[data-result-notes]').inputValue(), hostileNote);
    assert.equal(await card.locator('input[data-result-issue]').inputValue(), hostileIssue);
    assert.equal(await page.locator('#tested-version').inputValue(), edited.run.testedVersion);
    assert.equal(await page.evaluate(() => window.qaInjected), undefined);
    assert.deepEqual(errors, []);
  });

  await t.test('invalid import preserves results; reset and valid import require a deliberate confirmation', async () => {
    const { page, errors } = await open();
    await page.locator('#search').fill('CHAT-001');
    await visibleCount(page, 1);
    await fillResult(page, 'CHAT-001', { status: 'passed', notes: 'נשמר לפני ייבוא', issueId: 'QA-42' });
    const original = await exportJson(page);
    async function importValue(value) {
      await page.locator('#import-file').setInputFiles({ name: 'qa-results.json', mimeType: 'application/json',
        buffer: Buffer.from(typeof value === 'string' ? value : JSON.stringify(value)) });
    }
    for (const invalid of ['{invalid json', { ...original, schemaVersion: 999 },
      { ...original, results: [{ id: 'CHAT-001', status: 'unknown', notes: 'bad', issueId: '', updatedAt: '' }] }]) {
      await page.evaluate(() => { document.querySelector('#notice').hidden = true; });
      await importValue(invalid);
      await page.waitForFunction(() => !document.querySelector('#notice').hidden &&
        document.querySelector('#notice').textContent.startsWith('הייבוא לא בוצע'));
      assert.equal(await page.locator('#confirm-dialog').evaluate(element => element.open), false);
      const current = await exportJson(page);
      assert.deepEqual(current.results, original.results, 'invalid import cannot discard any result');
    }
    await page.locator('#reset-run').click();
    assert.equal(await page.locator('#confirm-dialog').evaluate(element => element.open), true);
    await page.locator('#cancel-action').click();
    assert.deepEqual((await exportJson(page)).results, original.results);
    await page.locator('#reset-run').click();
    await page.locator('#confirm-action').click();
    const reset = await exportJson(page);
    assert.ok(reset.results.every(result => result.status === 'not-run' && !result.notes && !result.issueId));
    await importValue(original);
    await page.locator('#confirm-dialog').waitFor({ state: 'visible' });
    await page.locator('#cancel-action').click();
    assert.deepEqual((await exportJson(page)).results, reset.results);
    await importValue(original);
    await page.locator('#confirm-dialog').waitFor({ state: 'visible' });
    await page.locator('#confirm-action').click();
    assert.deepEqual((await exportJson(page)).results, original.results);
    assert.deepEqual(errors, []);
  });

  await t.test('unavailable browser storage is visible and leaves current results exportable', async () => {
    const { page, errors } = await open({}, () => {
      const original = Storage.prototype.setItem;
      Storage.prototype.setItem = function (key, value) {
        if (key === 'bt_qa_run_v1') throw new DOMException('Storage disabled for isolated test', 'QuotaExceededError');
        return original.call(this, key, value);
      };
    });
    await page.locator('#search').fill('CHAT-001');
    await visibleCount(page, 1);
    await fillResult(page, 'CHAT-001', { status: 'blocked', notes: 'בדיקה זמנית בזיכרון' });
    assert.equal(await page.locator('#storage-notice').isVisible(), true);
    const exported = await exportJson(page);
    assert.equal(exported.results.find(result => result.id === 'CHAT-001').status, 'blocked');
    assert.equal(await page.evaluate(key => localStorage.getItem(key), STORAGE_KEY), null);
    assert.deepEqual(errors, []);
  });

  await t.test('confirmed import repairs corrupt saved state and a large full export round-trips', async () => {
    const { page, errors } = await open({}, () => localStorage.setItem('bt_qa_run_v1', 'corrupt prior results'));
    assert.equal(await page.locator('#storage-notice').isVisible(), true);
    assert.equal(await page.evaluate(key => localStorage.getItem(key), STORAGE_KEY), 'corrupt prior results');
    const document = await exportJson(page);
    const repaired = { ...document, results: document.results.map(result => result.id === 'CHAT-001'
      ? { ...result, status: 'passed', notes: 'ייבוא מאושר מתקן את השמירה' } : result) };
    await page.locator('#import-file').setInputFiles({ name: 'repair.json', mimeType: 'application/json',
      buffer: Buffer.from(JSON.stringify(repaired)) });
    await page.locator('#confirm-dialog').waitFor({ state: 'visible' });
    await page.locator('#confirm-action').click();
    assert.equal(await page.locator('#storage-notice').isVisible(), false);
    const saved = await page.evaluate(key => JSON.parse(localStorage.getItem(key)), STORAGE_KEY);
    assert.equal(saved.results.find(result => result.id === 'CHAT-001').status, 'passed');
    const full = { ...repaired, results: repaired.results.map(result => ({ ...result, notes: 'ת'.repeat(8000) })) };
    const largeBytes = Buffer.from(JSON.stringify(full));
    assert.ok(largeBytes.length > 2 * 1024 * 1024);
    await page.locator('#import-file').setInputFiles({ name: 'full.json', mimeType: 'application/json', buffer: largeBytes });
    await page.locator('#confirm-dialog').waitFor({ state: 'visible' });
    await page.locator('#confirm-action').click();
    const exported = await exportJson(page);
    assert.deepEqual(exported.results, full.results);
    // Per-browser storage quota can be lower than the export size; memory export must still work.
    assert.deepEqual(errors, []);
  });

  await t.test('320px RTL layout keeps labelled inputs usable through a keyboard', async () => {
    const { page, errors } = await open({ viewport: { width: 320, height: 720 } });
    assert.equal(await page.locator('html').getAttribute('dir'), 'rtl');
    assert.equal(await page.locator('html').getAttribute('lang'), 'he');
    const overflow = await page.evaluate(() => ({ width: document.documentElement.clientWidth,
      scroll: document.documentElement.scrollWidth }));
    assert.ok(overflow.scroll <= overflow.width, JSON.stringify(overflow));
    await page.locator('#search').focus();
    await page.keyboard.type('CHAT-001');
    await visibleCount(page, 1);
    const card = page.locator('[data-id="CHAT-001"]');
    await card.locator('summary').first().focus();
    await page.keyboard.press('Enter');
    assert.equal(await card.evaluate(element => element.open), true);
    await card.locator('textarea[data-result-notes]').waitFor();
    const missingLabels = await page.locator('input:not([type="file"]), select, textarea').evaluateAll(elements =>
      elements.filter(element => !element.labels?.length && !element.getAttribute('aria-label') &&
        !element.getAttribute('aria-labelledby')).map(element => element.id || element.outerHTML));
    assert.deepEqual(missingLabels, []);
    await card.locator('textarea[data-result-notes]').focus();
    await page.keyboard.type('keyboard note');
    await page.keyboard.press('Tab');
    assert.equal(await card.locator('textarea[data-result-notes]').inputValue(), 'keyboard note');
    const expanded = await page.evaluate(() => ({ width: document.documentElement.clientWidth,
      scroll: document.documentElement.scrollWidth }));
    assert.ok(expanded.scroll <= expanded.width, JSON.stringify(expanded));
    assert.deepEqual(errors, []);
  });

  assert.ok(requests.length > 0);
  assert.ok(requests.every(request => request.method === 'GET'), 'manual checklist never mutates the server');
  assert.ok(requests.every(request => !request.path.includes('/api/')), 'manual results need no API access');
});
