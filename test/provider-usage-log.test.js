'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const test = require('node:test');

const server = fs.readFileSync(require.resolve('../server/index.js'), 'utf8');
const schema = fs.readFileSync(require.resolve('../server/schema.sql'), 'utf8');
const logger = fs.readFileSync(require.resolve('../server/provider-usage-log.js'), 'utf8');
const guide = fs.readFileSync(require.resolve('../server/system-guide-ai.js'), 'utf8');
const gemini = fs.readFileSync(
  require.resolve('../server/gemini-modesty-verification.js'), 'utf8');
const openai = fs.readFileSync(
  require.resolve('../server/modesty-verification.js'), 'utf8');
const person = fs.readFileSync(
  require.resolve('../server/person-verification.js'), 'utf8');
const google = fs.readFileSync(require.resolve('../server/google-vision.js'), 'utf8');

test('provider calls use a dedicated append-only accounting table', () => {
  assert.match(schema, /CREATE TABLE IF NOT EXISTS moderation_provider_calls/);
  assert.match(schema, /request_id UUID NOT NULL UNIQUE/);
  assert.match(schema, /usage_reported BOOLEAN NOT NULL DEFAULT FALSE/);
  assert.match(schema, /cache_hit BOOLEAN NOT NULL DEFAULT FALSE/);
  assert.match(schema, /estimated_cost_usd DOUBLE PRECISION/);
  assert.match(logger, /INSERT INTO moderation_provider_calls/);
  assert.doesNotMatch(logger, /UPDATE moderation_provider_calls/);
  assert.doesNotMatch(logger, /DELETE FROM moderation_provider_calls/);
});

test('all external AI entry points record usage and failures', () => {
  assert.match(openai, /operation: 'modesty'/);
  assert.match(person, /operation: 'person_presence'/);
  assert.match(guide, /operation: 'system_guide'/);
  assert.match(gemini, /'modesty_format_repair'/);
  assert.match(gemini, /usage\[key\] \+= callUsage\[key\]/);
  assert.match(google, /operation: 'safe_search'/);
  assert.match(google, /operation: 'object_localization'/);
  assert.match(google, /operation: 'face_detection'/);
});

test('dashboard distinguishes journal accounting from historical estimates', () => {
  assert.match(server, /providerJournalResult/);
  assert.match(server, /completeForRecordedCalls/);
  assert.match(server, /missingUsage/);
  assert.match(server, /unpricedCalls/);
  assert.match(server, /operation: 'moderation_cache'/);
  assert.match(server, /operation: 'google_safe_search_reuse'/);
});
