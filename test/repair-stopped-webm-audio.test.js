'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs/promises');
const path = require('path');
const { createHash } = require('crypto');
const { verifyAudio } = require('../server/repair-stopped-webm-audio');

function row(bytes, overrides = {}) {
  return { original_name: 'recording.webm', file_type: 'video', mime_type: 'video/webm',
    moderation_status: 'stopped', file_size: bytes.length,
    content_sha256: createHash('sha256').update(bytes).digest('hex'),
    moderation_details: { reasonCode: 'scan_incomplete',
      error: 'The uploaded file is not a readable video' }, ...overrides };
}
const fixture = name => fs.readFile(path.join(__dirname, 'fixtures', name));

test('repair verifies an audio-only WebM and measures duration', async () => {
  const bytes = await fixture('webm-audio.webm');
  assert.ok((await verifyAudio(row(bytes), bytes)).durationSeconds > 0);
});
test('repair refuses real video and corrupt WebM', async () => {
  const bytes = await fixture('webm-video.webm');
  await assert.rejects(verifyAudio(row(bytes), bytes), /contains video/);
  const corrupt = Buffer.from('not a media file');
  await assert.rejects(verifyAudio(row(corrupt), corrupt));
});
test('repair refuses changed content, size and moderation states', async () => {
  const bytes = await fixture('webm-audio.webm');
  await assert.rejects(verifyAudio(row(bytes, { content_sha256: '0'.repeat(64) }), bytes), /checksum/);
  await assert.rejects(verifyAudio(row(bytes, { file_size: bytes.length + 1 }), bytes), /size/);
  for (const moderation_status of ['approved', 'pending', 'rejected']) {
    await assert.rejects(verifyAudio(row(bytes, { moderation_status }), bytes), /eligible/);
  }
  await assert.rejects(verifyAudio(row(bytes, { moderation_details: { reasonCode: 'other_failure' } }), bytes), /eligible/);
});
