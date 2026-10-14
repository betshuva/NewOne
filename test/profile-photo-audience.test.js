'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { normalizeAudience, signedPhotoUrl, validPhotoTicket, PHOTO_BASE,
  projectAudience, validateAudience, prepareProfilePhoto, registerProfilePhotoAudience } = require('../server/profile-photo-audience');

const owner = '11111111-1111-4111-8111-111111111111';
const viewer = '22222222-2222-4222-8222-222222222222';
const stranger = '33333333-3333-4333-8333-333333333333';
const group = '44444444-4444-4444-8444-444444444444';
const photo = '55555555-5555-4555-8555-555555555555';
const secret = 'test-only-profile-photo-ticket';

test('omitted fields preserve selections, empty selections stay private and invalid IDs fail', () => {
  const current = { privacy_pic: 'selected', profile_photo_user_ids: [viewer], profile_photo_group_ids: [group] };
  assert.deepEqual(normalizeAudience({}, current), { mode: 'selected', userIds: [viewer], groupIds: [group] });
  assert.deepEqual(normalizeAudience({ privacy_pic: 'selected', profile_photo_user_ids: [], profile_photo_group_ids: [] }, current),
    { mode: 'selected', userIds: [], groupIds: [] });
  assert.equal(normalizeAudience({ privacy_pic: 'all' }, {}, true).mode, 'contacts');
  assert.throws(() => normalizeAudience({ privacy_pic: 'invalid' }, {}), /פרטיות/);
  assert.throws(() => normalizeAudience({ profile_photo_user_ids: ['not-an-id'] }, {}), /רשימת/);
  assert.throws(() => normalizeAudience({}, current, true), /נוער/);
});

test('photo tickets reject tampering, expiry, missing signatures and another photo', () => {
  const now = Date.now();
  const url = new URL(signedPhotoUrl(PHOTO_BASE + photo, viewer, secret, now), 'https://example.test');
  const query = Object.fromEntries(url.searchParams);
  assert.equal(validPhotoTicket(photo, query, secret, now), true);
  assert.equal(validPhotoTicket(photo, { ...query, viewer: stranger }, secret, now), false);
  assert.equal(validPhotoTicket(stranger, query, secret, now), false);
  assert.equal(validPhotoTicket(photo, { ...query, sig: '' }, secret, now), false);
  assert.equal(validPhotoTicket(photo, query, secret, now + 7200001), false);
});

test('projection hides selected avatars including emoji and uses sender/seller/reaction IDs', async () => {
  const pool = { query: async (_, values) => {
    assert.deepEqual(new Set(values[1]), new Set([owner]));
    return { rows: [{ id: owner, photo_audience_allowed: false }] };
  } };
  const rows = [{ id: 'request', sender_id: owner, profile_pic_url: 'emoji:🌻' },
    { id: 'listing', seller_id: owner, seller_pic: 'private' },
    { user_id: owner, profile_pic_url: 'private' }];
  const result = await projectAudience(pool, viewer, rows, ['profile_pic_url', 'seller_pic']);
  assert.equal(result[0].profile_pic_url, null);
  assert.equal(result[1].seller_pic, null);
  assert.equal(result[2].profile_pic_url, null);
  assert.equal(rows[0].profile_pic_url, 'emoji:🌻');
});

test('forged group selections and missing users cannot be saved', async () => {
  const pool = { query: async () => ({ rows: [] }) };
  await assert.rejects(validateAudience(pool, owner, { mode: 'selected', userIds: [], groupIds: [group] }, false), /חבר פעיל/);
  await assert.rejects(validateAudience(pool, owner, { mode: 'selected', userIds: [stranger], groupIds: [] }, false), /משתמשים/);
});

