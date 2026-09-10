'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');

const {
  generateSafeInformationAnswer,
  localSafetyReply,
  redactSensitiveInput,
  safeCitationUrls,
  TEEN_SEARCH_DOMAINS,
} = require('../server/safe-information-ai');

function providerResponse(text, { annotations = [], webSearched = false, sources = [] } = {}) {
  return { ok: true, json: async () => ({
    usage: { input_tokens: 10, output_tokens: 20, total_tokens: 30 },
    output: [
      ...(webSearched ? [{ type: 'web_search_call', status: 'completed', action: { type: 'search', sources } }] : []),
      { type: 'message', role: 'assistant', content: [{ type: 'output_text', text, annotations }] },
    ],
  }) };
}

function annotatedResponse(claim, url = 'https://www.gov.il/test') {
  const marker = 'citeturn0search0';
  const text = `${claim}${marker}`;
  return providerResponse(text, { webSearched: true, annotations: [{
    type: 'url_citation', title: 'משרד ממשלתי', url,
    start_index: claim.length, end_index: text.length,
  }] });
}

test('halachic questions are referred to a rabbi without a provider call', async () => {
  let called = false;
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test', question: 'האם מותר לנסוע בשבת?',
    fetchImpl: async () => { called = true; },
  });
  assert.equal(called, false);
  assert.match(answer, /לשאול רב/);
});

test('emergency and secret questions stop locally', () => {
  assert.match(localSafetyReply('יש לו כאב חזק בחזה'), /מד״א 101/);
  assert.match(localSafetyReply('אשלח לך קוד אימות'), /אין לשלוח/);
});

test('sensitive identifiers are removed before sending to the provider', () => {
  const value = redactSensitiveInput('כרטיס 4580 1234 5678 9010 ותז 123456789');
  assert.doesNotMatch(value, /4580/);
  assert.doesNotMatch(value, /123456789/);
});

test('redaction preserves numeric listing UUIDs while removing nearby private numbers', () => {
  const listing = 'betshuva://listing/22222222-2222-4222-8222-222222222222';
  const value = redactSensitiveInput(
    `${listing}\nכרטיס 4580 1234 5678 9010 ותז 123456789 וטלפון 0501234567`);
  assert.ok(value.includes(listing));
  assert.doesNotMatch(value, /4580|123456789|0501234567/);
});

test('only unique HTTPS citations without credentials or blocked source domains are retained', () => {
  const citations = safeCitationUrls({ output: [{ content: [{
    annotations: [
      { type: 'url_citation', title: 'משרד ממשלתי', url: 'https://www.gov.il/test' },
      { type: 'url_citation', title: 'כפול', url: 'https://www.gov.il/test' },
      { type: 'url_citation', title: 'מעקב', url: 'https://www.gov.il/test?utm_source=chatgpt' },
      { type: 'url_citation', title: 'לא בטוח', url: 'http://example.com/' },
      { type: 'url_citation', title: 'סיסמה', url: 'https://user:secret@example.com/' },
      { type: 'url_citation', title: 'רשת חברתית', url: 'https://www.facebook.com/test' },
    ],
  }] }] });
  assert.deepEqual(citations, [{ title: 'משרד ממשלתי', url: 'https://www.gov.il/test' }]);
});

test('explicit internet searches enable live web search and force it on the first request', async () => {
  const validated = [];
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test-key', model: 'gpt-5.6-luna', userId: 'user-1',
    question: 'חפש באינטרנט מידע על שירות ממשלתי',
    validateSource: async url => { validated.push(url); return true; },
    fetchImpl: async (url, options) => {
      assert.equal(url, 'https://api.openai.com/v1/responses');
      const body = JSON.parse(options.body);
      assert.equal(body.model, 'gpt-5.6-luna');
      const webTool = body.tools.find(tool => tool.type === 'web_search');
      assert.ok(webTool);
      assert.equal(webTool.external_web_access, true);
      assert.equal(webTool.user_location.country, 'IL');
      assert.deepEqual(body.tool_choice, { type: 'web_search' });
      assert.ok(body.include.includes('web_search_call.action.sources'));
      assert.equal(body.store, false);
      return annotatedResponse('פרטי השירות המעודכנים.');
    },
  });
  assert.deepEqual(validated, ['https://www.gov.il/test']);
  assert.equal(answer, 'פרטי השירות המעודכנים. (https://www.gov.il/test)');
  assert.doesNotMatch(answer, /מושבת||/);
});

