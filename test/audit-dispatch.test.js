"use strict";
const test=require('node:test'),assert=require('node:assert/strict'),{randomUUID}=require('node:crypto'),{Client}=require('pg');
const {ensureSystemAuditSchema,beginOperation,recordAuditEvent,registerSystemAuditRoutes,readFilters,buildQuery,buildFilterOptionsQuery}=require('../server/system-audit');
const {prepareQuery,presentDispatch,DISPATCH_FIELDS}=require('../server/audit-dispatch');
const {dispatchDetails}=require('../server/system-audit-context');
process.env.MESSAGE_ENCRYPTION_KEY='disposable-audit-dispatch-test-key-0123456789';
async function fixture(t){
 const url=new URL(process.env.DATABASE_URL);assert.match(url.pathname,/test/);const db=new Client({connectionString:url.href,ssl:false});await db.connect();const schema='dispatch_'+randomUUID().replaceAll('-','');await db.query(`CREATE SCHEMA "${schema}";SET search_path TO "${schema}";CREATE TABLE users(id uuid PRIMARY KEY,name text,short_id integer);`);t.after(async()=>{await db.query(`DROP SCHEMA "${schema}" CASCADE`);await db.end();});
 await db.query(require('./helpers/audit-dispatch-schema'));await ensureSystemAuditSchema(db);
 const sender=randomUUID(),recipient=randomUUID(),group=randomUUID();await db.query('INSERT INTO users VALUES($1,$2,10),($3,$4,5)',[sender,'שולח',recipient,'נמענת']);await db.query('INSERT INTO groups VALUES($1,$2)',[group,'קבוצת בדיקה']);
 const start=(extra={})=>beginOperation(db,{action:'send_message',source:'http',initiatorId:sender,targetType:'user',targetId:recipient,...extra});
 const event=(op,data)=>recordAuditEvent(db,{operationId:op.id,parentEventId:op.root_event_id,...data});
 const message=async(op,extra={})=>{const m={id:randomUUID(),sender_id:sender,recipient_id:recipient,type:'text',body:'שלום',audit_operation_id:op.id,...extra};const keys=Object.keys(m);await db.query(`INSERT INTO messages(${keys.join(',')}) VALUES(${keys.map((_,i)=>'$'+(i+1)).join(',')})`,Object.values(m));return m;};
 const projection=async op=>presentDispatch({dispatch:(await db.query('SELECT system_audit_dispatch($1) AS value',[op.id])).rows[0].value}).dispatch;
 return {db,sender,recipient,group,start,event,message,projection};
}
const opts={skip:process.env.RUN_DB_TESTS!=='1'};
test('HTTP success, scan completion and push acceptance cannot prove a send',opts,async t=>{
 const f=await fixture(t),op=await f.start();await f.event(op,{kind:'http_response',status:'completed',operationStatus:'completed',reasonCode:'http_200'});await f.event(op,{kind:'push_provider_result',status:'completed',details:{acceptedCount:1}});assert.equal((await f.projection(op)).dispatch_state,'unknown');assert.equal((await f.projection(op)).recipient_name,'נמענת');
 const admin=await f.start({action:'admin_action'});assert.equal((await f.projection(admin)).dispatch_state,'not_applicable');
});
test('encrypted attempted text and exact denial are readable only through presentation',opts,async t=>{
 const f=await fixture(t),details=dispatchDetails({toUserId:f.recipient,text:'<script>הודעה לבדיקה</script>'});assert.ok(details.dispatchBody.startsWith('enc:v1:'));const op=await f.start({details});await f.event(op,{kind:'http_response',status:'blocked',operationStatus:'blocked',reasonCode:'chat_content_blocked',details:{dispatchReason:'ההודעה נחסמה משום שהיא כוללת תוכן פוגעני או אסור'}});
 const d=await f.projection(op);assert.equal(d.dispatch_state,'blocked');assert.equal(d.dispatch_sent_count,0);assert.equal(d.dispatch_failed_count,1);assert.equal(d.dispatch_content,'<script>הודעה לבדיקה</script>');assert.equal(d.dispatch_reason,'ההודעה נחסמה משום שהיא כוללת תוכן פוגעני או אסור');
 const raw=(await f.db.query('SELECT details FROM audit_events WHERE operation_id=$1',[op.id])).rows;assert.ok(!JSON.stringify(raw).includes('<script>'));
});
test('message persistence is distinct from server status and explicit read report; retry resolves the same message',opts,async t=>{
 const f=await fixture(t),op=await f.start(),msg=await f.message(op);let d=await f.projection(op);assert.equal(d.dispatch_state,'sent');assert.equal(d.dispatch_delivery,'unconfirmed');assert.equal(d.dispatch_content,'שלום');
 await f.db.query('INSERT INTO message_status VALUES($1,$2,$3)',[msg.id,f.recipient,'delivered']);assert.equal((await f.projection(op)).dispatch_delivery,'server_delivered');await f.db.query('UPDATE message_status SET status=$1 WHERE message_id=$2',['read',msg.id]);assert.equal((await f.projection(op)).dispatch_delivery,'read');
 const retry=await f.start();await f.event(retry,{kind:'message_retry_reused',status:'completed',details:{messageId:msg.id}});assert.equal((await f.projection(retry)).dispatch_state,'sent');
});
test('group partial, all blocked, no recipients and missing distribution remain distinct',opts,async t=>{
 const f=await fixture(t);for(const [summary,state,sent,failed]of [[{deliveredTo:[{id:f.recipient,name:'נמענת'}],blockedFor:[{id:randomUUID(),name:'חסום',reason:'סרטונים חסומים'}]},'partial',1,1],[{deliveredTo:[],blockedFor:[{id:f.recipient}]},'blocked',0,1],[{deliveredTo:[],blockedFor:[]},'not_sent',0,0],[null,'unknown',null,null]]){
 const op=await f.start({action:'send_group_message',targetType:'group',targetId:f.group});await f.message(op,{recipient_id:null,group_id:f.group,delivery_summary:summary});const d=await f.projection(op);assert.equal(d.recipient_name,'קבוצת בדיקה');assert.equal(d.dispatch_state,state);assert.equal(d.dispatch_sent_count,sent);assert.equal(d.dispatch_failed_count,failed);assert.notEqual(d.dispatch_delivery,'read');}
});
test('media queued, stopped and separate explicit file send are resolved without borrowing another recipient',opts,async t=>{
 const f=await fixture(t),op=await f.start({action:'upload_file',targetType:null,targetId:null});await f.event(op,{kind:'upload_context',details:{mediaType:'video',recipientType:'user',recipientId:f.recipient}});
 const id=randomUUID();await f.db.query('INSERT INTO stored_files(id,public_url,file_type,original_name,moderation_status,audit_operation_id) VALUES($1,$2,$3,$4,$5,$6)',[id,'private-test-file','video','צילום.webm','pending',op.id]);await f.db.query('INSERT INTO pending_scans(file_type,audit_operation_id) VALUES($1,$2)',['video',op.id]);assert.equal((await f.projection(op)).dispatch_state,'pending');
 await f.db.query('DELETE FROM pending_scans WHERE audit_operation_id=$1',[op.id]);await f.db.query('UPDATE stored_files SET moderation_status=$1,moderation_details=$2 WHERE id=$3',['stopped',{reasonCode:'budget_exhausted',reason:'מכסת 36 הבדיקות מוצתה'},id]);let d=await f.projection(op);assert.equal(d.dispatch_state,'failed');assert.equal(d.dispatch_reason,'מכסת 36 הבדיקות מוצתה');
 const send=await f.start();await f.message(send,{file_url:'private-test-file',type:'video',recipient_id:randomUUID()});assert.notEqual((await f.projection(op)).dispatch_state,'sent');await f.message(send,{file_url:'private-test-file',type:'video',file_name:'צילום.webm'});assert.equal((await f.projection(op)).dispatch_state,'sent');
});
test('all dispatch columns filter, facet and sort in both modes, including decrypted text and recipient lookup',opts,async t=>{
 const f=await fixture(t),a=await f.start({details:dispatchDetails({text:'אחד',toUserId:f.recipient})}),b=await f.start({details:dispatchDetails({text:'שתיים',toUserId:f.recipient})});await f.event(a,{kind:'http_response',status:'blocked',operationStatus:'blocked',details:{dispatchReason:'סיבת דחייה'}});await f.message(b,{body:'שתיים'});
 for(const mode of ['operations','events'])for(const [column,type]of Object.entries(DISPATCH_FIELDS)){
  const filters=readFilters({dispatch:'1',sort:column,direction:'asc'},{mode});assert.ok((await f.db.query(await prepareQuery(f.db,buildQuery(filters)))).rows.length);
  if(type==='text')assert.ok((await f.db.query(await prepareQuery(f.db,buildFilterOptionsQuery(filters,column)))).rows.length);
 }
 const filtered=readFilters({dispatch:'1',columnFilters:JSON.stringify({dispatch_content:{values:['אחד']}})});assert.deepEqual((await f.db.query(await prepareQuery(f.db,buildQuery(filtered)))).rows.map(r=>r.id),[a.id]);
 const recipientQuery=buildFilterOptionsQuery(readFilters({dispatch:'1'}),'recipient_id');assert.match(JSON.stringify((await f.db.query(recipientQuery)).rows),/נמענת/);
});

