'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { MAX_IMAGE_BYTES, registerChatListingImage, readBoundedSourceMedia } = require('../server/chat-listing-image');

const userId = '11111111-1111-4111-8111-111111111111';
const messageId = '22222222-2222-4222-8222-222222222222';
const fileId = '33333333-3333-4333-8333-333333333333';
const bytes = Buffer.from('approved image fixture');
const hash = createHash('sha256').update(bytes).digest('hex');
const originalUrl = '/betshuva-app/uploads/source/image.png';

function harness(options = {}) {
  const message = { id: messageId, sender_id: userId, recipient_id: 'recipient', group_id: null,
    type: 'image', file_url: originalUrl, ...options.message };
  const request = { id: messageId, sender_id: userId, recipient_id: 'recipient',
    type: 'image', file_url: originalUrl, status: 'pending', ...options.request };
  const file = { id: fileId, user_id: userId, public_url: originalUrl, storage_path: 'image.png',
    file_type: 'image', mime_type: 'image/png', moderation_status: 'approved', content_purged_at: null,
    moderation_details: {}, file_size: bytes.length, content_sha256: hash,
    original_name: 'צילום מסך.png', ...options.file };
  const calls = { queries: [], projections: [], personalized: [], requestProjections: [], reads: 0 };
  let visible = options.visible !== false;
  let handler;
  const auth = () => {}, rateLimit = () => {};
  const db = { async query(sql, values) {
    calls.queries.push({ sql, values });
    if (sql.includes('FROM messages m WHERE')) return { rows: visible ? [message] : [] };
    if (sql.includes('FROM message_requests mr WHERE')) return { rows: visible &&
      request.sender_id === values[0] && request.id === values[1] && request.type === 'image' &&
      ['pending', 'rejected'].includes(request.status) && !options.requestCleared && !options.requestDeleted
        ? [structuredClone(request)] : [] };
    if (sql.includes('FROM stored_files sf')) {
      const approved = file.file_type === 'image' && file.moderation_status === 'approved' &&
        !file.content_purged_at && !file.moderation_details.blocked && !file.moderation_details.pending &&
        !file.moderation_details.scanStopped && !options.deletedSource;
      const requestOwner = !sql.includes('WHERE sf.user_id=$1 AND sf.public_url=$2') ||
        file.user_id === values[0] && file.public_url === values[1];
      return { rows: approved && requestOwner && options.fileAccessible !== false ? [structuredClone(file)] : [] };
    }
    throw new Error('Unexpected query');
  } };
  registerChatListingImage({ get(route, ...handlers) {
    assert.equal(route, '/api/messages/:id/listing-image-source');
    assert.equal(handlers[0], auth); assert.equal(handlers[1], rateLimit);
    handler = handlers[2];
  } }, { auth, rateLimit, getPool: async () => db, uploadRoot: '/private/uploads', logger: { warn() {} },
    projectHistory: async (...args) => {
      calls.projections.push(args);
      if (options.projectDeleted) return [];
      return args[2].map(row => options.hidden ? { ...row, file_url: null, filter_hidden: true } : row);
    },
    personalizeMessages: async (...args) => {
      calls.personalized.push(args);
      return args[2].map(row => options.copyUrl ? { ...row, file_url: options.copyUrl }
        : options.copyDeleted ? { ...row, file_url: null, file_deleted: true } : row);
    },
    projectRequests: async (...args) => {
      calls.requestProjections.push(args);
      if (options.projectRequestDeleted) return [];
      return args[2].map(row => options.requestHidden ? { ...row, file_url: null, filter_hidden: true }
        : options.requestCopyUrl ? { ...row, file_url: options.requestCopyUrl }
        : options.requestFileDeleted ? { ...row, file_deleted: true } : row);
    },
    readImage: async (database, root, source) => {
      assert.equal(database, db); assert.equal(root, '/private/uploads'); assert.deepEqual(source, file);
      calls.reads++;
      if (options.revokeDuringRead) visible = false;
      if (options.changeDuringRead) file.content_sha256 = 'b'.repeat(64);
      if (options.requestFilterDuringRead) options.requestHidden = true;
      if (options.requestSettledDuringRead) request.status = 'accepted';
      if (options.requestSafetyDuringRead) file.moderation_status = 'rejected';
      if (options.requestOwnerDuringRead) file.user_id = 'another-user';
      if (options.readFailure) throw Object.assign(new Error('private Drive error'), { code: 'RESTORE_FAILED' });
      return options.readBytes ?? bytes;
    },
  });
  return { calls, file, async call(extra = {}) {
    const response = { code: 200, headers: {}, value: null,
      status(code) { this.code = code; return this; },
      set(name, value) { this.headers[name.toLowerCase()] = value; return this; },
      append(name, value) { this.headers[name.toLowerCase()] = value; return this; },
      json(value) { this.value = value; return this; }, send(value) { this.value = value; return this; } };
    await handler({ user: { id: userId, isTeen: options.teen },
      params: { id: options.requestSource ? `request_${messageId}` : messageId },
      query: { fileUrl: 'https://external.invalid/secret', userId: 'other' }, ...extra }, response);
    return response;
  } };
}

