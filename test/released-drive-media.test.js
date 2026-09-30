'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const vm = require('node:vm');
const crypto = require('node:crypto');
const { encryptBuffer, decryptBuffer } = require('../server/media-backup-crypto');
const { createVaultKey, wrapVaultKey, unwrapVaultKey } = require('../server/backup-vault-key');

for (const centralStorage of [false, true]) test(`${centralStorage ? 'central' : 'personal'} released media keeps its URL, decrypts on demand and supports video byte ranges`, async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'drive-serving-'));
  const previous = process.env.BACKUP_TOKEN_ENCRYPTION_KEY;
  process.env.BACKUP_TOKEN_ENCRYPTION_KEY = 'test-only-drive-delivery-master-key-longer-than-32-bytes';
  try {
    const plain = Buffer.from('0123456789video');
    const key = createVaultKey();
    const associatedData = centralStorage ? 'central-v1/owner/media' : 'media-owner';
    const encrypted = encryptBuffer(plain, key, associatedData);
    const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
    const row = { id: 'media', user_id: 'owner', mime_type: 'video/mp4', file_size: plain.length,
      content_sha256: hash(plain), remote_file_id: 'remote', encrypted_sha256: hash(encrypted.ciphertext),
      encryption_metadata: { ...encrypted, associatedData }, central_storage: centralStorage,
      encrypted_data_key: wrapVaultKey(key,'owner'), encrypted_refresh_token: 'encrypted-token' };
    const source = await fs.readFile(require.resolve('../server/index'), 'utf8');
    const start = source.indexOf('const serveReleasedDriveMedia = async');
    const end = source.indexOf('// Baseline protection for all API routes.',start);
    const mounts = new Map();
    let downloads = 0;
    const errors = [];
    vm.runInNewContext(source.slice(start,end), {
      app: { use(mount, handler) { if (typeof mount === 'string') mounts.set(mount,handler); } },
      publicStatic: () => () => {}, __dirname: root, path, fs, crypto, Buffer, process,
      UPLOAD_ROOT: root, UPLOAD_PUBLIC_BASE: '/betshuva-app/uploads',
      DRIVE_MEDIA_CACHE_ROOT: path.join(root,'cache'), driveMediaLoads: new Map(),
      getPool: async () => ({ query: async sql => {
        if (sql.includes('deleted_media_sources')) return { rows: [] };
        if (sql.includes('SELECT moderation_status')) return { rows: [{ moderation_status: 'approved' }] };
        assert.doesNotMatch(sql, /s\.enabled=TRUE/, 'opting out of future backups must not break existing media');
        return { rows: [row] };
      } }),
      centralDrive: { ...require('../server/central-drive'), deliveryRecord: async () => centralStorage ? row : null },
      personalDrive: { decryptRefreshToken: () => 'token', downloadAppDataFile: async () => {
        downloads++; return encrypted.ciphertext;
      } },
      unwrapVaultKey, decryptBackupBuffer: decryptBuffer,
      readDriveMediaCacheMetadata: async () => ({ lastAccessAt: Date.now(), accessCount: 1 }),
      writeDriveMediaCacheMetadata: async () => {}, driveMediaCacheTtl: () => 60000,
      clearExpiredDriveMediaCache: async () => {}, console: { error(...args) { errors.push(args.join(' ')); } },
    });
    async function request(mount, method = 'GET', range) {
      const response = { code: 200, headers: {}, body: null,
        status(code) { this.code = code; return this; },
        set(name,value) { if (typeof name === 'object') Object.assign(this.headers,name);
          else this.headers[name]=value; return this; },
        end(bytes) { this.body=bytes; return this; }, json(body) { this.body=body; return this; } };
      await mounts.get(mount)({ method, path: '/owner/video.mp4', headers: { range } }, response,
        () => assert.fail('Cloud-only media must not fall through to a missing local file'));
      return response;
    }
    for (const mount of ['/betshuva-app/uploads','/uploads']) {
      const full = await request(mount);
      assert.equal(full.code,200,errors.join('\n')); assert.deepEqual(full.body,plain);
      const head = await request(mount,'HEAD');
      assert.equal(head.headers['Content-Length'],String(plain.length));
      assert.equal(head.body,undefined);
      for (const [range,start,end] of [['bytes=2-5',2,5],['bytes=10-',10,14],['bytes=-5',10,14]]) {
        const part = await request(mount,'GET',range);
        assert.equal(part.code,206);
        assert.equal(part.headers['Content-Range'],`bytes ${start}-${end}/${plain.length}`);
        assert.deepEqual(part.body,plain.subarray(start,end+1));
      }
      for (const range of ['bytes=-0','bytes=99-','bytes=8-2','bytes=-'])
        assert.equal((await request(mount,'GET',range)).code,416);
    }
    assert.equal(downloads,1,'repeat requests use the temporary encrypted cache');
    row.content_sha256 = 'bad';
    assert.equal((await request('/uploads')).code,503,'corrupt restored content must never be served');
    await assert.rejects(fs.stat(path.join(root,'owner/video.mp4')), { code: 'ENOENT' });
  } finally {
    if (previous === undefined) delete process.env.BACKUP_TOKEN_ENCRYPTION_KEY;
    else process.env.BACKUP_TOKEN_ENCRYPTION_KEY = previous;
    await fs.rm(root,{recursive:true,force:true});
  }
});
