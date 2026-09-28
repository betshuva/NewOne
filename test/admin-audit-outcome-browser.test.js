'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs/promises'),path=require('node:path');
test('collapsed first step shows whole-operation failure, reason and scan budget on desktop and mobile',{skip:process.env.RUN_BROWSER_TESTS!=='1',timeout:60000},async t=>{
 const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright'),browser=await chromium.launch({headless:true,args:['--no-sandbox']});t.after(()=>browser.close());
 const html=await fs.readFile(path.join(__dirname,'../admin-audit.html'));
 for(const width of [1440,390])await t.test(String(width),async()=>{
  const context=await browser.newContext({viewport:{width,height:950},locale:'he-IL'}),page=await context.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
  const root={id:'00000000-0000-4000-8000-000000000001',action:'upload_file',media_type:'video',created_at:'2026-09-27T08:00:00Z',root_event_id:'1',event_count:'100',sub_event_count:'99',status:'failed',status_source:'scan_workflow_finished',reason_code:'scan_stopped',outcome_event:{id:'100',status:'failed',reason_code:'scan_stopped'},scan_summary:{id:'99',status:'failed',reason_code:'scan_incomplete',details:{providerCallsUsed:29,providerCallsLimit:36}}};
  const events=[{id:'2',operation_id:root.id,kind:'upload_context',status:'completed',created_at:root.created_at,sub_event_index:'1',sub_event_total:'99'},{id:'99',operation_id:root.id,kind:'scan_workflow_finished',status:'failed',reason_code:'scan_incomplete',details:{providerCallsUsed:29,providerCallsLimit:36},created_at:root.created_at,sub_event_index:'98',sub_event_total:'99'}];root.first_sub_event=events[0];
  let childRequests=0;
  await page.addInitScript(()=>localStorage.setItem('bt_admin_token','mock-token'));
  await page.route('**/*',async route=>{
   const url=new URL(route.request().url());
   if(url.hostname==='audit.test')return route.fulfill({contentType:'text/html',body:url.pathname.endsWith('.html')?html:''});
   if(url.pathname.endsWith('/column-order'))return route.fulfill({json:{orders:{},widths:{operations:{action:280}}}});
   if(url.pathname.endsWith('/catalog'))return route.fulfill({json:{actions:[]}});
   if(url.pathname.endsWith('/operations'))return route.fulfill({json:{operations:[root],nextCursor:null}});
   if(url.pathname.endsWith('/events')){childRequests++;return route.fulfill({json:{events:events.map(event=>({...event,operation_action:root.action,operation_created_at:root.created_at,current_operation_status:root.status,current_operation_reason_code:root.reason_code,current_operation_status_source:root.status_source})),nextCursor:null}});}
   throw new Error(`Unexpected request ${url.pathname}`);
  });
  await page.goto('https://audit.test/admin-audit.html');await page.waitForFunction(()=>state.hasLoaded&&!state.loading&&columnOrdersLoaded);
  const first=page.locator('[data-event-id="2"]'),summary=first.locator('[data-field="operation_reason"]');
  assert.equal(childRequests,0);assert.equal(await page.locator('tbody tr').count(),1);
  const text=await summary.textContent();assert.equal(await first.locator('[data-field="operation_status"]').getAttribute('data-status'),'failed');assert.match(text,/בדיקה נדרשת לא הושלמה/);assert.equal(await first.locator('[data-field="provider_calls_used"]').textContent(),'29');assert.equal(await first.locator('[data-field="provider_calls_limit"]').textContent(),'36');
  assert.match(await first.locator('[data-field="event_explanation"]').textContent(),/פרטי המדיה והנמען/);
  assert.match(await first.locator('[data-field="status"]').textContent(),/הושלם/);assert.equal(await first.locator('[data-field="operation_status"]').getAttribute('data-status'),'failed');assert.doesNotMatch(await first.locator('.action-cell').textContent(),/הסריקה נעצרה/);
  const color=await first.evaluate(n=>n.style.getPropertyValue('--group-color'));
  await summary.scrollIntoViewIfNeeded();await page.screenshot({path:`/tmp/audit-outcome-${width}.png`});
  await first.locator('[data-expand]').click();await page.waitForFunction(()=>[...state.pages.values()].every(p=>!p.loading));
  assert.equal(await summary.textContent(),text);assert.equal(await page.locator('[data-field="operation_reason"]').count(),2);assert.equal(await page.locator('[data-event-id="99"]').evaluate(n=>n.style.getPropertyValue('--group-color')),color);
  await first.locator('[data-expand]').click();assert.equal(await page.locator('tbody tr').count(),1);assert.equal(await summary.textContent(),text);
  // Filtering to the completed upload-context event does not hide the failed operation result.
  await page.evaluate(()=>{state.columns.operations={kind:{values:['upload_context']}};return load();});await page.waitForFunction(()=>!state.loading);assert.equal(await summary.textContent(),text);
  // When a retry completes, a reload must remove the old failure and budget.
  root.status='completed';root.reason_code='queue_processed';root.scan_summary=null;root.outcome_event={id:'101',status:'completed',reason_code:'queue_processed'};
  await page.evaluate(()=>load());await page.waitForFunction(()=>!state.loading);assert.doesNotMatch(await summary.textContent(),/29|נעצרה|נכשלה/);assert.equal(await first.locator('[data-field="provider_calls_used"]').textContent(),'-');assert.equal(await first.locator('[data-field="operation_status"]').getAttribute('data-status'),'completed');
  await page.locator('#events-tab').click();await page.waitForFunction(()=>state.mode==='events'&&!state.loading);
  assert.equal(await page.locator('[data-event-id="99"] [data-field="operation_status"]').getAttribute('data-status'),'completed');
  assert.equal(await page.locator('[data-event-id="99"] [data-field="status"]').getAttribute('data-status'),'failed');
  assert.equal(await page.locator('[data-event-id="99"] [data-field="operation_id"]').textContent(),root.id);
  assert.equal(await page.locator('[data-event-id="99"] [data-field="event_id"]').textContent(),'99');
  root.status='blocked';root.reason_code='http_200';root.status_source='http_response';
  root.outcome_event={id:'101',status:'blocked',reason_code:'http_200'};
  root.dispatch={dispatch_state:'blocked',dispatch_code:'content_filter',dispatch_reason:'הקטגוריה חסומה בהגדרות הקבוצה'};
  await page.locator('#operations-tab').click();await page.waitForFunction(()=>state.mode==='operations'&&!state.loading);
  const filterStatus=first.locator('[data-field="operation_status"]');
  assert.match(await filterStatus.textContent(),/לא נשלח — הגדרות סינון/);
  assert.equal(await filterStatus.getAttribute('data-outcome'),'filtered');
  assert.match(await summary.textContent(),/הגדרות הסינון/);
  root.dispatch={dispatch_state:'blocked',dispatch_code:'dualModesty'};root.reason_code='dualModesty';
  await page.evaluate(()=>load());await page.waitForFunction(()=>!state.loading);
  assert.equal(await filterStatus.getAttribute('data-outcome'),null);
  assert.match(await filterStatus.textContent(),/נחסם/);
  assert.deepEqual(errors,[]);await context.close();
 });
});
