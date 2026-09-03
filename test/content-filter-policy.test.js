'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const {
  contentAllowedByFilter,
  resolveScopedContentFilter,
} = require('../server/content-filter-policy');

const blocked = Object.freeze({
  text: false,
  video: false,
  nonHumanImages: false,
  men: false,
  women: false,
  children: false,
});
const allowed = Object.freeze({
  text: true,
  video: true,
  nonHumanImages: true,
  men: true,
  women: true,
  children: true,
});
const man = Object.freeze({
  category: 'men',
  detectedCategories: ['men'],
  uncertain: false,
});

for (const context of ['private forwarding', 'group forwarding']) {
  test(`${context} enforces every supported content type`, () => {
    for (const type of ['text', 'sticker', 'audio', 'document', 'image', 'video']) {
      assert.equal(contentAllowedByFilter(blocked, type, man), false, type);
      assert.equal(contentAllowedByFilter(allowed, type, man), true, type);
    }
  });

  test(`${context} rejects unknown content types`, () => {
    assert.equal(contentAllowedByFilter(allowed, 'archive', null), false);
    assert.equal(contentAllowedByFilter(allowed, '', null), false);
    assert.equal(contentAllowedByFilter(allowed, null, null), false);
  });
}

test('friend or group scope overrides the general filter in either direction', () => {
  assert.deepEqual(resolveScopedContentFilter(allowed, blocked), blocked);
  assert.deepEqual(resolveScopedContentFilter(blocked, allowed), allowed);
  assert.deepEqual(resolveScopedContentFilter(blocked, null), blocked);
});

test('private and group HTTP forwarding routes enforce the shared policy', () => {
  const source = fs.readFileSync(
    path.join(__dirname, '..', 'server', 'index.js'), 'utf8');
  const privateRoute = source.slice(
    source.indexOf("app.post('/api/messages'"),
    source.indexOf("app.get('/api/messages/requests'"));
  const groupRoute = source.slice(
    source.indexOf("app.post('/api/groups/:id/messages'"),
    source.indexOf("app.get('/api/groups/:id/messages'"));
  assert.match(privateRoute, /contentAllowedByFilter\(recipientPolicy\?\.filter/);
  assert.match(privateRoute, /RECIPIENT_CONTENT_FILTERED/);
  assert.match(groupRoute, /contentAllowedByFilter\(effectiveGroupFilter/);
  assert.match(groupRoute, /GROUP_CONTENT_FILTERED/);
});

test('forwarding UI displays the exact server rejection reason', () => {
  const source = fs.readFileSync(
    path.join(__dirname, '..', 'flutter_app', 'lib', 'main.dart'), 'utf8');
  const forwarding = source.slice(
    source.indexOf('Future<void> _forwardChatMessages'),
    source.indexOf('// Google Web Client ID'));
  assert.match(forwarding, /body\['error'\]\.toString\(\)/);
  assert.match(forwarding, /forwardingErrors\.add\(responseError\(response\)\)/);
  assert.match(forwarding, /for \(final target in targets\)/);
  assert.match(forwarding, /for \(final message in messages\)/);
});
