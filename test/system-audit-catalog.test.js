'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const {
  ACTION_CATALOG, ACTION_BY_KEY, COVERAGE, STATUSES, CATEGORIES, SAFE_DETAILS_KEYS,
  normalizeAction, lookupAction, sanitizeAuditDetails,
} = require('../server/system-audit-catalog');

const UUID = '123e4567-e89b-12d3-a456-426614174000';

test('audit metadata excludes sensitive, unrecognized and nested fields', () => {
  assert.deepEqual(sanitizeAuditDetails({
    message: 'private message', body: 'private body', text: 'private text',
    email: 'person@example.com', phone: '0501234567', password: 'private', token: 'private',
    url: 'https://example.com/private', path: '/private/file',
    reasonCode: { text: 'private' }, operation: ['private'],
    workflow: 'media_scan', from: '2026-09-24', to: '2026-09-25',
  }), { workflow: 'media_scan' });
  for (const value of [null, undefined, false, 123, 'private', [], new Date()]) {
    assert.deepEqual(sanitizeAuditDetails(value), {});
  }
});

test('audit metadata ignores inherited values and never invokes getters', () => {
  const input = Object.create({ workflow: 'inherited' });
  Object.defineProperty(input, 'reasonCode', { enumerable: true, get() {
    throw new Error('Getter must not run');
  } });
  input.cacheHit = false;
  assert.deepEqual(sanitizeAuditDetails(input), { cacheHit: false });
  const polluted = JSON.parse('{"__proto__":{"workflow":"unsafe"},"operation":"scan"}');
  assert.deepEqual(sanitizeAuditDetails(polluted), { operation: 'scan' });
});

test('audit metadata retains only nonnegative safe integer measurements and typed booleans', () => {
  assert.deepEqual(sanitizeAuditDetails({
    fileSize: 2048, durationMs: 0, attempt: 1, eventCount: 4,
    count: 2, byteCount: 0, memberCount: 3, scanAttempt: 1,
    cacheHit: true, truncated: false, acceptedCount: 2, failedCount: 0,
  }), {
    fileSize: 2048, durationMs: 0, attempt: 1, cacheHit: true,
    eventCount: 4, truncated: false, count: 2, byteCount: 0, memberCount: 3, scanAttempt: 1,
    acceptedCount: 2, failedCount: 0,
  });
  for (const value of [-1, 0.5, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1, '12', null, {}, []]) {
    assert.deepEqual(sanitizeAuditDetails({ count: value, durationMs: value, scanAttempt: value }), {});
  }
  assert.deepEqual(sanitizeAuditDetails({ cacheHit: 1, truncated: 'true' }), {});
});

test('audit metadata rejects phones, credentials, contact addresses and paths under safe keys', () => {
  for (const value of [
    '0501234567', '+972501234567', '050-123-4567', 'person@example.com',
    'https://example.com/file', '/home/private', '../private', 'C:\\private',
    'Bearer-private', 'password-private', 'api_key-private', 'sk-proj-private',
    'eyJhbGciOiJIUzI1NiJ9', 'hello world', 'line\nbreak', ' leading', 'trailing ',
    'a'.repeat(129),
  ]) {
    assert.deepEqual(sanitizeAuditDetails({ reasonCode: value, requestId: value, provider: value }), {}, value);
  }
  assert.deepEqual(sanitizeAuditDetails({ reasonCode: 'hidden..path', messageId: 'private/file' }), {});
});

test('stopped scan audit details retain typed usage limits without raw scan contents', () => {
  const budget = {
    frameCount: 10, providerCallsUsed: 60, providerCallsLimit: 60,
    googleVisionCallsUsed: 30, googleVisionCallsLimit: 30,
    openAICallsUsed: 20, openAICallsLimit: 20,
    geminiCallsUsed: 10, geminiCallsLimit: 10,
  };
  const status = { moderationStatus: 'stopped', previousStatus: 'pending',
    nextStatus: 'stopped', reasonCode: 'scan_stopped' };
  assert.deepEqual(sanitizeAuditDetails({ ...budget, ...status,
    budget: { frameCount: 10 }, frameResults: [{ text: 'private' }],
    reason: 'Private provider explanation',
  }), { ...budget, ...status });
  for (const value of [-1, 0.5, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1, '12', null, {}, []])
    assert.deepEqual(sanitizeAuditDetails(Object.fromEntries(
      Object.keys(budget).map(key => [key, value]))), {});
});

test('audit metadata keeps bounded identifiers, enumerated media and status values, and codes', () => {
  const input = {
    reasonCode: 'CONTENT_FILTER', blockedBy: 'recipient_filter', messageType: 'video',
    fileType: 'document', mimeType: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    provider: 'google_drive', model: 'gemini-2.5-flash', code: 'scan_pending',
    policyRevisionId: '42', providerCallId: 'req_abcd', storedFileId: UUID,
    messageId: UUID, requestId: 'req_123', clientMessageId: 'client-123',
    groupId: UUID, recipientId: UUID, queueId: 'queue_42', sourceFileId: UUID,
    rootEventId: '123', moderationStatus: 'approved', previousStatus: 'pending', nextStatus: 'completed',
  };
  assert.deepEqual(sanitizeAuditDetails(input), input);
  assert.deepEqual(sanitizeAuditDetails({
    mimeType: 'private/secrets', messageType: 'private_text', fileType: 'unknown_private',
    moderationStatus: 'private', previousStatus: 'unknown_state', nextStatus: 'arbitrary',
  }), {});
});

