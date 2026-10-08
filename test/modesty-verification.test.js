'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const {
  classifyOpenAIModesty,
  classifyOpenAIModestyUncertaintyReview,
  MODESTY_UNCERTAINTY_REVIEW_PROMPT,
  MODESTY_RESPONSE_SCHEMA,
  UNCERTAINTY_REVIEW_TIMEOUT_MS,
  parseModestyDecision,
} = require('../server/modesty-verification');

// Provider helpers must not log to an application database in unit tests.
delete process.env.DATABASE_URL;

function reviewResponse(overrides = {}) {
  return { ok: true, json: async () => ({ output_text: JSON.stringify({
    decision: 'modest', confidence: 0.96, violationClearlyVisible: false,
    visibleEvidence: 'הכתפיים והחזה הנראים מכוסים בחולצה',
    visibleAreasDecision: 'compliant', uncertaintyReason: 'none',
    reason: 'הלבוש הנראה עומד בכללים', ...overrides,
  }), usage: { input_tokens: 320, output_tokens: 40, total_tokens: 360 } }) };
}

function reviewHarness() {
  const calls = [], guards = [], timeouts = [];
  const module = { exports: {} };
  vm.runInNewContext(fs.readFileSync(require.resolve('../server/modesty-verification'), 'utf8'), {
    module, process: { env: {} }, performance, Buffer,
    require(name) {
      if (name === './provider-usage-log') return {
        recordProviderCall: async event => calls.push(event),
      };
      if (name === './moderation-provider-guard') return {
        guardModerationProvider: async args => {
          guards.push(args);
          return args.run();
        },
        providerRequestSignal(options, milliseconds) {
          timeouts.push(milliseconds);
          return options.signal || options.tracking?.videoBudget?.signal;
        },
      };
      throw new Error(`Unexpected dependency: ${name}`);
    },
  });
  return { classify: module.exports.classifyOpenAIModestyUncertaintyReview,
    calls, guards, timeouts };
}

test('modesty parser accepts only the three fail-closed decisions', () => {
  assert.deepEqual(parseModestyDecision(
    '{"decision":"non_modest","confidence":0.97,"violationClearlyVisible":true,"visibleEvidence":"קו מכפלת ורגל חשופה","reason":"מכנסיים קצרים"}'),
  { decision: 'non_modest', confidence: 0.97, reason: 'מכנסיים קצרים',
    violationClearlyVisible: true, visibleEvidence: 'קו מכפלת ורגל חשופה' });
  assert.equal(parseModestyDecision('{"decision":"safe","confidence":1}'), null);
});

test('unsupported clothing inference is downgraded to uncertain', () => {
  const result = parseModestyDecision(
    '{"decision":"non_modest","confidence":0.99,"violationClearlyVisible":false,"visibleEvidence":"","reason":"כנראה מכנסיים קצרים"}');
  assert.equal(result.decision, 'uncertain');
  assert.equal(result.unsupportedViolation, true);
});

test('independent modesty review sends the strict policy and parses its result', async () => {
  let requestBody;
  const result = await classifyOpenAIModesty(Buffer.from('image'), {
    apiKey: 'test-key',
    fetchImpl: async (_url, options) => {
      requestBody = JSON.parse(options.body);
      return {
        ok: true,
        json: async () => ({ output_text:
          '{"decision":"uncertain","confidence":0.71,"reason":"cropped"}' }),
      };
    },
  });
  assert.equal(requestBody.store, false);
  const prompt = requestBody.input[0].content[0].text;
  assert.match(prompt, /Bare arms, visible forearms, visible upper arms, and short sleeves are allowed/);
  assert.match(prompt, /as long as the shoulders are covered/);
  assert.match(prompt, /Never infer exposed arms, short sleeves, shorts, trouser length/);
  assert.match(prompt, /both the garment hem and exposed leg below that hem are clearly visible/);
  assert.match(prompt, /long skirt/);
  assert.match(prompt, /exposed calves, shins, ankles and feet strictly below the knee are allowed/);
  assert.match(prompt, /entire knee, including the kneecap and knee joint, and the thighs must be covered/);
  assert.match(prompt, /calf-length or cropped pants that cover the entire knee are allowed/);
  assert.match(prompt, /a knee outline under opaque clothing is not exposed skin/);
  assert.doesNotMatch(prompt, /must have long pants|shirtlessness, exposed legs/);
  assert.match(prompt, /infant babies, including animated or illustrated babies/);
  assert.match(prompt, /A diaper alone satisfies the clothing requirement for these infants/);
  assert.match(prompt, /covers the genital and buttock areas/);
  assert.match(prompt, /only to ordinary non-sexual depictions of infants/);
  assert.match(prompt, /does not apply to older children or adults/);
  assert.match(prompt, /never exempts another person in the same image/);
  assert.match(prompt, /completely outside the frame are not applicable/);
  assert.doesNotMatch(prompt, /partly outside the frame, or genuinely ambiguous/);
  assert.match(prompt, /Missing pixels outside the frame never count as that ambiguity/);
  assert.match(prompt, /A visible violation must still be non_modest/);
  assert.equal(requestBody.input[0].content[1].detail, 'high');
  assert.equal(result.decision, 'uncertain');
});

