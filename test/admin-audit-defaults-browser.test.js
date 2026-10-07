'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs/promises'),path=require('node:path');
test('server action defaults precede data loading, initialize both tabs, and remain clearable across refreshes',
 {skip:process.env.RUN_BROWSER_TESTS!=='1',timeout:60000},async t=>{
 const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
 const browser=await chromium.launch({headless:true,args:['--no-sandbox']});t.after(()=>browser.close());
 const page=await browser.newPage(),html=await fs.readFile(path.join(__dirname,'../admin-audit.html'));
 const defaults={display_action:{values:['media:video','media:image'],exclude:false}},queries=[],errors=[];
 let catalogCalls=0;
 page.on('pageerror',error=>errors.push(error.message));
 await page.addInitScript(()=>localStorage.setItem('bt_admin_token','fixture'));
 await page.route('**/*',async route=>{
  const url=new URL(route.request().url()),name=url.pathname.split('/').pop();
  if(url.hostname==='audit.test')return route.fulfill({contentType:'text/html',body:url.pathname.endsWith('.html')?html:''});
  if(name==='catalog'){
   if(++catalogCalls===1)return route.fulfill({status:503,json:{error:'temporarily unavailable'}});
   return route.fulfill({json:{actions:[],defaultColumnFilters:defaults}});
  }
  if(name==='column-order')return route.fulfill({json:{orders:{},widths:{}}});
  if(['operations','events'].includes(name)){
   queries.push({name,columns:JSON.parse(url.searchParams.get('columnFilters')||'{}')});
   return route.fulfill({json:{[name]:[],nextCursor:null}});
  }
  throw Error('Unexpected request '+url.pathname);
 });
 await page.goto('https://audit.test/admin-audit.html');
 await page.locator('#catalog-error button').waitFor();
 assert.equal(queries.length,0,'no unfiltered data request while server defaults are unavailable');
 await page.locator('#catalog-error button').click();
 await page.waitForFunction(()=>state.hasLoaded&&!state.loading);
 assert.deepEqual(queries[0],{name:'operations',columns:defaults});
 assert.ok(await page.locator('#clear-columns').isVisible());
 await page.locator('#events-tab').click();
 await page.waitForFunction(()=>state.mode==='events'&&!state.loading);
 assert.deepEqual(queries.at(-1),{name:'events',columns:defaults});
 await page.locator('#clear-columns').click();await page.waitForFunction(()=>!state.loading);
 assert.deepEqual(queries.at(-1).columns,{});
 await page.locator('#refresh').click();await page.waitForFunction(()=>!state.loading&&!catalogPromise);
 assert.deepEqual(queries.at(-1).columns,{});
 assert.equal(await page.locator('#clear-columns').isVisible(),false);
 await page.locator('#operations-tab').click();await page.waitForFunction(()=>state.mode==='operations'&&!state.loading);
 assert.deepEqual(queries.at(-1).columns,defaults,'clearing one view does not change the other');
 await page.reload();await page.waitForFunction(()=>state.hasLoaded&&!state.loading);
 assert.deepEqual(queries.at(-1).columns,defaults);
 assert.deepEqual(errors,[]);
});
