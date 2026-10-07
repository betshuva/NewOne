'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { execFileSync } = require('node:child_process');
const { imageClassificationOutcome } = require('../server/image-classification-outcome');
const { stoppedVideoResult, videoProviderStop } = require('../server/video-scan-controller');
const { moderationCheckSummary } = require('../server/moderation-check-summary');
const { corroboratedCompliantGeminiFlag } = require('../server/modesty-verification');

const source = fs.readFileSync(require.resolve('../server/index.js'), 'utf8');
const start = source.indexOf('async function scanStaticImage(');
const end = source.indexOf('// Increment whenever moderation models', start);
assert.ok(start >= 0 && end > start);

const disabled = () => ({ configured: false, available: false, required: false,
  status: 'disabled', reasonCode: 'provider_disabled' });
const cleanGemini = { configured: true, available: true, status: 'completed',
  decision: 'modest', confidence: 0.99 };
const cleanGoogle = { configured: true, available: true, blocked: false, uncertain: false };
const person = { category: 'men', detectedCategories: ['men'], uncertain: false };

async function scanFixture({ gemini = cleanGemini, google = cleanGoogle,
  localSafety = { available: true, wouldBlock: false },
  classification = person, verification = { decision: 'person_confirmed_by_gemini',
    providers: { gemini: { available: true, decision: 'person' } } }, video = false,
  enabled = false, required = false, openai = cleanGemini } = {}) {
  const calls = [], checks = [];
  const scan = vm.runInNewContext(`${source.slice(start, end)};scanStaticImage`, {
    process: { env: {} }, console,
    MODERATION_CACHE_VERSION: 'test-google-gemini',
    openAIModerationEnabled: () => enabled,
    openAIModerationRequired: () => required,
    moderationProviderPolicy: () => 'google_gemini',
    disabledModerationProviderResult: disabled,
    stoppedVideoResult, videoProviderStop, imageClassificationOutcome, corroboratedCompliantGeminiFlag,
    recordProviderCheck: async event => checks.push(event),
    classifyClip: async () => ({}),
    classifyImageContent: async () => classification,
    classifyLocalSafety: async () => localSafety,
    googleSafeSearchConfigured: () => true,
    normalizeBlockThreshold: () => 'LIKELY',
    scanGoogleSafeSearch: async () => { calls.push('google'); return google; },
    verifyPersonClassification: async (_bytes, current) => {
      calls.push('person'); return { classification: current, verification };
    },
    classifyOpenAIModesty: async () => {
      assert.equal(enabled, true, 'disabled OpenAI must never be invoked');
      calls.push('openai'); return openai;
    },
    classifyGeminiModesty: async () => { calls.push('gemini'); return gemini; },
  });
  const result = await scan(Buffer.from('synthetic frame'), video
    ? { tracking: { videoBudget: { frameIndex: 0, timestampSeconds: 0 } } } : {});
  return { result, calls, checks };
}

test('Google and Gemini can approve without invoking disabled OpenAI', async () => {
  const { result, calls, checks } = await scanFixture();
  assert.equal(result.blocked, false);
  assert.notEqual(result.pending, true);
  assert.notEqual(result.scanStopped, true);
  assert.deepEqual(calls, ['google', 'person', 'gemini']);
  assert.equal(result.modestyVerification.status, 'disabled');
  assert.equal(result.modestyVerification.required, false);
  assert.equal(result.modestyVerification.available, false);
  assert.equal(result.classificationStats.openAIUsed, false);
  assert.notEqual(result.classificationStats.modestyDisagreement, true);
  assert.equal(result.modestyDisagreement, undefined);
  const skipped = checks.find(event => event.provider === 'openai');
  assert.ok(skipped, 'history distinguishes a disabled provider from a completed check');
  const summary = moderationCheckSummary(skipped.provider, skipped.operation, skipped.result);
  assert.equal(summary.checkOutcome, 'skipped');
  assert.ok(summary.checkFindings.includes('provider_disabled'));
  assert.ok(!summary.checkFindings.includes('modest'));
});

