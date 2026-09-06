'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { imageClassificationOutcome } = require('../server/image-classification-outcome');
test('ambiguous screenshot stays pending, preserving verification provenance', () => {
  const scan = { classification: { category: 'people', uncertain: true }, personVerification: { available: false } };
  const result = imageClassificationOutcome(scan);
  assert.equal(result.pending, true);
  assert.notEqual(result.blocked, true);
  assert.deepEqual(result.personVerification, scan.personVerification);
});
test('verified nonhuman screenshot is approved; missing classifier is retried', () => {
  assert.equal(imageClassificationOutcome({ classification: { category: 'nonHumanImages', uncertain: false } }).blocked, false);
  assert.equal(imageClassificationOutcome({}).pending, true);
});
test('explicit safety blocks cannot be overridden by screenshot classification', () => {
  const scan = { blocked: true, blockedBy: 'googleSafeSearch', classification: { category: 'nonHumanImages' } };
  assert.deepEqual(imageClassificationOutcome(scan), scan);
});
