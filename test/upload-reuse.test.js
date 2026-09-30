'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const crypto = require('node:crypto');
const { acquireUploadLock, findReusableUpload } = require('../server/upload-reuse');
const { contentAllowedByFilter, normalizeContentFilter } = require('../server/content-filter-policy');
const { visuallyEquivalent } = require('../server/visual-fingerprint');

const source = fs.readFileSync(require.resolve('../server/index.js'), 'utf8');
const routeStart = source.indexOf("app.post('/api/upload',");
const routeEnd = source.indexOf('// ── Groups: list mine', routeStart);
assert.ok(routeStart > 0 && routeEnd > routeStart);
const VERSION = 'test-current';
const realResolveAllowedUpload = vm.runInNewContext(source.slice(
  source.indexOf('const ALLOWED_TYPES ='), source.indexOf('const upload = multer(')) +
  ';resolveAllowedUpload', { Buffer, uploadHeader: require('../server/upload-file-source').uploadHeader, path: require('node:path'),
  probeWebmMime: require('../server/audio-moderation').probeWebmMime });
const ALL = { text: true, video: true, nonHumanImages: true,
  men: true, women: true, children: true };
const MEN = { category: 'men', detectedCategories: ['men'], uncertain: false };
const OBJECT = { category: 'nonHumanImages', detectedCategories: ['nonHumanImages'], uncertain: false };
const FINGERPRINT = { algorithm: 'ahash16+dhash16-v1', aspect: 0.666667,
  averageHash: '0123456789abcdef', differenceHash: 'fedcba9876543210' };
let fixtureId = 0;

