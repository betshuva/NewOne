'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { randomUUID, randomBytes } = require('node:crypto');
const express = require('express');
const { SCHEMA, createGroupInviteLinks, registerGroupInviteLinks, tokenHash } =
  require('../server/group-invite-links');

test('group invitation HTTP endpoints protect mutations and reject malformed input without database access', async t => {
  const app = express();
  app.use(express.json());
  let databaseCalls = 0;
  registerGroupInviteLinks(app, {
    secret: 'isolated-test-secret',
    getPool: async () => { databaseCalls++; throw new Error('unexpected database access'); },
    auth(req, res, next) {
      if (!req.headers.authorization) return res.sendStatus(401);
      req.user = { id: randomUUID() }; next();
    },
  });
  const server = app.listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  t.after(() => new Promise(resolve => { server.close(resolve); server.closeAllConnections(); }));
  const request = (route, body, authenticated = true) => fetch(
    `http://127.0.0.1:${server.address().port}${route}`, { method: 'POST',
      headers: { 'Content-Type': 'application/json', ...(authenticated ? { authorization: 'test' } : {}) },
      body: JSON.stringify(body || {}) });
  assert.equal((await request(`/api/groups/${randomUUID()}/invite-link`, {}, false)).status, 401);
  assert.equal((await request('/api/group-invites/invalid/join', {}, false)).status, 401);
  const invalidReset = await request(`/api/groups/${randomUUID()}/invite-link`, { reset: 'true' });
  assert.equal(invalidReset.status, 400);
  assert.equal(invalidReset.headers.get('cache-control'), 'no-store');
  assert.equal(invalidReset.headers.get('referrer-policy'), 'no-referrer');
  assert.equal((await request('/api/groups/not-a-uuid/invite-link')).status, 400);
  assert.equal(databaseCalls, 0);
});

test('group invitation links require a server secret', () => {
  assert.throws(() => createGroupInviteLinks({ getPool() {} }), /server secret/);
});

