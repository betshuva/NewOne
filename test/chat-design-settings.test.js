'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { DEFAULTS, validateSettings, decodeDocument, registerChatDesignRoutes } = require('../server/chat-design-settings');

test('design validates bounded numeric fields, booleans, readable colors and unknown keys', () => {
  assert.deepEqual(validateSettings({ messageGap: 2, textScale: 1.1, showFileNames: false, accentColor: '#164A73' }),
    { messageGap: 2, textScale: 1.1, showFileNames: false, accentColor: '#164A73' });
  for (const bad of [{ messageGap: -1 }, { voicePlayerWidth: 500 }, { textScale: NaN },
    { showFileNames: 'false' }, { javascript: 'alert(1)' }, { accentColor: '#FFFFFF' },
    { chatBackground: '#000000' }, { outgoingBubble: '#123' }, null, []])
    assert.throws(() => validateSettings(bad));
  assert.deepEqual(validateSettings(DEFAULTS), DEFAULTS);
});
test('damaged or incompatible documents fall back to complete defaults', () => {
  for (const bad of ['broken', null, { schemaVersion: 2 }, { schemaVersion: 1, revision: 'x', settings: { textScale: 100 } }]) {
    const result = decodeDocument(bad);
    assert.equal(result.revision, 'initial');
    assert.deepEqual(result.settings, DEFAULTS);
  }
});
function harness() {
  const routes = new Map(); let stored; let committed; let notifications = 0; let fail = false;
  const query = async (sql, args) => {
    if (fail && sql.startsWith('INSERT')) throw Error('database unavailable');
    if (sql.startsWith('SELECT value')) return { rows: stored ? [{ value: stored }] : [] };
    if (sql === 'BEGIN') committed = stored;
    if (sql === 'ROLLBACK') stored = committed;
    if (sql.startsWith('INSERT')) stored = args[1];
    return { rows: [] };
  };
  const pool = { query, connect: async () => ({ query, release() {} }) };
  const app = { get(path, ...handlers) { routes.set('GET '+path, handlers); },
    put(path, ...handlers) { routes.set('PUT '+path, handlers); } };
  const adminAuth = (req, res, next) => next();
  registerChatDesignRoutes(app, { getPool: async () => pool, adminAuth,
    notify() { notifications++; } });
  return { routes, get notifications() { return notifications; },
    failWrites() { fail = true; }, async request(method, path, body, perm = 'edit') {
      const handlers = routes.get(method+' '+path); const req = { body, adminPerm: perm };
      const res = { statusCode: 200, headers: {}, set(k,v) { this.headers[k]=v; return this; },
        status(n) { this.statusCode=n; return this; }, json(v) { this.body=v; return this; } };
      await handlers.at(-1)(req,res); return res;
    } };
}
test('public endpoint exposes defaults with no caching and admin routes require authentication', async () => {
  const api=harness(); const r=await api.request('GET','/api/chat-design');
  assert.equal(r.statusCode,200); assert.equal(r.headers['Cache-Control'],'no-store');
  assert.deepEqual(r.body.settings,DEFAULTS);
  assert.equal(api.routes.get('PUT /api/admin/chat-design').length,2);
  assert.equal(api.routes.get('GET /api/admin/chat-design').length,2);
});
test('updates merge fields, persist revisions and notify clients only after successful commit', async () => {
  const api=harness(); const r=await api.request('PUT','/api/admin/chat-design',
    { expectedRevision:'initial',settings:{messageGap:2,showFileNames:false} });
  assert.equal(r.statusCode,200); assert.notEqual(r.body.revision,'initial');
  assert.equal(r.body.settings.voicePlayerWidth,285); assert.equal(api.notifications,1);
  const read=await api.request('GET','/api/chat-design'); assert.deepEqual(read.body,r.body);
  const stale=await api.request('PUT','/api/admin/chat-design',{expectedRevision:'initial',settings:{messageGap:8}});
  assert.equal(stale.statusCode,409); assert.equal(api.notifications,1);
});
test('read-only admins and invalid settings cannot change design', async () => {
  const api=harness();
  const r=await api.request('PUT','/api/admin/chat-design',{expectedRevision:'initial',settings:{messageGap:2}},'view');
  assert.equal(r.statusCode,403);
  const bad=await api.request('PUT','/api/admin/chat-design',{expectedRevision:'initial',settings:{voicePlayerWidth:500}});
  assert.equal(bad.statusCode,400); assert.equal(api.notifications,0);
});
test('failed writes retain the previous document and do not notify clients', async () => {
  const api=harness();api.failWrites();
  const r=await api.request('PUT','/api/admin/chat-design',{expectedRevision:'initial',settings:{messageGap:2}});
  assert.equal(r.statusCode,500);assert.equal(api.notifications,0);
  assert.equal((await api.request('GET','/api/chat-design')).body.revision,'initial');
});

test('expanded chat and listing controls reject invalid layouts and category lists', () => {
  const patch={compactBlockedMedia:false,compactWaitingCards:false,listingLayout:'cards',
    listingSearchSide:'left',listingImageSize:160,listingCategoryOrder:['רכב','נדל״ן'],
    listingSearchFieldOrder:['manufacturer','model'],listingShowPost:false};
  assert.deepEqual(validateSettings(patch),patch);
  for(const bad of [{listingLayout:'javascript'}, {listingSearchSide:'center'},
    {listingCategoryOrder:['רכב','רכב']},{listingSearchFieldOrder:[123]},
    {listingImageSize:900},{compactBlockedMedia:'false'}]) assert.throws(()=>validateSettings(bad));
  const old=decodeDocument({schemaVersion:1,revision:'old',settings:{composerActionSize:36}});
  assert.equal(old.settings.composerActionSize,36);
  assert.equal(old.settings.compactBlockedMedia,true);
  assert.equal(old.settings.listingLayout,'list');
});

test('behavior policies are bounded presets and preserve old document settings', () => {
  const patch={composerToolsVisibility:'focused',dismissKeyboardOnSend:false,
    autoScrollMode:'manual',autoScrollDistance:120,autoScrollDurationMs:0,
    messageMenuPresentation:'sheet',messageMenuOrder:['העתק','ענה'],
    listingSearchAsYouType:false,listingSearchDebounceMs:500,
    listingSearchSectionOrder:['query','category'],cardTapAction:'none'};
  assert.deepEqual(validateSettings(patch),patch);
  for(const bad of [{composerToolsVisibility:'script'},{autoScrollMode:'execute'},
    {listingSearchDebounceMs:-1},{messageMenuOrder:['ענה','ענה']},{cardTapAction:'openBlockedFile'}])
    assert.throws(()=>validateSettings(bad));
});
