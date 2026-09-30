'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');

test('Gmail page reads hostile mail safely and replies using a stable request identifier', {
  skip: !process.env.PLAYWRIGHT_MODULE,
}, async () => {
  const { chromium } = require(process.env.PLAYWRIGHT_MODULE);
  const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
  try {
    const page = await browser.newPage();
    const errors = [], external = [], replies = [];
    let connected = true;
    page.on('pageerror', e => errors.push(e.message));
    await page.addInitScript(() => localStorage.setItem('bt_admin_token', 'test-token'));
    const html = fs.readFileSync(require.resolve('../admin-gmail.html'), 'utf8');
    const message = { id: 'abc123', subject: '<img src=x onerror=alert(1)>', from: 'sender@example.com',
      to: 'yanive8@gmail.com', replyTo: 'reply@example.com', date: 'today', text: '',
      html: '<p>שלום</p><img src="https://tracker.test/pixel"><script>window.injected=true</script>' };
    await page.route('**/*', async route => {
      const url = new URL(route.request().url());
      if (url.hostname !== 'gmail.test') { external.push(url.href); return route.abort(); }
      if (url.pathname.endsWith('/admin-gmail.html')) return route.fulfill({ contentType: 'text/html', body: html });
      if (url.pathname.endsWith('/status')) return route.fulfill({ json: { configured: true, connected,
        email: 'yanive8@gmail.com', setupUrl: 'https://console.cloud.google.com/apis/library/gmail.googleapis.com?project=123' } });
      if (url.pathname.endsWith('/messages')) return route.fulfill({ json: { messages: [message], nextPageToken: null } });
      if (url.pathname.endsWith('/messages/abc123')) return route.fulfill({ json: message });
      if (url.pathname.endsWith('/reply')) {
        replies.push(route.request().postDataJSON());
        if (replies.length === 1) return route.abort();
        return route.fulfill({ json: { id: 'sent' } });
      }
      return route.fulfill({ status: 404, body: '{}' });
    });
    await page.goto('https://gmail.test/betshuva-app/admin-gmail.html');
    await page.locator('.mail').click();
    await page.locator('#body').waitFor();
    assert.match(await page.locator('#body').textContent(), /שלום/);
    assert.equal(await page.locator('#subject').textContent(), message.subject);
    assert.equal(await page.locator('img').count(), 0);
    assert.equal(await page.evaluate(() => window.injected), undefined);
    assert.deepEqual(external, []);
    await page.locator('#reply-text').fill('תשובה לבדיקה');
    await page.locator('#send').click();
    await page.waitForFunction(() => document.getElementById('notice').classList.contains('error'));
    await page.locator('#send').click();
    await page.waitForFunction(() => document.getElementById('notice').textContent === 'התשובה נשלחה');
    assert.equal(replies.length, 2);
    assert.equal(replies[0].requestId, replies[1].requestId);
    assert.equal(replies[0].text, 'תשובה לבדיקה');
    assert.equal(await page.locator('#reply-text').inputValue(), '');
    connected = false;
    await page.goto('https://gmail.test/betshuva-app/admin-gmail.html?gmail=api_disabled');
    await page.locator('#setup-link').waitFor();
    assert.match(await page.locator('#notice').textContent(), /Gmail API/);
    assert.equal(await page.locator('#setup-link').getAttribute('href'), 'https://console.cloud.google.com/apis/library/gmail.googleapis.com?project=123');
    assert.equal(await page.locator('#mailbox').isVisible(), false);
    assert.deepEqual(errors, []);
  } finally { await browser.close(); }
});