test('broadcast recipients, missing historical messages and sorted event projection stay explicit',opts,async t=>{
 const f=await fixture(t),op=await f.start({action:'send_system_message',targetType:null,targetId:null});await f.message(op);await f.message(op,{recipient_id:f.sender});let d=await f.projection(op);assert.equal(d.dispatch_state,'sent');assert.equal(d.dispatch_sent_count,2);assert.equal(d.recipients.deliveredTo.length,2);
 const q=await prepareQuery(f.db,buildQuery(readFilters({dispatch:'1',sort:'dispatch_state',direction:'asc'},{mode:'events'})));const events=(await f.db.query(q)).rows;assert.ok(events.length);assert.ok(events.every(row=>row.dispatch?.dispatch_state==='sent'));
 const missing=await f.start();await f.event(missing,{kind:'message_persisted',targetType:'message',targetId:randomUUID()});d=await f.projection(missing);assert.equal(d.dispatch_state,'unknown');assert.equal(d.dispatch_code,'message_unavailable');
});

test('authenticated route uses decrypted preview facets and preserves paging for both views',opts,async t=>{
 const f=await fixture(t),op=await f.start({details:dispatchDetails({toUserId:f.recipient,text:'הודעה מוצפנת'})});await f.event(op,{kind:'http_response',status:'blocked',operationStatus:'blocked'});
 const routes={};registerSystemAuditRoutes({get:(path,...handlers)=>routes[path]=handlers.at(-1),delete(){}},{getPool:async()=>f.db,adminMiddleware(){}});
 const call=async(path,query)=>{const res={set(){},status(code){this.code=code;return this;},json(body){this.body=body;return this;}};await routes[path]({query,user:{id:f.sender}},res);assert.equal(res.code,undefined);return res.body;};
 const options=await call('/api/admin/audit/filter-options',{dispatch:'1',column:'dispatch_content',search:'מוצפנת'});assert.equal(options.options[0].value,'הודעה מוצפנת');
 for(const mode of ['operations','events']){const response=await call('/api/admin/audit/'+mode,{dispatch:'1',sort:'dispatch_content',direction:'asc',limit:'1',...(mode==='operations'?{steps:'1'}:{})});assert.equal(response[mode][0].dispatch.dispatch_content,'הודעה מוצפנת');}
});

