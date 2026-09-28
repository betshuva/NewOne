'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),{randomUUID}=require('node:crypto');
const {stoppedItems,attachStoppedScanEvidence}=require('../server/audit-stopped-evidence');

test('stopped evidence uses unresolved final frames, not isolated provider refusals or unrelated frames',()=>{
  const file={file_id:randomUUID(),file_type:'video',original_name:'video.webm',frames:[
    {index:0,pending:false,timestampSeconds:0},{index:1,pending:true,timestampSeconds:5.005,reason:'מחלוקת'},
    {index:2,scanStopped:true,timestampSeconds:10},
  ]};
  const event=(id,index,ms,outcome,extra={})=>({id:String(id),kind:'provider_call_finished',status:'observed',details:{
    checkType:'modesty',checkOutcome:outcome,storedFileId:file.file_id,frameIndex:index,frameTimestampMs:ms,scanPreviewId:randomUUID(),...extra}});
  const events=[event(1,0,0,'blocked'),event(2,1,5005,'blocked'),event(3,1,5005,'passed'),
    event(4,1,5005,'failed',{storedFileId:randomUUID()}),event(5,1,5006,'failed')];
  const items=stoppedItems(file,events);
  assert.equal(items.length,2);assert.equal(items[0].preview.id,'2');
  assert.equal(items[0].name,'video.webm · תמונה 2 · שנייה 5.005');
  assert.equal(items[0].key,`${file.file_id}:frame:1:5005`);
  assert.equal(items[1].preview,null);
  assert.equal(stoppedItems({...file,frames:[]},events)[0].preview,null);
  assert.equal(stoppedItems({...file,frames:[]},events)[0].key,undefined);
  assert.equal(stoppedItems({...file,frames:{}},events)[0].preview,null);
  assert.equal(stoppedItems({...file,file_type:'image',frames:[]},events)[0].name,'video.webm');
});

test('blocked evidence shows only final rejected frames and links the rejected still image',()=>{
  const id=randomUUID(),file={file_id:id,file_type:'video',operation_status:'blocked',original_name:'blocked.webm',frames:[
    {index:0,blocked:false,timestampSeconds:0},{index:1,blocked:true,timestampSeconds:5},
    {index:2,pending:true,timestampSeconds:10},
  ]};
  const events=[0,1,2].map(index=>({id:String(index+1),kind:'provider_call_finished',details:{storedFileId:id,
    checkType:'modesty',checkOutcome:'blocked',frameIndex:index,frameTimestampMs:index*5000,scanPreviewId:randomUUID()}}));
  const items=stoppedItems(file,events);
  assert.equal(items.length,1);assert.equal(items[0].preview.id,'2');assert.equal(items[0].key,`${id}:frame:1:5000`);
  assert.equal(items[0].reason,'התמונה נחסמה');
  assert.equal(stoppedItems({...file,frames:[]},events)[0].preview,null);
  assert.equal(stoppedItems({...file,decision_kind:'decision_blocked'},events)[0].preview,null);
  const image=stoppedItems({...file,file_type:'image'},events)[0];
  assert.equal(image.key,`${id}:image`);assert.ok(image.preview.checkPreviewUrl);assert.equal(image.reason,'התמונה נחסמה');
});

