'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs/promises'),path=require('node:path');
test('merged stage keeps legacy placement and widths and filters/sorts either component',{skip:process.env.RUN_BROWSER_TESTS!=='1',timeout:60000},async t=>{
 const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright'),browser=await chromium.launch({headless:true,args:['--no-sandbox']});t.after(()=>browser.close());const html=await fs.readFile(path.join(__dirname,'../admin-audit.html')),{COLUMN_IDS}=require('../server/audit-column-order');
 for(const width of [1440,390])await t.test(String(width),async()=>{
  const context=await browser.newContext({viewport:{width,height:950},locale:'he-IL'}),page=await context.newPage(),errors=[],queries=[];page.on('pageerror',e=>errors.push(e.message));
  const root={id:'00000000-0000-4000-8000-000000000001',action:'upload_file',created_at:'2026-09-27T08:00:00Z',status:'completed',root_event_id:'1',event_count:'137',sub_event_count:'136'};
  const event={id:'21',operation_id:root.id,created_at:root.created_at,kind:'scan_queued',status:'completed',sub_event_index:'20',sub_event_total:'136'};root.first_sub_event=event;
  const legacy=COLUMN_IDS.operations.slice();legacy.splice(legacy.indexOf('step_index'),0,'step_total');
  await page.addInitScript(()=>localStorage.setItem('bt_admin_token','mock-token'));await page.route('**/*',async route=>{
   const url=new URL(route.request().url());if(url.hostname==='audit.test')return route.fulfill({contentType:'text/html',body:url.pathname.endsWith('.html')?html:''});
   if(url.pathname.endsWith('/column-order'))return route.fulfill({json:{orders:{operations:legacy},widths:{operations:{step_index:175,step_total:120,action:260}}}});
   if(url.pathname.endsWith('/catalog'))return route.fulfill({json:{actions:[]}});
   if(url.pathname.endsWith('/operations')){queries.push(url);return route.fulfill({json:{operations:[root],nextCursor:null}});}
   if(url.pathname.endsWith('/events'))return route.fulfill({json:{events:[event],nextCursor:null}});throw new Error('Unexpected request');
  });
  await page.goto('https://audit.test/admin-audit.html');await page.waitForFunction(()=>state.hasLoaded&&!state.loading&&columnOrdersLoaded);
  assert.equal(await page.locator('[data-field="step_index"]').innerText(),'20 מתוך 136');assert.equal(await page.locator('[data-column-id="step_total"]').count(),0);assert.match(await page.locator('[data-column-id="step_index"]').innerText(),/שלב/);
  assert.deepEqual(await page.locator('thead th').evaluateAll(nodes=>nodes.map(node=>node.dataset.columnId)),COLUMN_IDS.operations);
  assert.equal(await page.locator('[data-column-id="step_index"] .column-resize').getAttribute('aria-valuenow'),'175');assert.equal(await page.locator('[data-column-id="action"] .column-resize').getAttribute('aria-valuenow'),'260');
  await page.locator('[data-column-filter="step_index"]').click();await page.locator('#column-dialog[open]').waitFor();assert.deepEqual(await page.locator('#column-field option').allTextContents(),['מספר שלב','סך שלבים']);
  await page.locator('#column-start').fill('20');await page.locator('#column-field').selectOption('step_total');await page.locator('#column-start').fill('100');await page.locator('#column-end').fill('150');await page.locator('[data-step-sort="desc"]').click();await page.waitForFunction(()=>!state.loading&&!columnPopup);
  assert.equal(queries.at(-1).searchParams.get('sort'),'step_total');assert.equal(queries.at(-1).searchParams.get('direction'),'desc');assert.deepEqual(JSON.parse(queries.at(-1).searchParams.get('columnFilters')),{step_index:{min:'20'},step_total:{min:'100',max:'150'}});
  await page.locator('[data-column-sort="step_total"]').click();await page.waitForFunction(()=>!state.loading);assert.equal(queries.at(-1).searchParams.get('direction'),'asc');
  await page.locator('[data-column-filter="step_index"]').click();await page.locator('#column-field').selectOption('step_index');await page.locator('[data-step-sort="desc"]').click();await page.waitForFunction(()=>!state.loading&&!columnPopup);assert.equal(queries.at(-1).searchParams.get('sort'),'step_index');
  await page.locator('[data-expand]').click();await page.waitForFunction(()=>[...state.pages.values()].every(p=>!p.loading));assert.equal(await page.locator('[data-field="step_index"]').innerText(),'20 מתוך 136');
  assert.deepEqual(errors,[]);await context.close();
 });
});
