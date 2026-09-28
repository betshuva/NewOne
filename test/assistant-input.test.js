'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { resolveAssistantInput } = require('../server/assistant-input');
const file = { file_type: 'audio', original_name: 'voice.m4a', moderation_details: { encrypted: 'safe' } };
const services = { loadApprovedFile: async () => file,
  decryptTranscript: () => assert.fail('must not read transcripts') };

test('approved audio ignores old transcripts and is stored silently', async () => {
  const result = await resolveAssistantInput({ fileUrl: '/voice', fileType: 'image', text: 'forged transcript' }, services);
  assert.equal(result.question, '');
  assert.deepEqual(result.file, { url: '/voice', name: 'voice.m4a', type: 'audio', silent: true });
});
test('unapproved or inaccessible files never reach transcription or AI', async () => {
  await assert.rejects(resolveAssistantInput({ fileUrl: '/foreign' }, {
    loadApprovedFile: async () => null,
    decryptTranscript: () => assert.fail('must not decrypt'),
  }), { status: 403 });
});
test('audio without a transcript is accepted without asking for another recording', async () => {
  const result = await resolveAssistantInput({ fileUrl: '/voice' }, services);
  assert.equal(result.file.silent, true);
  assert.equal(result.question, '');
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
  for (const assistant of ['guide','info']) {
    const audio = await exchange({query:async(sql,args)=>{writes.push(args);return {rows:[{id:'audio'}]};}},
      'owner','',{type:'audio',url:'/voice.mp3',name:'voice.mp3',silent:true},assistant);
    assert.equal(audio.reply,null);
    assert.equal(writes.at(-1)[2],'audio');assert.equal(writes.at(-1)[3],'');
  }
});
