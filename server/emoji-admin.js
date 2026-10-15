'use strict';
const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const fail = (status, code) => Object.assign(new Error(code), { status, code });
function createEmojiAdmin(root) {
  const catalogPath = path.join(root, 'catalog.json');
  const registryPath = path.join(root, 'emoji-registry.json');
  const lockPath = path.join(root, '.emoji-admin.lock');
  async function read() {
    const [bytes, registryBytes] = await Promise.all([fs.readFile(catalogPath), fs.readFile(registryPath)]);
    const catalog = JSON.parse(bytes), registry = JSON.parse(registryBytes);
    const category = catalog.categories.find(c => c.id === 'user-emojis');
    if (!category || !Array.isArray(registry.items)) throw fail(503, 'INVALID_CATALOG');
    const hidden = new Set(category.removedIds || []), ids = new Set();
    const items = [];
    for (const item of registry.items) {
      if (!Number.isInteger(item.id) || item.id < 1 || item.id > 6400 || ids.has(item.id) ||
          typeof item.file !== 'string' || path.basename(item.file) !== item.file ||
          !/^[^/\\]+\.png$/i.test(item.file)) throw fail(503, 'INVALID_REGISTRY');
      ids.add(item.id);
      const stat = await fs.lstat(path.join(root, 'emojis', item.file));
      if (!stat.isFile() || stat.isSymbolicLink()) throw fail(503, 'INVALID_ASSET');
      items.push({ id: item.id, name: String(item.label || item.file), hidden: hidden.has(item.id),
        image: `/betshuva-app/api/expressions/emoji/${item.id}` });
    }
    return { catalog, category, items, revision: crypto.createHash('sha256').update(bytes).update(registryBytes).digest('hex') };
  }
  async function inventory() { const { items, revision } = await read(); return { items, revision }; }
  async function setHidden(id, hidden, revision) {
    if (!Number.isInteger(id) || typeof hidden !== 'boolean' || !/^[a-f0-9]{64}$/.test(revision || '')) throw fail(400, 'INVALID_CHANGE');
    let lock, temporary;
    try { lock = await fs.open(lockPath, 'wx', 0o600); }
    catch (e) { if (e.code === 'EEXIST') throw fail(409, 'EDIT_BUSY'); throw e; }
    try {
      const current = await read();
      if (current.revision !== revision) throw fail(409, 'CATALOG_CHANGED');
      if (!current.items.some(item => item.id === id)) throw fail(404, 'UNKNOWN_EMOJI');
      const removed = new Set(current.category.removedIds || []);
      if (hidden) removed.add(id); else removed.delete(id);
      current.category.removedIds = [...removed].sort((a,b) => a-b);
      temporary = path.join(root, `.emoji-catalog-${crypto.randomUUID()}.tmp`);
      const handle = await fs.open(temporary, 'wx', 0o644);
      try { await handle.writeFile(JSON.stringify(current.catalog, null, 2) + '\n'); await handle.sync(); }
      finally { await handle.close(); }
      await fs.rename(temporary, catalogPath); temporary = null;
      const directory = await fs.open(root, 'r');
      try { await directory.sync(); } finally { await directory.close(); }
      return inventory();
    } finally {
      if (temporary) await fs.unlink(temporary).catch(() => {});
      await lock.close(); await fs.unlink(lockPath);
    }
  }
  return { inventory, setHidden };
}
function registerEmojiAdmin(app, { root, adminAuth, origin = 'https://betshuva.com' }) {
  const library = createEmojiAdmin(root);
  const edit = (req,res,next) => req.adminPerm === 'edit' ? next() : res.status(403).json({code:'EDIT_REQUIRED'});
  const error = (res,e) => res.status(e.status || 503).json({code:e.code && e.status ? e.code : 'CATALOG_UNAVAILABLE'});
  app.get('/api/admin/emojis', adminAuth, edit, async (_req,res) => {
    res.set('Cache-Control','no-store');
    try { res.json(await library.inventory()); } catch(e) { error(res,e); }
  });
  app.put('/api/admin/emojis/:id', adminAuth, edit, async (req,res) => {
    res.set('Cache-Control','no-store');
    // Browser writes require the same HTTPS origin plus explicit bearer auth.
    // Cookies, URL tokens and arbitrary origins are never authentication here.
    if (req.get('Origin') !== origin) return res.status(403).json({code:'ORIGIN_REQUIRED'});
    if (!req.is('application/json') || !/^[1-9][0-9]{0,3}$/.test(req.params.id)) return res.status(400).json({code:'INVALID_CHANGE'});
    try { res.json(await library.setHidden(Number(req.params.id),req.body?.hidden,req.body?.revision)); }
    catch(e) { error(res,e); }
  });
}
module.exports = { createEmojiAdmin, registerEmojiAdmin };
