'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { generateSafeInformationAnswer } = require('../server/safe-information-ai');

const firstId = '11111111-1111-4111-8111-111111111111';
const secondId = '22222222-2222-4222-8222-222222222222';
const unrelatedId = '33333333-3333-4333-8333-333333333333';
const listingUrl = id => `betshuva://listing/${id}`;
const listing = id => ({ id, url: listingUrl(id), title: 'מקרר', price: 500, has_images: true });
const photo = (id, index = 0) => ({
  listing_id: id,
  image_url: `data:image/jpeg;base64,${Buffer.from(`${id}/${index}`).toString('base64')}`,
});
const response = output => ({ ok: true, json: async () => ({ output }) });
const message = (text, annotations = []) => ({
  type: 'message', role: 'assistant', content: [{ type: 'output_text', text, annotations }],
});
const searchCall = (callId, args = {}) => ({
  type: 'function_call', name: 'search_marketplace', call_id: callId,
  arguments: JSON.stringify(args),
});
const searchCompleted = sources => ({
  type: 'web_search_call', status: 'completed', action: { type: 'search', sources },
});
const imagesIn = input => input.flatMap(item => Array.isArray(item.content)
  ? item.content.filter(part => part.type === 'input_image') : []);

test('explicit internet listing research validates sources without displaying their links or a footer', async () => {
  const sourceUrl = 'https://example.test/listing/fridge';
  const text = `מקרר מוצע ב־500 ש״ח (${sourceUrl}).\n\nמקורות:\n- חנות לדוגמה: ${sourceUrl}\nנבדק בתאריך: 09/09/2026`;
  const validated = [];
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test', question: 'חפש באינטרנט מודעות למקרר',
    searchMarketplace: async () => assert.fail('provider requested no internal search'),
    validateSource: async url => { validated.push(url); return true; },
    fetchImpl: async (_, options) => {
      const body = JSON.parse(options.body);
      assert.ok(body.tools.some(tool => tool.name === 'search_marketplace'));
      assert.ok(body.tools.some(tool => tool.type === 'web_search'));
      assert.deepEqual(body.tool_choice, { type: 'web_search' });
      return response([
        searchCompleted([{ url: sourceUrl, title: 'חנות לדוגמה' }]), message(text),
      ]);
    },
  });
  assert.deepEqual(validated, [sourceUrl]);
  assert.match(answer, /מקרר מוצע ב־500/);
  assert.doesNotMatch(answer, /https?:|example\.test|מקורות|חנות לדוגמה|נבדק בתאריך|09\/09\/2026/);
});

test('a brief listing answer with consulted sources and no visible links still validates its evidence', async () => {
  const sourceUrl = 'https://manufacturer.example.test/fridge';
  const validated = [];
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test', question: 'בחן את המודעה: האם המחיר כדאי ומה חשוב לבדוק?',
    validateSource: async url => { validated.push(url); return true; },
    fetchImpl: async () => response([
      searchCompleted([{ url: sourceUrl, title: 'יצרן לדוגמה' }]),
      message('מחיר חדש שנמצא הוא 1,200 ש״ח. לפני קנייה יש לבדוק קירור ואטמים.'),
    ]),
  });
  assert.deepEqual(validated, [sourceUrl]);
  assert.match(answer, /1,200/);
  assert.match(answer, /קירור ואטמים/);
  assert.doesNotMatch(answer, /https?:|example\.test|יצרן לדוגמה|מקורות|לא הצלחתי לאמת/);
  assert.ok(answer.length <= 600);
});

test('consulted source metadata does not excuse an invented plain link in a listing answer', async () => {
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test', question: 'בדוק את המחיר במודעה',
    validateSource: async () => assert.fail('an invented source must not be validated'),
    fetchImpl: async () => response([
      searchCompleted([{ url: 'https://manufacturer.example.test/fridge', title: 'יצרן' }]),
      message('UNVERIFIED_PRICE 9999 https://invented.example.test/fridge'),
    ]),
  });
  assert.doesNotMatch(answer, /UNVERIFIED_PRICE|9999|https?:|קישורים|מקורות/);
  assert.match(answer, /אין כרגע מספיק נתונים/);
});

