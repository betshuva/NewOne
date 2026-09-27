'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { verifyPersonClassification } = require('../server/person-verification');

const local = { category: 'men', detectedCategories: ['men'], uncertain: false };
const geminiPerson = { available: true, decision: 'person', confidence: 0.95,
  personCategories: ['women', 'children'] };

function optional(t) {
  const old = process.env.MODERATION_OPENAI_REQUIRED;
  process.env.MODERATION_OPENAI_REQUIRED = 'false';
  t.after(() => old === undefined ? delete process.env.MODERATION_OPENAI_REQUIRED
    : process.env.MODERATION_OPENAI_REQUIRED = old);
}

test('person review falls back from unavailable OpenAI to Gemini and retains both actual provider results', async t => {
  optional(t);
  for (const failed of [{ available: false, budgetStopped: true, providerSuspended: true,
    reasonCode: 'credit_balance_exhausted' }, { available: false, status: 'error' },
  { available: true, decision: 'uncertain' }]) {
    const calls = [];
    const result = await verifyPersonClassification(Buffer.from('mock image'), local, {
      scanObjects: async () => ({ available: true, personDetected: true, persons: [{}, {}] }),
      scanFaces: async () => ({ available: true, faceDetected: true, faceCount: 2 }),
      classifyOpenAI: async () => { calls.push('openai'); return failed; },
      classifyGemini: async () => { calls.push('gemini'); return geminiPerson; },
    });
    assert.deepEqual(calls, ['openai', 'gemini']);
    assert.equal(result.verification.providers.openai, failed);
    assert.equal(result.verification.providers.gemini, geminiPerson);
    assert.equal(result.verification.decision, 'demographics_reviewed_by_gemini');
    assert.deepEqual(result.classification.detectedCategories, ['women', 'children']);
    assert.equal(result.classification.uncertain, false);
  }
});

test('healthy OpenAI stays enabled without an unnecessary Gemini person request', async t => {
  optional(t);
  const result = await verifyPersonClassification(Buffer.from('mock image'), local, {
    scanObjects: async () => ({ available: true, personDetected: true, persons: [{}, {}] }),
    scanFaces: async () => ({ available: true, faceDetected: true, faceCount: 2 }),
    classifyOpenAI: async () => geminiPerson,
    classifyGemini: async () => assert.fail('No fallback needed'),
  });
  assert.equal(result.verification.decision, 'demographics_reviewed_by_openai');
  assert.equal(result.verification.providers.gemini, undefined);
});

test('unavailable or uncertain Gemini cannot erase unresolved demographic evidence', async t => {
  optional(t);
  for (const gemini of [{ available: false, status: 'error' },
    { available: true, decision: 'uncertain' }, { available: true, decision: 'non_human' }]) {
    const result = await verifyPersonClassification(Buffer.from('mock image'), local, {
      scanObjects: async () => ({ available: true, personDetected: true, persons: [{}, {}] }),
      scanFaces: async () => ({ available: true, faceDetected: true, faceCount: 2 }),
      classifyOpenAI: async () => ({ available: false }), classifyGemini: async () => gemini,
    });
    assert.equal(result.classification.uncertain, true);
    assert.equal(result.verification.decision, 'uncertain');
  }
});

test('negative Google person detections use Gemini fallback when optional OpenAI is unavailable', async t => {
  optional(t);
  const result = await verifyPersonClassification(Buffer.from('mock image'), local, {
    scanObjects: async () => ({ available: true, personDetected: false }),
    scanFaces: async () => ({ available: true, faceDetected: false }),
    classifyOpenAI: async () => ({ available: false }),
    classifyGemini: async () => ({ available: true, decision: 'non_human', confidence: 0.98 }),
  });
  assert.equal(result.classification.category, 'nonHumanImages');
  assert.equal(result.classification.uncertain, false);
  assert.equal(result.verification.providers.openai.available, false);
  assert.equal(result.verification.providers.gemini.available, true);
});
