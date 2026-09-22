'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const sharp = require('sharp');
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

test('blank video frames resolve without repeating an uncertain model review', async () => {
  const frame = await sharp({ create: { width: 64, height: 48, channels: 3,
    background: { r: 2, g: 3, b: 4 } } }).png().toBuffer();
  const result = await verifyPersonClassification(frame, {
    category: null, detectedCategories: [], uncertain: true,
  }, {
    videoFrame: true, scanObjects: noObjects, scanFaces: noFaces,
    classifyOpenAI: async () => assert.fail('Blank frame needs no model review'),
  });
  assert.equal(result.classification.category, 'nonHumanImages');
  assert.equal(result.classification.uncertain, false);
  assert.equal(result.verification.decision, 'non_human_blank_video_frame');
  assert.equal(result.verification.providers.videoFramePixels.maximum, 4);
});

test('blank-frame handling does not erase evidence or approve other uncertain media', async t => {
  const black = await sharp({ create: { width: 64, height: 48, channels: 3,
    background: { r: 0, g: 0, b: 0 } } }).png().toBuffer();
  const pixels = Buffer.alloc(64 * 48 * 3, 0);
  pixels[0] = 20;
  const detailed = await sharp(pixels, { raw: { width: 64, height: 48, channels: 3 } })
    .png().toBuffer();
  for (const scenario of [
    { name: 'still image', buffer: black, videoFrame: false },
    { name: 'one visible pixel', buffer: detailed },
    { name: 'invalid image', buffer: Buffer.from('invalid') },
    { name: 'local person evidence', buffer: black, classification: localFalsePositive },
    { name: 'Google unavailable', buffer: black,
      scanFaces: async () => ({ available: false }) },
  ]) {
    await t.test(scenario.name, async () => {
      let reviews = 0;
      const result = await verifyPersonClassification(scenario.buffer,
        scenario.classification || { category: null, detectedCategories: [], uncertain: true }, {
          videoFrame: scenario.videoFrame ?? true,
          scanObjects: noObjects, scanFaces: scenario.scanFaces || noFaces,
          classifyOpenAI: async () => {
            reviews++;
            return { available: true, decision: 'uncertain', confidence: 0.8 };
          },
        });
      assert.equal(reviews, 1);
      assert.equal(result.classification.uncertain, true);
      assert.equal(result.verification.decision, 'uncertain');
    });
  }
});

test('Google person evidence takes precedence over blank video frame handling', async () => {
  const frame = await sharp({ create: { width: 64, height: 48, channels: 3,
    background: { r: 0, g: 0, b: 0 } } }).png().toBuffer();
  const result = await verifyPersonClassification(frame, {
    category: null, detectedCategories: [], uncertain: true,
  }, {
    videoFrame: true,
    scanObjects: async () => ({ available: true, personDetected: true, persons: [{}] }),
    scanFaces: noFaces,
    classifyOpenAI: async () => ({ available: true, decision: 'person',
      personCategories: ['men'], confidence: 0.95 }),
  });
  assert.deepEqual(result.classification.detectedCategories, ['men']);
  assert.equal(result.verification.providers.videoFramePixels, undefined);
});

test('negative Google detections never erase local people when OpenAI is unavailable', async () => {
  const result = await verifyPersonClassification(Buffer.from('image'),
    localFalsePositive, {
      scanObjects: noObjects,
      scanFaces: noFaces,
      classifyOpenAI: async () => ({ configured: false, available: false }),
    });
  assert.equal(result.classification.category, 'people');
  assert.deepEqual(result.classification.detectedCategories, ['men', 'children']);
  assert.equal(result.classification.uncertain, true);
  assert.equal(result.classification.uncertainStage, 'personVerification');
  assert.equal(result.verification.decision, 'uncertain');
  assert.equal(result.verification.confidence, 0);
});

test('drawing-aware non-human review can correct a local false person result', async () => {
  const result = await verifyPersonClassification(Buffer.from('image'),
    localFalsePositive, {
      scanObjects: noObjects,
      scanFaces: noFaces,
      classifyOpenAI: async () => ({ available: true,
        decision: 'non_human', confidence: 0.98 }),
    });
  assert.equal(result.classification.category, 'nonHumanImages');
  assert.deepEqual(result.classification.detectedCategories, ['nonHumanImages']);
  assert.deepEqual(result.classification.originalDetectedCategories, ['men', 'children']);
  assert.equal(result.classification.uncertain, false);
  assert.equal(result.verification.decision, 'non_human_confirmed');
});