test('consulted sources cannot replace a rejected citation in a listing answer', async () => {
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test', question: 'בדוק את המחיר במודעה',
    validateSource: async () => assert.fail('a blocked citation must not be replaced with unrelated evidence'),
    fetchImpl: async () => response([
      searchCompleted([{ url: 'https://manufacturer.example.test/fridge', title: 'יצרן' }]),
      message('UNVERIFIED_PRICE 9999', [{
        type: 'url_citation', url: 'https://www.facebook.com/fridge', title: 'רשת חברתית',
      }]),
    ]),
  });
  assert.doesNotMatch(answer, /UNVERIFIED_PRICE|9999|https?:|קישורים|מקורות/);
  assert.match(answer, /אין כרגע מספיק נתונים/);
});

test('internal listing results require web research for current price and product comparisons', async () => {
  const sourceUrl = 'https://manufacturer.example.test/fridge/specs';
  let requests = 0;
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test', question: `בדוק את המודעה והשווה מחיר ומפרט ${listingUrl(firstId)}`,
    searchMarketplace: async () => ({ listings: [listing(firstId)] }),
    validateSource: async url => { assert.equal(url, sourceUrl); return true; },
    fetchImpl: async (_, options) => {
      const body = JSON.parse(options.body);
      assert.ok(body.tools.some(tool => tool.name === 'search_marketplace'));
      assert.ok(body.tools.some(tool => tool.type === 'web_search'));
      if (++requests === 1) {
        assert.deepEqual(body.tool_choice, { type: 'function', name: 'search_marketplace' });
        return response([searchCall('internal', { listing_id: firstId })]);
      }
      assert.deepEqual(body.tool_choice, { type: 'web_search' });
      assert.equal(JSON.parse(body.input.find(item => item.type === 'function_call_output').output).listings[0].id, firstId);
      const claim = `המחיר המבוקש במודעה הוא 500 ש״ח.\n${listingUrl(firstId)}\nהמפרט באתר היצרן (${sourceUrl}).`;
      return response([
        searchCompleted([{ url: sourceUrl, title: 'יצרן' }]),
        message(`${claim}\nמקורות: ${sourceUrl}`),
      ]);
    },
  });
  assert.equal(requests, 2);
  assert.ok(answer.includes(listingUrl(firstId)));
  assert.match(answer, /500/);
  assert.doesNotMatch(answer, /https?:|manufacturer\.example\.test|מקורות:/);
});

test('listing assessments hide website names, domains and every external citation form while keeping product facts', async () => {
  const sourceUrl = 'https://zap.example.test/fridge';
  const secondSourceUrl = 'https://ikea.example.test/fridge';
  const marker = '【מקור 1】';
  const providerText = `המחיר המבוקש הוא 500 ש״ח. לפי אתר Zap המחיר החדש הוא 1,200 ש״ח [בדיקה](${sourceUrl}). באתר IKEA מצוין עומק של 60 ס״מ. בתמונה נראית שריטה בדלת. ${marker}\nמידע נוסף: ${secondSourceUrl}\nwww.catalog.example.test\nמקורות:\nZap: ${sourceUrl}\nנבדק בתאריך: 09/09/2026`;
  const validated = [];
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test', question: 'בחן את המודעה: האם המחיר כדאי ומה חשוב לבדוק?',
    validateSource: async url => { validated.push(url); return true; },
    fetchImpl: async () => response([
      searchCompleted([
        { url: sourceUrl, title: 'Zap' },
        { url: secondSourceUrl, title: 'IKEA' },
      ]),
      message(providerText, [{
        type: 'url_citation', url: sourceUrl, title: 'Zap',
        start_index: providerText.indexOf(marker),
        end_index: providerText.indexOf(marker) + marker.length,
      }, {
        type: 'url_citation', url: secondSourceUrl, title: 'IKEA',
      }]),
    ]),
  });
  assert.deepEqual(validated.sort(), [sourceUrl, secondSourceUrl].sort());
  assert.match(answer, /500/);
  assert.match(answer, /1,200/);
  assert.match(answer, /60/);
  assert.match(answer, /שריטה בדלת/);
  assert.doesNotMatch(answer, /https?:|www\.|example\.test|Zap|IKEA|מקורות|נבדק בתאריך|【|cite|\]\(/i);
});

