'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const html = fs.readFileSync(process.env.TEST_AUDIT_HTML_PATH || path.join(__dirname, '..', 'admin-audit.html'), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
function helpers(fetch = async () => { throw new Error('Unexpected fetch'); }) {
  const module = { exports: {} };
  vm.runInNewContext(script, { module, Date, URL, URLSearchParams, AbortController,
    fetch, setTimeout, clearTimeout });
  return module.exports;
}

test('audit dates use inclusive local calendar days and UTC API boundaries', () => {
  const { buildQuery } = helpers();
  const result = buildQuery({ from: '2026-09-23', to: '2026-09-24', userId: ' 7 ',
    action: 'message.send', targetId: '', token: 'never-in-query' });
  assert.equal(result.from, new Date(2026, 8, 23).toISOString());
  assert.equal(result.to, new Date(2026, 8, 25).toISOString());
  assert.equal(result.userId, '7');
  assert.equal(result.action, 'message.send');
  assert.equal(result.token, undefined);
  assert.equal(result.targetId, undefined);
  assert.throws(() => buildQuery({ from: '2026-09-25', to: '2026-09-24' }));
});

test('audit pages append unique IDs without resorting or mutating previous rows', () => {
  const first = [{ id: 'first', status: 'stored' }, { id: 'second' }];
  const rows = helpers().mergeRows(first, [{ id: 'first', status: 'changed' }, { id: 'third' }]);
  assert.deepEqual(Array.from(rows, row => row.id), ['first', 'second', 'third']);
  assert.equal(rows[0].status, 'stored');
  assert.equal(first.length, 2);
});

test('hierarchy queries scope user operations and leave independent events unscoped', () => {
  const { hierarchyQuery } = helpers();
  const query = { limit: '50', before: 'opaque', columnFilters: '{"status":{"values":["failed"]}}' };
  const operations = hierarchyQuery(query, 'operations');
  assert.equal(operations.scope, 'user');
  assert.equal(operations.match, 'items');
  assert.equal(operations.before, 'opaque');
  assert.equal(operations.columnFilters, query.columnFilters);
  assert.equal(hierarchyQuery(query, 'events').scope, undefined);
  assert.equal(query.scope, undefined);
});

test('operation colors depend only on operation identity, not user or row position', () => {
  const { operationHue } = helpers();
  const first = '00000000-0000-4000-8000-000000000001';
  const second = '00000000-0000-4000-8000-000000000002';
  const hue = operationHue(first);
  assert.ok(hue >= 0 && hue < 360);
  assert.ok(Math.abs(hue - operationHue(second)) > 50);
  operationHue('an unrelated operation');
  assert.equal(operationHue(first), hue);
});

test('child display sorts copied correlated evidence by time and exact ID without changing cursor order', () => {
  const { chronologicalChildren } = helpers();
  const root = { id: 'op', root_event_id: '1' };
  const rows = [
    { id: '9007199254740994', operation_id: 'op', created_at: '2026-09-24T10:00:02Z' },
    { id: '9007199254740993', operation_id: 'op', created_at: '2026-09-24T10:00:02Z' },
    { id: '3', operation_id: 'op', created_at: '2026-09-24T10:00:03Z', kind: 'operation_started' },
    { id: '2', operation_id: 'other-op', created_at: '2026-09-24T10:00:01Z' },
    { id: '1', operation_id: 'op', created_at: '2026-09-24T10:00:00Z' },
  ];
  const before = JSON.stringify(rows);
  assert.deepEqual(Array.from(chronologicalChildren(rows, root), row => row.id),
    ['9007199254740993', '9007199254740994', '3']);
  assert.equal(JSON.stringify(rows), before);
  assert.equal(rows.at(-1).id, '1');
});

test('hierarchy summaries count recorded child evidence, never invent planned or completed stages', () => {
  const { childCount, elapsedFromRoot } = helpers();
  assert.equal(childCount({ sub_event_count: '2', event_count: '100' }), '2');
  assert.equal(childCount({ root_event_id: '1', event_count: '9007199254740994' }), '9007199254740993');
  assert.equal(childCount({ root_event_id: '1', event_count: '0' }), '0');
  assert.equal(childCount({ event_count: '10' }), null);
  assert.equal(childCount({ event_count: 'invalid', root_event_id: '1' }), null);
  const root = { created_at: '2026-09-24T10:00:00.042Z' };
  assert.equal(elapsedFromRoot({ created_at: '2026-09-24T10:00:01.048Z' }, root), '00:01');
  assert.equal(elapsedFromRoot({ created_at: '2026-09-24T09:59:59Z' }, root), '-');
  assert.equal(elapsedFromRoot({}, root), '-');
});

test('upload labels distinguish captured media from selected files without guessing history', () => {
  const { mediaActionLabel } = helpers();
  assert.equal(mediaActionLabel({ action: 'upload_file', media_type: 'video', capture_kind: 'camera_video' }), 'צילום וידאו');
  assert.equal(mediaActionLabel({ action: 'upload_file', media_type: 'video' }), 'העלאת וידאו');
  assert.equal(mediaActionLabel({ action: 'upload_file', media_type: 'image', capture_kind: 'camera_image' }), 'צילום תמונה');
  assert.equal(mediaActionLabel({ action: 'upload_file', media_type: 'audio', capture_kind: 'microphone' }), 'הקלטת קול');
  assert.equal(mediaActionLabel({ action: 'upload_file', media_type: 'audio', capture_kind: 'camera_video' }), 'העלאת קובץ קול');
  assert.equal(mediaActionLabel({ action: 'upload_file', original_name: 'betshuva-video-recorded.mp4' }), 'upload_file');
  assert.equal(mediaActionLabel({ action: 'send_message', media_type: 'video', capture_kind: 'camera_video' }), 'send_message');
});