test('approved media can fail recipient access; detailed destination reason wins over generic scan terminal',opts,async t=>{
 const f=await fixture(t),op=await f.start({action:'upload_file',targetType:null,targetId:null});await f.event(op,{kind:'upload_context',details:{mediaType:'video',recipientType:'user',recipientId:f.recipient}});
 const id=randomUUID();await f.db.query('INSERT INTO stored_files(id,public_url,file_type,moderation_status,moderation_details,audit_operation_id) VALUES($1,$2,$3,$4,$5,$6)',[id,'specific-destination-file','video','approved',{destinationFilterRejected:true,reason:'הנמען עדיין לא אישר אותך כחבר',reasonCode:'contact_or_group_access'},op.id]);
 await f.event(op,{kind:'decision_blocked',status:'blocked',reasonCode:'contact_or_group_access'});await f.event(op,{kind:'scan_workflow_finished',status:'blocked',operationStatus:'blocked',reasonCode:'media_not_allowed'});const d=await f.projection(op);assert.equal(d.dispatch_state,'blocked');assert.equal(d.dispatch_reason,'הנמען עדיין לא אישר אותך כחבר');assert.equal(d.dispatch_code,'contact_or_group_access');
});


test('contact requests keep an accurate waiting, blocked or accepted dispatch after later HTTP events',opts,async t=>{
 const f=await fixture(t),op=await f.start(),requestId=randomUUID();
 await f.db.query(`INSERT INTO message_requests(id,sender_id,recipient_id,type,body,status,audit_operation_id)
 VALUES($1,$2,$3,'text',$4,'pending',$5)`,[requestId,f.sender,f.recipient,'ממתין לאישור',op.id]);
 await f.event(op,{kind:'http_response',status:'completed',operationStatus:'completed'});
 let d=await f.projection(op);assert.equal(d.dispatch_state,'pending');assert.equal(d.dispatch_code,'contact_approval_required');assert.equal(d.dispatch_content,'ממתין לאישור');
 await f.db.query(`UPDATE message_requests SET status='rejected',rejection_reason=$1,rejection_code=$2 WHERE id=$3`,['הנמען דחה את בקשת החברות','contact_request_declined',requestId]);
 d=await f.projection(op);assert.equal(d.dispatch_state,'blocked');assert.equal(d.dispatch_reason,'הנמען דחה את בקשת החברות');assert.equal(d.dispatch_sent_count,0);
 const accepted=await f.start(),msg=await f.message(accepted);await f.event(op,{kind:'message_request_accepted',status:'completed',operationStatus:'completed',targetType:'message',targetId:msg.id,details:{messageId:msg.id}});
 await f.db.query('DELETE FROM message_requests WHERE id=$1',[requestId]);
 d=await f.projection(op);assert.equal(d.dispatch_state,'sent');assert.equal(d.dispatch_message_id,msg.id);
});