function harness({ classification = MEN, result, scanDelay = false,
  fingerprint = null, trustedBuiltinExpression = false, conversionError = null,
  audioDuration = 10, onScan, realSenderGuard = false, realUploadResolver = false } = {}) {
  const activeUploadFileIds = new Set();
  const state = { files: [], queries: [], blobs: [], scans: 0, audits: [], reports: [],
    pending: [], gifs: [], senderReads: [], recipientReads: [], senderAllowed: true,
    recipientFilter: { ...ALL }, groupFilter: { ...ALL }, member: { role: 'member', send_permission: 'all' },
    failNextScan: false, owner: `owner-${++fixtureId}`, audioConversions: [], audioProbes: [] };
  const clone = value => JSON.parse(JSON.stringify(value));
  const isExempt = details => details?.source === 'builtin-expression' || details?.scanSkipped === true;
  const assertScannedOnly = statement => {
    assert.match(statement, /moderation_details->>'source' IS DISTINCT FROM 'builtin-expression'/);
    assert.match(statement, /moderation_details->>'scanSkipped' IS DISTINCT FROM 'true'/);
  };
  const pool = { async query(sql, values = []) {
    state.queries.push({ sql, values });
    const statement = sql.trim();
    if (statement === 'SELECT short_id FROM users WHERE id=$1') {
      assert.deepEqual(values, [state.owner]);
      return { rows: [{ short_id: '742' }] };
    }
    if (statement.startsWith('SELECT moderation_details FROM stored_files')) {
      assertScannedOnly(statement);
      const found = [...state.files].reverse().find(file =>
        file.content_sha256 === values[0] && file.file_type === values[1] &&
        ['approved', 'rejected'].includes(file.moderation_status) &&
        file.moderation_details?.moderationVersion === values[2] &&
        file.moderation_details.pending !== true && !isExempt(file.moderation_details));
      return { rows: found ? [{ moderation_details: clone(found.moderation_details) }] : [] };
    }
    if (statement.startsWith('SELECT moderation_details,visual_fingerprint FROM stored_files')) {
      assertScannedOnly(statement);
      return { rows: [...state.files].reverse().filter(file =>
        file.file_type === 'image' && file.visual_fingerprint &&
        ['approved', 'rejected'].includes(file.moderation_status) &&
        file.moderation_details?.moderationVersion === values[0] &&
        !isExempt(file.moderation_details) &&
        Math.abs(file.visual_fingerprint.aspect - values[1]) <= 0.01).map(file => ({
          moderation_details: clone(file.moderation_details),
          visual_fingerprint: clone(file.visual_fingerprint),
        })) };
    }
    if (statement.startsWith('SELECT id,public_url FROM stored_files')) {
      assertScannedOnly(statement);
      assert.match(statement, /\$8::boolean OR/);
      const found = [...state.files].reverse().find(file =>
        file.user_id === values[0] && file.content_sha256 === values[1] &&
        file.file_type === values[2] && file.mime_type === values[3] && file.file_size === values[4] &&
        file.moderation_status === 'approved' && !file.content_purged_at && !file.released_at &&
        file.moderation_details?.moderationVersion === values[5] &&
        file.moderation_details.pending !== true && file.moderation_details.blocked !== true &&
        (values[7] === true || !isExempt(file.moderation_details)) &&
        (file.context_type === 'listing') === values[6] && file.public_url);
      return { rows: found ? [{ id: found.id, public_url: found.public_url }] : [] };
    }
    if (statement.startsWith('INSERT INTO stored_files')) {
      const names = ['user_id', 'original_name', 'storage_path', 'public_url', 'mime_type',
        'file_type', 'file_size', 'context_type', 'context_id', 'content_sha256', 'visual_fingerprint'];
      const file = { id: values[11], moderation_status: 'pending' };
      assert.deepEqual([...values.slice(12, 14)], [null, null]);
      file.client_upload_id = values[14];
      assert.ok(activeUploadFileIds.has(file.id), 'reserve ownership before inserting the file');
      names.forEach((name, index) => { file[name] = values[index]; });
      if (file.visual_fingerprint) file.visual_fingerprint = JSON.parse(file.visual_fingerprint);
      state.files.push(file);
      return { rows: [{ id: file.id }] };
    }
    if (statement.startsWith('UPDATE stored_files')) {
      const parameterStatus = statement.includes('moderation_status=$1');
      const valueIndex = parameterStatus ? 1 : 0;
      const file = state.files.find(file => file.id === values[valueIndex + 1] ||
        file.public_url === values[valueIndex + 1]);
      assert.ok(file, 'updates must target the request file');
      file.moderation_details = JSON.parse(values[valueIndex]);
      if (parameterStatus) file.moderation_status = values[0];
      else if (statement.includes("moderation_status='approved'")) file.moderation_status = 'approved';
      else if (statement.includes("moderation_status='rejected'")) file.moderation_status = 'rejected';
      return { rows: [{ blocked_content_expires_at: '2026-09-18T10:02:00Z' }] };
    }
    if (statement.startsWith('INSERT INTO pending_scans')) {
      const pending = { id: `pending-${state.pending.length + 1}`, values: [...values] };
      state.pending.push(pending);
      return { rows: [{ id: pending.id }] };
    }
    if (statement.startsWith('SELECT gm.role')) return { rows: state.member ? [state.member] : [] };
    if (statement.startsWith('INSERT INTO shared_gifs')) {
      const file = state.files.find(file => file.public_url === values[3]);
      assert.ok(file);
      let gif = state.gifs.find(gif => gif.fileId === file.id);
      if (!gif) { gif = { id: `gif-${state.gifs.length + 1}`, fileId: file.id }; state.gifs.push(gif); }
      Object.assign(gif, { title: values[1], tags: values[2] });
      return { rows: [{ id: gif.id }] };
    }
    throw new Error('Unexpected upload query: ' + statement);
  } };
  let handler;
  const scan = async () => {
    state.scans++;
    await onScan?.({ state, activeUploadFileIds });
    if (scanDelay) await new Promise(resolve => setImmediate(resolve));
    if (state.failNextScan) { state.failNextScan = false; throw new Error('scan failed'); }
    return clone(result || { blocked: false, classification, faces: [] });
  };
  vm.runInNewContext(source.slice(routeStart, routeEnd), {
    reserveMultipartStorage() {},
    storageQuota: { reserve: async () => {}, release: async () => {}, quotaError: error => error },
    path: require('node:path'), UPLOAD_ROOT: '/test-uploads',
    fs: { unlink: async () => {} },
    ...require('./helpers/system-audit-stubs'),
    app: { post(_route, ...handlers) { handler = handlers.at(-1); } },
    auth() {}, uploadRateLimit() {}, cleanAttachment() {}, attachmentUpload: { single() {} },
    ...require('../server/upload-file-source'),
    MAX_RECORDING_INPUT_BYTES: require('../server/audio-moderation').MAX_RECORDING_INPUT_BYTES,
    BLOCKED_TYPES: [], MODERATION_CACHE_VERSION: VERSION, VIDEO_SCAN_VERSION: VERSION, SCAN_BOT_ID: 'scan-bot',
    approvedAudioResult: vm.runInNewContext(source.slice(source.indexOf('function approvedAudioResult('),
      source.indexOf('// Legacy queued recordings')) + ';approvedAudioResult'),
    normalizeUploadFileName: value => value,
    resolveAllowedUpload: realUploadResolver ? realResolveAllowedUpload : file => ({ dbType: file.mimetype.startsWith('audio/') ? 'audio'
      : file.mimetype.startsWith('video/') ? 'video' : 'image',
      mime: file.mimetype, maxMB: 10 }),
    probeAudio: async (buffer, name) => {
      state.audioProbes.push({ buffer, name }); return { durationSeconds: audioDuration };
    },
    convertRecordedAudio: async (buffer, name, type) => {
      state.audioConversions.push({ buffer, name, type });
      if (conversionError) throw Object.assign(new Error('test conversion failure'), { code: conversionError });
      const converted = Buffer.from('encoded MP3 recording');
      return { buffer: converted, originalname: name.replace(/\.[^.]+$/, '.mp3'),
        mimetype: 'audio/mpeg', size: converted.length, durationSeconds: audioDuration };
    },
    shortenCapturedFileName: require('../server/user-short-id').shortenCapturedFileName,
    crypto, getPool: async () => pool, acquireUploadLock, findReusableUpload, activeUploadFileIds,
    isTrustedBuiltinExpression: async () => trustedBuiltinExpression,
    builtinExpressionResult: vm.runInNewContext(source.slice(
      source.indexOf('function builtinExpressionResult()'),
      source.indexOf('// ── Firebase Cloud Messaging')) + ';builtinExpressionResult'),
    createVisualFingerprint: async () => fingerprint, visuallyEquivalent,
    teenContactAllowed: async () => true,
    async getEffectiveRecipientFilter(_pool, recipient, owner) {
      state.recipientReads.push({ recipient, owner });
      return { isContact: true, filter: state.recipientFilter };
    },
    getGroupContentFilter: async () => state.groupFilter,
    async uploadToBlob(_buffer, key) { state.blobs.push(key); return `/uploads/${key}`; },
    scanImage: scan, recordProviderCheck: async () => {},
    saveAuditScanPreview: async () => null,
    async assertSenderMediaAllowed(_pool, options) {
      state.senderReads.push(options);
      if (realSenderGuard) return require('../server/sender-content-filter').assertSenderMediaAllowed(_pool, options);
      if (!state.senderAllowed) throw Object.assign(new Error('sender blocked'), {
        code: 'SENDER_CONTENT_FILTERED',
      });
    },
    contentAllowedByFilter, normalizeContentFilter,
    async recordFilterDecision(_pool, options) { state.audits.push(options); },
    notifyDestinationFilterBlock: async () => {},
    notifyRejectedSend: async () => {},
    scanGoogleObjectLocalization: async () => ({ available: false }),
    scanGoogleFaceDetection: async () => ({ available: false }),
    async saveScanBotReport(_pool, owner, file, url, details, status) {
      const report = { owner, file, url, details, status };
      state.reports.push(report); return report;
    },
    requestPendingScanRetry() {}, logActivity() {}, console: { log() {}, error() {}, warn() {} },
  });
  return { state, activeUploadFileIds, async upload({ body = {}, owner = state.owner, name = 'photo.png',
    bytes = 'same content', mime = 'image/png', reportedSize } = {}) {
    const buffer = Buffer.from(bytes);
    const res = { statusCode: 200, status(code) { this.statusCode = code; return this; },
      json(value) { this.body = clone(value); return this; } };
    await handler({ user: { id: owner }, body, ip: '127.0.0.1',
      file: { buffer, originalname: name, mimetype: mime, size: reportedSize ?? buffer.length } }, res);
    return res;
  } };
}