test('recipient labels use recorded identity snapshots and distinguish group, user and missing context', () => {
  const { recipientLabel } = helpers();
  assert.equal(recipientLabel({}), 'לא תועד');
  assert.equal(recipientLabel({ recipient_id: 'user-id', recipient_type: 'user', recipient_name: 'נמען', recipient_short_id: '42' }), 'משתמש: נמען (ID 42)');
  assert.equal(recipientLabel({ recipient_id: 'group-id', recipient_type: 'group', recipient_name: 'קבוצת בדיקה' }), 'קבוצה: קבוצת בדיקה (ID group-id)');
  assert.equal(recipientLabel({ recipient_id: 'unknown-id', recipient_type: 'user' }), 'משתמש: unknown-id');
  assert.ok(recipientLabel({ recipient_id: 'safe-id', recipient_type: 'user', recipient_name: '<img onerror=alert(1)>' }).includes('<img onerror=alert(1)>'));
  assert.doesNotMatch(script, /innerHTML|insertAdjacentHTML|document\.write/);
  assert.match(script, /case 'recipient_identifier'/);
  assert.match(script, /\["display_action", "media_type", "capture_kind"\]/);
});

test('scan columns use semantic API labels and recorded check codes without inventing outcomes', () => {
  const { checkLabel, checkResultLabel } = helpers();
  const recorded = { checkLabel: 'זיהוי פנים', checkResultLabel: 'זוהו 2 פנים',
    details: { checkType: 'safe_search', checkOutcome: 'passed' } };
  assert.equal(checkLabel(recorded), 'זיהוי פנים');
  assert.equal(checkResultLabel(recorded), 'זוהו 2 פנים');
  assert.equal(checkLabel({ details: { checkType: 'face_detection' } }), 'איתור וספירת פנים');
  assert.equal(checkResultLabel({ details: { checkType: 'face_detection' }, status: 'completed' }), 'תוצאה לא תועדה');
  assert.equal(checkResultLabel({ details: { checkType: 'modesty', checkOutcome: 'uncertain' } }), 'תוצאה לא ודאית');
  assert.equal(checkResultLabel({ check_type: 'modesty', check_outcome: 'blocked' }), 'נמצא ממצא לחסימה');
  for (const row of [{}, { status: 'completed' }, { status: 'failed' },
    { details: { provider: 'openai', operation: 'modesty' } },
    { details: { checkType: 'toString', checkOutcome: 'constructor' } }]) {
    assert.equal(checkLabel(row), '-');
    assert.equal(checkResultLabel(row), '-');
  }
});

test('scan context preserves actual cached outcomes and displays recorded zero-based frames as one-based', () => {
  const { checkContext, checkResultLabel } = helpers();
  const row = { details: { checkType: 'modesty', checkOutcome: 'blocked',
    provider: 'gemini', frameIndex: 0, frameTimestampMs: 0, cacheHit: true } };
  assert.equal(checkContext(row), 'Gemini · תמונה 1 · שנייה 0 · תוצאה שמורה');
  assert.equal(checkResultLabel(row), 'נמצא ממצא לחסימה');
  assert.equal(checkContext({ details: { provider: 'google_vision', frameIndex: 3,
    frameTimestampMs: 1500 } }), 'Google Vision · תמונה 4 · שנייה 1.5');
  assert.equal(checkContext({ executor_type: 'provider', executor_id: 'openai' }), 'OpenAI');
  for (const value of [-1, 0.5, NaN, Infinity, '1', null, {}, []])
    assert.equal(checkContext({ details: { frameIndex: value, frameTimestampMs: value } }), '');
  assert.equal(checkContext({ details: { frameIndex: 90, provider: 'toString', cacheHit: 'true' } }), '');
});

test('scan column options and CSV queries retain independent purpose and outcome filters', () => {
  const { optionLabel, withColumnFilters } = helpers();
  assert.equal(optionLabel('check_type', { value: 'modesty' }), 'בדיקת צניעות הלבוש');
  assert.equal(optionLabel('check_outcome', { value: 'uncertain' }), 'תוצאה לא ודאית');
  assert.equal(optionLabel('check_outcome', { value: null }), '(ריק)');
  assert.equal(optionLabel('check_type', { value: 'face_detection', label: 'זיהוי פנים מוקלט' }), 'זיהוי פנים מוקלט');
  const columns = { check_type: { values: ['modesty'], exclude: false },
    check_outcome: { values: ['uncertain', null], exclude: false } };
  assert.deepEqual(JSON.parse(withColumnFilters({ mode: 'events' }, columns).columnFilters), columns);
  assert.match(script, /key==='check_outcome'/);
  assert.match(script, /appendFieldCells\(tr,'operations',row,root,control\)/);
  assert.match(script, /appendFieldCells\(tr,'events',row,root,control\)/);
});

