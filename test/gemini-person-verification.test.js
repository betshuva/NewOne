'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { createRequire } = require('node:module');
const sharp = require('sharp');
const { PERSON_PRESENCE_PROMPT } = require('../server/person-presence-decision');

function fixture(env = {}) {
  const events = [], calls = [], cache = new Map();
  const pool = { query: async (sql, values) => {
    if (/INSERT INTO moderation_provider_calls/.test(sql)) calls.push(values);
    return { rows: [], rowCount: 0 };
  } };
  const modules = new Set(['gemini-person-verification', 'provider-usage-log',
    'moderation-provider-guard', 'moderation-provider-policy']);
  const load = name => {
    if (cache.has(name)) return cache.get(name).exports;
    const filename = require.resolve(`../server/${name}`);
    const actualRequire = createRequire(filename), module = { exports: {} };
    cache.set(name, module);
    const requireMock = request => {
      if (request === './db') return { getPool: async () => pool };
      if (request === './system-audit') return { getAuditContext: () => ({ operationId: 'synthetic-operation' }) };
      if (request === './system-audit-context') return { observeAudit: async (_db, event) => {
        events.push(JSON.parse(JSON.stringify(event)));
      } };
      if (request.startsWith('./') && modules.has(request.slice(2))) return load(request.slice(2));
      return actualRequire(request);
    };
    vm.runInNewContext(`(function(require,module,exports){${fs.readFileSync(filename, 'utf8')}\n})`, {
      Buffer, performance, AbortSignal, console: { warn() {} },
      process: { env: { DATABASE_URL: 'synthetic', MODERATION_OPENAI_ENABLED: 'false', ...env } },
    }, { filename })(requireMock, module, module.exports);
    return module.exports;
  };
  const { classifyGeminiPersonPresence: classify, PERSON_RESPONSE_SCHEMA } = load('gemini-person-verification');
  return { classify, schema: PERSON_RESPONSE_SCHEMA, events, calls, pool,
    options: { apiKey: 'synthetic-key', skipImagePreparation: true,
      tracking: { storedFileId: '10000000-0000-4000-8000-000000000001',
        scanPreviewId: '20000000-0000-4000-8000-000000000002',
        videoBudget: { scanId: 'test-scan', leaseToken: 'test-lease', frameIndex: 2, timestampSeconds: 1.5 } } } };
}

const response = (body, status = 200) => ({ ok: status >= 200 && status < 300, status, json: async () => body });
const personBody = () => ({ candidates: [{ content: { parts: [{ text: JSON.stringify({
  decision: 'person', person_categories: ['women', 'children'], person_category: 'women',
  confidence: 0.95, reason: 'private provider reason',
}) }] } }], usageMetadata: { promptTokenCount: 300, candidatesTokenCount: 20,
  thoughtsTokenCount: 5, totalTokenCount: 325 } });
const nonVideo = f => ({ ...f.options, tracking: { ...f.options.tracking, videoBudget: undefined } });

test('Gemini person review uses the shared policy, structured output and exactly one accounting/audit result', async () => {
  const f = fixture();
  let request;
  const result = await f.classify(Buffer.from('image'), {
    ...nonVideo(f), fetchImpl: async (url, options) => {
      request = { url, options, body: JSON.parse(options.body) };
      return response(personBody());
    },
  });
  assert.equal(request.body.store, false);
  assert.match(request.url, /gemini-3\.5-flash-lite:generateContent$/);
  assert.doesNotMatch(request.url, /synthetic-key/);
  assert.equal(request.options.headers['x-goog-api-key'], 'synthetic-key');
  assert.equal(request.body.contents[0].parts[0].text, PERSON_PRESENCE_PROMPT);
  assert.deepEqual(request.body.generationConfig.responseJsonSchema, JSON.parse(JSON.stringify(f.schema)));
  assert.equal(request.body.generationConfig.responseMimeType, 'application/json');
  assert.equal(result.available, true);
  assert.deepEqual(Array.from(result.personCategories), ['women', 'children']);
  assert.equal(result.usage.totalTokens, 325);
  assert.equal(f.calls.length, 1);
  assert.equal(f.calls[0][3], 'gemini');
  assert.equal(f.calls[0][5], 'person_presence');
  assert.equal(f.calls[0][12], 325);
  assert.equal(f.events.length, 1);
  assert.equal(f.events[0].details.checkType, 'person_presence');
  assert.equal(f.events[0].details.checkOutcome, 'passed');
  assert.ok(f.events[0].details.checkFindings.includes('women'));
  assert.equal(f.events[0].details.scanPreviewId, f.options.tracking.scanPreviewId);
  assert.doesNotMatch(JSON.stringify(f.events), /private provider reason|synthetic-key/);
});

test('Gemini person model configuration follows explicit, person, modesty then default settings', async () => {
  for (const [env, explicit, expected] of [
    [{ GEMINI_PERSON_MODEL: 'person-model', GEMINI_MODESTY_MODEL: 'modesty-model' }, 'chosen-model', 'chosen-model'],
    [{ GEMINI_PERSON_MODEL: 'person-model', GEMINI_MODESTY_MODEL: 'modesty-model' }, undefined, 'person-model'],
    [{ GEMINI_MODESTY_MODEL: 'modesty-model' }, undefined, 'modesty-model'],
    [{}, undefined, 'gemini-3.5-flash-lite'],
  ]) {
    const f = fixture(env);
    const result = await f.classify(Buffer.from('image'), { ...nonVideo(f), model: explicit,
      fetchImpl: async url => { assert.ok(url.endsWith(`/${expected}:generateContent`)); return response(personBody()); } });
    assert.equal(result.model, expected);
  }
});

