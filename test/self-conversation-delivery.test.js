'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(require.resolve('../server/index.js'), 'utf8');
const start = source.indexOf("async function sendPrivateHttpMessage(");
const end = source.indexOf("app.get('/api/message-requests',", start);

async function deliver(body, { contentAllowed = true, approved = true } = {}) {
  let handler;
  const writes = [];
  const filterDecisions = [];
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
    auth:()=>{}, messageRateLimit:()=>{}, registerGuideMessageSend:()=>{}, SCAN_BOT_ID:'scan',
    SYSTEM_USER_ID:'guide', SAFE_INFORMATION_USER_ID:'info',
    normalizeBuiltinStickerId:()=>null, moderateChatText:()=>({blocked:false}),
    verifyMessageLinks:async()=>{}, getPool:async()=>pool,
    teenContactAllowed:async()=>true, getStoredImageClassification:async()=>({category:'nonHumanImages'}),
    getEffectiveRecipientFilter:async()=>({isContact:true,filter:{text:true}}),
    contentAllowedByFilter:()=>contentAllowed, validateApprovedFile:async()=>approved,
    async writeSenderFilteredMedia(db, options, write) {
      assert.equal(db, pool);
      assert.equal(options.userId, 'me');
      assert.equal(options.contextType, 'chat');
      assert.equal(options.contextId, 'me');
      assert.equal(options.fileUrl, body.fileUrl);
      return write(pool);
    },
    recordFilterDecision:async(_db,decision)=>filterDecisions.push(decision),
    async notifyDestinationFilterBlock(db, options) {
      assert.equal(db, pool);
      assert.equal(options.userId, 'me');
      assert.equal(options.toUserId, 'me');
      assert.equal(options.fileUrl, body.fileUrl);
    },
    onlineUsers:new Map(), logActivity:()=>{},sendPush:()=>{},console,
  });
  const response = {code:200,status(code){this.code=code;return this;},json(body){this.body=body;return this;}};
  await handler({user:{id:'me',name:'Me'},body:{toUserId:'me',...body}},response);
  return {response,writes,filterDecisions};
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
    assert.equal(result.filterDecisions.length,policy.contentAllowed===false ? 1 : 0);
    if (result.filterDecisions.length) assert.equal(result.filterDecisions[0].source,'direct_http_send');
  }
});
