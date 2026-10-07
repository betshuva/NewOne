'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const { createReadStream } = require('node:fs');

const CHUNK_BYTES = 4 * 1024 * 1024;
const MAX_RECORDING_BYTES = 512 * 1024 * 1024;
const TTL = 60 * 60 * 1000;
const UUID = /^[a-f0-9-]{36}$/i;

function createResumableAttachments({ root }) {
  let quotaHooks;
  const busy = new Set();
  const location = (user, id) => {
    if (!UUID.test(id || '')) throw Object.assign(new Error('מזהה העלאה אינו תקין'), { status: 400 });
    return path.join(root, crypto.createHash('sha256').update(String(user)).digest('hex'), id);
  };
  async function save(dir, state) {
    const temporary = path.join(dir, `${crypto.randomUUID()}.tmp`);
    await fs.writeFile(temporary, JSON.stringify(state), { mode: 0o600 });
    await fs.rename(temporary, path.join(dir, 'state.json'));
  }
  async function load(dir) {
    try {
      const state = JSON.parse(await fs.readFile(path.join(dir, 'state.json'), 'utf8'));
      if (Date.now() - state.updated > TTL) throw Object.assign(new Error('ההעלאה פגה'), { status: 410 });
      return state;
    } catch (e) {
      if (e.code === 'ENOENT') throw Object.assign(new Error('ההעלאה לא נמצאה'), { status: 404 });
      throw e;
    }
  }
  const publicState = (dir, state) => ({ id: state.id, offset: state.offset,
    chunkBytes: CHUNK_BYTES, processing: busy.has(dir), result: state.result || null });
  const endpoint = handler => async (req, res) => {
    res.set('Cache-Control', 'no-store');
    try { await handler(req, res); }
    catch (e) { if (!res.headersSent) res.status(e.status || 500).json({ error: e.status ? e.message : 'לא ניתן לחדש את ההעלאה', code: e.quotaCode || e.code }); }
  };
  const create = endpoint(async (req, res) => {
    const { id, name, size, mime, fields = {}, recording = false } = req.body || {};
    if (typeof name !== 'string' || !name || name.length > 500 ||
        !Number.isSafeInteger(size) || (recording === true ? size !== 0 : size < 1) ||
        typeof recording !== 'boolean' ||
        typeof mime !== 'string' || mime.length > 200 ||
        !fields || Array.isArray(fields) || typeof fields !== 'object' ||
        Object.entries(fields).some(([key, value]) => key.length > 100 || typeof value !== 'string' || value.length > 2000))
      return res.status(400).json({ error: 'פרטי העלאה אינם תקינים' });
    const dir = location(req.user.id, id);
    if (busy.has(dir)) return res.status(409).json({ error: 'ההעלאה כבר בטיפול' });
    busy.add(dir);
    try {
      let state;
      try { state = await load(dir); } catch (e) { if (e.status !== 404) throw e; }
      const metadata = { name, size, mime, fields, ...(recording ? { recording: true } : {}) };
      if (state) {
        if (JSON.stringify(state.metadata) !== JSON.stringify(metadata))
          return res.status(409).json({ error: 'פרטי הקובץ השתנו' });
      } else {
        await quotaHooks?.reserve(req.user.id, id, Math.max(1, size));
        await fs.mkdir(dir, { recursive: true, mode: 0o700 });
        state = { id, owner: req.user.id, metadata, offset: 0, updated: Date.now() };
        // No state means no acknowledged bytes, including a crash during creation.
        await fs.writeFile(path.join(dir, 'data'), '', { mode: 0o600 });
        await save(dir, state);
      }
      res.json({ ...publicState(dir, state), processing: false });
    } finally { busy.delete(dir); }
  });
  const status = endpoint(async (req, res) => {
    const dir = location(req.user.id, req.params.id);
    res.json(publicState(dir, await load(dir)));
  });
  const chunk = endpoint(async (req, res) => {
    const dir = location(req.user.id, req.params.id);
    if (busy.has(dir)) return res.status(409).json({ error: 'ההעלאה כבר בטיפול' });
    busy.add(dir);
    let handle, state;
    try {
      state = await load(dir);
      const offset = Number(req.headers['upload-offset']);
      const length = Number(req.headers['content-length']);
      const patch = req.method === 'PATCH';
      if (state.result || state.sealed || !Number.isSafeInteger(offset) || offset < 0 ||
          (patch ? !state.metadata.recording || offset >= state.offset : offset !== state.offset))
        return res.status(409).json(publicState(dir, state));
      if (!Number.isSafeInteger(length) || length < 1 || length > CHUNK_BYTES || offset + length > (patch ? state.offset : state.metadata.recording ? MAX_RECORDING_BYTES : state.metadata.size))
        return res.status(400).json({ error: 'גודל חלק אינו תקין' });
      await quotaHooks?.reserve(req.user.id, state.id, state.metadata.recording ? Math.max(state.offset, offset + length) : state.metadata.size);
      handle = await fs.open(path.join(dir, 'data'), 'r+');
      if (!patch) await handle.truncate(state.offset); // discard an unacknowledged partial chunk after a restart
      let written = 0;
      for await (const bytes of req) {
        if (written + bytes.length > length) throw Object.assign(new Error('חלק גדול מדי'), { status: 400 });
        let consumed = 0;
        while (consumed < bytes.length) {
          const result = await handle.write(bytes, consumed, bytes.length - consumed, offset + written + consumed);
          consumed += result.bytesWritten;
        }
        written += bytes.length;
      }
      if (written !== length) throw Object.assign(new Error('החלק לא התקבל במלואו'), { status: 400 });
      await handle.sync();
      if (!patch) state.offset += written;
      state.updated = Date.now();
      await save(dir, state);
      res.json({ offset: state.offset });
    } finally {
      if (handle) await handle.close();
      busy.delete(dir);
    }
  });
  // Sealing only verifies a private recording. It never scans or delivers it.
  const seal = endpoint(async (req, res) => {
    const dir = location(req.user.id, req.params.id);
    if (busy.has(dir)) return res.status(409).json({ error: 'ההעלאה כבר בטיפול' });
    busy.add(dir);
    try {
      const state = await load(dir);
      const { size, name, mime, fields, sha256 } = req.body || {};
      if (!Number.isSafeInteger(size) || size < 1 || size !== state.offset ||
          typeof name !== 'string' || !name || name.length > 500 ||
          typeof mime !== 'string' || !mime || mime.length > 200 ||
          !fields || Array.isArray(fields) || typeof fields !== 'object' ||
          Object.entries(fields).some(([k, v]) => k.length > 100 || typeof v !== 'string' || v.length > 2000) ||
          typeof sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(sha256))
        return res.status(400).json({ error: 'פרטי סיום ההקלטה אינם תקינים' });
      const metadata = { name, size, mime, fields };
      if (state.sealed) {
        if (state.sealed !== sha256 || JSON.stringify(state.metadata) !== JSON.stringify(metadata))
          return res.status(409).json({ error: 'ההקלטה כבר נסגרה' });
        return res.json({ sealed: true });
      }
      if (!state.metadata.recording || state.result) return res.status(409).json({ error: 'זו אינה הקלטה פתוחה' });
      // MP4 and WAV encoders rewrite headers when they stop. Never send a
      // recording until its complete on-device bytes match the staged bytes.
      const digest = crypto.createHash('sha256');
      for await (const bytes of createReadStream(path.join(dir, 'data'))) digest.update(bytes);
      if (digest.digest('hex') !== sha256) return res.status(409).json({ error: 'בדיקת שלמות ההקלטה נכשלה' });
      state.metadata = metadata;
      state.sealed = sha256;
      state.updated = Date.now();
      await save(dir, state);
      res.json({ sealed: true });
    } finally { busy.delete(dir); }
  });
  const cancel = endpoint(async (req, res) => {
    const dir = location(req.user.id, req.params.id);
    if (busy.has(dir)) return res.status(409).json({ error: 'ההעלאה כבר בטיפול' });
    busy.add(dir);
    try {
      let state;
      try { state = await load(dir); } catch (e) { if (e.status !== 404 && e.status !== 410) throw e; }
      // Retain completed receipts: retries must never scan or send twice.
      if (!state?.result) {
        await quotaHooks?.release(req.user.id, req.params.id);
        await fs.rm(dir, { recursive: true, force: true });
      }
      res.json({ cancelled: !state?.result });
    } finally { busy.delete(dir); }
  });
  // Reuse the existing moderation/authorization route after transfer completes.
  async function prepare(req, res, next) {
    if (!req.body?.uploadSessionId) return next();
    let dir;
    try {
      dir = location(req.user.id, req.body.uploadSessionId);
      const state = await load(dir);
      if (state.result) return res.status(state.result.statusCode).json(state.result.data);
      if (busy.has(dir)) return res.status(202).json({ uploadProcessing: true });
      if (state.metadata.recording || state.offset !== state.metadata.size) return res.status(409).json({ error: 'ההעלאה טרם הושלמה' });
      busy.add(dir);
      res.once('finish', () => busy.delete(dir));
      req.body = { ...state.metadata.fields };
      req.storageQuotaReservation = state.id;
      req.file = { path: path.join(dir, 'data'), size: state.offset,
        originalname: state.metadata.name, mimetype: state.metadata.mime, resumable: true };
      const originalJson = res.json.bind(res);
      res.json = data => {
        const statusCode = res.statusCode;
        return (async () => {
          try {
            if (statusCode >= 500 || statusCode === 429) return originalJson(data);
            // Save before responding: a lost final response can be fetched without another scan/send.
            state.result = { statusCode, data };
            state.updated = Date.now();
            await save(dir, state);
            await fs.rm(path.join(dir, 'data'), { force: true });
            await quotaHooks?.release(req.user.id, state.id);
            return originalJson(data);
          } catch (_) {
            return res.status(503).end();
          } finally { busy.delete(dir); }
        })();
      };
      next();
    } catch (e) {
      if (dir) busy.delete(dir);
      res.status(e.status || 500).json({ error: e.status ? e.message : 'לא ניתן להשלים את ההעלאה' });
    }
  }
  async function cleanup() {
    for (const user of await fs.readdir(root).catch(() => [])) {
      const userDir = path.join(root, user);
      for (const id of await fs.readdir(userDir).catch(() => [])) {
        const dir = path.join(userDir, id);
        if (busy.has(dir)) continue;
        const stat = await fs.stat(path.join(dir, 'state.json')).catch(() => null);
        if (stat && Date.now() - stat.mtimeMs > TTL && !busy.has(dir)) {
          busy.add(dir);
          try {
            const state = JSON.parse(await fs.readFile(path.join(dir, 'state.json'), 'utf8'));
            if (Date.now() - state.updated <= TTL) continue;
            if (state.owner) await quotaHooks?.release(state.owner, state.id);
            await fs.rm(dir, { recursive: true, force: true });
          } finally { busy.delete(dir); }
        }
      }
    }
  }
  return { create, status, chunk, seal, cancel, prepare, cleanup, setQuotaHooks(hooks) { quotaHooks = hooks; } };
}

module.exports = { createResumableAttachments, CHUNK_BYTES };
