'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');

test('admin listings and inline user/file actions render hostile values as data', {
  skip: !process.env.PLAYWRIGHT_MODULE,
}, async () => {
  const { chromium } = require(process.env.PLAYWRIGHT_MODULE);
  const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
  try {
    const page = await browser.newPage();
    const errors = []; page.on('pageerror', error => errors.push(error.message));
    const html = fs.readFileSync(require.resolve('../admin.html'), 'utf8');
    const attack = `');window.securityInjected=true;//<img src=x onerror="window.securityInjected=true">`;
    const item = { id: '123', title: attack, description: attack, category: attack,
      seller_name: attack, city: attack, image_url: 'x" onerror="window.securityInjected=true',
      images: ['x" onerror="window.securityInjected=true'], type: 'free', status: 'active', created_at: '2026-09-29' };
    await page.route('**/*', async route => {
      const url = new URL(route.request().url());
      if (url.hostname === 'admin-security.test' && url.pathname === '/admin.html')
        return route.fulfill({ contentType: 'text/html', body: html });
      if (url.pathname === '/betshuva-app/api/listings') return route.fulfill({ json: [item] });
      if (url.pathname === '/betshuva-app/api/listings/123') return route.fulfill({ json: item });
      return route.fulfill({ status: 404, body: '' });
    });
    await page.goto('https://admin-security.test/admin.html');
    await page.evaluate(async () => { await loadAdminListings(); await openAdminListingDetail('123'); });
    assert.equal(await page.locator('.lst-title').textContent(), attack);
    assert.equal(await page.locator('.lst-card [onerror]').count(), 0);
    assert.equal(await page.locator('.lst-overlay [onerror]').count(), 0);
    const captured = await page.evaluate(value => {
      window.openUserDeleteModal = (...args) => { window.captured = args; };
      const button = document.createElement('button');
      const host = document.createElement('div');
      host.innerHTML = `<button onclick="openUserDeleteModal(${jsAttr('id')},${jsAttr(value)},${jsAttr('email')})">test</button>`;
      host.firstElementChild.click();
      return window.captured;
    }, attack);
    assert.deepEqual(captured, ['id', attack, 'email']);
    assert.equal(await page.evaluate(() => window.securityInjected), undefined);
    assert.deepEqual(errors, []);
  } finally { await browser.close(); }
});