test('live scans stay owned until completion, including errors', async () => {
  const api = harness({ onScan({ state, activeUploadFileIds }) {
    assert.equal(activeUploadFileIds.size, 1);
    assert.ok(activeUploadFileIds.has(state.files.at(-1).id));
  } });
  assert.equal((await api.upload()).statusCode, 200);
  assert.equal(api.activeUploadFileIds.size, 0);
  api.state.failNextScan = true;
  assert.equal((await api.upload({ bytes: 'different file' })).statusCode, 500);
  assert.equal(api.activeUploadFileIds.size, 0);
});

test('uncached videos enter the durable queue without scanning inside the upload request', async () => {
  const api = harness();
  const response = await api.upload({ name: 'clip.mp4', mime: 'video/mp4',
    bytes: '0000ftypisom', body: { toUserId: 'friend' } });
  assert.equal(response.statusCode, 200);
  assert.equal(response.body.status, 'pending');
  assert.equal(api.state.scans, 0);
  assert.equal(api.state.pending.length, 1);
  assert.equal(api.state.pending[0].values[1], 'friend');
  assert.equal(api.state.files[0].moderation_status, 'pending');
  assert.equal(api.state.files[0].moderation_details.pending, true);
  assert.equal(api.activeUploadFileIds.size, 0);
});

test('pending uploads retain a bounded client identity for owner history reconciliation', async () => {
  for (const key of ['uploading_group_123_1', 'uploading_group_123_2', '', '<invalid>', 'x'.repeat(161)]) {
    const api = harness();
    const response = await api.upload({ name: 'same.mp4', mime: 'video/mp4',
      bytes: '0000ftypisom', body: { groupId: 'group', clientUploadId: key } });
    assert.equal(response.statusCode, 200);
    assert.equal(response.body.status, 'pending');
    assert.equal(api.state.files[0].client_upload_id,
      key.startsWith('uploading_') ? key : null);
  }
});

