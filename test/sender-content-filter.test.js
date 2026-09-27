'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { assertSenderMediaAllowed, getEffectiveSenderFilter } = require('../server/sender-content-filter');
const ALL = { text:true, video:true, nonHumanImages:true, men:true, women:true, children:true };
const MEN = { category:'men', detectedCategories:['men'], uncertain:false };
const USER='10000000-0000-4000-8000-000000000001', CONTACT='10000000-0000-4000-8000-000000000002', FILE='10000000-0000-4000-8000-000000000003';
function database(general={...ALL,men:false,video:false,enforceGeneralFilter:true},scoped=null) {
 const db={general,scoped,queries:[],events:[]};
 db.query=async(sql,params)=>{
  db.queries.push({sql,params});
  if(sql.startsWith('SELECT u.content_filter'))return{rows:[{general_filter:db.general,scoped_filter:params[1]==='general'?null:db.scoped}]};
  if(sql.startsWith('INSERT INTO filter_audit_events')) {db.events.push(JSON.parse(params[7]));return{rows:[{}]};}
  throw new Error('Unexpected query: '+sql);
 };return db;
}
const check=(db,extra={})=>assertSenderMediaAllowed(db,{userId:USER,contextType:'chat',contextId:CONTACT,type:'image',classification:MEN,fileId:FILE,...extra});
for(const contextType of ['chat','contact','group'])test(`${contextType} outgoing content ignores all sender receiving preferences`,async()=>{
 const db=database({...ALL,men:false,women:false,children:false,video:false,enforceGeneralFilter:true},{...ALL,men:false,video:false});
 for(const type of ['image','video','document','audio','text','sticker'])
  for(const source of ['sender_upload','approved_file_send','shared_gif_send','sender_persist','sender_delayed_scan','sender_delayed_persist'])
   assert.equal(await check(db,{contextType,type,source}),null);
 assert.equal(db.queries.length,0);assert.equal(db.events.length,0);
});
test('standalone and self-conversation preferences still protect the viewer',async()=>{
 for(const contextType of ['general','profile','scan','unknown',undefined]) {
  const db=database();await assert.rejects(check(db,{contextType}),{code:'SENDER_CONTENT_FILTERED'});
  assert.equal(db.events[0].policy.men,false);
 }
 for(const type of ['image','video','document']) {
  const db=database();await assert.rejects(check(db,{type,contextId:USER}),{code:'SENDER_CONTENT_FILTERED'});
 }
});
test('personal history still resolves contact/group settings and enforced general restrictions',async()=>{
 const db=database({...ALL,men:false,enforceGeneralFilter:true},ALL);
 for(const contextType of ['chat','group'])assert.equal((await getEffectiveSenderFilter(db,USER,contextType,CONTACT)).men,false);
 db.general.enforceGeneralFilter=false;
 assert.equal((await getEffectiveSenderFilter(db,USER,'chat',CONTACT)).men,true);
 db.scoped={...ALL,women:false};assert.equal((await getEffectiveSenderFilter(db,USER,'group',CONTACT)).women,false);
});
test('changing sender preferences does not invalidate delivery to another recipient',async()=>{
 const db=database(ALL);assert.equal(await check(db),null);db.general={...ALL,men:false,video:false};
 assert.equal(await check(db,{type:'video',source:'sender_delayed_scan'}),null);
 assert.equal(db.events.length,0);
});
test('missing destination uses personal preferences; ordinary text/audio remains available',async()=>{
 const db=database();await assert.rejects(check(db,{contextId:null}),{code:'SENDER_CONTENT_FILTERED'});
 for(const type of ['text','audio','sticker'])assert.equal(await check(db,{contextType:'general',type}),null);
});