test('client size rejection appears in the upload audit without a stored file or message',opts,async t=>{
 const f=await fixture(t),op=await f.start({action:'upload_file',targetType:null,targetId:null});
 const reason='דווח מהדפדפן: הקובץ גדול מדי; נדחה לפני שליחת הקובץ';
 await f.event(op,{kind:'dispatch_context',source:'client_upload_validation',executorType:'client',executorId:f.sender,
  status:'blocked',operationStatus:'blocked',reasonCode:'client_file_too_large',details:{
   ...dispatchDetails({fileName:'הקלטה גדולה.mp3',fileType:'audio'}),mediaType:'audio',fileSize:157286401,
   maxBytes:157286400,clientReported:true,dispatchReason:reason}});
 await f.event(op,{kind:'http_response',status:'blocked',operationStatus:'blocked',reasonCode:'client_file_too_large',details:{dispatchReason:reason}});
 const operation=(await f.db.query('SELECT * FROM audit_operations WHERE id=$1',[op.id])).rows[0];
 assert.equal(operation.action,'upload_file');assert.equal(operation.media_type,'audio');assert.equal(operation.status,'blocked');
 const d=await f.projection(op);assert.equal(d.dispatch_file_name,'הקלטה גדולה.mp3');assert.equal(d.dispatch_state,'blocked');
 assert.equal(d.dispatch_delivery,'not_sent');assert.equal(d.dispatch_sent_count,0);assert.equal(d.dispatch_reason,reason);
 assert.equal(d.dispatch_code,'client_file_too_large');
 const evidence=(await f.db.query("SELECT details FROM audit_events WHERE operation_id=$1 AND kind='dispatch_context'",[op.id])).rows[0].details;
 assert.equal(evidence.fileSize,157286401);assert.equal(evidence.maxBytes,157286400);assert.equal(evidence.clientReported,true);
 assert.ok(evidence.dispatchFileName.startsWith('enc:v1:'));
 assert.equal((await f.db.query('SELECT count(*)::int AS count FROM stored_files')).rows[0].count,0);
 assert.equal((await f.db.query('SELECT count(*)::int AS count FROM messages')).rows[0].count,0);
});