test('a new general web question displays validated citation links even after discussing a listing', async () => {
  const sourceUrl = 'https://rail.example.test/stations';
  const validated = [];
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test', question: 'בדוק באינטרנט את שעות תחנת הרכבת',
    history: [
      { role: 'user', content: `בדוק את המודעה ${listingUrl(firstId)}` },
      { role: 'assistant', content: `המחיר 500 ש״ח.\n${listingUrl(firstId)}` },
    ],
    validateSource: async url => { validated.push(url); return true; },
    fetchImpl: async () => response([
      searchCompleted([{ url: sourceUrl, title: 'רכבת' }]),
      message(`התחנה נפתחת בשעה 06:00. ${sourceUrl}`),
    ]),
  });
  assert.deepEqual(validated, [sourceUrl]);
  assert.match(answer, /06:00/);
  assert.ok(answer.includes(sourceUrl));
});

test('an overlong listing assessment is bounded while preserving its opening recommendation and whole internal link', async () => {
  let requests = 0;
  const opening = `המחיר 500 ש״ח סביר אם המקרר תקין. בתמונה נראית שריטה בדלת. בדקו קירור ואטמים לפני קנייה.\n${listingUrl(firstId)}`;
  const verboseText = `${opening}\n${'פרטים נוספים על אפשרויות הבדיקה והשוואת מחירים לפני קניית מוצר משומש. '.repeat(25)}`;
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test', question: `בדוק את המודעה ${listingUrl(firstId)}`,
    searchMarketplace: async () => ({ listings: [listing(firstId)] }),
    validateSource: async () => true,
    fetchImpl: async () => ++requests === 1
      ? response([searchCall('one', { listing_id: firstId })])
      : response([searchCompleted([{ url: 'https://comparison.example.test/fridge', title: 'השוואת מקררים' }]),
        message(verboseText)]),
  });
  assert.equal(requests, 2);
  assert.match(answer, /500/);
  assert.match(answer, /שריטה בדלת/);
  assert.match(answer, /קירור ואטמים/);
  assert.ok(answer.includes(listingUrl(firstId)));
  assert.ok(answer.length <= 600, `expected at most 600 characters; received ${answer.length}`);
  assert.ok(answer.split(/\s+/).length <= 80, 'listing answer exceeds 80 words');
});

test('a price follow-up reloads the listing, stays brief and hides websites', async () => {
  const sourceUrl = 'https://zap.example.test/fridge';
  const validated = [];
  let requests = 0;
  const providerText = `לפי אתר Zap המחיר 500 ש״ח סביר למקרר תקין (${sourceUrl}).\n${'כדאי להשוות מחיר ומצב לפני קניית מוצר משומש. '.repeat(25)}`;
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test', question: 'ומה המחיר?',
    history: [
      { role: 'user', content: `בדוק את המודעה ${listingUrl(firstId)}` },
      { role: 'assistant', content: `בתמונה מקרר לבן.\n${listingUrl(firstId)}` },
    ],
    searchMarketplace: async args => {
      assert.equal(args.listing_id, firstId);
      return { listings: [listing(firstId)] };
    },
    validateSource: async url => { validated.push(url); return true; },
    fetchImpl: async () => ++requests === 1
      ? response([searchCall('follow-up', { listing_id: firstId })])
      : response([
        searchCompleted([{ url: sourceUrl, title: 'Zap' }]),
        message(providerText),
      ]),
  });
  assert.equal(requests, 2);
  assert.deepEqual(validated, [sourceUrl]);
  assert.match(answer, /500/);
  assert.match(answer, /תקין/);
  assert.doesNotMatch(answer, /https?:|example\.test|Zap|אתר/i);
  assert.ok(answer.length <= 800);
  assert.ok(answer.split(/\s+/).length <= 90);
});