test('WebM audio selected as video is stored and returned as audio without a video scan', async () => {
  const api = harness({ realUploadResolver: true });
  const bytes = fs.readFileSync(require.resolve('./fixtures/webm-audio.webm'));
  for (const mime of ['video/webm', 'application/octet-stream', 'audio/webm']) {
    const response = await api.upload({ name: 'recording.webm', mime, bytes });
    assert.equal(response.statusCode, 200);
    assert.equal(response.body.fileType, 'audio');
    assert.ok(response.body.url);
    assert.equal(api.state.files.at(-1).moderation_status, 'approved');
  }
  assert.equal(api.state.audioProbes.length, 3);
  assert.equal(api.state.pending.length, 0);
  assert.equal(api.state.scans, 0);
  assert.equal(api.state.files[0].file_type, 'audio');
  assert.equal(api.state.files[0].mime_type, 'audio/webm');
});

test('a WebM containing video still enters video scanning even when declared audio', async () => {
  const api = harness({ realUploadResolver: true });
  const bytes = fs.readFileSync(require.resolve('./fixtures/webm-video.webm'));
  for (const name of ['clip.webm', 'disguised.mp3']) {
    const response = await api.upload({ name, mime: 'audio/webm', bytes });
    assert.equal(response.statusCode, 200);
    assert.equal(response.body.fileType, 'video');
    assert.equal(response.body.status, 'pending');
  }
  assert.equal(api.state.audioProbes.length, 0);
  assert.equal(api.state.pending.length, 2);
});

test('unreadable WebM is rejected before storing or queueing it', async () => {
  const api = harness({ realUploadResolver: true });
  const response = await api.upload({ name: 'broken.webm', mime: 'video/webm',
    bytes: Buffer.from([0x1a, 0x45, 0xdf, 0xa3, 0x00]) });
  assert.equal(response.statusCode, 400);
  assert.equal(response.body.code, 'INVALID_WEBM_CONTAINER');
  assert.equal(api.state.files.length, 0);
  assert.equal(api.state.pending.length, 0);
});

test('detected WebM audio accepts duration beyond two minutes', async () => {
  const api = harness({ realUploadResolver: true, audioDuration: 121 });
  const response = await api.upload({ name: 'recording.webm', mime: 'video/webm',
    bytes: fs.readFileSync(require.resolve('./fixtures/webm-audio.webm')) });
  assert.equal(response.statusCode, 200);
  assert.equal(response.body.fileType, 'audio');
  assert.equal(api.state.files.length, 1);
});

test('repeat upload reuses approved owner file and preserves a renamed library entry', async () => {
  const api = harness();
  const first = await api.upload();
  assert.equal(first.statusCode, 200);
  api.state.files[0].original_name = 'השם שבחרתי.png';
  const before = JSON.stringify(api.state.files[0]);
  const again = await api.upload({ name: 'another-name.png', body: { toUserId: 'friend' } });
  assert.equal(again.statusCode, 200);
  assert.equal(again.body.url, first.body.url);
  assert.equal(api.state.blobs.length, 1);
  assert.equal(api.state.files.length, 1);
  assert.equal(api.state.scans, 1);
  assert.equal(JSON.stringify(api.state.files[0]), before);
  assert.equal(api.state.senderReads.length, 2, 'each request reevaluates sender restrictions');
  assert.equal(api.state.recipientReads.length, 1);
  assert.equal(api.state.senderReads[1].contextId, 'friend');
  api.state.files[0].released_at = '2026-09-18T10:00:00Z';
  const local = await api.upload();
  assert.equal(local.statusCode, 200);
  assert.notEqual(local.body.url, first.body.url,
    'a fresh upload must retain available bytes instead of depending on a cloud-only file');
  assert.equal(api.state.blobs.length, 2);
  assert.equal(api.state.files[0].original_name, 'השם שבחרתי.png');
});

test('simultaneous matching uploads create one blob and scan; another owner gets a separate file', async () => {
  const api = harness({ scanDelay: true });
  const results = await Promise.all([api.upload(), api.upload(), api.upload()]);
  assert.ok(results.every(result => result.statusCode === 200));
  assert.equal(new Set(results.map(result => result.body.url)).size, 1);
  assert.equal(api.state.blobs.length, 1);
  assert.equal(api.state.files.length, 1);
  assert.equal(api.state.scans, 1);
  const other = await api.upload({ owner: 'other-owner' });
  assert.equal(other.statusCode, 200);
  assert.notEqual(other.body.url, results[0].body.url);
  assert.equal(api.state.files.length, 2);
});

test('scan failure releases matching-upload queue without reusing an incomplete file', async () => {
  const api = harness({ scanDelay: true });
  api.state.failNextScan = true;
  const [failed, next] = await Promise.all([api.upload(), api.upload()]);
  assert.equal(failed.statusCode, 500);
  assert.equal(next.statusCode, 200);
  assert.equal(api.state.files[0].moderation_status, 'pending');
  assert.equal(api.state.files[1].moderation_status, 'approved');
  assert.equal(api.state.blobs.length, 2);
});

