'use strict';

const crypto = require('crypto');
const {currentFx,refreshFx}=require('./audit-fx');
const { getPool } = require('./db');
const { getAuditContext } = require('./system-audit');
const { observeAudit } = require('./system-audit-context');
const { moderationCheckSummary } = require('./moderation-check-summary');

const recordedResults = new WeakSet();

function providerResultRecorded(result) {
  return Boolean(result && typeof result === 'object' && recordedResults.has(result));
}

async function recordProviderCheck(event, existingPool) {
  const audit = getAuditContext();
  if (!audit?.operationId) return;
  try {
    const pool = audit.transactionDb || existingPool || (process.env.DATABASE_URL ? await getPool() : null);
    if (!pool) return;
    const provider = String(event.provider || 'unknown').slice(0, 40);
    const auditOnly = event.auditOnly !== false;
    const summary = moderationCheckSummary(provider, event.operation, event.result, event.tracking);
    await observeAudit(pool, {
      kind: event.cacheHit || event.result?.cacheHit ? 'scan_cache_used'
        : auditOnly ? 'moderation_check_finished' : 'provider_call_finished',
      executorType: ['local', 'cache'].includes(provider) ? 'system' : 'provider',
      executorId: provider.replace(/[^a-zA-Z0-9_.:-]/g, '_'),
      source: provider === 'local' ? 'local_moderation' : provider === 'cache' ? 'scan_cache'
        : auditOnly ? 'provider_guard' : 'provider_usage',
      status: ['failed', 'stopped'].includes(summary.checkOutcome) || ['failed', 'error', 'timeout'].includes(event.status)
        ? 'failed' : summary.checkOutcome === 'blocked' ? 'blocked' : 'observed',
      attempt: Math.max(1, Math.min(1000000, Number(event.tracking?.attempt) || 1)),
      details: { provider, model: event.model, operation: event.operation, workflow: event.tracking?.workflow,
        storedFileId: event.tracking?.storedFileId, durationMs: event.durationMs,
        scanPreviewId: event.tracking?.scanPreviewId,
        providerCallId: event.requestId, auditOnly, ...summary,
        cacheHit: event.cacheHit === true || event.result?.cacheHit === true },
    });
  } catch (error) {
    console.warn('Provider check audit:', error.message);
  }
}

