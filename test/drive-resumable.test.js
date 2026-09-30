'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { uploadResumable, CHUNK_BYTES } = require('../server/drive-resumable');
const { prepareBackupTransfer, clearBackupTransfer, recoverBackupTransfers } = require('../server/backup-transfer-job');

for (const mode of ['partial-chunk', 'lost-final-response', 'restart', 'expired']) {
  test(`Drive resumes from Google's acknowledged offset: ${mode}`, async t => {
    const root = await fs.mkdtemp(path.join(os.tmpdir(), 'drive-resume-'));
    t.after(() => fs.rm(root, { recursive: true, force: true }));
    const bytes = crypto.randomBytes(CHUNK_BYTES * 2 + 123);
    let saved = Buffer.alloc(0), starts = 0, faulted = false, restarted = false;
    const offsets = [];
    const result = { id: 'file-id', size: String(bytes.length) };
    const options = { root, ownerKey: 'owner-secret', metadata: { name: 'encrypted.bsv1' }, bytes,
      mimeType: 'application/octet-stream', sleep: async () => {},
      client: { getRequestHeaders: async () => new Headers({ Authorization: 'Bearer test' }) },
      fetchImpl: async (_url, req) => {
        if (req.method === 'POST') {
          starts++;
          return new Response(null, { status: 200, headers: { location: `https://www.googleapis.com/upload/drive/v3/files?upload_id=${starts}` } });
        }
        const range = req.headers.get('Content-Range');
        if (range.startsWith('bytes */')) {
          if (mode === 'restart' && !restarted) throw Object.assign(new Error('process stopped'), { permanent: true });
          if (saved.length === bytes.length) return Response.json(result);
          return new Response(null, { status: 308, headers: saved.length ? { range: `bytes=0-${saved.length-1}` } : {} });
        }
        const match = range.match(/^bytes (\d+)-(\d+)\/(\d+)$/);
        const offset = Number(match[1]);
        assert.equal(offset,saved.length);
        assert.ok(req.body.length <= CHUNK_BYTES);
        offsets.push(offset);
        if (!faulted && mode === 'expired') {
          faulted = true; return new Response(null,{status:404});
        }
        if (!faulted && mode === 'partial-chunk') {
          saved = Buffer.concat([saved,req.body.subarray(0,1024*1024)]);
          faulted = true; throw new TypeError('network lost');
        }
        saved = Buffer.concat([saved,req.body]);
        if (!faulted && mode === 'restart') {
          faulted = true; throw Object.assign(new Error('process stopped'), { permanent: true });
        }
        if (saved.length === bytes.length) {
          if (!faulted && mode === 'lost-final-response') {
            faulted = true; throw new TypeError('response lost');
          }
          return Response.json(result);
        }
        return new Response(null,{status:308,headers:{range:`bytes=0-${saved.length-1}`}});
      },
    };
    if (mode === 'restart') {
      await assert.rejects(uploadResumable(options),/process stopped/);
      restarted = true;
    }
    assert.deepEqual(await uploadResumable(options),result);
    assert.deepEqual(saved,bytes);
    assert.equal(starts,mode === 'expired' ? 2 : 1);
    if (mode === 'partial-chunk') assert.equal(offsets[1],1024*1024);
    assert.deepEqual(await uploadResumable({...options,fetchImpl:()=>assert.fail('completed upload repeated')}),result);
  });
}

test('encrypted backup preparation preserves exact bytes, nonce and id across retries', async t => {
  const root=await fs.mkdtemp(path.join(os.tmpdir(),'backup-spool-'));
  t.after(()=>fs.rm(root,{recursive:true,force:true}));
  const input={root,plain:Buffer.from('private media'),key:crypto.randomBytes(32),
    userId:'user',fileId:'file',associatedData:'user/file/server-v1'};
  const first=await prepareBackupTransfer(input);
  const resumed=await prepareBackupTransfer(input);
  assert.equal(resumed.backupId,first.backupId);
  assert.equal(resumed.createdAt,first.createdAt);
  assert.deepEqual(resumed.envelope,first.envelope);
  const recovered=[];
  await recoverBackupTransfers({query:async(sql,params)=>recovered.push({sql,params})},root);
  assert.equal(recovered.length,1);
  assert.deepEqual(recovered[0].params,['file','user']);
  assert.match(recovered[0].sql,/status='uploading'/);
  assert.equal((await fs.readFile(path.join(first.directory,'metadata.json'),'utf8')).includes(input.key.toString('base64')),false);
  await clearBackupTransfer(resumed);
  await assert.rejects(fs.stat(first.directory),{code:'ENOENT'});
});