test('authenticated source delivery returns only checked bytes and encoded filename, without creating a listing', async () => {
  const h = harness(); const response = await h.call();
  assert.equal(response.code, 200); assert.deepEqual(response.value, bytes);
  assert.equal(response.headers['content-type'], 'image/png');
  assert.equal(decodeURIComponent(response.headers['x-image-file-name']), 'צילום מסך.png');
  assert.equal(response.headers['x-content-type-options'], 'nosniff');
  assert.match(response.headers['cache-control'], /private.*no-store/);
  assert.match(response.headers['access-control-expose-headers'], /X-Image-File-Name/);
  assert.equal(h.calls.reads, 1); assert.equal(h.calls.projections.length, 2);
  for (const call of h.calls.queries) {
    assert.match(call.sql, /^SELECT/); assert.ok(!call.values.includes('other'));
    assert.ok(!call.values.some(value => String(value).includes('external.invalid')));
  }
  const authorization = h.calls.queries[0];
  assert.deepEqual(authorization.values, [userId, messageId]);
  for (const clause of ['deleted_for_everyone', 'deleted_for_sender', 'message_user_deletions',
    'conversation_user_state', 'group_members', 'joined_at']) assert.ok(authorization.sql.includes(clause));
});

test('teen, invalid/synthetic message IDs and inaccessible messages never read bytes', async () => {
  for (const [options, request, expected] of [
    [{ teen: true }, {}, 403], [{}, { params: { id: 'scan_' + fileId } }, 400],
    [{}, { params: { id: '../../image.png' } }, 400], [{ visible: false }, {}, 404],
  ]) {
    const h = harness(options); assert.equal((await h.call(request)).code, expected);
    assert.equal(h.calls.reads, 0);
  }
});

test('current personal/group projection is authoritative and hidden media cannot fall back to its URL', async () => {
  for (const options of [{ hidden: true }, { projectDeleted: true }, { copyDeleted: true }]) {
    const h = harness(options); assert.equal((await h.call()).code, 404); assert.equal(h.calls.reads, 0);
  }
  const h = harness({ message: { group_id: 'group' } });
  assert.equal((await h.call()).code, 200);
  assert.deepEqual(h.calls.projections[0][3], { groupId: 'group' });
});

test('pending, stopped, blocked, deleted and purged source bytes are unavailable', async () => {
  for (const file of [{ moderation_status: 'pending' }, { moderation_status: 'rejected' },
    { moderation_status: 'stopped' }, { content_purged_at: new Date() },
    { moderation_details: { blocked: true } }, { moderation_details: { pending: true } },
    { moderation_details: { scanStopped: true } }, { file_type: 'video' },
    { mime_type: 'image/svg+xml' }, { file_size: 0 }]) {
    const h = harness({ file }); assert.equal((await h.call()).code, 404); assert.equal(h.calls.reads, 0);
  }
  const h = harness({ deletedSource: true }); assert.equal((await h.call()).code, 404);
  assert.equal(h.calls.reads, 0);
});

test('personal ready copies use their own bytes and preserve the source message binding', async () => {
  const copyUrl = '/betshuva-app/uploads/received/owned/copy.png';
  const h = harness({ copyUrl, file: { public_url: copyUrl } });
  assert.equal((await h.call()).code, 200);
  const lookup = h.calls.queries.find(call => call.sql.includes('FROM stored_files sf'));
  assert.deepEqual(lookup.values, [userId, copyUrl, originalUrl, messageId]);
  assert.ok(lookup.sql.includes("received.status='ready'"));
  assert.ok(lookup.sql.includes('received.stored_file_id=sf.id'));
  const foreign = harness({ copyUrl, fileAccessible: false });
  assert.equal((await foreign.call()).code, 404); assert.equal(foreign.calls.reads, 0);
});

test('size and exact-byte checks reject oversize, empty, incomplete or corrupt restored images', async () => {
  const oversized = harness({ file: { file_size: MAX_IMAGE_BYTES + 1 } });
  assert.equal((await oversized.call()).code, 413); assert.equal(oversized.calls.reads, 0);
  for (const readBytes of [Buffer.alloc(0), bytes.subarray(1), Buffer.alloc(bytes.length),
    Buffer.alloc(MAX_IMAGE_BYTES + 1)]) {
    const h = harness({ readBytes }); assert.ok((await h.call()).code >= 400);
  }
  const failed = harness({ readFailure: true }); const response = await failed.call();
  assert.equal(response.code, 503); assert.ok(!JSON.stringify(response.value).includes('private Drive error'));
});

