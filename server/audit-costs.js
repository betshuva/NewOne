"use strict";
const {currentFx}=require('./audit-fx');
const COST_FIELDS={
 input_tokens:['number','step','input_tokens'],output_tokens:['number','step','output_tokens'],
 cached_input_tokens:['number','step','cached_input_tokens'],total_tokens:['number','step','total_tokens'],
 cost_ils:['decimal','step','cost_ils'],usage_status:['text','step','status'],usage_model:['text','step','model'],
 fx_rate:['decimal','step','fx_rate'],fx_date:['text','step','fx_date'],
 operation_input_tokens:['number','parent','input_tokens'],operation_output_tokens:['number','parent','output_tokens'],
 operation_total_tokens:['number','parent','total_tokens'],operation_cost_ils:['decimal','parent','cost_ils'],
 operation_usage_status:['text','parent','status'],
};
const USAGE_LABELS={estimated:'אומדן מתועד',partial:'חסר מידע',no_charge:'ללא קריאת ספק בתשלום'};
const COST_SQL=`
DO $$ BEGIN IF to_regclass('moderation_provider_calls') IS NOT NULL THEN
 ALTER TABLE moderation_provider_calls ADD COLUMN IF NOT EXISTS audit_operation_id uuid;
 ALTER TABLE moderation_provider_calls ADD COLUMN IF NOT EXISTS cached_input_tokens bigint;
 ALTER TABLE moderation_provider_calls ADD COLUMN IF NOT EXISTS cost_basis jsonb;
 CREATE INDEX IF NOT EXISTS moderation_provider_calls_audit_idx ON moderation_provider_calls(audit_operation_id);
 CREATE INDEX IF NOT EXISTS moderation_provider_calls_request_text_idx ON moderation_provider_calls((request_id::text));
END IF; END $$;
CREATE INDEX IF NOT EXISTS audit_events_provider_call_idx ON audit_events((details->>'providerCallId')) WHERE details ? 'providerCallId';
CREATE OR REPLACE FUNCTION system_audit_usage(op uuid,step bigint,fx numeric,fxday text)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE answer jsonb;
BEGIN
 WITH evidence AS MATERIALIZED (
  SELECT e.id,e.details,e.executor_type FROM audit_events e WHERE e.operation_id=op
 ), links AS (
  SELECT details->>'providerCallId' AS request,min(id) AS event_id FROM evidence
  WHERE details ? 'providerCallId' GROUP BY details->>'providerCallId'
 ), linked_calls AS (
  SELECT p.*,l.event_id FROM moderation_provider_calls p LEFT JOIN links l ON p.request_id::text=l.request
  WHERE p.audit_operation_id=op
  UNION ALL
  SELECT p.*,l.event_id FROM links l JOIN moderation_provider_calls p ON p.request_id::text=l.request
  WHERE p.audit_operation_id IS NULL
 ), calls AS (
  SELECT * FROM linked_calls WHERE step IS NULL OR event_id=step
 ), normalized AS (
  SELECT request_id::text AS request,model,cache_hit,
   CASE WHEN cache_hit OR provider='google_vision' THEN 0 WHEN usage_reported THEN input_tokens END AS inp,
   CASE WHEN cache_hit OR provider='google_vision' THEN 0 WHEN usage_reported THEN output_tokens+thought_tokens END AS outp,
   CASE WHEN cache_hit OR provider='google_vision' THEN 0 WHEN usage_reported THEN total_tokens END AS tokens,
   CASE WHEN cache_hit OR provider='google_vision' THEN 0 WHEN usage_reported THEN cached_input_tokens END AS cached,
   CASE WHEN cache_hit THEN 0 WHEN (usage_reported OR provider='google_vision' AND status='completed') THEN estimated_cost_usd::numeric END AS usd,
   COALESCE((cost_basis->>'fxRate')::numeric,fx) AS rate,
   COALESCE(cost_basis->>'fxDate',fxday) AS rate_date,
   jsonb_build_object('model',model,'provider',provider,'source',price_source,'inputUsdPerMillion',input_price_usd_per_million,
    'outputUsdPerMillion',output_price_usd_per_million,'unitUsd',unit_price_usd,'snapshot',cost_basis) AS basis
  FROM calls
  UNION ALL
  SELECT NULL,details->>'model',false,NULL,NULL,NULL,NULL,NULL,fx,fxday,
   jsonb_build_object('missingUsage',true)
  FROM evidence e WHERE (step IS NULL OR id=step) AND (
   (details ? 'providerCallId' AND NOT EXISTS(SELECT 1 FROM moderation_provider_calls p WHERE p.request_id::text=e.details->>'providerCallId'))
   OR (NOT details ? 'providerCallId' AND executor_type='provider'
    AND COALESCE(details->>'checkOutcome','') NOT IN ('skipped','not_applicable')
    AND COALESCE(details->>'cacheHit','false')<>'true'))
 ), sums AS (
  SELECT count(*) AS calls,count(*) FILTER(WHERE usd IS NULL) AS missing_cost,
   count(*) FILTER(WHERE tokens IS NULL OR inp IS NULL OR outp IS NULL) AS missing_tokens,
   COALESCE(sum(inp),0) AS inp,COALESCE(sum(outp),0) AS outp,COALESCE(sum(tokens),0) AS tokens,
   CASE WHEN count(*) FILTER(WHERE cached IS NULL)=0 THEN COALESCE(sum(cached),0) END AS cached,
   round(COALESCE(sum(usd*rate),0),12) AS ils,COALESCE(sum(usd),0) AS usd,
   CASE WHEN count(DISTINCT model)=1 THEN min(model) END AS model,
   CASE WHEN count(DISTINCT rate)=1 THEN min(rate) END AS rate,
   CASE WHEN count(DISTINCT rate_date)=1 THEN min(rate_date) END AS rate_date,
   COALESCE(jsonb_agg(DISTINCT basis),'[]'::jsonb) AS basis FROM normalized
 ) SELECT jsonb_build_object('input_tokens',CASE WHEN missing_tokens=0 THEN inp END,
  'output_tokens',CASE WHEN missing_tokens=0 THEN outp END,'total_tokens',CASE WHEN missing_tokens=0 THEN tokens END,
  'cached_input_tokens',cached,'cost_ils',CASE WHEN missing_cost=0 THEN ils END,
  'known_cost_ils',ils,'known_total_tokens',tokens,'cost_usd',CASE WHEN missing_cost=0 THEN usd END,
  'missing_calls',GREATEST(missing_cost,missing_tokens),'calls',calls,
  'status',CASE WHEN missing_cost>0 OR missing_tokens>0 THEN 'partial' WHEN calls=0 THEN 'no_charge' ELSE 'estimated' END,
  'model',model,'fx_rate',rate,'fx_date',rate_date,'basis',basis) INTO answer FROM sums;
 RETURN answer;
END $$;
`;
function enabled(filters){return filters.costs||Object.hasOwn(COST_FIELDS,filters.sort||'')||Object.keys(filters.columnFilters||{}).some(k=>Object.hasOwn(COST_FIELDS,k));}
function usageSql(operation,step='NULL'){
 const fx=currentFx();return `system_audit_usage(${operation},${step},${fx.rate}::numeric,'${fx.date}')`;
}
function fieldSql(alias,key){
 const [type,scope,property]=COST_FIELDS[key];
 const value=`(${usageSql('o.id',scope==='parent'?'NULL':alias+'.id')}->>'${property}')`;
 return type==='number'?`(${value})::bigint`:type==='decimal'?`(${value})::numeric`:value;
}
function presentUsage(row){
 for(const [key,[,scope,property]]of Object.entries(COST_FIELDS)){
  const usage=scope==='parent'?row.operation_usage:row.usage;
  if(usage)row[key]=usage[property]??null;
 }
 return row;
}
module.exports={COST_SQL,COST_FIELDS,USAGE_LABELS,enabled,usageSql,fieldSql,presentUsage};
