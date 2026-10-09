'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { validPin, sessionKey, requireFilterPin } = require('../server/filter-pin');

test('PIN accepts only four to eight ASCII digits and preserves leading zeroes',()=>{
 for(const pin of ['0000','12345678','004812'])assert.equal(validPin(pin),true);
 for(const pin of ['123','123456789','12 34','abcd','１２３４',1234,null])assert.equal(validPin(pin),false);
});
test('grant is bound to the current bearer session and stores no bearer value',()=>{
 const a=sessionKey({headers:{authorization:'Bearer session-a'}});
 assert.equal(a.length,64);assert.notEqual(a,sessionKey({headers:{authorization:'Bearer session-b'}}));
 assert.equal(a.includes('session-a'),false);
});
test('configured locked, expired or revoked grants cannot change filters',async()=>{
 for(const unlocked of [false,null,undefined]){
  await assert.rejects(requireFilterPin({query:async()=>({rows:[{unlocked}]})},{user:{id:'user'},headers:{authorization:'Bearer session'}}),e=>e.status===423&&e.code==='FILTER_PIN_LOCKED');
 }
});
test('unconfigured account and valid session grant can change filters',async()=>{
 for(const rows of [[],[{unlocked:true}]])await requireFilterPin({query:async()=>({rows})},{user:{id:'user'},headers:{authorization:'Bearer session'}});
});
