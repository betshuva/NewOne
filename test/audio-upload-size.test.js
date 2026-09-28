'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const http = require('node:http');
const { once } = require('node:events');
const multer = require('multer');
const { MAX_AUDIO_BYTES } = require('../server/audio-moderation');

test('real multipart parser accepts 150MB inclusively and rejects one byte more', async t => {
  const source = fs.readFileSync(require.resolve('../server/index.js'), 'utf8');
  const start = source.indexOf('const upload = multer(');
  const end = source.indexOf('const VIDEO_MODERATION_URL', start);
  const upload = vm.runInNewContext(source.slice(start, end) + ';upload', { multer, MAX_AUDIO_BYTES });
  const parse = upload.single('file');
  const server = http.createServer((req, res) => parse(req, res, error => {
    res.statusCode = error ? 413 : 200;
    res.end(JSON.stringify(error ? { code: error.code } : { size: req.file.size }));
  }));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  for (const size of [MAX_AUDIO_BYTES, MAX_AUDIO_BYTES + 1]) {
    const head = Buffer.from('--audio-boundary\r\nContent-Disposition: form-data; name="file"; filename="large.mp3"\r\nContent-Type: audio/mpeg\r\n\r\n');
    const tail = Buffer.from('\r\n--audio-boundary--\r\n');
    const req = http.request({ hostname: '127.0.0.1', port: server.address().port,
      method: 'POST', headers: { 'Content-Type': 'multipart/form-data; boundary=audio-boundary',
        'Content-Length': head.length + size + tail.length } });
    const response = once(req, 'response');
    req.write(head);
    const chunk = Buffer.alloc(1024 * 1024);
    for (let remaining = size; remaining > 0;) {
      const count = Math.min(chunk.length, remaining);
      if (!req.write(chunk.subarray(0, count))) await once(req, 'drain');
      remaining -= count;
    }
    req.end(tail);
    const [res] = await response;
    const chunks = [];
    for await (const chunk of res) chunks.push(chunk);
    const body = JSON.parse(Buffer.concat(chunks));
    assert.equal(res.statusCode, size === MAX_AUDIO_BYTES ? 200 : 413);
    if (size === MAX_AUDIO_BYTES) assert.equal(body.size, size);
    else assert.equal(body.code, 'LIMIT_FILE_SIZE');
  }
});
