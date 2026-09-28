'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs/promises'),path=require('node:path');
test('clicking a stopped or regular image name opens only that image across providers and clears conflicting filters',{
  skip:process.env.RUN_BROWSER_TESTS!=='1',timeout:60000,
},async t=>{
  const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright'),browser=await chromium.launch({headless:true,args:['--no-sandbox']});
  t.after(()=>browser.close());const html=await fs.readFile(path.join(__dirname,'../admin-audit.html'));
  for(const width of [1440,390])await t.test(String(width),async()=>{
    const context=await browser.newContext({viewport:{width,height:900}}),page=await context.newPage(),errors=[],requests=[];
    page.on('pageerror',e=>errors.push(e.message));
    const id='00000000-0000-4000-8000-000000000001',key='00000000-0000-4000-8000-000000000002:frame:3:14991';
    const name='video.webm · תמונה 4 · שנייה 14.991';
    const root={id,action:'upload_file',status:'failed',created_at:'2026-09-28T12:00:00Z',event_count:'8',sub_event_count:'7',
      stoppedEvidence:{items:[{name,key,preview:null,reason:'בדיקת התמונה לא הושלמה'},{name:'unknown.webm',preview:null}]},
      first_sub_event:{id:'20',operation_id:id,kind:'scan_workflow_finished',status:'failed',details:{}}};
    const rows=[['openai','passed',key],['gemini','blocked',key],['gemini','passed',key.replace(':3:14991',':4:19999')],
      ['gemini','passed',key.replace('000000000002','000000000003')]].map(([provider,outcome,imageKey],i)=>({id:String(i+2),operation_id:id,
        kind:'provider_call_finished',status:'observed',check_type:'modesty',check_outcome:outcome,
        created_at:'2026-09-28T12:00:01Z',details:{provider,checkType:'modesty',checkOutcome:outcome},scanImage:{key:imageKey,name}}));
    await page.addInitScript(()=>localStorage.setItem('bt_admin_token','mock-admin'));
    await page.route('**/*',route=>{
      const url=new URL(route.request().url());
      if(url.hostname==='audit.test')return route.fulfill({contentType:'text/html',body:url.pathname.endsWith('.html')?html:''});
      assert.equal(route.request().headers().authorization,'Bearer mock-admin');requests.push(url);
      if(url.pathname.endsWith('/catalog'))return route.fulfill({json:{actions:[]}});
      if(url.pathname.endsWith('/column-order'))return route.fulfill({json:{orders:{operations:['expand','stopped_evidence','scan_image'],events:['select','scan_image']},widths:{},formats:{}}});
      if(url.pathname.endsWith('/filter-options')){
        const field=url.searchParams.get('column');const options={scan_status:[{value:'failed',label:'נכשל'}],provider:[{value:'gemini',label:'Gemini'}]};
        return route.fulfill({json:{options:options[field]||[],hasMore:false}});
      }
      if(url.pathname.endsWith('/operations'))return route.fulfill({json:{operations:[root],nextCursor:null}});
      let selected=rows;const filters=JSON.parse(url.searchParams.get('columnFilters')||'{}');
      for(const [field,filter]of Object.entries(filters))selected=selected.filter(row=>filter.values.includes(
        field==='scan_image'?row.scanImage.key:field==='provider'?row.details.provider:row.check_outcome)!==!!filter.exclude);
      return route.fulfill({json:{events:selected,nextCursor:null}});
    });
    await page.goto('https://audit.test/admin-audit.html');
    const settled=()=>page.waitForFunction(()=>state.hasLoaded&&!state.loading&&columnOrdersLoaded);
    await settled();
    const visibleOrder=()=>page.locator('thead th').evaluateAll(nodes=>nodes.map(node=>node.dataset.columnId));
    const originalOrder=await visibleOrder();
    const savedOrders=await page.evaluate(()=>JSON.parse(JSON.stringify(columnOrders)));
    // File drill-down preserves shared columns without saving over either tab's order.
    const shared=new Set(savedOrders.events.filter(key=>originalOrder.includes(key)));
    const expectedOrder=originalOrder.filter(key=>shared.has(key));
    assert.notDeepEqual(savedOrders.events.filter(key=>shared.has(key)),expectedOrder);
    const filter=async(field,value)=>{
      await page.locator(`[data-column-filter="${field}"]`).click();await page.waitForFunction(()=>columnPopup&&!columnPopup.loading);
      await page.locator('#column-all').uncheck();await page.locator(`[data-option-value="${value}"]`).check();
      await page.locator('#column-apply').click();await settled();
    };
    await filter('scan_status','failed');
    assert.equal(await page.locator('[data-field="stopped_evidence"] [data-image-filter]').count(),1);
    await page.locator('[data-field="stopped_evidence"] [data-image-filter]').click();await settled();
    const assertImageOnly=async()=>{
      assert.equal(await page.locator('#events-tab').getAttribute('aria-selected'),'true');
      assert.deepEqual(await page.evaluate(()=>state.columns.events),{scan_image:{values:[key],exclude:false}});
      assert.deepEqual((await page.locator('[data-event-id]').evaluateAll(nodes=>nodes.map(node=>node.dataset.eventId))).sort(),['2','3']);
      const query=requests.findLast(url=>url.pathname.endsWith('/events'));
      assert.deepEqual(JSON.parse(query.searchParams.get('columnFilters')),{scan_image:{values:[key],exclude:false}});
      assert.equal(query.searchParams.get('sort'),'created_at');assert.equal(query.searchParams.get('direction'),'asc');
      assert.deepEqual((await visibleOrder()).filter(key=>shared.has(key)),expectedOrder);
      assert.deepEqual(await page.evaluate(()=>columnOrders),savedOrders);
    };
    await assertImageOnly();
    await filter('provider','gemini');assert.equal(await page.locator('[data-event-id]').count(),1);
    const nameButton=page.locator('[data-field="scan_image"] [data-image-filter]');
    await nameButton.focus();await page.keyboard.press('Enter');await settled();await assertImageOnly();
    await page.locator('#refresh').click();await settled();await assertImageOnly();
    await page.locator('#open-column-settings').click();
    assert.deepEqual(await page.evaluate(()=>settingsDraft.order),await visibleOrder());
    await page.locator('#settings-cancel').click();
    await page.locator('#operations-tab').click();await settled();
    assert.deepEqual(await visibleOrder(),originalOrder);
    await page.locator('#events-tab').click();await settled();
    assert.deepEqual(await visibleOrder(),savedOrders.events);
    // A direct click within the events tab keeps that tab's own saved order.
    await page.locator('[data-field="scan_image"] [data-image-filter]').first().click();await settled();
    assert.deepEqual(await visibleOrder(),savedOrders.events);
    assert.deepEqual(errors,[]);await context.close();
  });
});
