'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const source = fs.readFileSync(
  path.join(__dirname, '..', 'server', 'index.js'),
  'utf8',
);

test('contacts track explicit filter confirmation separately from defaults', () => {
  assert.match(
    source,
    /ADD COLUMN IF NOT EXISTS filter_choice_confirmed BOOLEAN NOT NULL DEFAULT FALSE/,
  );
  assert.match(
    source,
    /requiresChoice: result\.rows\[0\]\.filter_choice_confirmed !== true/,
  );
  assert.match(source, /AS has_sent_message/);
});

test('saving or accepting a contact filter confirms the choice', () => {
  const settingsStart = source.indexOf(
    "app.put('/api/contacts/:userId/filter-settings'",
  );
  const settingsEnd = source.indexOf(
    "app.post('/api/contacts/match'",
    settingsStart,
  );
  const settingsSource = source.slice(settingsStart, settingsEnd);
  assert.equal(
    (settingsSource.match(/filter_choice_confirmed=TRUE/g) || []).length,
    2,
  );

  const acceptStart = source.indexOf(
    "app.post('/api/message-requests/:id/accept'",
  );
  const acceptEnd = source.indexOf(
    "app.delete('/api/message-requests/:id'",
    acceptStart,
  );
  assert.match(
    source.slice(acceptStart, acceptEnd),
    /filter_override=\$1, filter_choice_confirmed=TRUE/,
  );
});

test('a contact filter is private to its owner and is not written to the friend', () => {
  const settingsStart = source.indexOf(
    "app.put('/api/contacts/:userId/filter-settings'",
  );
  const settingsEnd = source.indexOf(
    "app.post('/api/contacts/match'",
    settingsStart,
  );
  const settingsSource = source.slice(settingsStart, settingsEnd);
  assert.match(settingsSource, /WHERE owner_id=\$2 AND contact_id=\$3/);
  assert.doesNotMatch(settingsSource, /owner_id=\$3 AND contact_id=\$2/);
});

test('the private filter chat entry is persisted before sending and visible only to its owner', () => {
  assert.match(source, /CREATE TABLE IF NOT EXISTS contact_filter_chat_entries/);
  assert.match(source, /UNIQUE \(owner_id, contact_id\)/);

  const historyStart = source.indexOf("app.get('/api/messages/:userId'");
  const historyEnd = source.indexOf("app.post('/api/messages'", historyStart);
  const historySource = source.slice(historyStart, historyEnd);
  assert.match(historySource, /entry\.owner_id=\$1 AND entry\.contact_id=\$2/);
  assert.match(historySource, /'private_filter' AS type/);

  const settingsStart = source.indexOf(
    "app.put('/api/contacts/:userId/filter-settings'",
  );
  const settingsEnd = source.indexOf(
    "app.post('/api/contacts/match'",
    settingsStart,
  );
  const settingsSource = source.slice(settingsStart, settingsEnd);
  assert.match(settingsSource, /await client\.query\('BEGIN'\)/);
  assert.match(settingsSource, /INSERT INTO contact_filter_chat_entries/);
  assert.match(settingsSource, /await client\.query\('COMMIT'\)/);
  assert.match(settingsSource, /privateEntry:/);
});

test('a pending or unapproved contact cannot read the counterpart filter', () => {
  const comparisonStart = source.indexOf(
    "app.get('/api/contacts/:userId/filter-comparison'",
  );
  const comparisonEnd = source.indexOf(
    "app.put('/api/contacts/:userId/filter-settings'",
    comparisonStart,
  );
  const comparisonSource = source.slice(comparisonStart, comparisonEnd);
  assert.match(comparisonSource, /counterpart_filter_available/);
  assert.match(comparisonSource, /FROM user_contacts reciprocal/);
  assert.match(comparisonSource, /FROM message_requests pending/);
  assert.match(comparisonSource, /recipientFilter: recipient\?\.filter \|\| null/);
});
