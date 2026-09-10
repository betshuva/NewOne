'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { generateSafeInformationAnswer } = require('../server/safe-information-ai');

const currentId = '22222222-2222-4222-8222-222222222222';
const previousId = '11111111-1111-4111-8111-111111111111';
const listingUrl = id => `betshuva://listing/${id}`;
const appraisal = id =>
  `אשמח לחוות דעת על המודעה הזו: האם המחיר כדאי ומה חשוב לבדוק?\n${listingUrl(id)}`;
const vehicle = {
  id: currentId, url: listingUrl(currentId), title: 'מרצדס VITO',
  type: 'sale', price: 70000, city: 'רחובות', has_images: true,
  vehicle_details: JSON.stringify({ year: 2012, mileage: 138000,
    fuel: 'דיזל', transmission: 'אוטומטית' }),
};
const imageUrl = `data:image/jpeg;base64,${Buffer.from('test-listing-photo').toString('base64')}`;
const source = { url: 'https://comparison.example.test/vito-2012', title: 'לוח רכבים לדוגמה' };
const response = output => ({ ok: true, json: async () => ({ output }) });
const message = text => ({ type: 'message', role: 'assistant',
  content: [{ type: 'output_text', text }] });
const lookup = (callId = 'listing', id = currentId) => ({
  type: 'function_call', name: 'search_marketplace', call_id: callId,
  arguments: JSON.stringify({ listing_id: id }),
});
const researched = text => response([
  { type: 'web_search_call', status: 'completed', action: { type: 'search', sources: [source] } },
  message(text),
]);
const inputs = body => JSON.stringify(body.input);
const isForcedWeb = body => body.tool_choice?.type === 'web_search';

test('the ordinary listing appraisal loads its current facts and photos before mandatory web comparison', async () => {
  const events = [];
  let loaded = false;
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test', question: appraisal(currentId),
    searchMarketplace: async args => {
      assert.equal(args.listing_id, currentId);
      events.push('listing');
      loaded = true;
      return { listings: [vehicle] };
    },
    loadMarketplaceImages: async ids => {
      assert.deepEqual(ids, [currentId]);
      events.push('photos');
      return [{ listing_id: currentId, image_url: imageUrl }];
    },
    validateSource: async url => { assert.equal(url, source.url); return true; },
    fetchImpl: async (_, options) => {
      const body = JSON.parse(options.body);
      if (!loaded) {
        assert.ok(!isForcedWeb(body), 'do not search the web from an opaque listing UUID');
        assert.deepEqual(body.tool_choice, { type: 'function', name: 'search_marketplace' });
        return response([lookup()]);
      }
      assert.ok(isForcedWeb(body), 'the appraisal must require a web comparison');
      assert.match(inputs(body), /VITO/);
      assert.match(inputs(body), /2012/);
      assert.match(inputs(body), /138000/);
      assert.ok(inputs(body).includes(imageUrl), 'authorized listing photos reach the comparison request');
      assert.ok(body.tools.some(tool => tool.type === 'web_search'));
      events.push('web');
      return researched('70,000 ש״ח דומה למחירים מבוקשים שנמצאו לגרסה דומה. בדוק את גרסת הרכב ואת מצב המנוע והגיר.');
    },
  });
  assert.deepEqual(events, ['listing', 'photos', 'web']);
  assert.match(answer, /70,000/);
  assert.match(answer, /המנוע והגיר/);
  assert.doesNotMatch(answer, /https?:|example\.test|לוח רכבים|מקורות/);
});