for (const [name, validateSource] of [
  ['rejects the listing URL', async () => false],
  ['cannot complete', async () => { throw new Error('offline'); }],
]) {
  test(`internet listing claims are withheld when link validation ${name}`, async () => {
    const sourceUrl = 'https://example.test/listing/fridge';
    const answer = await generateSafeInformationAnswer({
      apiKey: 'test', question: 'חפש באינטרנט מודעות למקרר', validateSource,
      fetchImpl: async () => response([
        searchCompleted([{ url: sourceUrl, title: 'מקרר' }]),
        message(`UNVERIFIED_PRICE 500 ${sourceUrl}`),
      ]),
    });
    assert.match(answer, /אין כרגע מספיק נתונים/);
    assert.doesNotMatch(answer, /UNVERIFIED_PRICE|500|https?:|קישורים|מקורות/);
    assert.ok(answer.length <= 600);
  });

  test(`verified internal listing details survive when web validation ${name}`, async () => {
    let requests = 0;
    const sourceUrl = 'https://example.test/listing/fridge';
    const validated = [];
    const answer = await generateSafeInformationAnswer({
      apiKey: 'test', question: `בדוק את המודעה ${listingUrl(firstId)}`,
      searchMarketplace: async () => ({ listings: [listing(firstId)] }),
      validateSource: async url => { validated.push(url); return validateSource(url); },
      fetchImpl: async () => ++requests === 1
        ? response([searchCall('listing', { listing_id: firstId })])
        : response([
          searchCompleted([{ url: sourceUrl, title: 'חנות לדוגמה' }]),
          message(`UNVERIFIED_PRICE 9999 ש״ח. בתמונה נראית שריטה בדלת. ${sourceUrl}`),
        ]),
    });
    assert.equal(requests, 2);
    assert.deepEqual(validated, [sourceUrl]);
    assert.match(answer, /מקרר/);
    assert.match(answer, /500/);
    assert.match(answer, /השוואת מחיר/);
    assert.doesNotMatch(answer, /UNVERIFIED_PRICE|9999|שריטה|https?:|example\.test|חנות לדוגמה|קישורים|מקורות/);
    assert.ok(answer.length <= 600);
  });
}

test('a listing fallback uses only the newly opened listing even when the tool returned previous results', async () => {
  let requests = 0;
  const sourceUrl = 'https://example.test/listing/fridge';
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test', question: `בדוק את המודעה ${listingUrl(firstId)}`,
    history: [{ role: 'user', content: `בדוק את המודעה ${listingUrl(secondId)}` }],
    searchMarketplace: async () => ({ listings: [
      { ...listing(secondId), title: 'שולחן', price: 222 },
      listing(firstId),
    ] }),
    validateSource: async () => false,
    fetchImpl: async () => ++requests === 1
      ? response([searchCall('listing', { listing_id: firstId })])
      : response([
        searchCompleted([{ url: sourceUrl, title: 'חנות לדוגמה' }]),
        message(`UNVERIFIED_PRICE 9999 ${sourceUrl}`),
      ]),
  });
  assert.match(answer, /מקרר/);
  assert.match(answer, /500/);
  assert.ok(!answer.includes(listingUrl(secondId)));
  assert.doesNotMatch(answer, /שולחן|222|UNVERIFIED_PRICE|9999|https?:/);
});

test('a rejected listing lookup cannot supply fallback listing facts', async () => {
  let requests = 0;
  const sourceUrl = 'https://example.test/listing/fridge';
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test', question: `בדוק את המודעה ${listingUrl(firstId)}`,
    searchMarketplace: async () => ({ error: 'MARKETPLACE_UNAVAILABLE', listings: [listing(firstId)] }),
    validateSource: async () => false,
    fetchImpl: async () => ++requests === 1
      ? response([searchCall('listing', { listing_id: firstId })])
      : response([
        searchCompleted([{ url: sourceUrl, title: 'חנות לדוגמה' }]),
        message(`UNVERIFIED_PRICE 9999 ${sourceUrl}`),
      ]),
  });
  assert.match(answer, /אין כרגע מספיק נתונים/);
  assert.doesNotMatch(answer, /500|UNVERIFIED_PRICE|9999|https?:|betshuva:|קישורים|מקורות/);
});

