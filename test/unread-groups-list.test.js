'use strict';

const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');

const source = fs.readFileSync(
  path.join(__dirname, '..', 'flutter_app', 'lib', 'main.dart'), 'utf8');

test('unread conversations include private chats and groups', () => {
  const start = source.indexOf('final visibleUsers = _tab == 1');
  const end = source.indexOf('final conversationItems', start);
  const filter = source.slice(start, end);

  assert.match(filter, /widget\.unreadCounts\[u\['id'\]\]/);
  assert.match(filter, /_tab == 1[\s\S]*?widget\.groupUnreadCounts\[g\['id'\]\]/);
  assert.match(filter, /\.contains\(_searchQuery\)/);
});