test('budgeted Google/Gemini scan does not stop because OpenAI is disabled', async () => {
  const { result, calls } = await scanFixture({ video: true });
  assert.equal(result.blocked, false);
  assert.notEqual(result.pending, true);
  assert.notEqual(result.scanStopped, true);
  assert.deepEqual(calls, ['google', 'person', 'gemini']);
});

for (const [name, gemini] of [
  ['uncertain', { available: true, decision: 'uncertain', confidence: 0.8 }],
  ['unavailable', { available: false, status: 'error' }],
  ['not configured', { configured: false, available: false, status: 'not_configured' }],
  ['unsupported violation', { available: true, decision: 'non_modest', confidence: 0.99,
    violationClearlyVisible: false }],
  ['low-confidence violation', { available: true, decision: 'non_modest', confidence: 0.84,
    violationClearlyVisible: true }],
]) test(`clean safety cannot approve Gemini modesty result: ${name}, without OpenAI`, async () => {
  const { result } = await scanFixture({ gemini });
  assert.equal(result.pending, true);
  assert.notEqual(result.blocked, true);
  assert.equal(result.modestyDisagreement, undefined);
});

for (const gemini of [
  { available: true, decision: 'non_modest', confidence: 0.85, violationClearlyVisible: true },
  { available: true, decision: 'non_modest', confidence: 1, status: 'safety_blocked' },
]) test(`explicit Gemini violation blocks without requiring OpenAI (${gemini.status || 'visible evidence'})`, async () => {
  const { result } = await scanFixture({ gemini });
  assert.equal(result.blocked, true);
  assert.notEqual(result.pending, true);
  assert.notEqual(result.blockedBy, 'dualModesty');
  assert.equal(result.modestyDisagreement, undefined);
});

test('a budget-stopped Gemini check remains terminal even with clean Google and local safety', async () => {
  const { result } = await scanFixture({ video: true, gemini: { available: false,
    budgetStopped: true, reasonCode: 'budget_exhausted' } });
  assert.equal(result.scanStopped, true);
  assert.equal(result.pending, false);
  assert.equal(result.reasonCode, 'budget_exhausted');
  assert.equal(result.classification.uncertain, true);
});

for (const decision of ['person_confirmed_by_gemini', 'demographics_reviewed_by_gemini'])
  test(`${decision} still requires Gemini modesty with unresolved demographic category`, async () => {
    const { result, calls } = await scanFixture({
      classification: { category: 'people', detectedCategories: [], uncertain: true },
      verification: { decision, providers: {} },
    });
    assert.ok(calls.includes('gemini'));
    assert.equal(result.pending, true, 'unknown demographics cannot become approved');
  });

test('non-human images skip Gemini modesty and record OpenAI as disabled, not clean', async () => {
  const { result, calls, checks } = await scanFixture({
    classification: { category: 'nonHumanImages', detectedCategories: ['nonHumanImages'] },
    verification: { decision: 'non_human_google_consensus', providers: {} },
  });
  assert.equal(result.blocked, false);
  assert.deepEqual(calls, ['google', 'person']);
  assert.equal(result.modestyVerification.status, 'disabled');
  const skipped = checks.filter(event => event.operation === 'modesty');
  assert.equal(skipped.length, 2);
  for (const event of skipped) {
    const summary = moderationCheckSummary(event.provider, event.operation, event.result);
    assert.equal(summary.checkOutcome, 'skipped');
    assert.ok(!summary.checkFindings.includes('modest'));
  }
});

for (const [name, google] of [
  ['blocked', { ...cleanGoogle, blocked: true }],
  ['unknown', { ...cleanGoogle, uncertain: true }],
  ['unavailable', { configured: true, available: false }],
]) test(`Gemini clean result cannot bypass ${name} Google safety`, async () => {
  const { result } = await scanFixture({ google });
  assert.ok(result.blocked === true || result.pending === true);
});

