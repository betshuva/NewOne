'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

test('report screen renders hostile text safely and handles edit permissions and stale updates',{
  skip:!process.env.PLAYWRIGHT_MODULE,
},async()=>{
  const {chromium}=require(process.env.PLAYWRIGHT_MODULE);
  const browser=await chromium.launch({headless:true,args:['--no-sandbox']});
  try{
    const page=await browser.newPage();const errors=[];page.on('pageerror',e=>errors.push(e.message));
    const html=fs.readFileSync(require.resolve('../admin-reports.html'),'utf8');
    const attack='<img src=x onerror="window.injected=true">';
    const report={id:'11111111-1111-4111-8111-111111111111',target_id:'target',reporter_id:'reporter',
      target_type:'message',reason:'harassment',details:attack,target_summary:attack,reporter_name:attack,
      target_available:true,status:'pending',revision:'123',notification_version:1,notified_version:1};
    let permission='view',conflict=true,saved=[];const offsets=[];
    await page.route('**/*',async route=>{
      const request=route.request(),url=new URL(request.url());
      if(url.pathname==='/admin-reports.html')return route.fulfill({contentType:'text/html',body:html});
      if(url.pathname==='/api/admin/db')return route.fulfill({json:{permission}});
      if(url.pathname==='/api/admin/reports'&&request.method()==='GET'){
        offsets.push(url.searchParams.get('offset'));
        return route.fulfill({json:[report],headers:{'X-Has-More':'true'}});
      }
      if(url.pathname.startsWith('/api/admin/reports/')&&request.method()==='PUT'){
        saved.push(request.postDataJSON());
        if(conflict)return route.fulfill({status:409,json:{error:'הדיווח השתנה; יש לרענן'}});
        report.status=request.postDataJSON().status;report.revision='124';
        return route.fulfill({json:report});
      }
      assert.fail('Unexpected network request: '+url.pathname);
    });
    await page.addInitScript(()=>localStorage.setItem('bt_admin_token','synthetic-token'));
    await page.goto('https://reports.test/admin-reports.html');
    await page.locator('.report').waitFor();
    assert.equal(await page.locator('.actions button').isDisabled(),true);
    assert.equal(await page.locator('.report img').count(),0);
    assert.equal(await page.locator('.summary').textContent(),attack);
    permission='edit';await page.locator('#refresh').click();
    await page.waitForFunction(()=>!document.querySelector('.actions button').disabled);
    await page.locator('.actions select').selectOption('resolved');
    await page.locator('.actions button').click();
    await page.locator('.result.error').waitFor();
    assert.equal(await page.locator('h2').textContent(),'הודעה · ממתין לבדיקה');
    assert.deepEqual(saved,[{status:'resolved',revision:'123'}]);
    conflict=false;await page.locator('.actions button').click();
    await page.waitForFunction(()=>document.querySelector('h2').textContent==='הודעה · טופל');
    await page.locator('#next').click();await page.waitForFunction(()=>document.querySelector('#page').textContent==='עמוד 2'&&!document.querySelector('#refresh').disabled);
    assert.ok(offsets.includes('100'));
    await page.locator('#status').selectOption('all');
    await page.waitForFunction(()=>document.querySelector('#page').textContent==='עמוד 1'&&!document.querySelector('#refresh').disabled);
    await page.setViewportSize({width:390,height:844});
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
    assert.equal(await page.evaluate(()=>window.injected),undefined);assert.deepEqual(errors,[]);
    if(process.env.REPORT_SCREENSHOT)await page.screenshot({path:process.env.REPORT_SCREENSHOT,fullPage:true});
  }finally{await browser.close();}
});
