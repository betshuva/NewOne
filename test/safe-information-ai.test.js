'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');

const {
  generateSafeInformationAnswer,
  localSafetyReply,
  redactSensitiveInput,
  safeCitationUrls,
} = require('../server/safe-information-ai');

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

test('only unique HTTPS citation annotations are retained', () => {
  const citations = safeCitationUrls({ output: [{ content: [{
    annotations: [
      { type: 'url_citation', title: 'משרד ממשלתי', url: 'https://www.gov.il/test' },
      { type: 'url_citation', title: 'כפול', url: 'https://www.gov.il/test' },
      { type: 'url_citation', title: 'לא בטוח', url: 'http://example.com/' },
    ],
  }] }] });
  assert.deepEqual(citations, [{ title: 'משרד ממשלתי', url: 'https://www.gov.il/test' }]);
});

test('temporary pause removes web tools, historical external claims and citation fetching', async () => {
  let validations = 0;
  const answer = await generateSafeInformationAnswer({
    apiKey: 'test-key', model: 'gpt-5.6-luna', userId: 'user-1',
    question: 'מה המידע הרשמי?',
    history: [{ role: 'assistant', content: 'OLD_EXTERNAL_PRICE 500 https://example.com' }, { role: 'user', content: 'מה המידע הרשמי?' }],
    validateSource: async () => { validations++; return true; },
    fetchImpl: async (url, options) => {
      assert.equal(url, 'https://api.openai.com/v1/responses');
      const body = JSON.parse(options.body);
      assert.deepEqual(body.tools, []);
      assert.ok(body.input.every(item => !item.content.includes('OLD_EXTERNAL_PRICE')));
      assert.equal(body.store, false);
      return { ok: true, json: async () => ({
        usage: { input_tokens: 10, output_tokens: 20, total_tokens: 30 },
        output: [{ content: [{ type: 'output_text',
          text: 'זהו מידע מאומת.\nנבדק בתאריך: 04/09/2026',
          annotations: [
            { type: 'url_citation', title: 'Gov', url: 'https://www.gov.il/test' },
            { type: 'url_citation', title: 'Bad', url: 'https://bad.example/test' },
          ] }] }],
      }) };
    },
  });
  assert.doesNotMatch(answer, /https:\/\/www\.gov\.il\/test/);
  assert.match(answer, /מושבתים זמנית/);
  assert.equal(validations, 0);
  assert.doesNotMatch(answer, /bad\.example/);
});