test('moderation cache versions cannot be reused across provider policies', () => {
  const declaration = source.match(/^const MODERATION_CACHE_VERSION = .+;$/m)?.[0];
  assert.ok(declaration);
  const version = policy => vm.runInNewContext(`${declaration};MODERATION_CACHE_VERSION`, {
    moderationProviderPolicy: () => policy,
  });
  assert.notEqual(version('google_gemini'), version('google_openai_gemini'));
  assert.match(version('google_gemini'), /google_gemini/);
  assert.notEqual(version('google_gemini_optional_openai'), version('google_openai_gemini'));
});

test('optional OpenAI remains enabled and its outage does not stop a clean Gemini video', async () => {
  for (const openai of [
    { available: false, status: 'error', errorCode: 'REQUEST_FAILED' },
    { available: false, status: 'stopped', budgetStopped: true,
      providerSuspended: true, reasonCode: 'credit_balance_exhausted' },
    { configured: false, available: false, status: 'not_configured' },
  ]) {
    const { result, calls } = await scanFixture({ enabled: true, required: false, video: true,
      openai, verification: { decision: 'person_confirmed', providers: {} } });
    assert.deepEqual(calls, ['google', 'person', 'openai', 'gemini']);
    assert.equal(result.modestyVerification, openai);
    assert.notEqual(result.scanStopped, true);
    assert.notEqual(result.pending, true);
    assert.equal(result.blocked, false);
  }
});

test('healthy optional OpenAI still runs and remains part of the evidence', async () => {
  const { result, calls } = await scanFixture({ enabled: true, required: false, video: true,
    verification: { decision: 'person_confirmed', providers: {} } });
  assert.ok(calls.includes('openai'));
  assert.equal(result.modestyVerification.available, true);
  assert.equal(result.modestyDisagreement, undefined);
  assert.equal(result.blocked, false);
});

test('a Gemini person fallback skips the additional optional OpenAI modesty request', async () => {
  const { result, calls } = await scanFixture({ enabled: true, required: false });
  assert.deepEqual(calls, ['google', 'person', 'gemini']);
  assert.equal(result.modestyVerification.status, 'skipped');
  assert.notEqual(result.pending, true);
});

test('optional OpenAI outage cannot approve missing or uncertain Gemini evidence', async () => {
  for (const gemini of [{ available: false, status: 'error' },
    { available: true, decision: 'uncertain' },
    { available: true, decision: 'non_modest', violationClearlyVisible: false }]) {
    const { result } = await scanFixture({ enabled: true, required: false, gemini,
      openai: { available: false, status: 'error' },
      verification: { decision: 'person_confirmed', providers: {} } });
    assert.equal(result.pending, true);
  }
});

test('Gemini-only blocking evidence is never reported as agreement with unavailable OpenAI', async () => {
  const { result } = await scanFixture({ enabled: true, required: false,
    openai: { available: false, status: 'error' },
    gemini: { available: true, decision: 'non_modest', confidence: 0.99, violationClearlyVisible: true },
    verification: { decision: 'person_confirmed', providers: {} } });
  assert.equal(result.blocked, true);
  assert.equal(result.blockedBy, 'geminiModesty');
});

const coveredOpenAI = { ...cleanGemini, visibleAreasDecision:'compliant',
  uncertaintyReason:'none', violationClearlyVisible:false,
  visibleEvidence:'הכתפיים והחזה מכוסים, הברכיים והירכיים מכוסות בבגד ארוך' };
const conflictingGemini = { ...coveredOpenAI, decision:'uncertain', violationClearlyVisible:true,
  reason:'כל האזורים הנראים לעין עומדים בדרישות הצניעות' };
const conflictOptions = { enabled:true,required:false,openai:coveredOpenAI,
  gemini:conflictingGemini,verification:{decision:'person_confirmed',providers:{}} };

