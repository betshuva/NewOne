'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { projectProfileImages } = require('../server/profile-image-policy');
const { normalizePhone } = require('../server/contact-phone-privacy');

const source = fs.readFileSync(require.resolve('../server/index.js'), 'utf8');
const viewerId = 'viewer-aviv';
const routes = [
  ['get', '/api/users'],
  ['get', '/api/users/directory'],
  ['get', '/api/users/search'],
  ['post', '/api/contacts/match'],
  ['get', '/api/message-requests'],
];

function section(startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start + startMarker.length);
  assert.ok(start >= 0 && end > start, `missing server section: ${startMarker}`);
  return source.slice(start, end + endMarker.length);
}

function fixtures() {
  const rows = [
    { id: 'female-photo', profile_pic_url: '/uploads/woman.jpg' },
    { id: 'male-photo', profile_pic_url: '/uploads/man.jpg' },
    { id: 'mixed-photo', profile_pic_url: '/uploads/mixed.jpg' },
    { id: 'legacy-photo', profile_pic_url: 'https://example.test/legacy-photo.jpg' },
    { id: 'emoji-photo', profile_pic_url: 'emoji:🌿' },
    { id: 'no-photo', profile_pic_url: null },
  ].map(row => ({
    name: row.id, phone: '0501234567', city: 'Test city', saved: true,
    // Contact and recipient settings must not replace the viewer's profile policy.
    receiving_filter: { women: true }, filter_override: { women: true },
    ...row,
  }));
  const files = [
    ['/uploads/woman.jpg', { category: 'women' }],
    ['/uploads/man.jpg', { category: 'men' }],
    ['/uploads/mixed.jpg', { category: 'men', detectedCategories: ['men', 'women'] }],
  ].map(([public_url, classification]) => ({
    public_url, classification, file_type: 'image', moderation_status: 'approved',
    content_purged_at: null, blocked: false,
  }));
  return { rows, files };
}

function harness(method, route, { women = false } = {}) {
  const data = fixtures();
  const isRequests = route === '/api/message-requests';
  const originalRows = isRequests
    ? data.rows.map(row => ({ ...row, id: `request-${row.id}`, sender_id: row.id,
      sender_name: row.name }))
    : data.rows;
  const originalJson = JSON.stringify(originalRows);
  let filter = { text: true, video: true, nonHumanImages: true, men: true,
    women, children: true, enforceGeneralFilter: false };
  const filterReaders = [];
  const phoneCalls = [];
  const rememberedPhones = [];
  const self = { id: viewerId, profile_pic_url: 'https://example.test/self-photo.jpg' };
  const pool = {
    async query(sql, values) {
      if (/^SELECT content_filter FROM users WHERE id=\$1$/.test(sql)) {
        filterReaders.push(values[0]);
        return { rows: [{ content_filter: { ...filter } }] };
      }
      if (/FROM stored_files WHERE public_url=ANY/.test(sql)) {
        return { rows: data.files.filter(file => values[0].includes(file.public_url)) };
      }
      if (/SELECT u\.id,u\.profile_pic_url,u\.content_filter AS receiving_filter/.test(sql)) {
        return { rows: [self] };
      }
      const expectedSelect = isRequests ? /FROM message_requests mr/
        : route === '/api/users' ? /FROM users u[\s\S]*LEFT JOIN user_contacts c/
          : /FROM users[\s\S]*blocked_users/;
      assert.match(sql, expectedSelect, 'unexpected route database query');
      assert.equal(values[0], viewerId, 'the list belongs to the authenticated viewer');
      return { rows: originalRows };
    },
  };
  let handler;
  const context = vm.createContext({
    app: { [method](registeredRoute, ...handlers) {
      assert.equal(registeredRoute, route);
      handler = handlers.at(-1);
    } },
    authWithDbCheck() {}, searchRateLimit() {},
    getPool: async () => pool, projectProfileImages, normalizePhone,
    projectContactPhones: async (passedPool, ownerId, rows, options) => {
      assert.equal(passedPool, pool);
      assert.equal(ownerId, viewerId);
      phoneCalls.push(options);
      return rows.map(row => ({ ...row, phone: null, phone_visible: false }));
    },
    rememberKnownContactPhones: async (passedPool, ownerId, phones, options) => {
      assert.equal(passedPool, pool);
      assert.equal(ownerId, viewerId);
      rememberedPhones.push({ phones: [...phones], options });
    },
    provisionSystemConversation: async () => {},
    messageAfterConversationClear: () => 'TRUE',
    SCAN_BOT_ID: 'scan', SYSTEM_USER_ID: 'guide', GOOGLE_PLAY_REVIEWER_ID: 'reviewer',
  });
  // Load the actual wrapper as well as the registered handler, so omitting
  // either integration causes a behavioral failure instead of passing a mock.
  vm.runInContext(section('async function projectContactProfiles(', '\n}'), context);
  vm.runInContext(section(`app.${method}('${route}',`, '\n});'), context);
  return {
    originalRows, originalJson, phoneCalls, rememberedPhones, filterReaders,
    allowWomen(value) { filter = { ...filter, women: value }; },
    async invoke() {
      const res = {
        statusCode: 200, headers: {},
        status(code) { this.statusCode = code; return this; },
        set(name, value) { this.headers[name.toLowerCase()] = value; return this; },
        json(body) { this.body = body; return this; },
      };
      await handler({
        user: { id: viewerId }, query: { q: '0501234567' },
        body: { phones: ['+972 50-123-4567'], emails: [], source: 'phone_manual' },
      }, res);
      assert.equal(res.statusCode, 200, JSON.stringify(res.body));
      assert.equal(res.headers['cache-control'], 'no-store');
      assert.equal(JSON.stringify(originalRows), originalJson, 'projection must not mutate database rows');
      return res.body;
    },
  };
}

