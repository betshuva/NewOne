'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { Client } = require('pg');
const { DEFAULT_CONTENT_FILTER, resolveScopedContentFilter } = require('../server/content-filter-policy');
test('SQL enforcement agrees with delivery policy and legacy updates preserve the flag', {skip:process.env.RUN_DB_TESTS!=='1'}, async () => {
 const db=new Client({connectionString:process.env.DATABASE_URL,ssl:process.env.DB_SSL==='true'?{rejectUnauthorized:process.env.DB_REJECT_UNAUTHORIZED!=='false'}:false});
 await db.connect();
 try {
  await db.query('BEGIN');
  await db.query('CREATE TEMP TABLE filter_test(content_filter jsonb)');
  await db.query(fs.readFileSync(require.resolve('../server/scoped-content-filter.sql'),'utf8').replace('FUNCTION betshuva_effective_filter','FUNCTION pg_temp.betshuva_effective_filter'));
  const keys=Object.keys(DEFAULT_CONTENT_FILTER);
  for (const enforce of [false,true]) {
   for (let n=0;n<64;n++) {
    const general={...Object.fromEntries(keys.map((k,i)=>[k,!!(n&(1<<i))])),enforceGeneralFilter:enforce};
    for (const scope of [null,DEFAULT_CONTENT_FILTER,{text:false,women:true}]) {
     const result=await db.query('SELECT pg_temp.betshuva_effective_filter($1,$2) AS filter',[JSON.stringify(general),scope===null?null:JSON.stringify(scope)]);
     assert.deepEqual(result.rows[0].filter,resolveScopedContentFilter(general,scope));
    }
   }
  }
  await db.query('INSERT INTO filter_test VALUES($1)',[JSON.stringify({...DEFAULT_CONTENT_FILTER,enforceGeneralFilter:true})]);
  const update=flag=>db.query(`UPDATE filter_test SET content_filter=$1::jsonb || jsonb_build_object('enforceGeneralFilter',COALESCE($2::boolean,(content_filter->>'enforceGeneralFilter')::boolean,false)) RETURNING content_filter`,[JSON.stringify(DEFAULT_CONTENT_FILTER),flag]);
  assert.equal((await update(null)).rows[0].content_filter.enforceGeneralFilter,true);
  assert.equal((await update(false)).rows[0].content_filter.enforceGeneralFilter,false);
  assert.equal((await update(true)).rows[0].content_filter.enforceGeneralFilter,true);
 } finally {await db.query('ROLLBACK');await db.end();}
});
