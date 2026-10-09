'use strict';
const crypto = require('node:crypto');
const bcrypt = require('bcryptjs');
const SCHEMA = `CREATE TABLE IF NOT EXISTS filter_pin_settings (
 user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
 pin_hash TEXT NOT NULL, recovery_email TEXT NOT NULL, generation INTEGER NOT NULL DEFAULT 1,
 failures INTEGER NOT NULL DEFAULT 0, blocked_until TIMESTAMPTZ,
 recovery_hash TEXT, recovery_expires TIMESTAMPTZ, recovery_failures INTEGER NOT NULL DEFAULT 0,
 recovery_sent_at TIMESTAMPTZ, recovery_window TIMESTAMPTZ, recovery_sends INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS filter_pin_grants (
 user_id UUID NOT NULL REFERENCES filter_pin_settings(user_id) ON DELETE CASCADE,
 session_key TEXT NOT NULL, generation INTEGER NOT NULL, expires_at TIMESTAMPTZ NOT NULL,
 PRIMARY KEY(user_id,session_key)
 );
ALTER TABLE filter_pin_grants ADD COLUMN IF NOT EXISTS screen_scope TEXT;`;
const fail = (status, code, message) => Object.assign(new Error(message), {status, code});
const sessionKey = req => crypto.createHash('sha256').update(req.headers.authorization || '').digest('hex');
const validPin = value => typeof value === 'string' && /^\d{4,8}$/.test(value);
async function requireFilterPin(db, req) {
 const rows = await db.query(`SELECT s.user_id, g.screen_scope IS NOT NULL AND g.expires_at > clock_timestamp() AND g.generation=s.generation AS unlocked
 FROM filter_pin_settings s LEFT JOIN filter_pin_grants g ON g.user_id=s.user_id AND g.session_key=$2
 WHERE s.user_id=$1`, [req.user.id, sessionKey(req)]);
 if (rows.rows.length && rows.rows[0].unlocked !== true)
  throw fail(423, 'FILTER_PIN_LOCKED', 'הגדרות הסינון נעולות. יש להזין קוד כדי לשנות אותן');
}
function registerFilterPin(app, {auth, getPool, sendEmail, secret, resetLimit = (_req,_res,next)=>next()}) {
 const scope = req => {
  const value=req.headers['x-filter-pin-scope'];
  if(typeof value!=='string'||! /^[a-f0-9]{32}$/.test(value))throw fail(400,'PIN_SCREEN_REQUIRED','יש לפתוח מחדש את מסך הסינון');
  return value;
 };
 const linkHash = token => 'link:'+crypto.createHash('sha256').update(token).digest('hex');
 async function transaction(req, operation) {
  const db = await (await getPool()).connect();
  try {
   await db.query('BEGIN');
   await db.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))', ['personal-media-owner:'+req.user.id]);
   const found = await db.query('SELECT * FROM filter_pin_settings WHERE user_id=$1 FOR UPDATE', [req.user.id]);
   const result = await operation(db, found.rows[0]);
   await db.query('COMMIT'); return result;
  } catch(e) {await db.query('ROLLBACK');throw e;} finally {db.release();}
 }
 const route = (path, handler) => app.post('/api/filter-pin/'+path, auth, async (req,res) => {
  try {const result=await handler(req);res.set('Cache-Control','no-store');res.status(result.status||200).json(result);}
  catch(e) {res.status(e.status||503).json({error:e.status?e.message:'לא ניתן לבצע את הפעולה כעת',code:e.code||'FILTER_PIN_UNAVAILABLE'});}
 });
 async function verify(db, row, pin) {
  if (!row) throw fail(409,'FILTER_PIN_NOT_CONFIGURED','יש להגדיר קוד תחילה');
  if (row.blocked_until && new Date(row.blocked_until)>new Date()) return {status:429,error:'יותר מדי ניסיונות. נסו שוב בעוד 15 דקות'};
  if (!validPin(pin) || !await bcrypt.compare(pin,row.pin_hash)) {
   await db.query(`UPDATE filter_pin_settings SET failures=CASE WHEN blocked_until < clock_timestamp() THEN 1 ELSE failures+1 END,
   blocked_until=CASE WHEN (CASE WHEN blocked_until < clock_timestamp() THEN 1 ELSE failures+1 END)>=5 THEN clock_timestamp()+interval '15 minutes' ELSE NULL END WHERE user_id=$1`,[row.user_id]);
   return {status:403,error:'קוד שגוי'};
  }
  await db.query('UPDATE filter_pin_settings SET failures=0,blocked_until=NULL WHERE user_id=$1',[row.user_id]);
 }
 app.get('/api/filter-pin',auth,async(req,res)=>{
  try {const db=await getPool();const row=await db.query(`SELECT s.user_id,g.expires_at > clock_timestamp() AS active,g.generation=s.generation AND g.screen_scope=$3 AS current
   FROM filter_pin_settings s LEFT JOIN filter_pin_grants g ON g.user_id=s.user_id AND g.session_key=$2 WHERE s.user_id=$1`,[req.user.id,sessionKey(req),req.headers['x-filter-pin-scope']||null]);
   const r=row.rows[0];res.set('Cache-Control','no-store').json({configured:!!r,unlocked:!r||r.current===true&&r.active===true});
  }catch(_){res.status(503).json({error:'לא ניתן לבדוק את נעילת הסינון כעת'});}
 });
 route('setup',req=>transaction(req,async(db,row)=>{
  if(row)throw fail(409,'FILTER_PIN_EXISTS','קוד כבר הוגדר');
  if(!validPin(req.body.pin)||req.body.pin!==req.body.confirmPin)throw fail(400,'INVALID_PIN','יש לבחור קוד תואם בן 4–8 ספרות');
  const account=(await db.query('SELECT email,email_verified FROM users WHERE id=$1',[req.user.id])).rows[0];
  if(!account?.email_verified||!account.email)throw fail(409,'VERIFIED_EMAIL_REQUIRED','נדרש אימייל מאומת לשחזור קוד');
  await db.query('INSERT INTO filter_pin_settings(user_id,pin_hash,recovery_email) VALUES($1,$2,$3)',[req.user.id,await bcrypt.hash(req.body.pin,12),account.email]);
  return {configured:true,unlocked:false};
 }));
 for(const action of ['unlock','lock'])route(action,req=>transaction(req,async(db,row)=>{
  const invalid=await verify(db,row,req.body.pin);if(invalid)return invalid;
  if(action==='lock'){
   await db.query('UPDATE filter_pin_settings SET generation=generation+1 WHERE user_id=$1',[req.user.id]);
   await db.query('DELETE FROM filter_pin_grants WHERE user_id=$1',[req.user.id]);
   return {configured:true,unlocked:false};
  }
  const grant=await db.query(`UPDATE filter_pin_grants SET generation=$3,expires_at='infinity'::timestamptz
   WHERE user_id=$1 AND session_key=$2 AND screen_scope=$4 RETURNING user_id`,[req.user.id,sessionKey(req),row.generation,scope(req)]);
  if(!grant.rowCount)throw fail(409,'PIN_SCREEN_CLOSED','מסך הסינון נסגר. יש לפתוח אותו מחדש');
  return {configured:true,unlocked:true};
 }));
 route('enter',req=>transaction(req,async(db,row)=>{
  const screen=scope(req);
  if(row)await db.query(`INSERT INTO filter_pin_grants(user_id,session_key,generation,expires_at,screen_scope)
   VALUES($1,$2,$3,clock_timestamp(),$4) ON CONFLICT(user_id,session_key) DO UPDATE SET
   generation=EXCLUDED.generation,expires_at=EXCLUDED.expires_at,screen_scope=EXCLUDED.screen_scope`,[req.user.id,sessionKey(req),row.generation,screen]);
  return {configured:!!row,unlocked:!row};
 }));
 route('leave',req=>transaction(req,async(db)=>{
  await db.query('DELETE FROM filter_pin_grants WHERE user_id=$1 AND session_key=$2 AND screen_scope=$3',[req.user.id,sessionKey(req),scope(req)]);
  return {ok:true};
 }));
 route('disable',req=>transaction(req,async(db,row)=>{
  const invalid=await verify(db,row,req.body.pin);if(invalid)return invalid;
  await db.query('DELETE FROM filter_pin_settings WHERE user_id=$1',[req.user.id]);
  return {configured:false,unlocked:true};
 }));
 route('recover',req=>transaction(req,async(db,row)=>{
  if(!row)throw fail(409,'FILTER_PIN_NOT_CONFIGURED','לא הוגדר קוד');
  const now=Date.now(),sent=Number(new Date(row.recovery_sent_at||0)),window=Number(new Date(row.recovery_window||0));
  if(now-sent<60000||now-window<3600000&&row.recovery_sends>=5)throw fail(429,'RECOVERY_RATE_LIMIT','יש להמתין לפני שליחת קוד נוסף');
  const token=crypto.randomBytes(32).toString('hex');
  const link='https://betshuva.com/betshuva-app/reset-filter-code#token='+token;
  await db.query(`UPDATE filter_pin_settings SET recovery_hash=$2,recovery_expires=clock_timestamp()+interval '30 minutes',recovery_failures=0,
    recovery_sent_at=clock_timestamp(),recovery_sends=CASE WHEN recovery_window > clock_timestamp()-interval '1 hour' THEN recovery_sends+1 ELSE 1 END,
    recovery_window=CASE WHEN recovery_window > clock_timestamp()-interval '1 hour' THEN recovery_window ELSE clock_timestamp() END WHERE user_id=$1`,[req.user.id,linkHash(token)]);
  await sendEmail({to:row.recovery_email,subject:'איפוס קוד נעילת הסינון בבתשובה',html:`<div dir="rtl">לבחירת קוד נעילה חדש, לחצו על <a href="${link}">איפוס קוד הנעילה</a>.<br>הקישור חד־פעמי ותקף ל־30 דקות. אם לא ביקשתם איפוס, התעלמו מההודעה.</div>`});
  return {ok:true};
 }));
 route('reset',async()=>{throw fail(410,'RESET_LINK_REQUIRED','פתחו את קישור האיפוס שנשלח לאימייל');});
 app.get('/reset-filter-code',(_req,res)=>{
  const nonce=crypto.randomBytes(18).toString('base64');
  res.set({'Cache-Control':'no-store','Referrer-Policy':'no-referrer','X-Robots-Tag':'noindex, nofollow',
   'Content-Security-Policy':`default-src 'none'; script-src 'nonce-${nonce}'; style-src 'nonce-${nonce}'; connect-src 'self'; form-action 'none'; base-uri 'none'; frame-ancestors 'none'`});
  res.type('html').send(require('./filter-code-reset-page')(nonce));
 });
 app.post('/api/filter-pin/reset-link',resetLimit,async(req,res)=>{
  res.set('Cache-Control','no-store');
  try{
   const {token,pin,confirmPin}=req.body||{};
   if(typeof token!=='string'||!/^[a-f0-9]{64}$/.test(token))throw fail(403,'RECOVERY_EXPIRED','הקישור אינו תקף. בקשו קישור חדש');
   if(!validPin(pin)||pin!==confirmPin)throw fail(400,'INVALID_PIN','יש לבחור קוד תואם בן 4–8 ספרות');
   const found=await (await getPool()).query('SELECT user_id FROM filter_pin_settings WHERE recovery_hash=$1',[linkHash(token)]);
   if(!found.rows.length)throw fail(403,'RECOVERY_EXPIRED','הקישור אינו תקף או שכבר נעשה בו שימוש. בקשו קישור חדש');
   await transaction({user:{id:found.rows[0].user_id}},async(db,row)=>{
    if(!row||row.recovery_hash!==linkHash(token)||!row.recovery_expires||new Date(row.recovery_expires)<=new Date())
     throw fail(403,'RECOVERY_EXPIRED','הקישור אינו תקף או שפג תוקפו. בקשו קישור חדש');
    await db.query(`UPDATE filter_pin_settings SET pin_hash=$2,generation=generation+1,failures=0,blocked_until=NULL,
     recovery_hash=NULL,recovery_expires=NULL,recovery_failures=0 WHERE user_id=$1`,[row.user_id,await bcrypt.hash(pin,12)]);
    await db.query('DELETE FROM filter_pin_grants WHERE user_id=$1',[row.user_id]);
   });
   res.json({ok:true});
  }catch(e){res.status(e.status||503).json({error:e.status?e.message:'לא ניתן לעדכן את הקוד כעת',code:e.code||'FILTER_PIN_UNAVAILABLE'});}
 });
}
// Friendship approval alone does not edit filters. Only a different effective
// filter requires an open code grant, checked under the owner's transaction lock.
async function resolveFriendAcceptanceFilter(db, req, general, currentOverride, requested) {
 const {resolveScopedContentFilter}=require('./content-filter-policy');
 const current=resolveScopedContentFilter(general,currentOverride);
 const filter=requested==null?current:resolveScopedContentFilter(general,requested);
 const changed=Object.keys(current).some(key=>current[key]!==filter[key]);
 if(changed)await requireFilterPin(db,req);
 return {filter,changed};
}
async function filterPinQuery(pool, req, sql, params) {
 const db=await pool.connect();
 try {await db.query('BEGIN');await db.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))',['personal-media-owner:'+req.user.id]);
 await requireFilterPin(db,req);const result=await db.query(sql,params);await db.query('COMMIT');return result;
 }catch(e){await db.query('ROLLBACK');throw e;}finally{db.release();}
}
module.exports={SCHEMA,registerFilterPin,requireFilterPin,filterPinQuery,validPin,sessionKey,resolveFriendAcceptanceFilter};
