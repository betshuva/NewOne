'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { REACTION_READ_SCHEMA, registerMessageReactions, projectReactionConversations,
  reactionUnreadCounts, markReactionsRead, visibleMessage } = require('../server/message-reactions');
const { contentAllowedByFilter } = require('../server/content-filter-policy');
const id = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const [a, b, c, outsider, messageId, groupId] = [111, 112, 113, 114, 115, 116].map(id);
const oldTime = '2026-10-01T12:00:00.000Z';
const newTime = '2026-10-07T12:00:00.000Z';
const reaction = (overrides = {}) => ({ message_id: messageId, actor_id: b, actor_name: 'מגיב בדיקה',
  emoji: '👍', updated_at: newTime, read_at: newTime, sender_id: a, recipient_id: b, group_id: null,
  type: 'text', target_id: b, unread: true, ...overrides });

function harness({ group = false, self = false, hidden = false, failTransport = false, filteredRecipient = false } = {}) {
  const actor = self ? a : b;
  const message = { id: messageId, sender_id: a, recipient_id: self ? a : b,
    group_id: group ? groupId : null, group_name: group ? 'קבוצת בדיקה' : null, type: 'text' };
  const members = self ? [a] : group ? [a, b, c] : [a, b];
  const pushes = [], events = [], writes = [];
  let emoji, generation = 0;
  const pool = { query: async (sql, values) => {
    if (sql.startsWith('SELECT m.id,m.sender_id')) return { rows: hidden ? [] : [message] };
    if (sql.startsWith('SELECT u.id,m.sender_id')) return { rows: members.map(viewer => ({ id: viewer,
      sender_id: a, type: filteredRecipient && viewer === c ? 'image' : 'text',
      receiving_filter: { women: false }, classification: { category: 'women' } })) };
    if (sql.startsWith('SELECT name FROM users')) return { rows: [{ name: 'מגיב בדיקה' }] };
    if (sql.startsWith('WITH changed AS')) {
      writes.push({ sql, values });
      if (emoji === values[2]) return { rows: [] };
      emoji = values[2];
      return { rows: [{ updated_at: new Date(Date.parse(newTime) + generation++ * 1000) }] };
    }
    if (sql.startsWith('DELETE FROM message_reactions')) {
      writes.push({ sql, values });
      if (!emoji) return { rows: [] };
      emoji = undefined;
      return { rows: [{ updated_at: new Date(Date.parse(newTime) + generation++ * 1000) }] };
    }
    if (sql.startsWith('SELECT emoji,COUNT')) return { rows: emoji ? [{ emoji, count: 1, mine: true }] : [] };
    assert.fail('unexpected reaction query');
  } };
  const handlers = new Map();
  const app = Object.fromEntries(['get', 'put'].map(method => [method,
    (path, ...middleware) => handlers.set(`${method} ${path}`, middleware.at(-1))]));
  registerMessageReactions(app, { auth() {}, rateLimit() {}, getPool: async () => pool, contentAllowedByFilter,
    notifyReaction: async (viewer, payload) => {
      events.push({ viewer, payload });
      if (failTransport) throw new Error('transport unavailable');
    }, sendPush: async (viewer, title, body, data) => {
      pushes.push({ viewer, title, body, data });
      if (failTransport) throw new Error('transport unavailable');
    } });
  return { actor, events, pushes, writes, async invoke(value, method = 'put', target = messageId) {
    const output = { status: 200, headers: {} };
    const res = { status: code => { output.status = code; return res; },
      set: (name, value) => { output.headers[name] = value; return res; },
      json: body => { output.body = body; return res; } };
    await handlers.get(`${method} /api/messages/:id/reactions`)({ user: { id: actor }, params: { id: target }, body: { emoji: value } }, res);
    await new Promise(resolve => setImmediate(resolve));
    return output;
  } };
}

