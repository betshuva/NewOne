'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const sharp = require('sharp');
const { randomUUID } = require('node:crypto');
const { promisify } = require('node:util');
const execFile = promisify(require('node:child_process').execFile);

function wav() {
  const b = Buffer.alloc(16044);
  b.write('RIFF'); b.writeUInt32LE(b.length - 8, 4); b.write('WAVEfmt ', 8);
  b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22);
  b.writeUInt32LE(8000, 24); b.writeUInt32LE(16000, 28);
  b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34); b.write('data', 36); b.writeUInt32LE(16000, 40);
  return b;
}

function pdf() {
  const objects=['<</Type/Catalog/Pages 2 0 R>>','<</Type/Pages/Count 1/Kids[3 0 R]>>',
    '<</Type/Page/Parent 2 0 R/MediaBox[0 0 100 100]/Contents 4 0 R>>','<</Length 0>>\nstream\n\nendstream'];
  let text='%PDF-1.4\n';const offsets=[0];
  objects.forEach((object,index)=>{offsets.push(Buffer.byteLength(text));text+=`${index+1} 0 obj\n${object}\nendobj\n`;});
  const xref=Buffer.byteLength(text);text+=`xref\n0 5\n0000000000 65535 f \n`;
  for(const offset of offsets.slice(1))text+=`${String(offset).padStart(10,'0')} 00000 n \n`;
  text+=`trailer\n<</Size 5/Root 1 0 R>>\nstartxref\n${xref}\n%%EOF`;
  return Buffer.from(text);
}

test('audit opens actual blocked image, video, audio and PDF on desktop and mobile, with unavailable-file handling', {
  skip: process.env.RUN_BROWSER_TESTS !== '1', timeout: 90000,
}, async t => {
  const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
  const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
  t.after(() => browser.close());
  const html = await fs.readFile(path.join(__dirname, '../admin-audit.html'));
  const image = await sharp({ create: { width: 100, height: 80, channels: 3, background: 'blue' } }).png().toBuffer();
  const temp = await fs.mkdtemp('/tmp/audit-media-browser-');
  t.after(() => fs.rm(temp, { recursive: true, force: true }));
  await execFile(process.env.WHISPER_PYTHON || path.join(__dirname, '../.venv-whisper/bin/python'), ['-c',
    `import av,sys
out=av.open(sys.argv[1],'w')
s=out.add_stream('mpeg4',rate=10);s.width=32;s.height=32;s.pix_fmt='yuv420p'
for i in range(10):
 f=av.VideoFrame(32,32,'yuv420p');f.pts=i
 for p in f.planes:p.update(bytes(p.buffer_size))
 for p in s.encode(f):out.mux(p)
for p in s.encode(None):out.mux(p)
out.close()`, path.join(temp, 'video.mp4')]);
  const fixtures = {
    image: ['image/png', image], video: ['video/mp4', await fs.readFile(path.join(temp, 'video.mp4'))],
    audio: ['audio/wav', wav()], document: ['application/pdf', pdf()],
  };
  for (const width of [1440,390]) await t.test(String(width), async () => {
    const context = await browser.newContext({ viewport: { width, height: 900 } });
    const page = await context.newPage(), errors = [], fetched = [];
    page.on('pageerror', error => errors.push(error.message));
    const operations = Object.entries(fixtures).map(([type,[mime]]) => {
      const id = randomUUID(), fileId = randomUUID();
      return { id, action: 'upload_file', status: 'blocked', media_type: type,
        created_at: '2026-09-28T12:00:00Z', event_count:'1', sub_event_count:'0',
        operationMedia: [{ id:fileId, operationId:id, mediaType:type, mimeType:mime, name:type,
          available:true, url:`/api/admin/audit/operations/${id}/media/${fileId}` }] };
    });
    await page.addInitScript(() => localStorage.setItem('bt_admin_token', 'mock-admin'));
    let unavailable = false;
    await page.route('**/*', async route => {
      const url = new URL(route.request().url());
      if (url.hostname === 'audit.test') return route.fulfill({ contentType:'text/html', body:url.pathname.endsWith('.html') ? html : '' });
      if(!url.pathname.includes('/api/admin/audit/'))return route.continue();
      assert.equal(route.request().headers().authorization, 'Bearer mock-admin');
      assert.ok(!url.searchParams.has('token'));
      const operation = operations.find(op => url.pathname.endsWith(`/media/${op.operationMedia[0].id}`));
      if (operation) {
        fetched.push(operation.media_type);
        if(unavailable)return route.fulfill({status:404,json:{error:'deleted'}});
        const [contentType,body] = fixtures[operation.media_type];
        return route.fulfill({contentType,body});
      }
      if(url.pathname.endsWith('/catalog'))return route.fulfill({json:{actions:[]}});
      if(url.pathname.endsWith('/column-order'))return route.fulfill({json:{orders:{},widths:{},formats:{}}});
      if(url.pathname.endsWith('/operations'))return route.fulfill({json:{operations,nextCursor:null}});
      if(url.pathname.endsWith('/events'))return route.fulfill({json:{events:[],nextCursor:null}});
      return route.fulfill({json:{}});
    });
    await page.goto('https://audit.test/admin-audit.html');
    await page.waitForFunction(() => state.hasLoaded && !state.loading && columnOrdersLoaded);
    assert.equal(await page.getByText('תצוגת תמונה',{exact:true}).count(),0);
    assert.equal(fetched.length,0,'media must only be fetched on a user click');
    for(const op of operations){
      const control=page.locator(`[data-audit-media="${op.operationMedia[0].id}"]`).first();
      await control.scrollIntoViewIfNeeded();await control.click();
      const selector={image:'#preview-image',video:'#preview-video',audio:'#preview-audio',document:'#preview-pdf'}[op.media_type];
      await page.waitForFunction(selector=>!document.querySelector(selector).hidden&&document.querySelector(selector).src.startsWith('blob:'),selector);
      if(['audio','video'].includes(op.media_type)){
        assert.equal(await page.locator(selector).evaluate(node=>node.controls),true);
        if(op.media_type==='audio')await page.waitForFunction(()=>document.querySelector('#preview-audio').readyState>=1);
      }
      if(op.media_type==='image')await page.waitForFunction(()=>document.querySelector('#preview-image').naturalWidth>0);
      await page.locator('#close-preview').click();
      await page.waitForFunction(selector=>!document.querySelector(selector).hasAttribute('src'),selector);
      assert.equal(await page.locator(selector).getAttribute('src'),null);
    }
    assert.deepEqual(fetched,['image','video','audio','document']);
    unavailable=true;
    await page.locator(`[data-audit-media="${operations[0].operationMedia[0].id}"]`).first().click();
    await page.waitForFunction(()=>document.getElementById('preview-status').textContent.includes('הקובץ נמחק'));
    assert.deepEqual(errors,[]);
    await context.close();
  });
});
