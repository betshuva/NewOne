'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs/promises'),path=require('node:path');
test('overall object status stays separate from each scan and filters by final recipient outcome',{
  skip:process.env.RUN_BROWSER_TESTS!=='1',timeout:60000,
},async t=>{
  const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright'),browser=await chromium.launch({headless:true,args:['--no-sandbox']});
  t.after(()=>browser.close());const html=await fs.readFile(path.join(__dirname,'../admin-audit.html'));
  for(const width of [1440,390])await t.test(String(width),async()=>{
    const context=await browser.newContext({viewport:{width,height:900}}),page=await context.newPage(),errors=[];
    page.on('pageerror',error=>errors.push(error.message));
    const labels={blocked:'נחסם',blocked_for_recipient:'נחסם למשתמש',sent:'נשלח'};
    const roots=Object.keys(labels).map((status,i)=>{
      const id=`00000000-0000-4000-8000-00000000000${i+1}`;
      return {id,action:'upload_file',status:'failed',created_at:'2026-09-28T12:00:00Z',event_count:'2',sub_event_count:'1',
        dispatch:{object_status:status,dispatch_state:status==='blocked_for_recipient'?'blocked':status,dispatch_reason:'סיבה מתועדת'},
        first_sub_event:{id:String(i+2),operation_id:id,kind:'provider_call_finished',status:'observed',check_type:'modesty',check_outcome:'passed',details:{}}};
    });
    await page.addInitScript(()=>localStorage.setItem('bt_admin_token','mock-admin'));
    await page.route('**/*',route=>{
      const url=new URL(route.request().url());
      if(url.hostname==='audit.test')return route.fulfill({contentType:'text/html',body:url.pathname.endsWith('.html')?html:''});
      assert.equal(route.request().headers().authorization,'Bearer mock-admin');
      if(url.pathname.endsWith('/catalog'))return route.fulfill({json:{actions:[]}});
      if(url.pathname.endsWith('/column-order'))return route.fulfill({json:{orders:{operations:['expand','operation_status','preview'],events:['select','operation_status','preview']},widths:{},formats:{}}});
      if(url.pathname.endsWith('/filter-options')){assert.equal(url.searchParams.get('column'),'object_status');return route.fulfill({json:{options:Object.entries(labels).map(([value,label])=>({value,label})),hasMore:false}});}
      const filter=JSON.parse(url.searchParams.get('columnFilters')||'{}').object_status;
      const selected=filter?roots.filter(row=>filter.values.includes(row.dispatch.object_status)!==!!filter.exclude):roots;
      if(url.pathname.endsWith('/operations'))return route.fulfill({json:{operations:selected,nextCursor:null}});
      return route.fulfill({json:{events:selected.map(row=>({...row.first_sub_event,current_operation_status:row.status,operation_action:row.action,dispatch:row.dispatch})),nextCursor:null}});
    });
    await page.goto('https://audit.test/admin-audit.html');
    const settled=()=>page.waitForFunction(()=>state.hasLoaded&&!state.loading&&columnOrdersLoaded);
    await settled();
    for(const mode of ['operations','events']){
      if(mode==='events'){await page.locator('#events-tab').click();await settled();}
      const columns=await page.locator('thead th').evaluateAll(nodes=>nodes.map(node=>node.dataset.columnId));
      assert.equal(columns.indexOf('object_status')+1,columns.indexOf('operation_status'));
      for(const [i,[code,label]]of Object.entries(labels).entries()){
        const row=page.locator(`[data-event-id="${i+2}"]`);
        assert.equal(await row.locator('[data-field="object_status"]').textContent(),label);
        assert.equal(await row.locator('[data-field="object_status"]').getAttribute('data-object-status'),code);
        assert.equal(await row.locator('[data-field="operation_status"]').getAttribute('data-scan-status'),'passed');
      }
      await page.locator('[data-column-filter="object_status"]').click();
      await page.waitForFunction(()=>columnPopup&&!columnPopup.loading);
      await page.locator('#column-all').uncheck();await page.locator('[data-option-value="blocked_for_recipient"]').check();
      await page.locator('#column-apply').click();await settled();
      assert.equal(await page.locator('[data-field="object_status"]').count(),1);
      assert.equal(await page.locator('[data-field="object_status"]').textContent(),'נחסם למשתמש');
    }
    assert.deepEqual(errors,[]);await context.close();
  });
});