test('missing or failed independent review is unavailable for fail-closed caller', async () => {
  assert.deepEqual(await classifyOpenAIModesty(Buffer.from('image'), { apiKey: '' }),
    { configured: false, available: false, status: 'not_configured' });
  const failed = await classifyOpenAIModesty(Buffer.from('image'), {
    apiKey: 'test-key',
    fetchImpl: async () => ({ ok: false, status: 500, json: async () => ({}) }),
  });
  assert.equal(failed.available, false);
  assert.equal(failed.status, 'error');
});

const cropOnly = overrides => ({ decision:'uncertain',confidence:0.9,violationClearlyVisible:false,
  visibleEvidence:'חולצה מכסה את הכתפיים והחזה הנראים',reason:'לא רואים את החלק התחתון',
  visibleAreasDecision:'compliant',uncertaintyReason:'out_of_frame_only',...overrides });

test('out-of-frame-only uncertainty does not reject assessed compliant visible clothing',()=>{
  const parsed=parseModestyDecision(JSON.stringify(cropOnly()));
  assert.equal(parsed.decision,'modest');assert.equal(parsed.ignoredOutOfFrameUncertainty,true);
  assert.equal(parsed.originalDecision,'uncertain');assert.equal(parsed.originalReason,'לא רואים את החלק התחתון');
  assert.match(parsed.reason,/האזורים הנראים עומדים בכללים/);
});

test('cropping never erases visible violations or ambiguous visible clothing',()=>{
  const violation=parseModestyDecision(JSON.stringify(cropOnly({decision:'non_modest',
    visibleAreasDecision:'violation',violationClearlyVisible:true,
    visibleEvidence:'כתף חשופה וקצה הבגד נראים בבירור',confidence:0.97})));
  assert.equal(violation.decision,'non_modest');assert.equal(violation.ignoredOutOfFrameUncertainty,undefined);
  for(const overrides of [
    {visibleAreasDecision:'uncertain',uncertaintyReason:'visible_area_ambiguous'},
    {visibleAreasDecision:'uncertain'}, {violationClearlyVisible:true},
    {visibleEvidence:''}, {visibleEvidence:{}}, {violationClearlyVisible:'false'},
    {decision:'non_modest',violationClearlyVisible:false},
  ]){
    const result=parseModestyDecision(JSON.stringify(cropOnly(overrides)));
    assert.notEqual(result.decision,'modest');assert.equal(result.ignoredOutOfFrameUncertainty,undefined);
  }
  // A legacy free-text explanation is not sufficient evidence for approval.
  assert.equal(parseModestyDecision(JSON.stringify({decision:'uncertain',reason:'מחוץ לתמונה בלבד'})).decision,'uncertain');
});

test('malformed scope evidence and contradictory approvals cannot become clean checks',()=>{
  for(const overrides of [{visibleAreasDecision:'yes'},{uncertaintyReason:null},
    {visibleAreasDecision:undefined},{uncertaintyReason:undefined}])
    assert.equal(parseModestyDecision(JSON.stringify(cropOnly(overrides))),null);
  for(const overrides of [{visibleAreasDecision:'uncertain'},{uncertaintyReason:'visible_area_ambiguous'},
    {violationClearlyVisible:true},{visibleAreasDecision:'violation'}])
    assert.equal(parseModestyDecision(JSON.stringify(cropOnly({decision:'modest',...overrides}))).decision,'uncertain');
});

test('OpenAI applies the same crop policy while HTTP errors remain unavailable',async()=>{
  const result=await classifyOpenAIModesty(Buffer.from('image'),{apiKey:'mock-key',fetchImpl:async()=>({ok:true,json:async()=>({output_text:JSON.stringify(cropOnly())})})});
  assert.equal(result.available,true);assert.equal(result.decision,'modest');
  const failed=await classifyOpenAIModesty(Buffer.from('image'),{apiKey:'mock-key',fetchImpl:async()=>({ok:false,status:503,json:async()=>({output_text:JSON.stringify(cropOnly())})})});
  assert.equal(failed.available,false);assert.equal(failed.decision,undefined);
});