test('reused files still enforce sender, recipient, group membership, and group filters', async () => {
  const api = harness();
  await api.upload();
  const original = JSON.stringify(api.state.files[0]);
  api.state.senderAllowed = false;
  const sender = await api.upload();
  assert.equal(sender.statusCode, 403);
  assert.equal(sender.body.code, 'SENDER_CONTENT_FILTERED');
  api.state.senderAllowed = true;
  api.state.recipientFilter = { ...ALL, men: false };
  const recipient = await api.upload({ body: { toUserId: 'friend' } });
  assert.equal(recipient.body.status, 'rejected');
  assert.equal(recipient.body.forwardAllowed, true);
  api.state.member = null;
  const missingMember = await api.upload({ body: { groupId: 'group' } });
  assert.equal(missingMember.statusCode, 403);
  api.state.member = { role: 'member', send_permission: 'admin' };
  const adminOnly = await api.upload({ body: { groupId: 'group' } });
  assert.equal(adminOnly.statusCode, 403);
  api.state.member = { role: 'member', send_permission: 'all' };
  api.state.groupFilter = { ...ALL, men: false };
  const group = await api.upload({ body: { groupId: 'group' } });
  assert.equal(group.body.status, 'rejected');
  assert.equal(api.state.audits.length, 2);
  assert.equal(api.state.blobs.length, 1);
  assert.equal(JSON.stringify(api.state.files[0]), original,
    'a failed destination never changes a previously approved asset');
});

for (const status of ['pending', 'rejected']) {
  test(`${status} uploads retain separate moderation and delivery records`, async () => {
    const api = harness({ result: { blocked: status === 'rejected', pending: status === 'pending',
      reason: status, classification: MEN } });
    const first = await api.upload({ body: { toUserId: 'friend-a' } });
    const second = await api.upload({ body: { toUserId: 'friend-b' } });
    assert.equal(first.body.status, status);
    assert.equal(second.body.status, status);
    assert.notEqual(first.body.url, second.body.url);
    assert.equal(api.state.files.length, 2);
    if (status === 'pending') {
      assert.equal(api.state.pending.length, 2);
      assert.equal(api.state.pending[0].values[1], 'friend-a');
      assert.equal(api.state.pending[1].values[1], 'friend-b');
    }
  });
}

test('current rejected scan and outdated moderation version cannot reuse a former approval', async () => {
  const api = harness();
  await api.upload();
  api.state.files[0].moderation_details.moderationVersion = 'old';
  const rescanned = await api.upload();
  assert.equal(rescanned.statusCode, 200);
  assert.equal(api.state.scans, 2);
  assert.equal(api.state.blobs.length, 2);
  api.state.files.push({ ...api.state.files[1], id: 'later-rejection',
    user_id: 'other-owner', public_url: '/different/rejected', moderation_status: 'rejected',
    moderation_details: { moderationVersion: VERSION, blocked: true, reason: 'new safety result' } });
  const rejected = await api.upload();
  assert.equal(rejected.body.status, 'rejected');
  assert.notEqual(rejected.body.url, rescanned.body.url);
  assert.equal(api.state.files[1].moderation_status, 'approved');
});

for (const exemption of [{ source: 'builtin-expression' }, { scanSkipped: true }]) {
  const label = Object.keys(exemption)[0];
  test(`ordinary uploads rescan an exact cached ${label} exemption`, async () => {
    const api = harness();
    const first = await api.upload();
    Object.assign(api.state.files[0].moderation_details, exemption, { classification: OBJECT });
    const again = await api.upload();
    assert.equal(again.statusCode, 200);
    assert.equal(api.state.scans, 2);
    assert.notEqual(again.body.url, first.body.url);
    assert.deepEqual(again.body.classification, MEN);
  });

  test(`ordinary uploads rescan a visually matched cached ${label} exemption`, async () => {
    const api = harness({ fingerprint: FINGERPRINT });
    await api.upload();
    Object.assign(api.state.files[0].moderation_details, exemption, { classification: OBJECT });
    const again = await api.upload({ bytes: 'reencoded copy' });
    assert.equal(again.statusCode, 200);
    assert.equal(api.state.scans, 2);
    assert.deepEqual(again.body.classification, MEN);
  });

  test(`valid scan cache does not reuse an owner file retaining a ${label} exemption`, async () => {
    const api = harness();
    const first = await api.upload();
    const original = api.state.files[0];
    const validDetails = JSON.parse(JSON.stringify(original.moderation_details));
    Object.assign(original.moderation_details, exemption, { classification: OBJECT });
    api.state.files.push({ ...original, id: 'valid-other-owner', user_id: 'other-owner',
      public_url: '/valid-scanned-copy', moderation_details: validDetails });
    const again = await api.upload();
    assert.equal(again.statusCode, 200);
    assert.equal(api.state.scans, 1, 'the genuinely scanned copy remains cacheable');
    assert.notEqual(again.body.url, first.body.url);
    assert.deepEqual(again.body.classification, MEN);
    assert.deepEqual(api.state.files.at(-1).moderation_details.classification, MEN);
  });
}

