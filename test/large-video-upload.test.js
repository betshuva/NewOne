'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { once } = require('node:events');
const fs = require('node:fs/promises');
const { attachmentUpload, cleanAttachment } = require('../server/attachment-upload');
const { sourceHash, sourceBlob, uploadHeader } = require('../server/upload-file-source');

test('video above former limits streams to disk and is cleaned after response', async t => {
  const parse = attachmentUpload.single('file');
  let temporary;
  const server = http.createServer((req, res) => cleanAttachment(req, res, () => parse(req, res, async error => {
    if (error) { res.statusCode = 500; res.end(error.message); return; }
    temporary = req.file.path;
    assert.equal(req.file.buffer, undefined);
    const header = await uploadHeader(req.file);
    const hash = await sourceHash(req.file);
    const blob = await sourceBlob(req.file, 'video/mp4');
    res.end(JSON.stringify({ size: req.file.size, blobSize: blob.size,
      signature: header.subarray(4, 8).toString(), hashLength: hash.length }));
  })));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const size = 201 * 1024 * 1024;
  const head = Buffer.from('--video-test\r\nContent-Disposition: form-data; name="file"; filename="large.mp4"\r\nContent-Type: video/mp4\r\n\r\n');
  const tail = Buffer.from('\r\n--video-test--\r\n');
  const req = http.request({ hostname:'127.0.0.1', port:server.address().port,
    method:'POST', headers:{ 'Content-Type':'multipart/form-data; boundary=video-test',
      'Content-Length': head.length + size + tail.length } });
  const response = once(req, 'response');
  req.write(head);
  const chunk = Buffer.alloc(1024 * 1024);
  chunk.write('ftyp', 4);
  for (let left = size; left > 0; left -= chunk.length) {
    if (!req.write(chunk.subarray(0, Math.min(left, chunk.length)))) await once(req, 'drain');
  }
  req.end(tail);
  const [res] = await response;
  let body = '';
  for await (const chunk of res) body += chunk;
  assert.equal(res.statusCode, 200);
  assert.deepEqual(JSON.parse(body), {size, blobSize:size, signature:'ftyp', hashLength:64});
  for (let i=0; i<20; i++) {
    if (!await fs.stat(temporary).then(()=>true,()=>false)) break;
    await new Promise(resolve=>setTimeout(resolve,10));
  }
  await assert.rejects(fs.stat(temporary), {code:'ENOENT'});
});
