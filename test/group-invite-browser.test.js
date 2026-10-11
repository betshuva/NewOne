'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');

test('group invitation safely previews the group and keeps the invitation through entry', {
  skip: process.env.RUN_BROWSER_TESTS !== '1', timeout: 60000,
}, async t => {
  const {chromium} = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
  const browser = await chromium.launch({headless: true, args: ['--no-sandbox']});
  t.after(() => browser.close());
  const html = await fs.readFile(path.join(__dirname, '../group-invite.html'), 'utf8');
  const token = 'A'.repeat(43);
  const base = 'https://betshuva.test/betshuva-app/';
  const pixel = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jrZkAAAAASUVORK5CYII=', 'base64');

  async function setup({width = 390, query = token, api} = {}) {
    const context = await browser.newContext({viewport: {width, height: 844}, locale: 'he-IL'});
    await context.addCookies([{name: 'existing_session', value: 'private', domain: 'betshuva.test', path: '/'}]);
    t.after(() => context.close());
    const page = await context.newPage();
    const apiRequests = [];
    const unexpectedRequests = [];
    const errors = [];
    page.on('pageerror', e => errors.push(e.message));
    await page.route('**/*', async route => {
      const request = route.request();
      const url = new URL(request.url());
      if (url.origin !== new URL(base).origin) {
        unexpectedRequests.push(request.url());
        return route.abort();
      }
      if (url.pathname === '/betshuva-app/group-invite.html') {
        return route.fulfill({contentType: 'text/html', body: html});
      }
      if (url.pathname.startsWith('/betshuva-app/api/group-invites/')) {
        apiRequests.push(request);
        assert.equal(url.pathname, '/betshuva-app/api/group-invites/' + token);
        assert.equal(request.headers().cookie, undefined, 'public preview must omit session cookies');
        return api(route, apiRequests.length);
      }
      if (url.pathname === '/betshuva-app/uploads/group.png') {
        return route.fulfill({contentType: 'image/png', body: pixel});
      }
      if (url.pathname === '/betshuva-app/favicon.png') return route.fulfill({status: 204});
      unexpectedRequests.push(request.url());
      return route.abort();
    });
    await page.goto(base + 'group-invite.html?groupInvite=' + encodeURIComponent(query));
    await page.waitForFunction(() => document.getElementById('invitation').getAttribute('aria-busy') === 'false');
    return {page, apiRequests, unexpectedRequests, errors};
  }

  for (const width of [390, 1440]) {
    await t.test('valid invitation at width ' + width, async () => {
      const group = {id: 'private-group', name: 'משפחת אליהו', description: 'ממשיכים ביחד\nכאן נפגשים', avatar_url: '/uploads/group.png'};
      const {page, apiRequests, unexpectedRequests, errors} = await setup({width, api: route => route.fulfill({json: {group, inviter: {name: 'אביב'}}})});
      assert.equal(await page.getByRole('heading', {level: 1}).innerText(), group.name);
      assert.equal(await page.locator('#group-description').innerText(), group.description);
      assert.match(await page.locator('#inviter').innerText(), /אביב/);
      assert.equal(await page.getByRole('link', {name: 'הצטרף לקבוצה', exact: true}).getAttribute('href'), '/betshuva-app/?groupInvite=' + token);
      await page.waitForFunction(() => !document.getElementById('group-avatar').hidden);
      assert.equal(await page.locator('#group-avatar').getAttribute('src'), new URL('/betshuva-app/uploads/group.png', base).href);
      assert.equal(await page.locator('#avatar-placeholder').isVisible(), false);
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
      assert.equal(apiRequests.length, 1);
      assert.deepEqual(unexpectedRequests, []);
      assert.deepEqual(errors, []);
    });
  }

  await t.test('untrusted names are text and offsite avatar URLs are never loaded', async () => {
    const unsafe = '<img src=x onerror="window.injected=true">';
    const {page, unexpectedRequests, errors} = await setup({api: route => route.fulfill({json: {
      group: {name: unsafe, description: '<svg onload="window.injected=true">', avatar_url: 'https://outside.test/photo.jpg'},
      inviter: {name: unsafe},
    }})});
    assert.equal(await page.locator('#group-name').innerText(), unsafe);
    assert.equal(await page.locator('#group-description svg, #group-name img, #inviter img').count(), 0);
    assert.equal(await page.evaluate(() => window.injected), undefined);
    assert.equal(await page.locator('#group-avatar').getAttribute('src'), null);
    assert.deepEqual(unexpectedRequests, []);
    assert.deepEqual(errors, []);
  });

  await t.test('expired invitation cannot join', async () => {
    const {page} = await setup({api: route => route.fulfill({status: 410, json: {error: 'expired'}})});
    assert.match(await page.locator('#status').innerText(), /פג תוקפה/);
    assert.equal(await page.getByRole('link', {name: 'הצטרף לקבוצה', exact: true}).count(), 0);
    assert.equal(await page.getByRole('button', {name: 'נסה שוב'}).count(), 0);
    assert.equal(await page.locator('#join').getAttribute('href'), null);
  });

  await t.test('invalid token does not request a preview', async () => {
    const {page, apiRequests} = await setup({query: 'invalid-token'});
    assert.match(await page.locator('#status').innerText(), /אינו תקין/);
    assert.equal(apiRequests.length, 0);
    assert.equal(await page.getByRole('link', {name: 'הצטרף לקבוצה', exact: true}).count(), 0);
  });

  await t.test('network failure offers a retry which restores the same invite', async () => {
    const {page, apiRequests, errors} = await setup({api: (route, attempt) => attempt === 1 ? route.abort() : route.fulfill({json: {group: {name: 'קבוצת בדיקה'}, inviter: {name: 'דני'}}})});
    assert.match(await page.locator('#status').innerText(), /בדקו את החיבור/);
    assert.equal(await page.getByRole('link', {name: 'הצטרף לקבוצה', exact: true}).count(), 0);
    await page.getByRole('button', {name: 'נסה שוב', exact: true}).click();
    const join = page.getByRole('link', {name: 'הצטרף לקבוצה', exact: true});
    await join.waitFor({state: 'visible'});
    assert.equal(await join.getAttribute('href'), '/betshuva-app/?groupInvite=' + token);
    assert.equal(apiRequests.length, 2);
    assert.deepEqual(errors, []);
  });
});
