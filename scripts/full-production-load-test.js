#!/usr/bin/env node
'use strict';

require('dotenv').config({ quiet: true });
const bcrypt = require('bcryptjs');
const fs = require('node:fs/promises');
const path = require('node:path');
const sharp = require('sharp');
const { io } = require('socket.io-client');
const { performance } = require('node:perf_hooks');
const { getPool } = require('../server/db');

const base = process.env.LOAD_API_BASE || 'http://127.0.0.1:5003';
const userCount = Number(process.env.LOAD_USERS || 100);
const prefix = `loadtest-overnight-${Date.now()}`;
const password = `Lt-${Date.now()}-safe`;
const ids = [];
const tokens = [];
const storedPaths = [];
const results = [];

const pct = (xs, p) => xs.length ? [...xs].sort((a,b)=>a-b)[Math.ceil(xs.length*p)-1] : 0;
const record = (name, times, ok, errors = {}, enforceLatency = true) => {
  const row = { name, requests: times.length, ok, errors, p50Ms:+pct(times,.5).toFixed(1), p95Ms:+pct(times,.95).toFixed(1), p99Ms:+pct(times,.99).toFixed(1) };
  results.push(row); console.log(JSON.stringify({event:'result', ...row}));
  if (ok / Math.max(times.length, 1) < .98 || (enforceLatency && row.p95Ms > 2000)) throw new Error(`Safety threshold: ${name}`);
};

async function request(route, { token, method='GET', body, ip=1 }={}) {
  const started = performance.now();
  try {
    const response = await fetch(`${base}${route}`, {
      method,
      headers: { ...(token ? {Authorization:`Bearer ${token}`} : {}),
        ...(body ? {'Content-Type':'application/json'} : {}), 'X-Real-IP':`203.0.113.${(ip%250)+1}` },
      body: body ? JSON.stringify(body) : undefined,
      signal: AbortSignal.timeout(10000),
    });
    const data = await response.json().catch(()=>null);
    return { ms:performance.now()-started, status:response.status, data };
  } catch (error) { return { ms:performance.now()-started, status:0, error:error.message }; }
}

async function parallel(name, count, fn) {
  const rows = await Promise.all(Array.from({length:count},(_,i)=>fn(i)));
  const errors = {}; for (const r of rows) if (r.status < 200 || r.status >= 300) errors[r.status]=(errors[r.status]||0)+1;
  record(name, rows.map(r=>r.ms), rows.length-Object.values(errors).reduce((a,b)=>a+b,0), errors);
  return rows;
}

async function createUsers(pool) {
  const hash = await bcrypt.hash(password, 8);
  for (let i=0;i<userCount;i++) {
    const r=await pool.query(`INSERT INTO users(name,email,password_hash,phone,email_verified,phone_verified,city,community,country,terms_accepted_at,terms_version,age_confirmed)
      VALUES($1,$2,$3,$4,TRUE,TRUE,'ירושלים','בדיקת עומס','ישראל',now(),'2026-08-18',TRUE) RETURNING id`,
      [`${prefix}-${i}`,`${prefix}-${i}@example.invalid`,hash,`059${String(i).padStart(7,'0')}`]); ids.push(r.rows[0].id);
  }
  for(let i=0;i<ids.length;i+=2) await pool.query(`INSERT INTO user_contacts(owner_id,contact_id) VALUES($1,$2),($2,$1) ON CONFLICT DO NOTHING`,[ids[i],ids[(i+1)%ids.length]]);
}

async function login() {
  const rows=await parallel('login',userCount,i=>request('/api/login',{method:'POST',ip:i+1,body:{email:`${prefix}-${i}@example.invalid`,password}}));
  for(const r of rows) tokens.push(r.data?.token); if(tokens.some(t=>!t)) throw new Error('Missing login token');
}

async function socketTest() {
  const sockets=[]; const connectTimes=[]; let received=0, delivered=0, rejected=0, pending=0; const started=performance.now();
  await Promise.all(tokens.map((token,i)=>new Promise((resolve,reject)=>{
    const t=performance.now(); const s=io(base,{auth:{token},transports:['websocket'],reconnection:false,timeout:10000}); sockets.push(s);
    s.on('chat:message',()=>received++); s.on('message:delivered',()=>delivered++);
    s.on('message:rejected',()=>rejected++); s.on('message:request-pending',()=>pending++);
    s.on('connect',()=>{connectTimes.push(performance.now()-t);resolve()}); s.on('connect_error',reject);
  })));
  // The application currently installs chat listeners after asynchronous
  // connection initialization. Allow that initialization to finish so this
  // phase measures sustained delivery separately from the readiness race.
  await new Promise(resolve => setTimeout(resolve, 1000));
  for(let i=0;i<sockets.length;i++){ sockets[i].emit('chat:typing',{toUserId:ids[(i^1)%ids.length]}); sockets[i].emit('chat:message',{toUserId:ids[(i^1)%ids.length],text:`${prefix} socket ${i}`}); }
  const deadline=Date.now()+10000; while(received<userCount && Date.now()<deadline) await new Promise(r=>setTimeout(r,50));
  sockets.forEach(s=>s.disconnect());
  record('socket-connect',connectTimes,connectTimes.length,{});
  results.push({name:'socket-delivery',sent:userCount,received,delivered,rejected,pending,durationMs:+(performance.now()-started).toFixed(1)});
  console.log(JSON.stringify({event:'result',...results.at(-1)})); if(received<userCount*.98) throw new Error('Socket delivery below 98%');
}

