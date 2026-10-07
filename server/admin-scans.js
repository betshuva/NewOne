'use strict';
const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const path = require('node:path');
const jwt = require('jsonwebtoken');
const { signSession } = require('./session-security');
const { acquireUploadLock } = require('./upload-reuse');
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MIME = new Set(['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm','video/quicktime']);
const SCHEMA = `
ALTER TABLE stored_files ADD COLUMN IF NOT EXISTS scan_cache_invalidated_at timestamptz;
CREATE TABLE IF NOT EXISTS moderation_scan_resets (
 id uuid PRIMARY KEY,stored_file_id uuid REFERENCES stored_files(id) ON DELETE SET NULL,
 actor_id uuid REFERENCES users(id) ON DELETE SET NULL,content_sha256 text NOT NULL,
 file_type text NOT NULL,affected_files integer NOT NULL,previous_budgets jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX IF NOT EXISTS moderation_scan_resets_hash ON moderation_scan_resets(content_sha256,created_at DESC);
`;
const failure = (status,message) => Object.assign(new Error(message),{status});
async function resetScan(pool,fileId,actorId) {
 if(!UUID.test(fileId||''))throw failure(400,'מזהה קובץ אינו תקין');
 const source=(await pool.query('SELECT content_sha256,file_type FROM stored_files WHERE id=$1',[fileId])).rows[0];
 if(!source||!['image','video'].includes(source.file_type))throw failure(404,'הסריקה לא נמצאה');
 if(!/^[a-f0-9]{64}$/.test(source.content_sha256||''))throw failure(409,'אין זיהוי תוכן המאפשר מחיקה בטוחה של הסריקה');
 const release=await acquireUploadLock('scan-cache',source.content_sha256,source.file_type);
 let db;
 try {
  db=await pool.connect();await db.query('BEGIN');
  await db.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))',['scan-cache:'+source.content_sha256]);
  const files=(await db.query(`SELECT id,moderation_status,scan_cache_invalidated_at FROM stored_files
    WHERE content_sha256=$1 AND file_type=$2 ORDER BY id FOR UPDATE`,[source.content_sha256,source.file_type])).rows;
  const chosen=files.find(f=>f.id===fileId);
  if(!chosen)throw failure(404,'הסריקה לא נמצאה');
  if(chosen.scan_cache_invalidated_at){await db.query('COMMIT');return {ok:true,alreadyDeleted:true,affectedFiles:0};}
  const budgets=(await db.query('SELECT * FROM video_scan_budgets WHERE content_sha256=$1 ORDER BY id FOR UPDATE',[source.content_sha256])).rows;
  const pending=(await db.query(`SELECT 1 FROM pending_scans ps JOIN stored_files sf ON sf.public_url=ps.file_url
    WHERE sf.content_sha256=$1 LIMIT 1`,[source.content_sha256])).rowCount;
  if(pending||files.some(f=>f.moderation_status==='pending')||budgets.some(b=>b.status==='active'))
    throw failure(409,'קיימת סריקה פעילה של הקובץ. אפשר למחוק את הסריקה לאחר סיומה.');
  // Keep file decisions and audit/billing history. Only reusable scan state is removed.
  const summaries=budgets.map(({id,user_id,status,reason,started_at,updated_at,total_used,google_vision_used,openai_used,gemini_used})=>
    ({id,user_id,status,reason,started_at,updated_at,total_used,google_vision_used,openai_used,gemini_used}));
  const changed=await db.query(`UPDATE stored_files SET scan_cache_invalidated_at=clock_timestamp()
    WHERE content_sha256=$1 AND file_type=$2 AND scan_cache_invalidated_at IS NULL`,[source.content_sha256,source.file_type]);
  await db.query(`INSERT INTO moderation_scan_resets(id,stored_file_id,actor_id,content_sha256,file_type,affected_files,previous_budgets)
    VALUES($1,$2,$3,$4,$5,$6,$7)`,[crypto.randomUUID(),fileId,actorId,source.content_sha256,source.file_type,changed.rowCount,JSON.stringify(summaries)]);
  const ids=budgets.map(b=>b.id);
  await db.query('DELETE FROM video_scan_operations WHERE scan_id=ANY($1::uuid[])',[ids]);
  await db.query('DELETE FROM video_scan_budgets WHERE id=ANY($1::uuid[])',[ids]);
  await db.query('COMMIT');return {ok:true,affectedFiles:changed.rowCount};
 } catch(error){if(db)await db.query('ROLLBACK');throw error;}
 finally{db?.release();release();}
}
const FILTER_FIELDS={name:'sf.original_name',user:'sf.user_id::text',type:'sf.file_type',status:'sf.moderation_status'};
const OPTION_LABELS={type:"CASE sf.file_type WHEN 'image' THEN 'תמונה' WHEN 'video' THEN 'סרטון' ELSE sf.file_type END",
 status:"CASE sf.moderation_status WHEN 'approved' THEN 'אושרה' WHEN 'rejected' THEN 'נחסמה' WHEN 'stopped' THEN 'הסריקה נעצרה' WHEN 'pending' THEN 'ממתינה לבדיקה' ELSE sf.moderation_status END"};
