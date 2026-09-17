'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const { notifyGuideFilterBlock, shortFilterReason, formatGroupFilterNotice } = require('../server/guide-filter-notice');
const { DEFAULT_CONTENT_FILTER } = require('../server/content-filter-policy');
const { encryptedQueryValues, decryptMessageRows, decryptMessageText } = require('../server/message-at-rest');

function input(extra = {}) {
  return { guideUserId: randomUUID(), userId: randomUUID(), targetType: 'chat',
    targetId: randomUUID(), targetName: 'חבר לבדיקה', fileUrl: '/betshuva-app/uploads/test/image.png',
    fileName: 'תמונה.png', fileType: 'image', classification: { detectedCategories: ['men'] },
    reason: 'תוכן הכולל גברים חסום', ...extra };
}

test('short reasons identify only the actually blocked detected categories', () => {
  for (const [category, label] of Object.entries({ men: 'גברים', women: 'נשים',
    children: 'ילדים' })) {
    assert.equal(shortFilterReason({ fileType: 'image',
      filter: { ...DEFAULT_CONTENT_FILTER, [category]: false },
      classification: { detectedCategories: [category] } }), `תוכן הכולל ${label} חסום`);
  }
  assert.equal(shortFilterReason({ fileType: 'image',
    filter: { ...DEFAULT_CONTENT_FILTER, children: false },
    classification: { detectedCategories: ['men', 'people'] }, reason: 'סיבה שמורה' }), 'סיבה שמורה');
});

test('short reasons respect video policy', () => {
  assert.equal(shortFilterReason({ fileType: 'video',
    filter: { ...DEFAULT_CONTENT_FILTER, video: false } }), 'סרטונים חסומים');
  assert.equal(shortFilterReason({ fileType: 'video', filter: { video: false, men: false },
    classification: { detectedCategories: ['men', 'men'] } }),
  'סרטונים חסומים; תוכן הכולל גברים חסום');
});

test('legacy text and landscape flags do not invent a blocked-category reason', () => {
  for (const fileType of ['text', 'sticker', 'audio', 'document', 'image']) {
    assert.equal(shortFilterReason({ fileType,
      filter: { ...DEFAULT_CONTENT_FILTER, text: false, nonHumanImages: false },
      classification: { detectedCategories: ['nonHumanImages'] },
      reason: 'סיבה אחרת' }), 'סיבה אחרת');
  }
});

test('unknown people and uncertain classifications do not invent a specific person category', () => {
  assert.equal(shortFilterReason({ fileType: 'image', filter: { children: false },
    classification: { category: 'people' } }), 'תמונות אנשים חסומות לפי הגדרות הסינון');
  assert.equal(shortFilterReason({ fileType: 'image', filter: { women: false },
    classification: { uncertain: true } }), 'סיווג התמונה אינו ודאי ביחס להגדרות הסינון');
  assert.equal(shortFilterReason({ reason: '  הסינון\n של\u202e הנמען  ' }), 'הסינון של הנמען');
  assert.equal(shortFilterReason({ reason: 'א'.repeat(500) }).length, 160);
});

function blockedMember(name, extra = {}) {
  return { name, filter: { ...DEFAULT_CONTENT_FILTER, men: false },
    fileType: 'image', classification: { detectedCategories: ['men'] }, ...extra };
}

test('group formatter gives each member a separate line even for identical reasons', () => {
  const result = formatGroupFilterNotice('לימוד משותף', [
    blockedMember('דני'), blockedMember('רוני'),
    blockedMember('יעל', { filter: { ...DEFAULT_CONTENT_FILTER, women: false },
      classification: { detectedCategories: ['women'] } }),
  ]);
  assert.equal(result, 'בקבוצה ״לימוד משותף״ נחסם ל:\n' +
    '• דני — תוכן הכולל גברים חסום\n' +
    '• רוני — תוכן הכולל גברים חסום\n' +
    '• יעל — תוכן הכולל נשים חסום');
});

test('group formatter retains every member beyond eight names and 600 characters', () => {
  const members = Array.from({ length: 30 }, (_, index) =>
    blockedMember(`חבר מספר ${index + 1} עם שם משפחה ארוך לבדיקה`));
  const result = formatGroupFilterNotice('קבוצה גדולה', members);
  const expected = ['בקבוצה ״קבוצה גדולה״ נחסם ל:',
    ...members.map(member => `• ${member.name} — תוכן הכולל גברים חסום`)].join('\n');
  assert.ok(expected.length > 600);
  assert.equal(result, expected);
  assert.equal(result.split('\n').length, members.length + 1);
});

