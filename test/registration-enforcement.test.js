'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const {normalizeContentFilter,NEW_ACCOUNT_CONTENT_FILTER}=require('../server/content-filter-policy');
const source=fs.readFileSync(require.resolve('../server/index.js'),'utf8');
const start=source.indexOf('function requestedRegistrationFilter(');
const end=source.indexOf('async function getEffectiveRecipientFilter',start);
const context={normalizeContentFilter,NEW_ACCOUNT_CONTENT_FILTER};
vm.runInNewContext(source.slice(start,end),context);
test('registration persists explicit enforcement and defaults omitted option to off',()=>{
 for(const flag of [true,false,undefined]){
  const result=context.requestedRegistrationFilter({contentFilterConfirmed:true,contentFilter:{...NEW_ACCOUNT_CONTENT_FILTER,...(flag===undefined?{}:{enforceGeneralFilter:flag})}});
  assert.equal(result.enforceGeneralFilter,flag===true);
  assert.equal(result.women,false);
 }
});
test('malformed enforcement is rejected instead of silently switching protection off',()=>{
 assert.equal(context.requestedRegistrationFilter({contentFilterConfirmed:true,contentFilter:{...NEW_ACCOUNT_CONTENT_FILTER,enforceGeneralFilter:'true'}}),null);
});
