'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const vm = require('node:vm');
const { Client, Pool } = require('pg');
const { normalizeImageChanges, listingImageApproved, mergeListingImages,
  getListingImageStatuses, attachListingImages, registerListingBackgroundImages,
  validateListingMedia, normalizeListingVideoChange } = require('../server/listing-background-images');

const { VIDEO_PROBE_VERSION } = require('../server/listing-video-policy');
const videoScan = () => ({ classification: { category: 'video', detectedCategories: ['video', 'nonHumanImages'],
  uncertain: false, durationSeconds: 9, sampledFrames: 2, fullyScannedFrames: 2 },
  frameResults: [objectScan, objectScan], listingVideoProof: { durationSeconds: 9, source: VIDEO_PROBE_VERSION } });

const id = n => `97000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const owner = id(1), other = id(2), listingId = id(3);
const url = n => `/test-listing-image/${n}.png`;
const objectScan = { classification: {
  category: 'nonHumanImages', detectedCategories: ['nonHumanImages'], uncertain: false,
} };
const approvedFile = (overrides = {}) => ({ file_type: 'image', context_type: 'listing',
  moderation_status: 'approved', moderation_details: objectScan, ...overrides });

test('background image changes validate input and preserve ordering and replacement intent', () => {
  const changes = normalizeImageChanges({ image_urls: [url(3), url(2), url(3)] });
  assert.deepEqual(mergeListingImages([url(1), url(2)], changes), [url(1), url(2), url(3)]);
  const replacement = normalizeImageChanges({ replacements: [{ expected_old_url: url(1), url: url(4) }] });
  assert.deepEqual(mergeListingImages([url(1), url(2)], replacement), [url(4), url(2)]);
  assert.deepEqual(mergeListingImages([url(4), url(2)], replacement), [url(4), url(2)], 'retry is idempotent');
  assert.throws(() => mergeListingImages([url(5), url(2)], replacement),
    error => error.status === 409 && error.code === 'LISTING_IMAGE_CHANGED');
  assert.throws(() => mergeListingImages(Array.from({ length: 8 }, (_, n) => url(n)),
    normalizeImageChanges({ image_urls: [url(10)] })), error => error.code === 'LISTING_IMAGE_LIMIT');
  for (const body of [{}, null, [], { image_urls: 'bad' }, { image_urls: [null] },
    { image_urls: Array.from({ length: 9 }, (_, n) => url(n)) },
    { replacements: [{ expected_old_url: url(1) }] },
    { replacements: [{ expected_old_url: url(1), url: url(2) }, { expected_old_url: url(1), url: url(3) }] }])
    assert.throws(() => normalizeImageChanges(body), error => error.status === 400);
});

test('listing attachment approval includes object-only evidence, not just general safety status', () => {
  assert.equal(listingImageApproved(approvedFile()), true);
  assert.equal(listingImageApproved(approvedFile({ released_at: '2026-01-01', backup_available: true })), true);
  assert.equal(listingImageApproved(approvedFile({ released_at: '2026-01-01', backup_available: true,
    content_purged_at: '2026-01-02' })), false);
  for (const overrides of [{ file_type: 'video' }, { context_type: 'general' },
    { moderation_status: 'pending' }, { moderation_status: 'rejected' },
    { content_purged_at: '2026-01-01' }, { released_at: '2026-01-01' },
    ...['blocked', 'pending', 'scanSkipped', 'scanStopped', 'senderFilterRejected',
      'destinationFilterRejected', 'deliveryRejected'].map(key => ({ moderation_details: { ...objectScan, [key]: true } })),
    { moderation_details: { ...objectScan, source: 'builtin-expression' } },
    { moderation_details: {} },
    { moderation_details: { classification: { category: 'people', detectedCategories: ['people'] } } },
    { moderation_details: { ...objectScan, faces: [{}] } },
    { moderation_details: { classification: { ...objectScan.classification, uncertain: true } } }])
    assert.equal(listingImageApproved(approvedFile(overrides)), false, JSON.stringify(overrides));
  const google = { available: true, personDetected: false };
  assert.equal(listingImageApproved(approvedFile({ moderation_details: {
    classification: { ...objectScan.classification, uncertain: true }, googleObjectLocalization: google,
  } })), true);
  assert.equal(listingImageApproved(approvedFile({ moderation_details: {
    classification: { category: 'men', detectedCategories: ['men'], uncertain: true }, googleObjectLocalization: google,
  } })), false, 'Google no-person result cannot override a positive local person classification');
});

test('background images route prevents teen writes and reports rejected files without exposing internals', async () => {
  const handlers = new Map();
  let reads = 0;
  registerListingBackgroundImages({ post: (path, _auth, callback) => { handlers.set(path, callback); } }, {
    auth: () => {}, getPool: async () => { reads++; throw new Error('private database details'); },
  });
  const output = {};
  const res = { status: code => { output.status = code; return res; },
    json: body => { output.body = body; return res; }, set: () => res };
  for (const handler of handlers.values()) {
    const previousReads = reads;
    await handler({ user: { id: owner, isTeen: true } }, res);
    assert.equal(output.status, 403); assert.equal(reads, previousReads);
    await handler({ user: { id: owner }, params: { id: listingId }, body: {} }, res);
    assert.equal(output.status, 500); assert.doesNotMatch(output.body.error, /private database/);
  }
});

test('background image attachment is atomic and merges concurrent writes in isolated PostgreSQL fixtures', {
  skip: process.env.RUN_DB_TESTS !== '1',
}, async t => {
  const config = { connectionString: process.env.DATABASE_URL, connectionTimeoutMillis: 10000,
    ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' } : false };
  const admin = new Client(config);
  const schema = `listing_images_test_${crypto.randomBytes(10).toString('hex')}`;
  let pool;
  await admin.connect();
  try {
    await admin.query(`CREATE SCHEMA ${schema}`);
    pool = new Pool({ ...config, max: 8, options: `-c search_path=${schema}` });
    await pool.query(`
      CREATE TABLE listings(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),user_id uuid,image_url text,video_url text,
        title text DEFAULT 'original title',description text DEFAULT 'original description',
        price numeric DEFAULT 100,status text DEFAULT 'active',expires_at timestamptz DEFAULT '2030-01-01',
        category text DEFAULT 'אחר',type text,city text,latitude double precision,longitude double precision,item_condition text,negotiable boolean,quantity integer,
        delivery_method text,pickup_details text,contact_phone_visible boolean,contact_preferences jsonb,
        license_plate text,vehicle_details jsonb,property_details jsonb,category_details jsonb);
      CREATE TABLE listing_images(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),listing_id uuid,url text,sort_order integer);
      CREATE TABLE stored_files(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),user_id uuid,
        public_url text UNIQUE,mime_type text DEFAULT 'image/png',file_type text DEFAULT 'image',context_type text DEFAULT 'listing',
        moderation_status text DEFAULT 'approved',moderation_details jsonb,
        content_purged_at timestamptz,released_at timestamptz,content_sha256 text DEFAULT 'test-hash',file_size bigint DEFAULT 10);
      CREATE TABLE media_backup_items(stored_file_id uuid,user_id uuid,provider text,status text,
        remote_file_id text,restore_verified_at timestamptz,encryption_metadata jsonb,plaintext_sha256 text);
      CREATE TABLE user_backup_settings(user_id uuid,encrypted_data_key text);
      CREATE TABLE cloud_backup_accounts(user_id uuid,provider text,status text,encrypted_refresh_token text);
      CREATE TABLE central_drive_objects(file_id uuid,owner_id uuid,status text,remote_file_id text,
        encrypted_data_key text,encrypted_sha256 text,encryption_metadata jsonb,plaintext_sha256 text,file_size bigint);
      CREATE TABLE central_drive_account(id integer,encrypted_token text);
    `);
    const addFile = async (n, { user = owner, ...overrides } = {}) => {
      const file = approvedFile(overrides);
      await pool.query(`INSERT INTO stored_files(user_id,public_url,file_type,context_type,
          moderation_status,moderation_details,content_purged_at,released_at,mime_type) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)`,
      [user, url(n), file.file_type, file.context_type, file.moderation_status,
        JSON.stringify(file.moderation_details), file.content_purged_at, file.released_at,
        file.mime_type || (file.file_type === 'video' ? 'video/mp4' : 'image/png')]);
    };
    const reset = async (count = 0) => {
      await pool.query('TRUNCATE listings,listing_images,stored_files,media_backup_items,user_backup_settings,cloud_backup_accounts,central_drive_objects,central_drive_account');
      await pool.query('INSERT INTO listings(id,user_id,image_url) VALUES($1,$2,$3)', [listingId, owner, count ? url(0) : null]);
      for (let n = 0; n < count; n++) {
        await addFile(n);
        await pool.query('INSERT INTO listing_images(listing_id,url,sort_order) VALUES($1,$2,$3)', [listingId, url(n), n]);
      }
    };
    const images = async () => (await pool.query('SELECT url FROM listing_images ORDER BY sort_order')).rows.map(row => row.url);
    const attach = (body, user = owner, target = listingId) => attachListingImages(pool, user, target, body);
    const editHandler = testPool => {
      const source = fs.readFileSync(require.resolve('../server/index.js'), 'utf8');
      const start = source.indexOf("app.put('/api/listings/:id', auth,");
      const end = source.indexOf('registerListingBackgroundImages(app,', start);
      let handler;
      vm.runInNewContext(source.slice(start, end), {
        app: { put: (_path, _auth, callback) => { handler = callback; } }, auth: () => {},
        validateListingMedia, normalizeListingVideoChange,
        getPool: async () => testPool, logActivity: () => {}, deleteStoredFile: async () => {},
        sanitizeListingCategoryDetails: () => null,
        sanitizeListingContactPreferences: () => ({ in_app: true, email: false, phone: false }),
        listingDescriptionWithTitle: (_title, description) => description,
        normalizeLicensePlate: value => /^\d{7,8}$/.test(value) ? value : null,
        validPropertyEntryDate: () => true,
      });
      return async (body, actor = owner) => {
        const output = {};
        const res = { status: code => { output.status = code; return res; },
          json: result => { output.body = result; output.status ||= 200; return res; } };
        await handler({ user: { id: actor }, params: { id: listingId }, body }, res);
        return output;
      };
    };

    await t.test('one video attaches atomically, retries idempotently and stale background replacements cannot overwrite it', async () => {
      await reset(1);
      for (const n of [101, 102, 103]) await addFile(n, { file_type: 'video', moderation_details: videoScan() });
      const first = await attach({ video_url: url(101) });
      assert.equal(first.video_url, url(101)); assert.deepEqual(first.images, [url(0)]);
      assert.equal((await attach({ video_url: url(101) })).video_url, url(101));
      await assert.rejects(attach({ video_url: url(102) }), e => e.code === 'LISTING_VIDEO_CHANGED');
      const replacement = { video_url: url(102), expected_old_video_url: url(101) };
      assert.equal((await attach(replacement)).video_url, url(102));
      assert.equal((await attach(replacement)).video_url, url(102));
      await assert.rejects(attach({ video_url: url(103), expected_old_video_url: url(101) }), e => e.code === 'LISTING_VIDEO_CHANGED');
      assert.equal((await attach({ video_url: null, expected_old_video_url: url(102) })).video_url, null);
      await addFile(110);
      await assert.rejects(attach({ image_urls: [url(110)], video_url: url(999) }), e => e.code === 'LISTING_VIDEO_NOT_APPROVED');
      assert.deepEqual(await images(), [url(0)], 'a rejected mixed image/video batch writes neither');
      assert.equal((await attach({ video_url: null, expected_old_video_url: url(102) })).video_url, null);
    });

    await t.test('ordinary listing creation validates photo/video evidence and rolls back partial database failures', async () => {
      await reset(); await addFile(1);
      await addFile(120, { file_type: 'video', moderation_details: videoScan() });
      const source = fs.readFileSync(require.resolve('../server/index.js'), 'utf8');
      const start = source.indexOf("app.post('/api/listings', auth,");
      const end = source.indexOf("app.get('/api/listings', auth,", start);
      let handler;
      let failInsert = false;
      let outstanding = 0;
      const testPool = { query: (...args) => pool.query(...args), connect: async () => {
        const client = await pool.connect(); outstanding++;
        return { query: (sql, params) => {
          if (failInsert && sql.trim().startsWith('INSERT INTO listing_images')) throw new Error('synthetic image insert failure');
          return client.query(sql, params);
        }, release: () => { outstanding--; client.release(); } };
      } };
      vm.runInNewContext(source.slice(start, end), {
        app: { post: (_path, _auth, callback) => { handler = callback; } }, auth: () => {},
        getPool: async () => testPool, validateListingMedia, normalizeListingVideoChange,
        LISTING_CATEGORIES: ['אחר'], sanitizeListingCategoryDetails: () => null,
        sanitizeListingContactPreferences: () => ({ in_app: true, email: false, phone: false }),
        listingDescriptionWithTitle: (_title, description) => description,
        normalizeLicensePlate: () => null, validPropertyEntryDate: () => true,
      });
      const create = async body => {
        const output = {};
        const res = { status: code => { output.status = code; return res; },
          json: body => { output.body = body; output.status ||= 200; return res; } };
        await handler({ user: { id: owner }, body }, res);
        assert.equal(outstanding, 0);
        return output;
      };
      const body = { title: 'created listing', description: 'a sufficiently long description',
        latitude: 1, longitude: 1, image_urls: [url(1)], video_url: url(120) };
      assert.equal((await create({ ...body, image_urls: [url(120)] })).status, 400);
      assert.equal((await create({ ...body, image_urls: Array(9).fill(url(1)) })).status, 400);
      assert.equal((await create({ ...body, video_url: url(999) })).status, 400);
      assert.equal((await pool.query('SELECT count(*)::int AS n FROM listings')).rows[0].n, 1);
      failInsert = true;
      assert.equal((await create(body)).status, 500);
      assert.equal((await pool.query('SELECT count(*)::int AS n FROM listings')).rows[0].n, 1);
      failInsert = false;
      const result = await create(body);
      assert.equal(result.status, 200);
      const listing = (await pool.query('SELECT image_url,video_url FROM listings WHERE id=$1', [result.body.id])).rows[0];
      assert.equal(listing.image_url, url(1)); assert.equal(listing.video_url, url(120));
    });

    await t.test('concurrent video selection publishes exactly one and preserves metadata and images', async () => {
      await reset(1);
      for (const n of [101, 102]) await addFile(n, { file_type: 'video', moderation_details: videoScan() });
      const race = await Promise.allSettled([attach({ video_url: url(101) }), attach({ video_url: url(102) })]);
      assert.equal(race.filter(r => r.status === 'fulfilled').length, 1);
      assert.equal(race.find(r => r.status === 'rejected').reason.code, 'LISTING_VIDEO_CHANGED');
      assert.deepEqual(await images(), [url(0)]);
      assert.equal((await pool.query('SELECT title FROM listings')).rows[0].title, 'original title');
    });

    await t.test('video approval and ownership gate attachment, polling and ordinary full edits', async () => {
      await reset(1);
      const invalid = [{ user: other }, { moderation_status: 'pending' }, { moderation_status: 'rejected' },
        { context_type: 'general' }, { released_at: '2026-01-01' }, { content_purged_at: '2026-01-01' },
        { moderation_details: { ...videoScan(), listingVideoProof: { durationSeconds: 10.01, source: VIDEO_PROBE_VERSION } } },
        { moderation_details: { ...videoScan(), frameResults: [objectScan, { classification: { category: 'men', detectedCategories: ['men'] } }] } }];
      for (let n = 0; n < invalid.length; n++) {
        await addFile(n + 100, { file_type: 'video', moderation_details: videoScan(), ...invalid[n] });
        await assert.rejects(attach({ video_url: url(n + 100) }), e => e.code === 'LISTING_VIDEO_NOT_APPROVED');
      }
      await addFile(120, { file_type: 'video', moderation_details: videoScan() });
      await assert.rejects(attach({ image_urls: [url(120)] }), e => e.code === 'LISTING_IMAGE_NOT_APPROVED');
      const status = await getListingImageStatuses(pool, owner, { video_urls: [url(101)] });
      assert.equal(status.videos[0].status, 'pending');
      await pool.query('UPDATE stored_files SET moderation_status=$1,moderation_details=$2 WHERE public_url=$3',
        ['approved', videoScan(), url(101)]);
      assert.equal((await getListingImageStatuses(pool, owner, { video_urls: [url(101)] })).videos[0].status, 'approved');
      assert.equal((await getListingImageStatuses(pool, other, { video_urls: [url(120)] })).videos[0].status, 'unavailable');
      const edit = editHandler(pool);
      const body = { title: 'edited title', description: 'edited description', image_urls: [url(0)] };
      assert.equal((await edit({ ...body, video_url: url(100) })).status, 400);
      assert.equal((await edit({ ...body, image_urls: [url(120)] })).status, 400);
      assert.equal((await edit({ ...body, video_url: url(120) })).status, 200);
      assert.equal((await edit(body)).status, 200);
      assert.equal((await pool.query('SELECT video_url FROM listings')).rows[0].video_url, url(120));
      assert.equal((await edit({ ...body, video_url: null })).status, 200);
      assert.equal((await pool.query('SELECT video_url FROM listings')).rows[0].video_url, null);
      await pool.query('UPDATE stored_files SET released_at=now() WHERE public_url=$1', [url(0)]);
      assert.equal((await edit(body)).status, 200, 'already published images released to Drive remain editable');
      await assert.rejects(attach({ image_urls: [url(0)] }), e => e.code === 'LISTING_IMAGE_NOT_APPROVED',
        'a released file without a readable verified copy cannot create a new reference');
    });

    await t.test('verified personal Drive offload survives the scan-to-attachment race without accepting deleted or foreign copies', async () => {
      await reset();
      await addFile(1, { released_at: '2026-01-01' });
      await addFile(2, { released_at: '2026-01-01', file_type: 'video', moderation_details: videoScan() });
      await pool.query('INSERT INTO user_backup_settings VALUES($1,$2)', [owner, 'encrypted-vault-key']);
      await pool.query("INSERT INTO cloud_backup_accounts VALUES($1,'google_drive','connected',$2)", [owner, 'encrypted-token']);
      await pool.query(`INSERT INTO media_backup_items
        SELECT id,user_id,'google_drive','verified','remote-file',now(),'{"keySource":"server_vault"}',content_sha256
        FROM stored_files`);
      const body = { image_urls: [url(1)], video_urls: [url(2)] };
      const before = (await pool.query('SELECT * FROM stored_files ORDER BY public_url')).rows;
      const ready = await getListingImageStatuses(pool, owner, body);
      assert.equal(ready.images[0].status, 'approved'); assert.equal(ready.videos[0].status, 'approved');
      assert.deepEqual((await pool.query('SELECT * FROM stored_files ORDER BY public_url')).rows, before);
      assert.equal((await getListingImageStatuses(pool, other, body)).videos[0].status, 'unavailable');
      const attached = await attach({ image_urls: [url(1)], video_url: url(2) });
      assert.deepEqual(attached.images, [url(1)]); assert.equal(attached.video_url, url(2));
      await pool.query("UPDATE cloud_backup_accounts SET status='disconnected'");
      assert.equal((await getListingImageStatuses(pool, owner, body)).images[0].status, 'unavailable');
      await assert.rejects(attach({ video_url: url(2) }), e => e.code === 'LISTING_VIDEO_NOT_APPROVED');
      await pool.query("UPDATE cloud_backup_accounts SET status='connected'");
      await pool.query('UPDATE media_backup_items SET user_id=$1 WHERE stored_file_id=(SELECT id FROM stored_files WHERE public_url=$2)', [other, url(1)]);
      await assert.rejects(attach({ image_urls: [url(1)] }), e => e.code === 'LISTING_IMAGE_NOT_APPROVED');
      await pool.query('UPDATE media_backup_items SET user_id=$1', [owner]);
      await pool.query("UPDATE media_backup_items SET plaintext_sha256='wrong-hash'");
      assert.equal((await getListingImageStatuses(pool, owner, body)).videos[0].status, 'unavailable');
      await pool.query("UPDATE media_backup_items SET plaintext_sha256='test-hash'");
      await pool.query('UPDATE stored_files SET content_purged_at=now() WHERE public_url=$1', [url(2)]);
      assert.equal((await getListingImageStatuses(pool, owner, body)).videos[0].status, 'unavailable');
      await assert.rejects(attach({ video_url: url(2) }), e => e.code === 'LISTING_VIDEO_NOT_APPROVED');
    });

    await t.test('verified central vault copies remain readable while stale, retired and purged copies do not', async () => {
      await reset();
      await addFile(1, { released_at: '2026-01-01' });
      await addFile(2, { released_at: '2026-01-01', file_type: 'video', moderation_details: videoScan() });
      await pool.query('INSERT INTO central_drive_account VALUES(1,$1)', ['encrypted-central-token']);
      await pool.query(`INSERT INTO central_drive_objects
        SELECT id,user_id,'verified','remote-id','vault-key','cipher-hash','{}',content_sha256,file_size FROM stored_files`);
      const body = { image_urls: [url(1)], video_urls: [url(2)] };
      let ready = await getListingImageStatuses(pool, owner, body);
      assert.equal(ready.images[0].status, 'approved'); assert.equal(ready.videos[0].status, 'approved');
      const attached = await attach({ image_urls: [url(1)], video_url: url(2) });
      assert.deepEqual(attached.images, [url(1)]); assert.equal(attached.video_url, url(2));
      await pool.query('UPDATE central_drive_objects SET owner_id=$1', [other]);
      assert.equal((await getListingImageStatuses(pool, owner, body)).images[0].status, 'unavailable');
      await pool.query('UPDATE central_drive_objects SET owner_id=$1,file_size=11', [owner]);
      await assert.rejects(attach({ video_url: url(2) }), e => e.code === 'LISTING_VIDEO_NOT_APPROVED');
      await pool.query("UPDATE central_drive_objects SET file_size=10,status='delete_pending'");
      ready = await getListingImageStatuses(pool, owner, body);
      assert.equal(ready.images[0].status, 'unavailable'); assert.equal(ready.videos[0].status, 'unavailable');
      await pool.query("UPDATE central_drive_objects SET status='verified'");
      await pool.query('UPDATE stored_files SET content_purged_at=now()');
      await assert.rejects(attach({ image_urls: [url(1)] }), e => e.code === 'LISTING_IMAGE_NOT_APPROVED');
      assert.equal((await getListingImageStatuses(pool, owner, body)).videos[0].status, 'unavailable');
    });

    await t.test('only the owner can append and deleted or unknown listings remain unavailable', async () => {
      await reset(); await addFile(1);
      await assert.rejects(attach({ image_urls: [url(1)] }, other), error => error.status === 404);
      await assert.rejects(attach({ image_urls: [url(1)] }, owner, id(99)), error => error.status === 404);
      assert.deepEqual(await images(), []);
    });

    await t.test('foreign, pending, rejected, purged, released, general and people images cannot attach', async () => {
      await reset(1);
      const unsafe = [{ user: other }, { moderation_status: 'pending' },
        { moderation_status: 'rejected' }, { content_purged_at: '2026-01-01' },
        { released_at: '2026-01-01' }, { context_type: 'general' },
        { moderation_details: { classification: { category: 'men', detectedCategories: ['men'], uncertain: false } } }];
      for (let n = 0; n < unsafe.length; n++) {
        await addFile(n + 10, unsafe[n]);
        await assert.rejects(attach({ image_urls: [url(n + 10)] }), error => error.code === 'LISTING_IMAGE_NOT_APPROVED');
        assert.deepEqual(await images(), [url(0)]);
      }
    });

    await t.test('status polling is read-only, isolates ownership, and follows fresh scan evidence', async () => {
      await reset();
      await addFile(1, { moderation_status: 'pending', moderation_details: { pending: true } });
      await addFile(2, { user: other, moderation_status: 'rejected', moderation_details: { reason: 'private other-owner reason' } });
      await addFile(3, { context_type: 'general' });
      await addFile(4, { content_purged_at: '2026-01-01' });
      await addFile(5, { released_at: '2026-01-01' });
      await addFile(6, { moderation_status: 'rejected', moderation_details: { reason: 'התמונה נחסמה בסריקה' } });
      const body = { image_urls: [url(1), url(2), url(3), url(4), url(5), url(6), url(99)] };
      const before = (await pool.query('SELECT * FROM stored_files ORDER BY public_url')).rows;
      const status = await getListingImageStatuses(pool, owner, body);
      assert.deepEqual(status.images.map(image => image.status),
        ['pending', 'unavailable', 'unavailable', 'unavailable', 'unavailable', 'rejected', 'unavailable']);
      assert.equal(status.images[5].reason, 'התמונה נחסמה בסריקה');
      assert.doesNotMatch(JSON.stringify(status), /private other-owner/);
      assert.deepEqual((await pool.query('SELECT * FROM stored_files ORDER BY public_url')).rows, before,
        'polling cannot mutate storage or moderation');
      assert.deepEqual(await images(), []);
      await pool.query("UPDATE stored_files SET moderation_status='approved',moderation_details=$1 WHERE public_url=$2",
        [JSON.stringify(objectScan), url(1)]);
      assert.deepEqual(await getListingImageStatuses(pool, owner, { image_urls: [url(1)] }),
        { images: [{ url: url(1), status: 'approved' }], videos: [] });
      await pool.query('UPDATE stored_files SET moderation_details=$1 WHERE public_url=$2',
        [JSON.stringify({ classification: { category: 'men', detectedCategories: ['men'], uncertain: false } }), url(1)]);
      assert.equal((await getListingImageStatuses(pool, owner, { image_urls: [url(1)] })).images[0].status,
        'rejected', 'an approved general safety status cannot substitute for object-only evidence');
      await assert.rejects(getListingImageStatuses(pool, owner, { image_urls: Array.from({ length: 9 }, (_, n) => url(n)) }),
        error => error.status === 400);
    });

    await t.test('ordered batches retain the cover image and repeated responses cannot duplicate images', async () => {
      await reset(1); await addFile(1); await addFile(2);
      const first = await attach({ image_urls: [url(2), url(1)] });
      assert.deepEqual(first.images, [url(0), url(2), url(1)]); assert.equal(first.image_url, url(0));
      assert.deepEqual((await attach({ image_urls: [url(2), url(1)] })).images, first.images);
      assert.deepEqual((await pool.query('SELECT sort_order FROM listing_images ORDER BY sort_order')).rows,
        [{ sort_order: 0 }, { sort_order: 1 }, { sort_order: 2 }]);
    });

    await t.test('legacy cover-only listings retain their cover when adding a background image', async () => {
      await reset(); await addFile(1); await addFile(2);
      await pool.query('UPDATE listings SET image_url=$1 WHERE id=$2', [url(1), listingId]);
      assert.deepEqual((await attach({ image_urls: [url(2)] })).images, [url(1), url(2)]);
    });

    await t.test('concurrent append requests serialize instead of losing one completed batch', async () => {
      await reset(1); await addFile(1); await addFile(2);
      await Promise.all([attach({ image_urls: [url(1)] }), attach({ image_urls: [url(2)] })]);
      const result = await images();
      assert.equal(result[0], url(0)); assert.equal(result.length, 3);
      assert.deepEqual(new Set(result), new Set([url(0), url(1), url(2)]));
    });

    await t.test('a concurrent race for the eighth slot returns a conflict without publishing nine photos', async () => {
      await reset(7); await addFile(7); await addFile(8);
      const results = await Promise.allSettled([attach({ image_urls: [url(7)] }), attach({ image_urls: [url(8)] })]);
      assert.equal(results.filter(result => result.status === 'fulfilled').length, 1);
      assert.equal(results.find(result => result.status === 'rejected').reason.code, 'LISTING_IMAGE_LIMIT');
      assert.equal((await images()).length, 8);
    });

    await t.test('a saved edit completes before a background batch and its metadata and replacement survive', async () => {
      await reset(1); await addFile(1); await addFile(2);
      const editor = await pool.connect();
      try {
        await editor.query('BEGIN');
        await editor.query('SELECT id FROM listings WHERE id=$1 FOR UPDATE', [listingId]);
        const pending = attach({ image_urls: [url(2)] });
        await editor.query(`UPDATE listings SET title='edited title',description='edited description',
          price=222,status='paused',image_url=$1 WHERE id=$2`, [url(1), listingId]);
        await editor.query('UPDATE listing_images SET url=$1 WHERE listing_id=$2', [url(1), listingId]);
        await editor.query('COMMIT');
        assert.deepEqual((await pending).images, [url(1), url(2)]);
      } finally { editor.release(); }
      const listing = (await pool.query('SELECT * FROM listings WHERE id=$1', [listingId])).rows[0];
      assert.equal(listing.title, 'edited title'); assert.equal(listing.description, 'edited description');
      assert.equal(Number(listing.price), 222); assert.equal(listing.status, 'paused');
      assert.equal(listing.expires_at.toISOString(), '2030-01-01T00:00:00.000Z');
    });

    await t.test('replacement preserves position, retries safely, and refuses a conflicting intervening change', async () => {
      await reset(2); await addFile(2); await addFile(3);
      const change = { replacements: [{ expected_old_url: url(0), url: url(2) }] };
      assert.deepEqual((await attach(change)).images, [url(2), url(1)]);
      assert.deepEqual((await attach(change)).images, [url(2), url(1)]);
      await assert.rejects(attach({ replacements: [{ expected_old_url: url(0), url: url(3) }] }),
        error => error.code === 'LISTING_IMAGE_CHANGED');
      assert.deepEqual(await images(), [url(2), url(1)]);
      assert.equal((await pool.query('SELECT count(*)::int AS n FROM stored_files')).rows[0].n, 4,
        'replacement does not physically delete existing personal media');
    });

    await t.test('a database error rolls back both the cover and image collection and releases its connection', async () => {
      await reset(1); await addFile(1);
      let released = false;
      const failingPool = { connect: async () => {
        const client = await pool.connect();
        return { query: (sql, params) => {
          if (sql.startsWith('INSERT INTO listing_images')) throw new Error('synthetic insert failure');
          return client.query(sql, params);
        }, release: () => { released = true; client.release(); } };
      } };
      await assert.rejects(attachListingImages(failingPool, owner, listingId,
        { replacements: [{ expected_old_url: url(0), url: url(1) }] }), /synthetic insert failure/);
      assert.equal(released, true); assert.deepEqual(await images(), [url(0)]);
      assert.equal((await pool.query('SELECT image_url FROM listings WHERE id=$1', [listingId])).rows[0].image_url, url(0));
    });

    await t.test('the existing full edit route atomically commits images or rolls back and releases after validation failures', async () => {
      await reset(1); await addFile(1);
      let outstanding = 0;
      let failInsert = true;
      const testPool = { query: (...args) => pool.query(...args), connect: async () => {
        const client = await pool.connect(); outstanding++;
        return { query: (sql, params) => {
          if (failInsert && sql.trim().startsWith('INSERT INTO listing_images'))
            throw new Error('synthetic full edit failure');
          return client.query(sql, params);
        }, release: () => { outstanding--; client.release(); } };
      } };
      const edit = editHandler(testPool);
      const body = { title: 'new title', description: 'new description', price: 555,
        image_urls: [url(1)], contact_preferences: { in_app: true } };
      assert.equal((await edit(body)).status, 500); assert.equal(outstanding, 0);
      assert.deepEqual(await images(), [url(0)]);
      const previous = (await pool.query('SELECT title,price,image_url FROM listings WHERE id=$1', [listingId])).rows[0];
      assert.equal(previous.title, 'original title'); assert.equal(Number(previous.price), 100); assert.equal(previous.image_url, url(0));
      failInsert = false;
      assert.equal((await edit(body, other)).status, 404); assert.equal(outstanding, 0);
      await pool.query("UPDATE listings SET category='רכב' WHERE id=$1", [listingId]);
      assert.equal((await edit({ ...body, license_plate: 'bad' })).status, 400); assert.equal(outstanding, 0);
      assert.equal((await edit(body)).status, 200); assert.equal(outstanding, 0);
      assert.deepEqual(await images(), [url(1)]);
      assert.equal((await pool.query('SELECT title FROM listings WHERE id=$1', [listingId])).rows[0].title, 'new title');
    });
  } finally {
    if (pool) await pool.end();
    await admin.query(`DROP SCHEMA IF EXISTS ${schema} CASCADE`);
    await admin.end();
  }
});
