'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs/promises'),path=require('node:path');
test('audit explains actual changes, missing history and HTTP outcomes safely on desktop and mobile',{skip:process.env.RUN_BROWSER_TESTS!=='1',timeout:60000},async t=>{
 const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright'),browser=await chromium.launch({headless:true,args:['--no-sandbox']});t.after(()=>browser.close());
 const html=await fs.readFile(path.join(__dirname,'../admin-audit.html'));
 for(const width of [1440,390])await t.test(String(width),async()=>{
  const context=await browser.newContext({viewport:{width,height:950},locale:'he-IL'}),page=await context.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
  const root={id:'00000000-0000-4000-8000-000000000001',action:'filter_change',created_at:'2026-09-27T08:00:00Z',root_event_id:'1',event_count:'3',sub_event_count:'2',status:'completed'};
  const events=[{id:'2',operation_id:root.id,kind:'filter_changed',target_type:'general',status:'completed',created_at:root.created_at,sub_event_index:'1',sub_event_total:'2',details:{beforeWomen:true,afterWomen:false,beforeMen:false,afterMen:false,afterChildren:true,beforeEnforceGeneralFilter:false,afterEnforceGeneralFilter:true}},{id:'3',operation_id:root.id,kind:'http_response',status:'completed',reason_code:'http_200',created_at:root.created_at,sub_event_index:'2',sub_event_total:'2'}];root.first_sub_event=events[0];
  await page.addInitScript(()=>localStorage.setItem('bt_admin_token','mock-token'));
  await page.route('**/*',async route=>{
   const url=new URL(route.request().url());
   if(url.hostname==='audit.test')return route.fulfill({contentType:'text/html',body:url.pathname.endsWith('.html')?html:''});
   if(url.pathname.endsWith('/column-order'))return route.fulfill({json:{orders:{operations:['expand','created_at','action','kind','status']},widths:{operations:{action:280}}}});
   if(url.pathname.endsWith('/catalog'))return route.fulfill({json:{actions:[{action:'filter_change',label:'שינוי סינון'},{action:'filter_changed',label:'שינוי סינון'}]}});
   if(url.pathname.endsWith('/operations'))return route.fulfill({json:{operations:[root],nextCursor:null}});
   if(url.pathname.endsWith('/events'))return route.fulfill({json:{events,nextCursor:null}});
   throw new Error(`Unexpected request ${url.pathname}`);
  });
  await page.goto('https://audit.test/admin-audit.html');await page.waitForFunction(()=>state.hasLoaded&&!state.loading&&columnOrdersLoaded);
  const first=page.locator('[data-event-id="2"]');
  for(const [key,value] of Object.entries({change_context:'הגדרות סינון',target_type:'סינון כללי',beforeWomen:'מותר',afterWomen:'חסום',beforeChildren:'-',afterChildren:'מותר',afterEnforceGeneralFilter:'פעילה',event_explanation:'עדכון הגדרות הסינון'}))assert.equal(await first.locator(`[data-field="${key}"]`).innerText(),value);
  const headers=await page.locator('thead th').evaluateAll(nodes=>nodes.map(n=>n.dataset.columnId));assert.equal(new Set(headers).size,headers.length);
  assert.deepEqual(headers.filter(k=>['expand','created_at','action','kind','status'].includes(k)),['expand','created_at','action','kind','status']);
  assert.equal(await page.locator('[data-column-id="action"] .column-resize').getAttribute('aria-valuenow'),'280');
  await first.locator('[data-expand]').click();await page.waitForFunction(()=>[...state.pages.values()].every(p=>!p.loading));
  const response=page.locator('[data-event-id="3"]');assert.equal(await response.locator('[data-field="http_status"]').innerText(),'200');assert.equal(await response.locator('[data-field="step_reason"]').innerText(),'השרת השיב בהצלחה');
  assert.equal(await first.evaluate(n=>n.style.getPropertyValue('--group-color')),await response.evaluate(n=>n.style.getPropertyValue('--group-color')));
  await page.screenshot({path:`/tmp/audit-explanation-${width}.png`});
  await first.locator('[data-expand]').click();assert.equal(await page.locator('tbody tr').count(),1);
  await page.locator('#events-tab').click();await page.waitForFunction(()=>state.mode==='events'&&!state.loading);assert.equal(await page.locator('[data-field="before_value"]').count(),2);
  const evidence=await page.evaluate(()=>{
   const text=(key,row)=>singleFieldCell(key,row,{}).textContent;
   return {missing:text('beforeWomen',{kind:'filter_changed'}),unknown:text('event_explanation',{kind:'http_connection_closed'}),failed:text('step_reason',{kind:'http_response',reason_code:'http_500'}),safe:text('target_id',{target_id:'<img src=x onerror=alert(1)>'}),equal:text('beforeWomen',{details:{beforeWomen:false,afterWomen:false}})};
  });
  assert.equal(evidence.missing,'-');assert.match(evidence.unknown,/החיבור לשרת נסגר/);assert.equal(evidence.failed,'שגיאה בשרת');assert.match(evidence.safe,/<img/);assert.equal(await page.locator('td img[src="x"]').count(),0);assert.equal(evidence.equal,'חסום');
  assert.deepEqual(errors,[]);await context.close();
 });
});
