'use strict';

const sharp = require('sharp');
const { MODESTY_POLICY_PROMPT, parseModestyDecision } = require('./modesty-verification');
const { recordProviderCall } = require('./provider-usage-log');

const DEFAULT_MODEL = 'gemini-3.5-flash-lite';
const MODESTY_RESPONSE_SCHEMA = {
  type: 'object',
  properties: {
    decision: { type: 'string', enum: ['modest', 'non_modest', 'uncertain'] },
    confidence: { type: 'number', minimum: 0, maximum: 1 },
    violationClearlyVisible: { type: 'boolean' },
    visibleEvidence: { type: 'string' },
    reason: { type: 'string' },
  },
  required: ['decision', 'confidence', 'violationClearlyVisible',
    'visibleEvidence', 'reason'],
  additionalProperties: false,
};

async function prepareGeminiImage(buffer) {
  return sharp(buffer, { failOn: 'error', limitInputPixels: 120_000_000 })
    .rotate()
    .resize({ width: 768, height: 768, fit: 'inside', withoutEnlargement: true })
    .jpeg({ quality: 82, chromaSubsampling: '4:2:0' })
    .toBuffer();
}

async function classifyGeminiModesty(buffer, options = {}) {
  const startedAt = performance.now();
  const apiKey = String(options.apiKey ?? process.env.GEMINI_API_KEY ?? '').trim();
  if (!apiKey)
    return { configured: false, available: false, status: 'not_configured' };
  const fetchImpl = options.fetchImpl || globalThis.fetch;
  const model = options.model || process.env.GEMINI_MODESTY_MODEL || DEFAULT_MODEL;
  try {
    const prepared = options.skipImagePreparation ? buffer : await prepareGeminiImage(buffer);
    const endpoint = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent`;
    const usage = { inputTokens: 0, outputTokens: 0, thoughtTokens: 0,
      totalTokens: 0 };
    const generate = async (contents, operation) => {
      const requestStartedAt = performance.now();
      let response;
      let data = {};
      try {
        response = await fetchImpl(endpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-goog-api-key': apiKey,
      },
      body: JSON.stringify({
        contents,
        generationConfig: {
          temperature: 0,
          maxOutputTokens: 400,
          responseMimeType: 'application/json',
          responseJsonSchema: MODESTY_RESPONSE_SCHEMA,
        },
      }),
      signal: AbortSignal.timeout(30000),
        });
        data = await response.json().catch(() => ({}));
        const callUsage = {
          inputTokens: Number(data.usageMetadata?.promptTokenCount || 0),
          outputTokens: Number(data.usageMetadata?.candidatesTokenCount || 0),
          thoughtTokens: Number(data.usageMetadata?.thoughtsTokenCount || 0),
          totalTokens: Number(data.usageMetadata?.totalTokenCount || 0),
        };
        for (const key of Object.keys(usage)) usage[key] += callUsage[key];
        await recordProviderCall({ provider: 'gemini', model, operation,
          tracking: options.tracking, status: response.ok ? 'completed' : 'failed',
          usage: callUsage, usageReported: Boolean(data.usageMetadata),
          durationMs: Math.round(performance.now() - requestStartedAt),
          errorCode: response.ok ? null : data?.error?.status || `HTTP_${response.status}` });
        if (!response.ok)
        throw new Error(data?.error?.message || `Gemini HTTP ${response.status}`);
        return data;
      } catch (error) {
        if (!response) await recordProviderCall({ provider: 'gemini', model,
          operation, tracking: options.tracking, status: 'failed',
          durationMs: Math.round(performance.now() - requestStartedAt),
          errorCode: error?.code || error?.name || 'REQUEST_FAILED' });
        throw error;
      }
    };
    let data = await generate([{ role: 'user', parts: [
      { text: MODESTY_POLICY_PROMPT },
      { inlineData: { mimeType: 'image/jpeg', data: prepared.toString('base64') } },
    ] }], 'modesty');
    const finishReason = data.candidates?.[0]?.finishReason;
    const providerBlock = data.promptFeedback?.blockReason || finishReason === 'SAFETY';
    if (providerBlock) {
      return { configured: true, available: true, status: 'safety_blocked', model,
        decision: 'non_modest', confidence: 1,
        reason: 'Gemini safety filter blocked the image', usage,
        durationMs: Math.round(performance.now() - startedAt) };
    }
    let text = (data.candidates?.[0]?.content?.parts || [])
      .map(part => part.text || '').join('');
    let result = parseModestyDecision(text);
    let formatRepaired = false;
    if (!result && text.trim()) {
      data = await generate([{ role: 'user', parts: [{ text:
        `Convert the following attempted classification to the required JSON schema. ` +
        `Preserve its meaning and do not inspect or invent image details:\n${text.slice(0, 2000)}`,
      }] }], 'modesty_format_repair');
      text = (data.candidates?.[0]?.content?.parts || [])
        .map(part => part.text || '').join('');
      result = parseModestyDecision(text);
      formatRepaired = true;
    }
    if (!result) throw new Error('Gemini returned an invalid modesty result after schema enforcement');
    return { configured: true, available: true, status: 'completed', model,
      ...result, usage, formatRepaired,
      durationMs: Math.round(performance.now() - startedAt) };
  } catch (error) {
    return { configured: true, available: false, status: 'error', model,
      error: String(error?.message || error).slice(0, 300),
      durationMs: Math.round(performance.now() - startedAt) };
  }
}

module.exports = { DEFAULT_MODEL, MODESTY_RESPONSE_SCHEMA,
  classifyGeminiModesty, prepareGeminiImage };
