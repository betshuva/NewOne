'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const sharp = require('sharp');
const { presentAuditCheck } = require('../server/audit-check-presentation');

test('audit keeps the operation preview on non-check rows and shows the actual checked frame on check rows', {
  skip: process.env.RUN_BROWSER_TESTS !== '1', timeout: 60000,
}, async t => {
  const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
  const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
  t.after(() => browser.close());
  const html = await fs.readFile(path.join(__dirname, '../admin-audit.html'));
  const image = await sharp({ create: { width: 120, height: 90, channels: 3, background: 'blue' } }).jpeg().toBuffer();
  for (const width of [1440, 390]) for (const mediaType of ['image', 'video']) await t.test(`${width}-${mediaType}`, async () => {
    const context = await browser.newContext({ viewport: { width, height: 900 } });
    const page = await context.newPage(), errors = [], sizes = [];
    page.on('pageerror', error => errors.push(error.message));
    const root = { id: '00000000-0000-4000-8000-000000000001', action: 'upload_file',
      status: 'blocked', media_type: mediaType, created_at: '2026-09-27T12:00:00Z',
      root_event_id: '1', event_count: '3', sub_event_count: '2' };
    const event = presentAuditCheck({ id: '2', operation_id: root.id, kind: 'moderation_check_finished',
      status: 'blocked', created_at: '2026-09-27T12:00:01Z', sub_event_index: '2', sub_event_total: '2',
      details: { frameIndex: 4, checkType: 'modesty', checkOutcome: 'blocked', checkFindings: ['visible_violation'],
        storedFileId: '00000000-0000-4000-8000-000000000002',
        scanPreviewId: '00000000-0000-4000-8000-000000000003' } });
    root.operationPreview = { eventId: '7', mediaType,
      url: '/api/admin/audit/events/7/preview?size=thumb', fullUrl: '/api/admin/audit/events/7/preview?size=full' };
    event.operationPreview = root.operationPreview;
    const first = { id: '3', operation_id: root.id, kind: 'upload_context', status: 'completed',
      created_at: root.created_at, sub_event_index: '1', sub_event_total: '2', details: {} };
    root.first_sub_event = first;
    await page.addInitScript(() => localStorage.setItem('bt_admin_token', 'mock-admin'));
    await page.route('**/*', async route => {
      const url = new URL(route.request().url());
      if (url.hostname === 'audit.test') return route.fulfill({ contentType: 'text/html', body: url.pathname.endsWith('.html') ? html : '' });
      assert.equal(route.request().headers().authorization, 'Bearer mock-admin');
      if (/\/events\/(7|2)\/preview$/.test(url.pathname)) {
        assert.deepEqual([...url.searchParams.keys()], ['size']);
        sizes.push(url.searchParams.get('size'));
        return route.fulfill({ contentType: 'image/jpeg', body: image });
      }
      if (url.pathname.endsWith('/catalog')) return route.fulfill({ json: { actions: [] } });
      if (url.pathname.endsWith('/column-order')) return route.fulfill({ json: { orders: {}, widths: {}, formats: {} } });
      if (url.pathname.endsWith('/operations')) return route.fulfill({ json: { operations: [root], nextCursor: null } });
      if (url.pathname.endsWith('/events')) return route.fulfill({ json: { events: [first, event], nextCursor: null } });
      return route.fulfill({ json: {} });
    });
    await page.goto('https://audit.test/admin-audit.html');
    await page.waitForFunction(() => state.hasLoaded && !state.loading && columnOrdersLoaded);
    const preview = page.locator('[data-check-preview="7"]').first();
    await preview.scrollIntoViewIfNeeded();
    await page.waitForFunction(() => {
      const image = document.querySelector('[data-check-preview="7"] img');
      return image && !image.hidden && image.complete && image.naturalWidth > 0;
    });
    assert.equal(await preview.locator('img').getAttribute('alt'), mediaType === 'video' ? 'הפריים הראשון בסרטון' : 'התמונה שהועלתה');
    await preview.click();
    await page.waitForFunction(() => {
      const image = document.getElementById('preview-image');
      return !image.hidden && image.complete && image.naturalWidth > 0;
    });
    assert.ok((await page.locator('#preview-image').getAttribute('src')).startsWith('blob:'));
    assert.ok(sizes.includes('thumb') && sizes.includes('full'));
    await page.locator('#close-preview').click();
    await page.locator('[data-expand]').click();
    await page.waitForFunction(() => [...state.pages.values()].every(p => !p.loading));
    const laterPreview = page.locator('[data-event-id="2"] [data-check-preview="2"]');
    assert.equal(await laterPreview.count(), 1);
    assert.equal(await page.locator('[data-event-id="2"] [data-check-preview="7"]').count(), 0);
    await laterPreview.scrollIntoViewIfNeeded();
    await laterPreview.click();
    await page.waitForFunction(() => !document.getElementById('preview-image').hidden);
    assert.match(await page.locator('#preview-caption').textContent(), /תמונה 5/);
    await page.locator('#close-preview').click();
    assert.deepEqual(errors, []);
    await context.close();
  });
});
