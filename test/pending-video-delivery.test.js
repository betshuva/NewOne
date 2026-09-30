'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const source = fs.readFileSync(require.resolve('../server/index.js'), 'utf8');
const start = source.indexOf('async function retryPendingScans()');
const end = source.indexOf('async function recoverOrphanedPendingScans(', start);
const approved = { moderationVersion: 'test-current', blocked: false, pending: false, classification: {
  category: 'video', detectedCategories: ['video', 'nonHumanImages'], uncertain: false,
} };

async function retry({ cached = false, result = approved, stopped = false,
  isContact = true, contentAllowed = true, group = false, type = 'video', blockedRecipient = false, teenAllowed = true, realSenderGuard = false } = {}) {
  const row = { id: 103, retry_count: 0, created_at: new Date(), file_type: type,
    file_name: 'clip.mp4', mime_type: 'video/mp4', file_url: '/uploads/clip.mp4',
    stored_file_id: 'file', storage_path: 'clip.mp4', file_size: 5, user_id: 'sender',
    to_user_id: 'recipient', stored_moderation_status: stopped ? 'stopped' : cached ? 'approved' : 'pending',
    prior_moderation_details: stopped ? structuredClone(result)
      : cached ? structuredClone(approved) : { pending: true } };
  if (group) { row.to_user_id = null; row.group_id = 'group'; }
  const events = [];
  const rejections = [];
  const decisions = [];
  let savedDetails;
  let queued = true;
  const pool = { async query(sql, values) {
    const q = sql.trim();
    if (q.startsWith('SELECT ps.*')) return { rows: queued ? [row] : [] };
    if (q.startsWith('SELECT EXISTS')) return { rows: [{ waiting: false }] };
    if (q.startsWith('UPDATE pending_scans')) return { rows: [{ retry_count: 1 }] };
    if (q.startsWith('INSERT INTO scan_queue_wait_metrics')) return { rows: [] };
    if (q.startsWith('SELECT id FROM pending_scans')) return { rows: queued ? [{ id: row.id }] : [] };
    if (q.startsWith('SELECT 1 FROM blocked_users')) return { rows: blockedRecipient ? [{}] : [] };
    if (q.startsWith('SELECT pg_advisory_xact_lock')) return { rows: [] };
    if (q.startsWith('SELECT 1 FROM user_contacts')) return { rows: isContact ? [{}] : [] };
    if (q.startsWith('SELECT id,created_at FROM message_requests')) return { rows: [] };
    if (q.startsWith('INSERT INTO message_requests')) { events.push('request'); return { rows: [{ id: 'request', created_at: new Date() }] }; }
    if (q.startsWith('SELECT id FROM users')) return { rows: [{ id: row.user_id }] };
    if (q.startsWith('UPDATE stored_files')) {
      const details = JSON.parse(values[0]);
      savedDetails = details;
      if (details.pending) assert.match(q, /moderation_status='pending'/,
        'a pending retry must not overwrite a newer terminal scan');
      else events.push(q.includes("moderation_status='stopped'") ? 'stop' : 'approve');
      return { rows: [] };
    }
    if (q.startsWith('INSERT INTO messages')) {
      assert.equal(values[1], 'recipient');
      process.env.MESSAGE_ENCRYPTION_KEY ||= 'test-message-encryption-key-at-least-32-bytes';
      const encrypted = require('../server/message-at-rest').encryptedQueryValues(q, values);
      assert.match(encrypted[3], /^enc:v1:/);
      assert.equal(encrypted[5], 'clip.mp4');
      assert.match(q, /VALUES \(\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8\)/);
      assert.deepEqual([...values.slice(6)], [null, null]);
      events.push('message');
      return { rows: [{ id: 'sent', created_at: new Date() }] };
    }
    if (q.startsWith('DELETE FROM pending_scans')) {
      queued = false; events.push('dequeue');
      return { rows: [{ id: row.id }], rowCount: 1 };
    }
    if (['BEGIN', 'COMMIT', 'ROLLBACK'].includes(q)) { events.push(q); return { rows: [] }; }
    throw new Error(`Unexpected query: ${q}`);
  }, async connect() { return { query: pool.query, release() {} }; } };
  const errors = [];
  const run = vm.runInNewContext(`${source.slice(start, end)};retryPendingScans`, {
    ...require('./helpers/system-audit-stubs'),
    queueContactRequest: require('../server/contact-message-requests').queueContactRequest,
    teenContactAllowed: async () => teenAllowed,
    getPool: async () => pool, pendingScanPriorityClass: () => 'deferred_video',
    pendingScanRetryRequested: false, requestPendingScanRetry() {},
    UPLOAD_ROOT: '/missing-local-media', UPLOAD_PUBLIC_BASE: '/uploads',
    fs: { stat: async () => { throw Object.assign(new Error('missing'), { code: 'ENOENT' }); } },
    path: require('node:path'), VIDEO_SCAN_VERSION: 'test-current',
    MODERATION_CACHE_VERSION: 'test-current', SCAN_BOT_ID: 'bot', SYSTEM_USER_ID: 'guide', SAFE_INFORMATION_USER_ID: 'info',
    async readSourceMedia(db, root, file) {
      assert.equal(db, pool); assert.equal(root, '/missing-local-media');
      assert.equal(file.id, 'file'); assert.equal(file.user_id, 'sender');
      events.push('read-storage'); return Buffer.from('video');
    },
    async scanVideo(bytes) {
      assert.equal(bytes.toString(), 'video'); events.push('scan');
      return structuredClone(result);
    },
    async runBoundedVideoScan(bytes, name, mime, options) {
      assert.equal(options.pool, pool);
      assert.equal(options.scanVersion, 'test-current');
      assert.equal(options.legacyUnsafe, false);
      return options.scan(bytes);
    },
    stoppedVideoResult: require('../server/video-scan-controller').stoppedVideoResult,
    recordProviderCheck: async () => {},
    relay(userId, event, payload) {
      if (event === 'message:request' || event === 'message:request-pending') { events.push(event); return; }
      if (event === 'scan:rejected') { rejections.push(payload); return; }
      assert.equal(event, 'scan:cancelled');
      assert.equal(payload.scanStopped, true);
      events.push('stopped-notice');
    },
    assertSenderMediaAllowed: async (db,options) => { events.push('sender-policy');
      if (realSenderGuard) return require('../server/sender-content-filter').assertSenderMediaAllowed(db,options); },
    getEffectiveRecipientFilter: async () => ({ isContact, filter: { video: true } }),
    getGroupContentFilter: async () => null,
    contentAllowedByFilter: () => contentAllowed,
    recordFilterDecision: async (db, decision) => decisions.push(decision),
    notifyDestinationFilterBlock: async () => events.push('filter-notice'),
    assertSenderFileAllowed: async (db,userId,fileUrl,contextType,contextId,source) => {
      events.push('sender-policy-at-commit');
      if (realSenderGuard) return require('../server/sender-content-filter').assertSenderMediaAllowed(db,{userId,contextType,contextId,type,classification:approved.classification,source}); },
    decryptAudioTranscript: () => null,
    onlineUsers: new Map(), sendPush: () => events.push('notify'), logActivity() {},
    console: { error(...args) { errors.push(args); } },
  });
  await run();
  assert.deepEqual(errors, []);
  return { events, queued, rejections, decisions, savedDetails };
}

