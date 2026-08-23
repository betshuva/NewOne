#!/usr/bin/env node
'use strict';

require('dotenv').config({ quiet: true });
const bcrypt = require('bcryptjs');
const sharp = require('sharp');
const { io } = require('socket.io-client');
const { performance } = require('node:perf_hooks');
const fs = require('node:fs');
const path = require('node:path');
const { getPool } = require('../server/db');

const base = process.env.LOAD_API_BASE || 'http://127.0.0.1:5003';
const durationMs = Number(process.env.LOAD_DURATION_MS || 6 * 60 * 60 * 1000);
const userCount = Number(process.env.LOAD_USERS || 60);
const targetRps = Number(process.env.LOAD_RPS || 6);
const prefix = process.env.LOAD_PREFIX || `LOADTEST-6H-${Date.now()}`;
const password = `Load-${Date.now()}-Betshuva`;
const outputDir = path.resolve(__dirname, '..', 'tmp', prefix);
fs.mkdirSync(outputDir, { recursive: true });
const log = fs.createWriteStream(path.join(outputDir, 'events.ndjson'), { flags: 'a' });

const users = [];
const groups = [];
const sockets = [];
const samples = [];
const totals = { requests: 0, ok: 0, errors: {}, socketMessages: 0, calls: 0, uploads: 0 };
let stopping = false;

function emit(event, data = {}) {
  const row = { at: new Date().toISOString(), event, ...data };
  log.write(`${JSON.stringify(row)}\n`);
  console.log(JSON.stringify(row));
}
function sleep(ms) { return new Promise(resolve => setTimeout(resolve, ms)); }
function percentile(values, p) {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * p) - 1)];
}
async function request(route, { user, method = 'GET', body, timeout = 15000 } = {}) {
  const started = performance.now();
  let status = 0;
  try {
    const response = await fetch(`${base}${route}`, {
      method,
      headers: {
        ...(user ? { Authorization: `Bearer ${user.token}` } : {}),
        ...(body ? { 'Content-Type': 'application/json' } : {}),
        'X-Real-IP': `198.51.100.${((user?.index || 0) % 240) + 10}`,
      },
      body: body ? JSON.stringify(body) : undefined,
      signal: AbortSignal.timeout(timeout),
    });
    status = response.status;
    const data = await response.json().catch(() => null);
    return { status, data };
  } catch (error) {
    return { status, error: error.message };
  } finally {
    const ms = performance.now() - started;
    totals.requests++;
    if (status >= 200 && status < 300) totals.ok++;
    else totals.errors[status] = (totals.errors[status] || 0) + 1;
    samples.push({ at: Date.now(), route, status, ms });
    if (samples.length > 20000) samples.splice(0, samples.length - 20000);
  }
}

async function createUsers(pool) {
  const hash = await bcrypt.hash(password, 8);
  for (let i = 0; i < userCount; i++) {
    const email = `${prefix.toLowerCase()}-${i}@loadtest.invalid`;
    const phone = `058${String(Date.now()).slice(-3)}${String(i).padStart(4, '0')}`;
    const result = await pool.query(
      `INSERT INTO users(name,email,password_hash,phone,email_verified,phone_verified,city,country,
                         terms_accepted_at,terms_version,age_confirmed,gender,birth_date)
       VALUES($1,$2,$3,$4,TRUE,TRUE,'ירושלים','ישראל',now(),'2026-08-23',TRUE,$5,'1990-01-01')
       RETURNING id,name,email,phone`,
      [`${prefix} משתמש ${i + 1}`, email, hash, phone, i % 2 ? 'female' : 'male']);
    users.push({ ...result.rows[0], index: i });
  }
  for (let i = 0; i < users.length; i++) {
    const peer = users[(i + 1) % users.length];
    await pool.query(
      `INSERT INTO user_contacts(owner_id,contact_id) VALUES($1,$2),($2,$1)
       ON CONFLICT DO NOTHING`, [users[i].id, peer.id]);
  }
  fs.writeFileSync(path.join(outputDir, 'credentials.json'), JSON.stringify({
    prefix, password, users: users.map(({ id, name, email, phone }) => ({ id, name, email, phone })),
  }, null, 2), { mode: 0o600 });
  emit('users-created', { count: users.length, credentials: path.join(outputDir, 'credentials.json') });
}

