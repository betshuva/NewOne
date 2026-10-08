'use strict';

const sharp = require('sharp');
const { MODESTY_POLICY_PROMPT, MODESTY_UNCERTAINTY_REVIEW_PROMPT,
  MODESTY_RESPONSE_SCHEMA, UNCERTAINTY_REVIEW_TIMEOUT_MS,
  parseModestyDecision } = require('./modesty-verification');
const { recordProviderCall } = require('./provider-usage-log');
const { guardModerationProvider, providerRequestSignal } = require('./moderation-provider-guard');

const DEFAULT_MODEL = 'gemini-3.5-flash-lite';

async function prepareGeminiImage(buffer) {
  return sharp(buffer, { failOn: 'error', limitInputPixels: 120_000_000 })
    .rotate()
    .resize({ width: 768, height: 768, fit: 'inside', withoutEnlargement: true })
    .jpeg({ quality: 82, chromaSubsampling: '4:2:0' })
    .toBuffer();
}

async function classifyGeminiModesty(buffer, options = {}) {
  const apiKey = String(options.apiKey ?? process.env.GEMINI_API_KEY ?? '').trim();
  return guardModerationProvider({ provider: 'gemini', operation: 'modesty',
    apiKey, options, run: () => requestGeminiModesty(buffer, options) });
}

async function classifyGeminiModestyUncertaintyReview(buffer, options = {}) {
  const apiKey = String(options.apiKey ?? process.env.GEMINI_API_KEY ?? '').trim();
  return guardModerationProvider({ provider: 'gemini', operation: 'modesty_uncertainty_review',
    apiKey, options, run: () => requestGeminiModesty(buffer, options, {
      operation: 'modesty_uncertainty_review',
      prompt: MODESTY_UNCERTAINTY_REVIEW_PROMPT,
      timeoutMs: UNCERTAINTY_REVIEW_TIMEOUT_MS,
      allowFormatRepair: false,
    }) });
}

async function requestGeminiModesty(buffer, options, {
  operation = 'modesty', prompt = MODESTY_POLICY_PROMPT,
  timeoutMs = 30000, allowFormatRepair = true,
} = {}) {
  const startedAt = performance.now();
  const apiKey = String(options.apiKey ?? process.env.GEMINI_API_KEY ?? '').trim();
  if (!apiKey)
    return { configured: false, available: false, status: 'not_configured' };
  const fetchImpl = options.fetchImpl || globalThis.fetch;
  const model = options.model || process.env.GEMINI_MODESTY_MODEL || DEFAULT_MODEL;
  try {
    const prepared = options.skipImagePreparation ? buffer : await prepareGeminiImage(buffer);
    const endpoint = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent`;
    const usage = { cachedInputTokens: 0, inputTokens: 0, outputTokens: 0, thoughtTokens: 0,
      totalTokens: 0 };
    const generate = async (contents, operation) => {
      const requestStartedAt = performance.now();
      let data = {};
      let result;
      let callUsage = null;
      let text = '';
      try {
        const response = await fetchImpl(endpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-goog-api-key': apiKey,
      },
      body: JSON.stringify({
        store: false,
        contents,
        generationConfig: {
          temperature: 0,
          maxOutputTokens: 400,
          responseMimeType: 'application/json',
          responseJsonSchema: MODESTY_RESPONSE_SCHEMA,
        },
      }),
      signal: providerRequestSignal(options, timeoutMs),
        });
        const payload = await response.json().catch(() => ({}));
        data = payload && typeof payload === 'object' && !Array.isArray(payload) ? payload : {};
        callUsage = {
          inputTokens: Number(data.usageMetadata?.promptTokenCount || 0),
          cachedInputTokens: Number(data.usageMetadata?.cachedContentTokenCount || 0),
          outputTokens: Number(data.usageMetadata?.candidatesTokenCount || 0),
          thoughtTokens: Number(data.usageMetadata?.thoughtsTokenCount || 0),
          totalTokens: Number(data.usageMetadata?.totalTokenCount || 0),
        };
        for (const key of Object.keys(usage)) usage[key] += callUsage[key];
        if (!response.ok) throw Object.assign(new Error(data?.error?.message || `Gemini HTTP ${response.status}`),
          { code: data?.error?.status || `HTTP_${response.status}` });
        const providerBlock = data.promptFeedback?.blockReason || data.candidates?.[0]?.finishReason === 'SAFETY';
        if (providerBlock) result = { configured: true, available: true, status: 'safety_blocked', model,
          decision: 'non_modest', confidence: 1, reason: 'Gemini safety filter blocked the image' };
        else {
          const parts = data.candidates?.[0]?.content?.parts;
          text = Array.isArray(parts)
            ? parts.map(part => typeof part?.text === 'string' ? part.text : '').join('') : '';
          const decision = parseModestyDecision(text);
          if (!decision) throw Object.assign(new Error('Gemini returned an invalid modesty result after schema enforcement'),
            { code: 'INVALID_RESPONSE' });
          result = { configured: true, available: true, status: 'completed', model, ...decision };
        }
      } catch (error) {
        result = { configured: true, available: false, status: 'error', model,
          errorCode: String(error?.code || error?.name || 'REQUEST_FAILED'),
          error: String(error?.message || error).slice(0, 300) };
      }
      result.durationMs = Math.round(performance.now() - requestStartedAt);
      await recordProviderCall({ provider: 'gemini', model, operation,
        tracking: options.tracking, status: result.available ? 'completed' : 'failed',
        usage: callUsage, usageReported: Boolean(data.usageMetadata),
        durationMs: result.durationMs, errorCode: result.errorCode, result });
      return { result, text };
    };
    let generated = await generate([{ role: 'user', parts: [
      { text: prompt },
      { inlineData: { mimeType: 'image/jpeg', data: prepared.toString('base64') } },
    ] }], operation);
    const text = generated.text;
    let formatRepaired = false;
    if (allowFormatRepair && generated.result.errorCode === 'INVALID_RESPONSE' && text.trim() && !options.tracking?.videoBudget) {
      generated = await generate([{ role: 'user', parts: [{ text:
        `Convert the following attempted classification to the required JSON schema. ` +
        `Preserve its meaning and do not inspect or invent image details:\n${text.slice(0, 2000)}`,
      }] }], 'modesty_format_repair');
      formatRepaired = true;
    }
    Object.assign(generated.result, { usage, formatRepaired, durationMs: Math.round(performance.now() - startedAt) });
    return generated.result;
  } catch (error) {
    return { configured: true, available: false, status: 'error', model,
      errorCode: String(error?.code || error?.name || 'INVALID_RESPONSE'),
      error: String(error?.message || error).slice(0, 300),
      durationMs: Math.round(performance.now() - startedAt) };
  }
}

module.exports = { DEFAULT_MODEL, MODESTY_RESPONSE_SCHEMA,
  MODESTY_UNCERTAINTY_REVIEW_PROMPT, UNCERTAINTY_REVIEW_TIMEOUT_MS,
  classifyGeminiModesty, classifyGeminiModestyUncertaintyReview, prepareGeminiImage };
