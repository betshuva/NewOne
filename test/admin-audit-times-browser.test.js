'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs/promises'),path=require('node:path');
test('elapsed and whole-operation duration remain distinct across collapse, filters, layouts and event view',{skip:process.env.RUN_BROWSER_TESTS!=='1',timeout:60000},async t=>{
 const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright'),browser=await chromium.launch({headless:true,args:['--no-sandbox']});t.after(()=>browser.close());
 const html=await fs.readFile(path.join(__dirname,'../admin-audit.html')),{COLUMN_IDS}=require('../server/audit-column-order');
 for(const width of [1440,390])await t.test(String(width),async()=>{
  const context=await browser.newContext({viewport:{width,height:950},locale:'he-IL',timezoneId:'Asia/Jerusalem'}),page=await context.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
  const root={id:'00000000-0000-4000-8000-000000000001',action:'upload_file',created_at:'2026-09-27T08:00:00Z',root_event_id:'1',event_count:'3',sub_event_count:'2',status:'completed',duration_ms:'155003'};
  const events=[{id:'2',operation_id:root.id,kind:'upload_context',status:'completed',created_at:'2026-09-27T08:00:01.006Z',sub_event_index:'1',sub_event_total:'2'},{id:'3',operation_id:root.id,kind:'scan_workflow_finished',status:'completed',created_at:'2026-09-27T08:02:35.003Z',sub_event_index:'2',sub_event_total:'2'}];root.first_sub_event=events[0];
  let lastQuery;
  await page.addInitScript(()=>localStorage.setItem('bt_admin_token','mock-token'));
  await page.route('**/*',async route=>{
   const url=new URL(route.request().url());
   if(url.hostname==='audit.test')return route.fulfill({contentType:'text/html',body:url.pathname.endsWith('.html')?html:''});
   if(url.pathname.endsWith('/column-order'))return route.fulfill({json:{orders:{operations:COLUMN_IDS.operations.filter(k=>k!=='elapsed_ms'),events:COLUMN_IDS.events.filter(k=>!['elapsed_ms','duration_ms'].includes(k))},widths:{operations:{duration_ms:222}}}});
   if(url.pathname.endsWith('/catalog'))return route.fulfill({json:{actions:[],recordingStartedAt:root.created_at}});
   if(url.pathname.endsWith('/operations')){lastQuery=url.searchParams;return route.fulfill({json:{operations:[root],nextCursor:null}});}
   if(url.pathname.endsWith('/events'))return route.fulfill({json:{events:events.map(e=>({...e,operation_created_at:root.created_at,operation_duration_ms:root.duration_ms})),nextCursor:null}});
   throw new Error(`Unexpected request ${url.pathname}`);
  });
  await page.goto('https://audit.test/admin-audit.html');await page.waitForFunction(()=>state.hasLoaded&&!state.loading&&columnOrdersLoaded);
  const first=page.locator('[data-event-id="2"]');
  assert.equal(await first.locator('[data-field="created_at"]').innerText(),'27/09/26\n11:00:01.00');
  assert.equal(await page.locator('#started').innerText(),'תחילת תיעוד: 27/09/26 11:00:00.00');
  assert.match(await page.locator('#live-updated').innerText(),/^עודכן \d{2}\/\d{2}\/\d{2} \d{2}:\d{2}:\d{2}\.\d{2}$/);

  assert.equal(await first.locator('[data-timing="elapsed"]').innerText(),'00:01');assert.equal(await first.locator('[data-timing="total"]').innerText(),'02:35');assert.doesNotMatch(await first.locator('.action-cell').innerText(),/02:35/);
  assert.equal(await page.locator('th[data-column-id="duration_ms"] .column-resize').getAttribute('aria-valuenow'),'222');
  const keys=await page.locator('thead th').evaluateAll(nodes=>nodes.map(n=>n.dataset.columnId));assert.equal(keys.length,new Set(keys).size);assert.equal(keys.indexOf('duration_ms'),keys.indexOf('elapsed_ms')+1);
  const color=await first.evaluate(n=>n.style.getPropertyValue('--group-color'));
  await first.locator('[data-expand]').click();await page.waitForFunction(()=>[...state.pages.values()].every(p=>!p.loading));assert.equal(await page.locator('[data-event-id="3"] [data-timing="elapsed"]').innerText(),'02:35');assert.equal(await page.locator('[data-event-id="3"] [data-timing="total"]').innerText(),'02:35');
  await first.locator('[data-expand]').click();assert.equal(await page.locator('tbody tr').count(),1);assert.equal(await first.locator('[data-timing="total"]').innerText(),'02:35');
  await page.locator('[data-column-filter="duration_ms"]').click();await page.locator('#column-dialog[open]').waitFor();
  assert.equal(await page.locator('#column-start').getAttribute('placeholder'),'02:35');await page.locator('#column-start').fill('02:00');await page.locator('#column-end').fill('02:40');await page.locator('#column-end').press('Enter');await page.waitForFunction(()=>!state.loading&&!columnPopup);
  assert.deepEqual(JSON.parse(lastQuery.get('columnFilters')).duration_ms,{min:'120000',max:'160000'});
  assert.equal(await first.locator('[data-timing="total"]').innerText(),'02:35');assert.equal(await first.evaluate(n=>n.style.getPropertyValue('--group-color')),color);
  await first.locator('[data-timing="total"]').scrollIntoViewIfNeeded();await page.screenshot({path:`/tmp/audit-times-${width}.png`});
  await page.locator('#events-tab').click();await page.waitForFunction(()=>state.mode==='events'&&!state.loading);assert.equal(await first.locator('[data-timing="elapsed"]').innerText(),'00:01');assert.equal(await first.locator('[data-timing="total"]').innerText(),'02:35');
  root.duration_ms='180000';await page.evaluate(()=>load());await page.waitForFunction(()=>!state.loading);assert.equal(await first.locator('[data-timing="total"]').innerText(),'03:00');assert.equal(await first.locator('[data-timing="elapsed"]').innerText(),'00:01');
  assert.deepEqual(errors,[]);await context.close();
 });
});