test('adding a private reaction persists first and notifies the counterpart without a fake message', async () => {
  const api = harness();
  const result = await api.invoke('👍');
  assert.equal(result.status, 200);
  assert.equal(result.headers['Cache-Control'], 'no-store');
  assert.deepEqual(result.body, [{ emoji: '👍', count: 1, mine: true }]);
  assert.deepEqual(api.pushes.map(push => push.viewer), [a]);
  assert.deepEqual(api.events.map(event => [event.viewer, event.payload.targetId]), [[a, b], [b, a]]);
  assert.equal(api.pushes[0].data.type, 'chat');
  assert.equal(api.pushes[0].data.fromUserId, b);
  assert.equal(api.pushes[0].body, 'הגיב/ה 👍');
  assert.equal(api.events[0].payload.kind, 'chat');
  assert.equal(api.events[0].payload.messageId, messageId);
  assert.equal(api.events[0].payload.actorId, b);
  assert.deepEqual(api.writes[0].values[3], [a], 'actor never receives unread reaction activity');
  assert.doesNotMatch(api.writes[0].sql, /INSERT INTO messages\b/);
  assert.doesNotMatch(JSON.stringify(api.events), /fileUrl|replyBody|"text"|"body"/);
});

test('duplicate emoji requests are idempotent, replacement alerts once, and removal only refreshes', async () => {
  const api = harness();
  await api.invoke('👍');
  const firstEvent = api.events[0].payload.eventId;
  await api.invoke('👍');
  assert.equal(api.pushes.length, 1);
  assert.equal(api.events.length, 2);
  await api.invoke('❤️');
  assert.equal(api.pushes.length, 2);
  assert.notEqual(api.events[2].payload.eventId, firstEvent);
  const removed = await api.invoke(null);
  assert.deepEqual(removed.body, []);
  assert.equal(api.pushes.length, 2);
  assert.equal(api.events.length, 6);
  assert.equal(api.events[4].payload.emoji, null);
  assert.equal(api.events[4].payload.removed, true);
  assert.match(api.writes.at(-1).sql, /^DELETE FROM message_reactions/);
  await api.invoke(null);
  assert.equal(api.events.length, 6);
});

test('group reactions target allowed members individually and retain existing group push navigation', async () => {
  const api = harness({ group: true, filteredRecipient: true });
  await api.invoke('😂');
  assert.deepEqual(api.pushes.map(push => push.viewer), [a]);
  assert.equal(api.events.length, 2);
  assert.ok(api.events.every(event => event.payload.kind === 'group' && event.payload.targetId === groupId));
  assert.equal(api.pushes[0].data.groupId, groupId);
  assert.equal(api.pushes[0].data.groupName, 'קבוצת בדיקה');
  assert.ok(api.events.every(event => event.viewer !== outsider && event.viewer !== c));
});

test('hidden messages are rejected, self reactions remain private, and transport failure cannot fail persistence', async () => {
  const hidden = harness({ hidden: true });
  assert.equal((await hidden.invoke('👍')).status, 404);
  assert.equal(hidden.writes.length, 0);
  assert.equal(hidden.events.length, 0);
  const self = harness({ self: true });
  assert.equal((await self.invoke('🙏')).status, 200);
  assert.equal(self.pushes.length, 0);
  assert.deepEqual(self.writes[0].values[3], []);
  const failing = harness({ failTransport: true });
  assert.equal((await failing.invoke('👍')).status, 200);
  assert.equal((await failing.invoke('👍')).status, 200);
  assert.equal(failing.pushes.length, 1);
});