test('a genuine visual scan remains reusable across reencoded ordinary uploads', async () => {
  const api = harness({ fingerprint: FINGERPRINT });
  await api.upload();
  const again = await api.upload({ bytes: 'reencoded copy' });
  assert.equal(again.statusCode, 200);
  assert.equal(api.state.scans, 1);
  assert.equal(api.state.files[1].moderation_details.cacheMatch, 'visual');
  assert.deepEqual(again.body.classification, MEN);
});

test('current exact-byte trusted library stickers retain their exemption and owner reuse', async () => {
  const api = harness({ trustedBuiltinExpression: true });
  const first = await api.upload();
  const again = await api.upload();
  assert.equal(first.statusCode, 200);
  assert.equal(again.statusCode, 200);
  assert.equal(again.body.url, first.body.url);
  assert.equal(api.state.scans, 0);
  assert.equal(api.state.blobs.length, 1);
  assert.equal(api.state.files[0].moderation_details.scanSkipped, true);
  assert.equal(api.state.queries.some(query => query.sql.includes('SELECT moderation_details')), false);
});

test('listing reuse stays within listing storage and still enforces object-only photos', async () => {
  const api = harness({ classification: OBJECT });
  const general = await api.upload();
  const listing = await api.upload({ body: { listingImage: 'true' } });
  const again = await api.upload({ body: { listingImage: 'true' } });
  assert.notEqual(listing.body.url, general.body.url);
  assert.equal(again.body.url, listing.body.url);
  assert.equal(api.state.blobs.length, 2);
  api.state.files[1].moderation_details.classification = MEN;
  const before = JSON.stringify(api.state.files[1]);
  const denied = await api.upload({ body: { listingImage: 'true' } });
  assert.equal(denied.body.status, 'rejected');
  assert.equal(JSON.stringify(api.state.files[1]), before);
});

test('reused GIF still applies explicit rights and title, and scan bot still receives a report', async () => {
  const api = harness();
  const options = { name: 'picture.gif', mime: 'image/gif' };
  const first = await api.upload(options);
  const unauthorized = await api.upload({ ...options, body: { sharedGif: 'true' } });
  assert.equal(unauthorized.statusCode, 400);
  const share = await api.upload({ ...options, body: { sharedGif: 'true', rightsConfirmed: 'true',
    sharedGifTitle: 'שלום', sharedGifTags: 'ברכה, שלום' } });
  assert.equal(share.statusCode, 200);
  assert.equal(share.body.url, first.body.url);
  assert.equal(share.body.sharedGifId, 'gif-1');
  assert.equal(api.state.gifs[0].fileId, api.state.files[0].id);
  const report = await api.upload({ ...options, body: { toUserId: 'scan-bot' } });
  assert.equal(report.body.handledByScanBot, true);
  assert.equal(report.body.url, first.body.url);
  assert.equal(api.state.reports.length, 1);
  assert.equal(api.state.blobs.length, 1);
});

test('new voice recordings are converted and approved without a transcription queue', async () => {
  const api = harness();
  const name = 'betshuva-audio-2026-09-23_14-07-36-25-ID-742_2.webm';
  const result = await api.upload({ name, mime: 'audio/webm', bytes: 'original WebM recording',
    body: { recordedAudio: 'true', toUserId: 'friend' } });
  assert.equal(result.statusCode, 200);
  assert.notEqual(result.body.status, 'pending');
  assert.equal(api.state.audioConversions.length, 1);
  assert.equal(api.state.audioProbes.length, 0);
  const file = api.state.files[0];
  assert.equal(file.original_name, name.replace('.webm', '.mp3'));
  assert.equal(file.mime_type, 'audio/mpeg');
  assert.equal(file.file_type, 'audio');
  assert.equal(file.file_size, Buffer.byteLength('encoded MP3 recording'));
  assert.equal(file.content_sha256, crypto.createHash('sha256').update('encoded MP3 recording').digest('hex'));
  assert.ok(file.public_url.endsWith('.mp3'));
  assert.equal(file.moderation_status, 'approved');
  assert.equal(file.moderation_details.audio.transcription, 'disabled');
  assert.equal(api.state.pending.length, 0, 'audio never queues for transcription');
  assert.equal(api.state.recipientReads.length, 1);
});

test('legacy recordings store and return the assigned short creator number after MP3 conversion', async () => {
  const api = harness();
  api.state.owner = 'c519a188-fcca-4aaa-bd69-c0d227ca7959';
  const stem = 'betshuva-audio-2026-09-23_14-07-36-25-ID-';
  const result = await api.upload({ name: `${stem}${api.state.owner}_2.webm`,
    mime: 'audio/webm', bytes: 'original recording',
    body: { recordedAudio: 'true', toUserId: 'friend' } });
  assert.equal(result.statusCode, 200);
  assert.equal(result.body.fileName, `${stem}742_2.mp3`);
  assert.equal(api.state.files[0].original_name, result.body.fileName);
  assert.ok(api.state.blobs[0].endsWith(`${stem}742_2.mp3`));
  assert.equal(api.state.pending.length, 0);
});

