"use strict";
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs/promises'),path=require('node:path');
test('dispatch columns show independent send/delivery evidence, safe content and per-recipient reasons',{skip:process.env.RUN_BROWSER_TESTS!=='1',timeout:60000},async t=>{
 const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright'),browser=await chromium.launch({headless:true,args:['--no-sandbox']});t.after(()=>browser.close());const html=await fs.readFile(path.join(__dirname,'../admin-audit.html'));
 for(const width of [1440,390])await t.test(String(width),async()=>{
 const context=await browser.newContext({viewport:{width,height:950},locale:'he-IL'}),page=await context.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
 const body='<img src=x onerror="window.injected=true">'+ 'תוכן מלא '.repeat(30),dispatch={dispatch_state:'partial',dispatch_delivery:'unconfirmed',dispatch_sent_count:2,dispatch_failed_count:1,dispatch_reason:'סרטונים חסומים',dispatch_code:'recipient_content_filter',dispatch_message_type:'video',dispatch_file_name:'צילום.webm',dispatch_content:body.slice(0,160),message_body:body,recipients:{deliveredTo:[{name:'דני'}],blockedFor:[{name:'רחל',reason:'סרטונים חסומים',reasonCode:'recipient_content_filter'}]}};
 const root={id:'00000000-0000-4000-8000-000000000001',action:'send_group_message',status:'completed',recipient_name:'קבוצת בדיקה',created_at:'2026-09-27T08:00:00Z',root_event_id:'1',event_count:'2',sub_event_count:'1',dispatch};
 const child={id:'2',operation_id:root.id,kind:'http_response',status:'completed',reason_code:'http_200',created_at:root.created_at,sub_event_index:'1',sub_event_total:'1',operation_action:root.action,current_operation_status:root.status,recipient_name:root.recipient_name,dispatch};root.first_sub_event=child;
 await page.addInitScript(()=>localStorage.setItem('bt_admin_token','mock-token'));await page.route('**/*',route=>{const u=new URL(route.request().url());if(u.hostname==='audit.test')return route.fulfill({contentType:'text/html',body:u.pathname.endsWith('.html')?html:''});if(u.pathname.endsWith('/column-order'))return route.fulfill({json:{orders:{},widths:{}}});if(u.pathname.endsWith('/catalog'))return route.fulfill({json:{actions:[]}});if(u.pathname.endsWith('/filter-options'))return route.fulfill({json:{options:[{value:'partial',label:'נשלח לחלק מהנמענים'}]}});if(u.pathname.endsWith('/operations')){assert.equal(u.searchParams.get('dispatch'),'1');return route.fulfill({json:{operations:[root],nextCursor:null}});}if(u.pathname.endsWith('/events'))return route.fulfill({json:{events:[child],nextCursor:null}});throw Error('Unexpected request');});
 await page.goto('https://audit.test/admin-audit.html');await page.waitForFunction(()=>state.hasLoaded&&!state.loading&&columnOrdersLoaded);
 for(const mode of ['operations','events']){
 if(mode==='events'){await page.locator('#events-tab').click();await page.waitForFunction(()=>state.mode==='events'&&!state.loading);}
 for(const [field,value]of Object.entries({dispatch_state:'נשלח לחלק מהנמענים',dispatch_delivery:'אין אישור מסירה מהמכשיר',dispatch_sent_count:'2',dispatch_failed_count:'1',dispatch_reason:'סרטונים חסומים',dispatch_file_name:'צילום.webm'}))assert.equal(await page.locator(`[data-field="${field}"]`).innerText(),value);
 assert.equal(await page.locator('[data-field="dispatch_content"] img').count(),0);assert.equal(await page.evaluate(()=>window.injected),undefined);
 await page.locator('[data-field="dispatch_content"] button').click();assert.equal(await page.locator('#detail-json').innerText(),body);await page.keyboard.press('Escape');
 await page.locator('[data-field="dispatch_recipients"] button').click();assert.match(await page.locator('#detail-json').innerText(),/רחל: לא נשלח — נחסם — סרטונים חסומים/);await page.keyboard.press('Escape');
 await page.locator('[data-column-filter="dispatch_state"]').click();await page.waitForFunction(()=>columnPopup&&!columnPopup.loading);assert.ok(await page.locator('[data-option-value="partial"]').count());await page.keyboard.press('Escape');
 }
 assert.deepEqual(errors,[]);await context.close();
 });
});
