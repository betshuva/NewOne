'use strict';

const { recordProviderCall } = require('./provider-usage-log');
const { guardModerationProvider, providerRequestSignal } = require('./moderation-provider-guard');

const MODESTY_POLICY_PROMPT = 'Apply this clothing policy to every recognizable person in the image, including people inside screenshots, posters, drawings or embedded photos. Evaluate only body parts and clothing that are actually visible inside the image frame. Clothing and body parts that are completely outside the frame are not applicable: never decide uncertain or non_modest merely because the lower body, sleeve ends, or another area is outside the frame. For a headshot or upper-body portrait, ignore clothing below the photographed area. This also applies at a crop boundary: evaluate only the visible portion and never require the missing remainder of a body area to be shown. A face-only portrait has no clothing violation merely because no clothing is visible. Infant clothing exception: clearly recognizable infant babies, including animated or illustrated babies, wearing a diaper or ordinary infant clothing that covers the genital and buttock areas are modest even with bare shoulders, chest, belly, arms, thighs, knees or lower legs. A diaper alone satisfies the clothing requirement for these infants; do not require a shirt, long trousers or a skirt. This exception applies only to ordinary non-sexual depictions of infants. It does not apply to older children or adults, and it never exempts another person in the same image from their own clothing requirements. Evaluate every person separately. The following general clothing requirements apply only to people outside this infant exception. Bare arms, visible forearms, visible upper arms, and short sleeves are allowed for every person as long as the shoulders are covered. Never infer exposed arms, short sleeves, shorts, trouser length, or exposed legs from color, shadows, folds, a cropped frame, or an unclear lower-body area. Shorts may be reported only when both the garment hem and exposed leg below that hem are clearly visible. For every person outside the infant exception, exposed calves, shins, ankles and feet strictly below the knee are allowed. The entire knee, including the kneecap and knee joint, and the thighs must be covered. Clearly visible bare skin on the knee itself or on the thigh above it is non_modest; a knee outline under opaque clothing is not exposed skin. Do not reject exposed lower legs below a covered knee, or trousers merely because they do not reach the ankles. Judge the actual visible skin and garment boundary, not the clothing label shorts or cropped pants. Women and girls: visible shoulders must be covered, a visible neckline must be high, and a visible lower body must have a long skirt covering the thighs and the entire knees; clearly visible pants, skirts exposing a knee or thigh, exposed shoulders, sleeveless tops, low necklines, or revealing/tight clothing are non_modest. Men and boys: visible shoulders and chest must be covered and visible thighs and entire knees must be covered by opaque clothing; calf-length or cropped pants that cover the entire knee are allowed. Clearly visible bare knees or thighs, exposed shoulders, sleeveless tops, shirtlessness, or exposed chest are non_modest. If any visible area clearly fails the policy, decide non_modest. Decide uncertain only when pixels INSIDE the frame show a relevant clothing area but blur, occlusion, insufficient detail, or ambiguity prevents assessing those visible pixels. Missing pixels outside the frame never count as that ambiguity. Decide modest when every assessable visible area satisfies the policy and no visible violation exists. For non_modest you must identify a concrete visible body area and garment boundary. Set violationClearlyVisible=true only when those pixels are unambiguous; otherwise decide uncertain. Report visibleAreasDecision as compliant, violation, or uncertain, based solely on assessable pixels inside the frame. Report uncertaintyReason as none, out_of_frame_only, or visible_area_ambiguous. If the only missing information concerns areas outside the frame and all assessable visible areas comply, set visibleAreasDecision=compliant, uncertaintyReason=out_of_frame_only, and decision=modest; do not request another image or a full-body view. A visible violation must still be non_modest even if other areas are cropped. If a visible area is ambiguous, use visibleAreasDecision=uncertain and uncertaintyReason=visible_area_ambiguous. Describe the actual visible evidence, not the missing body parts. Write the short reason and visible evidence in Hebrew. Return only JSON: {"decision":"modest|non_modest|uncertain","confidence":0.0,"violationClearlyVisible":false,"visibleEvidence":"what is directly visible, or empty","visibleAreasDecision":"compliant|violation|uncertain","uncertaintyReason":"none|out_of_frame_only|visible_area_ambiguous","reason":"short Hebrew reason"}.';