for(const video of [false,true])test(`corroborated compliant Gemini flag approves ${video?'video frame':'image'} without extra calls`,async()=>{
  for(const uncertaintyReason of ['none','out_of_frame_only']){
    const gemini={...conflictingGemini,uncertaintyReason};
    const {result,calls}=await scanFixture({...conflictOptions,video,gemini});
    assert.equal(result.blocked,false);assert.notEqual(result.pending,true);assert.notEqual(result.scanStopped,true);
    assert.equal(result.modestyDisagreement.resolution,'corroborated_compliant_gemini_flag');
    assert.equal(result.modestyVerification,coveredOpenAI);
    assert.equal(result.geminiModestyVerification,gemini,'original conflicting evidence is preserved');
    assert.deepEqual(calls,['google','person','openai','gemini']);
  }
});

test('compliant flag exception cannot bypass genuine violations, uncertainty, missing checks or low confidence',async()=>{
  for(const overrides of [
    {gemini:{...conflictingGemini,decision:'non_modest',visibleAreasDecision:'violation',visibleEvidence:'חזה וכתפיים חשופים'}},
    {gemini:{...conflictingGemini,decision:'non_modest'}},
    {gemini:{...conflictingGemini,visibleAreasDecision:'violation'}},
    {gemini:{...conflictingGemini,visibleAreasDecision:'uncertain'}},
    {gemini:{...conflictingGemini,uncertaintyReason:'visible_area_ambiguous'}},
    {gemini:{...conflictingGemini,visibleEvidence:''}},
    {gemini:{...conflictingGemini,confidence:0.84}},
    {gemini:{...conflictingGemini,available:false}},
    {gemini:{...conflictingGemini,status:'safety_blocked'}},
    {openai:{...coveredOpenAI,available:false}},
    {openai:{...coveredOpenAI,confidence:0.84}},
    {openai:{...coveredOpenAI,visibleAreasDecision:'uncertain'}},
    {openai:{...coveredOpenAI,decision:'non_modest',violationClearlyVisible:true}},
    {google:{...cleanGoogle,blocked:true}},
    {google:{...cleanGoogle,uncertain:true}},
    {google:{...cleanGoogle,available:false}},
    {localSafety:{available:true,wouldBlock:true}},
    {localSafety:{available:false}},
    {classification:{...person,uncertain:true}},
  ]){
    const {result}=await scanFixture({...conflictOptions,...overrides});
    assert.ok(result.blocked===true||result.pending===true||result.scanStopped===true,JSON.stringify(overrides));
    assert.notEqual(result.modestyDisagreement?.resolution,'corroborated_compliant_gemini_flag');
  }
});

for (const [name, flags] of [
  ['moderation flag', { OPENAI_ENABLED: 'true', MODERATION_OPENAI_ENABLED: 'false' }],
  ['trimmed moderation flag', { OPENAI_ENABLED: 'true', MODERATION_OPENAI_ENABLED: ' FALSE ' }],
  ['global flag', { OPENAI_ENABLED: 'false', MODERATION_OPENAI_ENABLED: 'true' }],
  ['trimmed global flag', { OPENAI_ENABLED: ' FALSE ', MODERATION_OPENAI_ENABLED: '' }],
]) test(`${name} prevents direct OpenAI helper network, reservation, and suspension lookup`, () => {
  const output = execFileSync(process.execPath, ['-e', `
    const assert = require('node:assert/strict');
    const { classifyOpenAIPersonPresence } = require('./server/person-verification');
    const { classifyOpenAIModesty } = require('./server/modesty-verification');
    const { moderationProviderPolicy, disabledModerationProviderResult } =
      require('./server/moderation-provider-policy');
    const { moderationCheckSummary } = require('./server/moderation-check-summary');
    const checks = [];
    let network = 0, database = 0;
    const forbiddenDatabase = async () => { database++; throw new Error('database forbidden'); };
    const forbiddenNetwork = async () => { network++; throw new Error('network forbidden'); };
    global.fetch = forbiddenNetwork;
    const dependencies = {
      getPool: forbiddenDatabase,
      ledger: { getProviderSuspension: forbiddenDatabase,
        reserveVideoScanOperation: forbiddenDatabase,
        finishVideoScanOperation: forbiddenDatabase },
      recordProviderCheck: async event => checks.push(event),
    };
    (async () => {
      for (const classify of [classifyOpenAIPersonPresence, classifyOpenAIModesty]) {
        for (const video of [false, true]) {
          for (const apiKey of ['', 'synthetic-key']) {
            const result = await classify(Buffer.from('not even an image'), {
              apiKey, fetchImpl: forbiddenNetwork, providerGuardDependencies: dependencies,
              tracking: video ? { videoBudget: { scanId: 'scan', leaseToken: 'lease', frameIndex: 0 } } : {},
            });
            assert.deepEqual(result, disabledModerationProviderResult());
            assert.equal(result.budgetStopped, undefined);
          }
        }
      }
      assert.equal(moderationProviderPolicy(), 'google_gemini');
      assert.equal(network, 0);
      assert.equal(database, 0);
      assert.equal(checks.length, 8);
      for (const check of checks) {
        assert.equal(check.provider, 'openai');
        const summary = moderationCheckSummary(check.provider, check.operation, check.result);
        assert.equal(summary.checkOutcome, 'skipped');
        assert.ok(summary.checkFindings.includes('provider_disabled'));
      }
      process.stdout.write(JSON.stringify({ network, database, checks: checks.length }));
    })().catch(error => { console.error(error); process.exitCode = 1; });
  `], { cwd: path.resolve(__dirname, '..'), encoding: 'utf8', timeout: 10000,
    env: { ...process.env, DATABASE_URL: '', ...flags } });
  assert.deepEqual(JSON.parse(output), { network: 0, database: 0, checks: 8 });
});

