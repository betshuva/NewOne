'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs/promises'),path=require('node:path');
test('every data header exposes server filters and sorting, with numeric, duration and enum editors',{skip:process.env.RUN_BROWSER_TESTS!=='1',timeout:60000},async t=>{
 const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright'),browser=await chromium.launch({headless:true,args:['--no-sandbox']});t.after(()=>browser.close());const html=await fs.readFile(path.join(__dirname,'../admin-audit.html'));
 for(const width of [1440,390])await t.test(String(width),async()=>{
  const context=await browser.newContext({viewport:{width,height:950},locale:'he-IL'}),page=await context.newPage(),errors=[],requests=[];page.on('pageerror',e=>errors.push(e.message));
  const root={id:'00000000-0000-4000-8000-000000000001',created_at:'2026-09-27T08:00:00Z',action:'upload_file',media_type:'video',capture_kind:'camera_video',status:'failed',reason_code:'scan_stopped',duration_ms:'27000',root_event_id:'1',event_count:'3',sub_event_count:'2'};
  const child={id:'2',operation_id:root.id,created_at:'2026-09-27T08:00:01.500Z',kind:'http_response',status:'completed',reason_code:'http_200',sub_event_index:'1',sub_event_total:'2',operation_created_at:root.created_at,operation_duration_ms:root.duration_ms,current_operation_status:root.status,current_operation_reason_code:root.reason_code,operation_action:root.action,details:{beforeWomen:true,afterWomen:false}};root.first_sub_event=child;
  await page.addInitScript(()=>localStorage.setItem('bt_admin_token','mock-token'));
  await page.route('**/*',async route=>{
   const url=new URL(route.request().url());if(url.hostname==='audit.test')return route.fulfill({contentType:'text/html',body:url.pathname.endsWith('.html')?html:''});requests.push(url);
   if(url.pathname.endsWith('/column-order'))return route.fulfill({json:{orders:{},widths:{}}});
   if(url.pathname.endsWith('/catalog'))return route.fulfill({json:{actions:[]}});
   if(url.pathname.endsWith('/filter-options')){const key=url.searchParams.get('column'),value=key==='operation_reason'?'scan_stopped':key==='beforeWomen'?'true':'http_200';return route.fulfill({json:{options:[{value,label:key==='beforeWomen'?'מותר':key==='operation_reason'?'הסריקה נעצרה':'השרת השיב בהצלחה'}],hasMore:false}});}
   if(url.pathname.endsWith('/operations'))return route.fulfill({json:{operations:[root],nextCursor:null}});
   if(url.pathname.endsWith('/events'))return route.fulfill({json:{events:[child],nextCursor:null}});throw new Error('Unexpected request');
  });
  await page.goto('https://audit.test/admin-audit.html');await page.waitForFunction(()=>state.hasLoaded&&!state.loading&&columnOrdersLoaded);
  for(const mode of ['operations','events']){
   if(mode==='events'){await page.locator('#events-tab').click();await page.waitForFunction(()=>state.mode==='events'&&!state.loading);}
   const headers=await page.locator('thead th').evaluateAll(nodes=>nodes.map(node=>({id:node.dataset.columnId,filter:!!node.querySelector('[data-column-filter]'),sort:!!node.querySelector('[data-column-sort]')})));
   for(const header of headers){const data=!['expand','select','details','preview','findings','dispatch_recipients'].includes(header.id);assert.equal(header.filter,data,header.id);assert.equal(header.sort,data,header.id);}
   for(const [field,value]of [['operation_reason','scan_stopped'],['step_reason','http_200'],['beforeWomen','true']]){
    await page.locator(`[data-column-filter="${field}"]`).click();await page.waitForFunction(()=>columnPopup&&!columnPopup.loading);await page.locator('#column-all').uncheck();await page.locator(`[data-option-value="${value}"]`).check();await page.locator('#column-apply').click();await page.waitForFunction(()=>!state.loading&&!columnPopup);
    assert.deepEqual(await page.evaluate(field=>state.columns[state.mode][field],field),{values:[value],exclude:false});
    await page.locator('#clear-columns').click();await page.waitForFunction(()=>!state.loading);
   }
   for(const field of ['elapsed_ms','frame_timestamp']){
    await page.locator(`[data-column-filter="${field}"]`).click();await page.locator('#column-start').fill('00:01.50');await page.locator('#column-end').fill('02:00');await page.locator('#column-apply').click();await page.waitForFunction(()=>!state.loading&&!columnPopup);
    assert.deepEqual(await page.evaluate(field=>state.columns[state.mode][field],field),{min:'1500',max:'120000'});await page.locator('#clear-columns').click();await page.waitForFunction(()=>!state.loading);
   }
   for(const field of ['operation_reason_code','step_reason','executor_identifier','frame_index'])for(const direction of ['asc','desc']){
    await page.locator(`[data-column-sort="${field}"]`).click();await page.waitForFunction(()=>!state.loading);
    const req=requests.findLast(url=>url.pathname.endsWith('/'+mode));assert.equal(req.searchParams.get('sort'),field);assert.equal(req.searchParams.get('direction'),direction);
   }
  }
  assert.deepEqual(errors,[]);await context.close();
 });
});