const TOKEN_PRICES = {
  openai: {
    'gpt-5.6-luna': {input:0.20,cached:0.02,cacheWrite:0.25,output:1.20,longContext:true},
    'gpt-4.1-mini': { input: 0.40, cached: 0.10, output: 1.60 },
    'gpt-4.1-nano': { input: 0.10, cached: 0.025, output: 0.40 },
  },
  gemini: {
    'gemini-3.5-flash-lite': {input:0.30,cached:0.03,output:2.50},
    'gemini-2.5-flash': { input: 0.30, cached: 0.03, output: 2.50 },
    'gemini-2.5-flash-lite': { input: 0.10, cached: 0.01, output: 0.40 },
    'gemini-3.6-flash': { input: 0.75, cached: 0.075, output: 3.75 },
    'gemini-3.7-flash': { input: 0.75, cached: 0.075, output: 3.75 },
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
    return { input: customInput, output: customOutput, cached: nonNegativeEnv(`MODERATION_${prefix}_CACHED_INPUT_USD_PER_MILLION`), cacheWrite: nonNegativeEnv(`MODERATION_${prefix}_CACHE_WRITE_USD_PER_MILLION`), source: 'configured' };
  let known = TOKEN_PRICES[provider]?.[model] || TOKEN_PRICES[provider]?.[String(model).replace(/-\d{4}-\d{2}-\d{2}$/, '')];
  if (known && provider==='gemini' && /^gemini-3\.[67]-flash$/.test(model) && new Date().getUTCFullYear()>=2027)
    known={input:1.50,cached:0.15,output:7.50};
  return known ? { ...known, source: 'official_list' } :
    { input: null, output: null, source: 'unknown' };
}

function estimatedCost(price, usage, units, cacheHit, usageReported=true, status='completed') {
  if (cacheHit) return 0;
  if (price.unit != null) return status==='completed'?Number(units || 0) * price.unit:null;
  if (!usageReported) return null;
  if (price.input == null || price.output == null) return null;
  const cached=Number(usage?.cachedInputTokens||0),writes=Number(usage?.cacheWriteTokens||0);
  if(price.cacheWrite!=null && usage?.cacheWriteTokens==null)return null;
  if(writes>0 && price.cacheWrite==null)return null;
  const long=price.longContext && Number(usage?.inputTokens)>272000;
  if(long)price={...price,input:price.input*2,cached:price.cached*2,cacheWrite:price.cacheWrite*2,output:price.output*1.5};
  if (cached>0 && price.cached==null) return null;
  return (Math.max(0,Number(usage?.inputTokens || 0)-cached-writes)*price.input + cached*(price.cached||0) + writes*(price.cacheWrite||0))/1_000_000 +
    (Number(usage?.outputTokens || 0) + Number(usage?.thoughtTokens || 0)) /
      1_000_000 * price.output + Number(usage?.webSearchCalls||0)*0.01;
}

async function recordProviderCall(event) {
  if (event.result && typeof event.result === 'object') recordedResults.add(event.result);
  // Unit tests import provider modules without bootstrapping the application
  // environment. No database means there is deliberately nowhere to log.
  if (!process.env.DATABASE_URL) return;
  const provider = String(event.provider || 'unknown').slice(0, 40);
  const model = event.model ? String(event.model).slice(0, 120) : null;
  const operation = String(event.operation || 'unknown').slice(0, 80);
  const usage = event.usage || {};
  const units = Number(event.units || 0);
  const price = priceSnapshot(provider, model, operation);
  const usageReported=event.usageReported === undefined ? Boolean(event.usage) : event.usageReported === true;
  const cost = estimatedCost(price, usage, units, event.cacheHit === true, usageReported, event.status||'completed');
  void refreshFx();
  const fx=currentFx(),audit=getAuditContext();
  const basis={version:1,verifiedAt:'2026-09-27',fxRate:fx.rate,fxDate:fx.date,fxSource:fx.source,
    cachedInputUsdPerMillion:price.cached??null,cacheWriteUsdPerMillion:price.cacheWrite??null,cacheWriteTokens:usage.cacheWriteTokens??null,webSearchCalls:usage.webSearchCalls||0,webSearchUsdPerCall:0.01,longContext:price.longContext===true&&Number(usage.inputTokens)>272000,priceSource:price.source==='configured'?'server_configuration':provider==='openai'?'https://developers.openai.com/api/docs/pricing':provider==='gemini'?'https://ai.google.dev/gemini-api/docs/pricing':'https://cloud.google.com/vision/pricing'};
  const requestId = event.requestId || crypto.randomUUID();
  let pool;
  try {
    pool = await getPool();
    await pool.query(`INSERT INTO moderation_provider_calls
      (request_id,stored_file_id,user_id,provider,model,operation,workflow,
       attempt,status,input_tokens,output_tokens,thought_tokens,total_tokens,
       billable_units,duration_ms,usage_reported,cache_hit,error_code,
       input_price_usd_per_million,output_price_usd_per_million,
       unit_price_usd,price_source,estimated_cost_usd,audit_operation_id,cached_input_tokens,cost_basis,completed_at)
      VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,
             $19,$20,$21,$22,$23,$24,$25,$26,now())`, [
      requestId, event.tracking?.storedFileId || null,
      event.tracking?.userId || null, provider, model, operation,
      event.tracking?.workflow || 'unknown', Number(event.tracking?.attempt || 1),
      event.status || 'completed', Number(usage.inputTokens || 0),
      Number(usage.outputTokens || 0), Number(usage.thoughtTokens || 0),
      Number(usage.totalTokens || 0), units, Number(event.durationMs || 0),
      event.usageReported === undefined ? Boolean(event.usage) : event.usageReported === true, event.cacheHit === true,
      event.errorCode ? String(event.errorCode).slice(0, 120) : null,
      price.input ?? null, price.output ?? null, price.unit ?? null, price.source,
      cost,audit?.operationId||null,usage.cachedInputTokens??null,JSON.stringify(basis),
    ]);
  } catch (error) {
    console.warn('Provider usage log:', error.message);
  }
  await recordProviderCheck({ ...event, requestId, auditOnly: false }, pool);
}

module.exports = { GOOGLE_UNIT_PRICES, TOKEN_PRICES, priceSnapshot, estimatedCost,
  recordProviderCall, recordProviderCheck, providerResultRecorded };
