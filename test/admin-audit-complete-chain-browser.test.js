'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs/promises'),path=require('node:path');
test('complete child chains retry atomically, cancel on collapse, and refresh beyond the previous row count',{skip:process.env.RUN_BROWSER_TESTS!=='1',timeout:60000},async t=>{
 const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright'),browser=await chromium.launch({headless:true,args:['--no-sandbox']});t.after(()=>browser.close());
 const context=await browser.newContext({viewport:{width:1440,height:950},locale:'he-IL'}),page=await context.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
 const html=await fs.readFile(path.join(__dirname,'../admin-audit.html'));
 const root={id:'00000000-0000-4000-8000-000000000001',action:'upload_file',created_at:'2026-09-27T08:00:00Z',status:'completed',root_event_id:'1',event_count:'206',sub_event_count:'205'};
 const event=index=>({id:String(index+2),operation_id:root.id,created_at:new Date(Date.parse(root.created_at)+(index+1)*1000).toISOString(),kind:'scan_queued',status:'completed',sub_event_index:String(index+1),sub_event_total:root.sub_event_count});
 const events=Array.from({length:205},(_,i)=>event(i));root.first_sub_event=events[0];let mode='fail',release,arrived,childRequests=0;const held=new Promise(resolve=>release=resolve),pending=new Promise(resolve=>arrived=resolve);
 await page.addInitScript(()=>localStorage.setItem('bt_admin_token','mock-token'));
 await page.route('**/*',async route=>{
  const url=new URL(route.request().url());if(url.hostname==='audit.test')return route.fulfill({contentType:'text/html',body:url.pathname.endsWith('.html')?html:''});
  if(url.pathname.endsWith('/column-order'))return route.fulfill({json:{orders:{},widths:{}}});
  if(url.pathname.endsWith('/catalog'))return route.fulfill({json:{actions:[]}});
  if(url.pathname.endsWith('/operations'))return route.fulfill({json:{operations:[root],nextCursor:null}});
  if(url.pathname.endsWith('/events')){
   childRequests++;assert.equal(url.searchParams.get('limit'),'200');assert.equal(url.searchParams.get('steps'),'1');assert.equal(url.searchParams.get('sort'),'created_at');assert.equal(url.searchParams.get('direction'),'asc');
   const offset=Number(url.searchParams.get('before')||0);
   if(offset&&mode==='fail')return route.fulfill({status:503,json:{error:'temporary'}});
   if(offset&&mode==='hold'){arrived();await held;try{return await route.fulfill({json:{events:[{...event(9997)}],nextCursor:null}});}catch{return;}}
   return route.fulfill({json:{events:events.slice(offset,offset+200),nextCursor:events.length>offset+200?String(offset+200):null}});
  }throw new Error('Unexpected request');
 });
 await page.goto('https://audit.test/admin-audit.html');await page.waitForFunction(()=>state.hasLoaded&&!state.loading&&columnOrdersLoaded);await page.evaluate(()=>{cancelAutoRefresh();scheduleAutoRefresh=()=>{};});
 const first=page.locator('[data-operation-id]'),toggle=first.locator('[data-expand]'),children=page.locator('[data-parent-operation-id]');
 await toggle.click();await page.waitForFunction(()=>[...state.pages.values()].every(p=>!p.loading));assert.equal(await children.count(),1);assert.equal(await page.locator('.group-note [role="alert"]').count(),1);
 assert.equal(await page.evaluate(()=>[...state.pages.values()][0].loaded),false);assert.equal(await page.locator('[data-event-more]').count(),0);
 mode='hold';await page.locator('.group-note [role="alert"] button').click();await pending;await toggle.click();assert.equal(await children.count(),1);assert.equal(await page.evaluate(()=>[...state.pages.values()][0].loading),false);
 mode='normal';await toggle.click();release();await page.waitForFunction(()=>[...state.pages.values()].every(p=>p.loaded&&!p.loading));
 assert.equal(await children.count(),205);assert.equal(await page.locator('[data-event-id="9999"]').count(),0);assert.equal(await page.locator('[data-event-more]').count(),0);assert.equal(await page.locator('.group-note [role="alert"]').count(),0);assert.equal(await page.evaluate(()=>[...state.pages.values()][0].cursor),null);
 const before=childRequests;await toggle.click();await toggle.click();assert.equal(await children.count(),205);assert.equal(childRequests,before);
 root.event_count='207';root.sub_event_count='206';events.push(event(205));for(const item of events)item.sub_event_total='206';
 await page.evaluate(()=>autoRefresh());assert.equal(await children.count(),206);assert.equal(await page.locator('[data-event-id="207"] [data-field="step_index"]').innerText(),'206 מתוך 206');assert.equal(await page.locator('[data-event-more]').count(),0);assert.equal(await page.locator('#live-error').innerText(),'');
 assert.deepEqual(errors,[]);await context.close();
});