test('selected/imported audio preserves its original bytes, extension, and content type', async () => {
  for (const [mime, name, body] of [
    ['audio/wav', 'original.wav', {}],
    ['audio/webm', 'original.webm', { recordedAudio: 'false' }],
    ['audio/mpeg', 'original.mp3', {}],
  ]) {
    const api = harness();
    const result = await api.upload({ name, mime, bytes: 'original audio', body });
    assert.equal(result.statusCode, 200);
    assert.equal(api.state.audioConversions.length, 0);
    assert.equal(api.state.audioProbes.length, 1);
    const file = api.state.files[0];
    assert.equal(file.original_name, name);
    assert.equal(file.mime_type, mime);
    assert.equal(file.content_sha256, crypto.createHash('sha256').update('original audio').digest('hex'));
  }
});

test('recording flag does not convert a non-audio upload', async () => {
  const api = harness();
  const result = await api.upload({ body: { recordedAudio: 'true' } });
  assert.equal(result.statusCode, 400);
  assert.equal(result.body.code, 'INVALID_AUDIO');
  assert.equal(api.state.audioConversions.length, 0);
  assert.equal(api.state.files.length, 0);
});

test('recording failures cannot create storage or moderation records', async () => {
  for (const [conversionError, status] of [
    ['INVALID_AUDIO', 400],
    ['AUDIO_SIZE_EXCEEDED', 400],
    ['AUDIO_CONVERSION_BUSY', 503],
    ['AUDIO_CONVERSION_UNAVAILABLE', 503],
  ]) {
    const api = harness({ conversionError });
    const result = await api.upload({ name: 'voice.wav', mime: 'audio/wav',
      body: { recordedAudio: 'true' } });
    assert.equal(result.statusCode, status);
    assert.equal(result.body.code, conversionError);
    assert.equal(api.state.files.length, 0);
    assert.equal(api.state.blobs.length, 0);
    assert.equal(api.state.pending.length, 0);
  }
});

test('matching upload locks queue fairly, release once, and do not block other hashes or owners', async () => {
  const first = await acquireUploadLock('lock-owner', 'hash', 'image');
  let secondAcquired = false;
  const waiting = acquireUploadLock('lock-owner', 'hash', 'image').then(release => {
    secondAcquired = true; return release;
  });
  const otherHash = await acquireUploadLock('lock-owner', 'another', 'image');
  const otherOwner = await acquireUploadLock('another-owner', 'hash', 'image');
  assert.equal(secondAcquired, false);
  first(); first();
  const second = await waiting;
  assert.equal(secondAcquired, true);
  second(); otherHash(); otherOwner();
  const final = await acquireUploadLock('lock-owner', 'hash', 'image');
  final();
});