const MODESTY_UNCERTAINTY_REVIEW_PROMPT = `${MODESTY_POLICY_PROMPT}\nPerform one independent clothing review of the entire image, without assuming either compliance or a violation. Locate the actual image borders before assessing clothing. A body area that continues beyond an image border is outside the frame, not ambiguous visible skin. For a partially framed shoulder, chest, knee or thigh, assess only the pixels actually present inside the frame; do not require its missing remainder or a full-body view. Reserve visible_area_ambiguous for relevant pixels inside the frame that cannot be assessed because of blur, occlusion or insufficient visible detail. Inspect every recognizable person and retain any concrete visible violation. Keep decision, violationClearlyVisible, visibleAreasDecision and uncertaintyReason consistent with this distinction. Return the same JSON schema, with actual visible evidence in Hebrew; never guess what lies outside the image.`;
const UNCERTAINTY_REVIEW_TIMEOUT_MS = 15000;
const MODESTY_RESPONSE_SCHEMA = {
  type: 'object',
  properties: {
    decision: { type: 'string', enum: ['modest', 'non_modest', 'uncertain'] },
    confidence: { type: 'number', minimum: 0, maximum: 1 },
    violationClearlyVisible: { type: 'boolean' },
    visibleEvidence: { type: 'string' },
    visibleAreasDecision: { type: 'string', enum: ['compliant', 'violation', 'uncertain'] },
    uncertaintyReason: { type: 'string', enum: ['none', 'out_of_frame_only', 'visible_area_ambiguous'] },
    reason: { type: 'string' },
  },
  required: ['decision', 'confidence', 'violationClearlyVisible',
    'visibleEvidence', 'visibleAreasDecision', 'uncertaintyReason', 'reason'],
  additionalProperties: false,
};

function parseModestyDecision(text) {
  try {
    const cleaned = String(text || '').replace(/^```(?:json)?\s*|\s*```$/g, '');
    const value = JSON.parse(cleaned);
    if (!['modest', 'non_modest', 'uncertain'].includes(value.decision))
      return null;
    const hasScope = Object.hasOwn(value, 'visibleAreasDecision') || Object.hasOwn(value, 'uncertaintyReason');
    if (hasScope && (!['compliant', 'violation', 'uncertain'].includes(value.visibleAreasDecision) ||
        !['none', 'out_of_frame_only', 'visible_area_ambiguous'].includes(value.uncertaintyReason))) return null;
    const evidence = String(value.visibleEvidence || '').slice(0, 300);
    const clearlyVisible = value.violationClearlyVisible === true;
    const unsupportedViolation = value.decision === 'non_modest' &&
      (!clearlyVisible || evidence.trim().length < 5);
    // Never infer crop-only uncertainty from free text or from an unavailable provider.
    // Require explicit, consistent evidence that the visible areas were assessed.
    const ignoredOutOfFrameUncertainty = value.decision === 'uncertain' &&
      value.visibleAreasDecision === 'compliant' && value.uncertaintyReason === 'out_of_frame_only' &&
      value.violationClearlyVisible === false && typeof value.visibleEvidence === 'string' && evidence.trim().length >= 5;
    const contradictoryApproval = value.decision === 'modest' && (clearlyVisible ||
      hasScope && (value.visibleAreasDecision !== 'compliant' || value.uncertaintyReason === 'visible_area_ambiguous'));
    const reason = String(value.reason || '').slice(0, 300);
    return {
      decision: unsupportedViolation || contradictoryApproval ? 'uncertain'
        : ignoredOutOfFrameUncertainty ? 'modest' : value.decision,
      confidence: Math.max(0, Math.min(1, Number(value.confidence) || 0)),
      reason: ignoredOutOfFrameUncertainty ? 'האזורים הנראים עומדים בכללים; חלקים שמחוץ לתמונה אינם סיבה לחסימה' : reason,
      violationClearlyVisible: clearlyVisible,
      visibleEvidence: evidence,
      ...(unsupportedViolation ? { unsupportedViolation: true } : {}),
      ...(hasScope ? { visibleAreasDecision: value.visibleAreasDecision, uncertaintyReason: value.uncertaintyReason } : {}),
      ...(ignoredOutOfFrameUncertainty ? { ignoredOutOfFrameUncertainty: true,
        originalDecision: value.decision, originalReason: reason } : {}),
    };
  } catch (_) {
    return null;
  }
}

// Resolve only a contradictory Gemini flag corroborated by a separate clean
// OpenAI clothing assessment. Keep both provider results intact for the audit.
function corroboratedCompliantGeminiFlag(openai, gemini) {
  const assessed = review => review?.available === true && review.status === 'completed' &&
    Number.isFinite(review.confidence) && review.confidence >= 0.85 &&
    review.visibleAreasDecision === 'compliant' &&
    ['none', 'out_of_frame_only'].includes(review.uncertaintyReason) &&
    typeof review.visibleEvidence === 'string' && review.visibleEvidence.trim().length >= 5;
  return assessed(openai) && openai.decision === 'modest' && openai.violationClearlyVisible === false &&
    assessed(gemini) && gemini.decision === 'uncertain' && gemini.violationClearlyVisible === true;
}