test('standalone scan fallback labels match the API presentation contract', () => {
  const { CHECK_TYPE_LABELS, CHECK_OUTCOME_LABELS } = require('../server/audit-check-presentation');
  const { checkLabel, checkResultLabel } = helpers();
  for (const [checkType, label] of Object.entries(CHECK_TYPE_LABELS))
    assert.equal(checkLabel({ details: { checkType } }), label);
  for (const [checkOutcome, label] of Object.entries(CHECK_OUTCOME_LABELS))
    assert.equal(checkResultLabel({ details: { checkType: 'safe_search', checkOutcome } }), label);
});

test('preview URLs are restricted to the recorded event on the authenticated audit endpoint', () => {
  const { previewRequestUrl } = helpers();
  const path='/api/admin/audit/events/42/preview?size=thumb';
  assert.equal(previewRequestUrl(path,'42'),'https://betshuva.com/betshuva-app/api/admin/audit/events/42/preview?size=thumb');
  assert.equal(previewRequestUrl('/betshuva-app/api/admin/audit/events/42/preview?size=full','42'),
    'https://betshuva.com/betshuva-app/api/admin/audit/events/42/preview?size=full');
  for(const raw of [null,'','/uploads/photo.jpg','https://evil.test'+path,
    path+'&token=private',path+'&size=full',path+'#private',path.replace('/42/','/43/'),
    path.replace('thumb','other'),'https://user:secret@betshuva.com'+path])
    assert.equal(previewRequestUrl(raw,'42'),null);
  assert.equal(previewRequestUrl(path,'not-an-event'),null);
});

test('preview fetches use header authorization and require bounded raster image responses', async () => {
  const calls=[],blob={size:123};
  const { fetchCheckPreview }=helpers(async(url,options)=>{
    calls.push({url,options});return {ok:true,headers:{get:key=>key==='content-type'?'image/png':'123'},blob:async()=>blob};
  });
  assert.equal(await fetchCheckPreview('/api/admin/audit/events/42/preview?size=thumb','42',{token:'mock-only-token'}),blob);
  assert.equal(calls.length,1);
  assert.equal(calls[0].options.headers.Authorization,'Bearer mock-only-token');
  assert.equal(calls[0].options.redirect,'error');
  assert.equal(calls[0].options.cache,'no-store');
  assert.equal(new URL(calls[0].url).search,'?size=thumb');
  for(const [type,size,status]of [['text/html',123,200],['image/svg+xml',123,200],
    ['image/png',11*1024*1024,200],['image/png',0,200],['image/png',123,401]]) {
    const helper=helpers(async()=>({ok:status===200,status,
      headers:{get:key=>key==='content-type'?type:String(size)},blob:async()=>({size})}));
    await assert.rejects(helper.fetchCheckPreview('/api/admin/audit/events/42/preview?size=thumb','42',
      {token:'mock-only-token'}));
  }
});

test('hierarchy renders children in the main table and keeps accessible collapse controls', () => {
  assert.match(script, /class:'child-row','data-event-id':row\?.id,'data-parent-operation-id':root.id/);
  assert.match(script, /aria-controls/);
  assert.match(script, /byId\('collapse-all'\)\.onclick/);
  assert.doesNotMatch(script, /class:'event-table'/);
  assert.match(script, /chronologicalChildren\(page.rows,root\)/);
  assert.match(script, /if\(current\(\)\)\{page.loading=false;page.controller=null;render\(\);restoreTableAnchor\(anchor\)/);
});

test('safe detail projection redacts secrets recursively and bounds arrays and strings', () => {
  const { safeDetails } = helpers();
  const result = safeDetails({ details: { before: false, after: true, token: 'secret',
    audio_transcript: 'private speech', email: 'private@example.test', body: 'private message',
    nested: { authorization: 'Bearer secret', attempt: 2 } }, many: Array(200).fill(1),
    long: 'x'.repeat(800), reason: '<img src=x onerror=bad()>' });
  const json = JSON.stringify(result);
  assert.ok(!json.includes('private speech'));
  assert.ok(!json.includes('private@example.test'));
  assert.ok(!json.includes('private message'));
  assert.ok(!json.includes('Bearer secret'));
  assert.equal(result.details.before, false);
  assert.equal(result.details.after, true);
  assert.equal(result.details.nested.attempt, 2);
  assert.equal(result.many.length, 100);
  assert.equal(result.long.length, 503);
  assert.equal(result.reason, '<img src=x onerror=bad()>');
});

test('stored, delivered and unknown execution identities remain distinct', () => {
  const { statusLabel, actor } = helpers();
  assert.equal(statusLabel('stored'), 'נשמר בשרת');
  assert.notEqual(statusLabel('stored'), statusLabel('delivered'));
  assert.equal(actor({ executor_type: 'service', executor_id: 'worker' }, true), 'שירות: worker');
  for (const [executor_type, label] of Object.entries({ user: 'משתמש', admin: 'מנהל',
    worker: 'שירות', system: 'מערכת', provider: 'ספק', client: 'מכשיר' })) {
    assert.equal(actor({ executor_type, executor_id: 'synthetic-id' }, true), `${label}: synthetic-id`);
  }
  assert.equal(actor({ executor_type: 'unknown', executor_name: 'unverified' }, true), 'מבצע לא ידוע');
  assert.equal(actor({ source: 'worker' }, true), 'מבצע לא ידוע');
  assert.equal(actor({ source: 'worker' }), 'יוזם לא ידוע');
});

test('event labels distinguish persistence, provider outcome and client evidence', () => {
  const { actionLabel } = helpers();
  assert.equal(actionLabel('media_stored'), 'מדיה נשמרה בשרת');
  assert.equal(actionLabel('push_provider_result'), 'תשובת ספק ההתראות');
  assert.equal(actionLabel('client_displayed'), 'דיווח תצוגה מהמכשיר');
  for (const code of ['scan_queued', 'scan_attempt_started', 'scan_waiting',
    'scan_attempt_failed', 'scan_workflow_finished', 'scan_queue_removed',
    'http_response', 'http_connection_closed', 'provider_call_finished',
    'scan_cache_used', 'push_skipped', 'message_retry_reused',
    'server_message_status_changed', 'media_moderation_changed']) {
    assert.notEqual(actionLabel(code), code);
  }
});

test('local timestamps use day/month/two-digit year, 24-hour time and hundredths without rolling forward', () => {
  const { time } = helpers();
  const stamp = (month,day,hour,minute,second,millisecond) => new Date(2026,month-1,day,hour,minute,second,millisecond).toISOString();
  assert.equal(time(stamp(9,27,1,45,32,199)), '27/09/26 01:45:32.19');
  assert.equal(time(stamp(1,2,0,0,0,0)), '02/01/26 00:00:00.00');
  assert.equal(time(stamp(12,31,23,59,59,999)), '31/12/26 23:59:59.99');
  assert.equal(time(stamp(9,27,13,4,5,9)), '27/09/26 13:04:05.00');
  assert.equal(time(stamp(9,27,13,4,5,10)), '27/09/26 13:04:05.01');
  assert.equal(time(null), 'זמן לא ידוע');
  assert.equal(time('invalid'), 'זמן לא ידוע');
});

test('audit requests are GET-only with header authentication and opaque cursors', async () => {
  const calls = [];
  const { apiRequest } = helpers(async (url, options) => {
    calls.push({ url, options });
    return { ok: true, status: 200 };
  });
  await apiRequest('operations', { userId: '7', before: 'opaque+/=' }, { token: 'test-secret' });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].options.method, 'GET');
  assert.equal(calls[0].options.headers.Authorization, 'Bearer test-secret');
  assert.equal(calls[0].url.searchParams.get('before'), 'opaque+/=');
  assert.ok(!calls[0].url.toString().includes('test-secret'));
  assert.ok(!calls[0].url.searchParams.has('token'));
});

