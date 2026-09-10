'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { registerGuideMessageSend } = require('../server/guide-message-send');
const { generateGuideAnswer, localGuideAnswer } = require('../server/system-guide-ai');
const source = '11111111-1111-4111-8111-111111111111';
const recipient = '22222222-2222-4222-8222-222222222222';

function harness({ owned = true, contact = true, blocked = false, failed = false } = {}) {
  const routes = {};
  const queries = [];
  let receipt;
  let sends = 0;
  let effects = 0;
  const client = {
    async query(sql, args) {
      queries.push(sql);
      if (sql.includes('SELECT body FROM messages')) return { rows: owned
        ? [{ body: 'betshuva://message-draft/eyJ0ZXh0IjoiIn0' }] : [] };
      if (sql.includes('SELECT result')) return { rows: receipt ? [{ result: receipt }] : [] };
      if (sql.includes('FROM user_contacts')) return { rows: contact ? [{}] : [] };
      if (sql.includes('FROM blocked_users')) return { rows: blocked ? [{}] : [] };
      if (sql.includes('INSERT INTO guide_message_sends')) receipt = JSON.parse(args[2]);
      return { rows: [] };
    }, release() {},
  };
  registerGuideMessageSend({ get(path, ...handlers) { routes[`GET ${path}`] = handlers.at(-1); },
    post(path, ...handlers) { routes[`POST ${path}`] = handlers.at(-1); } }, {
    auth() {}, rateLimit() {}, getPool: async () => ({ ...client, connect: async () => client }),
    systemUserId: 'guide', safeInformationUserId: 'safe', scanBotId: 'scan',
    sendMessage: async (req, res) => {
      assert.equal(req.messagePool, client);
      assert.deepEqual(Object.keys(req.body).sort(), ['text', 'toUserId']);
      assert.ok(queries.some(q => q.includes('pg_advisory_xact_lock')));
      sends++;
      req.messageEffects.push(() => { assert.equal(queries.at(-1), 'COMMIT'); effects++; });
      return failed ? res.status(403).json({ error: 'filtered' })
        : res.json({ id: 'saved-message', status: 'sent' });
    },
  });
  return { queries, get sends() { return sends; }, get effects() { return effects; },
    async send(body = { toUserId: recipient, text: 'שלום', confirmed: true }) {
      const result = { code: 200, value: null, status(code) { this.code = code; return this; },
        json(value) { this.value = value; return this; } };
      await routes['POST /api/guide-message-drafts/:id/send']({ user: { id: 'owner' }, params: { id: source }, body }, result);
      return result;
    },
  };
}

test('no message is sent without explicit confirmation, valid recipient and text', async () => {
  const h = harness();
  for (const body of [{ toUserId: recipient, text: 'שלום' },
    { toUserId: recipient, text: 'שלום', confirmed: 'true' },
    { toUserId: recipient, text: ' ', confirmed: true },
    { toUserId: 'invalid', text: 'שלום', confirmed: true }]) {
    assert.equal((await h.send(body)).code, 400);
  }
  assert.equal(h.sends, 0);
});

test('another user draft, unsaved contacts and blocked recipients cannot be sent', async () => {
  for (const options of [{ owned: false }, { contact: false }, { blocked: true }]) {
    const h = harness(options);
    assert.ok((await h.send()).code >= 400);
    assert.equal(h.sends, 0);
    assert.equal(h.queries.at(-1), 'ROLLBACK');
  }
});

test('confirmation reuses normal sender and commits before notifications; retries cannot send twice', async () => {
  const h = harness();
  assert.equal((await h.send()).code, 200);
  assert.equal((await h.send({ toUserId: recipient, text: 'changed', confirmed: true })).code, 200);
  assert.equal(h.sends, 1);
  assert.equal(h.effects, 1);
});

test('normal messaging rejection rolls back without delivery effects or receipt', async () => {
  const h = harness({ failed: true });
  assert.equal((await h.send()).code, 403);
  assert.equal(h.effects, 0);
  assert.equal(h.queries.at(-1), 'ROLLBACK');
  assert.ok(!h.queries.some(q => q.includes('INSERT INTO guide_message_sends')));
});

test('guide creates a draft, ignoring model claims of sending and without performing actions', async () => {
  const answer = await generateGuideAnswer({ question: 'שלח לנאור שלום', apiKey: 'mock',
    fetchImpl: async () => ({ ok: true, json: async () => ({ output_text: JSON.stringify({
      in_scope: true, answer: 'נשלח!', issue_type: 'none', issue_draft: '',
      message_requested: true, recipient_query: 'נאור', message_text: 'שלום',
    }) }) }),
  });
  assert.match(answer, /message-draft\//);
  assert.doesNotMatch(answer, /נשלח!/);
  const payload = JSON.parse(Buffer.from(answer.split('message-draft/')[1], 'base64url'));
  assert.deepEqual(payload, { recipientQuery: 'נאור', text: 'שלום' });
});

test('offline guide drafts an explicit send command but not how-to questions', () => {
  assert.match(localGuideAnswer('שלח לנאור: שלום'), /message-draft\//);
  assert.doesNotMatch(localGuideAnswer('איך שולחים הודעה?'), /message-draft\//);
});
