'use strict';

const stages = new Set(['handle', 'fresh_file', 'snapshot', 'fallback', 'chunk_read']);
const codes = new Set(['started', 'ok', 'unsupported', 'unavailable', 'not_file',
  'name_mismatch', 'unknown', 'StateError', 'TypeError', 'RangeError',
  'NotReadableError', 'NotAllowedError', 'SecurityError', 'NotFoundError',
  'AbortError', 'InvalidStateError', 'NotSupportedError']);
const extensions = new Set(['docx', 'xlsx', 'pdf', 'jpg', 'jpeg', 'png', 'webp',
  'gif', 'mp3', 'aac', 'm4a', 'ogg', 'wav', 'mp4', 'webm', 'mov', 'unknown']);

function registerAttachmentReadFailures(app, { auth, rateLimit, log = console.warn }) {
  app.post('/api/attachment-read-failures', auth, rateLimit, (req, res) => {
    const data = req.body || {};
    if (data.origin !== 'clipboard' || !extensions.has(data.extension) ||
        !Number.isSafeInteger(data.fileSize) || data.fileSize < 0 ||
        !Number.isInteger(data.batchSize) || data.batchSize < 1 || data.batchSize > 10000 ||
        !Number.isInteger(data.index) || data.index < 0 || data.index >= Math.min(data.batchSize, 100) ||
        !Array.isArray(data.events) || data.events.length < 1 || data.events.length > 12 ||
        data.events.some(event => !event || !stages.has(event.stage) || !codes.has(event.code))) {
      return res.status(400).json({ error: 'Invalid read diagnostics' });
    }
    // Whitelist fields and codes. Never log raw request bodies, file names,
    // paths, tokens, error messages, stack traces or the complete user agent.
    const ua = String(req.headers['user-agent'] || '');
    const browser = /\b(Edg)\/(\d{1,3})\b/.exec(ua) ||
      /\b(Chrome|Firefox)\/(\d{1,3})\b/.exec(ua) ||
      /\b(Version)\/(\d{1,3})\b/.exec(ua);
    const platform = /Windows/.test(ua) ? 'windows' : /Android/.test(ua) ? 'android' :
      /iPhone|iPad/.test(ua) ? 'ios' : /Macintosh/.test(ua) ? 'macos' :
      /Linux/.test(ua) ? 'linux' : 'unknown';
    log('[attachment-read-failure]', JSON.stringify({
      userId: req.user.id, origin: 'clipboard',
      extension: data.extension, fileSize: data.fileSize,
      batchSize: data.batchSize, index: data.index,
      events: data.events.map(({ stage, code }) => ({ stage, code })),
      browser: browser ? `${browser[1]}/${browser[2]}` : 'unknown', platform,
    }));
    res.set('Cache-Control', 'no-store');
    res.status(202).json({ recorded: true });
  });
}

module.exports = { registerAttachmentReadFailures };