async function uploadTest() {
  const seed=await sharp({create:{width:1280,height:720,channels:3,background:'#ffffff'}}).jpeg({quality:90}).toBuffer();
  for(const mb of [1,5,10]) {
    const payload=Buffer.concat([seed,Buffer.alloc(mb*1024*1024-seed.length)]); const form=new FormData();
    form.append('file',new Blob([payload],{type:'image/jpeg'}),`${prefix}-${mb}mb.jpg`);
    const t=performance.now(); const response=await fetch(`${base}/api/upload`,{method:'POST',headers:{Authorization:`Bearer ${tokens[0]}`,'X-Real-IP':'203.0.113.240'},body:form,signal:AbortSignal.timeout(120000)});
    const data=await response.json().catch(()=>null); const times=[performance.now()-t]; record(`upload-${mb}MB`,times,response.ok?1:0,{...(response.ok?{}:{[response.status]:1})},false);
    if(data?.url) console.log(JSON.stringify({event:'upload-status',sizeMB:mb,status:data.status||'approved'}));
  }
}

async function cleanup(pool) {
  if(!ids.length) return;
  const files=await pool.query('SELECT storage_path FROM stored_files WHERE user_id=ANY($1::uuid[])',[ids]); storedPaths.push(...files.rows.map(r=>r.storage_path));
  await pool.query('BEGIN');
  try {
    await pool.query('DELETE FROM message_status WHERE user_id=ANY($1::uuid[]) OR message_id IN (SELECT id FROM messages WHERE sender_id=ANY($1::uuid[]) OR recipient_id=ANY($1::uuid[]))',[ids]);
    await pool.query('DELETE FROM messages WHERE sender_id=ANY($1::uuid[]) OR recipient_id=ANY($1::uuid[])',[ids]);
    await pool.query('DELETE FROM activity_log WHERE user_id=ANY($1::uuid[])',[ids]);
    await pool.query('DELETE FROM audit_log WHERE user_id=ANY($1::uuid[])',[ids]);
    await pool.query('DELETE FROM pending_scans WHERE user_id=ANY($1::uuid[]) OR to_user_id=ANY($1::uuid[])',[ids]);
    await pool.query('DELETE FROM stored_files WHERE user_id=ANY($1::uuid[])',[ids]);
    await pool.query('DELETE FROM users WHERE id=ANY($1::uuid[])',[ids]);
    await pool.query('COMMIT');
  } catch(e){await pool.query('ROLLBACK');throw e}
  for(const relative of storedPaths){const absolute=path.resolve(__dirname,'..','uploads',relative);const root=path.resolve(__dirname,'..','uploads')+path.sep;if(absolute.startsWith(root))await fs.rm(absolute,{force:true}).catch(()=>{});}
}

(async()=>{const pool=await getPool();let error=null;try{
  console.log(JSON.stringify({event:'start',prefix,userCount,base})); await createUsers(pool); await login();
  await parallel('profile-get',userCount,i=>request('/api/profile',{token:tokens[i],ip:i+1}));
  await parallel('profile-update',Math.min(25,userCount),i=>request('/api/profile',{token:tokens[i],method:'PUT',ip:i+1,body:{name:`${prefix}-${i}`,city:'ירושלים',community:'בדיקת עומס',country:'ישראל',privacy_pic:'all',filter_level:'standard'}}));
  await parallel('search',userCount,i=>request(`/api/users/search?q=${encodeURIComponent(prefix)}`,{token:tokens[i],ip:i+1}));
  await parallel('chat-http',userCount,i=>request('/api/messages',{token:tokens[i],method:'POST',ip:i+1,body:{toUserId:ids[(i^1)%ids.length],text:`${prefix} http ${i}`}}));
  try { await socketTest(); } catch (e) { error=e; console.error(JSON.stringify({event:'phase-error',phase:'socket',message:e.message})); }
  await uploadTest();
}catch(e){error=e;console.error(JSON.stringify({event:'error',message:e.message}));}finally{try{await cleanup(pool);console.log(JSON.stringify({event:'cleanup',users:ids.length,files:storedPaths.length}));}catch(e){console.error(JSON.stringify({event:'cleanup-error',message:e.message}));error=error||e}await pool.end();}
console.log(JSON.stringify({event:'summary',ok:!error,results}));if(error)process.exitCode=1;})();