test('a detected object keeps local demographic categories', async () => {
  const result = await verifyPersonClassification(Buffer.from('image'),
    localFalsePositive, {
      scanObjects: async () => ({ available: true, personDetected: true,
        maxPersonScore: 0.93, persons: [{ score: 0.93 }] }),
      scanFaces: noFaces,
      classifyOpenAI: async () => ({ configured: false, available: false }),
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

test('substantial local person evidence escalates a false scenery result', async () => {
  let objectCalls = 0;
  let faceCalls = 0;
  let openAICalls = 0;
  const falseScenery = {
    category: 'nonHumanImages',
    detectedCategories: ['nonHumanImages'],
    uncertain: false,
    life: {
      'person or people are visible': 0.44,
      'animal or plant is visible': 0.5429,
    },
    stages: [{ name: 'life', personScore: 0.44 }],
  };
  const result = await verifyPersonClassification(Buffer.from('portrait'),
    falseScenery, {
      scanObjects: async () => {
        objectCalls += 1;
        return { available: true, personDetected: true,
          maxPersonScore: 0.87, persons: [{ score: 0.87 }] };
      },
      scanFaces: async () => {
        faceCalls += 1;
        return { available: true, faceDetected: true,
          faceCount: 1, faces: [{ detectionConfidence: 0.98 }] };
      },
      classifyOpenAI: async () => {
        openAICalls += 1;
        return { available: true, decision: 'person',
          personCategories: ['men'], confidence: 0.99 };
      },
    });
  assert.equal(objectCalls, 1);
  assert.equal(faceCalls, 1);
  assert.equal(openAICalls, 1);
  assert.equal(result.classification.category, 'men');
  assert.deepEqual(result.classification.detectedCategories, ['men']);
  assert.equal(result.verification.decision, 'demographics_reviewed_by_openai');
});

test('confirmed person without demographics never remains scenery', async () => {
  const falseScenery = {
    category: 'nonHumanImages', detectedCategories: ['nonHumanImages'],
    uncertain: false,
    life: { 'person or people are visible': 0.44 },
  };
  const result = await verifyPersonClassification(Buffer.from('portrait'),
    falseScenery, {
      scanObjects: async () => ({ available: true, personDetected: true,
        maxPersonScore: 0.9, persons: [{ score: 0.9 }] }),
      scanFaces: async () => ({ available: true, faceDetected: true,
        faceCount: 1, faces: [{}] }),
      classifyOpenAI: async () => ({ available: false, status: 'error' }),
    });
  assert.equal(result.classification.category, 'people');
  assert.deepEqual(result.classification.detectedCategories, []);
  assert.equal(result.classification.uncertain, true);
});

test('Google checks every confident non-human image without unnecessary OpenAI', async () => {
  let objectCalls = 0;
  let faceCalls = 0;
  let openAICalls = 0;
  const scenery = {
    category: 'nonHumanImages', detectedCategories: ['nonHumanImages'],
    uncertain: false,
    life: { 'person or people are visible': 0.04 },
  };
  const result = await verifyPersonClassification(Buffer.from('scenery'), scenery, {
    scanObjects: async () => {
      objectCalls += 1;
      return { available: true, personDetected: false, persons: [] };
    },
    scanFaces: async () => {
      faceCalls += 1;
      return { available: true, faceDetected: false, faces: [] };
    },
    classifyOpenAI: async () => {
      openAICalls += 1;
      return { available: true, decision: 'non_human', confidence: 1 };
    },
  });
  assert.equal(objectCalls, 1);
  assert.equal(faceCalls, 1);
  assert.equal(openAICalls, 0);
  assert.equal(result.verification.decision, 'non_human_google_consensus');
});

test('an uncertain drawing-aware review preserves local human evidence', async () => {
  const result = await verifyPersonClassification(Buffer.from('illustrated-person'),
    localFalsePositive, {
      scanObjects: noObjects,
      scanFaces: noFaces,
      classifyOpenAI: async () => ({ available: true, decision: 'uncertain',
        confidence: 0.6 }),
    });
  assert.equal(result.classification.category, 'people');
  assert.deepEqual(result.classification.detectedCategories, ['men', 'children']);
  assert.equal(result.classification.uncertain, true);
  assert.equal(result.verification.decision, 'uncertain');
});

test('incomplete Google checks without an OpenAI decision cannot approve local scenery', async t => {
  const unavailable = async () => ({ available: false, status: 'error' });
  const scenery = {
    category: 'nonHumanImages', detectedCategories: ['nonHumanImages'],
    uncertain: false,
  };
  for (const google of ['objects_unavailable', 'faces_unavailable', 'unavailable']) {
    for (const decision of ['unavailable', 'uncertain']) {
      await t.test(`${google} Google and ${decision} OpenAI`, async () => {
        const result = await verifyPersonClassification(Buffer.from('scenery'), scenery, {
          scanObjects: ['objects_unavailable', 'unavailable'].includes(google)
            ? unavailable : noObjects,
          scanFaces: ['faces_unavailable', 'unavailable'].includes(google)
            ? unavailable : noFaces,
          classifyOpenAI: async () => decision === 'unavailable'
            ? { available: false, status: 'error' }
            : { available: true, decision: 'uncertain', confidence: 0.6 },
        });
        assert.equal(result.classification.category, null);
        assert.deepEqual(result.classification.detectedCategories, []);
        assert.equal(result.classification.uncertain, true);
        assert.equal(result.classification.uncertainStage, 'personVerification');
        assert.equal(result.verification.decision, 'uncertain');
      });
    }
  }
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