for (const [method, route] of routes) {
  test(`${method.toUpperCase()} ${route} applies the viewer's blocked-women preference to avatars`, async () => {
    const api = harness(method, route);
    const rows = await api.invoke();
    const byId = new Map(rows.map(row => [row.sender_id || row.id, row]));
    assert.equal(byId.get('female-photo').profile_pic_url, null);
    assert.equal(byId.get('mixed-photo').profile_pic_url, null);
    assert.equal(byId.get('legacy-photo').profile_pic_url, null);
    assert.equal(byId.get('male-photo').profile_pic_url, '/uploads/man.jpg');
    assert.equal(byId.get('emoji-photo').profile_pic_url, 'emoji:🌿');
    assert.equal(byId.get('no-photo').profile_pic_url, null);
    assert.equal(byId.get('female-photo').saved, true, 'saved contacts remain accessible');
    assert.equal(byId.get('female-photo').city, 'Test city');
    assert.deepEqual(api.filterReaders, [viewerId]);
    assert.equal(api.phoneCalls.length, 1, 'existing phone privacy projection still runs');
    if (route === '/api/message-requests') {
      assert.equal(byId.get('female-photo').phoneSharing.phone_visible, false);
      assert.equal(byId.get('female-photo').id, 'request-female-photo');
    } else {
      assert.equal(byId.get('female-photo').phone, null);
      assert.equal(byId.get('female-photo').phone_visible, false);
    }
    if (route === '/api/users') {
      assert.equal(byId.get(viewerId).profile_pic_url, null);
      assert.equal(byId.get(viewerId).is_self, true);
      assert.equal(byId.get(viewerId).name, 'הודעות לעצמי');
    }
    if (route === '/api/users/search' || route === '/api/contacts/match') {
      assert.deepEqual([...api.phoneCalls[0].knownPhones], ['0501234567']);
    }
    if (route === '/api/contacts/match') {
      assert.equal(api.rememberedPhones.length, 1);
      assert.deepEqual(api.rememberedPhones[0].phones, ['0501234567']);
      assert.equal(api.rememberedPhones[0].options.source, 'phone_manual');
    }
  });

  test(`${method.toUpperCase()} ${route} refreshes avatars after the viewer changes preferences`, async () => {
    const api = harness(method, route, { women: true });
    const visible = await api.invoke();
    const find = (rows, id) => rows.find(row => (row.sender_id || row.id) === id);
    assert.equal(find(visible, 'female-photo').profile_pic_url, '/uploads/woman.jpg');
    assert.equal(find(visible, 'legacy-photo').profile_pic_url, 'https://example.test/legacy-photo.jpg');
    api.allowWomen(false);
    const filtered = await api.invoke();
    assert.equal(find(filtered, 'female-photo').profile_pic_url, null);
    assert.equal(find(filtered, 'legacy-photo').profile_pic_url, null);
    assert.equal(find(filtered, 'male-photo').profile_pic_url, '/uploads/man.jpg');
    assert.deepEqual(api.filterReaders, [viewerId, viewerId]);
  });
}
