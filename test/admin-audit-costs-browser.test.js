'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs/promises'),path=require('node:path');
test('token and shekel columns render one scalar, preserve totals when expanded, and filter decimal amounts',{skip:process.env.RUN_BROWSER_TESTS!=='1',timeout:60000},async t=>{
 const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright'),browser=await chromium.launch({headless:true,args:['--no-sandbox']});t.after(()=>browser.close());const html=await fs.readFile(path.join(__dirname,'../admin-audit.html'));
 for(const width of [1440,390])await t.test(String(width),async()=>{
 const context=await browser.newContext({viewport:{width,height:950},locale:'he-IL'}),page=await context.newPage(),errors=[],requests=[];page.on('pageerror',e=>errors.push(e.message));
 const usage={input_tokens:1000,output_tokens:200,total_tokens:1200,cached_input_tokens:600,cost_ils:0.000631,fx_rate:3.033,fx_date:'2026-09-25',model:'gpt-4.1-mini',status:'estimated',calls:1,basis:[{provider:'openai',model:'gpt-4.1-mini',inputUsdPerMillion:0.4,outputUsdPerMillion:1.6,snapshot:{cachedInputUsdPerMillion:0.1,fxRate:3.033,fxDate:'2026-09-25'}}]};
 const root={id:'00000000-0000-4000-8000-000000000001',action:'upload_file',media_type:'video',capture_kind:'camera_video',status:'completed',created_at:'2026-09-27T08:00:00Z',root_event_id:'1',event_count:'3',sub_event_count:'2',operation_usage:{...usage,total_tokens:2400,input_tokens:2000,output_tokens:400,cost_ils:0.001262,calls:2}};
 const a={id:'2',operation_id:root.id,kind:'provider_call_finished',status:'completed',created_at:root.created_at,sub_event_index:'1',sub_event_total:'2',operation_action:root.action,current_operation_status:root.status,usage,operation_usage:root.operation_usage};
 const b={...a,id:'3',sub_event_index:'2',usage:{...usage,cost_ils:null,total_tokens:null,status:'partial',missing_calls:1,known_cost_ils:0.0003,known_total_tokens:100}};root.first_sub_event=a;
 await page.addInitScript(()=>localStorage.setItem('bt_admin_token','mock-token'));await page.route('**/*',route=>{const u=new URL(route.request().url());if(u.hostname==='audit.test')return route.fulfill({contentType:'text/html',body:u.pathname.endsWith('.html')?html:''});requests.push(u);if(u.pathname.endsWith('/column-order'))return route.fulfill({json:{orders:{},widths:{}}});if(u.pathname.endsWith('/catalog'))return route.fulfill({json:{actions:[]}});if(u.pathname.endsWith('/operations')){assert.equal(u.searchParams.get('costs'),'1');return route.fulfill({json:{operations:[root],nextCursor:null}});}if(u.pathname.endsWith('/events'))return route.fulfill({json:{events:[a,b],nextCursor:null}});if(u.pathname.endsWith('/filter-options'))return route.fulfill({json:{options:[{value:'estimated',label:'אומדן מתועד'}]}});throw Error('Unexpected request');});
 await page.goto('https://audit.test/admin-audit.html');await page.waitForFunction(()=>state.hasLoaded&&!state.loading&&columnOrdersLoaded);
 assert.equal(await page.locator('[data-field="total_tokens"]').innerText(),'1,200');
 assert.equal(await page.locator('[data-field="operation_total_tokens"]').innerText(),'2,400');
 assert.equal(await page.locator('[data-field="operation_cost_ils"]').innerText(),'₪0.001262');
 await page.locator('[data-field="cost_ils"] [role="button"]').click();assert.match(await page.locator('#detail-json').innerText(),/3.033/);assert.match(await page.locator('#detail-json').innerText(),/0.4/);await page.keyboard.press('Escape');
 await page.locator('[data-expand]').click();await page.waitForFunction(()=>!Array.from(state.pages.values()).some(x=>x.loading));assert.equal(await page.locator('[data-field="operation_total_tokens"]').count(),2);assert.equal(await page.locator('[data-event-id="3"] [data-field="cost_ils"]').innerText(),'לא ידוע');assert.equal(await page.locator('[data-event-id="3"] [data-field="usage_status"]').innerText(),'חסר מידע');
 for(const mode of ['operations','events']){
 if(mode==='events'){await page.locator('#events-tab').click();await page.waitForFunction(()=>state.mode==='events'&&!state.loading);}
 await page.locator('[data-column-filter="cost_ils"]').click();await page.locator('#column-start').fill('0.0001');await page.locator('#column-end').fill('0.02');await page.locator('#column-apply').click();await page.waitForFunction(()=>!state.loading&&!columnPopup);assert.deepEqual(await page.evaluate(()=>state.columns[state.mode].cost_ils),{min:'0.0001',max:'0.02'});
 await page.locator('[data-column-sort="operation_cost_ils"]').click();await page.waitForFunction(()=>!state.loading);assert.equal(requests.findLast(u=>u.pathname.endsWith('/'+mode)).searchParams.get('sort'),'operation_cost_ils');
 }
 assert.deepEqual(errors,[]);await context.close();
 });
});