test('general questions offer web search without forcing it and discard invented plain URLs', async () => {
  let requested = false;
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test-key', question: 'מהו תחום האחריות של משרד התחבורה?',
    validateSource: async () => assert.fail('unannotated URLs must not be treated as sources'),
    fetchImpl: async (_, options) => {
      requested = true;
      const body = JSON.parse(options.body);
      assert.ok(body.tools.some(tool => tool.type === 'web_search'));
      assert.equal(body.tool_choice, 'auto');
      return providerResponse('הסבר כללי. https://invented.example.test/page');
    },
  });
  assert.equal(requested, true);
  assert.equal(answer, 'הסבר כללי.');
});

test('multiple citation offsets preserve Hebrew claims and only validated links', async () => {
  const marker1 = 'citeturn0search0';
  const marker2 = 'citeturn0search1';
  const claim1 = 'מידע ראשון. ';
  const claim2 = '\nמידע שני. ';
  const text = `${claim1}${marker1}${claim2}${marker2}\nhttps://invented.example.test/extra`;
  const secondStart = claim1.length + marker1.length + claim2.length;
  const annotations = [
    { type: 'url_citation', title: 'ראשון', url: 'https://www.gov.il/first?utm_source=chatgpt',
      start_index: claim1.length, end_index: claim1.length + marker1.length },
    { type: 'url_citation', title: 'שני', url: 'https://www.boi.org.il/second',
      start_index: secondStart, end_index: secondStart + marker2.length },
  ];
  const validated = [];
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test-key', question: 'חפש באינטרנט מידע כללי',
    validateSource: async url => { validated.push(url); return true; },
    fetchImpl: async () => providerResponse(text, { annotations, webSearched: true }),
  });
  assert.deepEqual(validated, ['https://www.gov.il/first', 'https://www.boi.org.il/second']);
  assert.match(answer, /מידע ראשון\.\s+\(https:\/\/www\.gov\.il\/first\)/);
  assert.match(answer, /מידע שני\.\s+\(https:\/\/www\.boi\.org\.il\/second\)/);
  assert.doesNotMatch(answer, /utm_source|invented||/);
});

test('plain links are accepted when the hosted search lists the same normalized consulted source', async () => {
  const validated = [];
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test-key', model: 'gpt-5.6-luna', question: 'חפש באינטרנט מידע על שירות ממשלתי',
    validateSource: async url => { validated.push(url); return true; },
    fetchImpl: async () => providerResponse(
      'פרטי השירות. [משרד ממשלתי](https://www.gov.il/test?utm_source=chatgpt)', {
        webSearched: true,
        sources: [{ type: 'url', title: 'משרד ממשלתי', url: 'https://www.gov.il/test' }],
      }),
  });
  assert.deepEqual(validated, ['https://www.gov.il/test']);
  assert.match(answer, /פרטי השירות/);
  assert.match(answer, /משרד ממשלתי \(https:\/\/www\.gov\.il\/test\)/);
  assert.doesNotMatch(answer, /utm_source|לא הצלחתי/);
});

test('a plain URL absent from consulted sources cannot substantiate researched claims', async () => {
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test-key', question: 'חפש באינטרנט מידע על שירות ממשלתי',
    validateSource: async () => assert.fail('an invented page must not reach source validation'),
    fetchImpl: async () => providerResponse('UNVERIFIED_CLAIM https://www.gov.il/invented', {
      webSearched: true,
      sources: [{ type: 'url', title: 'משרד ממשלתי', url: 'https://www.gov.il/test' }],
    }),
  });
  assert.match(answer, /לא הצלחתי לאמת/);
  assert.doesNotMatch(answer, /UNVERIFIED_CLAIM|https:/);
});

