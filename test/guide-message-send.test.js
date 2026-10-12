'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { registerGuideMessageSend } = require('../server/guide-message-send');
const { generateGuideAnswer, localGuideAnswer } = require('../server/system-guide-ai');
const { UnicodeEmojiModerationError } = require('../server/unicode-emoji-moderation');
const source = '11111111-1111-4111-8111-111111111111';
const recipient = '22222222-2222-4222-8222-222222222222';

function harness({ owned = true, contact = true, blocked = false, failed = false, teen = false,
  preflight, draftBodies, beforeSend } = {}) {
  const routes = {};
  const queries = [];
  const events = [];
  let receipt;
  let sends = 0;
  let effects = 0;
  let connections = 0;
  let releases = 0;
  let draftReads = 0;
  let lastRequest;
  const client = {
    async query(sql, args) {
      queries.push(sql);
      events.push(sql);
      if (sql.includes('SELECT body FROM messages')) {
        const body = draftBodies ? draftBodies[Math.min(draftReads++, draftBodies.length - 1)]
          : 'betshuva://message-draft/eyJ0ZXh0IjoiIn0';
        return { rows: owned && body !== null ? [{ body }] : [] };
      }
      if (sql.includes('SELECT result')) return { rows: receipt ? [{ result: receipt }] : [] };
      if (sql.includes('FROM user_contacts')) return { rows: contact ? [{}] : [] };
      if (sql.includes('FROM blocked_users')) return { rows: blocked ? [{}] : [] };
      if (sql.includes('INSERT INTO guide_message_sends')) receipt = JSON.parse(args[2]);
      return { rows: [] };
    }, release() { releases++; },
  };
  registerGuideMessageSend({ get(path, ...handlers) { routes[`GET ${path}`] = handlers.at(-1); },
    post(path, ...handlers) { routes[`POST ${path}`] = handlers.at(-1); } }, {
    auth() {}, rateLimit() {}, getPool: async () => ({ ...client, connect: async () => {
      connections++; events.push('connect'); return client;
    } }),
    preflight: preflight && (async req => {
      events.push('preflight:start');
      await preflight(req);
      events.push('preflight:end');
    }),
    systemUserId: 'guide', safeInformationUserId: 'safe', scanBotId: 'scan',
    sendGroupMessage: async (req, res) => {
      if (beforeSend) beforeSend(req);
      assert.equal(req.messagePool, client);
      assert.equal(req.params.id, recipient);
      assert.deepEqual(Object.keys(req.body), ['text']);
      sends++;
      req.messageEffects.push(() => { assert.equal(queries.at(-1), 'COMMIT'); effects++; });
      return failed ? res.status(403).json({error:'not a member'}) : res.json({id:'group-saved'});
    },
    sendMessage: async (req, res) => {
      if (beforeSend) beforeSend(req);
      assert.equal(req.messagePool, client);
      assert.deepEqual(Object.keys(req.body).sort(), ['text', 'toUserId']);
      assert.ok(queries.some(q => q.includes('pg_advisory_xact_lock')));
      sends++;
      req.messageEffects.push(() => { assert.equal(queries.at(-1), 'COMMIT'); effects++; });
      return failed ? res.status(403).json({ error: 'filtered' })
        : res.json({ id: 'saved-message', status: 'sent' });
    },
  });
  return { queries, events, get sends() { return sends; }, get effects() { return effects; },
    get connections() { return connections; }, get releases() { return releases; },
    get lastRequest() { return lastRequest; },
    async send(body = { toUserId: recipient, text: 'שלום', confirmed: true }) {
      const result = { code: 200, value: null, status(code) { this.code = code; return this; },
        json(value) { this.value = value; return this; } };
      lastRequest = { user: { id: 'owner', isTeen: teen }, params: { id: source }, body };
      await routes['POST /api/guide-message-drafts/:id/send'](lastRequest, result);
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

test('group drafts require one destination and explicit approval, and never duplicate delivery', async () => {
  const h=harness();
  assert.equal((await h.send({toUserId:recipient,groupId:recipient,text:'hello',confirmed:true})).code,400);
  assert.equal((await h.send({groupId:recipient,text:'hello'})).code,400);
  for(let i=0;i<2;i++) assert.equal((await h.send({groupId:recipient,text:'hello',confirmed:true})).code,200);
  assert.equal(h.sends,1);assert.equal(h.effects,1);
});
test('teen or group policy rejection cannot persist a guide receipt or publish delivery', async () => {
  for(const options of [{teen:true},{failed:true}]) {
    const h=harness(options);
    assert.equal((await h.send({groupId:recipient,text:'hello',confirmed:true})).code,403);
    assert.equal(h.effects,0);
    assert.ok(!h.queries.some(q=>q.includes('INSERT INTO guide_message_sends')));
  }
});

test('guide preflight rejection preserves public status/code without BEGIN, locks or delivery', async () => {
  for (const group of [false, true]) {
    for (const [status, code] of [[422, 'EMOJI_CONTENT_BLOCKED'], [503, 'EMOJI_SCAN_PENDING']]) {
      const h = harness({ preflight: async req => {
        assert.equal(req.messagePool, undefined);
        assert.equal(req.params.id, group ? recipient : source);
        assert.deepEqual(req.body, group ? { text: 'שלום 🫎' } : { toUserId: recipient, text: 'שלום 🫎' });
        const error = new UnicodeEmojiModerationError(status, code, 'ההודעה לא נשלחה');
        error.providerResponse = 'private-provider-detail';
        throw error;
      } });
      const result = await h.send({ [group ? 'groupId' : 'toUserId']: recipient,
        text: '  שלום 🫎  ', confirmed: true });
      assert.equal(result.code, status);
      assert.deepEqual(result.value, { error: 'ההודעה לא נשלחה', code });
      assert.equal(h.connections, 0);
      assert.equal(h.sends, 0);
      assert.equal(h.effects, 0);
      assert.ok(!h.queries.some(sql => /BEGIN|advisory|INSERT|ROLLBACK/.test(sql)));
      assert.equal(h.lastRequest.params.id, source);
      assert.doesNotMatch(JSON.stringify(result.value), /private-provider/);
    }
  }
});

test('async guide preflight completes before connect and reuses its server-owned result in the sender', async () => {
  for (const group of [false, true]) {
    let finish;
    const gate = new Promise(resolve => { finish = resolve; });
    const prepared = { textHash: 'immutable-fixture', classification: { category: 'nonHumanImages' } };
    const h = harness({ preflight: async req => {
      await gate;
      req.unicodeEmojiScan = prepared;
    }, beforeSend: req => {
      assert.equal(req.unicodeEmojiScan, prepared);
      assert.equal(req.body.text, 'שלום 🫎');
      assert.ok(h.events.indexOf('preflight:end') < h.events.indexOf('BEGIN'));
    } });
    const sending = h.send({ [group ? 'groupId' : 'toUserId']: recipient,
      text: '  שלום 🫎  ', confirmed: true });
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(h.events.at(-1), 'preflight:start');
    assert.equal(h.connections, 0);
    assert.equal(h.sends, 0);
    finish();
    assert.equal((await sending).code, 200);
    assert.ok(h.events.indexOf('preflight:end') < h.events.indexOf('connect'));
    assert.ok(h.queries.some(sql => sql.includes('SELECT body FROM messages') && sql.includes('FOR SHARE')));
    assert.equal(h.sends, 1);
    assert.equal(h.effects, 1);
    assert.equal(h.releases, 1);
    assert.equal(h.lastRequest.params.id, source);
  }
});

test('guide replay reads its completed receipt before preflight and cannot send or scan twice', async () => {
  let scans = 0;
  const h = harness({ preflight: async () => { scans++; } });
  const first = await h.send();
  const second = await h.send({ groupId: recipient, text: 'different destination', confirmed: true });
  assert.deepEqual(second.value, first.value);
  assert.equal(scans, 1);
  assert.equal(h.connections, 1);
  assert.equal(h.sends, 1);
  assert.equal(h.effects, 1);
});

test('editing or deleting a guide draft during preflight prevents sending the old confirmation', async () => {
  const original = 'betshuva://message-draft/eyJ0ZXh0IjoiIn0';
  for (const changed of ['betshuva://message-draft/changedPayload', null, 'draft removed']) {
    const h = harness({ draftBodies: [original, changed], preflight: async () => {} });
    const response = await h.send();
    assert.equal(response.code, changed?.includes('message-draft/') ? 409 : 404);
    assert.equal(h.sends, 0);
    assert.equal(h.effects, 0);
    assert.equal(h.queries.at(-1), 'ROLLBACK');
    assert.ok(!h.queries.some(sql => sql.includes('INSERT INTO guide_message_sends')));
    assert.equal(h.releases, 1);
  }
});

test('an unowned guide draft cannot invoke preflight or allocate a transaction', async () => {
  let scans = 0;
  const h = harness({ owned: false, preflight: async () => { scans++; } });
  assert.equal((await h.send()).code, 404);
  assert.equal(scans, 0);
  assert.equal(h.connections, 0);
  assert.equal(h.sends, 0);
  assert.equal(h.queries.length, 1);
});

test('input validation and teen restrictions still run before guide preflight', async () => {
  let scans = 0;
  const h = harness({ teen: true, preflight: async () => { scans++; } });
  assert.equal((await h.send({ toUserId: recipient, text: 'שלום' })).code, 400);
  assert.equal((await h.send({ groupId: recipient, text: 'שלום', confirmed: true })).code, 403);
  assert.equal(scans, 0);
  assert.deepEqual(h.queries, []);
});

test('preflight approval does not bypass current contact and normal send restrictions', async () => {
  for (const options of [{ contact: false }, { blocked: true }, { failed: true }]) {
    let scans = 0;
    const h = harness({ ...options, preflight: async () => { scans++; } });
    assert.equal((await h.send()).code, 403);
    assert.equal(scans, 1);
    assert.equal(h.effects, 0);
    assert.equal(h.queries.at(-1), 'ROLLBACK');
    assert.ok(!h.queries.some(sql => sql.includes('INSERT INTO guide_message_sends')));
  }
});

test('unexpected guide preflight errors do not expose provider detail or create a transaction', async () => {
  const originalError = console.error;
  console.error = () => {};
  try {
    const h = harness({ preflight: async () => { throw new Error('private-provider-token/response'); } });
    const result = await h.send();
    assert.equal(result.code, 500);
    assert.deepEqual(result.value, { error: 'לא ניתן לשלוח כעת. אפשר לנסות שוב בבטחה.' });
    assert.equal(h.connections, 0);
    assert.equal(h.sends, 0);
    assert.ok(!h.queries.some(sql => /BEGIN|ROLLBACK|INSERT/.test(sql)));
  } finally { console.error = originalError; }
});
