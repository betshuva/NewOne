'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { withPrivateMessageReceipt } = require('../server/private-message-receipts');
const { UnicodeEmojiModerationError } = require('../server/unicode-emoji-moderation');

function harness({ preflight, excludedRecipients = [], failure } = {}) {
  const events = [];
  const receipts = new Map();
  let sends = 0;
  let effects = 0;
  let connections = 0;
  let releases = 0;
  const client = { async query(sql, args) {
    events.push(sql);
    if (sql.includes('SELECT request_hash,result')) {
      const saved = receipts.get(`${args[0]}:${args[1]}`);
      return { rows: saved ? [saved] : [] };
    }
    if (sql.includes('INSERT INTO private_message_sends'))
      receipts.set(`${args[0]}:${args[1]}`, { request_hash: args[2], result: JSON.parse(args[3]) });
    return { rows: [] };
  }, release() { releases++; } };
  const pool = { query: client.query, async connect() {
    connections++;
    events.push('connect');
    return client;
  } };
  const handler = withPrivateMessageReceipt({ getPool: async () => pool,
    excludedRecipients, preflight: preflight && (async req => {
      events.push('preflight:start');
      await preflight(req);
      events.push('preflight:end');
    }), sendMessage: async (req, res) => {
      events.push('send');
      sends++;
      if (preflight) assert.equal(req.unicodeEmojiScan?.textHash, 'approved-fixture');
      if (req.messagePool) {
        assert.equal(req.messagePool, client);
        req.messageEffects.push(() => {
          assert.equal(events.at(-1), 'COMMIT');
          effects++;
        });
      }
      return failure ? res.status(403).json({ error: 'filtered' })
        : res.json({ id: `message-${sends}`, status: 'sent' });
    } });
  return { events, get sends() { return sends; }, get effects() { return effects; },
    get connections() { return connections; }, get releases() { return releases; },
    async send(body = {}, userId = 'owner') {
      const res = { code: 200, status(code) { this.code = code; return this; },
        json(value) { this.value = value; return this; } };
      await handler({ user: { id: userId }, body: { toUserId: 'peer', text: 'שלום 🫎', ...body } }, res);
      return res;
    } };
}

const clientMessageId = 'preflight_message_key_123';
const approve = async req => { req.unicodeEmojiScan = { textHash: 'approved-fixture', classification: null }; };

test('blocked and pending preflight responses preserve public status/code before any transaction or send', async () => {
  for (const [status, code] of [[422, 'EMOJI_CONTENT_BLOCKED'], [503, 'EMOJI_SCAN_PENDING']]) {
    const h = harness({ preflight: async () => {
      const error = new UnicodeEmojiModerationError(status, code, 'ההודעה לא נשלחה');
      error.providerResponse = { secret: 'private-provider-details' };
      throw error;
    } });
    const result = await h.send({ clientMessageId });
    assert.equal(result.code, status);
    assert.deepEqual(result.value, { error: 'ההודעה לא נשלחה', code });
    assert.equal(h.connections, 0);
    assert.equal(h.sends, 0);
    assert.ok(!h.events.some(event => /BEGIN|advisory|INSERT|ROLLBACK/.test(event)));
    assert.doesNotMatch(JSON.stringify(result.value), /private-provider/);
  }
});

test('async preflight finishes before connect, BEGIN and the normal sender', async () => {
  let finish;
  const gate = new Promise(resolve => { finish = resolve; });
  const h = harness({ preflight: async req => { await gate; await approve(req); } });
  const sending = h.send({ clientMessageId });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(h.events.at(-1), 'preflight:start');
  assert.equal(h.connections, 0);
  assert.equal(h.sends, 0);
  finish();
  assert.equal((await sending).code, 200);
  assert.ok(h.events.indexOf('preflight:end') < h.events.indexOf('connect'));
  assert.ok(h.events.indexOf('preflight:end') < h.events.indexOf('BEGIN'));
  assert.ok(h.events.indexOf('BEGIN') < h.events.indexOf('send'));
  assert.equal(h.effects, 1);
  assert.equal(h.releases, 1);
});