async function loginUsers() {
  for (let start = 0; start < users.length; start += 10) {
    await Promise.all(users.slice(start, start + 10).map(async user => {
      const result = await request('/api/login', {
        user, method: 'POST', body: { email: user.email, password },
      });
      if (!result.data?.token) throw new Error(`Login failed ${user.email}: ${result.status}`);
      user.token = result.data.token;
    }));
  }
  emit('users-logged-in', { count: users.length });
}

async function setupGroups(pool) {
  const groupCount = Math.max(3, Math.ceil(userCount / 15));
  for (let g = 0; g < groupCount; g++) {
    const admin = users[g];
    const created = await request('/api/groups', { user: admin, method: 'POST', body: {
      name: `${prefix} קבוצה ${g + 1}`, description: 'קבוצת בדיקת עומס ל-6 שעות — נא לא למחוק',
    }});
    if (!created.data?.id) throw new Error(`Group creation failed: ${created.status}`);
    const group = { id: created.data.id, admin, members: [admin] };
    const candidates = users.filter((_, i) => i % groupCount === g && i !== g);
    for (const member of candidates) {
      await request(`/api/groups/${group.id}/members`, {
        user: admin, method: 'POST', body: { userId: member.id },
      });
      const joined = await request(`/api/groups/${group.id}/join`, { user: member, method: 'POST' });
      if (joined.status === 200) group.members.push(member);
    }
    groups.push(group);
  }
  fs.writeFileSync(path.join(outputDir, 'groups.json'), JSON.stringify(groups.map(g => ({
    id: g.id, name: `${prefix}`, memberIds: g.members.map(m => m.id),
  })), null, 2));
  emit('groups-created', { count: groups.length, memberships: groups.reduce((n, g) => n + g.members.length, 0) });
}

async function connectSockets() {
  await Promise.all(users.map(user => new Promise((resolve, reject) => {
    const socket = io(base, { auth: { token: user.token }, transports: ['websocket'],
      reconnection: true, timeout: 15000 });
    user.socket = socket;
    sockets.push(socket);
    socket.on('chat:message', () => totals.socketMessages++);
    socket.on('group:message', () => totals.socketMessages++);
    socket.on('call:incoming', payload => {
      totals.calls++;
      setTimeout(() => socket.emit('call:reject', { callId: payload.callId }), 250);
    });
    socket.once('connect', resolve);
    socket.once('connect_error', reject);
  })));
  for (const group of groups) {
    for (const member of group.members) member.socket.emit('group:join', { groupId: group.id });
  }
  emit('sockets-connected', { count: sockets.filter(s => s.connected).length });
}

async function uploadImage(user, context = {}) {
  const image = await sharp({ create: { width: 640, height: 480, channels: 3,
    background: { r: 30, g: 120, b: 210 } } }).png().toBuffer();
  const form = new FormData();
  form.append('file', new Blob([image], { type: 'image/png' }), `${prefix}-${Date.now()}.png`);
  for (const [key, value] of Object.entries(context)) form.append(key, value);
  const started = performance.now();
  const response = await fetch(`${base}/api/upload`, {
    method: 'POST', headers: { Authorization: `Bearer ${user.token}` }, body: form,
    signal: AbortSignal.timeout(120000),
  });
  const data = await response.json().catch(() => null);
  const ms = performance.now() - started;
  totals.requests++; samples.push({ at: Date.now(), route: '/api/upload', status: response.status, ms });
  if (response.ok) { totals.ok++; totals.uploads++; } else totals.errors[response.status] = (totals.errors[response.status] || 0) + 1;
  return response.ok && data?.url && data.status !== 'rejected' ? data : null;
}

async function seedImages() {
  for (let i = 0; i < Math.min(groups.length, 4); i++) {
    const group = groups[i];
    const uploaded = await uploadImage(group.admin, { groupId: group.id });
    if (uploaded) await request(`/api/groups/${group.id}/messages`, { user: group.admin,
      method: 'POST', body: { fileUrl: uploaded.url, fileName: uploaded.fileName, fileType: 'image' } });
  }
  emit('images-seeded', { uploads: totals.uploads });
}

