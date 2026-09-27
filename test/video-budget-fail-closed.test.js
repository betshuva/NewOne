'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { stoppedVideoResult, videoProviderStop } = require('../server/video-scan-controller');

const source = fs.readFileSync(require.resolve('../server/index.js'), 'utf8');
const start = source.indexOf('async function scanStaticImage(');
const end = source.indexOf('// Increment whenever moderation models', start);
const stopped = { available: false, budgetStopped: true, reasonCode: 'credit_balance_exhausted' };

async function frame(stage) {
  const called = [];
  const scan = vm.runInNewContext(`${source.slice(start, end)};scanStaticImage`, {
    stoppedVideoResult, videoProviderStop, process: { env: {} }, console,
    recordProviderCheck: async () => {},
    MODERATION_CACHE_VERSION: 'test',
    openAIModerationEnabled: () => true,
    openAIModerationRequired: () => true,
    moderationProviderPolicy: () => 'google_openai_gemini',
    disabledModerationProviderResult: () => assert.fail('OpenAI is enabled in this fixture'),
    classifyClip: async () => ({}),
    classifyImageContent: async () => ({ category: 'men', detectedCategories: ['men'], uncertain: false }),
    classifyLocalSafety: async () => ({ available: true, wouldBlock: false }),
    googleSafeSearchConfigured: () => true,
    normalizeBlockThreshold: () => 'LIKELY',
    scanGoogleSafeSearch: async () => {
      called.push('safe');
      return stage === 'safe' ? stopped : { available: true, blocked: false, uncertain: false };
    },
    verifyPersonClassification: async (_bytes, classification) => {
      called.push('person');
      return { classification, verification: { providers: stage === 'person' ? { openai: stopped } : {} } };
    },
    classifyOpenAIModesty: async () => { called.push('openai'); return stopped; },
    classifyGeminiModesty: async () => { called.push('gemini'); return { available: true, decision: 'modest' }; },
    imageClassificationOutcome: () => assert.fail('partial scan cannot approve'),
  });
  const result = await scan(Buffer.from('image'), { tracking: { videoBudget: {} } });
  return { result, called };
}

for (const stage of ['safe', 'person', 'modesty']) test(`stopped ${stage} stage bypasses clean-safety approval fallback`, async () => {
  const { result, called } = await frame(stage);
  assert.equal(result.scanStopped, true);
  assert.equal(result.pending, false);
  assert.equal(result.classification.uncertain, true);
  assert.equal(result.reasonCode, 'credit_balance_exhausted');
  assert.deepEqual(called, stage === 'safe' ? ['safe'] : stage === 'person'
    ? ['safe', 'person'] : ['safe', 'person', 'openai', 'gemini']);
});
