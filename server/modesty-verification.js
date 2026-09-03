'use strict';

const { recordProviderCall } = require('./provider-usage-log');

const MODESTY_POLICY_PROMPT = 'Apply this clothing policy to every recognizable person in the image, including people inside screenshots, posters, drawings or embedded photos. Evaluate only body parts and clothing that are actually visible inside the image frame. Clothing and body parts that are completely outside the frame are not applicable: never decide uncertain or non_modest merely because the lower body, sleeve ends, or another area is outside the frame. For a headshot or upper-body portrait, ignore clothing below the photographed area. Bare arms, visible forearms, visible upper arms, and short sleeves are allowed for every person as long as the shoulders are covered. Never infer exposed arms, short sleeves, shorts, trouser length, or exposed legs from color, shadows, folds, a cropped frame, or an unclear lower-body area. Shorts may be reported only when both the garment hem and exposed leg below that hem are clearly visible. Women and girls: visible shoulders must be covered, a visible neckline must be high, and a visible lower body must have a long skirt; clearly visible pants, short skirts, exposed shoulders, sleeveless tops, low necklines, or revealing/tight clothing are non_modest. Men and boys: visible shoulders and chest must be covered and a visible lower body must have long pants; clearly visible shorts, exposed shoulders, sleeveless tops, shirtlessness, exposed legs, or exposed chest are non_modest. If any visible area clearly fails the policy, decide non_modest. Decide uncertain when a relevant clothing area is blurred, covered, too small, partly outside the frame, or genuinely ambiguous. Decide modest when every assessable visible area satisfies the policy and no visible violation exists. For non_modest you must identify a concrete visible body area and garment boundary. Set violationClearlyVisible=true only when those pixels are unambiguous; otherwise decide uncertain. Write the short reason and visible evidence in Hebrew. Return only JSON: {"decision":"modest|non_modest|uncertain","confidence":0.0,"violationClearlyVisible":false,"visibleEvidence":"what is directly visible, or empty","reason":"short Hebrew reason"}.';

function parseModestyDecision(text) {
  try {
    const cleaned = String(text || '').replace(/^```(?:json)?\s*|\s*```$/g, '');
    const value = JSON.parse(cleaned);
    if (!['modest', 'non_modest', 'uncertain'].includes(value.decision))
      return null;
    const evidence = String(value.visibleEvidence || '').slice(0, 300);
    const clearlyVisible = value.violationClearlyVisible === true;
    const unsupportedViolation = value.decision === 'non_modest' &&
      (!clearlyVisible || evidence.trim().length < 5);
    return {
      decision: unsupportedViolation ? 'uncertain' : value.decision,
      confidence: Math.max(0, Math.min(1, Number(value.confidence) || 0)),
      reason: String(value.reason || '').slice(0, 300),
      violationClearlyVisible: clearlyVisible,
      visibleEvidence: evidence,
      ...(unsupportedViolation ? { unsupportedViolation: true } : {}),
    };
  } catch (_) {
    return null;
  }
}

async function classifyOpenAIModesty(buffer, options = {}) {
  const startedAt = performance.now();
  const apiKey = String(options.apiKey ?? process.env.OPENAI_API_KEY ?? '').trim();
  if (!apiKey)
    return { configured: false, available: false, status: 'not_configured' };
  const fetchImpl = options.fetchImpl || globalThis.fetch;
  const model = options.model || process.env.OPENAI_VISION_MODEL || 'gpt-5.6-luna';
  let usageLogged = false;
  let capturedUsage = null;
  try {
    const response = await fetchImpl('https://api.openai.com/v1/responses', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model,
        reasoning: { effort: 'none' },
        max_output_tokens: 120,
        input: [{
          role: 'user',
          content: [
            { type: 'input_text', text: MODESTY_POLICY_PROMPT },
            { type: 'input_image', image_url: `data:image/jpeg;base64,${buffer.toString('base64')}`, detail: 'high' },
          ],
        }],
      }),
      signal: AbortSignal.timeout(30000),
    });
    const data = await response.json().catch(() => ({}));
    const usage = {
      inputTokens: Number(data.usage?.input_tokens || 0),
      outputTokens: Number(data.usage?.output_tokens || 0),
      totalTokens: Number(data.usage?.total_tokens || 0),
    };
    capturedUsage = usage;
    if (!response.ok) {
      await recordProviderCall({ provider: 'openai', model,
        operation: 'modesty', tracking: options.tracking, status: 'failed',
        usage, usageReported: Boolean(data.usage),
        durationMs: Math.round(performance.now() - startedAt),
        errorCode: data?.error?.code || `HTTP_${response.status}` });
      usageLogged = true;
      throw new Error(data?.error?.message || `OpenAI HTTP ${response.status}`);
    }
    const text = data.output_text || data.output?.flatMap(item => item.content || [])
      .find(item => item.type === 'output_text')?.text;
    const result = parseModestyDecision(text);
    if (!result) throw new Error('OpenAI returned an invalid modesty result');
    await recordProviderCall({ provider: 'openai', model, operation: 'modesty',
      tracking: options.tracking, status: 'completed', usage, usageReported: true,
      durationMs: Math.round(performance.now() - startedAt) });
    usageLogged = true;
    return {
      configured: true, available: true, status: 'completed', model, ...result,
      durationMs: Math.round(performance.now() - startedAt),
      usage,
    };
  } catch (error) {
    if (!usageLogged) await recordProviderCall({ provider: 'openai', model,
      operation: 'modesty', tracking: options.tracking, status: 'failed',
      usage: capturedUsage, usageReported: capturedUsage != null,
      durationMs: Math.round(performance.now() - startedAt),
      errorCode: error?.code || error?.name || 'INVALID_RESPONSE' });
    return {
      configured: true,
      available: false,
      status: 'error',
      error: String(error?.message || error).slice(0, 300),
      durationMs: Math.round(performance.now() - startedAt),
    };
  }
}

module.exports = { MODESTY_POLICY_PROMPT, classifyOpenAIModesty, parseModestyDecision };