test('database and HTTP enforce membership changes, revocation, blocking and filters',
  { skip: !process.env.DATABASE_URL }, async () => {
    const { Client } = require('pg');
    const express = require('express');
    const db = new Client({ connectionString: process.env.DATABASE_URL,
      ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' } : false });
    await db.connect();
    let server;
    try {
      await db.query('BEGIN');
      // All writes below are connection-local temporary fixtures, never users.
      await db.query(`CREATE TEMP TABLE users(id UUID PRIMARY KEY,name TEXT,privacy_pic TEXT,
        profile_pic_url TEXT,profile_photo_user_ids UUID[] DEFAULT '{}',profile_photo_group_ids UUID[] DEFAULT '{}',
        content_filter JSONB,email_verified BOOLEAN DEFAULT TRUE,phone_verified BOOLEAN DEFAULT FALSE,birth_date DATE);
        CREATE TEMP TABLE group_members(group_id UUID,user_id UUID,status TEXT);
        CREATE TEMP TABLE user_contacts(owner_id UUID,contact_id UUID);
        CREATE TEMP TABLE blocked_users(blocker_id UUID,blocked_id UUID);
        CREATE TEMP TABLE stored_files(public_url TEXT,moderation_status TEXT,content_purged_at TIMESTAMPTZ,moderation_details JSONB,
          user_id UUID,file_type TEXT,file_size BIGINT,storage_path TEXT);
        CREATE TEMP TABLE profile_photo_assets(id UUID,owner_id UUID,classification JSONB,image_bytes BYTEA,source_url TEXT);`);
      const filter = { men: true, women: true, children: true, nonHumanImages: true };
      for (const id of [owner, viewer, stranger])
        await db.query(`INSERT INTO users(id,name,privacy_pic,content_filter,birth_date) VALUES($1,'fixture','all',$2,'1990-01-01')`, [id, filter]);
      await db.query(`UPDATE users SET privacy_pic='selected',profile_pic_url=$2,profile_photo_user_ids=ARRAY[$3::uuid] WHERE id=$1`, [owner, PHOTO_BASE + photo, viewer]);
      await db.query(`INSERT INTO profile_photo_assets VALUES($1,$2,'{"category":"women"}',$3,'fixture-source')`, [photo, owner, Buffer.from('private-image-fixture')]);
      const fs = require('node:fs/promises');
      const path = require('node:path');
      const sharp = require('sharp');
      const uploadRoot = path.join(__dirname, '..', 'uploads');
      const relative = `.profile-photo-test-${require('node:crypto').randomUUID()}.png`;
      const bytes = await sharp({ create: { width: 4, height: 4, channels: 3, background: '#336699' } }).png().toBuffer();
      await fs.writeFile(path.join(uploadRoot, relative), bytes, { mode: 0o600, flag: 'wx' });
      try {
        await db.query(`INSERT INTO stored_files VALUES('fixture-approved','approved',NULL,
          '{"classification":{"category":"nonHumanImages"}}',$1,'image',$2,$3)`, [owner, bytes.length, relative]);
        const prepared = await prepareProfilePhoto(db, owner, 'fixture-approved', null);
        assert.ok(prepared.startsWith(PHOTO_BASE));
        assert.equal(prepared.includes('fixture-approved'), false, 'source URL is never the avatar URL');
        const asset = (await db.query('SELECT image_bytes FROM profile_photo_assets WHERE id=$1', [prepared.slice(PHOTO_BASE.length)])).rows[0];
        assert.equal((await sharp(asset.image_bytes).metadata()).format, 'webp');
        await assert.rejects(prepareProfilePhoto(db, stranger, 'fixture-approved', null), /תמונה שלך/);
        await assert.rejects(prepareProfilePhoto(db, stranger, prepared, null), /שייכת/);
      } finally { await fs.unlink(path.join(uploadRoot, relative)); }
      const app = express();
      registerProfilePhotoAudience(app, { auth: (_, __, next) => next(), getPool: async () => db, secret });
      server = await new Promise(resolve => { const instance = app.listen(0, '127.0.0.1', () => resolve(instance)); });
      const origin = `http://127.0.0.1:${server.address().port}`;
      const ticket = id => signedPhotoUrl(PHOTO_BASE + photo, id, secret).replace('/betshuva-app', '');
      const get = async id => fetch(origin + ticket(id));
      assert.equal((await get(viewer)).status, 200);
      assert.equal((await get(stranger)).status, 404);
      assert.equal((await get(owner)).headers.get('cache-control'), 'private, no-store');
      assert.equal((await fetch(origin + '/api/profile-photos/' + photo)).status, 403);
      await db.query(`UPDATE users SET profile_photo_user_ids='{}',profile_photo_group_ids=ARRAY[$2::uuid] WHERE id=$1`, [owner, group]);
      await db.query(`INSERT INTO group_members VALUES($1,$2,'member'),($1,$3,'pending')`, [group, owner, viewer]);
      assert.equal((await get(viewer)).status, 404, 'pending membership is not permission');
      await db.query(`UPDATE group_members SET status='member' WHERE user_id=$1`, [viewer]);
      assert.equal((await get(viewer)).status, 200);
      await db.query(`UPDATE group_members SET status='left' WHERE user_id=$1`, [owner]);
      assert.equal((await get(viewer)).status, 404, 'owner must remain a member');
      await db.query(`UPDATE users SET privacy_pic='all' WHERE id=$1`, [owner]);
      assert.equal((await get(stranger)).status, 200);
      await db.query(`UPDATE users SET content_filter='{"women":false}' WHERE id=$1`, [stranger]);
      assert.equal((await get(stranger)).status, 403);
      await db.query('INSERT INTO blocked_users VALUES($1,$2)', [owner, viewer]);
      assert.equal((await get(viewer)).status, 404);
      await db.query(`UPDATE users SET privacy_pic='nobody' WHERE id=$1`, [owner]);
      assert.equal((await get(owner)).status, 200);
      assert.equal((await get(viewer)).status, 404, 'previously signed URL cannot override new privacy');
      await db.query(`UPDATE users SET profile_pic_url=NULL WHERE id=$1`, [owner]);
      assert.equal((await get(owner)).status, 404, 'old photos cannot be reopened');
    } finally {
      if (server) await new Promise(resolve => server.close(resolve));
      await db.query('ROLLBACK');
      await db.end();
    }
  });