async function classifyOpenAIModesty(buffer, options = {}) {
  const apiKey = String(options.apiKey ?? process.env.OPENAI_API_KEY ?? '').trim();
  return guardModerationProvider({ provider: 'openai', operation: 'modesty',
    apiKey, options, run: () => requestOpenAIModesty(buffer, options) });
}

async function classifyOpenAIModestyUncertaintyReview(buffer, options = {}) {
  const apiKey = String(options.apiKey ?? process.env.OPENAI_API_KEY ?? '').trim();
  return guardModerationProvider({ provider: 'openai', operation: 'modesty_uncertainty_review',
    apiKey, options, run: () => requestOpenAIModesty(buffer, options, {
      operation: 'modesty_uncertainty_review',
      prompt: MODESTY_UNCERTAINTY_REVIEW_PROMPT,
      timeoutMs: UNCERTAINTY_REVIEW_TIMEOUT_MS,
      strictJson: true,
    }) });
}

async function requestOpenAIModesty(buffer, options, {
  operation = 'modesty', prompt = MODESTY_POLICY_PROMPT,
  timeoutMs = 30000, strictJson = false,
} = {}) {
  const startedAt = performance.now();
  const apiKey = String(options.apiKey ?? process.env.OPENAI_API_KEY ?? '').trim();
  if (!apiKey)
    return { configured: false, available: false, status: 'not_configured' };
  const fetchImpl = options.fetchImpl || globalThis.fetch;
  const model = options.model || process.env.OPENAI_VISION_MODEL || 'gpt-5.6-luna';
  let capturedUsage = null;
  let capturedUsageReported = false;
  try {
    const response = await fetchImpl('https://api.openai.com/v1/responses', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model,
        store: false,
        reasoning: { effort: 'none' },
        max_output_tokens: 400,
        ...(strictJson ? { text: { format: {
          type: 'json_schema', name: 'modesty_uncertainty_review', strict: true,
          schema: MODESTY_RESPONSE_SCHEMA,
        } } } : {}),
        input: [{
          role: 'user',
          content: [
            { type: 'input_text', text: prompt },
            { type: 'input_image', image_url: `data:image/jpeg;base64,${buffer.toString('base64')}`, detail: 'high' },
          ],
        }],
      }),
      signal: providerRequestSignal(options, timeoutMs),
    });
    const data = await response.json().catch(() => ({}));
    const usage = {
      inputTokens: Number(data.usage?.input_tokens || 0),
      cachedInputTokens: Number(data.usage?.input_tokens_details?.cached_tokens || 0),
      cacheWriteTokens: data.usage?.input_tokens_details?.cache_write_tokens ?? null,
      outputTokens: Number(data.usage?.output_tokens || 0),
      totalTokens: Number(data.usage?.total_tokens || 0),
    };
    capturedUsage = usage;
    capturedUsageReported = Boolean(data.usage);
    if (!response.ok) {
      const error = new Error(data?.error?.message || `OpenAI HTTP ${response.status}`);
      error.code = data?.error?.code || `HTTP_${response.status}`;
      throw error;
    }
    const text = data.output_text || data.output?.flatMap(item => item.content || [])
      .find(item => item.type === 'output_text')?.text;
    const result = parseModestyDecision(text);
    if (!result) throw Object.assign(new Error('OpenAI returned an invalid modesty result'), { code: 'INVALID_RESPONSE' });
    const responseResult = {
      configured: true, available: true, status: 'completed', model, ...result,
      durationMs: Math.round(performance.now() - startedAt),
      usage,
    };
    await recordProviderCall({ provider: 'openai', model, operation,
      tracking: options.tracking, status: 'completed', usage, usageReported: capturedUsageReported,
      durationMs: responseResult.durationMs, result: responseResult });
    return responseResult;
  } catch (error) {
    const result = {
      configured: true,
      available: false,
      status: 'error',
      errorCode: String(error?.code || error?.name || 'INVALID_RESPONSE'),
      error: String(error?.message || error).slice(0, 300),
      durationMs: Math.round(performance.now() - startedAt),
    };
    await recordProviderCall({ provider: 'openai', model,
      operation, tracking: options.tracking, status: 'failed',
      usage: capturedUsage, usageReported: capturedUsageReported,
      durationMs: result.durationMs, errorCode: result.errorCode, result });
    return result;
  }
}

module.exports = { MODESTY_POLICY_PROMPT, MODESTY_UNCERTAINTY_REVIEW_PROMPT,
  MODESTY_RESPONSE_SCHEMA, UNCERTAINTY_REVIEW_TIMEOUT_MS,
  classifyOpenAIModesty, classifyOpenAIModestyUncertaintyReview, parseModestyDecision,
  corroboratedCompliantGeminiFlag };
