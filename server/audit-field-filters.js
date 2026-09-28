'use strict';
const {COST_FIELDS,USAGE_LABELS,fieldSql:costFieldSql}=require('./audit-costs');
const {DISPATCH_FIELDS,SEND_LABELS,DELIVERY_LABELS,TYPE_LABELS,OBJECT_STATUS_LABELS}=require('./audit-dispatch');
const {EVENT_KIND_LABELS}=require('./system-audit-catalog');
const {checkOutcomeSql,CHECK_OUTCOME_LABELS}=require('./audit-check-presentation');
const {imageKeySql,imageNameSql}=require('./audit-image-names');
const {problemFileEventSql}=require('./audit-problem-file');
const AUDIT_REASON_LABELS={scan_stopped:'הסריקה נעצרה',scan_incomplete:'בדיקה נדרשת לא הושלמה',required_provider_unavailable:'שירות בדיקה נדרש אינו זמין',budget_exhausted:'מכסת הבדיקות לסרטון מוצתה',deadline_exceeded:'הסריקה חרגה מהזמן המותר',credit_balance_exhausted:'אין יתרת קרדיט אצל ספק הבדיקה',provider_suspended:'ספק הבדיקה מושהה',provider_not_configured:'ספק בדיקה נדרש אינו מוגדר',legacy_budget_unknown:'לא ניתן לאמת את מספר הבדיקות הקודמות',frame_manifest_changed:'התמונות שנדגמו אינן תואמות לסריקה הקודמת',scan_version_changed:'גרסת הסריקה השתנתה ונדרש אישור לבדיקה נוספת',operation_outcome_unknown:'תוצאת בקשת בדיקה קודמת אינה ידועה',provider_guard_unavailable:'לא ניתן לאמת את מכסת הבדיקות',source_unavailable:'לא ניתן לקרוא את קובץ הסרטון',queue_processed:'הטיפול בתור הסתיים',media_not_allowed:'המדיה לא אושרה',outcome_unknown:'התוצאה אינה ידועה',request_removed_without_acceptance:'הבקשה הוסרה ללא אישור',request_entry_removed:'רשומת הבקשה הוסרה',permission_denied:'אין הרשאה',unauthorized:'נדרשת הזדהות',forbidden:'אין הרשאה',not_found:'היעד לא נמצא',timeout:'תם זמן ההמתנה',provider_error:'שגיאה אצל ספק השירות',filter_blocked:'נחסם לפי הגדרות הסינון'};
const STATUS_LABELS={accepted:'התקבל',queued:'בתור',running:'בתהליך',pending:'ממתין',stored:'נשמר בשרת',persisted:'נשמר בשרת',completed:'הושלם',succeeded:'הצליח',cancelled:'בוטל',partial:'חלקי',observed:'תועד',approved:'אושר',delivered:'נמסר',read:'נקרא',failed:'נכשל',blocked:'נחסם',rejected:'נדחה',skipped:'דולג',unknown:'לא ידוע'};
const EXECUTOR_LABELS={user:'משתמש',admin:'מנהל',service:'שירות',worker:'שירות',system:'מערכת',provider:'ספק',client:'מכשיר'};
const PROVIDER_LABELS={google_vision:'Google Vision',openai:'OpenAI',gemini:'Gemini',local:'בדיקה מקומית',local_clip:'בדיקה מקומית',local_safety:'בדיקה מקומית'};
const TARGET_LABELS={general:'סינון כללי',contact:'סינון איש קשר',group:'סינון קבוצה',user:'משתמש',message:'הודעה',file:'קובץ',stored_file:'קובץ',pending_scan:'סריקה בתור'};
const CHANGE_LABELS={Text:'טקסט',Image:'תמונות',Video:'סרטונים',Audio:'קול',Document:'מסמכים',Men:'גברים',Women:'נשים',Children:'ילדים',NonHumanImages:'נוף וחפצים',EnforceGeneralFilter:'אכיפת הסינון הכללי'};
const OPERATION_OUTCOME_JOINS = `    LEFT JOIN LATERAL (SELECT e.id::text AS id,e.kind,e.status,e.reason_code,e.details
      FROM audit_events e WHERE e.operation_id=o.id AND e.kind=o.status_source
      AND e.operation_status=o.status ORDER BY e.id DESC LIMIT 1) outcome ON true
    LEFT JOIN LATERAL (SELECT e.id::text AS id,e.kind,e.status,e.reason_code,e.details
      FROM audit_events e WHERE e.operation_id=o.id AND o.status_source='scan_workflow_finished'
      AND e.kind='scan_workflow_finished' AND e.operation_status=o.status
      AND e.id<=outcome.id::bigint
      AND (e.reason_code NOT IN ('scan_stopped','queue_processed')
        OR (jsonb_typeof(e.details->'providerCallsUsed')='number'
          AND jsonb_typeof(e.details->'providerCallsLimit')='number'))
      AND NOT EXISTS(SELECT 1 FROM audit_events boundary WHERE boundary.operation_id=o.id AND boundary.id>e.id
        AND (boundary.kind='scan_attempt_started' OR (boundary.kind='scan_workflow_finished'
          AND boundary.operation_status IS DISTINCT FROM e.operation_status)))
      ORDER BY e.id DESC LIMIT 1) scan ON true
`;