test('an appraisal with supplied product details requires web research and a conclusion with exactly two checks', async () => {
  const conclusion = '70,000 ש״ח דומה למחירים מבוקשים שנמצאו לגרסה דומה.';
  const checks = ['גרסת נוסעים או מסחרית ברישיון.', 'מנוע וגיר במוסך.'];
  let requests = 0;
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test', question: 'חוות דעת על מודעת מרצדס VITO דיזל אוטומטית 2012 ב־70,000 ש״ח: האם המחיר כדאי?',
    validateSource: async () => true,
    fetchImpl: async (_, options) => {
      requests++;
      const body = JSON.parse(options.body);
      assert.ok(isForcedWeb(body));
      assert.equal(body.text?.format?.type, 'json_schema');
      const schema = body.text.format.schema;
      assert.deepEqual([...schema.required].sort(), ['checks', 'conclusion']);
      assert.equal(schema.properties.checks.minItems, 2);
      assert.equal(schema.properties.checks.maxItems, 2);
      return researched(JSON.stringify({ conclusion, checks }));
    },
  });
  assert.equal(requests, 1);
  assert.ok(answer.includes(conclusion));
  for (const check of checks) assert.ok(answer.includes(check));
  assert.doesNotMatch(answer, /"conclusion"|"checks"|https?:|example\.test|מקורות/);
  assert.ok(answer.split(/\s+/).length <= 90);
});

test('a provider cannot replace the required search with an unsupported final verdict', async () => {
  let loaded = false;
  let afterLoad = 0;
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test', question: appraisal(currentId),
    searchMarketplace: async () => { loaded = true; return { listings: [vehicle] }; },
    fetchImpl: async (_, options) => {
      const body = JSON.parse(options.body);
      if (!loaded) return response([lookup()]);
      afterLoad++;
      assert.ok(isForcedWeb(body));
      return response([message('EARLY_NO_COMPARISON המחיר כדאי כי מחיר השוק הוא 999,999 ש״ח.')]);
    },
  });
  assert.equal(afterLoad, 1, 'the required attempt is bounded when the provider fails to run its tool');
  assert.match(answer, /70,000/);
  assert.match(answer, /השוואת מחיר/);
  assert.doesNotMatch(answer, /EARLY_NO_COMPARISON|999,999|המחיר כדאי כי/);
});

test('a current listing price follow-up reloads only its subject before mandatory comparison', async () => {
  let loaded = false;
  const loadedIds = [];
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test', question: 'ומה המחיר?',
    history: [
      { role: 'user', content: appraisal(previousId) },
      { role: 'assistant', content: `מקרר קודם\n${listingUrl(previousId)}` },
      { role: 'user', content: appraisal(currentId) },
      { role: 'assistant', content: `רכב נוכחי\n${listingUrl(currentId)}` },
    ],
    searchMarketplace: async args => {
      loadedIds.push(args.listing_id);
      loaded = true;
      return { listings: [vehicle] };
    },
    validateSource: async () => true,
    fetchImpl: async (_, options) => {
      const body = JSON.parse(options.body);
      assert.ok(!inputs(body).includes(previousId));
      if (!loaded) return response([lookup()]);
      assert.ok(isForcedWeb(body));
      assert.match(inputs(body), /VITO/);
      return researched('70,000 ש״ח דומה למחירים מבוקשים שנמצאו. בדוק את הגרסה ואת היסטוריית הטיפולים.');
    },
  });
  assert.deepEqual(loadedIds, [currentId]);
  assert.match(answer, /70,000/);
  assert.doesNotMatch(answer, /מקרר קודם|11111111/);
});

test('the exact appraisal reference wins over the provider selecting an unrelated listing', async () => {
  let loaded = false;
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test', question: appraisal(currentId),
    searchMarketplace: async args => {
      assert.equal(args.listing_id, currentId);
      loaded = true;
      return { listings: [vehicle] };
    },
    validateSource: async () => true,
    fetchImpl: async (_, options) => {
      const body = JSON.parse(options.body);
      if (!loaded) return response([lookup('wrong-provider-selection', previousId)]);
      assert.ok(isForcedWeb(body));
      assert.match(inputs(body), /VITO/);
      return researched('70,000 ש״ח דורש בירור של הגרסה המדויקת. בדוק את סוג הרישוי ואת היסטוריית הטיפולים.');
    },
  });
  assert.equal(loaded, true);
  assert.match(answer, /70,000/);
});

