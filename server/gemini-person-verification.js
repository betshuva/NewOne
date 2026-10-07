'use strict';

const { PERSON_PRESENCE_PROMPT, parsePersonPresenceDecision } =
  require('./person-presence-decision');
const { DEFAULT_MODEL, prepareGeminiImage } = require('./gemini-modesty-verification');
const { recordProviderCall } = require('./provider-usage-log');
const { guardModerationProvider, providerRequestSignal } = require('./moderation-provider-guard');

const PERSON_RESPONSE_SCHEMA = {
  type: 'object',
  properties: {
    decision: { type: 'string', enum: ['person', 'non_human', 'uncertain'] },
    person_categories: {
      type: 'array', items: { type: 'string', enum: ['men', 'women', 'children'] },
    },
    person_category: { type: 'string', enum: ['men', 'women', 'children', 'uncertain'] },
    confidence: { type: 'number', minimum: 0, maximum: 1 },
    reason: { type: 'string' },
  },
  required: ['decision', 'person_categories', 'person_category', 'confidence', 'reason'],
  additionalProperties: false,
};

async function classifyGeminiPersonPresence(buffer, options = {}) {
  const apiKey = String(options.apiKey ?? process.env.GEMINI_API_KEY ?? '').trim();
  return guardModerationProvider({ provider: 'gemini', operation: 'person_presence',
    apiKey, options, run: () => requestGeminiPersonPresence(buffer, options) });
}

async function requestGeminiPersonPresence(buffer, options) {
  const startedAt = performance.now();
  const apiKey = String(options.apiKey ?? process.env.GEMINI_API_KEY ?? '').trim();
  if (!apiKey) return { configured: false, available: false, status: 'not_configured' };
  const model = options.model || process.env.GEMINI_PERSON_MODEL ||
    process.env.GEMINI_MODESTY_MODEL || DEFAULT_MODEL;
  let prepared;
  try {
    prepared = options.skipImagePreparation ? buffer : await prepareGeminiImage(buffer);
  } catch (error) {
    return { configured: true, available: false, status: 'error', model,
      errorCode: String(error?.code || error?.name || 'IMAGE_PREPARATION_FAILED'),
      durationMs: Math.round(performance.now() - startedAt) };
  }

  let result;
  let usage = null;
  let usageReported = false;
  try {
    const fetchImpl = options.fetchImpl || globalThis.fetch;
    const response = await fetchImpl(
      `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'x-goog-api-key': apiKey },
        body: JSON.stringify({
          store: false,
          contents: [{ role: 'user', parts: [
            { text: PERSON_PRESENCE_PROMPT },
            { inlineData: { mimeType: 'image/jpeg', data: prepared.toString('base64') } },
          ] }],
          generationConfig: {
            temperature: 0,
            maxOutputTokens: 400,
            responseMimeType: 'application/json',
            responseJsonSchema: PERSON_RESPONSE_SCHEMA,
          },
        }),
        signal: providerRequestSignal(options, 30000),
      });
    const payload = await response.json().catch(() => ({}));
    const data = payload && typeof payload === 'object' && !Array.isArray(payload) ? payload : {};
    usageReported = Boolean(data.usageMetadata);
    usage = {
      inputTokens: Number(data.usageMetadata?.promptTokenCount || 0),
          cachedInputTokens: Number(data.usageMetadata?.cachedContentTokenCount || 0),
      outputTokens: Number(data.usageMetadata?.candidatesTokenCount || 0),
      thoughtTokens: Number(data.usageMetadata?.thoughtsTokenCount || 0),
      totalTokens: Number(data.usageMetadata?.totalTokenCount || 0),
    };
    if (!response.ok) throw Object.assign(
      new Error(data?.error?.message || `Gemini HTTP ${response.status}`),
      { code: data?.error?.status || `HTTP_${response.status}` });
    if (data.promptFeedback?.blockReason || data.candidates?.[0]?.finishReason === 'SAFETY')
      throw Object.assign(new Error('Gemini safety filter blocked the person review'),
        { code: 'SAFETY_BLOCKED' });
    const parts = data.candidates?.[0]?.content?.parts;
    const text = Array.isArray(parts)
      ? parts.filter(part => part?.thought !== true)
        .map(part => typeof part?.text === 'string' ? part.text : '').join('') : '';
    const decision = parsePersonPresenceDecision(text);
    if (!decision) throw Object.assign(new Error('Gemini returned an invalid person classification'),
      { code: 'INVALID_RESPONSE' });
    result = { configured: true, available: true, status: 'completed', model, ...decision };
  } catch (error) {
    result = { configured: true, available: false, status: 'error', model,
      errorCode: String(error?.code || error?.name || 'REQUEST_FAILED'),
      error: String(error?.message || error).slice(0, 300) };
  }
  Object.assign(result, { usage, durationMs: Math.round(performance.now() - startedAt) });
  await recordProviderCall({ provider: 'gemini', model, operation: 'person_presence',
    tracking: options.tracking, status: result.available ? 'completed' : 'failed',
    usage, usageReported, durationMs: result.durationMs, errorCode: result.errorCode, result });
  return result;
}

module.exports = { PERSON_RESPONSE_SCHEMA, classifyGeminiPersonPresence };