test('missing contact approval moves approved media to a request without delivering or blaming content', async () => {
  const state = await retry({ isContact: false });
  assert.equal(state.queued, false);
  assert.deepEqual(state.rejections, []);
  assert.equal(state.savedDetails.destinationFilterRejected, undefined);
  assert.ok(state.events.includes('request'));
  assert.ok(state.events.includes('message:request-pending'));
  assert.ok(!state.events.includes('message'));
  assert.ok(!state.events.includes('filter-notice'));
});

test('destination content rejection retains its distinct reason', async () => {
  const state = await retry({ contentAllowed: false });
  assert.equal(state.rejections[0].reason, 'הקובץ אינו מותר לפי הגדרות הסינון הנוכחיות של היעד');
  assert.equal(state.savedDetails.reasonCode, 'content_filter');
  assert.ok(state.events.includes('filter-notice'));
  assert.ok(!state.events.includes('message'));
});

test('missing group access does not claim contact approval or content rejection', async () => {
  const state = await retry({ group: true });
  assert.equal(state.rejections[0].reason, 'לא ניתן לשלוח לקבוצה: אין גישה לקבוצה');
  assert.equal(state.savedDetails.reasonCode, 'contact_or_group_access');
  assert.equal(state.queued, false);
  assert.ok(!state.events.includes('message'));
});