test('OpenAI uncertainty review shares a blind full-image prompt and strict schema', async () => {
  const fixture = reviewHarness();
  const source = Buffer.from('complete image');
  const signal = new AbortController().signal;
  const tracking = { storedFileId: 'file', videoBudget: {
    scanId: 'scan', leaseToken: 'lease', frameIndex: 4, signal,
  } };
  let request;
  const result = await fixture.classify(source, {
    apiKey: 'test-key', tracking,
    previousReason: 'Earlier reviewer approved this image',
    fetchImpl: async (_url, options) => {
      request = { body: JSON.parse(options.body), signal: options.signal };
      return reviewResponse();
    },
  });
  assert.equal(fixture.guards.length, 1);
  assert.equal(fixture.guards[0].provider, 'openai');
  assert.equal(fixture.guards[0].operation, 'modesty_uncertainty_review');
  assert.equal(fixture.guards[0].options.tracking, tracking);
  assert.equal(fixture.timeouts.length, 1);
  assert.equal(fixture.timeouts[0], UNCERTAINTY_REVIEW_TIMEOUT_MS);
  assert.equal(UNCERTAINTY_REVIEW_TIMEOUT_MS, 15000);
  assert.equal(request.signal, signal);
  assert.equal(request.body.store, false);
  const content = request.body.input[0].content;
  assert.equal(content.length, 2);
  assert.equal(content[0].text, MODESTY_UNCERTAINTY_REVIEW_PROMPT);
  assert.doesNotMatch(content[0].text, /Earlier reviewer approved/);
  assert.equal(content[1].image_url,
    `data:image/jpeg;base64,${source.toString('base64')}`);
  assert.equal(content[1].detail, 'high');
  assert.equal(request.body.text.format.type, 'json_schema');
  assert.equal(request.body.text.format.strict, true);
  assert.deepEqual(request.body.text.format.schema, MODESTY_RESPONSE_SCHEMA);
  assert.equal(require('../server/gemini-modesty-verification').MODESTY_UNCERTAINTY_REVIEW_PROMPT,
    MODESTY_UNCERTAINTY_REVIEW_PROMPT);
  assert.equal(result.decision, 'modest');
  assert.equal(fixture.calls.length, 1);
  assert.equal(fixture.calls[0].operation, 'modesty_uncertainty_review');
  assert.equal(fixture.calls[0].tracking, tracking);
  assert.equal(fixture.calls[0].usage.totalTokens, 360);
});

test('OpenAI uncertainty review malformed output fails after one request', async () => {
  const fixture = reviewHarness();
  let requests = 0;
  const result = await fixture.classify(Buffer.from('image'), {
    apiKey: 'test-key',
    fetchImpl: async () => {
      requests++;
      return { ok: true, json: async () => ({ output_text: 'decision: modest' }) };
    },
  });
  assert.equal(requests, 1);
  assert.equal(result.available, false);
  assert.equal(result.errorCode, 'INVALID_RESPONSE');
  assert.equal(fixture.calls.length, 1);
  assert.equal(fixture.calls[0].operation, 'modesty_uncertainty_review');
  assert.equal(fixture.calls[0].status, 'failed');
});

test('OpenAI uncertainty review HTTP failure retains usage and never retries', async () => {
  const fixture = reviewHarness();
  let requests = 0;
  const result = await fixture.classify(Buffer.from('image'), {
    apiKey: 'test-key',
    fetchImpl: async () => {
      requests++;
      return { ok: false, status: 429, json: async () => ({
        error: { code: 'insufficient_quota', message: 'quota exhausted' },
        usage: { input_tokens: 10, output_tokens: 0, total_tokens: 10 },
      }) };
    },
  });
  assert.equal(requests, 1);
  assert.equal(result.available, false);
  assert.equal(result.errorCode, 'insufficient_quota');
  assert.equal(fixture.calls.length, 1);
  assert.equal(fixture.calls[0].operation, 'modesty_uncertainty_review');
  assert.equal(fixture.calls[0].usage.totalTokens, 10);
  assert.equal(fixture.calls[0].usageReported, true);
  assert.equal(fixture.calls[0].status, 'failed');
});

