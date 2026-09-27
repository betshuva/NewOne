'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { presentAuditCheck } = require('../server/audit-check-presentation');

test('audit check columns render and filter in desktop and mobile histories', {
  skip: process.env.RUN_BROWSER_TESTS !== '1', timeout: 90000,
}, async t => {
  const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
  const directory = path.resolve(__dirname, '..');
  const html = await fs.readFile(path.join(directory, 'admin-audit.html'));
  const previewImage = await fs.readFile(path.join(directory, 'assets/icon_source.png'));
  const output = process.env.AUDIT_CHECKS_SCREENSHOTS || '/tmp/betshuva-audit-checks-qa';
  await fs.mkdir(output, { recursive: true });
  const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
  t.after(() => browser.close());
  for (const [name, viewport] of [['desktop', { width: 1440, height: 1000 }],
    ['mobile', { width: 390, height: 844 }]]) {
    await t.test(name, async () => {
      const context = await browser.newContext({ viewport, locale: 'he-IL',
        timezoneId: 'Asia/Jerusalem', acceptDownloads: true });
      const page = await context.newPage();
      const errors = [], requests = [];
      let unauthorizedPreview = false;
      page.on('pageerror', error => errors.push(error.message));
      const root = { id: '00000000-0000-4000-8000-000000000001',
        created_at: '2026-09-24T10:00:00Z', action: 'upload_file',
        initiator_id: '00000000-0000-4000-8000-000000000002',
        initiator_name: 'משתמש בדיקה', status: 'completed', root_event_id: '1',
        event_count: '6', sub_event_count: '5', media_type: 'video',
        source: 'http', checkLabel: '-', checkResultLabel: '-' };
      const event = (id, details, extra = {}) => ({ id: String(id), operation_id: root.id,
        created_at: `2026-09-24T10:00:0${id}Z`, parent_event_id: '1',
        kind: 'provider_call_finished', executor_type: 'provider', executor_id: 'google_vision',
        source: 'provider_usage', status: 'completed', attempt: 1, details, ...extra });
      const events = [presentAuditCheck(event(6, { checkType: 'safe_search', checkOutcome: 'passed',
        provider: 'google_vision', checkFindings: ['adult_very_unlikely', 'racy_very_unlikely',
          'violence_very_unlikely', 'medical_very_unlikely', 'spoof_very_unlikely'] })),
      event(5, { checkType: 'modesty', checkOutcome: 'blocked',
        provider: 'gemini', frameIndex: 0, frameTimestampMs: 0, cacheHit: true }),
      event(4, { provider: 'openai', operation: 'modesty' },
        { checkLabel: 'בדיקת צניעות', checkResultLabel: 'תוצאה לא תועדה' }),
      event(3, { checkType: 'face_detection', checkOutcome: 'passed', provider: 'google_vision',
        frameIndex: 3, frameTimestampMs: 1500 },
      { checkLabel: 'זיהוי פנים', checkResultLabel: 'זוהו 2 פנים',
        checkPreviewUrl: '/api/admin/audit/events/3/preview?size=thumb',
        checkPreviewFullUrl: '/api/admin/audit/events/3/preview?size=full' }),
      event(2, { checkType: 'safe_search', checkOutcome: 'uncertain', provider: 'google_vision',
        frameIndex: 0, frameTimestampMs: 0 },
      { checkLabel: 'בדיקת תוכן לא ראוי', checkResultLabel: '<img src=x onerror=alert(1)>' })];
      for(const row of events){row.sub_event_index=String(Number(row.id)-1);row.sub_event_total='5';}
      await page.addInitScript(() => {
        localStorage.setItem('bt_admin_token', 'mock-only-token');
        window.mockPreviewUrls = { created: [], revoked: [] };
        const create = URL.createObjectURL.bind(URL), revoke = URL.revokeObjectURL.bind(URL);
        URL.createObjectURL = blob => { const url = create(blob); if (blob.type.startsWith('image/')) window.mockPreviewUrls.created.push(url); return url; };
        URL.revokeObjectURL = url => { window.mockPreviewUrls.revoked.push(url); revoke(url); };
      });
      await page.route('**/*', async route => {
        const url = new URL(route.request().url());
        if (url.hostname === 'audit.test') {
          if (url.pathname === '/admin-audit.html') return route.fulfill({ contentType: 'text/html', body: html });
          if (url.pathname.endsWith('/MaterialIcons-Audit.otf')) return route.fulfill({
            contentType: 'font/otf', body: await fs.readFile(path.join(directory, 'assets/fonts/MaterialIcons-Audit.otf')) });
          return route.fulfill({ status: 404, body: '' });
        }
        assert.equal(url.origin, 'https://betshuva.com');
        assert.equal(route.request().method(), 'GET');
        assert.equal(route.request().headers().authorization, 'Bearer mock-only-token');
        requests.push(url);
        if (url.pathname.endsWith('/events/3/preview')) {
          assert.deepEqual([...url.searchParams.keys()], ['size']);
          return unauthorizedPreview ? route.fulfill({ status: 401, body: '' }) :
            route.fulfill({ contentType: 'image/png', body: previewImage });
        }
        if (url.pathname.endsWith('/catalog')) return route.fulfill({ json: {
          actions: [{ code: 'upload_file', label: 'העלאת קובץ' }], statuses: [], categories: [], recordingStartedAt:new Date(Date.now()-86400000).toISOString() } });
        if (url.pathname.endsWith('/filter-options')) {
          const field = url.searchParams.get('column');
          const options = field === 'check_type' ? ['face_detection', 'modesty'] : ['passed', 'blocked', 'uncertain', null];
          return route.fulfill({ json: { options: options.map(value => ({ value })), hasMore: false } });
        }
        if (url.pathname.endsWith('/export.csv')) return route.fulfill({ contentType: 'text/csv',
          body: 'check_type,check_outcome\r\nmodesty,blocked\r\n' });
        const children = /\/operations\/[^/]+\/events$/.test(url.pathname);
        let selected = events;
        for (const [field, filter] of Object.entries(JSON.parse(url.searchParams.get('columnFilters') || '{}'))) {
          const detail = field === 'check_type' ? 'checkType' : 'checkOutcome';
          selected = selected.filter(row => filter.exclude !== filter.values.includes(row.details[detail] ?? null));
        }
        if(url.searchParams.get('sort')==='created_at')selected=selected.slice().sort((a,b)=>(Date.parse(a.created_at)-Date.parse(b.created_at))*(url.searchParams.get('direction')==='asc'?1:-1));
        if (url.pathname.endsWith('/operations')) return route.fulfill({ json: { operations: [{...root,first_sub_event:selected.slice().sort((a,b)=>Date.parse(a.created_at)-Date.parse(b.created_at))[0]||null}], nextCursor: null } });
        return route.fulfill({ json: { events: selected, nextCursor: null } });
      });
      try {
        await page.goto('https://audit.test/admin-audit.html');
        const settled = () => page.waitForFunction(() => !state.loading && !state.exporting &&
          [...state.pages.values()].every(value => !value.loading));
        await page.locator('[data-operation-id]').waitFor();
        await settled();
        assert.equal(await page.locator('#filters,#filter-form').count(),0);
        assert.match(await page.locator('[data-operation-id] .check-cell').innerText(), /בדיקת תוכן לא ראוי/);
        assert.equal(await page.locator('[data-operation-id] .check-result').innerText(), 'תוצאה לא ודאית');
        const headings = await page.locator('thead th').allTextContents();
        assert.ok(headings.some(value => value.includes('מה נבדק')));
        assert.ok(headings.some(value => value.includes('תוצאת הבדיקה')));
        await page.locator('[data-expand]').click();
        await page.locator('.child-row').first().waitFor();
        await settled();
        const row = id => page.locator(`[data-event-id="${id}"]`);
        assert.equal(await row(3).locator('.check-result').innerText(), 'הבדיקה הושלמה');
        assert.equal(await row(3).locator('[data-field="provider"]').innerText(),'Google Vision');assert.equal(await row(3).locator('[data-field="frame_index"]').innerText(),'4');assert.equal(await row(3).locator('[data-field="frame_timestamp"]').innerText(),'00:01.500');
        assert.equal(await row(4).locator('.check-result').innerText(), 'תוצאה לא תועדה');
        assert.equal(await row(5).locator('.check-result').innerText(), 'נמצא ממצא לחסימה');
        assert.equal(await row(5).locator('[data-field="cache_hit"]').innerText(),'כן');
        assert.equal(await row(2).locator('.check-result').innerText(), 'תוצאה לא ודאית');
        assert.equal(await page.locator('#audit-table .check-result img').count(), 0);
        assert.equal(await row(4).locator('.check-preview').count(), 0);
        assert.equal(await row(6).locator('.check-result').innerText(), 'הבדיקה הושלמה');await row(6).locator('[data-field="findings"] button').click();assert.equal(await page.locator('#detail-json').innerText(),events[0].checkResultLabel);await page.locator('#close-dialog').click();
        assert.ok(events[0].checkResultLabel.length > 150);
        assert.equal(await row(6).locator('.check-result .value').evaluate(node =>
          node.scrollHeight > node.clientHeight + 1 || node.scrollWidth > node.clientWidth + 1), false);
        const parentColumns = await page.locator('[data-operation-id] td').count();
        assert.equal(parentColumns, headings.length);
        assert.equal(await row(3).locator('td').count(), parentColumns);
        await row(3).locator('.check-preview').scrollIntoViewIfNeeded();
        await page.waitForFunction(() => {
          const image = document.querySelector('[data-check-preview="3"] img');
          return image && !image.hidden && image.complete && image.naturalWidth > 0;
        });
        const thumbnail = await row(3).locator('.check-preview img').getAttribute('src');
        assert.ok(thumbnail.startsWith('blob:'));
        assert.equal(await row(3).locator('.check-preview img').evaluate(image => {
          const canvas = document.createElement('canvas'); canvas.width = 16; canvas.height = 16;
          const context = canvas.getContext('2d'); context.drawImage(image, 0, 0, 16, 16);
          return context.getImageData(0, 0, 16, 16).data.some((value, index) => index % 4 === 3 && value > 0);
        }), true);
        const thumbnailBox = await row(3).locator('.check-preview').boundingBox();
        assert.equal(thumbnailBox.width, 64);
        assert.equal(thumbnailBox.height, 48);
        await row(3).locator('.check-preview').click();
        await page.waitForFunction(() => {
          const image = document.getElementById('preview-image');
          return !image.hidden && image.complete && image.naturalWidth > 0;
        });
        assert.equal(await page.evaluate(() => autoRefreshPaused()), true);
        const enlarged = await page.locator('#preview-image').getAttribute('src');
        assert.ok(enlarged.startsWith('blob:'));
        assert.ok(requests.some(url => url.pathname.endsWith('/events/3/preview') && url.searchParams.get('size') === 'full'));
        const modal = await page.locator('#preview-dialog').boundingBox();
        assert.ok(modal.x >= 0 && modal.y >= 0 && modal.x + modal.width <= viewport.width + 1 && modal.y + modal.height <= viewport.height + 1);
        await page.screenshot({ path: path.join(output, `${name}-preview.png`), fullPage: true });
        await page.locator('#close-preview').click();
        await page.waitForFunction(url => window.mockPreviewUrls.revoked.includes(url), enlarged);
        await row(6).locator('.check-cell').evaluate(node => node.scrollIntoView({ block: 'nearest', inline: 'start' }));
        const checkBounds = await row(6).locator('.check-cell,.check-result').evaluateAll(nodes =>
          nodes.map(node => ({ left: node.getBoundingClientRect().left, right: node.getBoundingClientRect().right })));
        assert.ok(checkBounds.some(box => box.left >= -1 && box.right <= viewport.width + 1));
        await page.screenshot({ path: path.join(output, `${name}-hierarchy.png`), fullPage: true });

        await page.locator('#events-tab').click();
        await settled();
        assert.equal(await page.evaluate(url => window.mockPreviewUrls.revoked.includes(url), thumbnail), true);
        assert.equal(await row(3).locator('.check-result').innerText(), 'הבדיקה הושלמה');
        const filter = async (field, value) => {
          await page.locator(`[data-column-filter="${field}"]`).click();
          await page.waitForFunction(() => columnPopup && !columnPopup.loading);
          const box = await page.locator('#column-dialog').boundingBox();
          assert.ok(box.x >= 0 && box.x + box.width <= viewport.width + 1);
          await page.locator('#column-all').uncheck();
          await page.locator(`[data-option-value="${value}"]`).check();
          await page.locator('#column-apply').click();
          await settled();
        };
        await filter('check_type', 'modesty');
        await filter('check_outcome', 'blocked');
        assert.equal(await page.locator('[data-event-id]').count(), 1);
        assert.equal(await row(5).locator('.check-result').innerText(), 'נמצא ממצא לחסימה');
        const columns = { check_type: { values: ['modesty'], exclude: false },
          check_outcome: { values: ['blocked'], exclude: false } };
        assert.deepEqual(await page.evaluate(() => state.columns.events), columns);
        await page.locator('#operations-tab').click();await settled();
        await filter('check_type','modesty');await filter('check_outcome','blocked');
        await page.locator('[data-expand]').click();await settled();
        assert.equal(await page.locator('.child-row').count(),1);
        assert.equal(await row(5).count(),1);
        const childRequest=requests.findLast(url=>/\/operations\/[^/]+\/events$/.test(url.pathname));
        assert.deepEqual(JSON.parse(childRequest.searchParams.get('columnFilters')),columns);
        await page.locator('[data-column-sort="created_at"]').click();await settled();
        assert.equal(await page.locator('th[aria-sort="ascending"]').count(),1);
        await page.locator('[data-expand]').click();await settled();
        assert.equal(requests.findLast(url=>/\/operations\/[^/]+\/events$/.test(url.pathname)).searchParams.get('direction'),'asc');
        await page.evaluate(()=>autoRefresh());await settled();
        assert.equal(await page.locator('.child-row').count(),1);
        await page.locator('[data-column-sort="created_at"]').click();await settled();
        assert.equal(await page.locator('th[aria-sort="descending"]').count(),1);
        await page.locator('#events-tab').click();await settled();
        const download = page.waitForEvent('download');
        await page.locator('#export').click();
        await download;
        await settled();
        const exported = requests.findLast(url => url.pathname.endsWith('/export.csv'));
        assert.deepEqual(JSON.parse(exported.searchParams.get('columnFilters')), columns);
        assert.equal(exported.searchParams.get('mode'), 'events');
        assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
        assert.equal(await page.locator('.check-cell .value,.check-result .value,.check-context').evaluateAll(nodes =>
          nodes.some(node => node.scrollWidth > node.clientWidth + 1 || node.scrollHeight > node.clientHeight + 1)), false);
        await row(5).locator('.check-cell').evaluate(node => node.scrollIntoView({ block: 'nearest', inline: 'start' }));
        await page.screenshot({ path: path.join(output, `${name}-filtered.png`), fullPage: true });
        unauthorizedPreview = true;
        await page.locator('#clear-columns').click();
        await settled();
        await row(3).locator('.check-preview').scrollIntoViewIfNeeded();
        await page.waitForFunction(() => document.querySelector('[data-check-preview="3"]')?.disabled);
        const attempts = requests.filter(url => url.pathname.endsWith('/events/3/preview')).length;
        await page.evaluate(() => render());
        await page.evaluate(() => autoRefresh());
        await settled();
        await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
        assert.equal(requests.filter(url => url.pathname.endsWith('/events/3/preview')).length, attempts);
        assert.equal(await row(3).locator('.preview-placeholder').innerText(), 'לא זמין');
        await page.evaluate(() => window.dispatchEvent(new PageTransitionEvent('pagehide')));
        assert.equal(await page.evaluate(() => window.mockPreviewUrls.created.every(url => window.mockPreviewUrls.revoked.includes(url))), true);
        assert.deepEqual(errors, []);
      } finally { await context.close(); }
    });
  }
});
