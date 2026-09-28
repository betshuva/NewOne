"use strict";
const {decryptMessageText}=require('./message-at-rest');
const SEND_LABELS={sent:'נשלח — נשמר בשרת',partial:'נשלח לחלק מהנמענים',blocked:'נחסם',failed:'נכשל',pending:'ממתין',not_sent:'לא נשלח',unknown:'לא ידוע',not_applicable:'לא רלוונטי'};
const DELIVERY_LABELS={read:'דווח שנקרא',server_delivered:'השרת סימן מסירה — אין אישור מהמכשיר',unconfirmed:'אין אישור מסירה מהמכשיר',not_sent:'לא נשלח',not_applicable:'לא רלוונטי'};
const TYPE_LABELS={text:'טקסט',image:'תמונה',video:'וידאו',audio:'הקלטה / קובץ קול',document:'קובץ',sticker:'מדבקה'};
const OBJECT_STATUS_LABELS={sent:'נשלח',blocked:'נחסם',blocked_for_recipient:'נחסם למשתמש',partial:'נשלח לחלק מהנמענים — נחסם לאחרים',pending:'ממתין',stopped:'הסריקה נעצרה — לא נשלח',failed:'לא נשלח — תקלה',not_sent:'לא נשלח',unknown:'טרם תועדה תוצאה',not_applicable:'לא רלוונטי'};
const DISPATCH_FIELDS={dispatch_state:'text',dispatch_reason:'text',dispatch_code:'text',dispatch_delivery:'text',dispatch_sent_count:'number',dispatch_failed_count:'number',dispatch_message_type:'text',dispatch_file_name:'text',dispatch_content:'text',dispatch_message_id:'text'};
DISPATCH_FIELDS.object_status='text';
const DISPATCH_SQL=String.raw`
CREATE OR REPLACE FUNCTION system_audit_dispatch(op_id uuid) RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE op audit_operations; ev jsonb; msg jsonb; file_row jsonb; pending_row jsonb; request_row jsonb; evidence jsonb;
  rid uuid; rtype text; rname text; rshort text; state text:='unknown'; delivery text:='unconfirmed';
  reason text; reason_code text; object_state text; msg_type text; sent_count int; failed_count int; count_messages int:=0;
  summary jsonb; content_context jsonb; messages_json jsonb:='[]'; ids uuid[]; sending boolean; has_persisted boolean; is_broadcast boolean;
BEGIN
 SELECT * INTO op FROM audit_operations WHERE id=op_id;
 SELECT COALESCE(jsonb_agg(to_jsonb(e) ORDER BY e.id),'[]'::jsonb) INTO ev FROM audit_events e WHERE e.operation_id=op_id;
 is_broadcast:=op.action='send_system_message' OR EXISTS(SELECT 1 FROM jsonb_array_elements(ev) e WHERE e->>'kind'='send_system_message' OR e->'details'->>'httpRoute'='/api/admin/system-message');
 sending:=is_broadcast OR op.action IN('send_message','send_group_message','send_file','send_file_delayed','send_group_file_delayed','upload_file','blocked_upload','blocked_upload_delayed','group_file_delivery_rejected');
 IF NOT sending THEN RETURN jsonb_build_object('dispatch_state','not_applicable','dispatch_delivery','not_applicable','object_status','not_applicable'); END IF;
 rid:=op.recipient_id;rtype:=op.recipient_type;rname:=op.recipient_name;rshort:=op.recipient_short_id;
 IF rid IS NULL AND op.action IN('send_message','send_group_message') AND op.target_type IN('user','group') THEN rid:=op.target_id;rtype:=op.target_type; END IF;
 IF rid IS NULL THEN
   SELECT e->'details' INTO evidence FROM jsonb_array_elements(ev) e WHERE e->>'kind' IN('operation_started','dispatch_context','upload_context') ORDER BY (e->>'id')::bigint LIMIT 1;
   IF evidence->>'recipientId' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' AND evidence->>'recipientType' IN('user','group') THEN rid:=(evidence->>'recipientId')::uuid;rtype:=evidence->>'recipientType';END IF;
 END IF;
 SELECT e->'details' INTO content_context FROM jsonb_array_elements(ev) e WHERE e->>'kind' IN('operation_started','dispatch_context') AND (e->'details' ? 'dispatchBody' OR e->'details' ? 'dispatchFileName') ORDER BY (e->>'id')::bigint LIMIT 1;
 SELECT array_agg(DISTINCT COALESCE(e->>'target_id',e->'details'->>'messageId')::uuid) INTO ids FROM jsonb_array_elements(ev) e
 WHERE (e->>'target_type'='message' OR e->'details'->>'messageId' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') AND e->>'kind' IN('message_persisted','message_retry_reused','message_request_accepted','send_message','send_group_message','send_file');
 has_persisted:=EXISTS(SELECT 1 FROM jsonb_array_elements(ev) e WHERE e->>'kind' IN('message_persisted','message_retry_reused'));
 SELECT COALESCE(jsonb_agg(to_jsonb(m) ORDER BY m.created_at,m.id),'[]'::jsonb) INTO messages_json FROM messages m
 WHERE m.id=ANY(ids) AND NOT COALESCE(m.delivery_summary ? 'guideFilterNotice',false)
 AND (is_broadcast OR op.initiator_id IS NULL OR m.sender_id=op.initiator_id);
 count_messages:=jsonb_array_length(messages_json);msg:=messages_json->0;
 IF is_broadcast THEN SELECT jsonb_build_object('deliveredTo',COALESCE(jsonb_agg(jsonb_build_object('id',m->>'recipient_id','name',u.name)),'[]'::jsonb),'blockedFor','[]'::jsonb) INTO summary FROM jsonb_array_elements(messages_json) m LEFT JOIN users u ON u.id=(m->>'recipient_id')::uuid;END IF;
 -- Uploads and their later send request may be separate operations. Match the exact stored file, sender and explicit destination.
 SELECT to_jsonb(f) INTO file_row FROM stored_files f JOIN audit_events e ON e.operation_id=op_id
   AND (e.target_type IN('file','stored_file') AND e.target_id=f.id OR e.details->>'storedFileId'=f.id::text)
 ORDER BY e.id LIMIT 1;
 IF count_messages=0 AND file_row IS NOT NULL AND rid IS NOT NULL THEN
   SELECT COALESCE(jsonb_agg(to_jsonb(m) ORDER BY m.created_at,m.id),'[]'::jsonb) INTO messages_json FROM messages m
   WHERE m.file_url=file_row->>'public_url' AND m.sender_id=op.initiator_id
     AND ((rtype='user' AND m.recipient_id=rid) OR (rtype='group' AND m.group_id=rid))
     AND m.created_at>=op.created_at AND NOT COALESCE(m.delivery_summary ? 'guideFilterNotice',false);
   count_messages:=jsonb_array_length(messages_json);msg:=messages_json->0;
 END IF;
 IF rid IS NULL AND NOT is_broadcast AND msg IS NOT NULL THEN
   rid:=COALESCE((msg->>'group_id')::uuid,(msg->>'recipient_id')::uuid);rtype:=CASE WHEN msg->>'group_id' IS NOT NULL THEN 'group' ELSE 'user' END;
 END IF;
 IF rid IS NOT NULL AND rname IS NULL THEN
   IF rtype='group' THEN SELECT g.name,to_jsonb(g)->>'short_id' INTO rname,rshort FROM groups g WHERE g.id=rid;
   ELSE SELECT u.name,to_jsonb(u)->>'short_id' INTO rname,rshort FROM users u WHERE u.id=rid;END IF;
 END IF;
 SELECT to_jsonb(p) INTO pending_row FROM pending_scans p WHERE to_jsonb(p)->>'audit_operation_id'=op_id::text ORDER BY p.id DESC LIMIT 1;
 SELECT to_jsonb(r) INTO request_row FROM message_requests r
 WHERE r.audit_operation_id=op_id OR (file_row IS NOT NULL AND r.file_url=file_row->>'public_url'
   AND r.sender_id=op.initiator_id AND r.recipient_id=rid)
 ORDER BY r.created_at DESC LIMIT 1;
 SELECT e INTO evidence FROM jsonb_array_elements(ev) e WHERE e->>'kind' IN('dispatch_outcome','http_response','scan_workflow_finished','decision_blocked','delivery_blocked_persisted','group_file_delivery_rejected','blocked_upload','blocked_upload_delayed','contact_request_pending','socket_handler_failed')
 AND (e->>'status' IN('failed','blocked','pending','cancelled') OR e->'details' ? 'dispatchReason')
 ORDER BY (e->>'id')::bigint DESC LIMIT 1;
 reason:=NULLIF(evidence->'details'->>'dispatchReason','');reason_code:=COALESCE(evidence->>'reason_code',evidence->'details'->>'reasonCode');
 IF reason IS NULL AND (file_row->>'moderation_status' IN('rejected','stopped') OR file_row->'moderation_details'->>'destinationFilterRejected'='true') THEN
   reason:=COALESCE(file_row->'moderation_details'->>'reason',file_row->'moderation_details'->>'error');
   reason_code:=COALESCE(file_row->'moderation_details'->>'reasonCode',file_row->'moderation_details'->>'blockedBy',reason_code);
 END IF;
 -- Older uploads returned only HTTP 200 for a destination-filter refusal.
 -- Classify that result from the approved file and the recorded policy decision.
 IF file_row->>'moderation_status'='approved' AND file_row->'moderation_details'->>'blocked' IS DISTINCT FROM 'true'
   AND (file_row->'moderation_details'->>'destinationFilterRejected'='true' OR file_row->'moderation_details'->>'senderFilterRejected'='true')
   AND EXISTS(SELECT 1 FROM jsonb_array_elements(ev) e WHERE e->>'kind'='decision_blocked'
     AND e->>'reason_code' IN('content_filter','sender_content_filter','recipient_content_filter')) THEN
   reason_code:='content_filter';
 END IF;
 IF count_messages>0 THEN
   state:='sent';sent_count:=count_messages;failed_count:=0;
   IF rtype='group' THEN
     summary:=msg->'delivery_summary';sent_count:=NULL;failed_count:=NULL;
     IF jsonb_typeof(summary->'deliveredTo')='array' AND jsonb_typeof(summary->'blockedFor')='array' THEN
       sent_count:=jsonb_array_length(summary->'deliveredTo');failed_count:=jsonb_array_length(summary->'blockedFor');
       IF failed_count>0 THEN state:=CASE WHEN sent_count>0 THEN 'partial' ELSE 'blocked' END;SELECT string_agg(DISTINCT x->>'reason','; ') INTO reason FROM jsonb_array_elements(summary->'blockedFor') x;reason:=COALESCE(reason,'נמענים נחסמו לפי סינון; ההגדרה המדויקת לא תועדה');reason_code:='recipient_content_filter';
       ELSIF sent_count=0 THEN state:='not_sent';reason:='אין נמענים בקבוצה מלבד השולח';reason_code:='no_recipients';END IF;
     ELSE state:='unknown';reason:='ההודעה נשמרה, אך לא תועדה חלוקת השליחה לחברי הקבוצה';reason_code:='group_distribution_unknown';END IF;
   ELSE
     IF EXISTS(SELECT 1 FROM message_status ms WHERE ms.message_id=(msg->>'id')::uuid AND ms.user_id=rid AND ms.status='read') THEN delivery:='read';
     ELSIF EXISTS(SELECT 1 FROM message_status ms WHERE ms.message_id=(msg->>'id')::uuid AND ms.user_id=rid AND ms.status='delivered') THEN delivery:='server_delivered';END IF;
   END IF;
   IF state='sent' THEN reason:=NULL;reason_code:=NULL;END IF;
 ELSIF request_row->>'status'='rejected' THEN
   state:='blocked';reason:=request_row->>'rejection_reason';reason_code:=request_row->>'rejection_code';
 ELSIF request_row->>'status'='pending' THEN
   state:='pending';reason:='ממתין לאישור חברות ולבחירת סוגי התוכן שהנמען מתיר';reason_code:='contact_approval_required';
 ELSIF has_persisted THEN state:='unknown';
 ELSIF pending_row IS NOT NULL OR evidence->>'kind'='contact_request_pending' OR op.status IN('pending','queued','running','accepted') THEN
   state:='pending';reason:=COALESCE(reason,CASE WHEN pending_row IS NOT NULL THEN 'ממתין להשלמת סריקת המדיה' WHEN evidence->>'kind'='contact_request_pending' THEN 'ממתין לאישור בקשת קשר' ELSE 'הפעולה עדיין ממתינה; טרם תועדה שליחה' END);reason_code:=COALESCE(reason_code,'awaiting_processing');
 ELSIF evidence->>'status'='blocked' OR op.status IN('blocked','rejected') OR file_row->>'moderation_status'='rejected' THEN state:='blocked';
 ELSIF evidence->>'status'='failed' OR op.status IN('failed','cancelled') OR file_row->>'moderation_status'='stopped' THEN state:='failed';
 ELSE state:='unknown';END IF;
 IF count_messages=0 THEN
   delivery:='not_sent';
   IF state='unknown' THEN delivery:='unconfirmed';reason:=COALESCE(reason,CASE WHEN has_persisted THEN 'תועדה שמירת הודעה, אך ההודעה המקושרת אינה זמינה' ELSE 'לא תועדה שליחת הודעה; השלמת הפעולה לבדה אינה אישור שליחה' END);reason_code:=COALESCE(reason_code,CASE WHEN has_persisted THEN 'message_unavailable' ELSE 'send_not_recorded' END);
   ELSE sent_count:=0;IF rtype='user' AND state IN('failed','blocked') THEN failed_count:=1;END IF;END IF;
 END IF;
 IF state IN('blocked','failed','not_sent') THEN delivery:='not_sent';reason:=COALESCE(reason,'הסיבה המפורטת לא תועדה');reason_code:=COALESCE(reason_code,op.reason_code);END IF;
 -- A per-recipient policy refusal is different from global media rejection.
 -- Keep real sends, partial group delivery, pending scans and technical stops distinct.
 object_state:=state;
 IF state='blocked' AND file_row->>'moderation_status' IS DISTINCT FROM 'rejected' AND
   (file_row->'moderation_details'->>'destinationFilterRejected'='true'
    OR reason_code IN('recipient_content_filter','destination_content_filtered','group_content_filter',
      'contact_or_group_access','contact_request_declined','recipient_blocked_sender','teen_mutual_contact_required')) THEN
   object_state:='blocked_for_recipient';
 ELSIF state='failed' AND (file_row->>'moderation_status'='stopped'
   OR reason_code IN('scan_stopped','scan_incomplete','budget_exhausted','deadline_exceeded','required_provider_unavailable')) THEN
   object_state:='stopped';
 END IF;
 msg_type:=COALESCE(msg->>'type',op.media_type,file_row->>'file_type',pending_row->>'file_type',request_row->>'type',content_context->>'messageType');
 RETURN jsonb_build_object('object_status',object_state,'dispatch_state',state,'dispatch_reason',left(reason,500),'dispatch_code',reason_code,
 'dispatch_delivery',delivery,'dispatch_sent_count',sent_count,'dispatch_failed_count',failed_count,
 'dispatch_message_type',msg_type,'dispatch_message_id',msg->>'id','message_body',COALESCE(msg->>'body',request_row->>'body',content_context->>'dispatchBody'),
 'dispatch_file_name',COALESCE(msg->>'file_name',file_row->>'original_name',pending_row->>'file_name',request_row->>'file_name',content_context->>'dispatchFileName'),
 'recipient_id',rid,'recipient_type',rtype,'recipient_name',CASE WHEN is_broadcast THEN 'מספר נמענים — הודעת מערכת' ELSE rname END,'recipient_short_id',rshort,
 'recipients',CASE WHEN rtype='group' OR is_broadcast THEN summary ELSE NULL END);
END $$;
`;
function enabled(filters){return filters.dispatch||Object.keys(filters.columnFilters||{}).some(k=>k in DISPATCH_FIELDS||k==='stopped_file')||filters.sort in DISPATCH_FIELDS||filters.sort==='stopped_file';}
function wrapQuery(query,filters){
 if(!enabled(filters))return query;
 const text=query.text.replaceAll('audit_operations o','dispatch_operations o').replace('e.*,','e.*,o.dispatch,');
 return {...query,text:`WITH dispatch_evidence AS MATERIALIZED (SELECT b.*,system_audit_dispatch(b.id) AS dispatch FROM audit_operations b),
 dispatch_operations AS MATERIALIZED (SELECT p.*,d.dispatch FROM dispatch_evidence d CROSS JOIN LATERAL jsonb_populate_record(NULL::audit_operations,
 to_jsonb(d)||jsonb_strip_nulls(jsonb_build_object('recipient_id',d.dispatch->'recipient_id','recipient_type',d.dispatch->'recipient_type','recipient_name',d.dispatch->'recipient_name','recipient_short_id',d.dispatch->'recipient_short_id'))) p) ${text}`};
}
function contentPreview(value){return typeof value==='string'?value.slice(0,160):null;}
function presentDispatch(row){
 if(!row.dispatch)return row;
 const dispatch={...row.dispatch};
 try{dispatch.dispatch_file_name=decryptMessageText(dispatch.dispatch_file_name);dispatch.message_body=decryptMessageText(dispatch.message_body);if(dispatch.dispatch_message_type!=='text'&&dispatch.message_body===dispatch.dispatch_file_name)dispatch.message_body=null;dispatch.dispatch_content=contentPreview(dispatch.message_body);}catch{dispatch.message_body=null;dispatch.dispatch_content='לא ניתן לקרוא את תוכן ההודעה';}
 row.dispatch=dispatch;return row;
}
async function prepareQuery(db,query){
 const fields=['dispatch_content','dispatch_file_name'].filter(field=>query.text.includes(`o.dispatch->>'${field}'`));if(!fields.length)return query;
 // Plaintext exists only in this authorized request. Never persist it or compare ciphertext as human text.
 const result=await db.query(`SELECT id,system_audit_dispatch(id) AS dispatch FROM audit_operations`),values=[...query.values];let text=query.text;
 for(const field of fields){const content={};for(const row of result.rows){try{let raw=decryptMessageText(row.dispatch[field==='dispatch_content'?'message_body':field]);if(field==='dispatch_content'&&row.dispatch.dispatch_message_type!=='text'&&raw===decryptMessageText(row.dispatch.dispatch_file_name))raw=null;content[row.id]=field==='dispatch_content'?contentPreview(raw):raw;}catch{content[row.id]='לא ניתן לקרוא את התוכן';}}
 values.push(JSON.stringify(content));text=text.replaceAll(`o.dispatch->>'${field}'`,`($${values.length}::jsonb->>o.id::text)`);}
 return {values,text};
}
module.exports={DISPATCH_SQL,DISPATCH_FIELDS,SEND_LABELS,DELIVERY_LABELS,TYPE_LABELS,OBJECT_STATUS_LABELS,enabled,wrapQuery,presentDispatch,prepareQuery,contentPreview};