test('OpenAI uncertainty review reserves separately and reuses only its result', async () => {
  const reservations = [], cached = new Map();
  let requests = 0;
  const dependencies = { pool: {}, ledger: {
    getProviderSuspension: async () => null,
    async reserveVideoScanOperation(_pool, args) {
      const key = `${args.frameIndex}:${args.provider}:${args.operation}`;
      if (cached.has(key)) return { status: 'cached', result: cached.get(key) };
      const reservationId = String(reservations.length + 1);
      reservations.push({ ...args, key, reservationId });
      return { status: 'reserved', reservationId };
    },
    async finishVideoScanOperation(_pool, args) {
      const reserved = reservations.find(item => item.reservationId === args.reservationId);
      cached.set(reserved.key, args.result);
      return { status: 'completed', result: args.result };
    },
  } };
  const options = { apiKey: 'test-key',
    tracking: { videoBudget: { scanId: 'scan', leaseToken: 'lease', frameIndex: 2 } },
    providerGuardDependencies: dependencies,
    fetchImpl: async () => {
      requests++;
      assert.equal(reservations.length, requests);
      return requests === 1 ? reviewResponse({ decision: 'uncertain',
        visibleAreasDecision: 'uncertain', uncertaintyReason: 'visible_area_ambiguous' })
        : reviewResponse();
    },
  };
  const first = await classifyOpenAIModesty(Buffer.from('image'), options);
  assert.equal(first.decision, 'uncertain');
  const reviewed = await classifyOpenAIModestyUncertaintyReview(Buffer.from('image'), options);
  assert.equal(reviewed.decision, 'modest');
  const reused = await classifyOpenAIModestyUncertaintyReview(Buffer.from('image'), options);
  assert.equal(reused.cacheHit, true);
  assert.equal(reused.decision, 'modest');
  assert.deepEqual(reservations.map(item => item.operation),
    ['modesty', 'modesty_uncertainty_review']);
  assert.equal(requests, 2);
});

test('OpenAI refused review reservation cannot make a paid request', async () => {
  const result = await classifyOpenAIModestyUncertaintyReview(Buffer.from('image'), {
    apiKey: 'test-key',
    tracking: { videoBudget: { scanId: 'scan', leaseToken: 'lease', frameIndex: 0 } },
    providerGuardDependencies: { pool: {}, ledger: {
      getProviderSuspension: async () => null,
      reserveVideoScanOperation: async () => ({ status: 'stopped', reason: 'budget_exhausted' }),
    } },
    fetchImpl: async () => assert.fail('exhausted review budget must not call OpenAI'),
  });
  assert.equal(result.available, false);
  assert.equal(result.budgetStopped, true);
  assert.equal(result.reasonCode, 'budget_exhausted');
});

test('OpenAI uncertainty review honors cancellation without another attempt', async () => {
  const abort = new AbortController();
  let requests = 0;
  const result = await classifyOpenAIModestyUncertaintyReview(Buffer.from('image'), {
    apiKey: 'test-key', signal: abort.signal,
    fetchImpl: async (_url, options) => {
      requests++;
      return new Promise((_, reject) => {
        options.signal.addEventListener('abort', () => reject(options.signal.reason), { once: true });
        abort.abort(Object.assign(new Error('cancelled'), { name: 'AbortError' }));
      });
    },
  });
  assert.equal(requests, 1);
  assert.equal(result.available, false);
  assert.equal(result.errorCode, 'AbortError');
});

test('OpenAI uncertainty review retains ambiguity, violations and crop-only evidence', async () => {
  for (const [override, expected] of [
    [{ decision: 'uncertain', visibleAreasDecision: 'uncertain',
      uncertaintyReason: 'visible_area_ambiguous' }, 'uncertain'],
    [{ decision: 'non_modest', violationClearlyVisible: true,
      visibleAreasDecision: 'violation', visibleEvidence: 'כתף חשופה נראית בבירור' }, 'non_modest'],
    [{ decision: 'modest', visibleAreasDecision: 'uncertain',
      uncertaintyReason: 'visible_area_ambiguous' }, 'uncertain'],
    [{ decision: 'uncertain', uncertaintyReason: 'out_of_frame_only' }, 'modest'],
  ]) {
    const fixture = reviewHarness();
    const result = await fixture.classify(Buffer.from('image'), {
      apiKey: 'test-key', fetchImpl: async () => reviewResponse(override),
    });
    assert.equal(result.available, true);
    assert.equal(result.decision, expected);
    assert.equal(fixture.calls.length, 1);
  }
});
