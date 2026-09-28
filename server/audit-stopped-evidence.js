'use strict';
const {presentAuditCheck}=require('./audit-check-presentation');
const {problemFileEventSql}=require('./audit-problem-file');
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Use unresolved frames in the persisted final result, not a provider's isolated
// block (which a later check may have resolved). Match previews within that attempt.
function stoppedItems(file,events){
  const name=file.original_name||'שם הקובץ אינו זמין',frames=Array.isArray(file.frames)?file.frames:[];
  const blocked=file.operation_status==='blocked';
  const recipientBlocked=blocked&&file.decision_kind==='decision_blocked';
  const missing=blocked?'לא תועדה תמונה מסוימת שגרמה לחסימה':'לא תועדה תמונה מסוימת שגרמה לעצירה';
  const unresolved=frames.filter(frame=>frame&&(blocked?!recipientBlocked&&frame.blocked===true:(frame.pending===true||frame.scanStopped===true)));
  const items=[];
  if(file.file_type==='image'){
    const event=events.filter(e=>e.details?.storedFileId===file.file_id&&e.details.scanPreviewId)
      .sort((a,b)=>BigInt(a.id)>BigInt(b.id)?-1:1)[0];
    const preview=event?presentAuditCheck(event):null;
    return [{name,key:UUID.test(file.file_id||'')?`${file.file_id.toLowerCase()}:image`:null,
      reason:blocked?(recipientBlocked?'התמונה נחסמה לפי הגדרות הסינון':'התמונה נחסמה'):'בדיקת התמונה נעצרה',preview:preview?.checkPreviewUrl?preview:null}];
  }
  for(const frame of unresolved){
    const index=frame.index,ms=typeof frame.timestampSeconds==='number'?Math.round(frame.timestampSeconds*1000):null;
    if(!Number.isInteger(index)||index<0||index>89||!Number.isSafeInteger(ms)||ms<0||ms>86400000)continue;
    const candidates=events.filter(event=>event.details?.storedFileId===file.file_id&&
      event.details.frameIndex===index&&event.details.frameTimestampMs===ms&&event.details.scanPreviewId);
    const priority=event=>['blocked','uncertain','failed','stopped'].includes(event.details.checkOutcome)?1:0;
    candidates.sort((a,b)=>priority(b)-priority(a)||(BigInt(a.id)>BigInt(b.id)?-1:1));
    const preview=candidates.length?presentAuditCheck(candidates[0]):null;
    items.push({name:`${name} · תמונה ${index+1} · שנייה ${ms/1000}`,
      key:UUID.test(file.file_id||'')?`${file.file_id.toLowerCase()}:frame:${index}:${ms}`:null,
      reason:typeof frame.reason==='string'?frame.reason.slice(0,500):(blocked?'התמונה נחסמה':'בדיקת התמונה לא הושלמה'),
      preview:preview?.checkPreviewUrl?preview:null});
  }
  if(!items.length)items.push({name,preview:null,reason:missing});
  return items;
}

async function attachStoppedScanEvidence(db,rows,mode){
  const visibleRows=rows.filter(row=>row.dispatch?.object_status!=='blocked_for_recipient');
  for(const row of rows)row.stoppedEvidence=null;
  const ids=[...new Set(visibleRows.map(row=>mode==='events'?row.operation_id:row.id).filter(id=>UUID.test(id||'')))];
  if(!ids.length)return;
  const result=await db.query(`SELECT o.id AS operation_id,o.status AS operation_status,stop.kind AS decision_kind,stop.id::text AS stop_id,
      COALESCE((SELECT max(start.id) FROM audit_events start WHERE start.operation_id=o.id
        AND start.kind='scan_attempt_started' AND start.id<stop.id),0)::text AS start_id,
      sf.id AS file_id,sf.original_name,sf.file_type,sf.moderation_status,
      NOT EXISTS(SELECT 1 FROM audit_events newer WHERE newer.id>stop.id
        AND newer.kind IN ('scan_workflow_finished','media_moderation_changed') AND newer.target_type='file' AND newer.target_id=sf.id
        AND NOT (stop.kind='decision_blocked' AND newer.operation_id=o.id AND newer.kind='media_moderation_changed' AND newer.status='completed'))
      AND NOT EXISTS(SELECT 1 FROM audit_events restart WHERE restart.operation_id=o.id
        AND restart.kind='scan_attempt_started' AND restart.id>stop.id) AS current_result,
      (SELECT jsonb_agg(jsonb_build_object('index',f.ordinality-1,'pending',f.value->'pending',
        'blocked',f.value->'blocked','scanStopped',f.value->'scanStopped','timestampSeconds',f.value->'timestampSeconds',
        'reason',left(f.value->>'reason',500)))
        FROM jsonb_array_elements(CASE WHEN jsonb_typeof(sf.moderation_details->'frameResults')='array'
          THEN sf.moderation_details->'frameResults' ELSE '[]'::jsonb END) WITH ORDINALITY f(value,ordinality)
        WHERE f.ordinality<=90) AS frames
    FROM audit_operations o
    LEFT JOIN LATERAL (${problemFileEventSql()}) stop ON true
    LEFT JOIN stored_files sf ON sf.id=stop.target_id
    WHERE o.id=ANY($1::uuid[]) AND (o.status='blocked' OR (o.status='failed' AND o.status_source='scan_workflow_finished'))`,[ids]);
  const evidence=new Map(),valid=[];
  for(const file of result.rows){
    evidence.set(file.operation_id,{items:[],message:file.operation_status==='blocked'?'לא תועדה תמונה מסוימת שגרמה לחסימה':'לא תועדה תמונה מסוימת שגרמה לעצירה'});
    const matches=file.operation_status==='blocked'
      ?file.moderation_status==='rejected'||(file.decision_kind==='decision_blocked'&&file.moderation_status==='approved')
      :file.moderation_status==='stopped';
    if(file.file_id&&file.current_result&&matches)valid.push(file);
    else if(file.original_name)evidence.get(file.operation_id).items.push({name:file.original_name,preview:null,
      reason:'אין תיעוד ודאי של התמונה עבור החלטה זו'});
  }
  if(valid.length){
    const checks=await db.query(`SELECT e.id::text,e.operation_id,e.kind,e.status,e.details
      FROM unnest($1::uuid[],$2::bigint[],$3::bigint[],$4::text[]) AS stops(operation_id,start_id,stop_id,file_id)
      JOIN audit_events e ON e.operation_id=stops.operation_id AND e.id>stops.start_id AND e.id<stops.stop_id
        AND e.details->>'storedFileId'=stops.file_id
      WHERE e.details ? 'scanPreviewId'`,[valid.map(f=>f.operation_id),valid.map(f=>f.start_id),valid.map(f=>f.stop_id),valid.map(f=>f.file_id)]);
    for(const file of valid)evidence.set(file.operation_id,{items:stoppedItems(file,checks.rows.filter(e=>e.operation_id===file.operation_id))});
  }
  for(const row of visibleRows)row.stoppedEvidence=evidence.get(mode==='events'?row.operation_id:row.id)||null;
}
module.exports={stoppedItems,attachStoppedScanEvidence};