test('a video whose local bytes were released is scanned from verified storage and delivered once', async () => {
  const state = await retry();
  assert.deepEqual(state.events, ['read-storage', 'scan', 'sender-policy', 'BEGIN',
    'approve', 'sender-policy-at-commit', 'message', 'dequeue', 'COMMIT', 'notify']);
  assert.equal(state.queued, false);
});

test('an approved queued video finishes delivery without another scan or storage read', async () => {
  const state = await retry({ cached: true });
  assert.equal(state.queued, false);
  assert.ok(state.events.includes('message'));
  assert.ok(!state.events.includes('scan'));
  assert.ok(!state.events.includes('read-storage'));
});

test('an unresolved video stays queued and sends no message or notification', async () => {
  const state = await retry({ result: { pending: true, blocked: false } });
  assert.equal(state.queued, true);
  assert.deepEqual(state.events, ['read-storage', 'scan']);
});

test('a budget-stopped video is removed from the queue without approval or delivery', async () => {
  const result = require('../server/video-scan-controller').stoppedVideoResult('budget_exhausted');
  const state = await retry({ result });
  assert.equal(state.queued, false);
  assert.deepEqual(state.events, ['read-storage', 'scan', 'BEGIN', 'stop', 'dequeue',
    'COMMIT', 'stopped-notice']);
});

test('a duplicate stopped queue row is retired without storage reads or another scan', async () => {
  const result = require('../server/video-scan-controller').stoppedVideoResult('credit_balance_exhausted');
  const state = await retry({ result, stopped: true });
  assert.equal(state.queued, false);
  assert.deepEqual(state.events, ['BEGIN', 'stop', 'dequeue', 'COMMIT', 'stopped-notice']);
});

for (const type of ['image', 'video', 'audio', 'document']) {
  test(`${type} finishing in background waits for contact choice even when current recipient preferences disallow it`, async () => {
    const state = await retry({ type, cached: true, isContact: false, contentAllowed: false });
    assert.ok(state.events.includes('request'));
    assert.ok(!state.events.includes('message'));
    assert.deepEqual(state.rejections, []);
    assert.equal(state.queued, false);
  });
}
test('delayed sends honor blocked accounts and teen restrictions without creating requests', async () => {
  for (const options of [{ blockedRecipient: true }, { teenAllowed: false }]) {
    const state = await retry({ ...options, cached: true, isContact: false });
    assert.ok(!state.events.includes('request'));
    assert.ok(!state.events.includes('message'));
    assert.equal(state.rejections.length, 1);
    assert.equal(state.queued, false);
  }
});


test('actual sender preference guard leaves delayed recipient approval and safety decisions intact', async () => {
  const sent = await retry({cached:true,realSenderGuard:true});
  assert.ok(sent.events.includes('message'));assert.deepEqual(sent.rejections,[]);
  const waiting = await retry({cached:true,realSenderGuard:true,isContact:false});
  assert.ok(waiting.events.includes('request'));assert.ok(!waiting.events.includes('message'));
  const rejected = await retry({cached:true,realSenderGuard:true,contentAllowed:false});
  assert.ok(!rejected.events.includes('message'));assert.equal(rejected.rejections.length,1);
});