test('group invitation database acceptance, privacy, rotation and concurrent joins',
  { skip: process.env.RUN_DB_TESTS !== '1' }, async t => {
    const { Pool, Client } = require('pg');
    const schema = `group_invite_test_${randomBytes(8).toString('hex')}`;
    const control = new Client({ connectionString: process.env.DATABASE_URL });
    await control.connect();
    await control.query(`CREATE SCHEMA ${schema}`);
    const pool = new Pool({ connectionString: process.env.DATABASE_URL,
      options: `-c search_path=${schema},public`, max: 6 });
    t.after(async () => {
      await pool.end();
      await control.query(`DROP SCHEMA ${schema} CASCADE`);
      await control.end();
    });
    await pool.query(`CREATE TABLE users(id uuid PRIMARY KEY,name text,birth_date date,content_filter jsonb);
      CREATE TABLE groups(id uuid PRIMARY KEY,name text,description text,profile_pic_url text,
        creator_id uuid REFERENCES users,is_self boolean DEFAULT FALSE,is_broadcast boolean DEFAULT FALSE,
        send_permission text DEFAULT 'all',filter_level text DEFAULT 'standard',content_filter jsonb);
      CREATE TABLE group_members(group_id uuid REFERENCES groups,user_id uuid REFERENCES users,
        role text DEFAULT 'member',status text DEFAULT 'member',joined_at timestamptz DEFAULT now(),
        added_by uuid,pending_since timestamptz,filter_override jsonb,share_phone boolean DEFAULT TRUE,
        PRIMARY KEY(group_id,user_id));
      CREATE TABLE filter_pin_settings(user_id uuid PRIMARY KEY REFERENCES users,pin_hash text);
      CREATE TABLE stored_files(public_url text PRIMARY KEY,file_type text,moderation_status text,
        content_purged_at timestamptz,moderation_details jsonb);`);
    await pool.query(SCHEMA);
    const [admin, otherAdmin, outsider, member, pending, teen, missingBirthDate, groupId, selfGroup] =
      Array.from({ length: 9 }, randomUUID);
    const personalFilter = { text: true, video: false, nonHumanImages: true,
      men: false, women: false, children: false, enforceGeneralFilter: true };
    const override = { ...personalFilter, men: true };
    for (const id of [admin, otherAdmin, outsider, member, pending, teen, missingBirthDate]) {
      await pool.query('INSERT INTO users VALUES($1,$2,$3,$4)', [id, id === admin ? 'המנהל' : 'חבר',
        id === teen ? '2015-01-01' : id === missingBirthDate ? null : '1990-01-01', personalFilter]);
    }
    await pool.query(`INSERT INTO groups(id,name,description,profile_pic_url,creator_id,is_self,content_filter)
      VALUES($1,'קבוצת מעבר','תיאור קבוצתי','emoji:🌿',$2,FALSE,$4),
        ($3,'הודעות לעצמי','תיאור פרטי',NULL,$2,TRUE,$4)`,
    [groupId, admin, selfGroup, { ...personalFilter, men: true, women: true, video: true }]);
    await pool.query(`INSERT INTO group_members(group_id,user_id,role,status,filter_override,share_phone)
      VALUES($1,$2,'admin','member',NULL,TRUE),($1,$3,'admin','member',NULL,FALSE),
        ($1,$4,'member','member',$6,TRUE),($1,$5,'member','pending',$6,TRUE),
        ($7,$2,'admin','member',NULL,TRUE)`,
    [groupId, admin, otherAdmin, member, pending, override, selfGroup]);
    await pool.query("INSERT INTO filter_pin_settings VALUES($1,'locked-test-pin')", [outsider]);
    const service = createGroupInviteLinks({ getPool: async () => pool, secret: 'isolated-test-secret',
      projectImages: async (_db, _userId, rows) => rows });
    let invite;

    await t.test('only an adult active administrator can issue a reusable group link', async () => {
      await assert.rejects(service.issue(groupId, member), { status: 403, code: 'GROUP_ADMIN_REQUIRED' });
      await assert.rejects(service.issue(selfGroup, admin), { status: 404 });
      invite = await service.issue(groupId, admin);
      assert.match(invite.token, /^[A-Za-z0-9_-]{43}$/);
      assert.equal(new URL(invite.url).searchParams.get('groupInvite'), invite.token);
      assert.deepEqual(await service.issue(groupId, otherAdmin), invite);
      const stored = (await pool.query('SELECT * FROM group_invite_links')).rows[0];
      assert.equal(stored.token_hash, tokenHash(invite.token));
      assert.equal(Object.values(stored).includes(invite.token), false, 'raw token is never stored');
      await pool.query("UPDATE group_members SET status='pending' WHERE group_id=$1 AND user_id=$2", [groupId, otherAdmin]);
      await assert.rejects(service.issue(groupId, otherAdmin), { status: 403 });
      await pool.query("UPDATE group_members SET status='member' WHERE group_id=$1 AND user_id=$2", [groupId, otherAdmin]);
    });

    await t.test('public preview reveals only the group and inviter, with no member data', async () => {
      assert.deepEqual(await service.preview(invite.token), {
        group: { id: groupId, name: 'קבוצת מעבר', description: 'תיאור קבוצתי', avatar_url: 'emoji:🌿' },
        inviter: { name: 'המנהל' },
      });
      await assert.rejects(service.preview('malformed'), { status: 404 });
      await assert.rejects(service.preview(randomBytes(32).toString('base64url')), { status: 404 });
    });

    await t.test('anonymous avatars respect review results and conservative image categories', async () => {
      const cases = [
        ['/betshuva-app/uploads/woman.jpg', { category: 'women' }, 'approved', null],
        ['/betshuva-app/uploads/group.jpg', { category: 'nonHumanImages' }, 'approved', '/betshuva-app/uploads/group.jpg'],
        ['/betshuva-app/uploads/stopped.jpg', { category: 'nonHumanImages' }, 'stopped', null],
        ['https://elsewhere.test/photo.jpg', { category: 'nonHumanImages' }, 'approved', null],
      ];
      for (const [url, classification, status, expected] of cases) {
        await pool.query(`INSERT INTO stored_files(public_url,file_type,moderation_status,moderation_details)
          VALUES($1,'image',$2,$3)`, [url, status, { classification }]);
        await pool.query('UPDATE groups SET profile_pic_url=$2 WHERE id=$1', [groupId, url]);
        assert.equal((await service.preview(invite.token)).group.avatar_url, expected);
      }
      await pool.query("UPDATE groups SET profile_pic_url='emoji:🌿' WHERE id=$1", [groupId]);
    });

    await t.test('new membership needs no filter unlock, inherits general filters and keeps phone private', async () => {
      const result = await service.join(invite.token, outsider);
      assert.equal(result.alreadyMember, false);
      assert.equal(result.group.status, 'member');
      assert.equal(result.group.role, 'member');
      assert.equal(result.group.share_phone, false);
      assert.equal(result.group.member_count, 4);
      assert.equal(Object.hasOwn(result.group, 'inviter_birth_date'), false);
      const stored = (await pool.query('SELECT * FROM group_members WHERE group_id=$1 AND user_id=$2', [groupId, outsider])).rows[0];
      assert.equal(stored.filter_override, null);
      assert.equal(stored.share_phone, false);
      assert.deepEqual((await pool.query('SELECT content_filter FROM users WHERE id=$1', [outsider])).rows[0].content_filter, personalFilter);
      assert.equal((await pool.query('SELECT pin_hash FROM filter_pin_settings WHERE user_id=$1', [outsider])).rows[0].pin_hash, 'locked-test-pin');
    });

    await t.test('existing membership is idempotent and retains filter and phone choices', async () => {
      const before = (await pool.query('SELECT * FROM group_members WHERE group_id=$1 AND user_id=$2', [groupId, member])).rows[0];
      const result = await service.join(invite.token, member);
      assert.equal(result.alreadyMember, true);
      assert.equal(result.group.share_phone, true);
      const after = (await pool.query('SELECT * FROM group_members WHERE group_id=$1 AND user_id=$2', [groupId, member])).rows[0];
      assert.deepEqual(after.filter_override, override);
      assert.deepEqual(after.joined_at, before.joined_at);
      assert.equal(after.role, 'member');
    });

    await t.test('pending acceptance keeps its filter choice and starts with phone sharing off', async () => {
      const result = await service.join(invite.token, pending);
      assert.equal(result.alreadyMember, false);
      const stored = (await pool.query('SELECT * FROM group_members WHERE group_id=$1 AND user_id=$2', [groupId, pending])).rows[0];
      assert.equal(stored.status, 'member');
      assert.equal(stored.share_phone, false);
      assert.deepEqual(stored.filter_override, override);
    });

    await t.test('underage and incomplete-age accounts cannot join or create a link', async () => {
      await assert.rejects(service.join(invite.token, teen), { status: 403, code: 'AGE_RESTRICTED' });
      await assert.rejects(service.join(invite.token, missingBirthDate), { status: 403, code: 'BIRTH_DATE_REQUIRED' });
      assert.equal((await pool.query('SELECT * FROM group_members WHERE user_id=ANY($1::uuid[])', [[teen, missingBirthDate]])).rows.length, 0);
      await pool.query('UPDATE users SET birth_date=$2 WHERE id=$1', [admin, '2015-01-01']);
      await assert.rejects(service.issue(groupId, admin), { status: 403 });
      await assert.rejects(service.preview(invite.token), { status: 404 });
      await pool.query('UPDATE users SET birth_date=$2 WHERE id=$1', [admin, '1990-01-01']);
    });

    await t.test('concurrent acceptance creates exactly one membership and one first-join result', async () => {
      const newcomer = randomUUID();
      await pool.query('INSERT INTO users VALUES($1,$2,$3,$4)', [newcomer, 'מצטרף', '1990-01-01', personalFilter]);
      const results = await Promise.all(Array.from({ length: 6 }, () => service.join(invite.token, newcomer)));
      assert.equal(results.filter(result => !result.alreadyMember).length, 1);
      assert.equal((await pool.query('SELECT * FROM group_members WHERE group_id=$1 AND user_id=$2', [groupId, newcomer])).rows.length, 1);
    });

    await t.test('a join racing a reset cannot accept the old token after reset commits', async () => {
      let reportLocked, allowReset;
      const locked = new Promise(resolve => { reportLocked = resolve; });
      const release = new Promise(resolve => { allowReset = resolve; });
      const rotating = createGroupInviteLinks({ secret: 'isolated-test-secret', getPool: async () => ({
        query: pool.query.bind(pool),
        async connect() {
          const client = await pool.connect();
          return { release: client.release.bind(client), async query(sql, values) {
            const result = await client.query(sql, values);
            if (sql === 'SELECT id,is_self FROM groups WHERE id=$1 FOR UPDATE') {
              reportLocked(); await release;
            }
            return result;
          } };
        },
      }) });
      const reset = rotating.issue(groupId, admin, { reset: true });
      await locked;
      const attemptedJoin = assert.rejects(service.join(invite.token, outsider), { status: 404 });
      allowReset();
      invite = await reset;
      await attemptedJoin;
      assert.equal((await service.preview(invite.token)).group.id, groupId);
    });

    await t.test('reset revokes the old token and an inactive issuer cannot invite', async () => {
      const old = invite;
      invite = await service.issue(groupId, otherAdmin, { reset: true });
      assert.notEqual(invite.token, old.token);
      await assert.rejects(service.preview(old.token), { status: 404 });
      await assert.rejects(service.join(old.token, outsider), { status: 404 });
      await pool.query("UPDATE group_members SET role='member' WHERE group_id=$1 AND user_id=$2", [groupId, otherAdmin]);
      await assert.rejects(service.preview(invite.token), { status: 404 });
      await assert.rejects(service.join(invite.token, outsider), { status: 404 });
      await pool.query("UPDATE group_members SET role='admin' WHERE group_id=$1 AND user_id=$2", [groupId, otherAdmin]);
      await assert.rejects(service.preview(invite.token), { status: 404 });
      const replacement = await service.issue(groupId, admin);
      assert.notEqual(replacement.token, invite.token);
      invite = replacement;
      await pool.query('DELETE FROM group_members WHERE group_id=$1 AND user_id=$2', [groupId, admin]);
      await assert.rejects(service.preview(invite.token), { status: 404 });
      await pool.query("INSERT INTO group_members(group_id,user_id,role) VALUES($1,$2,'admin')", [groupId, admin]);
      await assert.rejects(service.preview(invite.token), { status: 404 }, 'returning admins cannot resurrect an old invitation');
      invite = await service.issue(groupId, admin);
    });

    await t.test('self groups and deleted groups cannot be joined, and deletion removes tokens', async () => {
      await pool.query('UPDATE groups SET is_self=TRUE WHERE id=$1', [groupId]);
      await assert.rejects(service.preview(invite.token), { status: 404 });
      await assert.rejects(service.join(invite.token, outsider), { status: 404 });
      await pool.query('UPDATE groups SET is_self=FALSE WHERE id=$1', [groupId]);
      await pool.query('DELETE FROM group_members WHERE group_id=$1', [groupId]);
      await pool.query('DELETE FROM groups WHERE id=$1', [groupId]);
      assert.equal((await pool.query('SELECT * FROM group_invite_links WHERE group_id=$1', [groupId])).rows.length, 0);
      await assert.rejects(service.preview(invite.token), { status: 404 });
    });
  });