test('PostgreSQL reuse lookup excludes other owners, incomplete scans, unavailable bytes, and listing boundaries', {
  skip: process.env.RUN_DB_TESTS !== '1',
}, async () => {
  const { Client } = require('pg');
  const db = new Client({ connectionString: process.env.DATABASE_URL,
    ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' } : false });
  await db.connect();
  try {
    await db.query('SET search_path=pg_temp');
    await db.query(`CREATE TEMP TABLE stored_files(id text,user_id text,content_sha256 text,
      file_type text,mime_type text,file_size bigint,moderation_status text,
      moderation_details jsonb,content_purged_at timestamptz,released_at timestamptz,context_type text,
      public_url text,created_at timestamptz DEFAULT now())`);
    const options = { userId: 'owner', contentSha256: 'hash', fileType: 'image', mimeType: 'image/png',
      fileSize: 12, moderationVersion: VERSION, listingImage: false };
    const base = { id: 'file', user_id: options.userId, content_sha256: options.contentSha256,
      file_type: options.fileType, mime_type: options.mimeType, file_size: options.fileSize,
      moderation_status: 'approved', moderation_details: { moderationVersion: VERSION, blocked: false },
      content_purged_at: null, context_type: 'chat', public_url: '/approved' };
    const insert = async overrides => {
      await db.query('DELETE FROM stored_files');
      const record = { ...base, ...overrides };
      const columns = Object.keys(record);
      await db.query(`INSERT INTO stored_files(${columns.join(',')}) VALUES(${columns.map((_, i) => `$${i + 1}`).join(',')})`,
        Object.values(record));
    };
    await insert({});
    assert.deepEqual(await findReusableUpload(db, options), { id: 'file', public_url: '/approved' });
    for (const changes of [
      { user_id: 'someone-else' }, { content_sha256: 'different' }, { file_type: 'document' },
      { mime_type: 'image/gif' }, { file_size: 13 }, { moderation_status: 'pending' },
      { moderation_status: 'rejected' }, { content_purged_at: new Date() },
      { released_at: new Date() },
      { moderation_details: { moderationVersion: 'old' } },
      { moderation_details: { moderationVersion: VERSION, pending: true } },
      { moderation_details: { moderationVersion: VERSION, blocked: true } },
      { moderation_details: { moderationVersion: VERSION, source: 'builtin-expression' } },
      { moderation_details: { moderationVersion: VERSION, scanSkipped: true } },
      { moderation_details: null }, { context_type: 'listing' }, { public_url: '' },
    ]) {
      await insert(changes);
      assert.equal(await findReusableUpload(db, options), null, JSON.stringify(changes));
    }
    await insert({ context_type: 'listing' });
    assert.ok(await findReusableUpload(db, { ...options, listingImage: true }));
    await insert({ context_type: 'received' });
    assert.ok(await findReusableUpload(db, options), 'already owned received copies may be reused');
    await insert({ moderation_details: { moderationVersion: VERSION,
      source: 'builtin-expression', scanSkipped: true } });
    assert.ok(await findReusableUpload(db, { ...options, trustedBuiltinExpression: true }),
      'current exact-byte library recognition still permits sticker reuse');
  } finally { await db.end(); }
});

test('PostgreSQL exact and visual moderation caches exclude unscanned library exemptions', {
  skip: process.env.RUN_DB_TESTS !== '1',
}, async () => {
  const { Client } = require('pg');
  const db = new Client({ connectionString: process.env.DATABASE_URL,
    ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' } : false });
  const exactSql = source.match(/`(SELECT moderation_details FROM stored_files\s+WHERE content_sha256=[\s\S]*?)`/)[1];
  const visualSql = source.match(/`(SELECT moderation_details,visual_fingerprint FROM stored_files[\s\S]*?)`/)[1];
  await db.connect();
  try {
    await db.query('SET search_path=pg_temp');
    await db.query(`CREATE TEMP TABLE stored_files(content_sha256 text,file_type text,
      moderation_status text,moderation_details jsonb,visual_fingerprint jsonb,
      created_at timestamptz DEFAULT now())`);
    for (const exemption of [null, { source: 'builtin-expression' }, { scanSkipped: true },
      { source: 'builtin-expression', scanSkipped: true }]) {
      await db.query('DELETE FROM stored_files');
      await db.query(`INSERT INTO stored_files(content_sha256,file_type,moderation_status,
        moderation_details,visual_fingerprint) VALUES('hash','image','approved',$1,$2)`,
        [{ moderationVersion: VERSION, blocked: false, ...exemption }, FINGERPRINT]);
      const exact = await db.query(exactSql, ['hash', 'image', VERSION]);
      const visual = await db.query(visualSql, [VERSION, FINGERPRINT.aspect]);
      const expected = exemption ? 0 : 1;
      assert.equal(exact.rows.length, expected, `exact cache: ${JSON.stringify(exemption)}`);
      assert.equal(visual.rows.length, expected, `visual cache: ${JSON.stringify(exemption)}`);
    }
  } finally { await db.end(); }
});


test('real upload sender guard permits new/cached outgoing media and still applies the recipient filter', async () => {
  for (const body of [{toUserId:'friend'}, {groupId:'group'}]) {
    const api = harness({realSenderGuard:true});
    api.state.senderAllowed=false;
    const first=await api.upload({body});
    assert.equal(first.statusCode,200);assert.ok(first.body.url);assert.equal(api.state.files[0].moderation_status,'approved');
    const cached=await api.upload({body});
    assert.equal(cached.statusCode,200);assert.equal(cached.body.url,first.body.url);
    assert.equal(api.state.scans,1);
    api.state.recipientFilter={...ALL,men:false};api.state.groupFilter={...ALL,men:false};
    const rejected=await api.upload({body});
    assert.equal(rejected.body.status,'rejected');assert.equal(rejected.body.forwardAllowed,true);
    assert.ok(!rejected.body.reason.includes('שלך'));
  }
});

test('recipient-only upload policy does not bypass a failed safety scan', async () => {
  const api=harness({realSenderGuard:true,result:{blocked:true,reason:'unsafe-test-content',classification:MEN}});
  const result=await api.upload({body:{toUserId:'friend'}});
  assert.equal(result.body.status,'rejected');assert.equal(result.body.reason,'unsafe-test-content');
});

test('audio accepts exactly 150MB and long duration while other file caps remain enforced', async () => {
  for (const [name, mime, size, status] of [
    ['long.mp3', 'audio/mpeg', 150 * 1024 * 1024, 200],
    ['large.mp3', 'audio/mpeg', 150 * 1024 * 1024 + 1, 400],
    ['large.mp4', 'video/mp4', 3 * 1024 * 1024 * 1024, 200],
    ['large.pdf', 'application/pdf', 26 * 1024 * 1024, 400],
  ]) {
    const api = harness({ realUploadResolver: true, audioDuration: 24 * 3600 });
    const response = await api.upload({ name, mime, bytes: '0000ftypisom', reportedSize: size });
    assert.equal(response.statusCode, status, name);
    assert.equal(api.state.files.length, status === 200 ? 1 : 0);
    if (status === 200 && mime.startsWith('audio/')) assert.equal(api.state.files[0].moderation_details.audio.durationSeconds, 86400);
  }
});