test('mixed eligible and blocked citation annotations withhold the researched answer', async () => {
  const validated = [];
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test-key', question: 'חפש באינטרנט מידע כללי',
    validateSource: async url => { validated.push(url); return true; },
    fetchImpl: async () => providerResponse('MIXED_UNVERIFIED_CLAIM', {
      webSearched: true,
      annotations: [
        { type: 'url_citation', title: 'ממשלתי', url: 'https://www.gov.il/test' },
        { type: 'url_citation', title: 'רשת חברתית', url: 'https://www.facebook.com/test' },
      ],
    }),
  });
  assert.deepEqual(validated, ['https://www.gov.il/test']);
  assert.match(answer, /לא הצלחתי לאמת/);
  assert.doesNotMatch(answer, /MIXED_UNVERIFIED_CLAIM|https:/);
});

for (const [description, validateSource] of [
  ['source validation rejects a link', async () => false],
  ['source validation throws', async () => { throw new Error('source unavailable'); }],
  ['source validation is unavailable', undefined],
]) {
  test(`researched claims are withheld when ${description}`, async () => {
    const answer = await generateSafeInformationAnswer({
      apiKey: 'test-key', question: 'חפש באינטרנט מידע על התחבורה', validateSource,
      fetchImpl: async () => annotatedResponse('UNVERIFIED_CLAIM מחיר הנסיעה הוא 50 שקלים.'),
    });
    assert.match(answer, /לא הצלחתי לאמת/);
    assert.doesNotMatch(answer, /UNVERIFIED_CLAIM|50|https:/);
  });
}

test('web search without an eligible citation returns safe unavailable text', async () => {
  for (const annotations of [[], [{
    type: 'url_citation', title: 'רשת חברתית', url: 'https://www.facebook.com/test',
  }]]) {
    const answer = await generateSafeInformationAnswer({
      apiKey: 'test-key', question: 'חפש באינטרנט מידע כללי',
      validateSource: async () => assert.fail('ineligible sources must not be fetched'),
      fetchImpl: async () => providerResponse('UNVERIFIED_CLAIM', { annotations, webSearched: true }),
    });
    assert.match(answer, /לא הצלחתי לאמת/);
    assert.doesNotMatch(answer, /UNVERIFIED_CLAIM/);
  }
});

test('teen internet search is restricted to allowed domains and exposes no marketplace tool', async () => {
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test-key', isTeen: true, question: 'חפש באינטרנט מידע על תחבורה ציבורית',
    searchMarketplace: async () => assert.fail('teens cannot search marketplace'),
    validateSource: async () => true,
    fetchImpl: async (_, options) => {
      const body = JSON.parse(options.body);
      const webTool = body.tools.find(tool => tool.type === 'web_search');
      assert.deepEqual(webTool.filters.allowed_domains, TEEN_SEARCH_DOMAINS);
      assert.ok(webTool.filters.allowed_domains.includes('gov.il'));
      assert.ok(!body.tools.some(tool => tool.name === 'search_marketplace'));
      return annotatedResponse('מידע רשמי על התחבורה.');
    },
  });
  assert.match(answer, /https:\/\/www\.gov\.il\/test/);
});

test('blocked historical secrets and stale external claims are omitted before the provider', async () => {
  const question = 'איפה אפשר לקבל מידע כללי?';
  const listing = 'betshuva://listing/11111111-1111-4111-8111-111111111111';
  let requested = false;
  await generateSafeInformationAnswer({
    apiKey: 'test-key', question,
    history: [
      { role: 'user', content: 'הסיסמה שלי היא FictionalSecret-Zebra' },
      { role: 'assistant', content: `OLD_EXTERNAL_PRICE 500 https://stale.example.test\n${listing}` },
      { role: 'user', content: question },
    ],
    fetchImpl: async (_, options) => {
      requested = true;
      const input = JSON.parse(options.body).input;
      const serialized = JSON.stringify(input);
      assert.doesNotMatch(serialized, /FictionalSecret|OLD_EXTERNAL_PRICE|stale\.example/);
      assert.ok(input.some(item => item.content === listing));
      assert.equal(input.filter(item => item.content === question).length, 1);
      return providerResponse('אפשר לברר בגוף הרלוונטי.');
    },
  });
  assert.equal(requested, true);
});