test('permissions are rechecked after restoration and prevent delivery after revocation', async () => {
  const h = harness({ revokeDuringRead: true }); const response = await h.call();
  assert.equal(response.code, 404); assert.equal(h.calls.reads, 1); assert.ok(!Buffer.isBuffer(response.value));
});

test('encoded names cannot inject headers or filesystem paths', async () => {
  const h = harness({ file: { original_name: 'C:\\private\\צילום\r\nX-Header: secret.png' } });
  const response = await h.call(); assert.equal(response.code, 200);
  const name = decodeURIComponent(response.headers['x-image-file-name']);
  assert.ok(!/[\\/\r\n]/.test(name)); assert.ok(!name.includes('private'));
});

test('an approved owned contact request uses the explicit namespace without delivering or resolving the request', async () => {
  for (const status of ['pending', 'rejected']) {
    const h = harness({ requestSource: true, request: { status } });
    const response = await h.call();
    assert.equal(response.code, 200); assert.deepEqual(response.value, bytes);
    assert.equal(h.calls.reads, 1); assert.equal(h.calls.requestProjections.length, 2);
    assert.equal(h.calls.projections.length, 0); assert.equal(h.calls.personalized.length, 0);
    const projection = h.calls.requestProjections[0];
    assert.equal(projection[1], userId); assert.equal(projection[2][0].id, `request_${messageId}`);
    assert.deepEqual(projection[3], { contextType: 'chat', contextId: 'recipient' });
    const lookups = h.calls.queries.filter(call => call.sql.includes('FROM message_requests mr WHERE'));
    assert.equal(lookups.length, 2);
    for (const lookup of lookups) {
      assert.deepEqual(lookup.values, [userId, messageId]);
      for (const clause of ['mr.sender_id=$1', "mr.type='image'", "mr.status IN ('pending','rejected')",
        'message_user_deletions', 'conversation_user_state', 'mr.created_at<=clear_state.cleared_at']) {
        assert.ok(lookup.sql.includes(clause), clause);
      }
    }
    for (const call of h.calls.queries) {
      assert.match(call.sql, /^SELECT/);
      assert.ok(!call.sql.includes('FROM messages m WHERE'));
      assert.ok(!call.sql.includes('received_message_media'));
      assert.ok(!call.values.some(value => String(value).includes('external.invalid')));
    }
    const fileLookup = h.calls.queries.find(call => call.sql.includes('FROM stored_files sf'));
    assert.ok(fileLookup.sql.includes('sf.user_id=$1 AND sf.public_url=$2'));
    assert.deepEqual(fileLookup.values, [userId, originalUrl]);
  }
});

test('request sources reject recipients, outsiders, unavailable requests and foreign file ownership without fallback', async () => {
  for (const options of [
    { request: { sender_id: 'another-user' } },
    { request: { type: 'video' } }, { request: { file_url: null } },
    { request: { status: 'accepted' } }, { visible: false },
    { requestCleared: true }, { requestDeleted: true },
    { file: { user_id: 'another-user' } },
  ]) {
    const h = harness({ requestSource: true, ...options });
    assert.equal((await h.call()).code, 404); assert.equal(h.calls.reads, 0);
    assert.ok(!h.calls.queries.some(call => call.sql.includes('FROM messages m WHERE')));
  }
  const h = harness({ requestSource: true });
  assert.equal((await h.call({ user: { id: 'recipient' } })).code, 404);
  assert.equal(h.calls.reads, 0);
});

test('request identities are strict and never reinterpret raw IDs or other synthetic namespaces', async () => {
  for (const id of [`request_scan_${messageId}`, 'request_', `request_request_${messageId}`,
    `REQUEST_${messageId}`, `scan_${fileId}`, `file_${fileId}`, `request_${messageId}/../source`,
    `request_${messageId}?url=external`]) {
    const h = harness({ requestSource: true });
    assert.equal((await h.call({ params: { id } })).code, 400, id);
    assert.equal(h.calls.queries.length, 0); assert.equal(h.calls.reads, 0);
  }
  const normal = harness({ visible: false });
  assert.equal((await normal.call()).code, 404);
  assert.equal(normal.calls.requestProjections.length, 0);
  assert.ok(!normal.calls.queries.some(call => call.sql.includes('FROM message_requests')));
  const teen = harness({ requestSource: true, teen: true });
  assert.equal((await teen.call()).code, 403); assert.equal(teen.calls.queries.length, 0);
});

