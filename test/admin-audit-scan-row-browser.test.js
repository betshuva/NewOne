'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs/promises');
const path=require('node:path');
const sharp=require('sharp');
const {presentAuditCheck,CHECK_OUTCOME_LABELS}=require('../server/audit-check-presentation');

test('scan rows show their own frame and outcome in both histories, including missing evidence',{
  skip:process.env.RUN_BROWSER_TESTS!=='1',timeout:90000,
},async t=>{
  const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
  const browser=await chromium.launch({headless:true,args:['--no-sandbox']});t.after(()=>browser.close());
  const html=await fs.readFile(path.join(__dirname,'../admin-audit.html'));
  const images=await Promise.all(['red','blue'].map(background=>sharp({create:{width:80,height:60,channels:3,background}}).png().toBuffer()));
  for(const width of [1440,390])await t.test(String(width),async()=>{
    const context=await browser.newContext({viewport:{width,height:900}});const page=await context.newPage(),errors=[],requests=[];
    page.on('pageerror',error=>errors.push(error.message));
    const op='00000000-0000-4000-8000-000000000001',file='00000000-0000-4000-8000-000000000002';
    const root={id:op,status:'failed',action:'upload_file',media_type:'video',created_at:'2026-09-28T12:00:00Z',event_count:'10',sub_event_count:'9',
      operationMedia:[{id:file,operationId:op,mediaType:'video',available:true,url:`/api/admin/audit/operations/${op}/media/${file}`}],
      operationPreview:{eventId:'99',mediaType:'video',url:'/api/admin/audit/events/99/preview?size=thumb',fullUrl:'/api/admin/audit/events/99/preview?size=full'}};
    const outcomes=['passed','blocked','uncertain','failed','stopped','skipped',null];
    const rows=outcomes.map((outcome,i)=>presentAuditCheck({id:String(i+2),operation_id:op,kind:'provider_call_finished',status:'observed',
      created_at:'2026-09-28T12:00:01Z',sub_event_index:String(i+1),sub_event_total:'9',details:{checkType:'modesty',checkOutcome:outcome,
        frameIndex:i,frameTimestampMs:i*5000,...(i<2?{scanPreviewId:'00000000-0000-4000-8000-000000000003'}:{})}}));
    rows.push({id:'9',operation_id:op,kind:'upload_context',status:'completed',created_at:root.created_at,details:{}});
    rows.push(presentAuditCheck({id:'10',operation_id:op,kind:'moderation_check_finished',status:'completed',details:{checkType:'video_frames',checkOutcome:'passed'}}));
    rows.push({id:'11',operation_id:op,kind:'storage_upload_started',status:'running',details:{}});
    rows.push({id:'12',operation_id:op,kind:'scan_workflow_finished',status:'failed',details:{}});
    root.first_sub_event=rows.find(row=>row.id==='9');
    await page.addInitScript(()=>localStorage.setItem('bt_admin_token','mock-admin'));
    await page.route('**/*',async route=>{
      const url=new URL(route.request().url());
      if(url.hostname==='audit.test')return route.fulfill({contentType:'text/html',body:url.pathname.endsWith('.html')?html:''});
      assert.equal(route.request().headers().authorization,'Bearer mock-admin');requests.push(url);
      const preview=/\/events\/(2|3)\/preview$/.exec(url.pathname);
      if(preview)return route.fulfill({contentType:'image/png',body:images[Number(preview[1])-2]});
      assert.ok(!url.pathname.endsWith('/events/99/preview'),'must not fetch the first frame for another check');
      assert.ok(!url.pathname.includes('/media/'),'must not fetch the full video for a frame check');
      if(url.pathname.endsWith('/catalog'))return route.fulfill({json:{actions:[]}});
      if(url.pathname.endsWith('/column-order'))return route.fulfill({json:{orders:{},widths:{},formats:{}}});
      if(url.pathname.endsWith('/filter-options'))return route.fulfill({json:{options:[{value:'passed',label:CHECK_OUTCOME_LABELS.passed}],hasMore:false}});
      if(url.pathname.endsWith('/operations'))return route.fulfill({json:{operations:[root],nextCursor:null}});
      return route.fulfill({json:{events:rows.map(row=>({...row,operationMedia:root.operationMedia,operationPreview:root.operationPreview,
        operation_action:root.action,current_operation_status:root.status,operation_created_at:root.created_at})),nextCursor:null}});
    });
    await page.goto('https://audit.test/admin-audit.html');
    const settled=()=>page.waitForFunction(()=>state.hasLoaded&&!state.loading&&columnOrdersLoaded&&[...state.pages.values()].every(p=>!p.loading));
    await settled();
    assert.deepEqual(errors,[]);
    await page.locator('[data-operation-id] [data-field="operation_status"]').scrollIntoViewIfNeeded();
    assert.equal(await page.locator('[data-operation-id] [data-field="operation_status"]').getAttribute('data-status'),'completed');
    await page.screenshot({path:`/tmp/newone-scan-row/status-${width}.png`});
    await page.locator('[data-expand]').click();await settled();
    for(const mode of ['operations','events']){
      if(mode==='events'){await page.locator('#events-tab').click();await settled();}
      assert.match(await page.locator('th[data-column-id="operation_status"]').textContent(),/מצב הסריקה/);
      for(const [i,outcome]of outcomes.entries()){
        const row=page.locator(`[data-event-id="${i+2}"]`);
        assert.match(await row.locator('[data-field="operation_status"]').textContent(),new RegExp(CHECK_OUTCOME_LABELS[outcome||'not_recorded']));
        assert.equal(await row.locator('[data-audit-media]').count(),0);
        if(i>=2)assert.match(await row.locator('[data-field="preview"]').textContent(),/תמונת הבדיקה אינה זמינה/);
      }
      assert.equal(await page.locator('[data-event-id="9"] [data-audit-media]').count(),1);
      assert.equal(await page.locator('[data-event-id="10"] [data-audit-media]').count(),1);
      for(const [id,status,label]of [['9','completed','הושלם'],['11','running','בתהליך'],['12','failed','נכשל']]){
        const cell=page.locator(`[data-event-id="${id}"] [data-field="operation_status"]`);
        assert.equal(await cell.getAttribute('data-status'),status);
        assert.match(await cell.textContent(),new RegExp(label));
      }
      for(const id of ['2','3']){
        const preview=page.locator(`[data-event-id="${id}"] [data-check-preview="${id}"]`);
        await preview.scrollIntoViewIfNeeded();await preview.click();
        await page.waitForFunction(()=>{const image=document.querySelector('#preview-image');return !image.hidden&&image.complete&&image.naturalWidth>0;});
        const color=await page.locator('#preview-image').evaluate(image=>{const canvas=document.createElement('canvas');canvas.width=canvas.height=1;const c=canvas.getContext('2d');c.drawImage(image,0,0,1,1);return [...c.getImageData(0,0,1,1).data];});
        assert.deepEqual(color,id==='2'?[255,0,0,255]:[0,0,255,255]);
        assert.match(await page.locator('#preview-caption').textContent(),new RegExp(`תמונה ${Number(id)-1}`));
        await page.locator('#close-preview').click();
        await page.waitForFunction(()=>!document.querySelector('#preview-image').hasAttribute('src'));
      }
      await page.locator('[data-column-filter="scan_status"]').click();
      await page.waitForFunction(()=>columnPopup&&!columnPopup.loading);
      assert.equal(requests.findLast(url=>url.pathname.endsWith('/filter-options')).searchParams.get('column'),'scan_status');
      await page.keyboard.press('Escape');
    }
    assert.deepEqual(errors,[]);await context.close();
  });
});
