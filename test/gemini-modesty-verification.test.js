'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const sharp = require('sharp');
const {
  classifyGeminiModesty,
  MODESTY_RESPONSE_SCHEMA,
  prepareGeminiImage,
} = require('../server/gemini-modesty-verification');

function response(body, status = 200) {
  return { ok: status >= 200 && status < 300, status, json: async () => body };
}

test('Gemini modesty review uses the shared strict policy and records usage', async () => {
  let request;
  const result = await classifyGeminiModesty(Buffer.from('image'), {
    apiKey: 'gemini-key', skipImagePreparation: true,
    fetchImpl: async (url, options) => {
      request = { url, options, body: JSON.parse(options.body) };
      return response({
        candidates: [{ content: { parts: [{ text:
          '{"decision":"modest","confidence":0.96,"reason":"covered"}' }] } }],
        usageMetadata: { promptTokenCount: 300, candidatesTokenCount: 20,
          thoughtsTokenCount: 5, totalTokenCount: 325 },
      });
    },
  });
  assert.match(request.url, /gemini-3\.5-flash-lite:generateContent$/);
  assert.doesNotMatch(request.url, /gemini-key/);
  assert.equal(request.options.headers['x-goog-api-key'], 'gemini-key');
  assert.match(request.body.contents[0].parts[0].text,
    /Bare arms, visible forearms, visible upper arms, and short sleeves are allowed/);
  assert.equal(request.body.generationConfig.responseMimeType, 'application/json');
  assert.equal(request.body.generationConfig.maxOutputTokens, 400);
  assert.deepEqual(request.body.generationConfig.responseJsonSchema,
    MODESTY_RESPONSE_SCHEMA);
  assert.deepEqual(MODESTY_RESPONSE_SCHEMA.required,
    ['decision', 'confidence', 'violationClearlyVisible',
      'visibleEvidence', 'reason']);
  assert.equal(result.decision, 'modest');
  assert.equal(result.usage.totalTokens, 325);
});

test('Gemini repairs malformed output once without resending the image', async () => {
  const requests = [];
  const result = await classifyGeminiModesty(Buffer.from('image'), {
    apiKey: 'gemini-key', skipImagePreparation: true,
    fetchImpl: async (_url, options) => {
      requests.push(JSON.parse(options.body));
      if (requests.length === 1) return response({
        candidates: [{ content: { parts: [{ text: 'decision: modest' }] } }],
      });
      return response({ candidates: [{ content: { parts: [{ text:
        '{"decision":"modest","confidence":0.9,"violationClearlyVisible":false,"visibleEvidence":"","reason":"לבוש תקין"}' }] } }],
      });
    },
  });
  assert.equal(requests.length, 2);
  assert.ok(requests[0].contents[0].parts.some(part => part.inlineData));
  assert.ok(requests[1].contents[0].parts.every(part => !part.inlineData));
  assert.equal(result.formatRepaired, true);
  assert.equal(result.decision, 'modest');
});

test('Gemini provider safety blocks fail closed', async () => {
  const result = await classifyGeminiModesty(Buffer.from('image'), {
    apiKey: 'gemini-key', skipImagePreparation: true,
    fetchImpl: async () => response({ promptFeedback: { blockReason: 'SAFETY' } }),
  });
  assert.equal(result.available, true);
  assert.equal(result.decision, 'non_modest');
});

test('Gemini errors remain unavailable for retry', async () => {
  const result = await classifyGeminiModesty(Buffer.from('image'), {
    apiKey: 'gemini-key', skipImagePreparation: true,
    fetchImpl: async () => response({ error: { message: 'quota' } }, 429),
  });
  assert.equal(result.available, false);
  assert.equal(result.status, 'error');
});

test('Gemini receives a metadata-free bounded scan copy', async () => {
  const source = await sharp({ create: { width: 1200, height: 900, channels: 3,
    background: 'white' } }).png().toBuffer();
  const prepared = await prepareGeminiImage(source);
  const metadata = await sharp(prepared).metadata();
  assert.equal(metadata.format, 'jpeg');
  assert.ok(metadata.width <= 768);
  assert.ok(metadata.height <= 768);
});
