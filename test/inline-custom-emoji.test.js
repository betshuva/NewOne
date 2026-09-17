'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const {
  inlineEmojiModerationText,
  inlineEmojiPlainText,
} = require('../server/inline-custom-emoji');

const source = fs.readFileSync(require.resolve('../server/index.js'), 'utf8');
const moderationStart = source.indexOf('const DEFAULT_FEMALE_LABELS =');
const moderationEnd = source.indexOf('function redactHarmfulLanguageForDisplay', moderationStart);
assert.ok(moderationStart >= 0 && moderationEnd > moderationStart);
const moderateChatText = vm.runInNewContext(
  `${source.slice(moderationStart, moderationEnd)}; moderateChatText`,
  { inlineEmojiModerationText },
);

test('only exact catalog IDs 001 through 150 are decorative moderation tokens', () => {
  for (let id = 1; id <= 150; id++) {
    const marker = `[[bt-emoji:${String(id).padStart(3, '0')}]]`;
    assert.equal(inlineEmojiModerationText(`a${marker}b`), 'a b');
  }
  for (const text of [
    '[[bt-emoji:000]]', '[[bt-emoji:151]]', '[[bt-emoji:999]]',
    '[[bt-emoji:1]]', '[[bt-emoji:0001]]', '[[BT-EMOJI:001]]',
    '[[bt-emoji:001]', '[bt-emoji:001]]', '[[bt-emoji: 001]]',
    '[[bt-emoji:../file.png]]', '[[bt-emoji:https://example.test/file.png]]',
    '[[bt-emoji:００１]]', 'שלום 😀 ordinary text',
  ]) {
    assert.equal(inlineEmojiModerationText(text), text);
    assert.equal(inlineEmojiPlainText(text), text);
  }
});

test('push text uses original catalog labels while preserving surrounding content', () => {
  assert.equal(inlineEmojiPlainText('שלום [[bt-emoji:001]]!'), 'שלום [שמחה]!');
  assert.equal(inlineEmojiPlainText('[[bt-emoji:150]]'), '[זהירות מקישור לא ידוע]');
  assert.equal(inlineEmojiPlainText('[[bt-emoji:001]][[bt-emoji:001]]'), '[שמחה][שמחה]');
  assert.equal(inlineEmojiPlainText('https://example.test/ שלום'), 'https://example.test/ שלום');
});

test('push labels have a readable fallback without the optional catalog', () => {
  const helper = fs.readFileSync(require.resolve('../server/inline-custom-emoji'), 'utf8');
  const exports = vm.runInNewContext(`${helper}; module.exports`, {
    module: { exports: {} },
    require() { throw new Error('artwork catalog missing'); },
  });
  assert.equal(exports.inlineEmojiPlainText('שלום [[bt-emoji:150]]'), 'שלום [אימוג׳י]');
  assert.equal(exports.inlineEmojiPlainText('[[bt-emoji:151]]'), '[[bt-emoji:151]]');
});

test('actual moderation still recognizes harmful phrases around inline images', () => {
  for (const text of [
    'i will kill you',
    'i [[bt-emoji:001]] will kill you',
    'i[[bt-emoji:150]]will[[bt-emoji:099]]kill you',
    'אני [[bt-emoji:150]] אהרוג אותך',
    '[[bt-emoji:001]]מטומטם[[bt-emoji:150]]',
  ]) {
    assert.equal(moderateChatText(text).blocked, true, text);
  }
  for (const text of ['שלום לכולם', 'שלום [[bt-emoji:001]]', '[[bt-emoji:150]]', 'class assignment']) {
    assert.equal(moderateChatText(text).blocked, false, text);
  }
});

test('actual push sends readable labels without mutating persisted wire text', async () => {
  const start = source.indexOf('async function sendPush(');
  const end = source.indexOf('// ── File upload setup', start);
  assert.ok(start >= 0 && end > start);
  const sent = [];
  const sendPush = vm.runInNewContext(`${source.slice(start, end)}; sendPush`, {
    inlineEmojiPlainText,
    getPool: async () => ({ query: async () => ({ rows: [{ token: 'fixture-token' }] }) }),
    getFirebaseMessaging: () => ({
      async sendEachForMulticast(payload) {
        sent.push(payload);
        return { responses: [{ success: true }] };
      },
    }),
    console: { error(...args) { assert.fail(args.join(' ')); } },
  });
  const wire = 'שלום [[bt-emoji:001]]';
  await sendPush('recipient', 'Sender', wire, { type: 'chat', fromUserId: 'sender' });
  assert.equal(sent.length, 1);
  assert.equal(sent[0].notification.body, 'שלום [שמחה]');
  assert.equal(wire, 'שלום [[bt-emoji:001]]');
});