test('filter changes retain only explicitly typed before and after booleans', () => {
  const expected = {
    beforeText: true, afterText: true, beforeImage: false, afterImage: true,
    beforeVideo: false, afterVideo: true, beforeAudio: true, afterAudio: true,
    beforeDocument: true, afterDocument: false, beforeMen: false, afterMen: true,
    beforeWomen: true, afterWomen: false, beforeChildren: false, afterChildren: true,
    beforeNonHumanImages: true, afterNonHumanImages: true,
    beforeEnforceGeneralFilter: true, afterEnforceGeneralFilter: false,
  };
  assert.deepEqual(sanitizeAuditDetails({
    ...expected, before: { women: false }, after: { women: true },
  }), expected);
  for (const value of ['true', 'false', 1, 0, null, {}, []]) {
    assert.deepEqual(sanitizeAuditDetails({ beforeWomen: value, afterWomen: value }), {});
  }
});

test('HTTP metadata permits bounded server route templates and mutation methods only', () => {
  assert.deepEqual(sanitizeAuditDetails({
    httpRoute: '/api/groups/:groupId/messages/:messageId', httpMethod: 'PATCH',
  }), { httpRoute: '/api/groups/:groupId/messages/:messageId', httpMethod: 'PATCH' });
  for (const httpMethod of ['POST', 'PUT', 'PATCH', 'DELETE']) {
    assert.deepEqual(sanitizeAuditDetails({ httpMethod }), { httpMethod });
  }
  for (const httpRoute of [
    'https://example.com/api/messages', '/api/messages?token=private',
    '/api/person@example.com', '/api/../private', '/api/%2e%2e/private',
    '/api/..\\private', '/private/file', '/api/', '/api/' + 'a'.repeat(151),
    '/api/messages\n', {}, [], null,
  ]) assert.deepEqual(sanitizeAuditDetails({ httpRoute }), {});
  for (const httpMethod of ['GET', 'HEAD', 'OPTIONS', 'post', 'PATCH ', {}, null]) {
    assert.deepEqual(sanitizeAuditDetails({ httpMethod }), {});
  }
});

test('catalog exposes immutable rows, known coverage and Hebrew lifecycle status labels', () => {
  assert.deepEqual(STATUSES.map(row => row.code), [
    'running', 'pending', 'queued', 'completed', 'succeeded', 'failed',
    'blocked', 'rejected', 'cancelled', 'partial', 'skipped', 'observed',
  ]);
  assert.equal(Object.isFrozen(STATUSES), true);
  for (const row of STATUSES) {
    assert.deepEqual(Object.keys(row).sort(), ['code', 'label']);
    assert.match(row.label, /[\u0590-\u05ff]/);
    assert.equal(Object.isFrozen(row), true);
  }
  const coverage = new Set(COVERAGE.map(row => row.code));
  const categories = new Set(CATEGORIES.map(row => row.code));
  assert.equal(CATEGORIES.find(row => row.code === 'other').label, 'אחר');
  for (const row of [...COVERAGE, ...CATEGORIES]) {
    assert.match(row.label, /[\u0590-\u05ff]/);
    assert.doesNotMatch(row.label, /[a-z]/i);
  }
  for (const row of COVERAGE) {
    assert.match(row.description, /[\u0590-\u05ff]/);
    assert.doesNotMatch(row.description, /[a-z]/i);
  }
  assert.equal(Object.isFrozen(ACTION_CATALOG), true);
  assert.equal(ACTION_BY_KEY.size, ACTION_CATALOG.length);
  for (const row of ACTION_CATALOG) {
    assert.equal(Object.isFrozen(row), true);
    assert.equal(row.code, row.action);
    assert.match(row.label, /[\u0590-\u05ff]/);
    assert.doesNotMatch(row.label, /[a-z]/i);
    assert.equal(coverage.has(row.coverage), true, row.action);
    assert.equal(categories.has(row.category), true, row.action);
    assert.equal(lookupAction(row.action), row);
  }
  for (const action of [
    'send_message', 'send_group_message', 'send_file', 'upload_file', 'upload_pending',
    'filter_change', 'login', 'admin_action', 'audit_export', 'operation_started', 'api_mutation',
    'media_stored', 'media_moderation_changed', 'scan_queued', 'scan_attempt_started',
    'scan_queue_removed', 'message_persisted', 'message_delivery_state_changed',
    'contact_request_pending', 'contact_request_status_changed',
    'contact_request_removed', 'message_request_accepted',
    'request_completed', 'request_failed', 'request_aborted', 'scan_workflow_finished',
    'provider_call_finished', 'push_provider_result',
    'delete_account', 'report_message_read', 'manage_message_request', 'delete_message',
    'edit_message', 'manage_contacts', 'manage_backup', 'manage_calendar', 'manage_education',
    'manage_groups', 'manage_listings', 'manage_media', 'change_location', 'manage_invites',
    'manage_support', 'register_device', 'http_response', 'http_connection_closed',
    'scan_waiting', 'scan_attempt_failed', 'push_skipped', 'push_failed', 'media_reused',
    'scan_cache_used', 'message_retry_reused', 'server_message_status_changed',
  ]) assert.ok(lookupAction(action), action);
  assert.equal(lookupAction('filter_change').coverage, 'system_audit');
  assert.equal(lookupAction('admin_action').coverage, 'system_audit');
  assert.equal(SAFE_DETAILS_KEYS.includes('from'), false);
  assert.equal(SAFE_DETAILS_KEYS.includes('to'), false);
});

test('action lookup distinguishes unknown valid actions from invalid syntax', () => {
  assert.equal(normalizeAction('new_custom_action'), 'new_custom_action');
  assert.equal(lookupAction('new_custom_action'), null);
  for (const value of [null, 42, '', 'Send message', 'send/message', 'a'.repeat(81)]) {
    assert.equal(normalizeAction(value), null);
    assert.equal(lookupAction(value), null);
  }
});