const previousListingUrl = 'betshuva://listing/11111111-1111-4111-8111-111111111111';
const currentListingUrl = 'betshuva://listing/22222222-2222-4222-8222-222222222222';
const listingOpinion = url =>
  `אשמח לחוות דעת על המודעה הזו: האם המחיר כדאי ומה חשוב לבדוק?\n${url}`;

function listingHistory() {
  return [
    { role: 'user', content: listingOpinion(previousListingUrl) },
    { role: 'assistant', content: `רכב קודם\n${previousListingUrl}` },
    { role: 'user', content: listingOpinion(currentListingUrl) },
    { role: 'assistant', content: `המקרר הנוכחי\n${currentListingUrl}` },
  ];
}

test('opening AI for a new listing excludes the previous listing and deduplicates the current request', async () => {
  const question = listingOpinion(currentListingUrl);
  for (const includesCurrentMessage of [false, true]) {
    const requests = [];
    const history = listingHistory().slice(0, 2);
    if (includesCurrentMessage) history.push({ role: 'user', content: question });
    await generateSafeInformationAnswer({
      apiKey: 'test-key', question, history,
      searchMarketplace: async () => ({ listings: [] }),
      fetchImpl: async (_, options) => {
        requests.push(JSON.parse(options.body).input);
        return providerResponse('בדיקת המודעה הנוכחית.');
      },
    });
    assert.deepEqual(requests, [[{ role: 'user', content: question }]]);
  }
});

test('a follow-up stays with the latest listing instead of reviving earlier listings', async () => {
  const question = 'ומה חשוב לבדוק לפני הקנייה?';
  await generateSafeInformationAnswer({
    apiKey: 'test-key', question,
    history: [...listingHistory(), { role: 'user', content: question }],
    fetchImpl: async (_, options) => {
      const input = JSON.parse(options.body).input;
      assert.doesNotMatch(JSON.stringify(input), /11111111|רכב קודם/);
      assert.ok(input.some(item => item.content === listingOpinion(currentListingUrl)));
      assert.ok(input.some(item => item.content === currentListingUrl));
      assert.equal(input.filter(item => item.content === question).length, 1);
      return providerResponse('יש לבדוק את מצב המקרר.');
    },
  });
});

test('an explicit comparison with the previous listing retains both listing references', async () => {
  for (const prompt of ['השווה למודעה הקודמת', 'מה עדיף ביחס לקודם?', 'compare with the previous listing']) {
    const requests = [];
    const question = `${prompt}\n${currentListingUrl}`;
    await generateSafeInformationAnswer({
      apiKey: 'test-key', question,
      history: listingHistory().slice(0, 2),
      searchMarketplace: async () => ({ listings: [] }),
      fetchImpl: async (_, options) => {
        requests.push(JSON.stringify(JSON.parse(options.body).input));
        return providerResponse('אפשר להשוות אחרי בדיקת שתי המודעות.');
      },
    });
    assert.equal(requests.length, 1);
    assert.ok(requests[0].includes(previousListingUrl));
    assert.ok(requests[0].includes(currentListingUrl));
  }
});

test('a follow-up after an explicit comparison preserves both sides of that comparison', async () => {
  const comparison = `תשווה למודעה הקודמת\n${currentListingUrl}`;
  await generateSafeInformationAnswer({
    apiKey: 'test-key', question: 'ומה לגבי האחריות?',
    history: [
      ...listingHistory().slice(0, 2),
      { role: 'user', content: comparison },
      { role: 'assistant', content: `${previousListingUrl}\n${currentListingUrl}` },
    ],
    fetchImpl: async (_, options) => {
      const input = JSON.stringify(JSON.parse(options.body).input);
      assert.ok(input.includes(previousListingUrl));
      assert.ok(input.includes(currentListingUrl));
      return providerResponse('יש לברר אחריות עבור שתי המודעות.');
    },
  });
});

