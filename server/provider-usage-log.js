'use strict';

const crypto = require('crypto');
const { getPool } = require('./db');

const TOKEN_PRICES = {
  openai: {
    'gpt-4.1-mini': { input: 0.40, output: 1.60 },
    'gpt-4.1-nano': { input: 0.10, output: 0.40 },
  },
  gemini: {
    'gemini-2.5-flash': { input: 0.30, output: 2.50 },
    'gemini-2.5-flash-lite': { input: 0.10, output: 0.40 },
    'gemini-3.6-flash': { input: 0.75, output: 3.75 },
    'gemini-3.7-flash': { input: 0.75, output: 3.75 },
  },
};

const GOOGLE_UNIT_PRICES = {
  safe_search: 1.50 / 1000,
  object_localization: 2.25 / 1000,
  face_detection: 1.50 / 1000,
};

function nonNegativeEnv(name) {
  if (process.env[name] == null || process.env[name] === '') return null;
  const value = Number(process.env[name]);
  return Number.isFinite(value) && value >= 0 ? value : null;
}

function priceSnapshot(provider, model, operation) {
  if (provider === 'google_vision') {
    const custom = nonNegativeEnv(`MODERATION_GOOGLE_${operation.toUpperCase()}_USD_PER_UNIT`);
    const unit = custom ?? GOOGLE_UNIT_PRICES[operation] ?? null;
    return { unit, source: custom == null ? 'official_list' : 'configured' };
  }
  const prefix = provider === 'openai' ? 'OPENAI' : 'GEMINI';
  const customInput = nonNegativeEnv(`MODERATION_${prefix}_INPUT_USD_PER_MILLION`);
  const customOutput = nonNegativeEnv(`MODERATION_${prefix}_OUTPUT_USD_PER_MILLION`);
  if (customInput !== null && customOutput !== null)
    return { input: customInput, output: customOutput, source: 'configured' };
  const known = TOKEN_PRICES[provider]?.[model];
  return known ? { ...known, source: 'official_list' } :
    { input: null, output: null, source: 'unknown' };
}

function estimatedCost(price, usage, units, cacheHit) {
  if (cacheHit) return 0;
  if (price.unit != null) return Number(units || 0) * price.unit;
  if (price.input == null || price.output == null) return null;
  return Number(usage?.inputTokens || 0) / 1_000_000 * price.input +
    (Number(usage?.outputTokens || 0) + Number(usage?.thoughtTokens || 0)) /
      1_000_000 * price.output;
}

async function recordProviderCall(event) {
  // Unit tests import provider modules without bootstrapping the application
  // environment. No database means there is deliberately nowhere to log.
  if (!process.env.DATABASE_URL) return;
  const provider = String(event.provider || 'unknown').slice(0, 40);
  const model = event.model ? String(event.model).slice(0, 120) : null;
  const operation = String(event.operation || 'unknown').slice(0, 80);
  const usage = event.usage || {};
  const units = Number(event.units || 0);
  const price = priceSnapshot(provider, model, operation);
  const cost = estimatedCost(price, usage, units, event.cacheHit === true);
  try {
    const pool = await getPool();
    await pool.query(`INSERT INTO moderation_provider_calls
      (request_id,stored_file_id,user_id,provider,model,operation,workflow,
       attempt,status,input_tokens,output_tokens,thought_tokens,total_tokens,
       billable_units,duration_ms,usage_reported,cache_hit,error_code,
       input_price_usd_per_million,output_price_usd_per_million,
       unit_price_usd,price_source,estimated_cost_usd,completed_at)
      VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,
             $19,$20,$21,$22,$23,now())`, [
      event.requestId || crypto.randomUUID(), event.tracking?.storedFileId || null,
      event.tracking?.userId || null, provider, model, operation,
      event.tracking?.workflow || 'unknown', Number(event.tracking?.attempt || 1),
      event.status || 'completed', Number(usage.inputTokens || 0),
      Number(usage.outputTokens || 0), Number(usage.thoughtTokens || 0),
      Number(usage.totalTokens || 0), units, Number(event.durationMs || 0),
      event.usageReported === true || Boolean(event.usage), event.cacheHit === true,
      event.errorCode ? String(event.errorCode).slice(0, 120) : null,
      price.input ?? null, price.output ?? null, price.unit ?? null, price.source,
      cost,
    ]);
  } catch (error) {
    console.warn('Provider usage log:', error.message);
  }
}

module.exports = { GOOGLE_UNIT_PRICES, TOKEN_PRICES, priceSnapshot,
  recordProviderCall };