test('malformed person results never retry and retain billed usage and one failed audit event', async () => {
  for (const body of [null, [], { candidates: [{ content: { parts: {} } }] },
    { candidates: [{ content: { parts: [null, { text: 42 }] } }] },
    { candidates: [{ content: { parts: [{ text: 'decision: person' }] } }],
      usageMetadata: { promptTokenCount: 20, candidatesTokenCount: 5, totalTokenCount: 25 } }]) {
    const f = fixture();
    let requests = 0;
    const result = await f.classify(Buffer.from('image'), { ...nonVideo(f),
      fetchImpl: async () => { requests++; return response(body); } });
    assert.equal(requests, 1);
    assert.equal(result.available, false);
    assert.equal(result.errorCode, 'INVALID_RESPONSE');
    assert.equal(f.calls.length, 1);
    assert.equal(f.calls[0][12], body?.usageMetadata ? 25 : 0);
    assert.equal(f.events.length, 1);
    assert.equal(f.events[0].details.checkOutcome, 'failed');
  }
});

test('Gemini person safety blocks and HTTP failures remain unavailable without fallback calls', async () => {
  for (const [body, status, errorCode] of [
    [{ promptFeedback: { blockReason: 'SAFETY' } }, 200, 'SAFETY_BLOCKED'],
    [{ candidates: [{ finishReason: 'SAFETY' }] }, 200, 'SAFETY_BLOCKED'],
    [{ error: { status: 'RESOURCE_EXHAUSTED', message: 'quota' } }, 429, 'RESOURCE_EXHAUSTED'],
  ]) {
    const f = fixture();
    let requests = 0;
    const result = await f.classify(Buffer.from('image'), { ...nonVideo(f),
      fetchImpl: async () => { requests++; return response(body, status); } });
    assert.equal(requests, 1);
    assert.equal(result.available, false);
    assert.equal(result.errorCode, errorCode);
    assert.equal(f.calls.length, 1);
    assert.equal(f.events.length, 1);
    assert.equal(f.events[0].details.checkOutcome, 'failed');
  }
});

test('unconfigured and invalid-image Gemini person checks cannot make HTTP calls or accounting rows', async () => {
  for (const options of [{ apiKey: '' }, { skipImagePreparation: false }]) {
    const f = fixture();
    const result = await f.classify(Buffer.from('invalid-image'), { ...nonVideo(f), ...options,
      fetchImpl: async () => assert.fail('preparation failures must not make requests') });
    assert.equal(result.available, false);
    assert.equal(f.calls.length, 0);
    assert.equal(f.events.length, 1);
    assert.equal(f.events[0].details.auditOnly, true);
  }
});

test('Gemini person review sends a bounded metadata-free JPEG', async () => {
  const f = fixture();
  const source = await sharp({ create: { width: 1200, height: 900, channels: 3,
    background: 'white' } }).withMetadata().png().toBuffer();
  const result = await f.classify(source, { ...nonVideo(f), skipImagePreparation: false,
    fetchImpl: async (_url, options) => {
      const part = JSON.parse(options.body).contents[0].parts.find(value => value.inlineData);
      assert.equal(part.inlineData.mimeType, 'image/jpeg');
      const metadata = await sharp(Buffer.from(part.inlineData.data, 'base64')).metadata();
      assert.equal(metadata.format, 'jpeg');
      assert.ok(metadata.width <= 768 && metadata.height <= 768);
      assert.equal(metadata.exif, undefined);
      return response(personBody());
    } });
  assert.equal(result.available, true);
});

test('Gemini person review reserves the correct budget operation and cached results do not repeat HTTP', async () => {
  const f = fixture();
  let cached, requests = 0;
  const ledger = {
    reserveVideoScanOperation: async (pool, args) => {
      assert.equal(pool, f.pool);
      assert.equal(args.provider, 'gemini');
      assert.equal(args.operation, 'person_presence');
      assert.equal(args.frameIndex, 2);
      return cached ? { status: 'cached', result: cached }
        : { status: 'reserved', reservationId: 'reservation' };
    },
    finishVideoScanOperation: async (_pool, args) => {
      cached = args.result;
      return { status: 'completed' };
    },
    getProviderSuspension: async () => assert.fail('Gemini cannot consult OpenAI suspension'),
  };
  const options = { ...f.options, providerGuardDependencies: { pool: f.pool, ledger },
    fetchImpl: async () => { requests++; return response(personBody()); } };
  await f.classify(Buffer.from('image'), options);
  const second = await f.classify(Buffer.from('image'), options);
  assert.equal(requests, 1);
  assert.equal(f.calls.length, 1);
  assert.equal(second.cacheHit, true);
  assert.equal(f.events.length, 2);
  assert.equal(f.events[1].details.checkType, 'person_presence');
  assert.equal(f.events[1].details.frameIndex, 2);
  assert.equal(f.events[1].details.frameTimestampMs, 1500);
  assert.equal(f.events[1].details.auditOnly, true);
});
