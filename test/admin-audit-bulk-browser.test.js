'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs/promises'),path=require('node:path');
test('audit selection and delete-all require confirmation, keep a fixed boundary and handle failed saves',{
 skip:process.env.RUN_BROWSER_TESTS!=='1',timeout:60000,
},async t=>{
 const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');const browser=await chromium.launch({headless:true,args:['--no-sandbox']});t.after(()=>browser.close());
 const html=await fs.readFile(path.join(__dirname,'../admin-audit.html'));
 for(const width of [1440,390])await t.test(String(width),async()=>{
  const context=await browser.newContext({viewport:{width,height:900}}),page=await context.newPage(),requests=[],errors=[];page.on('pageerror',e=>errors.push(e.message));
  const root={id:'00000000-0000-4000-8000-000000000001',action:'upload_file',created_at:'2026-09-25T08:00:00Z',root_event_id:'1',event_count:'3',sub_event_count:'2'};
  const events=[2,3].map(id=>({id:String(id),operation_id:root.id,kind:'scan_queued',created_at:root.created_at,sub_event_index:String(id-1),sub_event_total:'2'}));root.first_sub_event=events[0];let allBatches=0,fail=false;
  await page.addInitScript(()=>localStorage.setItem('bt_admin_token','mock'));
  await page.route('**/*',async route=>{
   const url=new URL(route.request().url());if(url.hostname==='audit.test')return route.fulfill({contentType:'text/html',body:url.pathname.endsWith('.html')?html:''});
   if(url.pathname.endsWith('/column-order'))return route.fulfill({json:{orders:{},widths:{}}});
   if(url.pathname.endsWith('/catalog'))return route.fulfill({json:{canDelete:true,actions:[],statuses:[],categories:[]}});
   if(url.pathname.endsWith('/operations'))return route.fulfill({json:{operations:[root],nextCursor:null}});
   if(url.pathname.endsWith('/events'))return route.fulfill({json:{events,nextCursor:null}});
   if(url.pathname.endsWith('/deletion-preview'))return route.fulfill({json:{through:'99',operations:'2',events:'6'}});
   if(url.pathname.endsWith('/records')){assert.equal(route.request().method(),'DELETE');const body=route.request().postDataJSON();requests.push(body);if(fail)return route.fulfill({status:503,json:{error:'Unavailable'}});
    if(body.scope==='all')allBatches++;return route.fulfill({json:{deleted:true,deletedEvents:2,deletedOperations:body.scope==='all'?1:0,remaining:body.scope==='all'&&allBatches===1?'1':'0'}});}
   throw Error(`Unexpected ${url.pathname}`);
  });
  await page.goto('https://audit.test/admin-audit.html');await page.waitForFunction(()=>columnOrdersLoaded&&!state.loading&&canDelete);
  await page.locator('[data-expand]').click();await page.waitForFunction(()=>[...state.pages.values()].every(p=>!p.loading));
  await page.locator('#select-visible').click();assert.match(await page.locator('#delete-selected').innerText(),/\(2\)/);
  await page.locator('#delete-selected').click();await page.locator('#delete-dialog[open]').waitFor();assert.equal(requests.length,0);
  await page.locator('#delete-cancel').click();assert.equal(requests.length,0);
  await page.locator('#delete-selected').click();await page.locator('#delete-confirm').click();await page.waitForFunction(()=>!deleteBusy&&!state.loading);
  assert.deepEqual(requests[0],{scope:'selected',confirm:'DELETE_SELECTED_AUDIT',operations:[],events:['2','3']});
  await page.locator('#delete-all').click();await page.waitForFunction(()=>deleteTarget?.ready);
  assert.match(await page.locator('#delete-description').innerText(),/מחוץ לסינון/);await page.locator('#delete-confirm').click();await page.waitForFunction(()=>!deleteBusy&&!state.loading);
  assert.equal(allBatches,2);assert.deepEqual(requests[1],requests[2]);assert.equal(requests[1].through,'99');
  fail=true;await page.locator('#select-visible').click();await page.locator('#delete-selected').click();await page.locator('#delete-confirm').click();await page.waitForFunction(()=>!deleteBusy);
  assert.match(await page.locator('#delete-error').innerText(),/לא אושרה/);assert.equal(await page.locator('#delete-confirm').isDisabled(),true);
  await page.locator('#delete-cancel').click();assert.deepEqual(errors,[]);await context.close();
 });
});
