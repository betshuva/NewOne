'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  parseOpenAIDecision,
  verifyPersonClassification,
} = require('../server/person-verification');

const localFalsePositive = {
  category: 'people',
  detectedCategories: ['men', 'children'],
  uncertain: false,
  stages: [{ name: 'life', decision: 'person or people are visible' }],
};

const noObjects = async () => ({ available: true, personDetected: false,
  maxPersonScore: 0, persons: [] });
const noFaces = async () => ({ available: true, faceDetected: false,
  faceCount: 0, faces: [] });

test('specialized Google consensus corrects a local false person result', async () => {
  const result = await verifyPersonClassification(Buffer.from('image'),
    localFalsePositive, {
      scanObjects: noObjects,
      scanFaces: noFaces,
      classifyOpenAI: async () => ({ configured: false, available: false }),
    });
  assert.equal(result.classification.category, 'nonHumanImages');
  assert.deepEqual(result.classification.detectedCategories, ['nonHumanImages']);
  assert.deepEqual(result.classification.originalDetectedCategories,
    ['men', 'children']);
  assert.equal(result.verification.decision, 'non_human_google_consensus');
});

test('a detected object keeps local demographic categories', async () => {
  const result = await verifyPersonClassification(Buffer.from('image'),
    localFalsePositive, {
      scanObjects: async () => ({ available: true, personDetected: true,
        maxPersonScore: 0.93, persons: [{ score: 0.93 }] }),
      scanFaces: noFaces,
    });
  assert.deepEqual(result.classification.detectedCategories, ['men', 'children']);
  assert.equal(result.verification.decision, 'person_confirmed');
});

test('OpenAI completes demographics when Google sees several people', async () => {
  let openAICalls = 0;
  const childOnly = { ...localFalsePositive, category: 'children',
    detectedCategories: ['children'] };
  const result = await verifyPersonClassification(Buffer.from('image'), childOnly, {
    scanObjects: async () => ({ available: true, personDetected: true,
      maxPersonScore: 0.93, persons: [{ score: 0.93 }, { score: 0.88 }] }),
    scanFaces: async () => ({ available: true, faceDetected: true,
      faceCount: 5, faces: [{}, {}, {}, {}, {}] }),
    classifyOpenAI: async () => {
      openAICalls += 1;
      return { available: true, decision: 'person',
        personCategories: ['men', 'children'], confidence: 0.96 };
    },
  });
  assert.equal(openAICalls, 1);
  assert.equal(result.classification.category, 'people');
  assert.deepEqual(result.classification.detectedCategories, ['men', 'children']);
  assert.equal(result.verification.decision, 'demographics_reviewed_by_openai');
});

test('OpenAI removes a false child category when Google sees one adult', async () => {
  const result = await verifyPersonClassification(Buffer.from('image'),
    localFalsePositive, {
      scanObjects: async () => ({ available: true, personDetected: true,
        maxPersonScore: 0.93, persons: [{ score: 0.93 }] }),
      scanFaces: async () => ({ available: true, faceDetected: true,
        faceCount: 1, faces: [{ detectionConfidence: 0.94 }] }),
      classifyOpenAI: async () => ({ available: true, decision: 'person',
        personCategories: ['men'], confidence: 0.99 }),
    });
  assert.equal(result.classification.category, 'men');
  assert.deepEqual(result.classification.detectedCategories, ['men']);
  assert.equal(result.verification.decision, 'demographics_reviewed_by_openai');
});

test('OpenAI can confirm a person and its demographic when Google disagrees', async () => {
  const result = await verifyPersonClassification(Buffer.from('image'),
    localFalsePositive, {
      scanObjects: noObjects,
      scanFaces: noFaces,
      classifyOpenAI: async () => ({ available: true, decision: 'person',
        personCategory: 'children', confidence: 0.91 }),
    });
  assert.deepEqual(result.classification.detectedCategories, ['children']);
  assert.equal(result.verification.decision, 'person_confirmed_by_openai');
});