test('member and group names cannot inject extra rows or direction controls', () => {
  const result = formatGroupFilterNotice('קבוצה\r\n• קבוצה מזויפת\u202e\u2066\u0000', [
    blockedMember('דני\r\n• נמען מזויף\u202e\u2067\u0000'),
    blockedMember('רוני\u2028• נמען נוסף\u2029\t\u001b'),
  ]);
  const lines = result.split('\n');
  assert.equal(lines.length, 3, 'only the formatter may introduce row separators');
  assert.match(lines[0], /^בקבוצה ״.+״ נחסם ל:$/);
  assert.ok(lines.slice(1).every(line => line.startsWith('• ') && line.endsWith(' — תוכן הכולל גברים חסום')));
  assert.doesNotMatch(result, /[\u0000-\u0009\u000b-\u001f\u007f\u2028\u2029\u202a-\u202e\u2066-\u2069]/);
  assert.equal((result.match(/^• /gm) || []).length, 2);
});

test('invalid target, sender or file never obtains a database connection', async () => {
  let connections = 0;
  const valid = input({ pool: { connect() { connections++; throw new Error('unexpected DB use'); } }, relay() {} });
  const badValues = [{ userId: '' }, { guideUserId: valid.userId }, { targetId: 'invalid' },
    { targetType: 'public' }, { targetName: ' \n ' }, { fileType: 'text' },
    { fileUrl: 'https://other.invalid/image.png' }, { fileUrl: '//other.invalid/image.png' },
    { fileUrl: '/uploads/../private.png' }, { fileUrl: '/uploads/%2e%2e/private.png' },
    { fileUrl: '/uploads/%00.png' }, { fileUrl: '/uploads/image.png?token=secret' },
    { authorize: true }, { relay: null }];
  for (const invalid of badValues) {
    await assert.rejects(notifyGuideFilterBlock({ ...valid, ...invalid }), TypeError);
  }
  assert.equal(connections, 0);
});

test('authorization failure rolls back before lookup or insertion and releases connection', async () => {
  const statements = [];
  let released = false;
  const client = { async query(sql) { statements.push(sql); return { rows: [] }; },
    release() { released = true; } };
  const result = await notifyGuideFilterBlock(input({ pool: { connect: async () => client },
    authorize: async db => { assert.equal(db, client); return false; },
    relay() { assert.fail('unauthorized notices must not relay'); } }));
  assert.equal(result, null);
  assert.equal(statements.at(-1), 'ROLLBACK');
  assert.ok(statements.every(sql => !sql.includes('FROM messages') && !sql.includes('INSERT')));
  assert.equal(released, true);
});