test('an explicit two-listing appraisal loads both requested listings before mandatory comparison', async () => {
  const ids = [previousId, currentId];
  const loadedIds = [];
  const choices = [];
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test',
    question: `השווה את המחיר של שתי המודעות האלה: ${ids.map(listingUrl).join(' ')}`,
    searchMarketplace: async args => {
      assert.equal(args.listing_id, ids[loadedIds.length]);
      loadedIds.push(args.listing_id);
      return { listings: [{ ...vehicle, id: args.listing_id, url: listingUrl(args.listing_id),
        title: args.listing_id === previousId ? 'רכב להשוואה ראשון' : 'רכב להשוואה שני' }] };
    },
    validateSource: async () => true,
    fetchImpl: async (_, options) => {
      const body = JSON.parse(options.body);
      choices.push(body.tool_choice);
      if (loadedIds.length < ids.length) {
        assert.deepEqual(body.tool_choice, { type: 'function', name: 'search_marketplace' },
          'each requested listing must be loaded before external price research');
        return response([lookup(`listing-${loadedIds.length}`, ids[loadedIds.length])]);
      }
      assert.ok(isForcedWeb(body));
      assert.match(inputs(body), /רכב להשוואה ראשון/);
      assert.match(inputs(body), /רכב להשוואה שני/);
      return researched(JSON.stringify({
        conclusion: 'לשתי המודעות מחיר מבוקש דומה של 70,000 ש״ח.',
        checks: ['בדוק את גרסת כל רכב.', 'בדוק את היסטוריית הטיפולים.'],
      }));
    },
  });
  assert.deepEqual(loadedIds, ids);
  assert.equal(choices.length, 3);
  assert.match(answer, /70,000/);
  assert.doesNotMatch(answer, /https?:|example\.test/);
});

test('an unavailable second appraisal listing prevents a verdict based only on the first', async () => {
  const ids = [previousId, currentId];
  const loadedIds = [];
  let requests = 0;
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test',
    question: `השווה את המחיר של שתי המודעות האלה: ${ids.map(listingUrl).join(' ')}`,
    searchMarketplace: async args => {
      assert.equal(args.listing_id, ids[loadedIds.length]);
      loadedIds.push(args.listing_id);
      return { listings: args.listing_id === previousId
        ? [{ ...vehicle, id: previousId, url: listingUrl(previousId) }] : [] };
    },
    fetchImpl: async (_, options) => {
      requests++;
      const body = JSON.parse(options.body);
      assert.ok(!isForcedWeb(body), 'missing comparison subjects must not authorize external research');
      if (loadedIds.length < ids.length)
        return response([lookup(`listing-${loadedIds.length}`, ids[loadedIds.length])]);
      return response([message('UNVERIFIED_TWO_LISTING_VERDICT המודעה השנייה משתלמת יותר.')]);
    },
  });
  assert.deepEqual(loadedIds, ids);
  assert.equal(requests, 2, 'stop after the requested second listing is confirmed unavailable');
  assert.match(answer, /השוואת מחיר/);
  assert.doesNotMatch(answer, /UNVERIFIED_TWO_LISTING_VERDICT|המודעה השנייה משתלמת|https?:/);
});

for (const question of [
  `בדוק רק את תמונות המודעה ${listingUrl(currentId)}`,
  `האם המחיר כדאי? בלי חיפוש באינטרנט, רק לפי המודעה ${listingUrl(currentId)}`,
  `השווה מחירים רק בבתשובה ${listingUrl(currentId)}`,
]) {
  test(`the comparison respects the requested scope: ${question.split('betshuva:')[0].trim()}`, async () => {
    let loaded = false;
    let requests = 0;
    const answer = await generateSafeInformationAnswer({
      apiKey: 'test', question,
      searchMarketplace: async () => { loaded = true; return { listings: [vehicle] }; },
      fetchImpl: async (_, options) => {
        const body = JSON.parse(options.body);
        requests++;
        assert.ok(!isForcedWeb(body), 'the user-limited scope must not force web research');
        if (!loaded) return response([lookup()]);
        return response([message('המחיר המבוקש הוא 70,000 ש״ח; אין כאן השוואת שוק.')]);
      },
    });
    assert.ok(requests <= 2);
    assert.match(answer, /70,000/);
  });
}

