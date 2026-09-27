'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
const f=require('../server/audit-column-formats');
test('positions shift intervening columns and retain a unique 1-to-N permutation',()=>{
 assert.deepEqual(f.move(['a','b','c','d','e','f'],'f',2),['a','f','b','c','d','e']);
 assert.deepEqual(f.move(['a','b','c'],'a',3),['b','c','a']);
 for(const n of [0,4,1.2,NaN])assert.throws(()=>f.move(['a','b','c'],'b',n));
});
test('number display rounds decimals, groups thousands and preserves bigint precision',()=>{
 assert.equal(f.format('total_tokens','9007199254740993',{type:'number',decimals:2,grouping:true}),'9,007,199,254,740,993.00');
 assert.equal(f.format('cost_ils',1.005,{type:'number',decimals:2,grouping:false}),'1.01');
 assert.equal(f.format('cost_ils',-1.005,{type:'number',decimals:2,grouping:false}),'-1.01');
 assert.equal(f.format('cost_ils',0.0000005,{type:'number',decimals:8,grouping:false}),'0.00000050');
 assert.equal(f.format('cost_ils',null,{type:'currency',decimals:2,grouping:true,currency:'ILS'}),null);
 assert.equal(f.format('cost_ils','לא ידוע',{type:'number',decimals:2,grouping:true}),null);
 assert.equal(f.format('cost_ils',12.3,{type:'currency',decimals:2,grouping:true,currency:'USD'}),'$12.30');
 assert.equal(f.format('confidence',97,{type:'percent',decimals:1,grouping:false}),'97.0%');
 assert.equal(f.format('fx_rate',0.25,{type:'percent',decimals:0,grouping:false}),'25%');
});
test('durations never wrap at 24 hours; dates retain hundredths and date-only calendar values',()=>{
 assert.equal(f.format('duration_ms',90061005,{type:'duration',pattern:'hh:mm:ss',decimals:2}),'25:01:01.01');
 assert.equal(f.format('duration_ms',90061005,{type:'duration',pattern:'mm:ss',decimals:0}),'1501:01');
 assert.equal(f.format('duration_ms',75427,{type:'number',decimals:2,grouping:false}),'75.43');
 assert.equal(f.format('created_at','2026-09-27T09:15:30.129',{type:'date',pattern:'dd/MM/yy HH:mm:ss.SS'}),'27/09/26 09:15:30.12');
 assert.equal(f.format('fx_date','2026-09-25',{type:'date',pattern:'dd/MM/yyyy'}),'25/09/2026');
 assert.equal(f.format('created_at','not a date',{type:'date',pattern:'dd/MM/yyyy'}),null);
});
test('format validation rejects code, unknown options and incompatible types',()=>{
 for(const bad of [{type:'number',decimals:100,grouping:true},{type:'number',decimals:2,grouping:'true'},{type:'number',decimals:2,grouping:true,script:'x'},{type:'currency',decimals:2,grouping:true,currency:'<img>'}])assert.equal(f.valid('cost_ils',bad),false);
 assert.equal(f.valid('created_at',{type:'date',pattern:'<script>'}),false);
 assert.equal(f.valid('action',f.defaults('number')),false);
 assert.equal(f.valid('expand',f.defaults('text')),false);
 assert.deepEqual(f.normalize({cost_ils:f.defaults('number'),action:{type:'auto'},unknown:{type:'text'}},['cost_ils','action']),{cost_ils:f.defaults('number')});
});
test('browser embeds exactly the shared format engine',()=>{
 const source=fs.readFileSync(require.resolve('../server/audit-column-formats'),'utf8'),shared=source.slice(source.indexOf('function createAuditColumnFormats()'),source.indexOf('\nmodule.exports='));
 assert.ok(fs.readFileSync(require.resolve('../admin-audit.html'),'utf8').includes(shared));
});
