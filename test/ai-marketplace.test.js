'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { searchMarketplace } = require('../server/ai-marketplace');
const { generateSafeInformationAnswer } = require('../server/safe-information-ai');
const id = '11111111-1111-4111-8111-111111111111';
const url = `betshuva://listing/${id}`;

test('marketplace denies minors, unknown ages and missing users before reading listings', async () => {
  for (const rows of [[{allowed:false}], [{allowed:null}], []]) {
    let calls = 0;
    const result = await searchMarketplace({query: async () => { calls++; return {rows}; }}, 'user');
    assert.equal(result.error, 'MARKETPLACE_UNAVAILABLE');
    assert.equal(calls, 1);
  }
});

test('search is parameterized, active-only, paginated, and excludes seller fields', async () => {
  const pool = {query: async (sql, params) => {
    if (sql.includes('FROM users')) return {rows:[{allowed:true}]};
    assert.match(sql, /l.status='active'/);
    assert.match(sql, /l.expires_at > now\(\)/);
    assert.match(sql, /LIMIT 21 OFFSET/);
    assert.doesNotMatch(sql, /seller|phone|email|latitude|longitude|pickup_details/);
    assert.doesNotMatch(sql, /ירושלים|מקרר/);
    assert.deepEqual(params, [['%מקרר%', '%100\\%\\_%'], '%ירושלים%', 'free', 500, 20]);
    return {rows: Array.from({length:21}, () => ({id, title:'מקרר', description:'טלפון 0501234567', price:null, type:'free'}))};
  }};
  const result = await searchMarketplace(pool, 'user', {terms:['מקרר', '100%_'], city:'ירושלים', type:'free', max_price:500, offset:20});
  assert.equal(result.listings.length, 20);
  assert.equal(result.has_more, true);
  assert.equal(result.next_offset, 40);
  assert.equal(result.listings[0].url, url);
  assert.doesNotMatch(result.listings[0].description, /0501234567/);
});

test('specific listing ignores unrelated filters but still requires active status', async () => {
  const result = await searchMarketplace({query: async (sql, params) => {
    if (sql.includes('FROM users')) return {rows:[{allowed:true}]};
    assert.deepEqual(params, [id, 0]);
    assert.match(sql, /l.status='active'/);
    return {rows:[]};
  }}, 'user', {listing_id:id, terms:['other'], city:'other', offset:20});
  assert.deepEqual(result.listings, []);
  assert.equal(result.has_more, false);
});

test('AI calls marketplace and returns only verified listing links', async () => {
  let requests = 0;
  const answer = await generateSafeInformationAnswer({
    apiKey:'test', question:'אילו מקררים מוצעים למסירה?',
    searchMarketplace: async args => { assert.deepEqual(args.terms,['מקרר']); return {listings:[{id,url,title:'מקרר',type:'free'}]}; },
    fetchImpl: async (_, options) => {
      const body = JSON.parse(options.body);
      requests++;
      assert.ok(body.tools.some(tool => tool.name === 'search_marketplace'));
      if (requests === 1) return {ok:true,json:async()=>({output:[{type:'function_call', name:'search_marketplace',call_id:'call1',arguments:JSON.stringify({terms:['מקרר']})}]})};
      const output = body.input.find(item => item.type === 'function_call_output');
      assert.equal(output.call_id,'call1');
      assert.equal(JSON.parse(output.output).listings[0].title,'מקרר');
      return {ok:true,json:async()=>({output:[{content:[{type:'output_text',text:`מקרר למסירה\n${url}\nbetshuva://listing/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa`}]}]})};
    },
  });
  assert.equal(requests,2);
  assert.match(answer,new RegExp(url));
  assert.doesNotMatch(answer,/aaaaaaaa/);
  assert.doesNotMatch(answer,/לא צורף מקור/);
});

test('teen has no marketplace tool even when a callback exists', async () => {
  await generateSafeInformationAnswer({apiKey:'test',isTeen:true,question:'מקרר למסירה',
    searchMarketplace: async () => { throw new Error('must not run'); },
    fetchImpl: async (_, options) => {
      assert.ok(!JSON.parse(options.body).tools.some(tool => tool.name === 'search_marketplace'));
      return {ok:true,json:async()=>({output:[{content:[{type:'output_text',text:'הלוח אינו זמין לחשבון זה'}]}]})};
    }});
});

test('tool failure is reported as unavailable, not an empty successful search', async () => {
  let requests=0;
  const answer = await generateSafeInformationAnswer({apiKey:'test',question:'מקררים',
    searchMarketplace:async()=>{throw new Error('offline');},
    fetchImpl:async(_,options)=>{
      if (++requests===1) return {ok:true,json:async()=>({output:[{type:'function_call',name:'search_marketplace',call_id:'1',arguments:'{}'}]})};
      assert.equal(JSON.parse(JSON.parse(options.body).input.at(-1).output).error,'SEARCH_FAILED');
      return {ok:true,json:async()=>({output:[{content:[{type:'output_text',text:'לא ניתן לבדוק כרגע'}]}]})};
    }});
  assert.doesNotMatch(answer,/מקור: מודעות פעילות/);
});
