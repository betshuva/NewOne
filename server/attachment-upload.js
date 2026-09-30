'use strict';
const multer = require('multer');
const path = require('node:path');
const os = require('node:os');
const fs = require('node:fs/promises');
const { createWriteStream } = require('node:fs');
const { pipeline } = require('node:stream/promises');
const { randomUUID } = require('node:crypto');
const { createResumableAttachments } = require('./resumable-attachments');
const resumableAttachments = createResumableAttachments({
  root: path.join(__dirname, '..', '.transfer-state', 'device'),
});

// Keep even incomplete/aborted unlimited video uploads off the Node heap.
const storage = {
  _handleFile(req, file, callback) {
    (async () => {
      const directory = path.join(os.tmpdir(), 'betshuva-attachments');
      await fs.mkdir(directory, { recursive: true });
      const filename = path.join(directory, randomUUID());
      const output = createWriteStream(filename, { flags: 'wx', mode: 0o600 });
      const abort = () => file.stream.destroy(new Error('Upload aborted'));
      req.once('aborted', abort);
      try {
        if (req.aborted) abort();
        await pipeline(file.stream, output);
        callback(null, { path: filename, size: output.bytesWritten });
      } catch (error) {
        await fs.rm(filename, { force: true }).catch(() => {});
        callback(error);
      } finally { req.removeListener('aborted', abort); }
    })().catch(callback);
  },
  _removeFile(req, file, callback) {
    fs.rm(file.path, { force: true }).then(() => callback(null), callback);
  },
};
const attachmentUpload = multer({ storage });
const single = attachmentUpload.single.bind(attachmentUpload);
attachmentUpload.single = field => {
  const multipart = single(field);
  return (req, res, next) => req.body?.uploadSessionId
    ? resumableAttachments.prepare(req, res, next) : multipart(req, res, next);
};
function cleanAttachment(req, res, next) {
  const cleanup = () => {
    if (req.file?.path && !req.file.resumable) fs.rm(req.file.path, { force: true }).catch(() => {});
  };
  res.once('finish', cleanup);
  res.once('close', cleanup);
  next();
}
module.exports = { attachmentUpload, cleanAttachment, resumableAttachments };