async function privateSend(text, { allowText = true, linkError } = {}) {
  const writes = [];
  const links = [];
  const policyTypes = [];
  const pool = { async query(sql, values) {
    if (sql.includes('INSERT INTO messages ')) {
      writes.push(values);
      return { rows: [{ id: 'saved', created_at: '2026-09-17' }] };
    }
    if (sql.includes('INSERT INTO message_requests')) assert.fail('self notes need no contact request');
    return { rows: [] };
  } };
  const start = source.indexOf('async function sendPrivateHttpMessage(');
  const end = source.indexOf("app.post('/api/messages',", start);
  assert.ok(start >= 0 && end > start);
  const handler = vm.runInNewContext(`${source.slice(start, end)}; sendPrivateHttpMessage`, {
    SYSTEM_USER_ID: 'guide', SAFE_INFORMATION_USER_ID: 'info',
    normalizeBuiltinStickerId: () => null,
    moderateChatText, recordBlockedChat() {}, clientIp: () => '127.0.0.1',
    async verifyMessageLinks(value) { links.push(value); if (linkError) throw linkError; },
    LINK_BLOCKED_MESSAGE: 'unsafe link',
    getPool: async () => pool, teenContactAllowed: async () => true,
    getEffectiveRecipientFilter: async () => ({ filter: { text: allowText } }),
    contentAllowedByFilter(_filter, type) { policyTypes.push(type); return allowText; },
    recordFilterDecision: async () => {}, notifyDestinationFilterBlock: async () => {},
    writeSenderFilteredMedia: async (_pool, options, write) => {
      assert.equal(options.fileUrl, undefined);
      return write(pool);
    },
    onlineUsers: new Map(), logActivity() {}, sendPush() {},
    console: { warn() {}, error(...args) { assert.fail(args.join(' ')); } },
  });
  const response = { code: 200, status(code) { this.code = code; return this; },
    json(body) { this.body = body; return this; } };
  await handler({ user: { id: 'me', name: 'Me' }, body: { toUserId: 'me', text } }, response);
  return { response, writes, links, policyTypes };
}

test('actual send stores wire markers as text and still applies destination policy', async () => {
  const wire = 'שלום [[bt-emoji:001]][[bt-emoji:150]]';
  const allowed = await privateSend(wire);
  assert.equal(allowed.response.code, 200);
  assert.equal(allowed.writes.length, 1);
  assert.equal(allowed.writes[0][2], wire);
  assert.equal(allowed.writes[0][3], 'text');
  assert.deepEqual(allowed.links, [wire]);
  assert.deepEqual(allowed.policyTypes, ['text']);
  const denied = await privateSend(wire, { allowText: false });
  assert.equal(denied.response.code, 403);
  assert.equal(denied.response.body.code, 'RECIPIENT_CONTENT_FILTERED');
  assert.equal(denied.writes.length, 0);
  assert.deepEqual(denied.policyTypes, ['text']);
});

test('inline markers grant no exemption from harmful text or URL checks', async () => {
  const harmful = await privateSend('i [[bt-emoji:001]] will kill you');
  assert.equal(harmful.response.code, 422);
  assert.equal(harmful.response.body.code, 'CHAT_CONTENT_BLOCKED');
  assert.equal(harmful.writes.length, 0);
  const wire = '[[bt-emoji:001]] https://unsafe.example.test';
  const unsafe = await privateSend(wire, { linkError: new Error('unsafe fixture URL') });
  assert.equal(unsafe.response.code, 422);
  assert.equal(unsafe.response.body.code, 'UNSAFE_LINK');
  assert.equal(unsafe.writes.length, 0);
  assert.deepEqual(unsafe.links, [wire]);
});