async function oneOperation(sequence) {
  const user = users[sequence % users.length];
  const peer = users[(user.index ^ 1) % users.length];
  const choice = sequence % 20;
  if (choice < 7) return request('/api/messages', { user, method: 'POST', body: {
    toUserId: peer.id, text: `${prefix} הודעת עומס ${sequence}`,
  }});
  if (choice < 11) {
    const group = groups[sequence % groups.length];
    const sender = group.members[sequence % group.members.length];
    return request(`/api/groups/${group.id}/messages`, { user: sender, method: 'POST', body: {
      text: `${prefix} הודעה קבוצתית ${sequence}`,
    }});
  }
  if (choice < 14) return request('/api/users', { user });
  if (choice < 16) return request('/api/groups', { user });
  if (choice < 18) return request('/api/messages/unread', { user });
  if (choice === 18) return request(`/api/users/search?q=${encodeURIComponent(prefix.slice(0, 16))}`, { user });
  return request('/api/profile', { user });
}

function reportWindow(startedAt) {
  const cutoff = Date.now() - 5 * 60 * 1000;
  const recent = samples.filter(s => s.at >= cutoff);
  const times = recent.map(s => s.ms);
  const errors = recent.filter(s => s.status < 200 || s.status >= 300).length;
  emit('metrics', {
    elapsedMinutes: +((Date.now() - startedAt) / 60000).toFixed(1),
    requests: totals.requests, successRate: +(totals.ok / Math.max(1, totals.requests) * 100).toFixed(2),
    recentRequests: recent.length, recentErrorRate: +(errors / Math.max(1, recent.length) * 100).toFixed(2),
    p50Ms: +percentile(times, .5).toFixed(1), p95Ms: +percentile(times, .95).toFixed(1),
    p99Ms: +percentile(times, .99).toFixed(1), connectedSockets: sockets.filter(s => s.connected).length,
    uploads: totals.uploads, calls: totals.calls, errors: totals.errors,
  });
}

async function sustainedRun() {
  const startedAt = Date.now();
  const endsAt = startedAt + durationMs;
  let sequence = 0;
  let nextReport = Date.now() + 60000;
  let nextCall = Date.now() + 30000;
  let nextUpload = Date.now() + 30 * 60 * 1000;
  emit('load-started', { durationHours: durationMs / 3600000, targetRps, endsAt: new Date(endsAt).toISOString() });
  while (!stopping && Date.now() < endsAt) {
    const elapsed = Date.now() - startedAt;
    const ramp = Math.min(1, .2 + elapsed / (30 * 60 * 1000));
    const batch = Math.max(1, Math.round(targetRps * ramp));
    await Promise.all(Array.from({ length: batch }, () => oneOperation(sequence++)));
    if (Date.now() >= nextCall) {
      const caller = users[sequence % users.length];
      const callee = users[(sequence + 1) % users.length];
      caller.socket.emit('call:start', { toUserId: callee.id });
      nextCall = Date.now() + 60000;
    }
    if (Date.now() >= nextUpload) {
      const group = groups[sequence % groups.length];
      const uploaded = await uploadImage(group.admin, { groupId: group.id });
      if (uploaded) await request(`/api/groups/${group.id}/messages`, { user: group.admin,
        method: 'POST', body: { fileUrl: uploaded.url, fileName: uploaded.fileName, fileType: 'image' } });
      nextUpload = Date.now() + 30 * 60 * 1000;
    }
    if (Date.now() >= nextReport) { reportWindow(startedAt); nextReport = Date.now() + 60000; }
    await sleep(1000);
  }
  reportWindow(startedAt);
}

async function main() {
  const pool = await getPool();
  process.on('SIGTERM', () => { stopping = true; });
  process.on('SIGINT', () => { stopping = true; });
  try {
    emit('start', { prefix, base, userCount, targetRps, durationMs, outputDir });
    await createUsers(pool);
    await loginUsers();
    await setupGroups(pool);
    await connectSockets();
    await seedImages();
    await sustainedRun();
    emit('complete', { prefix, totals, retained: true });
    fs.writeFileSync(path.join(outputDir, 'summary.json'), JSON.stringify({ prefix, totals,
      users: users.length, groups: groups.length, retained: true, completedAt: new Date().toISOString() }, null, 2));
  } catch (error) {
    emit('fatal', { message: error.message, stack: error.stack, retained: true });
    process.exitCode = 1;
  } finally {
    sockets.forEach(socket => socket.disconnect());
    log.end();
    await pool.end();
  }
}

main();
