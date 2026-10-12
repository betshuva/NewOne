'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const {
  DEFAULT_CONTENT_FILTER,
  contentAllowedByFilter,
  combineMessageClassifications,
  normalizeContentFilter,
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

test('caption classifications add categories while preserving file category and scanner versions', () => {
  const emoji = { inlineEmoji: true, category: 'women', detectedCategories: ['women', 'men'],
    uncertain: false, artworkVersion: 'emoji-art', moderationVersion: 'emoji-scan', artworkHash: 'emoji-hash' };
  const merged = combineMessageClassifications(man, emoji);
  assert.equal(merged.category, 'men');
  assert.deepEqual(merged.detectedCategories, ['men', 'women']);
  assert.equal(merged.inlineEmoji, true);
  assert.equal(merged.artworkVersion, 'emoji-art');
  assert.equal(merged.moderationVersion, 'emoji-scan');
  assert.equal(merged.artworkHash, 'emoji-hash');
  assert.equal(combineMessageClassifications({ category: 'children', uncertain: true }, emoji).uncertain, true);
  assert.deepEqual(combineMessageClassifications({ category: 'children' }, { ...emoji, detectedCategories: [] })
    .detectedCategories, ['children', 'women']);
  assert.equal(combineMessageClassifications(man, { ...emoji, inlineEmoji: 'true' }), man);
  assert.equal(combineMessageClassifications(null, null), null);
  assert.equal(man.inlineEmoji, undefined);
  assert.deepEqual(emoji.detectedCategories, ['women', 'men']);
});

test('inline caption categories cannot bypass the base type or another attached category', () => {
  const emoji = { inlineEmoji: true, category: 'women', detectedCategories: ['women'] };
  const combined = combineMessageClassifications(man, emoji);
  for (const type of ['text', 'sticker', 'audio', 'document', 'image', 'video']) {
    assert.equal(contentAllowedByFilter({ ...allowed, women: false }, type, combined), false, type);
    assert.equal(contentAllowedByFilter({ ...allowed, men: false }, type, combined), false, type);
    assert.equal(contentAllowedByFilter(allowed, type, combined), true, type);
  }
  assert.equal(contentAllowedByFilter({ ...allowed, video: false }, 'video', combined), false);
  assert.equal(contentAllowedByFilter(allowed, 'archive', combined), false);
});

test('a specific caption never resolves unspecified or uncertain people in the file scan', () => {
  const emoji = { inlineEmoji: true, category: 'women', detectedCategories: ['women'] };
  for (const file of [{ category: 'people', detectedCategories: ['people'] },
    { category: 'men', detectedCategories: ['men'], uncertain: true }]) {
    const combined = combineMessageClassifications(file, emoji);
    assert.equal(contentAllowedByFilter(allowed, 'image', combined), true);
    for (const blockedCategory of ['men', 'women', 'children']) {
      assert.equal(contentAllowedByFilter({ ...allowed, [blockedCategory]: false }, 'image', combined), false,
        blockedCategory);
    }
  }
});

test('missing visual attachment classification remains conservative while ordinary text and audio keep their policy', () => {
  const emoji = { inlineEmoji: true, category: 'women', detectedCategories: ['women'] };
  for (const type of ['image', 'video']) {
    const combined = combineMessageClassifications(null, emoji, type);
    assert.equal(combined.category, 'people');
    assert.equal(combined.uncertain, true);
    assert.equal(contentAllowedByFilter({ ...allowed, men: false }, type, combined), false);
    assert.equal(contentAllowedByFilter(allowed, type, combined), true);
  }
  for (const type of ['text', 'audio', 'document']) {
    const combined = combineMessageClassifications(null, emoji, type);
    assert.equal(contentAllowedByFilter({ ...allowed, men: false }, type, combined), true);
  }
});

for (const context of ['private forwarding', 'group forwarding']) {
  test(`${context} keeps basic content available and enforces visual preferences`, () => {
    for (const type of ['text', 'sticker', 'audio', 'document', 'image', 'video']) {
      assert.equal(contentAllowedByFilter(blocked, type, man),
        ['text', 'sticker', 'audio'].includes(type), type);
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
  const restricted = { ...blocked, text: true, nonHumanImages: true };
  assert.deepEqual(resolveScopedContentFilter(allowed, blocked), restricted);
  assert.deepEqual(resolveScopedContentFilter(blocked, allowed), allowed);
  assert.deepEqual(resolveScopedContentFilter(blocked, null), restricted);
});

test('legacy false values cannot block text or non-human images, including enforced scopes', () => {
  const restricted = { ...blocked, text: true, nonHumanImages: true };
  assert.deepEqual(normalizeContentFilter(blocked), restricted);
  assert.deepEqual(normalizeContentFilter({}, blocked), restricted);
  for (const enforceGeneralFilter of [false, true]) {
    const general = { ...blocked, enforceGeneralFilter };
    for (const scope of [null, blocked, { text: false, nonHumanImages: false }]) {
      const policy = resolveScopedContentFilter(general, scope);
      assert.deepEqual(policy, restricted);
      assert.equal(contentAllowedByFilter(policy, 'text'), true);
      assert.equal(contentAllowedByFilter(policy, 'document'), true);
      for (const classification of [
        { category: 'nonHumanImages' },
        { detectedCategories: ['nonHumanImages'] },
      ]) {
        assert.equal(contentAllowedByFilter(policy, 'image', classification), true);
        assert.equal(contentAllowedByFilter(policy, 'document', classification), true);
        assert.equal(contentAllowedByFilter(policy, 'video', classification), false);
      }
      assert.equal(contentAllowedByFilter(policy, 'image', man), false);
    }
  }
});

test('private and group HTTP forwarding routes enforce the shared policy', () => {
  const source = fs.readFileSync(
    path.join(__dirname, '..', 'server', 'index.js'), 'utf8');
  const privateRoute = source.slice(
    source.indexOf("async function sendPrivateHttpMessage("),
    source.indexOf("app.post('/api/messages'"));
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
    source.indexOf('Future<ForwardChatResult> forwardChatMessages'),
    source.indexOf('// Google Web Client ID'));
  assert.match(forwarding, /body\['error'\]\.toString\(\)/);
  assert.match(forwarding, /forwardingErrors\.add\(responseError\(response\)\)/);
  assert.match(forwarding, /for \(final target in targets\)/);
  assert.match(forwarding, /final message = messages\[messageIndex\]/);
});

test('enforced general filter caps every scoped permission, including existing permissive overrides', () => {
  const general = { ...DEFAULT_CONTENT_FILTER, women: false, video: false, enforceGeneralFilter: true };
  const result = resolveScopedContentFilter(general, DEFAULT_CONTENT_FILTER);
  assert.equal(result.women, false);
  assert.equal(result.video, false);
  assert.equal(result.text, true);
  assert.equal(resolveScopedContentFilter(general, {text:false}).text, true);
  assert.equal(resolveScopedContentFilter({...general,enforceGeneralFilter:false}, DEFAULT_CONTENT_FILTER).women, true);
  assert.equal(resolveScopedContentFilter(general,null).women, false);
});
