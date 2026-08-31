const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const server = fs.readFileSync(
  path.join(__dirname, '..', 'server', 'index.js'),
  'utf8',
);

function section(startMarker, endMarker) {
  const start = server.indexOf(startMarker);
  const end = server.indexOf(endMarker, start + startMarker.length);
  assert.ok(start >= 0 && end > start, `missing section: ${startMarker}`);
  return server.slice(start, end);
}

test('group ownership transfers to the longest-serving active member', () => {
  const helper = section(
    'async function transferOwnedGroups',
    '// ── Groups: remove member',
  );

  assert.match(helper, /status='member'/);
  assert.match(helper, /user_id<>\$2/);
  assert.match(helper, /ORDER BY joined_at ASC NULLS LAST, user_id ASC/);
  assert.match(helper, /UPDATE groups SET creator_id=\$1/);
  assert.match(helper, /UPDATE group_members SET role='admin'/);
});

test('an owned group is deleted when no active successor remains', () => {
  const helper = section(
    'async function transferOwnedGroups',
    '// ── Groups: remove member',
  );

  assert.match(helper, /if \(!successorId\)/);
  assert.match(helper, /DELETE FROM message_status/);
  assert.match(helper, /DELETE FROM messages WHERE group_id=\$1/);
  assert.match(helper, /DELETE FROM group_members WHERE group_id=\$1/);
  assert.match(helper, /DELETE FROM groups WHERE id=\$1/);
});

test('permanent group deletion removes retained scan-file records', () => {
  const route = section(
    "app.delete('/api/groups/:id'",
    '// ── Groups: update settings',
  );

  assert.match(route, /FROM stored_files[\s\S]*context_type='group'/);
  assert.match(route, /DELETE FROM stored_files/);
  assert.match(route, /deleteStoredFile\(public_url\)/);
});

test('group scan history is limited to the current membership lifetime', () => {
  const route = section(
    "app.get('/api/groups/:id/messages'",
    '// ── Groups: educational approvals',
  );

  assert.match(route, /sf\.created_at >= \(/);
  assert.match(route, /SELECT gm\.joined_at FROM group_members gm/);
  assert.match(route, /gm\.status='member'/);
});

test('ownership is transferred before a member leaves', () => {
  const route = section(
    "app.delete('/api/groups/:id/leave'",
    '// ── Groups: delete group permanently',
  );

  assert.ok(
    route.indexOf('transferOwnedGroups') <
      route.indexOf('DELETE FROM group_members'),
  );
  assert.match(route, /BEGIN/);
  assert.match(route, /COMMIT/);
  assert.match(route, /ROLLBACK/);
});

test('account deletion transfers owned groups before memberships are removed', () => {
  const route = section(
    "app.delete('/api/account'",
    "app.delete('/api/account/data'",
  );

  assert.ok(
    route.indexOf('transferOwnedGroups') <
      route.indexOf('DELETE FROM group_members'),
  );
});

test('startup repairs groups that were already left without an owner', () => {
  const startup = section(
    'CREATE TABLE IF NOT EXISTS group_members',
    '// ── Educational approvals',
  );

  assert.match(startup, /WHERE g\.creator_id IS NULL AND gm\.status='member'/);
  assert.match(startup, /ORDER BY gm\.group_id, gm\.joined_at ASC NULLS LAST/);
  assert.match(startup, /UPDATE groups g SET creator_id=s\.user_id/);
  assert.match(startup, /UPDATE group_members gm SET role='admin'/);
});

test('pending invitations still load while a group has no owner', () => {
  const route = section(
    "app.get('/api/groups/:id/invitation-filter'",
    "app.post('/api/groups/:id/join'",
  );

  assert.match(route, /LEFT JOIN users creator ON creator\.id=g\.creator_id/);
});