const FIELDS={
 scan_status:['text','step'],
 scan_image:['text','step'],
 stopped_file:['text','parent'],
 operation_status:['text','parent'],operation_reason:['text','parent'],operation_reason_code:['text','parent'],
 initiator_identifier:['text','parent'],recipient_identifier:['text','parent'],operation_id:['uuid','parent'],
 step_total:['number','parent'],step_index:['number','step'],
 executor_identifier:['text','step'],executor_type:['text','step'],event_id:['bigint','step'],parent_event_id:['bigint','step'],attempt:['number','step'],
 step_reason:['text','step'],step_reason_code:['text','step'],before_value:['text','step'],after_value:['text','step'],
 change_context:['text','step'],event_explanation:['text','step'],elapsed_ms:['number','step'],
 provider:['text','step'],frame_index:['number','step'],frame_timestamp:['number','step'],cache_hit:['text','step'],
 person_count:['number','step'],face_count:['number','step'],confidence:['number','step'],http_status:['number','step'],affected_count:['number','step'],
 provider_calls_used:['number','budget'],provider_calls_limit:['number','budget'],
};
for(const [key,[type,scope]]of Object.entries(COST_FIELDS))FIELDS[key]=[type,scope];
for(const [key,type]of Object.entries(DISPATCH_FIELDS))FIELDS[key]=[type,'parent'];
for(const key of Object.keys(CHANGE_LABELS))for(const side of ['before','after'])FIELDS[side+key]=['text','step'];
const hasField=key=>Object.hasOwn(FIELDS,key);
const parentField=(key,mode)=>hasField(key)&&(FIELDS[key][1]==='parent'||(FIELDS[key][1]==='budget'&&mode==='operations'));
const stepField=(key,mode)=>hasField(key)&&!parentField(key,mode);
const literal=value=>"'"+String(value).replaceAll("'","''")+"'";
function mappedSql(expression,labels){return `COALESCE(${literal(JSON.stringify(labels))}::jsonb ->> (${expression})::text,(${expression})::text)`;}
// Cast only bounded integer text. Malformed old metadata must not fail the page/query.
function integerSql(expression){return `(CASE WHEN (${expression}) ~ '^(0|[1-9][0-9]{0,15})$' THEN CASE WHEN (${expression})::bigint<=9007199254740991 THEN (${expression})::bigint END END)`;}
function operationReasonSql(){
 const reason=`COALESCE(NULLIF(o.reason_code,''),CASE WHEN outcome.status=o.status THEN outcome.reason_code END)`;
 return `(SELECT CASE WHEN o.status_source='scan_workflow_finished' AND (${reason} IS NULL OR ${reason} IN ('scan_stopped','queue_processed'))
   THEN COALESCE(CASE WHEN scan.status=o.status THEN scan.reason_code END,${reason}) ELSE ${reason} END
   FROM (SELECT 1) evidence ${OPERATION_OUTCOME_JOINS})`;
}
function fieldSql(alias,key,mode){
 if(!hasField(key))return null;
 if(Object.hasOwn(COST_FIELDS,key))return costFieldSql(alias,key);
 if(Object.hasOwn(DISPATCH_FIELDS,key))return DISPATCH_FIELDS[key]==='number'?`(o.dispatch->>'${key}')::bigint`:`o.dispatch->>'${key}'`;
 const d=`${alias}.details`,value=name=>`${d}->>${literal(name)}`,integer=name=>integerSql(value(name));
 switch(key){
  case 'operation_status':return 'o.status';
  case 'scan_status':return `COALESCE(${checkOutcomeSql(alias)},${alias}.status)`;
  case 'scan_image':return imageKeySql(alias);
  case 'stopped_file':return `(CASE WHEN o.dispatch->>'object_status' IS DISTINCT FROM 'blocked_for_recipient'
    THEN (SELECT problem.target_id::text FROM (${problemFileEventSql()}) problem) END)`;
  case 'operation_reason':case 'operation_reason_code':return mode==='operations'?operationReasonSql():"NULLIF(o.reason_code,'')";
  case 'initiator_identifier':return 'COALESCE(o.initiator_short_id,o.initiator_id::text)';
  case 'recipient_identifier':return 'COALESCE(o.recipient_short_id,o.recipient_id::text)';
  case 'operation_id':return 'o.id';
  case 'executor_identifier':return `${alias}.executor_id`;
  case 'executor_type':return `${alias}.executor_type`;
  case 'event_id':return `${alias}.id`;
  case 'parent_event_id':case 'attempt':return `${alias}.${key}`;
  case 'step_reason':case 'step_reason_code':return `COALESCE(NULLIF(${alias}.reason_code,''),NULLIF(${value('reasonCode')},''))`;
  case 'before_value':return `NULLIF(${value('previousStatus')},'')`;
  case 'after_value':return `NULLIF(${value('nextStatus')},'')`;
  case 'step_total':return '(SELECT count(*) FROM audit_events step_count WHERE step_count.operation_id=o.id AND step_count.id IS DISTINCT FROM o.root_event_id)';
  case 'step_index':return `(CASE WHEN ${alias}.id IS DISTINCT FROM o.root_event_id AND ${alias}.id IS NOT NULL THEN (SELECT count(*) FROM audit_events step_count WHERE step_count.operation_id=o.id AND step_count.id IS DISTINCT FROM o.root_event_id AND (date_trunc('milliseconds',step_count.created_at),step_count.id)<=(date_trunc('milliseconds',${alias}.created_at),${alias}.id)) END)`;
  case 'elapsed_ms':return `(CASE WHEN date_trunc('milliseconds',${alias}.created_at)>=date_trunc('milliseconds',o.created_at) THEN (extract(epoch FROM (date_trunc('milliseconds',${alias}.created_at)-date_trunc('milliseconds',o.created_at)))*1000)::bigint END)`;
  case 'change_context':{
   const changes=Object.keys(CHANGE_LABELS).map(name=>`((jsonb_typeof(${d}->'before${name}')='boolean' OR jsonb_typeof(${d}->'after${name}')='boolean') AND ${d}->'before${name}' IS DISTINCT FROM ${d}->'after${name}')`).join(' OR ');
   return `(CASE WHEN ${changes} THEN 'הגדרות סינון' WHEN (jsonb_typeof(${d}->'previousStatus')='string' OR jsonb_typeof(${d}->'nextStatus')='string') AND ${d}->'previousStatus' IS DISTINCT FROM ${d}->'nextStatus' THEN 'מצב' END)`;
  }
  case 'event_explanation':return `${alias}.kind`;
  case 'provider':return `COALESCE(NULLIF(${value('provider')},''),CASE WHEN ${alias}.executor_type='provider' THEN ${alias}.executor_id END)`;
  case 'frame_index':return `(${integer('frameIndex')}+1)`;
  case 'frame_timestamp':return integer('frameTimestampMs');
  case 'cache_hit':return `(CASE WHEN jsonb_typeof(${d}->'cacheHit')='boolean' THEN ${value('cacheHit')} END)`;
  case 'person_count':return integer('checkPersonCount');
  case 'face_count':return integer('checkFaceCount');
  case 'confidence':return integer('checkConfidencePct');
  case 'http_status':return integerSql(`COALESCE(${value('httpStatus')},${value('statusCode')},substring(${alias}.reason_code FROM '^http_([1-5][0-9]{2})$'))`);
  case 'affected_count':return integer('affectedCount');
  case 'provider_calls_used':case 'provider_calls_limit':{
   const property=key==='provider_calls_used'?'providerCallsUsed':'providerCallsLimit';
   if(mode==='events')return integer(property);
   return `(SELECT ${integerSql(`COALESCE(CASE WHEN scan.status=o.status THEN scan.details->>'${property}' END,CASE WHEN outcome.status=o.status THEN outcome.details->>'${property}' END)`)} FROM (SELECT 1) evidence ${OPERATION_OUTCOME_JOINS})`;
  }
  default:return `(CASE WHEN jsonb_typeof(${d}->${literal(key)})='boolean' THEN ${value(key)} END)`;
 }
}
function reasonLabelSql(expression){
 const generic=mappedSql(expression,AUDIT_REASON_LABELS);
 return `(CASE WHEN ${expression} IS NULL THEN NULL WHEN ${expression} ~ '^http_[1-5][0-9]{2}$' THEN
   CASE WHEN ${expression}<'http_300' THEN 'השרת השיב בהצלחה' WHEN ${expression}<'http_400' THEN 'השרת החזיר הפניה'
   WHEN ${expression}='http_401' THEN 'נדרשת הזדהות' WHEN ${expression}='http_403' THEN 'אין הרשאה' WHEN ${expression}='http_404' THEN 'היעד לא נמצא'
   WHEN ${expression}<'http_500' THEN 'השרת דחה את הבקשה' ELSE 'שגיאה בשרת' END
   ELSE CASE WHEN ${literal(JSON.stringify(AUDIT_REASON_LABELS))}::jsonb ? (${expression}) THEN ${generic} ELSE 'קוד סיבה מתועד: '||(${expression}) END END)`;
}
function fieldLabelSql(key,expression){
 if(key==='stopped_file')return imageNameSql(`(${expression})||':image'`);
 if(key==='object_status')return mappedSql(expression,OBJECT_STATUS_LABELS);
 if(key==='scan_image')return imageNameSql(expression);
 if(key==='scan_status')return mappedSql(expression,{...STATUS_LABELS,...CHECK_OUTCOME_LABELS});
 if(['usage_status','operation_usage_status'].includes(key))return mappedSql(expression,USAGE_LABELS);
 if(key==='dispatch_state')return mappedSql(expression,SEND_LABELS);
 if(key==='dispatch_delivery')return mappedSql(expression,DELIVERY_LABELS);
 if(key==='dispatch_message_type')return mappedSql(expression,TYPE_LABELS);
 if(key==='operation_reason'||key==='step_reason')return reasonLabelSql(expression);
 const labels=['operation_status','before_value','after_value'].includes(key)?STATUS_LABELS
  :key==='executor_type'?EXECUTOR_LABELS:key==='provider'?PROVIDER_LABELS:key==='target_type'?TARGET_LABELS
  :key==='cache_hit'?{true:'כן',false:'לא'}
  :key==='event_explanation'?{...EVENT_KIND_LABELS,http_response:'תשובת השרת לבקשה',http_connection_closed:'החיבור לשרת נסגר',filter_changed:'עדכון הגדרות הסינון',filter_baseline:'תיעוד הגדרות הסינון ההתחלתיות'}
  :/^(before|after)/.test(key)&&hasField(key)?(/EnforceGeneralFilter$/.test(key)?{true:'פעילה',false:'כבויה'}:{true:'מותר',false:'חסום'}):null;
 return labels?mappedSql(expression,labels):expression;
}
module.exports={FIELDS,hasField,parentField,stepField,fieldSql,fieldLabelSql,OPERATION_OUTCOME_JOINS};
