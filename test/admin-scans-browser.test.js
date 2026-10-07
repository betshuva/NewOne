'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs/promises'),path=require('node:path');
test('scan manager shows users, date sorting, preview and explicit deletion',{skip:process.env.RUN_BROWSER_TESTS!=='1',timeout:60000},async t=>{
 const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright'),browser=await chromium.launch({headless:true,args:['--no-sandbox']});t.after(()=>browser.close());
 const html=await fs.readFile(path.join(__dirname,'../admin-scans.html'));
 for(const width of [1440,390])await t.test(String(width),async()=>{
  const context=await browser.newContext({viewport:{width,height:900}}),page=await context.newPage(),queries=[],mutations=[],errors=[];
  let deleted=false;page.on('pageerror',e=>errors.push(e.message));await page.addInitScript(()=>localStorage.setItem('bt_admin_token','fixture'));
  await page.route('**/*',route=>{
   const req=route.request(),url=new URL(req.url());
   if(url.pathname.endsWith('.html'))return route.fulfill({contentType:'text/html',body:html});
   if(url.pathname.endsWith('/filter-options'))return route.fulfill({json:{options:url.searchParams.get('column')==='user'?[{value:'user-fixture',label:'משתמש בדיקה · 42'}]:[{value:'approved',label:'אושרה'},{value:'rejected',label:'נחסמה'}],hasMore:false}});
   if(url.pathname.endsWith('/preview-ticket'))return route.fulfill({json:{url:'api/admin/scan-results/fixture/preview?ticket=fixture'}});
   if(url.pathname.endsWith('/preview'))return route.fulfill({contentType:'image/png',body:Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=','base64')});
   if(req.method()==='DELETE'){mutations.push(req.postDataJSON());deleted=true;return route.fulfill({json:{ok:true,affectedFiles:1}});}
   queries.push(Object.fromEntries(url.searchParams));return route.fulfill({json:{items:deleted?[]:[{id:'fixture',created_at:'2026-10-01T10:00:00Z',original_name:'תמונה.jpg',user_name:'משתמש בדיקה',user_number:42,file_type:'image',moderation_status:'rejected',reason:'תוצאת בדיקה',available:true,can_delete:true}],hasMore:false,page:1,canDelete:true}});
  });
  await page.goto('https://scan.test/admin-scans.html');await page.getByText('משתמש בדיקה · 42').waitFor();
  assert.equal(queries.at(-1).order,'desc');assert.match(await page.locator('#rows').innerText(),/תמונה.jpg/);
  await page.locator('#order').selectOption('asc');await page.locator('#filters button[type=submit]').click();await page.waitForFunction(()=>document.querySelector('#message').textContent==='1 רשומות בעמוד');
  assert.equal(queries.at(-1).order,'asc');
  await page.locator('[data-sort="name"]').click();await page.waitForFunction(()=>document.querySelector('#message').textContent==='1 רשומות בעמוד');assert.equal(queries.at(-1).sort,'name');assert.equal(queries.at(-1).order,'asc');
  await page.locator('[data-sort="name"]').click();await page.waitForFunction(()=>document.querySelector('#message').textContent==='1 רשומות בעמוד');assert.equal(queries.at(-1).order,'desc');
  await page.locator('[data-column-filter="status"]').click();await page.locator('#column-options input').first().waitFor();await page.locator('#column-all').uncheck();await page.locator('#column-options label').filter({hasText:'נחסמה'}).locator('input').check();await page.locator('#column-apply').click();
  await page.waitForFunction(()=>document.querySelector('#message').textContent==='1 רשומות בעמוד');assert.deepEqual(JSON.parse(queries.at(-1).columnFilters).status,{exclude:false,values:['rejected']});
  assert.equal(await page.locator('[data-column-filter="status"]').getAttribute('class'),'column-filter active');
  await page.locator('[data-column-filter="user"]').click();await page.locator('#column-options input').first().waitFor();await page.locator('#column-all').uncheck();await page.locator('#column-options input').check();await page.locator('#column-apply').click();
  await page.waitForFunction(()=>document.querySelector('#message').textContent==='1 רשומות בעמוד');assert.equal(Object.keys(JSON.parse(queries.at(-1).columnFilters)).length,2);
  await page.locator('[data-column-filter="date"]').click();await page.locator('#column-from').fill('2026-10-01T12:00');await page.locator('#column-to').fill('2026-09-01T12:00');const beforeInvalid=queries.length;await page.locator('#column-apply').click();assert.equal(queries.length,beforeInvalid);assert.match(await page.locator('#column-error').innerText(),/אחרי/);
  await page.locator('#column-to').fill('2026-10-02T12:00');await page.locator('#column-apply').click();await page.waitForFunction(()=>document.querySelector('#message').textContent==='1 רשומות בעמוד');assert.ok(JSON.parse(queries.at(-1).columnFilters).date.from);
  await page.locator('[data-column-filter="status"]').click();await page.locator('#column-clear').click();await page.waitForFunction(()=>document.querySelector('#message').textContent==='1 רשומות בעמוד');assert.equal(JSON.parse(queries.at(-1).columnFilters).status,undefined);assert.ok(JSON.parse(queries.at(-1).columnFilters).user);
  await page.locator('[data-column-filter="name"]').click();await page.locator('#column-cancel').click();
  await page.locator('#clear-columns').click();await page.waitForFunction(()=>document.querySelector('#message').textContent==='1 רשומות בעמוד');assert.equal(queries.at(-1).columnFilters,undefined);assert.equal(await page.locator('#clear-columns').isVisible(),false);
  await page.getByRole('button',{name:'הצג תמונה',exact:true}).click();await page.locator('#media img').waitFor();assert.equal(await page.locator('#file-title').innerText(),'תמונה.jpg');await page.locator('#preview-close').click();
  await page.getByRole('button',{name:'מחק סריקה קודמת',exact:true}).click();await page.locator('#delete-cancel').click();assert.equal(mutations.length,0);
  await page.getByRole('button',{name:'מחק סריקה קודמת',exact:true}).click();await page.locator('#delete-confirm').click();await page.getByText('הסריקה השמורה נמחקה. הקובץ וההודעות נשארו. לא הופעלה סריקה חדשה.').waitFor();
  assert.deepEqual(mutations,[{confirm:'DELETE_SCAN_CACHE'}]);assert.equal(await page.locator('#rows tr[data-id]').count(),0);assert.deepEqual(errors,[]);await context.close();
 });
});
