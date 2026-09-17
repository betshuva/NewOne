const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const html = fs.readFileSync(path.join(__dirname, '..', 'admin.html'), 'utf8');
const start = html.indexOf('// ── Filter audit timeline');
const end = html.indexOf('// ── End filter audit timeline', start);
const code = html.slice(start, end);
const escapeCode = html.match(/function escHtml\(s\) \{[\s\S]*?\n\}/)[0];

function context(fetch) {
  const elements = new Map();
  function element(id) {
    if (!elements.has(id)) elements.set(id, {
      value:'', innerHTML:'', textContent:'', hidden:false, disabled:false, scrollTop:0,
      style:{}, classList:{add(){},remove(){}},
    });
    return elements.get(id);
  }
  const document = {getElementById:element, querySelectorAll:() => []};
  const ctx = vm.createContext({
    document, fetch, API:'https://admin.invalid', token:'test-only-token', actTimer:null,
    clearInterval(){}, URLSearchParams, AbortController,
  });
  vm.runInContext(escapeCode + '\n' + code, ctx);
  return {ctx,element,run:source => vm.runInContext(source,ctx)};
}

function response(data, ok = true) {
  return {ok,json:async () => data};
}

function event(id, kind = 'filter_changed', details = {}) {
  return {id:String(id),kind,created_at:'2026-09-17T00:31:54.796Z',
    user_id:'viewer-id',user_name:'אביב',scope_type:'general',details};
}

test('all embedded admin scripts parse', () => {
  for (const script of html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)) {
    if (script[1].trim()) new vm.Script(script[1]);
  }
});

test('audit event rendering escapes stored fields and preserves baseline uncertainty', () => {
  const {ctx} = context();
  const output = ctx.renderFilterTimelineEvent({
    ...event(1,'filter_baseline',{before:{men:true},after:{men:false},note:'<script>bad()</script>'}),
    user_name:'<img src=x onerror=bad()>',actor_name:'" onclick="bad()',
    message_id:'<iframe>',created_at:'" onmouseover="bad()',
  });
  assert.doesNotMatch(output, /<img|<script|<iframe/);
  assert.match(output, /&lt;img/);
  assert.match(output, /&quot; onmouseover=&quot;/);
  assert.match(output, /אין באירוע זה מידע על מועד שינוי ההגדרות בעבר/);
  assert.match(output, /גברים: מותר ← <strong>חסום/);
});

test('browser reports, server persistence and allowance have distinct meanings', () => {
  const {ctx} = context();
  assert.match(ctx.renderFilterTimelineEvent(event(1,'client_displayed')), /זמן המכשיר.*אינו זמן מאומת/);
  assert.match(ctx.renderFilterTimelineEvent(event(2,'delivery_persisted')), /אינו מעיד שהגיעה למכשיר או הוצגה/);
  assert.match(ctx.renderFilterTimelineEvent(event(3,'decision_allowed')), /אינה הוכחה למסירה או לתצוגה/);
  const action = ctx.renderFilterTimelineEvent(event(4,'history_action',{action:'delete',count:3}));
  assert.match(action, /מחיקה עבור המשתמש/);
  assert.match(action, /3 תמונות/);
  const persisted = ctx.renderFilterTimelineEvent(event(5,'delivery_persisted',{policy:{men:false},classification:{detectedCategories:['men']}}));
  assert.match(persisted, /גברים: <strong>חסום/);
  assert.match(persisted, /סיווג: גברים/);
  assert.match(ctx.renderFilterTimelineEvent(event(6,'history_image_action',{action:'hide'})), /הבחירה הוחלה על תמונה קיימת/);
  const cleanup = ctx.renderFilterTimelineEvent(event(7,'history_cleanup',{action:'delete',affectedCount:4,deletedPersonalFiles:2,retainedSharedFiles:1,failedFiles:1}));
  assert.match(cleanup, /ניקוי קבצים לאחר מחיקה מההיסטוריה/);
  assert.match(cleanup, /תמונות שנמחקו מההיסטוריה: <strong>4/);
  assert.match(cleanup, /קבצים אישיים שנוקו: <strong>2/);
  assert.match(cleanup, /קבצים שניקוים נכשל: <strong>1/);
  assert.match(cleanup, /כשל בניקוי קובץ אינו מבטל את המחיקה עבור המשתמש/);
});

