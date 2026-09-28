'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs/promises'),path=require('node:path');
test('image names filter all providers for one video frame in both histories and preserve saved column order',{
  skip:process.env.RUN_BROWSER_TESTS!=='1',timeout:60000,
},async t=>{
  const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
  const browser=await chromium.launch({headless:true,args:['--no-sandbox']});t.after(()=>browser.close());
  const html=await fs.readFile(path.join(__dirname,'../admin-audit.html'));
  for(const width of [1440,390])await t.test(String(width),async()=>{
    const context=await browser.newContext({viewport:{width,height:900}}),page=await context.newPage(),errors=[],requests=[];
    page.on('pageerror',error=>errors.push(error.message));
    const id='00000000-0000-4000-8000-000000000001',file='00000000-0000-4000-8000-000000000002',key=file+':frame:0:0';
    const name='סרטון <img src=x onerror=alert(1)>.webm · תמונה 1 · שנייה 0';
    const rows=['openai','gemini','google_vision'].map((provider,i)=>({id:String(i+2),operation_id:id,kind:'provider_call_finished',
      status:'observed',created_at:'2026-09-28T12:00:01Z',check_type:'modesty',check_outcome:i===1?'blocked':'passed',
      details:{provider,checkType:'modesty',checkOutcome:i===1?'blocked':'passed',frameIndex:i===2?1:0},
      scanImage:{key:i===2?file+':frame:1:5000':key,name:i===2?'סרטון.webm · תמונה 2 · שנייה 5':name}}));
    const root={id,action:'upload_file',status:'failed',media_type:'video',created_at:'2026-09-28T12:00:00Z',event_count:'4',sub_event_count:'3'};
    await page.addInitScript(()=>localStorage.setItem('bt_admin_token','mock-admin'));
    await page.route('**/*',async route=>{
      const url=new URL(route.request().url());
      if(url.hostname==='audit.test')return route.fulfill({contentType:'text/html',body:url.pathname.endsWith('.html')?html:''});
      assert.equal(route.request().headers().authorization,'Bearer mock-admin');requests.push(url);
      if(url.pathname.endsWith('/catalog'))return route.fulfill({json:{actions:[]}});
      if(url.pathname.endsWith('/column-order'))return route.fulfill({json:{orders:{operations:['expand','preview','created_at'],events:['select','preview','created_at']},widths:{},formats:{}}});
      if(url.pathname.endsWith('/filter-options'))return route.fulfill({json:{options:[{value:key,label:name},{value:rows[2].scanImage.key,label:rows[2].scanImage.name}],hasMore:false}});
      const filter=JSON.parse(url.searchParams.get('columnFilters')||'{}').scan_image;
      const selected=filter?rows.filter(row=>filter.values.includes(row.scanImage.key)!==!!filter.exclude):rows;
      if(url.pathname.endsWith('/operations'))return route.fulfill({json:{operations:[{...root,first_sub_event:selected[0]}],nextCursor:null}});
      return route.fulfill({json:{events:selected.map(row=>({...row,operation_action:root.action,current_operation_status:root.status})),nextCursor:null}});
    });
    await page.goto('https://audit.test/admin-audit.html');
    const settled=()=>page.waitForFunction(()=>state.hasLoaded&&!state.loading&&columnOrdersLoaded&&[...state.pages.values()].every(p=>!p.loading));
    await settled();
    for(const mode of ['operations','events']){
      if(mode==='events'){await page.locator('#events-tab').click();await settled();}
      const columns=await page.locator('thead th').evaluateAll(nodes=>nodes.map(node=>node.dataset.columnId));
      assert.equal(columns.indexOf('scan_image')+1,columns.indexOf('preview'));
      assert.equal(await page.locator('[data-field="scan_image"]').first().textContent(),name);
      assert.equal(await page.locator('[data-field="scan_image"] img').count(),0);
      await page.locator('[data-column-filter="scan_image"]').click();
      await page.waitForFunction(()=>columnPopup&&!columnPopup.loading);
      assert.equal(requests.findLast(url=>url.pathname.endsWith('/filter-options')).searchParams.get('column'),'scan_image');
      await page.locator('#column-all').uncheck();
      await page.locator(`[data-option-value="${key}"]`).check();
      await page.locator('#column-apply').click();await settled();
      assert.deepEqual(await page.evaluate(()=>state.columns[state.mode].scan_image),{values:[key],exclude:false});
      if(mode==='operations'){await page.locator('[data-expand]').click();await settled();}
      assert.deepEqual((await page.locator('[data-event-id]').evaluateAll(nodes=>nodes.map(node=>node.dataset.eventId))).sort(),['2','3']);
      assert.equal(await page.locator('[data-event-id="3"] [data-field="operation_status"]').getAttribute('data-scan-status'),'blocked');
    }
    assert.deepEqual(errors,[]);await context.close();
  });
});