async function fixture(t) {
  const { Client, Pool } = require('pg');
  assert.ok(process.env.DATABASE_URL, 'RUN_DB_TESTS requires DATABASE_URL (use -r dotenv/config locally)');
  const config = { connectionString: process.env.DATABASE_URL, connectionTimeoutMillis: 5000,
    ssl: process.env.DB_SSL === 'true'
      ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' } : false };
  const owner = new Client(config);
  await owner.connect();
  const schema = `guide_filter_notice_test_${randomUUID().replaceAll('-', '')}`;
  await owner.query(`CREATE SCHEMA "${schema}"`);
  const raw = new Pool({ ...config, options: `-c search_path=${schema},pg_catalog`, max: 4 });
  const oldKey = process.env.MESSAGE_ENCRYPTION_KEY;
  process.env.MESSAGE_ENCRYPTION_KEY = 'synthetic-guide-filter-notice-test-key-32-characters';
  t.after(async () => {
    await raw.end();
    await owner.query(`DROP SCHEMA "${schema}" CASCADE`);
    await owner.end();
    if (oldKey === undefined) delete process.env.MESSAGE_ENCRYPTION_KEY;
    else process.env.MESSAGE_ENCRYPTION_KEY = oldKey;
  });
  await raw.query(`CREATE TABLE messages(
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),sender_id uuid NOT NULL,recipient_id uuid,
    group_id uuid,type text,body text,file_url text,file_name text,
    reply_to_id uuid REFERENCES messages(id),delivery_summary jsonb,
    created_at timestamptz DEFAULT now(),deleted_for_everyone bool DEFAULT FALSE)`);
  let rejectText = false;
  const pool = { async connect() {
    const client = await raw.connect();
    return { async query(sql, args) {
      if (rejectText && sql.includes('INSERT INTO messages') && sql.includes("'text'"))
        throw new Error('synthetic explanation insert failure');
      return decryptMessageRows(await client.query(sql, encryptedQueryValues(sql, args)));
    }, release: () => client.release() };
  } };
  return { raw, pool, failText(value) { rejectText = value; } };
}

test('guide notices persist atomically with encrypted bodies and concurrent retry dedupe', {
  skip: process.env.RUN_DB_TESTS !== '1',
}, async t => {
  const f = await fixture(t);
  const received = [];
  const request = input({ pool: f.pool, guideUserName: 'ישראל מדריך בתשובה',
    async relay(userId, event, payload) {
      const committed = await f.raw.query('SELECT id FROM messages WHERE id=$1', [payload.id]);
      assert.equal(committed.rows.length, 1, 'message must be committed before it is delivered');
      received.push({ userId, event, payload });
    } });
  const clear = async () => { await f.raw.query('TRUNCATE messages'); received.length = 0; };

  await t.test('file precedes linked explanation, only the original sender receives both', async () => {
    const result = await notifyGuideFilterBlock({ ...request, authorize: async client => {
      const before = await client.query('SELECT id FROM messages');
      assert.equal(before.rows.length, 0, 'authorization precedes any new message granting access');
      return true;
    } });
    const rows = (await f.raw.query('SELECT * FROM messages ORDER BY created_at')).rows;
    assert.equal(rows.length, 2);
    assert.equal(rows[0].id, result.fileMessageId);
    assert.equal(rows[0].body, null);
    assert.equal(rows[0].file_url, request.fileUrl);
    assert.equal(rows[1].id, result.noticeMessageId);
    assert.equal(rows[1].reply_to_id, rows[0].id);
    assert.match(rows[1].body, /^enc:v1:/);
    assert.equal(decryptMessageText(rows[1].body), 'נחסם לחבר לבדיקה: תוכן הכולל גברים חסום');
    const delay = (await f.raw.query(`SELECT EXTRACT(EPOCH FROM(n.created_at-f.created_at))*1000 AS delay
      FROM messages n JOIN messages f ON f.id=n.reply_to_id`)).rows[0].delay;
    assert.ok(Number(delay) >= 1, `message separation is ${delay}ms`);
    assert.deepEqual(received.map(item => [item.userId, item.event]),
      [[request.userId, 'chat:message'], [request.userId, 'chat:message']]);
    assert.ok(received.every(item => item.payload.fromUserId === request.guideUserId &&
      item.payload.fromName === request.guideUserName && !('deliverySummary' in item.payload)));
    assert.deepEqual(received[0].payload.classification, request.classification);
    assert.equal(received[1].payload.replyToId, result.fileMessageId);
    assert.equal(received[1].payload.replyBody, request.fileName);
    assert.equal(result.duplicate, false);
  });

  await t.test('six simultaneous retries create one file and one explanation', async () => {
    await clear();
    const results = await Promise.all(Array.from({ length: 6 }, () => notifyGuideFilterBlock(request)));
    assert.equal(results.filter(result => !result.duplicate).length, 1);
    assert.equal(new Set(results.map(result => result.fileMessageId)).size, 1);
    assert.equal(new Set(results.map(result => result.noticeMessageId)).size, 1);
    assert.equal((await f.raw.query('SELECT * FROM messages')).rows.length, 2);
    assert.equal(received.length, 2);
    assert.equal((await notifyGuideFilterBlock(request)).duplicate, true);
    assert.equal(received.length, 2, 'duplicates must not replay notifications');
  });

  await t.test('same-name targets, changed reasons, other senders and target kinds remain distinct', async () => {
    await clear();
    for (const extra of [{}, { targetId: randomUUID() }, { reason: 'תוכן הכולל נשים חסום' },
      { userId: randomUUID() }, { targetType: 'group' }]) {
      assert.equal((await notifyGuideFilterBlock({ ...request, ...extra })).duplicate, false);
    }
    assert.equal((await f.raw.query('SELECT * FROM messages')).rows.length, 10);
    assert.equal(received.length, 10);
    assert.match(received.at(-1).payload.text, /^נחסם לקבוצה /);
  });

  await t.test('one minute window expires, allowing a fresh report after another attempt', async () => {
    await clear();
    const first = await notifyGuideFilterBlock(request);
    await f.raw.query("UPDATE messages SET created_at=created_at-interval '61 seconds'");
    const next = await notifyGuideFilterBlock(request);
    assert.equal(next.duplicate, false);
    assert.notEqual(next.fileMessageId, first.fileMessageId);
    assert.equal((await f.raw.query('SELECT * FROM messages')).rows.length, 4);
  });

  await t.test('failed explanation insert rolls back the file and emits nothing', async () => {
    await clear();
    f.failText(true);
    try { await assert.rejects(notifyGuideFilterBlock(request), /synthetic explanation insert failure/); }
    finally { f.failText(false); }
    assert.equal((await f.raw.query('SELECT * FROM messages')).rows.length, 0);
    assert.equal(received.length, 0);
  });

  await t.test('authorization rechecks happen even for an otherwise duplicate notice', async () => {
    await clear();
    await notifyGuideFilterBlock(request);
    assert.equal(await notifyGuideFilterBlock({ ...request, authorize: async () => false }), null);
    assert.equal((await f.raw.query('SELECT * FROM messages')).rows.length, 2);
    assert.equal(received.length, 2);
  });

  await t.test('group newlines survive encryption, socket delivery and retry dedupe', async () => {
    await clear();
    const groupRequest = { ...request, targetType: 'group',
      noticeText: formatGroupFilterNotice('בדיקה', [blockedMember('דני'), blockedMember('רוני')]) };
    const result = await notifyGuideFilterBlock(groupRequest);
    const stored = (await f.raw.query('SELECT body FROM messages WHERE id=$1', [result.noticeMessageId])).rows[0];
    assert.match(stored.body, /^enc:v1:/);
    assert.equal(decryptMessageText(stored.body), groupRequest.noticeText);
    assert.equal(decryptMessageText(stored.body).split('\n').length, 3);
    assert.equal(received.at(-1).payload.text, groupRequest.noticeText);
    assert.equal((await notifyGuideFilterBlock(groupRequest)).duplicate, true);
    assert.equal(received.length, 2, 'identical multiline retries must not repeat socket messages');
    const changed = formatGroupFilterNotice('בדיקה', [blockedMember('דני'), blockedMember('שלומית')]);
    assert.equal((await notifyGuideFilterBlock({ ...groupRequest, noticeText: changed })).duplicate, false);
    assert.equal(received.at(-1).payload.text, changed);
    assert.equal((await f.raw.query('SELECT * FROM messages')).rows.length, 4);
  });

  await t.test('long group notices retain the final members in storage, delivery and dedupe identity', async () => {
    await clear();
    const members = Array.from({ length: 30 }, (_, index) =>
      blockedMember(`משתתף מספר ${index + 1} עם שם משפחה ארוך במיוחד`));
    const noticeText = formatGroupFilterNotice('קבוצה גדולה', members);
    assert.ok(noticeText.length > 600);
    const groupRequest = { ...request, targetType: 'group', noticeText };
    const result = await notifyGuideFilterBlock(groupRequest);
    const stored = (await f.raw.query('SELECT body FROM messages WHERE id=$1', [result.noticeMessageId])).rows[0];
    assert.equal(decryptMessageText(stored.body), noticeText);
    assert.equal(received.at(-1).payload.text, noticeText);
    assert.equal(received.at(-1).payload.text.split('\n').length, members.length + 1);
    assert.equal((await notifyGuideFilterBlock(groupRequest)).duplicate, true);
    assert.equal(received.length, 2);
    members[members.length - 1] = blockedMember('חבר אחר בסוף הרשימה');
    const changed = formatGroupFilterNotice('קבוצה גדולה', members);
    assert.equal(changed.slice(0, 600), noticeText.slice(0, 600));
    const next = await notifyGuideFilterBlock({ ...groupRequest, noticeText: changed });
    assert.equal(next.duplicate, false, 'a changed member beyond character 600 is a distinct notice');
    assert.equal(received.at(-1).payload.text, changed);
    assert.equal((await f.raw.query('SELECT * FROM messages')).rows.length, 4);
  });
});
