'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs/promises'),path=require('node:path');
const sharp=require('sharp');
test('a filtered stop summary displays the unresolved frame, filename and enlargement in both histories',{
  skip:process.env.RUN_BROWSER_TESTS!=='1',timeout:60000,
},async t=>{
  const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright'),browser=await chromium.launch({headless:true,args:['--no-sandbox']});
  t.after(()=>browser.close());const html=await fs.readFile(path.join(__dirname,'../admin-audit.html'));
  const image=await sharp({create:{width:80,height:60,channels:3,background:'red'}}).png().toBuffer();
  for(const width of [1440,390])await t.test(String(width),async()=>{
    const context=await browser.newContext({viewport:{width,height:900}}),page=await context.newPage(),errors=[],sizes=[];
    page.on('pageerror',e=>errors.push(e.message));
    const preview={id:'9',kind:'provider_call_finished',check_type:'modesty',check_outcome:'blocked',status:'blocked',
      checkPreviewUrl:'/api/admin/audit/events/9/preview?size=thumb',checkPreviewFullUrl:'/api/admin/audit/events/9/preview?size=full',
      details:{frameIndex:3,frameTimestampMs:14991,checkType:'modesty',checkOutcome:'blocked'}};
    const evidence=[{items:[{name:'video.webm · תמונה 4 · שנייה 14.991',reason:'בדיקות הצניעות אינן מסכימות',preview}]},
      {items:[{name:'technical.webm',reason:'לא תועדה תמונה מסוימת שגרמה לעצירה',preview:null}]},null,
      {items:[{name:'blocked.png',key:'00000000-0000-4000-8000-000000000101:image',reason:'התמונה נחסמה',preview}]},
      {items:[{name:'recipient.png',key:'00000000-0000-4000-8000-000000000102:image',reason:'התמונה נחסמה לפי הגדרות הסינון',preview}]}];
    const roots=evidence.map((stoppedEvidence,i)=>{
      const id=`00000000-0000-4000-8000-00000000000${i+1}`;
      return {id,action:'upload_file',status:i===2?'completed':i>=3?'blocked':'failed',status_source:'scan_workflow_finished',
        created_at:'2026-09-28T12:00:00Z',event_count:'20',sub_event_count:'19',stoppedEvidence,
        dispatch:{object_status:i===4?'blocked_for_recipient':i===3?'blocked':i===2?'sent':'stopped'},
        first_sub_event:{id:String(i+20),operation_id:id,kind:'scan_workflow_finished',status:i===2?'completed':i>=3?'blocked':'failed',details:{}}};
    });
    await page.addInitScript(()=>localStorage.setItem('bt_admin_token','mock-admin'));
    await page.route('**/*',route=>{
      const url=new URL(route.request().url());
      if(url.hostname==='audit.test')return route.fulfill({contentType:'text/html',body:url.pathname.endsWith('.html')?html:''});
      assert.equal(route.request().headers().authorization,'Bearer mock-admin');
      if(url.pathname.endsWith('/events/9/preview')){sizes.push(url.searchParams.get('size'));return route.fulfill({contentType:'image/png',body:image});}
      if(url.pathname.endsWith('/catalog'))return route.fulfill({json:{actions:[]}});
      if(url.pathname.endsWith('/column-order'))return route.fulfill({json:{orders:{operations:['expand','preview'],events:['select','preview']},widths:{},formats:{}}});
      if(url.pathname.endsWith('/filter-options'))return route.fulfill({json:{options:url.searchParams.get('column')==='stopped_file'
        ?[{value:'00000000-0000-4000-8000-000000000100',label:'video.webm'}]:[{value:'failed',label:'נכשל'}],hasMore:false}});
      const filters=JSON.parse(url.searchParams.get('columnFilters')||'{}');
      const selected=filters.stopped_file?roots.slice(0,1):filters.scan_status?roots.slice(0,2):roots;
      if(url.pathname.endsWith('/operations'))return route.fulfill({json:{operations:selected,nextCursor:null}});
      return route.fulfill({json:{events:selected.map(root=>({...root.first_sub_event,current_operation_status:root.status,operation_action:root.action,dispatch:root.dispatch,stoppedEvidence:root.stoppedEvidence})),nextCursor:null}});
    });
    await page.goto('https://audit.test/admin-audit.html');
    const settled=()=>page.waitForFunction(()=>state.hasLoaded&&!state.loading&&columnOrdersLoaded);
    await settled();
    for(const mode of ['operations','events']){
      if(mode==='events'){await page.locator('#events-tab').click();await settled();}
      const columns=await page.locator('thead th').evaluateAll(nodes=>nodes.map(node=>node.dataset.columnId));
      assert.equal(columns.indexOf('preview')+1,columns.indexOf('stopped_evidence'));
      assert.equal(await page.locator('[data-event-id="22"] [data-field="stopped_evidence"]').textContent(),'-');
      const recipient=page.locator('[data-event-id="24"]');
      assert.match(await recipient.locator('[data-field="object_status"]').textContent(),/נחסם למשתמש/);
      assert.equal(await recipient.locator('[data-field="stopped_evidence"]').textContent(),'');
      assert.equal(await recipient.locator('[data-field="stopped_evidence"] button, [data-field="stopped_evidence"] img').count(),0);
      const blocked=page.locator('[data-event-id="23"] [data-field="stopped_evidence"]');
      assert.match(await blocked.textContent(),/blocked.png.*התמונה נחסמה/s);
      assert.equal(await blocked.locator('[data-image-filter]').getAttribute('data-image-filter'),'00000000-0000-4000-8000-000000000101:image');
      await blocked.locator('[data-check-preview="9"]').click();
      await page.waitForFunction(()=>{const img=document.querySelector('#preview-image');return !img.hidden&&img.naturalWidth===80;});
      await page.locator('#close-preview').click();
      await page.locator('[data-column-filter="scan_status"]').click();await page.waitForFunction(()=>columnPopup&&!columnPopup.loading);
      await page.locator('#column-all').uncheck();await page.locator('[data-option-value="failed"]').check();
      await page.locator('#column-apply').click();await settled();
      const cell=page.locator('[data-event-id="20"] [data-field="stopped_evidence"]');
      assert.match(await cell.textContent(),/video.webm · תמונה 4 · שנייה 14.991/);
      assert.match(await page.locator('[data-event-id="21"] [data-field="stopped_evidence"]').textContent(),/לא תועדה תמונה מסוימת/);
      await cell.locator('[data-check-preview="9"]').scrollIntoViewIfNeeded();
      await cell.locator('[data-check-preview="9"]').click();
      await page.waitForFunction(()=>{const img=document.querySelector('#preview-image');return !img.hidden&&img.naturalWidth===80;});
      assert.match(await page.locator('#preview-caption').textContent(),/תמונה 4/);
      await page.locator('#close-preview').click();
      await page.waitForFunction(()=>!document.querySelector('#preview-image').hasAttribute('src'));
      await page.locator('[data-column-filter="stopped_file"]').click();
      await page.waitForFunction(()=>columnPopup&&!columnPopup.loading);
      assert.match(await page.locator('#column-title').textContent(),/קובץ שנחסם או שעצר את הסריקה/);
      assert.match(await page.locator('#column-options').textContent(),/video.webm/);
      await page.locator('#column-all').uncheck();
      await page.locator('[data-option-value="00000000-0000-4000-8000-000000000100"]').check();
      await page.locator('#column-apply').click();await settled();
      assert.equal(await page.locator('[data-event-id]').count(),1);
      assert.deepEqual(await page.evaluate(()=>state.columns[state.mode].stopped_file),{values:['00000000-0000-4000-8000-000000000100'],exclude:false});
    }
    assert.ok(sizes.includes('thumb')&&sizes.includes('full'));assert.deepEqual(errors,[]);await context.close();
  });
});