for (const [name, result] of [
  ['missing', { listings: [] }],
  ['denied', { error: 'MARKETPLACE_UNAVAILABLE', listings: [vehicle] }],
]) {
  test(`a ${name} listing cannot authorize invented facts, photos or a web comparison`, async () => {
    let lookedUp = false;
    const answer = await generateSafeInformationAnswer({
      apiKey: 'test', question: appraisal(currentId),
      searchMarketplace: async () => { lookedUp = true; return result; },
      loadMarketplaceImages: async () => assert.fail('unavailable listings cannot authorize photos'),
      fetchImpl: async (_, options) => {
        const body = JSON.parse(options.body);
        assert.ok(!isForcedWeb(body));
        if (!lookedUp) return response([lookup()]);
        return response([message('INVENTED_PRICE 70,000 ש״ח כדאי למרצדס VITO.')]);
      },
    });
    assert.equal(lookedUp, true);
    assert.doesNotMatch(answer, /INVENTED_PRICE|70,000|VITO|https?:|betshuva:/);
  });
}

for (const [name, failure] of [
  ['HTTP failure', async () => ({ ok: false, status: 503, json: async () => ({ error: { message: 'offline' } }) })],
  ['network timeout', async () => { throw Object.assign(new Error('timed out'), { name: 'TimeoutError' }); }],
]) {
  test(`a mandatory comparison ${name} retains verified listing facts`, async () => {
    let loaded = false;
    let attempted = false;
    const answer = await generateSafeInformationAnswer({
      apiKey: 'test', question: appraisal(currentId),
      searchMarketplace: async () => { loaded = true; return { listings: [vehicle] }; },
      fetchImpl: async (_, options) => {
        const body = JSON.parse(options.body);
        if (!loaded) return response([lookup()]);
        assert.ok(isForcedWeb(body));
        attempted = true;
        return failure();
      },
    });
    assert.equal(attempted, true);
    assert.match(answer, /70,000/);
    assert.match(answer, /השוואת מחיר/);
    assert.match(answer, /מנוע וגיר/);
    assert.doesNotMatch(answer, /https?:|קישורים|offline|timed out/);
  });
}

test('a completed comparison without usable evidence withholds its verdict and preserves known facts', async () => {
  let loaded = false;
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test', question: appraisal(currentId),
    searchMarketplace: async () => { loaded = true; return { listings: [vehicle] }; },
    fetchImpl: async (_, options) => {
      const body = JSON.parse(options.body);
      if (!loaded) return response([lookup()]);
      assert.ok(isForcedWeb(body));
      return response([
        { type: 'web_search_call', status: 'completed', action: { type: 'search', sources: [] } },
        message('UNVERIFIED_VERDICT המחיר כדאי כי מחיר השוק הוא 999,999 ש״ח.'),
      ]);
    },
  });
  assert.match(answer, /70,000/);
  assert.match(answer, /מנוע וגיר/);
  assert.doesNotMatch(answer, /UNVERIFIED_VERDICT|999,999|המחיר כדאי כי|https?:|קישורים/);
});

test('a listing search with a price filter remains a results list rather than a compulsory appraisal', async () => {
  let requests = 0;
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test', question: 'חפש מודעות למרצדס עד מחיר 80,000 ש״ח',
    searchMarketplace: async args => {
      assert.deepEqual(args, { terms: ['מרצדס'], max_price: 80000 });
      return { listings: [vehicle] };
    },
    fetchImpl: async (_, options) => {
      const body = JSON.parse(options.body);
      requests++;
      assert.equal(body.tool_choice, 'auto');
      assert.equal(body.text?.format, undefined);
      if (requests === 1) return response([{
        type: 'function_call', name: 'search_marketplace', call_id: 'price-filter',
        arguments: JSON.stringify({ terms: ['מרצדס'], max_price: 80000 }),
      }]);
      return response([message(`מרצדס VITO, מחיר מבוקש 70,000 ש״ח, רחובות.\n${listingUrl(currentId)}`)]);
    },
  });
  assert.equal(requests, 2);
  assert.match(answer, /VITO/);
  assert.match(answer, /70,000/);
  assert.ok(answer.includes(listingUrl(currentId)));
  assert.doesNotMatch(answer, /בדוק: 1\.|השוואת מחיר/);
});
