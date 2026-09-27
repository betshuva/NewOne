'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { resolveAssistantInput } = require('../server/assistant-input');
const file = { file_type: 'audio', original_name: 'voice.m4a', moderation_details: { encrypted: 'safe' } };
const services = { loadApprovedFile: async () => file,
  decryptTranscript: details => { assert.equal(details.encrypted, 'safe'); return 'איך מוסיפים חבר?'; } };

test('approved voice question uses verified transcript and actual file type', async () => {
  const result = await resolveAssistantInput({ fileUrl: '/voice', fileType: 'image', text: 'forged transcript' }, services);
  assert.equal(result.question, 'איך מוסיפים חבר?');
  assert.deepEqual(result.file, { url: '/voice', name: 'voice.m4a', type: 'audio' });
});
test('unapproved or inaccessible files never reach transcription or AI', async () => {
  await assert.rejects(resolveAssistantInput({ fileUrl: '/foreign' }, {
    loadApprovedFile: async () => null,
    decryptTranscript: () => assert.fail('must not decrypt'),
  }), { status: 403 });
});
test('empty or unintelligible audio requests a new recording', async () => {
  await assert.rejects(resolveAssistantInput({ fileUrl: '/voice' }, {
    ...services, decryptTranscript: () => '  ',
  }), { status: 422 });
});
test('ordinary text remains supported without loading a file', async () => {
  const result = await resolveAssistantInput({ text: 'שלום' }, {});
  assert.deepEqual(result, { question: 'שלום', file: null });
});

test('verified library stickers are silent while ordinary images still request an answer', async () => {
  const trusted = await resolveAssistantInput({text:'file.png',fileUrl:'/sticker'}, {
    loadApprovedFile:async()=>({file_type:'image',moderation_details:{source:'builtin-expression',scanSkipped:true}}),
  });
  assert.equal(trusted.file.silent,true);
  const ordinary = await resolveAssistantInput({fileUrl:'/photo',silent:true}, {
    loadApprovedFile:async()=>({file_type:'image',moderation_details:{}}),
  });
  assert.equal(ordinary.file.silent,undefined);
  const id = await resolveAssistantInput({trustedStickerId:'approved-sticker'},{});
  assert.equal(id.file.type,'sticker'); assert.equal(id.file.silent,true);
});

test('the actual guide exchange persists a silent sticker without generating or saving a reply', async () => {
  const fs=require('node:fs'), vm=require('node:vm');
  const source=fs.readFileSync(require.resolve('../server/index'),'utf8');
  const start=source.indexOf('async function createSystemExchange('),end=source.indexOf('// ── Activity logger',start);
  const writes=[];
  const exchange=vm.runInNewContext(`${source.slice(start,end)}; createSystemExchange`, {
    SYSTEM_USER_ID:'guide',SAFE_INFORMATION_USER_ID:'info',
    redactHarmfulLanguageForDisplay:value=>value,auditIds:()=>[null,null],
    generateSystemAnswer:()=>assert.fail('silent sticker must not call model'),
  });
  const result=await exchange({query:async(sql,args)=>{writes.push(args);return {rows:[{id:'saved'}]};}},'owner','sticker',{type:'sticker',silent:true});
  assert.equal(writes.length,1);assert.equal(writes[0][2],'sticker');assert.equal(result.sent.id,'saved');assert.equal(result.reply,null);
});