test('general web answers still require citations when consulted sources alone are returned', async () => {
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test', question: 'בדוק באינטרנט את שעות תחנת הרכבת',
    validateSource: async () => assert.fail('consulted sources alone are a listing-only fallback'),
    fetchImpl: async () => response([
      searchCompleted([{ url: 'https://rail.example.test/stations', title: 'רכבת' }]),
      message('UNVERIFIED_HOURS 06:00'),
    ]),
  });
  assert.match(answer, /לא הצלחתי לאמת/);
  assert.doesNotMatch(answer, /UNVERIFIED_HOURS|06:00/);
});

test('listing photos are mapped to authorized listing links and follow all function outputs', async () => {
  let requests = 0;
  const loadedIds = [];
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test', question: 'השווה את תמונות המודעות למקררים',
    searchMarketplace: async args => ({ listings: [listing(args.listing_id)] }),
    loadMarketplaceImages: async ids => {
      loadedIds.push(...ids);
      return [...ids.map(id => photo(id)), photo(unrelatedId)];
    },
    fetchImpl: async (_, options) => {
      const body = JSON.parse(options.body);
      if (++requests === 1) return response([
        searchCall('first', { listing_id: firstId }),
        searchCall('second', { listing_id: secondId }),
      ]);
      const imageMessages = body.input.filter(item => Array.isArray(item.content) &&
        item.content.some(part => part.type === 'input_image'));
      const images = imagesIn(body.input);
      assert.deepEqual(images.map(item => item.image_url).sort(), [photo(firstId).image_url, photo(secondId).image_url].sort());
      assert.ok(images.every(item => item.detail === 'auto'));
      const lastOutput = body.input.findLastIndex(item => item.type === 'function_call_output');
      assert.equal(body.input.filter(item => item.type === 'function_call_output').length, 2);
      assert.ok(imageMessages.every(item => item.role === 'user' && body.input.indexOf(item) > lastOutput));
      for (const id of [firstId, secondId]) {
        const containingMessage = imageMessages.find(item => item.content.some(part => part.image_url === photo(id).image_url));
        const photoIndex = containingMessage.content.findIndex(part => part.image_url === photo(id).image_url);
        assert.equal(containingMessage.content[photoIndex - 1]?.type, 'input_text');
        assert.ok(containingMessage.content[photoIndex - 1].text.includes(listingUrl(id)));
      }
      return response([message('בתמונה של המקרר הראשון נראית שריטה בדלת.')]);
    },
  });
  assert.equal(requests, 2);
  assert.deepEqual([...new Set(loadedIds)].sort(), [firstId, secondId].sort());
  assert.match(answer, /שריטה בדלת/);
});

test('repeated marketplace calls do not resend the same photo and cap image inputs at eight', async () => {
  let requests = 0;
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test', question: 'בדוק תמונות של מודעות למקררים',
    searchMarketplace: async () => ({ listings: [listing(firstId), listing(secondId)] }),
    loadMarketplaceImages: async ids => ids.flatMap(id =>
      Array.from({ length: 10 }, (_, index) => photo(id, index))),
    fetchImpl: async (_, options) => {
      const body = JSON.parse(options.body);
      const images = imagesIn(body.input);
      if (++requests === 1) {
        assert.equal(images.length, 0);
        return response([searchCall('first')]);
      }
      assert.equal(images.length, 8);
      assert.equal(new Set(images.map(item => item.image_url)).size, images.length);
      if (requests === 2) return response([searchCall('repeated')]);
      return response([message('אפשר להתרשם מהמראה בתמונות, אך לא לבדוק תקינות מלאה.')]);
    },
  });
  assert.equal(requests, 3);
  assert.match(answer, /תקינות מלאה/);
});

