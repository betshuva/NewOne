'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(require.resolve('../server/index.js'), 'utf8');
const start = source.indexOf("app.post('/api/messages',");
const end = source.indexOf("app.get('/api/message-requests',", start);

async function deliver(body, { contentAllowed = true, approved = true } = {}) {
  let handler;
  const writes = [];
  const pool = {query: async (sql, values) => {
    if (/INSERT INTO messages /.test(sql)) {
      writes.push({sql,values});
      return {rows:[{id:'saved',created_at:'2026-09-06'}]};
    }
    if (/INSERT INTO message_requests/.test(sql)) throw new Error('Self request must never be created');
    return {rows:[]};
  }};
  vm.runInNewContext(source.slice(start,end), {
    app:{post: (...args) => { handler = args.at(-1); }},
    auth:()=>{}, messageRateLimit:()=>{},
    SYSTEM_USER_ID:'guide', SAFE_INFORMATION_USER_ID:'info',
    normalizeBuiltinStickerId:()=>null, moderateChatText:()=>({blocked:false}),
    verifyMessageLinks:async()=>{}, getPool:async()=>pool,
    teenContactAllowed:async()=>true, getStoredImageClassification:async()=>({category:'nonHumanImages'}),
    getEffectiveRecipientFilter:async()=>({isContact:true,filter:{text:true}}),
    contentAllowedByFilter:()=>contentAllowed, validateApprovedFile:async()=>approved,
    onlineUsers:new Map(), logActivity:()=>{},sendPush:()=>{},console,
  });
  const response = {code:200,status(code){this.code=code;return this;},json(body){this.body=body;return this;}};
  await handler({user:{id:'me',name:'Me'},body:{toUserId:'me',...body}},response);
  return {response,writes};
}
test('actual HTTP handler saves the first self message without creating a contact request', async () => {
  const result = await deliver({text:'private note'});
  assert.equal(result.response.code,200);
  assert.equal(result.response.body.id,'saved');
  assert.equal(result.writes.length,1);
  assert.equal(result.writes[0].values[0],'me');
  assert.equal(result.writes[0].values[1],'me');
});
test('self attachments still require a passed scan and permitted content', async () => {
  const attachment = {fileUrl:'/file',fileName:'photo.jpg',fileType:'image'};
  assert.equal((await deliver(attachment)).writes.length,1);
  for (const policy of [{approved:false},{contentAllowed:false}]) {
    const result = await deliver(attachment,policy);
    assert.equal(result.response.code,403);
    assert.equal(result.writes.length,0);
  }
});
