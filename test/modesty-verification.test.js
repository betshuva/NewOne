'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  classifyOpenAIModesty,
  parseModestyDecision,
} = require('../server/modesty-verification');

test('modesty parser accepts only the three fail-closed decisions', () => {
  assert.deepEqual(parseModestyDecision(
    '{"decision":"non_modest","confidence":0.97,"violationClearlyVisible":true,"visibleEvidence":"קו מכפלת ורגל חשופה","reason":"מכנסיים קצרים"}'),
  { decision: 'non_modest', confidence: 0.97, reason: 'מכנסיים קצרים',
    violationClearlyVisible: true, visibleEvidence: 'קו מכפלת ורגל חשופה' });
  assert.equal(parseModestyDecision('{"decision":"safe","confidence":1}'), null);
});

test('unsupported clothing inference is downgraded to uncertain', () => {
  const result = parseModestyDecision(
    '{"decision":"non_modest","confidence":0.99,"violationClearlyVisible":false,"visibleEvidence":"","reason":"כנראה מכנסיים קצרים"}');
  assert.equal(result.decision, 'uncertain');
  assert.equal(result.unsupportedViolation, true);
});

test('independent modesty review sends the strict policy and parses its result', async () => {
  let requestBody;
  const result = await classifyOpenAIModesty(Buffer.from('image'), {
    apiKey: 'test-key',
    fetchImpl: async (_url, options) => {
      requestBody = JSON.parse(options.body);
      return {
        ok: true,
        json: async () => ({ output_text:
          '{"decision":"uncertain","confidence":0.71,"reason":"cropped"}' }),
      };
    },
  });
  const prompt = requestBody.input[0].content[0].text;
  assert.match(prompt, /Bare arms, visible forearms, visible upper arms, and short sleeves are allowed/);
  assert.match(prompt, /as long as the shoulders are covered/);
  assert.match(prompt, /Never infer exposed arms, short sleeves, shorts, trouser length/);
  assert.match(prompt, /both the garment hem and exposed leg below that hem are clearly visible/);
  assert.match(prompt, /long skirt/);
  assert.match(prompt, /completely outside the frame are not applicable/);
  assert.match(prompt, /partly outside the frame, or genuinely ambiguous/);
  assert.equal(requestBody.input[0].content[1].detail, 'high');
  assert.equal(result.decision, 'uncertain');
});

test('missing or failed independent review is unavailable for fail-closed caller', async () => {
  assert.deepEqual(await classifyOpenAIModesty(Buffer.from('image'), { apiKey: '' }),
    { configured: false, available: false, status: 'not_configured' });
  const failed = await classifyOpenAIModesty(Buffer.from('image'), {
    apiKey: 'test-key',
    fetchImpl: async () => ({ ok: false, status: 500, json: async () => ({}) }),
  });
  assert.equal(failed.available, false);
  assert.equal(failed.status, 'error');
});