test('stopped preview selection is independent of displayed row filters and bounded to the final attempt',{
  skip:process.env.RUN_DB_TESTS!=='1',
},async()=>{
  require('dotenv').config({quiet:true});const {Client}=require('pg');
  const db=new Client({connectionString:process.env.DATABASE_URL});await db.connect();
  try{
    await db.query(`BEGIN;
      CREATE TEMP TABLE audit_operations(id uuid,status text,status_source text);
      CREATE TEMP TABLE audit_events(id bigint,operation_id uuid,kind text,status text,target_type text,target_id uuid,details jsonb);
      CREATE TEMP TABLE stored_files(id uuid,original_name text,file_type text,moderation_status text,moderation_details jsonb);`);
    const op=randomUUID(),file=randomUUID(),other=randomUUID(),preview=randomUUID();
    await db.query("INSERT INTO audit_operations VALUES($1,'failed','scan_workflow_finished')",[op]);
    await db.query("INSERT INTO stored_files VALUES($1,'video.webm','video','stopped',$2)",[file,{frameResults:[{pending:false,timestampSeconds:0},{pending:true,timestampSeconds:5}]}]);
    const event=async(id,kind,details={},target=null)=>db.query('INSERT INTO audit_events VALUES($1,$2,$3,$4,$5,$6,$7)',[id,op,kind,kind==='scan_workflow_finished'?'failed':'observed',target?'file':null,target,details]);
    const check={checkType:'modesty',checkOutcome:'blocked',storedFileId:file,frameIndex:1,frameTimestampMs:5000,scanPreviewId:preview};
    await event(1,'provider_call_finished',check);await event(2,'scan_attempt_started');
    await event(3,'provider_call_finished',{...check,frameIndex:0,frameTimestampMs:0});
    await event(4,'provider_call_finished',check);await event(5,'provider_call_finished',{...check,checkOutcome:'passed'});
    await event(6,'scan_workflow_finished',{},file);await event(7,'scan_workflow_finished');
    const roots=[{id:op}],events=[{id:'7',operation_id:op}];
    await attachStoppedScanEvidence(db,roots,'operations');await attachStoppedScanEvidence(db,events,'events');
    assert.deepEqual(roots[0].stoppedEvidence,events[0].stoppedEvidence);
    assert.equal(roots[0].stoppedEvidence.items[0].preview.id,'4');
    assert.equal(roots[0].stoppedEvidence.items[0].key,`${file}:frame:1:5000`);
    // A new attempt invalidates the previous final result, even before it finishes.
    await event(8,'scan_attempt_started');await attachStoppedScanEvidence(db,roots,'operations');
    assert.equal(roots[0].stoppedEvidence.items[0].preview,null);
    await db.query('DELETE FROM audit_events WHERE id=8');
    // A different operation that rescaned this file must not lend its result here.
    await db.query("INSERT INTO audit_events VALUES(9,$1,'scan_workflow_finished','failed','file',$2,'{}')",[other,file]);
    await attachStoppedScanEvidence(db,roots,'operations');assert.equal(roots[0].stoppedEvidence.items[0].preview,null);
    await db.query('DELETE FROM audit_events WHERE id=9');
    await db.query("UPDATE stored_files SET moderation_details='{}'");
    await attachStoppedScanEvidence(db,roots,'operations');assert.equal(roots[0].stoppedEvidence.items[0].preview,null);
    await db.query("UPDATE audit_operations SET status='completed'");await attachStoppedScanEvidence(db,roots,'operations');
    assert.equal(roots[0].stoppedEvidence,null);
    // Final rejected media must also be shown, while provider-only blocks are not enough.
    await db.query("UPDATE audit_operations SET status='blocked',status_source='http_response'");
    await db.query("UPDATE stored_files SET file_type='image',moderation_status='rejected'");
    await db.query("INSERT INTO audit_events VALUES(10,$1,'media_moderation_changed','blocked','file',$2,'{}')",[op,file]);
    await attachStoppedScanEvidence(db,roots,'operations');
    assert.equal(roots[0].stoppedEvidence.items[0].key,`${file}:image`);
    assert.equal(roots[0].stoppedEvidence.items[0].preview.id,'5');
    // A recipient filter blocks an approved image; the subsequent approval event is not a rescan.
    await db.query("DELETE FROM audit_events WHERE id=10");
    await db.query("UPDATE stored_files SET moderation_status='approved'");
    await db.query("INSERT INTO audit_events VALUES(10,$1,'decision_blocked','blocked','group',$2,$3)",[op,other,{storedFileId:file}]);
    await db.query("INSERT INTO audit_events VALUES(11,$1,'media_moderation_changed','completed','file',$2,'{}')",[op,file]);
    await attachStoppedScanEvidence(db,roots,'operations');
    assert.equal(roots[0].stoppedEvidence.items[0].preview.id,'5');
    assert.match(roots[0].stoppedEvidence.items[0].reason,/הגדרות הסינון/);
    await db.query('DELETE FROM audit_events WHERE id>=10');
    await attachStoppedScanEvidence(db,roots,'operations');
    assert.deepEqual(roots[0].stoppedEvidence.items,[]);
  }finally{await db.query('ROLLBACK');await db.end();}
});
