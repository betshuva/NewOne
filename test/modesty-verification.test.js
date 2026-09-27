'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  classifyOpenAIModesty,
  parseModestyDecision,
} = require('../server/modesty-verification');

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
  const prompt = requestBody.input[0].content[0].text;
  assert.match(prompt, /Bare arms, visible forearms, visible upper arms, and short sleeves are allowed/);
  assert.match(prompt, /as long as the shoulders are covered/);
  assert.match(prompt, /Never infer exposed arms, short sleeves, shorts, trouser length/);
  assert.match(prompt, /both the garment hem and exposed leg below that hem are clearly visible/);
  assert.match(prompt, /long skirt/);
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
