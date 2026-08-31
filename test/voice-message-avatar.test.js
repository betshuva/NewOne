'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const source = fs.readFileSync(
  path.join(__dirname, '..', 'flutter_app', 'lib', 'main.dart'), 'utf8');

test('voice messages show the recorder profile photo instead of a generic icon', () => {
  const player = source.slice(
    source.indexOf('class VoiceMessagePlayer'),
    source.indexOf('class _ChatVideoPlayer'));
  assert.match(player, /final String\? senderAvatarUrl/);
  assert.match(player, /UserAvatar\([\s\S]*picUrl: widget\.senderAvatarUrl/);
  assert.doesNotMatch(player, /Icons\.person/);
});

test('private and group voice messages resolve the actual sender avatar', () => {
  assert.match(source, /senderAvatarUrl: isMe[\s\S]*profile_pic_url/);
  assert.match(source, /'senderId': map\['sender_id'\]/);
  assert.match(source, /_voiceMessageSender\(\s*msg, isMe\)/);
});

test('a single group image keeps and displays its classification', () => {
  const server = fs.readFileSync(
    path.join(__dirname, '..', 'server', 'index.js'), 'utf8');
  assert.match(server, /status: 'sent',\s*classification, deliverySummary/);
  assert.match(source, /sendData\['classification'\] \?\? data\['classification'\]/);
  assert.match(
    source,
    /child: _ImageStatusBadge\([\s\S]{0,700}_ImageClassificationBadges\([\s\S]{0,100}message: msg/);
});