test('reaction watermarks preserve legacy receipts and use sent for watermark-only status rows', async () => {
  assert.match(REACTION_READ_SCHEMA, /ADD COLUMN IF NOT EXISTS reactions_read_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP/);
  const api = harness();
  await api.invoke('👍');
  const conflict = api.writes[0].sql.slice(api.writes[0].sql.lastIndexOf('ON CONFLICT'));
  assert.doesNotMatch(conflict, /SET status|status=|updated_at=/);
  assert.match(api.writes[0].sql, /id,'sent',changed.updated_at/);
  const queries = [];
  const db = { query: async (sql, values) => {
    queries.push({ sql, values });
    return { rows: sql.startsWith('SELECT r.message_id') ? [reaction({ sender_id: a }), reaction({ message_id: id(117) })] : [] };
  } };
  await markReactionsRead(db, a, 'chat', b, contentAllowedByFilter);
  assert.deepEqual(queries[1].values, [a, [messageId, id(117)], newTime]);
  assert.match(queries[1].sql, /SELECT id,\$1,'sent',\$3::timestamptz/);
  assert.match(queries[1].sql, /GREATEST\(message_status.reactions_read_at,EXCLUDED.reactions_read_at\)/);
  assert.doesNotMatch(queries[1].sql.slice(queries[1].sql.indexOf('ON CONFLICT')), /status=|updated_at=/);
});

test('durable preview selects current reaction activity and unread counts exclude read and hidden content', async () => {
  let rows = [reaction(), reaction({ actor_id: a, unread: false, updated_at: oldTime }),
    reaction({ type: 'image', classification: { category: 'women' }, receiving_filter: { women: false }, sender_id: b })];
  const db = { query: async sql => { assert.match(sql, /^SELECT /); return { rows }; } };
  const originals = [{ id: b, last_message_type: 'text', last_message: 'original', last_message_at: oldTime }];
  const [preview] = await projectReactionConversations(db, a, 'chat', originals, contentAllowedByFilter);
  assert.equal(preview.last_message_type, 'reaction');
  assert.equal(preview.last_message, '👍');
  assert.equal(preview.last_message_sender_name, 'מגיב בדיקה');
  assert.equal(preview.last_message_status, null);
  assert.equal(originals[0].last_message, 'original');
  assert.deepEqual(await reactionUnreadCounts(db, a, 'chat', contentAllowedByFilter), { [b]: 1 });
  rows = [];
  assert.deepEqual(await projectReactionConversations(db, a, 'chat', originals, contentAllowedByFilter), originals);
});