test('starting another listing clears an earlier explicit comparison', async () => {
  const requests = [];
  const nextUrl = 'betshuva://listing/33333333-3333-4333-8333-333333333333';
  const question = listingOpinion(nextUrl);
  await generateSafeInformationAnswer({
    apiKey: 'test-key', question,
    history: [
      ...listingHistory().slice(0, 2),
      { role: 'user', content: `תשווה למודעה הקודמת\n${currentListingUrl}` },
      { role: 'assistant', content: `${previousListingUrl}\n${currentListingUrl}` },
    ],
    searchMarketplace: async () => ({ listings: [] }),
    fetchImpl: async (_, options) => {
      requests.push(JSON.parse(options.body).input);
      return providerResponse('בדיקת המודעה החדשה.');
    },
  });
  assert.deepEqual(requests, [[{ role: 'user', content: question }]]);
});

test('market-price comparisons for a new listing do not import an unrelated earlier listing', async () => {
  for (const prompt of ['השווה למחירי השוק', 'השוואת מחיר למודעות דומות', 'compare with current market prices']) {
    const requests = [];
    const question = `${prompt}\n${currentListingUrl}`;
    await generateSafeInformationAnswer({
      apiKey: 'test-key', question,
      history: [...listingHistory().slice(0, 2), { role: 'user', content: question }],
      searchMarketplace: async () => ({ listings: [] }),
      fetchImpl: async (_, options) => {
        requests.push(JSON.parse(options.body).input);
        return providerResponse('יש לבדוק מודעות דומות למקרר.');
      },
    });
    assert.deepEqual(requests, [[{ role: 'user', content: question }]]);
  }
});

test('a comparison with explicit listing links uses the supplied subjects', async () => {
  const requests = [];
  const otherUrl = 'betshuva://listing/44444444-4444-4444-8444-444444444444';
  const question = `השווה בין המודעות האלה\n${currentListingUrl}\n${otherUrl}`;
  await generateSafeInformationAnswer({
    apiKey: 'test-key', question,
    history: listingHistory().slice(0, 2),
    searchMarketplace: async () => ({ listings: [] }),
    fetchImpl: async (_, options) => {
      requests.push(JSON.parse(options.body).input);
      return providerResponse('השוואת שתי המודעות שבבקשה.');
    },
  });
  assert.deepEqual(requests, [[{ role: 'user', content: question }]]);
});

test('an already mixed assistant answer cannot revive an older listing in a follow-up', async () => {
  const question = 'כמה מקום צריך בשביל המוצר?';
  const history = listingHistory();
  history.at(-1).content = `תשובה שהתערבבה\n${previousListingUrl}\n${currentListingUrl}`;
  history.push({ role: 'user', content: question });
  await generateSafeInformationAnswer({
    apiKey: 'test-key', question, history,
    fetchImpl: async (_, options) => {
      const input = JSON.stringify(JSON.parse(options.body).input);
      assert.ok(input.includes(currentListingUrl));
      assert.ok(!input.includes(previousListingUrl));
      return providerResponse('צריך לברר את מידות המקרר.');
    },
  });
});

test('questions about previous owners stay on the current listing', async () => {
  for (const question of ['מה צריך לבדוק אצל הבעלים הקודמים?', 'What should I ask the previous owner?']) {
    await generateSafeInformationAnswer({
      apiKey: 'test-key', question,
      history: [...listingHistory(), { role: 'user', content: question }],
      fetchImpl: async (_, options) => {
        const input = JSON.stringify(JSON.parse(options.body).input);
        assert.ok(input.includes(currentListingUrl));
        assert.ok(!input.includes(previousListingUrl));
        return providerResponse('אפשר לברר את היסטוריית הטיפולים.');
      },
    });
  }
});