test('cursor pagination keeps applied filters and deduplicates events', async () => {
  const requests = [];
  const batches = [
    {events:[event(9),event(8)],nextCursor:'8',recordingStartedAt:'2026-09-17T00:00:00Z'},
    {events:[event(8),event(7)],nextCursor:null},
  ];
  const {ctx,element,run} = context(async (url,options) => {
    requests.push({url,options}); return response(batches.shift());
  });
  element('filter-timeline-user').value = 'viewer-id';
  element('filter-timeline-message').value = ' message-id ';
  await ctx.loadFilterTimeline();
  assert.equal(element('filter-timeline-more').hidden,false);
  element('filter-timeline-message').value = 'not-applied-yet';
  await ctx.loadFilterTimeline(true);
  const query = new URL(requests[1].url).searchParams;
  assert.equal(query.get('before'),'8');
  assert.equal(query.get('userId'),'viewer-id');
  assert.equal(query.get('messageId'),'message-id');
  assert.equal(requests[0].options.headers.Authorization,'Bearer test-only-token');
  assert.equal(run('filterTimelineEvents.length'),3);
  assert.equal(element('filter-timeline-more').hidden,true);
  assert.match(element('filter-timeline-count').textContent,/3 אירועים/);
});

test('a late response cannot replace a newer search', async () => {
  const pending = [];
  const {ctx,element,run} = context(() => new Promise(resolve => pending.push(resolve)));
  element('filter-timeline-user').value = 'first';
  const first = ctx.loadFilterTimeline();
  element('filter-timeline-user').value = 'second';
  const second = ctx.loadFilterTimeline();
  pending[1](response({events:[event(20)],nextCursor:null}));
  await second;
  pending[0](response({events:[event(10)],nextCursor:null}));
  await first;
  assert.equal(run('filterTimelineEvents[0].id'),'20');
});

test('closing the panel aborts work and prevents response from populating hidden state', async () => {
  let resolve,signal;
  const {ctx,element,run} = context((_url,options) => {
    signal=options.signal;
    return new Promise(done => {resolve=done;});
  });
  const loading=ctx.loadFilterTimeline();
  ctx.hideFilterTimelinePanel();
  assert.equal(signal.aborted,true);
  resolve(response({events:[event(30)],nextCursor:null}));
  await loading;
  assert.equal(element('filter-timeline-panel').style.display,'none');
  assert.equal(run('filterTimelineEvents.length'),0);
});

test('search accepts a name or email and retains current selection safely', async () => {
  const {ctx,element} = context(async () => response([
    {id:'u1',name:'אביב',email:'aviv@example.test',profile_pic_url:'do-not-render'},
    {id:'u2',name:'<img onerror=bad()>',email:'yaniv@example.test'},
    {id:'u3',name:'שרה',email:'sarah@example.test'},
  ]));
  await ctx.loadFilterTimelineUsers();
  element('filter-timeline-user').value='u1';
  element('filter-timeline-search').value='YANIV';
  ctx.renderFilterTimelineUsers();
  const output = element('filter-timeline-user').innerHTML;
  assert.match(output,/אביב/);
  assert.match(output,/yaniv@example.test/);
  assert.doesNotMatch(output,/sarah@example.test|<img|do-not-render/);
  assert.equal(element('filter-timeline-user').value,'u1');
});

test('every main navigation path closes the timeline', () => {
  for (const name of ['logout','loadTable','showVisionPanel','showImageTestPanel',
    'showActivityPanel','showPermPanel','showScanPanel','showFilesPanel',
    'showListingsPanel','showModerationPanel']) {
    const position = html.indexOf('function ' + name + '(');
    const body = html.slice(html.indexOf('{',position)+1);
    assert.match(body,/^\s*hideFilterTimelinePanel\(\);/,name);
  }
});