test('PostgreSQL read-only fixtures verify reaction visibility and legacy/read watermarks', {
  skip: process.env.RUN_REACTION_READ_DB_TESTS !== '1',
}, async t => {
  const { Client } = require('pg');
  const db = new Client({ connectionString: process.env.DATABASE_URL, connectionTimeoutMillis: 10000,
    ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' } : false });
  const definitions = {
    users: 'id uuid,name text,birth_date date,content_filter jsonb',
    messages: 'id uuid,sender_id uuid,recipient_id uuid,group_id uuid,type text,file_url text,created_at timestamptz,deleted_for_everyone boolean,deleted_for_sender boolean',
    group_members: 'group_id uuid,user_id uuid,status text,filter_override jsonb,joined_at timestamptz',
    groups: 'id uuid,name text,creator_id uuid,content_filter jsonb',
    user_contacts: 'owner_id uuid,contact_id uuid,filter_override jsonb',
    stored_files: 'public_url text,moderation_details jsonb',
    conversation_user_state: 'user_id uuid,kind text,target_id uuid,cleared_at timestamptz',
    message_user_deletions: 'message_id uuid,user_id uuid', blocked_users: 'blocker_id uuid,blocked_id uuid',
    message_reactions: 'message_id uuid,user_id uuid,emoji text,updated_at timestamptz',
    message_status: 'message_id uuid,user_id uuid,status text,reactions_read_at timestamptz',
  };
  const fixtures = Object.fromEntries(Object.keys(definitions).map(key => [key, []]));
  fixtures.users = [a, b, c, outsider].map(userId => ({ id: userId, name: 'בדיקה', birth_date: '1990-01-01', content_filter: { women: false } }));
  fixtures.messages = [{ id: messageId, sender_id: a, recipient_id: b, type: 'text', created_at: oldTime,
    deleted_for_everyone: false, deleted_for_sender: false }];
  fixtures.message_reactions = [{ message_id: messageId, user_id: b, emoji: '👍', updated_at: newTime }];
  const pool = { query: async (sql, values) => {
    assert.match(sql, /^SELECT /, 'this fixture executes no mutations or schema changes');
    const keys = Object.keys(definitions);
    const ctes = keys.map((key, index) => `${key} AS (SELECT * FROM jsonb_to_recordset($${values.length + index + 1}::jsonb) AS fixture(${definitions[key]}))`);
    return db.query(`WITH ${ctes.join(',')} ${sql}`, [...values, ...keys.map(key => JSON.stringify(fixtures[key]))]);
  } };
  await db.connect();
  try {
    await db.query('BEGIN READ ONLY');
    await t.test('absent status and migration-time watermark keep old reactions read; future activity remains unread', async () => {
      assert.deepEqual(await reactionUnreadCounts(pool, a, 'chat', contentAllowedByFilter), {});
      fixtures.message_status = [{ message_id: messageId, user_id: a, status: 'sent', reactions_read_at: oldTime }];
      assert.deepEqual(await reactionUnreadCounts(pool, a, 'chat', contentAllowedByFilter), { [b]: 1 });
      fixtures.message_status[0].reactions_read_at = '2026-10-08T00:00:00Z';
      assert.deepEqual(await reactionUnreadCounts(pool, a, 'chat', contentAllowedByFilter), {});
      assert.deepEqual(await reactionUnreadCounts(pool, b, 'chat', contentAllowedByFilter), {}, 'actor is never unread');
    });
    await t.test('both block directions, deletion and cleared history prevent access and previews', async () => {
      for (const block of [{ blocker_id: a, blocked_id: b }, { blocker_id: b, blocked_id: a }]) {
        fixtures.blocked_users = [block];
        assert.equal(await visibleMessage(pool, messageId, a, contentAllowedByFilter), null);
        assert.deepEqual(await projectReactionConversations(pool, a, 'chat', [{ id: b }], contentAllowedByFilter), [{ id: b }]);
      }
      fixtures.blocked_users = [];
      fixtures.message_user_deletions = [{ message_id: messageId, user_id: a }];
      assert.equal(await visibleMessage(pool, messageId, a, contentAllowedByFilter), null);
      fixtures.message_user_deletions = [];
      fixtures.conversation_user_state = [{ user_id: a, kind: 'chat', target_id: b, cleared_at: newTime }];
      assert.equal(await visibleMessage(pool, messageId, a, contentAllowedByFilter), null);
      fixtures.conversation_user_state = [];
    });
    await t.test('groups require current adult membership, joining before the message and permitted content', async () => {
      fixtures.groups = [{ id: groupId, creator_id: a, name: 'בדיקה' }];
      fixtures.messages[0].group_id = groupId;
      fixtures.group_members = [a, b].map(userId => ({ group_id: groupId, user_id: userId, status: 'member', joined_at: '2026-09-01T00:00:00Z' }));
      assert.ok(await visibleMessage(pool, messageId, b, contentAllowedByFilter));
      assert.equal(await visibleMessage(pool, messageId, outsider, contentAllowedByFilter), null);
      fixtures.group_members[1].status = 'left';
      assert.equal(await visibleMessage(pool, messageId, b, contentAllowedByFilter), null);
      fixtures.group_members[1].status = 'member';fixtures.group_members[1].joined_at = newTime;
      assert.equal(await visibleMessage(pool, messageId, b, contentAllowedByFilter), null);
      fixtures.group_members[1].joined_at = '2026-09-01T00:00:00Z';fixtures.users[1].birth_date = null;
      assert.equal(await visibleMessage(pool, messageId, b, contentAllowedByFilter), null);
      fixtures.users[1].birth_date = '1990-01-01';fixtures.messages[0].type = 'image';fixtures.messages[0].file_url = '/fixture';
      fixtures.stored_files = [{ public_url: '/fixture', moderation_details: { classification: { category: 'women' } } }];
      assert.equal(await visibleMessage(pool, messageId, b, contentAllowedByFilter), null);
      assert.ok(await visibleMessage(pool, messageId, a, contentAllowedByFilter), 'the author retains its own visible message');
    });
  } finally { await db.query('ROLLBACK');await db.end(); }
});
