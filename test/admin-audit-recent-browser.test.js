'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs/promises'),path=require('node:path');
test('recent minutes defaults to ten, rolls forward and applies to tabs and export',{skip:process.env.RUN_BROWSER_TESTS!=='1',timeout:60000},async t=>{
 const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright'),browser=await chromium.launch({headless:true,args:['--no-sandbox']});t.after(()=>browser.close());
 const html=await fs.readFile(path.join(__dirname,'../admin-audit.html'));
 for(const width of [1440,390])await t.test(String(width),async()=>{
  const context=await browser.newContext({viewport:{width,height:900}}),page=await context.newPage(),queries=[],errors=[];
  page.on('pageerror',e=>errors.push(e.message));await page.addInitScript(()=>localStorage.setItem('bt_admin_token','fixture'));
  await page.route('**/*',route=>{
   const url=new URL(route.request().url()),name=url.pathname.split('/').pop();
   if(url.hostname==='audit.test')return route.fulfill({contentType:'text/html',body:url.pathname.endsWith('.html')?html:''});
   if(name==='catalog')return route.fulfill({json:{actions:[]}});
   if(name==='column-order')return route.fulfill({json:{orders:{},widths:{}}});
   if(['operations','events','export.csv'].includes(name)){
    queries.push({name,from:url.searchParams.get('from'),to:url.searchParams.get('to')});
    return route.fulfill(name==='export.csv'?{contentType:'text/csv',body:'id\n'}:{json:{[name]:[],nextCursor:null}});
   }
   throw Error('Unexpected request '+url.pathname);
  });
  await page.goto('https://audit.test/admin-audit.html');await page.waitForFunction(()=>state.hasLoaded&&!state.loading);
  assert.equal(await page.locator('#recent-minutes').inputValue(),'10');
  assert.equal(Date.parse(queries.at(-1).to)-Date.parse(queries.at(-1).from),600000);
  await page.locator('#recent-minutes').fill('30');await page.locator('#recent-window button').click();await page.waitForFunction(()=>!state.loading&&recentMinutes===30);
  assert.equal(Date.parse(queries.at(-1).to)-Date.parse(queries.at(-1).from),1800000);
  const previous=queries.at(-1).from;
  await page.evaluate(()=>{const original=Date.now;Date.now=()=>original()+60000;});
  await page.locator('#events-tab').click();await page.waitForFunction(()=>state.mode==='events'&&!state.loading);
  assert.equal(queries.at(-1).name,'events');assert.ok(Date.parse(queries.at(-1).from)-Date.parse(previous)>=60000);
  assert.equal(Date.parse(queries.at(-1).to)-Date.parse(queries.at(-1).from),1800000);
  await page.locator('#recent-minutes').fill('0');const count=queries.length;
  await page.locator('#recent-window button').click();assert.equal(queries.length,count);
  await page.locator('#recent-minutes').fill('30');await page.locator('#export').click();await page.waitForFunction(()=>!state.exporting);
  assert.equal(queries.at(-1).name,'export.csv');assert.equal(Date.parse(queries.at(-1).to)-Date.parse(queries.at(-1).from),1800000);
  await page.screenshot({path:`/tmp/audit-recent-${width}.png`});assert.deepEqual(errors,[]);await context.close();
 });
});