test('authorization errors do not echo raw response content', async () => {
  const { apiRequest } = helpers(async () => ({ ok: false, status: 403,
    json: async () => ({ error: 'private-server-detail' }) }));
  await assert.rejects(apiRequest('operations', {}, { token: 'test' }),
    error => error.message === 'אין הרשאה לצפייה ביומן');
});

test('audit deletion keeps operation and exact bigint event scopes distinct', () => {
  const { deletionTarget } = helpers();
  const root = deletionTarget({ id: 'op-id', root_event_id: '1' });
  assert.equal(root.kind, 'operations');
  assert.equal(root.root, false);
  const child = deletionTarget({ id: '9007199254740993', operation_id: 'op-id', root_event_id: '1' });
  assert.equal(child.kind, 'events');
  assert.equal(child.id, '9007199254740993');
  assert.equal(child.operationId, 'op-id');
  assert.equal(child.root, false);
  assert.equal(deletionTarget({ id: '1', root_event_id: '1', operation_id: 'op-id' }).root, true);
  assert.equal(deletionTarget({ id: '2', kind: 'operation_started', operation_id: 'op-id' }).root, true);
  assert.equal(deletionTarget({ id: '2', root_event_id: '1', kind: 'operation_started', operation_id: 'op-id' }).root, false);
});

test('audit deletion sends only exact confirmation via authenticated DELETE and never query credentials', async () => {
  const calls = [];
  const { deleteAuditRecord } = helpers(async (url, options) => {
    calls.push({ url, options });
    return { ok: true, status: 200, json: async () => ({ deleted: true, deletedEvents: 1 }) };
  });
  for (const [kind, id] of [['operations', '00000000-0000-4000-8000-000000000001'], ['events', '9007199254740993']]) {
    const result = await deleteAuditRecord(kind, id, { token: 'private-token' });
    assert.equal(result.deleted, true);
    const call = calls.at(-1);
    assert.equal(call.options.method, 'DELETE');
    assert.equal(call.options.headers.Authorization, 'Bearer private-token');
    assert.equal(call.options.headers['Content-Type'], 'application/json');
    assert.deepEqual(JSON.parse(call.options.body), { confirmId: id });
    assert.ok(call.url.endsWith(`/${kind}/${id}`));
    assert.ok(!call.url.includes('private-token'));
    assert.equal(new URL(call.url).search, '');
  }
  for (const [kind, id] of [['all', '1'], ['events', '../operations/1'], ['operations', 'not-uuid'], ['events', 1]]) {
    await assert.rejects(deleteAuditRecord(kind, id, { token: 'private-token' }));
  }
  assert.equal(calls.length, 2);
});

