'use strict';

const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');

const source = fs.readFileSync(
  path.join(__dirname, '..', 'flutter_app', 'lib', 'main.dart'), 'utf8');

test('normal group messages render outside the blocked-content branch', () => {
  const groupStart = source.indexOf('class GroupChatScreen');
  const branchStart = source.indexOf("if (uploadStatus ==", groupStart);
  const branchEnd = source.indexOf('if (sharedUrl != null)', branchStart);
  const branch = source.slice(branchStart, branchEnd);

  assert.match(branch,
    /uploadStatus ==\s*'blocked_content' &&\s*uploadFileType !=\s*'image'/);
  assert.match(branch,
    /else if \(uploadStatus ==\s*'blocked_content'\)\s*const SizedBox\s*\.shrink\(\)\s*else if \(avielSticker !=\s*null\)/);
  assert.match(branch, /else if \(sharedContact !=\s*null\)/);
  assert.match(branch, /else\s*InlineEmojiText\(\s*msg\['text'\]/);
});

test('group message bubbles size themselves to their content', () => {
  const groupStart = source.indexOf('class GroupChatScreen');
  const bubbleStart = source.indexOf('child: Column(', groupStart);
  const bubble = source.slice(bubbleStart, bubbleStart + 500);
  assert.match(bubble, /mainAxisSize: MainAxisSize\.min/);
});