test('unavailable listing photos preserve the successful textual listing result', async () => {
  let requests = 0;
  let imageLoads = 0;
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test', question: `בדוק את תמונת המודעה ${listingUrl(firstId)}`,
    searchMarketplace: async () => ({ listings: [listing(firstId)] }),
    loadMarketplaceImages: async ids => {
      assert.deepEqual(ids, [firstId]);
      imageLoads++;
      throw new Error('photo unavailable');
    },
    fetchImpl: async (_, options) => {
      const body = JSON.parse(options.body);
      if (++requests === 1) return response([searchCall('listing', { listing_id: firstId })]);
      assert.equal(imagesIn(body.input).length, 0);
      assert.equal(JSON.parse(body.input.find(item => item.type === 'function_call_output').output).listings[0].id, firstId);
      return response([message(`המחיר במודעה הוא 500 ש״ח; התמונות לא זמינות לבדיקה.\n${listingUrl(firstId)}`)]);
    },
  });
  assert.equal(imageLoads, 1);
  assert.ok(answer.includes(listingUrl(firstId)));
  assert.match(answer, /500|התמונות לא זמינות/);
});

test('teen requests cannot load marketplace photos even if the provider requests the hidden tool', async () => {
  let requests = 0;
  let marketplaceCalls = 0;
  let imageLoads = 0;
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test', isTeen: true, question: `בדוק תמונה ${listingUrl(firstId)}`,
    searchMarketplace: async () => { marketplaceCalls++; return { listings: [listing(firstId)] }; },
    loadMarketplaceImages: async () => { imageLoads++; return [photo(firstId)]; },
    fetchImpl: async (_, options) => {
      const body = JSON.parse(options.body);
      assert.ok(!body.tools.some(tool => tool.name === 'search_marketplace'));
      assert.equal(imagesIn(body.input).length, 0);
      if (++requests === 1) return response([searchCall('forbidden', { listing_id: firstId })]);
      assert.equal(JSON.parse(body.input.at(-1).output).error, 'SEARCH_FAILED');
      return response([message('המודעות אינן זמינות לחשבון זה.')]);
    },
  });
  assert.equal(requests, 2);
  assert.equal(marketplaceCalls, 0);
  assert.equal(imageLoads, 0);
  assert.match(answer, /אינן זמינות/);
});

for (const [name, result] of [
  ['empty results', { listings: [] }],
  ['denied results', { error: 'MARKETPLACE_UNAVAILABLE', listings: [listing(firstId)] }],
]) {
  test(`marketplace ${name} do not authorize image loading`, async () => {
    let requests = 0;
    let imageLoads = 0;
    await generateSafeInformationAnswer({
      apiKey: 'test', question: 'תמונות של מודעות למקרר',
      searchMarketplace: async () => result,
      loadMarketplaceImages: async () => { imageLoads++; return [photo(firstId)]; },
      fetchImpl: async (_, options) => {
        const body = JSON.parse(options.body);
        assert.equal(imagesIn(body.input).length, 0);
        if (++requests === 1) return response([searchCall('empty')]);
        return response([message('אין כרגע תוצאות שאפשר להציג.')]);
      },
    });
    assert.equal(requests, 2);
    assert.equal(imageLoads, 0);
  });
}

test('an exact new listing limits image loading to that listing instead of the previous topic', async () => {
  let requests = 0;
  const loadedIds = [];
  await generateSafeInformationAnswer({
    apiKey: 'test', question: `בדוק את תמונות המודעה הזו ${listingUrl(secondId)}`,
    history: [
      { role: 'user', content: `בדוק את המודעה ${listingUrl(firstId)}` },
      { role: 'assistant', content: listingUrl(firstId) },
    ],
    searchMarketplace: async args => {
      assert.equal(args.listing_id, secondId);
      return { listings: [listing(secondId), listing(unrelatedId)] };
    },
    loadMarketplaceImages: async ids => { loadedIds.push(...ids); return ids.map(id => photo(id)); },
    fetchImpl: async (_, options) => {
      const body = JSON.parse(options.body);
      assert.ok(!JSON.stringify(body.input).includes(firstId));
      if (++requests === 1) return response([searchCall('current', { listing_id: secondId })]);
      assert.deepEqual(imagesIn(body.input).map(item => item.image_url), [photo(secondId).image_url]);
      return response([message('בתמונה של המודעה הנוכחית נראה מקרר לבן.')]);
    },
  });
  assert.deepEqual(loadedIds, [secondId]);
});

