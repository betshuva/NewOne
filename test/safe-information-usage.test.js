'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs'),{createRequire}=require('node:module');
function fixture(){const calls=[],filename=require.resolve('../server/safe-information-ai'),localRequire=createRequire(filename),module={exports:{}};vm.runInNewContext(fs.readFileSync(filename,'utf8'),{module,console,process,performance,AbortSignal,URL,Buffer,require:name=>name==='./provider-usage-log'?{recordProviderCall:async event=>calls.push(event)}:localRequire(name)});return {calls,run:module.exports.generateSafeInformationAnswer};}
test('assistant logs every successful round once and retains it when a later network request fails',async()=>{
 const h=fixture();let n=0;
 await assert.rejects(h.run({apiKey:'test',question:'חפש מודעות למקרר',searchMarketplace:async()=>({listings:[]}),fetchImpl:async()=>{
  if(n++)throw Error('network failed');
  return {ok:true,json:async()=>({usage:{input_tokens:100,output_tokens:20,total_tokens:120,input_tokens_details:{cached_tokens:30,cache_write_tokens:40}},output:[{type:'function_call',name:'search_marketplace',call_id:'one',arguments:'{"query":"מקרר"}'}]})};
 }}),/network failed/);
 assert.equal(h.calls.length,2);assert.equal(h.calls[0].usage.totalTokens,120);assert.equal(h.calls[0].usage.cacheWriteTokens,40);assert.equal(h.calls[1].usageReported,false);
});
test('an HTTP failure is logged once, with reported usage and no duplicate aggregate',async()=>{
 const h=fixture();await assert.rejects(h.run({apiKey:'test',question:'מה מזג האוויר?',fetchImpl:async()=>({ok:false,status:429,json:async()=>({error:{message:'quota'},usage:{input_tokens:10,output_tokens:0,total_tokens:10}})})}),/quota/);assert.equal(h.calls.length,1);assert.equal(h.calls[0].usage.totalTokens,10);
});