test('deletion handles stale rows and failures without exposing server response details', async () => {
  for (const status of [400, 401, 403, 409, 503]) {
    const { deleteAuditRecord } = helpers(async () => ({ ok: false, status,
      json: async () => ({ error: 'private server detail' }) }));
    await assert.rejects(deleteAuditRecord('events', '2', { token: 'private' }),
      error => error.message.length > 0 && !error.message.includes('private'));
  }
  const { deleteAuditRecord } = helpers(async () => ({ ok: false, status: 404 }));
  assert.equal((await deleteAuditRecord('events', '2', { token: 'private' })).missing, true);
  const malformed = helpers(async () => ({ ok: true, status: 200, json: async () => ({}) }));
  await assert.rejects(malformed.deleteAuditRecord('events', '2'), /לא התקבל אישור/);
  const invalidJson = helpers(async () => ({ ok: true, status: 200,
    json: async () => { throw new SyntaxError('private malformed response'); } }));
  await assert.rejects(invalidJson.deleteAuditRecord('events', '2'),
    error => !error.message.includes('private') && error.message.includes('לא התקבל אישור'));
  const aborted = helpers(async () => { throw Object.assign(new Error('private'), { name: 'AbortError' }); });
  await assert.rejects(aborted.deleteAuditRecord('events', '2'), /לא התקבל אישור/);
});

test('deletion controls require edit catalog permission and pause polling during confirmation', () => {
  assert.match(script, /canDelete=data.canDelete===true/);
  assert.match(script, /if\(canDelete\)/);
  assert.match(script, /deleteTarget\|\|deleteBusy/);
  assert.match(script, /if\(!deleteTarget\|\|deleteBusy\|\|!canDelete\)return/);
  assert.match(html, /id="delete-dialog"[^>]*aria-describedby="delete-description"/);
  assert.match(script, /byId\('delete-cancel'\)\.focus\(\)/);
  assert.match(script, /הודעות וקבצים לא יימחקו/);
});

test('audit auto refresh retains cancellation through response body consumption', async () => {
  const controller = new AbortController();
  let began;
  const consuming = new Promise(resolve => { began = resolve; });
  const { apiRequest } = helpers(async (_url, options) => ({ ok: true, status: 200,
    json: () => new Promise((_resolve, reject) => {
      options.signal.addEventListener('abort', () => reject(new Error('body-aborted')), { once: true });
      began();
    }) }));
  const request = apiRequest('operations', {}, { token: 'test', signal: controller.signal,
    consume: response => response.json() });
  const rejected = assert.rejects(request, /body-aborted/);
  await consuming;
  controller.abort();
  await rejected;
});