test('request previews retain sender filtering and never substitute a personal or foreign copy', async () => {
  for (const options of [{ requestHidden: true }, { projectRequestDeleted: true },
    { requestFileDeleted: true }, { requestCopyUrl: '/received/another-copy.png' }]) {
    const h = harness({ requestSource: true, ...options });
    assert.equal((await h.call()).code, 404); assert.equal(h.calls.reads, 0);
    assert.equal(h.calls.personalized.length, 0);
  }
});

test('contact approval never bypasses a request source safety result, MIME, size or checksum', async () => {
  for (const file of [{ moderation_status: 'pending' }, { moderation_status: 'rejected' },
    { moderation_status: 'stopped' }, { content_purged_at: new Date() },
    { moderation_details: { blocked: true } }, { moderation_details: { pending: true } },
    { moderation_details: { scanStopped: true } }, { file_type: 'video' },
    { mime_type: 'image/svg+xml' }, { file_size: 0 }]) {
    const h = harness({ requestSource: true, file });
    assert.equal((await h.call()).code, 404); assert.equal(h.calls.reads, 0);
  }
  const deleted = harness({ requestSource: true, deletedSource: true });
  assert.equal((await deleted.call()).code, 404); assert.equal(deleted.calls.reads, 0);
  const oversized = harness({ requestSource: true, file: { file_size: MAX_IMAGE_BYTES + 1 } });
  assert.equal((await oversized.call()).code, 413); assert.equal(oversized.calls.reads, 0);
  const corrupt = harness({ requestSource: true, readBytes: Buffer.alloc(bytes.length) });
  assert.equal((await corrupt.call()).code, 503); assert.equal(corrupt.calls.reads, 1);
});

test('request visibility, resolution, filtering, safety, ownership and hash are rechecked after a slow read', async () => {
  for (const [change, expected] of [
    ['revokeDuringRead', 404], ['requestSettledDuringRead', 404],
    ['requestFilterDuringRead', 404], ['requestSafetyDuringRead', 404],
    ['requestOwnerDuringRead', 404], ['changeDuringRead', 404],
  ]) {
    const h = harness({ requestSource: true, [change]: true });
    const response = await h.call();
    assert.equal(response.code, expected, change); assert.equal(h.calls.reads, 1);
    assert.ok(!Buffer.isBuffer(response.value));
  }
});

test('local reads are bounded and Drive fallback occurs only for missing safe paths', async t => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'chat-listing-image-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const file = { storage_path: 'image.png', file_size: bytes.length };
  await fs.writeFile(path.join(root, file.storage_path), bytes);
  let restored = 0;
  const restore = async (db, sourceRoot, source, options) => {
    assert.equal(sourceRoot, root); assert.equal(source, file);
    assert.deepEqual(options, { skipLocal: true }); restored++; return bytes;
  };
  assert.deepEqual(await readBoundedSourceMedia({}, root, file, restore), bytes);
  assert.equal(restored, 0);
  await fs.truncate(path.join(root, file.storage_path), MAX_IMAGE_BYTES + 1);
  await assert.rejects(readBoundedSourceMedia({}, root, file, restore), error => error.status === 413);
  assert.equal(restored, 0);
  await fs.rm(path.join(root, file.storage_path));
  assert.deepEqual(await readBoundedSourceMedia({}, root, file, restore), bytes);
  assert.equal(restored, 1);
  await assert.rejects(readBoundedSourceMedia({}, root, { ...file, storage_path: '../outside.png' }, restore),
    error => error.status === 404);
  const outside = root + '-outside.png';
  await fs.writeFile(outside, bytes); t.after(() => fs.rm(outside, { force: true }));
  await fs.symlink(outside, path.join(root, 'linked.png'));
  await assert.rejects(readBoundedSourceMedia({}, root, { ...file, storage_path: 'linked.png' }, restore),
    error => error.status === 404);
  await fs.rm(path.join(root, 'linked.png'));
  await fs.symlink(os.tmpdir(), path.join(root, 'outside-dir'));
  await assert.rejects(readBoundedSourceMedia({}, root, { ...file, storage_path: 'outside-dir' }, restore),
    error => error.status === 404);
  assert.equal(restored, 1);
});

test('an oversized local file appearing during remote fallback is never read by the restore helper', async t => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'chat-listing-image-race-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const file = { storage_path: 'image.png', file_size: bytes.length };
  const central = require('../server/central-drive');
  const originalRead = central.readFile;
  central.readFile = async () => bytes;
  t.after(() => { central.readFile = originalRead; });
  const { readSourceMedia } = require('../server/received-media');
  const restore = async (...args) => {
    await fs.writeFile(path.join(root, file.storage_path), Buffer.alloc(MAX_IMAGE_BYTES + 1));
    return readSourceMedia(...args);
  };
  assert.deepEqual(await readBoundedSourceMedia({}, root, file, restore), bytes);
});