test('cropped compliant frames complete video scanning with unavailable optional OpenAI',async()=>{
  const {parseModestyDecision}=require('../server/modesty-verification');
  const gemini={available:true,status:'completed',...parseModestyDecision(JSON.stringify({
    decision:'uncertain',confidence:0.95,violationClearlyVisible:false,
    visibleEvidence:'ראש וכתפיים מכוסים בחולצה; החזה מכוסה',reason:'חלק תחתון מחוץ לתמונה',
    visibleAreasDecision:'compliant',uncertaintyReason:'out_of_frame_only',
  }))};
  const scanSource=source.slice(source.indexOf('async function scanVideo('),source.indexOf('function normalizeUploadFileName('));
  let frameCalls=0;
  const scan=vm.runInNewContext(`${scanSource};scanVideo`,{
    Buffer,Blob,FormData,AbortSignal,console,process:{env:{}},
    sourceBlob: require('../server/upload-file-source').sourceBlob,
    VIDEO_MODERATION_URL:'https://mock-video.test',MAX_VIDEO_SECONDS:30,stoppedVideoResult,
    videoDetectedCategories:require('../server/video-classification').videoDetectedCategories,
    fetch:async()=>({ok:true,json:async()=>({duration_seconds:3,sampled_frames:6,decision:'allowed',
      frame_samples:Array.from({length:6},(_,i)=>({timestamp_seconds:i*0.5,jpeg_base64:Buffer.alloc(40).toString('base64')}))})}),
    scanStaticImage:async()=>{frameCalls++;return (await scanFixture({gemini,enabled:true,required:false,video:true,
      openai:{available:false,status:'stopped',budgetStopped:true,reasonCode:'credit_balance_exhausted'},
      verification:{decision:'person_confirmed',providers:{}}})).result;},
  });
  const result=await scan(Buffer.from('video'),'crop.mp4','video/mp4',{tracking:{videoBudget:{}}});
  assert.equal(frameCalls,6);assert.equal(result.blocked,false);assert.equal(result.pending,false);
  assert.notEqual(result.scanStopped,true);assert.equal(result.frameResults.length,6);
  const summary=moderationCheckSummary('gemini','modesty',gemini);
  assert.equal(summary.checkOutcome,'passed');assert.ok(summary.checkFindings.includes('out_of_frame_ignored'));
  const label=require('../server/audit-check-presentation').presentAuditCheck({kind:'provider_call_finished',details:summary});
  assert.match(label.checkResultLabel,/חלקים מחוץ לתמונה אינם סיבה לחסימה/);
});