test('standalone audit page uses tables, inert text, bounded exports and stale guards', () => {
  assert.match(html, /<html lang="he" dir="rtl">/);
  assert.match(html, /<table id="audit-table">/);
  assert.match(html, /url\('assets\/fonts\/MaterialIcons-Audit\.otf'\)/);
  assert.match(script, /const OP_WIDTHS = COLUMN_SCHEMAS.operations.map/);
  assert.doesNotMatch(html, /⇩|↻|ⓘ|⧉|⌃|⌄/);
  assert.match(script, /textContent=JSON\.stringify\(safeDetails\(row\)/);
  assert.doesNotMatch(script, /innerHTML|insertAdjacentHTML|document\.write/);
  assert.match(script, /generation!==state\.generation/);
  assert.match(script, /request!==state\.request/);
  assert.match(script, /request===page\.request&&state.pages.get\(id\)===page&&state.expanded.has\(id\)/);
  assert.match(script, /MAX_EXPORT_BYTES/);
  assert.match(script, /31\*86400000/);
  assert.match(script, /x-audit-export-truncated/);
  assert.doesNotMatch(script, /setInterval|method:['"](?:POST|PATCH)/);
  assert.doesNotMatch(helpers().apiRequest.toString(), /DELETE/);
  assert.equal((script.match(/method:'DELETE'/g) || []).length, 2);
});

test('column selections distinguish all, none, exclusions and blank values', () => {
  const { selectedValue, toggleColumnValue } = helpers();
  const all = { values: [], exclude: true };
  assert.equal(selectedValue(all, 'pending'), true);
  const excluded = toggleColumnValue(all, 'pending', false);
  assert.equal(selectedValue(excluded, 'pending'), false);
  assert.equal(selectedValue(excluded, 'future-value-not-loaded'), true);
  assert.equal(all.values.length, 0);
  const none = { values: [], exclude: false };
  assert.equal(selectedValue(none, null), false);
  const blankOnly = toggleColumnValue(none, null, true);
  assert.equal(selectedValue(blankOnly, null), true);
  assert.equal(selectedValue(blankOnly, ''), false);
  assert.equal(toggleColumnValue(blankOnly, null, false).values.length, 0);
  assert.throws(() => toggleColumnValue({ values: Array.from({ length: 100 }, (_, i) => String(i)), exclude: false }, 'extra', true));
});

test('column query serialization preserves top filters without mutating them', () => {
  const { withColumnFilters } = helpers();
  const base = { from: '2026-09-24T00:00:00Z', userId: '42' };
  const columns = { status: { values: ['pending', null], exclude: false } };
  const query = withColumnFilters(base, columns);
  assert.deepEqual(JSON.parse(query.columnFilters), columns);
  assert.equal(query.userId, '42');
  assert.equal(base.columnFilters, undefined);
  assert.equal(withColumnFilters(base, {}).columnFilters, undefined);
});

test('header range filters retain integer precision and exclusive timestamp boundaries', () => {
  const { rangeFilter, dateInputValue } = helpers();
  assert.equal(rangeFilter('event_count', '', ''), null);
  assert.equal(rangeFilter('duration_ms', '0', '9223372036854775807').max, '9223372036854775807');
  for (const [start, end] of [['2', '1'], ['-1', ''], ['1.2', ''], ['9223372036854775808', '']]) {
    assert.throws(() => rangeFilter('event_count', start, end));
  }
  const range = rangeFilter('created_at', '2026-09-24T10:11:12.123', '2026-09-24T10:11:12.124');
  assert.equal(Date.parse(range.to) - Date.parse(range.from), 1);
  assert.equal(dateInputValue(range.from), '2026-09-24T10:11:12.123');
  assert.throws(() => rangeFilter('created_at', '2026-09-24T10:00', '2026-09-24T10:00'));
  assert.throws(() => rangeFilter('created_at', 'invalid', ''));
});

test('main table headers also filter expanded event chains on the server', () => {
  assert.match(script, /data\.options/);
  assert.match(script, /apiRequest\('filter-options'/);
  assert.match(script, /query=\{\.\.\.activeColumnQuery\(\),limit:'50'/);
  assert.match(script, /apiRequest\('export\.csv',\{\.\.\.activeColumnQuery\(\),\.\.\.exportRange,mode\}/);
  assert.match(script, /tableHead\(state.mode==='events'\?EVENT_COLUMNS:OP_COLUMNS/);
  assert.match(script, /apiRequest\(`operations\/\$\{encodeURIComponent\(id\)\}\/events`,\{\.\.\.query,\.\.\.paging\}/);assert.match(script,/readAllEvents/);assert.doesNotMatch(script,/data-event-more/);
  assert.doesNotMatch(html, /id="filter-form"|id="filters"/);
  assert.match(script, /columnPopup!==popup\|\|request!==popup\.request/);
  assert.match(html, /id="column-dialog" aria-labelledby="column-title"/);
  assert.match(script, /aria-haspopup','dialog'/);
});

const liveOperation = (number, extra = {}) => ({
  id: `00000000-0000-4000-8000-${String(number).padStart(12, '0')}`,
  created_at: new Date(Date.UTC(2026, 8, 24) + number * 1000).toISOString(),
  status: 'pending', ...extra,
});

test('live audit sort keys retain bigint precision and UUID tie ordering', () => {
  const { auditRowKey, compareAuditKeys } = helpers();
  assert.equal(compareAuditKeys(auditRowKey({ id: '9007199254740993' }, 'events'),
    auditRowKey({ id: '9007199254740992' }, 'events'), 'events'), 1);
  const older = liveOperation(1), newer = liveOperation(2, { created_at: older.created_at });
  assert.equal(compareAuditKeys(auditRowKey(newer, 'operations'),
    auditRowKey(older, 'operations'), 'operations'), 1);
  assert.equal(auditRowKey(null, 'operations'), null);
  assert.throws(() => auditRowKey({ id: 'not-an-integer' }, 'events'));
  assert.throws(() => auditRowKey({ id: 'id', created_at: 'invalid' }, 'operations'));
});

test('auto refresh replaces a loaded prefix including old status changes and trims older history', async () => {
  const { readAuditWindow, auditRowKey } = helpers();
  const calls = [], boundary = auditRowKey(liveOperation(2), 'operations');
  const result = await readAuditWindow(async paging => {
    calls.push(paging);
    return calls.length === 1
      ? { operations: [liveOperation(5), liveOperation(4)], nextCursor: 'fresh-page-2' }
      : { operations: [liveOperation(3, { status: 'completed' }), liveOperation(2), liveOperation(1)], nextCursor: 'fresh-page-3' };
  }, { mode: 'operations', cursor: 'original-oldest-cursor', boundary, budget: { used: 0, max: 20 } });
  assert.deepEqual(Array.from(result.rows, row => row.id), [5, 4, 3, 2].map(n => liveOperation(n).id));
  assert.equal(result.rows[2].status, 'completed');
  assert.equal(result.cursor, 'original-oldest-cursor');
  assert.equal(result.boundary, boundary);
  assert.equal(calls[0].limit, '200');
  assert.equal(calls[0].before, undefined);
  assert.equal(calls[1].before, 'fresh-page-2');
});

test('live window retains its fence after a filtered-out boundary row and catches its later return', async () => {
  const { readAuditWindow, auditRowKey } = helpers();
  const boundary = auditRowKey(liveOperation(2), 'operations');
  const first = await readAuditWindow(async () => ({ operations: [liveOperation(4), liveOperation(1)], nextCursor: null }),
    { mode: 'operations', cursor: 'old-fence', boundary, budget: { used: 0, max: 20 } });
  assert.equal(first.cursor, 'old-fence');
  assert.deepEqual(Array.from(first.rows, row => row.id), [liveOperation(4).id]);
  const second = await readAuditWindow(async () => ({ operations: [liveOperation(5), liveOperation(4), liveOperation(3), liveOperation(2), liveOperation(1)], nextCursor: null }),
    { mode: 'operations', cursor: first.cursor, boundary: first.boundary, budget: { used: 0, max: 20 } });
  assert.deepEqual(Array.from(second.rows, row => row.id), [5, 4, 3, 2].map(n => liveOperation(n).id));
  assert.equal(second.cursor, 'old-fence');
});

test('auto refresh clears pagination only when the server ends without trimmed rows', async () => {
  const { readAuditWindow, auditRowKey } = helpers();
  const boundary = auditRowKey(liveOperation(2), 'operations');
  for (const rows of [[liveOperation(4)], [liveOperation(3), liveOperation(2)], []]) {
    const result = await readAuditWindow(async () => ({ operations: rows, nextCursor: null }),
      { mode: 'operations', cursor: 'old-fence', boundary, budget: { used: 0, max: 20 } });
    assert.equal(result.cursor, null);
  }
});

test('all-loaded views fetch through the end including newly matching old records', async () => {
  const { readAuditWindow, auditRowKey } = helpers();
  let calls = 0;
  const result = await readAuditWindow(async () => ++calls === 1
    ? { events: [{ id: '9' }, { id: '8' }], nextCursor: 'older' }
    : { events: [{ id: '8' }, { id: '3' }], nextCursor: null },
  { mode: 'events', cursor: null, boundary: auditRowKey({ id: '8' }, 'events'), budget: { used: 0, max: 20 } });
  assert.deepEqual(Array.from(result.rows, row => row.id), ['9', '8', '3']);
  assert.equal(result.cursor, null);
  assert.equal(calls, 2);
});

test('live refresh budgets, repeated cursors and request failures never return a partial window', async () => {
  const { readAuditWindow } = helpers();
  const budget = { used: 0, max: 1 };
  let calls = 0;
  await assert.rejects(readAuditWindow(async () => { calls++; return { events: [{ id: '3' }], nextCursor: 'next' }; },
    { mode: 'events', cursor: null, boundary: null, budget }), /טווח הרשומות גדול מדי/);
  assert.equal(calls, 1);
  await assert.rejects(readAuditWindow(async () => ({ events: [{ id: '3' }], nextCursor: 'same' }),
    { mode: 'events', cursor: null, boundary: null, budget: { used: 0, max: 20 } }), /רצף העדכון אינו תקין/);
  calls = 0;
  await assert.rejects(readAuditWindow(async () => {
    if (++calls === 1) return { events: [{ id: '3' }], nextCursor: 'next' };
    throw new Error('offline');
  }, { mode: 'events', cursor: null, boundary: null, budget: { used: 0, max: 20 } }), /offline/);
});

test('live audit uses bounded chained polling with lifecycle and stale-result guards', () => {
  const { AUTO_REFRESH_MS, AUTO_REFRESH_MAX_REQUESTS } = helpers();
  assert.equal(AUTO_REFRESH_MS, 5000);
  assert.equal(AUTO_REFRESH_MAX_REQUESTS, 20);
  assert.match(script, /setTimeout\(\(\)=>autoRefresh\(\),delay\)/);
  assert.match(script, /visibilitychange/);
  assert.match(script, /pagehide/);
  assert.match(script, /state\.liveController\?\.abort/);
  assert.match(script, /request===state\.liveRequest&&generation===state\.generation/);
  assert.match(script, /String\(page\.eventCount\)===String\(root\.event_count\)/);
  assert.match(script, /captureTableAnchor\(\)/);
  assert.match(script, /restoreTableAnchor\(anchor\)/);
  assert.match(html, /id="live-error"/);
});

test('step numbering keeps server ordinals and column migration preserves saved order and filters',()=>{
  const {subEventPosition,normalizedColumnOrder,childColumnQuery}=helpers();
  assert.equal(subEventPosition({sub_event_index:'9007199254740993',sub_event_total:'9007199254740994'},{}),'9007199254740993 מתוך 9007199254740994');
  assert.equal(subEventPosition({sub_event_index:'2',sub_event_total:'5'},{}),'2 מתוך 5');
  assert.equal(subEventPosition({sub_event_index:'6',sub_event_total:'5'},{}),'');
  assert.equal(subEventPosition({},{}),'');
  const order=Array.from(normalizedColumnOrder('operations',['status','action','created_at']));
  assert.deepEqual(order.filter(key=>['status','action','created_at'].includes(key)),['status','action','created_at']);assert.equal(new Set(order).size,order.length);
  const query=childColumnQuery({action:{values:['upload_file']},kind:{values:['scan_queued']}});
  assert.deepEqual(JSON.parse(query.columnFilters),{kind:{values:['scan_queued']}});
  assert.equal(query.steps,'1');assert.equal(query.sort,'created_at');assert.equal(query.direction,'asc');
});

test('whole-operation outcome distinguishes a stopped scan from its completed first step and treats calls as a budget',()=>{
  const {operationOutcome,scanBudgetText}=helpers();
  const root={status:'failed',status_source:'scan_workflow_finished',reason_code:'scan_stopped',
    first_sub_event:{kind:'upload_context',status:'completed'},
    outcome_event:{status:'failed',reason_code:'scan_stopped'},
    scan_summary:{status:'failed',reason_code:'scan_incomplete',details:{providerCallsUsed:29,providerCallsLimit:36}}};
  const result=operationOutcome(root);assert.match(result.headline,/הסריקה נעצרה/);assert.equal(result.reason,'בדיקה נדרשת לא הושלמה');assert.equal(result.budget,'נוצלו 29 מתוך מכסה של 36 קריאות בדיקה');assert.doesNotMatch(result.budget,/הצליחו|הושלמו/);
  assert.equal(operationOutcome({...root,scan_summary:null}).budget,'');
  assert.equal(operationOutcome({...root,status:'completed',scan_summary:null,outcome_event:{status:'completed'},reason_code:null}).budget,'');
  assert.doesNotMatch(operationOutcome({status:'running'}).headline,/הושלם|נעצרה/);
  assert.equal(scanBudgetText({details:{providerCallsUsed:0,providerCallsLimit:36}}),'נוצלו 0 מתוך מכסה של 36 קריאות בדיקה');
  for(const details of [{},{providerCallsUsed:29},{providerCallsUsed:'29',providerCallsLimit:36},{providerCallsUsed:-1,providerCallsLimit:36}])assert.equal(scanBudgetText({details}),'');
});

test('child queries keep initiator filters on the operation instead of rewriting them as executor filters',()=>{
 const {childColumnQuery,actor}=helpers();
 const filters={initiator_id:{values:['00000000-0000-4000-8000-000000000001']},executor_id:{values:['api']}};
 assert.deepEqual(JSON.parse(childColumnQuery(filters).columnFilters),filters);
 assert.equal(actor({executor_type:'system',executor_id:'api'},true),'מערכת: השרת (API)');
 assert.equal(actor({initiator_id:'person',initiator_name:'יוזם',initiator_short_id:'10',executor_type:'system',executor_id:'api'}),'משתמש: יוזם (ID 10)');
});

test('durations use minutes and seconds without rounding into the next second or losing bigint precision',()=>{
 const {formatDuration,elapsedFromRoot,durationFilterValue}=helpers();
 for(const [ms,text]of [[0,'00:00'],[3,'<00:01'],['999','<00:01'],[1000,'00:01'],[59999,'00:59'],[60000,'01:00'],[155000,'02:35'],[3600000,'60:00'],['9223372036854775807','153722867280912:55']])assert.equal(formatDuration(ms),text);
 for(const ms of [null,undefined,-1,1.5,true,'wrong','9223372036854775808',Number.MAX_SAFE_INTEGER+1])assert.equal(formatDuration(ms),'-');
 assert.equal(elapsedFromRoot({created_at:'2026-09-27T08:02:35Z'},{created_at:'2026-09-27T08:00:00Z'}),'02:35');
 assert.equal(formatDuration('155003',true),'02:35.003');assert.equal(durationFilterValue('02:35'),'155000');assert.equal(durationFilterValue('00:00.003'),'3');
 assert.equal(durationFilterValue(''), '');assert.equal(durationFilterValue(formatDuration('9223372036854775807',true)),'9223372036854775807');
 for(const input of ['2:60','-1:00','155000','00:00.0001','9999999999999999:59'])assert.throws(()=>durationFilterValue(input));
});


test('expanded operations load every cursor page, deduplicate IDs, and reject incomplete or stalled chains',async()=>{
 const {readAllEvents}=helpers();let calls=0;
 const all=await readAllEvents(async paging=>{assert.equal(paging.limit,'200');assert.equal(paging.before,calls?String(calls):undefined);const index=++calls;return {events:Array.from({length:200},(_,offset)=>({id:String((index-1)*200+offset+1)})),nextCursor:index<22?String(index):null};});
 assert.equal(calls,22);assert.equal(all.rows.length,4400);assert.equal(all.cursor,null);assert.equal(all.rows.at(-1).id,'4400');
 let step=0;const dedup=await readAllEvents(async()=>++step===1?{events:[{id:'1',status:'pending'},{id:'2'}],nextCursor:'next'}:{events:[{id:'1',status:'completed'},{id:'3'}],nextCursor:null});assert.deepEqual(Array.from(dedup.rows,row=>row.id),['1','2','3']);assert.equal(dedup.rows[0].status,'completed');
 await assert.rejects(readAllEvents(async()=>({events:[],nextCursor:'next'})),/רצף/);
 let repeat=0;await assert.rejects(readAllEvents(async()=>({events:[{id:String(++repeat)}],nextCursor:'repeat'})),/רצף/);
 let failed=0;await assert.rejects(readAllEvents(async()=>{if(++failed===2)throw new Error('offline');return {events:[{id:'1'}],nextCursor:'next'};}),/offline/);
 await assert.rejects(readAllEvents(async()=>({events:null})),/טעינת/);
});


test('preview column selects the operation image for every step without relabelling check evidence', () => {
  const { operationPreviewRow } = helpers();
  const step = { id: '9', details: { frameIndex: 4 }, checkPreviewUrl: '/api/admin/audit/events/9/preview?size=thumb' };
  const preview = { eventId: '3', mediaType: 'video', url: '/api/admin/audit/events/3/preview?size=thumb',
    fullUrl: '/api/admin/audit/events/3/preview?size=full' };
  const display = operationPreviewRow(step, { operationPreview: preview });
  assert.equal(display.id, '3');
  assert.equal(display.checkLabel, 'הפריים הראשון בסרטון');
  assert.equal(display.details, undefined);
  assert.equal(step.details.frameIndex, 4);
  assert.equal(operationPreviewRow({ operationPreview: preview }, {}).id, '3');
  assert.equal(operationPreviewRow({}, { operationPreview: { ...preview, mediaType: 'image' } }).checkLabel, 'התמונה שהועלתה');
  assert.equal(operationPreviewRow(step, { operationPreview: null }).checkPreviewUrl, undefined);
});
