'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { resolveAssistantInput } = require('../server/assistant-input');
const file = { file_type: 'audio', original_name: 'voice.m4a', moderation_details: { encrypted: 'safe' } };
const services = { loadApprovedFile: async () => file,
  decryptTranscript: details => { assert.equal(details.encrypted, 'safe'); return 'איך מוסיפים חבר?'; } };

test('approved voice question uses verified transcript and actual file type', async () => {
  const result = await resolveAssistantInput({ fileUrl: '/voice', fileType: 'image', text: 'forged transcript' }, services);
  assert.equal(result.question, 'איך מוסיפים חבר?');
  assert.deepEqual(result.file, { url: '/voice', name: 'voice.m4a', type: 'audio' });
});
test('unapproved or inaccessible files never reach transcription or AI', async () => {
  await assert.rejects(resolveAssistantInput({ fileUrl: '/foreign' }, {
    loadApprovedFile: async () => null,
    decryptTranscript: () => assert.fail('must not decrypt'),
  }), { status: 403 });
});
test('empty or unintelligible audio requests a new recording', async () => {
  await assert.rejects(resolveAssistantInput({ fileUrl: '/voice' }, {
    ...services, decryptTranscript: () => '  ',
  }), { status: 422 });
});
test('ordinary text remains supported without loading a file', async () => {
  const result = await resolveAssistantInput({ text: 'שלום' }, {});
  assert.deepEqual(result, { question: 'שלום', file: null });
});
