'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs/promises'),path=require('node:path');
test('action filter offers the same capture names as cells and applies inclusion/exclusion in both views', {skip:process.env.RUN_BROWSER_TESTS!=='1',timeout:60000},async t=>{
 const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright'),browser=await chromium.launch({headless:true,args:['--no-sandbox']});t.after(()=>browser.close());
 const html=await fs.readFile(path.join(__dirname,'../admin-audit.html'));
 for(const width of [1440,390])await t.test(String(width),async()=>{
  const context=await browser.newContext({viewport:{width,height:950},locale:'he-IL'}),page=await context.newPage(),errors=[],requests=[];page.on('pageerror',e=>errors.push(e.message));
  const rows=[['capture:camera_video','צילום וידאו','video','camera_video'],['media:video','העלאת וידאו','video','picker'],['capture:camera_image','צילום תמונה','image','camera_image']].map(([code,label,media_type,capture_kind],index)=>{
   const root={id:`00000000-0000-4000-8000-00000000000${index+1}`,created_at:'2026-09-27T08:00:00Z',action:'upload_file',media_type,capture_kind,status:'completed',root_event_id:String(index*10+1),event_count:'2',sub_event_count:'1'};
   const event={id:String(index*10+2),operation_id:root.id,operation_action:root.action,media_type,capture_kind,created_at:root.created_at,kind:'upload_context',status:'completed',current_operation_status:'completed',sub_event_index:'1',sub_event_total:'1'};root.first_sub_event=event;return {code,label,root,event};
  });
  await page.addInitScript(()=>localStorage.setItem('bt_admin_token','mock-token'));
  await page.route('**/*',async route=>{
   const url=new URL(route.request().url());if(url.hostname==='audit.test')return route.fulfill({contentType:'text/html',body:url.pathname.endsWith('.html')?html:''});requests.push(url);
   if(url.pathname.endsWith('/column-order'))return route.fulfill({json:{orders:{operations:['expand','created_at','action','kind']},widths:{operations:{action:280}}}});
   if(url.pathname.endsWith('/catalog'))return route.fulfill({json:{actions:[]}});
   if(url.pathname.endsWith('/filter-options')){assert.equal(url.searchParams.get('column'),'display_action');return route.fulfill({json:{options:rows.filter(row=>row.label.includes(url.searchParams.get('search')||'')).map(row=>({value:row.code,label:row.label})),hasMore:false}});}
   const filter=JSON.parse(url.searchParams.get('columnFilters')||'{}').display_action;
   const selected=filter?rows.filter(row=>filter.exclude!==filter.values.includes(row.code)):rows;
   if(url.pathname.endsWith('/operations'))return route.fulfill({json:{operations:selected.map(row=>row.root),nextCursor:null}});
   if(url.pathname.endsWith('/events')){const id=/\/operations\/([^/]+)\/events$/.exec(url.pathname)?.[1];return route.fulfill({json:{events:(id?rows.filter(row=>row.root.id===id):selected).map(row=>row.event),nextCursor:null}});}
   throw new Error('Unexpected request');
  });
  await page.goto('https://audit.test/admin-audit.html');await page.waitForFunction(()=>state.hasLoaded&&!state.loading&&columnOrdersLoaded);
  for(const mode of ['operations','events']){
   if(mode==='events'){await page.locator('#events-tab').click();await page.waitForFunction(()=>state.mode==='events'&&!state.loading);}
   await page.locator('[data-column-filter="display_action"]').click();await page.waitForFunction(()=>columnPopup&&!columnPopup.loading);
   assert.ok((await page.locator('#column-options').innerText()).includes('צילום וידאו'));
   await page.locator('#column-all').uncheck();await page.locator('[data-option-value="capture:camera_video"]').check();await page.locator('#column-apply').click();await page.waitForFunction(()=>!state.loading&&!columnPopup);
   assert.deepEqual(await page.locator('.action-cell').allTextContents(),['צילום וידאו']);
   assert.deepEqual(await page.evaluate(()=>state.columns[state.mode].display_action),{values:['capture:camera_video'],exclude:false});
   if(mode==='operations'){const first=page.locator('tr.operation-row'),color=await first.evaluate(n=>n.style.getPropertyValue('--group-color'));await first.locator('[data-expand]').click();await page.waitForFunction(()=>[...state.pages.values()].every(p=>!p.loading));assert.equal(await page.locator('.action-cell').first().innerText(),'צילום וידאו');assert.equal(await first.evaluate(n=>n.style.getPropertyValue('--group-color')),color);assert.equal(await page.locator('[data-column-id="action"] .column-resize').getAttribute('aria-valuenow'),'280');}
   await page.locator('[data-column-filter="display_action"]').click();await page.waitForFunction(()=>columnPopup&&!columnPopup.loading);await page.locator('#column-all').check();await page.locator('[data-option-value="capture:camera_video"]').uncheck();await page.locator('#column-apply').click();await page.waitForFunction(()=>!state.loading&&!columnPopup);
   const labels=await page.locator('.action-cell').allTextContents();assert.ok(labels.includes('העלאת וידאו'));assert.ok(!labels.includes('צילום וידאו'));
  }
  assert.ok(requests.some(url=>url.pathname.endsWith('/operations')&&url.searchParams.get('columnFilters')?.includes('display_action')));assert.deepEqual(errors,[]);await context.close();
 });
});