test('a completed receipt replays without rerunning preflight or taking a connection', async () => {
  let scans = 0;
  const h = harness({ preflight: async req => { scans++; await approve(req); } });
  const first = await h.send({ clientMessageId });
  const second = await h.send({ clientMessageId });
  assert.deepEqual(second.value, first.value);
  assert.equal(h.sends, 1);
  assert.equal(scans, 1);
  assert.equal(h.connections, 1);
  assert.equal(h.effects, 1);
  assert.equal((await h.send({ clientMessageId, text: 'changed' })).code, 409);
  assert.equal(scans, 1);
  assert.equal(h.connections, 1);
  assert.equal((await h.send({ clientMessageId }, 'other-owner')).code, 200);
  assert.equal(scans, 2);
});

test('preflight also blocks requests without a receipt key and excluded recipients', async () => {
  for (const body of [{}, { clientMessageId: 'invalid', toUserId: 'guide' }]) {
    let scans = 0;
    const h = harness({ excludedRecipients: ['guide'], preflight: async () => {
      scans++;
      throw new UnicodeEmojiModerationError(503, 'EMOJI_SCAN_PENDING', 'יש לנסות שוב');
    } });
    assert.equal((await h.send(body)).code, 503);
    assert.equal(scans, 1);
    assert.equal(h.sends, 0);
    assert.deepEqual(h.events, ['preflight:start']);
  }
});

test('keyless and excluded requests complete preflight before direct delegation', async () => {
  for (const body of [{}, { clientMessageId, toUserId: 'guide' }]) {
    const h = harness({ excludedRecipients: ['guide'], preflight: approve });
    assert.equal((await h.send(body)).code, 200);
    assert.deepEqual(h.events, ['preflight:start', 'preflight:end', 'send']);
    assert.equal(h.connections, 0);
  }
});

test('invalid receipt keys do not invoke preflight or query the database', async () => {
  const h = harness({ preflight: approve });
  assert.equal((await h.send({ clientMessageId: 'invalid' })).code, 400);
  assert.deepEqual(h.events, []);
});

test('unexpected preflight errors expose no provider detail for keyed or direct requests', async () => {
  const originalError = console.error;
  console.error = () => {};
  try {
    for (const body of [{}, { clientMessageId }]) {
      const h = harness({ preflight: async () => { throw new Error('provider private request/token'); } });
      const response = await h.send(body);
      assert.equal(response.code, 500);
      assert.deepEqual(response.value, { error: 'השליחה לא הושלמה. ניתן לנסות שוב בבטחה' });
      assert.equal(h.connections, 0);
      assert.equal(h.sends, 0);
    }
  } finally { console.error = originalError; }
});

test('a sender policy rejection after preflight rolls back without a receipt or effects', async () => {
  const h = harness({ preflight: approve, failure: true });
  assert.equal((await h.send({ clientMessageId })).code, 403);
  assert.equal(h.effects, 0);
  assert.equal(h.events.at(-1), 'ROLLBACK');
  assert.ok(!h.events.some(event => event.includes('INSERT INTO private_message_sends')));
  assert.equal(h.releases, 1);
});

test('legacy requests retain direct delegation and transactional replay without a callback', async () => {
  const direct = harness({ excludedRecipients: ['guide'] });
  assert.equal((await direct.send()).code, 200);
  assert.equal((await direct.send({ toUserId: 'guide', clientMessageId: 'invalid' })).code, 200);
  assert.deepEqual(direct.events, ['send', 'send']);
  const keyed = harness();
  const first = await keyed.send({ clientMessageId });
  assert.deepEqual((await keyed.send({ clientMessageId })).value, first.value);
  assert.equal(keyed.sends, 1);
  assert.equal(keyed.connections, 2);
  assert.equal(keyed.events.filter(event => event === 'BEGIN').length, 2);
});