test('a broad new listing search never preloads images from previous topics', async () => {
  let requests = 0;
  const loadedIds = [];
  await generateSafeInformationAnswer({
    apiKey: 'test', question: 'חפש מודעות לאופניים',
    history: [
      { role: 'user', content: `בדוק את המודעה למקרר ${listingUrl(firstId)}` },
      { role: 'assistant', content: listingUrl(firstId) },
    ],
    searchMarketplace: async args => {
      assert.deepEqual(args.terms, ['אופניים']);
      return { listings: [{ ...listing(secondId), title: 'אופניים' }] };
    },
    loadMarketplaceImages: async ids => { loadedIds.push(...ids); return ids.map(id => photo(id)); },
    fetchImpl: async (_, options) => {
      const body = JSON.parse(options.body);
      if (++requests === 1) {
        assert.equal(imagesIn(body.input).length, 0);
        assert.deepEqual(loadedIds, []);
        return response([searchCall('bikes', { terms: ['אופניים'] })]);
      }
      assert.deepEqual(imagesIn(body.input).map(item => item.image_url), [photo(secondId).image_url]);
      return response([message(`נמצאו אופניים.\n${listingUrl(secondId)}`)]);
    },
  });
  assert.deepEqual(loadedIds, [secondId]);
});

test('a singular source label between listing results does not remove the following listing', async () => {
  let requests = 0;
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test', question: 'מצא מודעות למקררים',
    searchMarketplace: async () => ({ listings: [listing(firstId), listing(secondId)] }),
    fetchImpl: async () => ++requests === 1
      ? response([searchCall('both')])
      : response([message(`מקרר ראשון\n${listingUrl(firstId)}\nמקור: בתשובה\n\nמקרר שני\n${listingUrl(secondId)}\nSource: Betshuva`)]),
  });
  assert.ok(answer.includes(listingUrl(firstId)));
  assert.ok(answer.includes(listingUrl(secondId)));
  assert.match(answer, /מקרר שני/);
  assert.doesNotMatch(answer, /מקור:|Source:/);
});

test('a manufacturer and model survive a matching product-page source title', async () => {
  const sourceUrl = 'https://www.samsung.com/il/refrigerators/';
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test', question: 'בדוק את המחיר במודעה', validateSource: async () => true,
    fetchImpl: async () => response([
      searchCompleted([{ url: sourceUrl, title: 'Samsung RB33' }]),
      message(`מקרר Samsung RB33 ב־1,000 ש״ח. יש לבדוק קירור ואטמים. (${sourceUrl})`),
    ]),
  });
  assert.match(answer, /Samsung RB33/);
  assert.match(answer, /1,000/);
  assert.doesNotMatch(answer, /https:|\(\s*\)/);
});

test('multiword Hebrew website attribution and linked site labels are hidden without losing the comparison', async () => {
  const sourceUrl = 'https://www.payngo.co.il/example';
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test', question: 'השווה את המחיר במודעה', validateSource: async () => true,
    fetchImpl: async () => response([
      searchCompleted([{ url: sourceUrl, title: 'מחסני חשמל' }]),
      message(`לפי אתר מחסני חשמל המחיר החדש הוא 1,200 ש״ח. לפי מחסני חשמל האחריות היא שנה. [מחסני חשמל](${sourceUrl})`),
    ]),
  });
  assert.match(answer, /1,200/);
  assert.match(answer, /האחריות היא שנה/);
  assert.doesNotMatch(answer, /מחסני|חשמל|https:|payngo/);
});

test('a new named-topic price question after a listing keeps ordinary web citations', async () => {
  const sourceUrl = 'https://www.rail.co.il/fares';
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test', question: 'מה המחיר של כרטיס רכבת?',
    history: [{ role: 'user', content: `בדוק את המודעה ${listingUrl(firstId)}` }],
    validateSource: async () => true,
    fetchImpl: async () => response([
      searchCompleted([{ url: sourceUrl, title: 'רכבת ישראל' }]),
      message(`תעריף הנסיעה תלוי במסלול. ${sourceUrl}`),
    ]),
  });
  assert.ok(answer.includes(sourceUrl));
});