const SORT_FIELDS={date:'sf.created_at',name:'sf.original_name',user:'u.name',...OPTION_LABELS};
function scanFilters(query,omit) {
 const type=String(query.type||'all'),search=String(query.search||'').trim();
 if(!['all','image','video'].includes(type)||search.length>200)throw failure(400,'מסנני החיפוש אינם תקינים');
 let columns;
 try{if(String(query.columnFilters||'').length>40000)throw Error();columns=JSON.parse(query.columnFilters||'{}');}catch{throw failure(400,'מסנני העמודות אינם תקינים');}
 if(!columns||typeof columns!=='object'||Array.isArray(columns))throw failure(400,'מסנני העמודות אינם תקינים');
 const values=[type,search],where=["sf.file_type IN ('image','video')","sf.context_type IS DISTINCT FROM 'received'",'sf.scan_cache_invalidated_at IS NULL',
 "($1='all' OR sf.file_type=$1)","($2='' OR sf.original_name ILIKE '%'||$2||'%' OR u.name ILIKE '%'||$2||'%' OR u.short_id::text=$2)"];
 const bind=value=>{values.push(value);return '$'+values.length;};
 for(const [field,filter]of Object.entries(columns)){
  if(!filter||typeof filter!=='object'||Array.isArray(filter))throw failure(400,'מסנן עמודה אינו תקין');
  if(field==='date'){
   const dates={};for(const key of ['from','to'])if(filter[key]){
    if(typeof filter[key]!=='string'||!/^\d{4}-\d{2}-\d{2}T/.test(filter[key])||!Number.isFinite(Date.parse(filter[key])))throw failure(400,'תאריך אינו תקין');
    dates[key]=new Date(filter[key]).toISOString();
   }
   if(dates.from&&dates.to&&dates.from>=dates.to)throw failure(400,'תאריך הסיום חייב להיות אחרי תאריך ההתחלה');
   if(field!==omit){if(dates.from)where.push('sf.created_at>='+bind(dates.from)+'::timestamptz');if(dates.to)where.push('sf.created_at<'+bind(dates.to)+'::timestamptz');}
  }else{
   if(!Object.hasOwn(FILTER_FIELDS,field)||!Array.isArray(filter.values)||filter.values.length>100||typeof filter.exclude!=='boolean'||filter.values.some(value=>value!==null&&(typeof value!=='string'||value.length>512)))throw failure(400,'מסנן עמודה אינו תקין');
   if(field===omit)continue;
   const expression=FILTER_FIELDS[field],nonNull=filter.values.filter(value=>value!==null);
   const match=`(COALESCE(${expression}=ANY(${bind(nonNull)}::text[]),FALSE) OR (${expression} IS NULL AND ${bind(filter.values.includes(null))}::boolean))`;
   where.push((filter.exclude?'NOT ':'')+match);
  }
 }
 return {where:where.join(' AND '),values,bind};
}
async function filterOptions(pool,query) {
 const field=String(query.column||''),search=String(query.optionSearch||'').trim();
 if(!Object.hasOwn(FILTER_FIELDS,field)||search.length>200)throw failure(400,'עמודת סינון אינה תקינה');
 const filters=scanFilters(query,field),expression=FILTER_FIELDS[field];
 const label=field==='user'?"COALESCE(u.name,'משתמש לא זמין')||COALESCE(' · '||u.short_id::text,'')":OPTION_LABELS[field]||expression;
 const term=filters.bind(search);
 const rows=(await pool.query(`SELECT DISTINCT ${expression} AS value,${label} AS label
   FROM stored_files sf LEFT JOIN users u ON u.id=sf.user_id WHERE ${filters.where}
   AND (${term}='' OR ${label} ILIKE '%'||${term}||'%') ORDER BY label NULLS LAST,value NULLS LAST LIMIT 101`,filters.values)).rows;
 return {options:rows.slice(0,100),hasMore:rows.length>100};
}
async function listScans(pool,query) {
 const type=String(query.type||'all'),order=String(query.order||'desc'),search=String(query.search||'').trim();
 const page=Number(query.page||1);
 const sort=String(query.sort||'date');
 if(!Object.hasOwn(SORT_FIELDS,sort)||!['all','image','video'].includes(type)||!['asc','desc'].includes(order)||search.length>200||!Number.isSafeInteger(page)||page<1||page>10000)
   throw failure(400,'מסנני החיפוש אינם תקינים');
 const filters=scanFilters(query),offset=filters.bind((page-1)*50);
 const rows=(await pool.query(`SELECT sf.id,sf.original_name,sf.file_type,sf.file_size,sf.created_at,
   sf.moderation_status,sf.moderation_details->>'reason' AS reason,
   sf.moderation_details->>'reasonCode' AS reason_code,u.name AS user_name,u.short_id AS user_number,
   sf.content_sha256 IS NOT NULL AND sf.moderation_status<>'pending' AS can_delete,
   sf.content_purged_at IS NULL OR EXISTS(SELECT 1 FROM audit_scan_previews p WHERE p.stored_file_id=sf.id AND sf.file_type='image' AND sf.moderation_status='rejected') AS available
   FROM stored_files sf LEFT JOIN users u ON u.id=sf.user_id
   WHERE ${filters.where}
   ORDER BY ${SORT_FIELDS[sort]} ${order==='asc'?'ASC':'DESC'} NULLS LAST,sf.id ${order==='asc'?'ASC':'DESC'} LIMIT 51 OFFSET ${offset}`,filters.values)).rows;
 return {items:rows.slice(0,50),hasMore:rows.length>50,page};
}
function registerAdminScanRoutes(app,{getPool,adminMiddleware,readMedia,uploadRoot,secret}) {
 const route=(method,url,handler)=>app[method](url,adminMiddleware,async(req,res)=>{
  res.set('Cache-Control','private, no-store');
  try{return await handler(req,res,await getPool());}catch(error){
   if(!error.status)console.warn('[admin-scans]',error.code||error.name);
   return res.status(error.status||503).json({error:error.status?error.message:'לא ניתן להשלים את הפעולה כרגע'});
  }
 });
 route('get','/api/admin/scan-results',async(req,res,pool)=>res.json({...await listScans(pool,req.query),canDelete:req.adminPerm==='edit'}));
 route('get','/api/admin/scan-results/filter-options',async(req,res,pool)=>res.json(await filterOptions(pool,req.query)));
 route('delete','/api/admin/scan-results/:id',async(req,res,pool)=>{
  if(req.adminPerm!=='edit')throw failure(403,'נדרשת הרשאת עריכה למחיקת סריקה');
  if(req.body?.confirm!=='DELETE_SCAN_CACHE')throw failure(400,'נדרש אישור למחיקת הסריקה השמורה');
  return res.json(await resetScan(pool,req.params.id,req.user.id));
 });
 route('post','/api/admin/scan-results/:id/preview-ticket',async(req,res,pool)=>{
  if(!UUID.test(req.params.id))throw failure(400,'מזהה קובץ אינו תקין');
  const exists=(await pool.query("SELECT 1 FROM stored_files WHERE id=$1 AND file_type IN ('image','video')",[req.params.id])).rowCount;
  if(!exists)throw failure(404,'הקובץ לא נמצא');
  const ticket=jwt.sign({purpose:'admin-scan-preview',fileId:req.params.id,id:req.user.id,sessionVersion:req.user.sessionVersion||0},secret,{algorithm:'HS256',expiresIn:'5m'});
  return res.json({url:`api/admin/scan-results/${req.params.id}/preview?ticket=${encodeURIComponent(ticket)}`});
 });
 app.get('/api/admin/scan-results/:id/preview',(req,res,next)=>{
  try{
   const claims=jwt.verify(req.query.ticket,secret,{algorithms:['HS256']});
   if(claims.purpose!=='admin-scan-preview'||claims.fileId!==req.params.id||!UUID.test(claims.id||''))throw Error('Invalid ticket');
   req.headers.authorization='Bearer '+signSession({id:claims.id,session_version:claims.sessionVersion},secret);next();
  }catch{res.status(401).end();}
 },adminMiddleware,async(req,res)=>{
  res.set({'Cache-Control':'private, no-store','X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer'});
  try{
   const pool=await getPool(),file=(await pool.query('SELECT * FROM stored_files WHERE id=$1',[req.params.id])).rows[0];
   if(!file||!MIME.has(file.mime_type))throw failure(404,'הקובץ אינו זמין לתצוגה');
   let bytes,mime=file.mime_type;
   if(file.content_purged_at){
    if(file.file_type==='image'&&file.moderation_status==='rejected'){
     bytes=(await pool.query('SELECT image FROM audit_scan_previews WHERE stored_file_id=$1 ORDER BY created_at LIMIT 1',[file.id])).rows[0]?.image;mime='image/jpeg';
    }
    if(!bytes)throw failure(404,'הקובץ נמחק ואינו זמין לתצוגה');
   }else{
    const local=path.resolve(uploadRoot,file.storage_path||'');
    if(!local.startsWith(path.resolve(uploadRoot)+path.sep))throw failure(404,'הקובץ אינו זמין');
    const real=await fs.realpath(local).catch(()=>null);
    if(real?.startsWith(path.resolve(uploadRoot)+path.sep)&&(await fs.stat(real)).isFile()){
     res.type(mime);return res.sendFile(real,{headers:{'Cache-Control':'private, no-store'}});
    }
    if(Number(file.file_size)>256*1024*1024)throw failure(413,'התצוגה כאן זמינה לקובצי ענן עד 256 MB');
    bytes=await readMedia(pool,file);
   }
   if(!Buffer.isBuffer(bytes)||!bytes.length)throw failure(404,'הקובץ אינו זמין');
   res.type(mime);return res.send(bytes);
  }catch(error){if(!res.headersSent)res.status(error.status||503).json({error:error.status?error.message:'לא ניתן להציג את הקובץ כרגע'});}
 });
}
module.exports={SCHEMA,resetScan,listScans,filterOptions,registerAdminScanRoutes};
