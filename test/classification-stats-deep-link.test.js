'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const test = require('node:test');

const source = fs.readFileSync(
  require.resolve('../flutter_app/lib/main.dart'), 'utf8');

test('classification statistics URL opens the protected admin tab directly', () => {
  assert.match(source,
    /queryParameters\['screen'\] == 'classification-stats'/);
  assert.match(source,
    /kOpenClassificationStats &&\s+permission != null/);
  assert.match(source,
    /AdminScreen\([\s\S]*?initialTab: 3/);
  assert.match(source,
    /TabController\(length: 5,[\s\S]*?initialIndex: widget\.initialTab/);
});