test('OpenAI demographic result corrects a local child false positive', async () => {
  const result = await verifyPersonClassification(Buffer.from('image'),
    localFalsePositive, {
      scanObjects: noObjects,
      scanFaces: noFaces,
      classifyOpenAI: async () => ({ available: true, decision: 'person',
        personCategory: 'men', confidence: 0.94 }),
    });
  assert.equal(result.classification.category, 'men');
  assert.deepEqual(result.classification.detectedCategories, ['men']);
  assert.equal(result.classification.uncertain, false);
});

test('unknown OpenAI demographics do not retain a local child guess', async () => {
  const result = await verifyPersonClassification(Buffer.from('image'),
    localFalsePositive, {
      scanObjects: noObjects,
      scanFaces: noFaces,
      classifyOpenAI: async () => ({ available: true, decision: 'person',
        personCategory: 'uncertain', confidence: 0.88 }),
    });
  assert.equal(result.classification.category, 'people');
  assert.deepEqual(result.classification.detectedCategories, []);
  assert.equal(result.classification.uncertain, true);
  assert.equal(result.classification.uncertainStage, 'demographics');
});

test('an uncertain local result without demographics still reaches OpenAI', async () => {
  let openAICalls = 0;
  const uncertain = {
    category: null,
    detectedCategories: [],
    uncertain: true,
    uncertainStage: 'people',
  };
  const result = await verifyPersonClassification(Buffer.from('image'), uncertain, {
    scanObjects: noObjects,
    scanFaces: noFaces,
    classifyOpenAI: async () => {
      openAICalls += 1;
      return { available: true, decision: 'non_human', confidence: 0.97 };
    },
  });
  assert.equal(openAICalls, 1);
  assert.equal(result.classification.category, 'nonHumanImages');
  assert.deepEqual(result.classification.detectedCategories, ['nonHumanImages']);
  assert.equal(result.verification.decision, 'non_human_confirmed');
});

test('an illustrated person can be rescued when Google person checks are unavailable', async () => {
  const uncertain = {
    category: null,
    detectedCategories: [],
    uncertain: true,
    uncertainStage: 'people',
  };
  const unavailable = async () => ({ available: false, status: 'not_configured' });
  const result = await verifyPersonClassification(Buffer.from('illustration'),
    uncertain, {
      scanObjects: unavailable,
      scanFaces: unavailable,
      classifyOpenAI: async () => ({
        available: true,
        decision: 'person',
        personCategories: ['men'],
        confidence: 0.94,
      }),
    });
  assert.equal(result.classification.category, 'men');
  assert.deepEqual(result.classification.detectedCategories, ['men']);
  assert.equal(result.classification.uncertain, false);
  assert.equal(result.verification.decision, 'person_confirmed_by_openai');
});

test('an unresolved second opinion remains uncertain when Google is unavailable', async () => {
  const uncertain = {
    category: null,
    detectedCategories: [],
    uncertain: true,
    uncertainStage: 'people',
  };
  const unavailable = async () => ({ available: false, status: 'not_configured' });
  const result = await verifyPersonClassification(Buffer.from('ambiguous'),
    uncertain, {
      scanObjects: unavailable,
      scanFaces: unavailable,
      classifyOpenAI: async () => ({
        available: true,
        decision: 'uncertain',
        confidence: 0.62,
      }),
    });
  assert.equal(result.classification.uncertain, true);
  assert.deepEqual(result.classification.detectedCategories, []);
  assert.equal(result.verification.decision, 'uncertain');
});

test('OpenAI JSON parser rejects unsupported decisions', () => {
  assert.deepEqual(parseOpenAIDecision(
    '{"decision":"non_human","person_category":"uncertain","confidence":0.98,"reason":"icon"}'),
  { decision: 'non_human', personCategory: 'uncertain', confidence: 0.98,
    reason: 'icon' });
  assert.equal(parseOpenAIDecision('{"decision":"maybe"}'), null);
  assert.deepEqual(parseOpenAIDecision(
    '{"decision":"person","person_categories":["men","children","men"],"confidence":0.96}'),
  { decision: 'person', confidence: 0.96, reason: '',
    personCategories: ['men', 'children'] });
});
