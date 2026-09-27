'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs/promises');
const path=require('node:path');
const {COLUMN_IDS}=require('../server/audit-column-order');

test('column dragging keeps cells aligned and restores account order in a fresh browser',{
  skip:process.env.RUN_BROWSER_TESTS!=='1',timeout:60000,
},async t=>{
  const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
  const browser=await chromium.launch({headless:true,args:['--no-sandbox']});
  t.after(()=>browser.close());
  const html=await fs.readFile(path.join(__dirname,'../admin-audit.html'));
  const root={id:'00000000-0000-4000-8000-000000000001',created_at:'2026-09-25T08:00:00Z',
    action:'upload_file',status:'completed',root_event_id:'1',event_count:'2',source:'http'};
  const child={id:'2',operation_id:root.id,created_at:'2026-09-25T08:00:01Z',kind:'scan_queued',status:'pending'};
  Object.assign(child,{sub_event_index:'1',sub_event_total:'1'});root.first_sub_event=child;
  for(const mobile of [false,true])await t.test(mobile?'touch':'mouse',async()=>{
    const orders={},widths={},errors=[];let failSave=false,holdSave=null;
    async function open(){
      const context=await browser.newContext({viewport:{width:mobile?390:1440,height:900},isMobile:mobile,hasTouch:mobile});
      const page=await context.newPage();page.on('pageerror',error=>errors.push(error.message));
      await page.addInitScript(()=>localStorage.setItem('bt_admin_token','mock-only-token'));
      await page.route('**/*',async route=>{
        const url=new URL(route.request().url()),pathname=url.pathname;
        if(url.hostname==='audit.test')return route.fulfill({contentType:'text/html',body:pathname.endsWith('.html')?html:''});
        assert.equal(route.request().headers().authorization,'Bearer mock-only-token');
        if(pathname.endsWith('/column-order'))return route.fulfill({json:{orders,widths}});
        if(pathname.includes('/column-widths/')){
          assert.equal(route.request().method(),'PUT');
          if(failSave)return route.fulfill({status:503,json:{error:'Unavailable'}});
          if(holdSave)await holdSave;
          const mode=pathname.split('/').at(-1);widths[mode]=route.request().postDataJSON().widths;
          return route.fulfill({json:{mode,widths:widths[mode]}});
        }
        if(pathname.includes('/column-order/')){
          assert.equal(route.request().method(),'PUT');
          if(failSave)return route.fulfill({status:503,json:{error:'Unavailable'}});
          if(holdSave)await holdSave;
          const mode=pathname.split('/').at(-1);orders[mode]=route.request().postDataJSON().order;
          return route.fulfill({json:{mode,order:orders[mode]}});
        }
        if(pathname.endsWith('/catalog'))return route.fulfill({json:{actions:[],statuses:[],categories:[]}});
        if(pathname.endsWith('/operations'))return route.fulfill({json:{operations:[root],nextCursor:null}});
        if(pathname.endsWith('/filter-options'))return route.fulfill({json:{options:[],hasMore:false}});
        if(pathname.endsWith('/events'))return route.fulfill({json:{events:[child],nextCursor:null}});
        throw new Error(`Unexpected request ${pathname}`);
      });
      await page.goto('https://audit.test/admin-audit.html');
      await page.waitForFunction(()=>columnOrdersLoaded&&!state.loading);
      return {context,page};
    }
    let {context,page}=await open();
    const ids=()=>page.locator('thead th').evaluateAll(nodes=>nodes.map(node=>node.dataset.columnId));
    const saved=()=>page.waitForFunction(()=>!columnOrdersSaving&&!pendingColumnOrders.size);
    await page.locator('[data-expand]').click();await page.locator('.child-row').waitFor();await page.waitForFunction(()=>[...state.pages.values()].every(page=>!page.loading));
    const snapshot=await page.locator('#audit-table tr').evaluateAll(rows=>rows.map(row=>[...row.cells].map(cell=>cell.textContent)));
    const initialWidths=await page.locator('col').evaluateAll(nodes=>nodes.map(node=>node.style.width));
    const from=await page.locator('th[data-column-id="created_at"]').boundingBox();
    const to=await page.locator('th[data-column-id="action"]').boundingBox();
    const start={x:from.x+from.width-22,y:from.y+from.height/2},end={x:Math.max(20,to.x+12),y:start.y};
    if(mobile){
      const cdp=await context.newCDPSession(page);
      await cdp.send('Input.dispatchTouchEvent',{type:'touchStart',touchPoints:[start]});
      for(let i=1;i<=12;i++){
        await cdp.send('Input.dispatchTouchEvent',{type:'touchMove',touchPoints:[{x:start.x+(end.x-start.x)*i/12,y:end.y}]});
        await page.waitForTimeout(20);
      }
      await cdp.send('Input.dispatchTouchEvent',{type:'touchEnd',touchPoints:[]});
    }else{
      await page.mouse.move(start.x,start.y);await page.mouse.down();await page.mouse.move(end.x,end.y,{steps:12});
      await page.waitForTimeout(60);await page.mouse.up();
    }
    await saved();
    const moved=COLUMN_IDS.operations.slice();moved.splice(1,1);moved.splice(2,0,'created_at');
    assert.deepEqual(await ids(),moved);assert.deepEqual(orders.operations,moved);
    const indices=moved.map(key=>COLUMN_IDS.operations.indexOf(key));
    assert.deepEqual(await page.locator('#audit-table tr').evaluateAll(rows=>rows.map(row=>[...row.cells].map(cell=>cell.textContent))),
      snapshot.map(row=>indices.map(index=>row[index])));
    assert.deepEqual(await page.locator('col').evaluateAll(nodes=>nodes.map(node=>node.style.width)),indices.map(index=>initialWidths[index]));
    await page.evaluate(()=>render());assert.deepEqual(await ids(),moved);
    // Sorting and filtering still address the field that moved.
    await page.locator('[data-column-filter="created_at"]').click();await page.locator('#column-dialog[open]').waitFor();
    await page.locator('#column-cancel').click();
    const sorting=page.waitForRequest(request=>request.url().includes('/operations?')&&request.url().includes('sort=created_at'));
    await page.locator('[data-column-sort="created_at"]').click();await sorting;
    await page.waitForFunction(()=>!state.loading);assert.deepEqual(await ids(),moved);
    await page.locator('#events-tab').click();await page.waitForFunction(()=>!state.loading);
    assert.deepEqual(await ids(),COLUMN_IDS.events);
    const time=page.locator('th[data-column-id="created_at"]');await time.focus();await time.press('Alt+ArrowLeft');await saved();
    assert.deepEqual((await ids()).slice(0,3),['select','action','created_at']);
    // Width follows the column identity after reordering and is scoped to its view.
    const widthSaved=()=>page.waitForFunction(()=>!columnWidthsSaving&&!pendingColumnWidths.size);
    const resize=page.locator('th[data-column-id="created_at"] .column-resize');
    await resize.scrollIntoViewIfNeeded();
    const resizeBox=await resize.boundingBox(),resizeStart={x:resizeBox.x+resizeBox.width/2,y:resizeBox.y+resizeBox.height/2};
    if(mobile){
      const cdp=await context.newCDPSession(page);
      await cdp.send('Input.dispatchTouchEvent',{type:'touchStart',touchPoints:[resizeStart]});
      await cdp.send('Input.dispatchTouchEvent',{type:'touchMove',touchPoints:[{x:resizeStart.x-60,y:resizeStart.y}]});
      await cdp.send('Input.dispatchTouchEvent',{type:'touchEnd',touchPoints:[]});
    }else{
      await page.mouse.move(resizeStart.x,resizeStart.y);await page.mouse.down();
      await page.mouse.move(resizeStart.x-60,resizeStart.y,{steps:6});await page.mouse.up();
    }
    await widthSaved();assert.equal(widths.events.created_at,240);
    assert.deepEqual((await ids()).slice(0,3),['select','action','created_at']);
    assert.ok(Math.abs((await page.locator('th[data-column-id="created_at"]').boundingBox()).width-240)<2);
    await page.evaluate(()=>render());assert.equal(await resize.getAttribute('aria-valuenow'),'240');
    await resize.focus();await resize.press('ArrowLeft');await widthSaved();assert.equal(widths.events.created_at,250);
    // Cancel returns to the last committed width without changing persistence.
    const box=await resize.boundingBox();await page.mouse.move(box.x+5,box.y+10);await page.mouse.down();
    await page.mouse.move(box.x-25,box.y+10);await page.keyboard.press('Escape');await page.mouse.up();
    assert.equal(await resize.getAttribute('aria-valuenow'),'250');assert.equal(widths.events.created_at,250);
    await context.close();({context,page}=await open());
    assert.equal(await page.locator('th[data-column-id="created_at"] .column-resize').getAttribute('aria-valuenow'),'180');
    assert.deepEqual(await ids(),moved);
    await page.locator('#events-tab').click();await page.waitForFunction(()=>!state.loading);
    assert.deepEqual((await ids()).slice(0,3),['select','action','created_at']);
    assert.equal(await page.locator('th[data-column-id="created_at"] .column-resize').getAttribute('aria-valuenow'),'250');
    failSave=true;await page.locator('#reset-column-widths').click();await page.locator('#retry-column-widths:visible').waitFor();
    assert.match(await page.locator('#column-width-status').innerText(),/לא נשמר/);
    failSave=false;await page.locator('#retry-column-widths').click();await widthSaved();assert.deepEqual(widths.events,{});
    // Rapid keyboard adjustments during a slow save persist the final width.
    let releaseWidth;holdSave=new Promise(resolve=>{releaseWidth=resolve;});
    const widthHandle=page.locator('th[data-column-id="created_at"] .column-resize');
    await widthHandle.focus();await widthHandle.press('ArrowLeft');await widthHandle.press('ArrowLeft');
    holdSave=null;releaseWidth();await widthSaved();assert.equal(widths.events.created_at,200);
    failSave=true;await page.locator('#reset-column-order').click();await page.locator('#retry-column-order:visible').waitFor();
    assert.match(await page.locator('#column-order-status').innerText(),/לא נשמר/);
    failSave=false;await page.locator('#retry-column-order').click();await saved();assert.deepEqual(orders.events,COLUMN_IDS.events);
    // A second move made during a slow save must be the final server value.
    let release;holdSave=new Promise(resolve=>{release=resolve;});
    await page.locator('th[data-column-id="created_at"]').focus();await page.keyboard.press('Alt+ArrowLeft');
    await page.keyboard.press('Alt+ArrowLeft');const latest=await ids();holdSave=null;release();await saved();
    assert.deepEqual(orders.events,latest);
    assert.deepEqual(await page.evaluate(()=>Object.keys(localStorage)),['bt_admin_token']);
    assert.deepEqual(errors,[]);await context.close();
  });
});
