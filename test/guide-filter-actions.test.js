'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../server/index.js'), 'utf8');
const start = source.indexOf('const GROUP_FILTER_ACTIONS =');
const end = source.indexOf('\nfunction formatSentMessageRow(', start);
assert.ok(start >= 0 && end > start);
const handleSystemAction = vm.runInNewContext(
  `${source.slice(start, end)}; handleSystemAction`, {
    SYSTEM_USER_ID: 'guide', SAFE_INFORMATION_USER_ID: 'safe', SCAN_BOT_ID: 'scan',
  });

test('guide explains fixed categories without creating a filter action', async () => {
  const pool = { query() { assert.fail('fixed categories must not query or change filters'); } };
  for (const command of ['חסום', 'אפשר']) {
    for (const category of ['טקסט', 'תמונות נוף', 'תמונות חפצים']) {
      for (const target of ['מהחבר דני', 'בקבוצת הטיולים']) {
        const reply = await handleSystemAction(pool, 'owner', `${command} ${category} ${target}`);
        assert.match(reply, /מותרים תמיד/);
        assert.doesNotMatch(reply, /ממתינה לאישור|חסמתי|אפשרתי/);
      }
    }
  }
});

test('legacy pending fixed-category actions are consumed without changing filters', async () => {
  for (const action of ['set_group_filter', 'set_contact_filter']) {
    for (const key of ['text', 'nonHumanImages']) {
      for (const enabled of [false, true]) {
        let calls = 0;
        const pool = { async query(sql, args) {
          calls++;
          assert.match(sql, /^DELETE FROM system_ai_pending_actions/);
          assert.equal(args[0], 'owner');
          return { rows: [{ action, payload: { key, enabled, groupId: 'group', contactId: 'contact' } }] };
        } };
        const reply = await handleSystemAction(pool, 'owner', 'אישור');
        assert.equal(calls, 1);
        assert.match(reply, /מותרים תמיד/);
        assert.doesNotMatch(reply, /השינוי פעיל|חסמתי|אפשרתי/);
      }
    }
  }
});

test('guide still confirms and applies configurable categories', async () => {
  for (const action of ['set_group_filter', 'set_contact_filter']) {
    for (const key of ['men', 'women', 'children', 'video']) {
      let calls = 0;
      const pool = { async query(sql, args) {
        calls++;
        if (calls === 1) return { rows: [{ action, payload: {
          key, enabled: false, label: key, groupId: 'group', contactId: 'contact',
        } }] };
        assert.match(sql, action === 'set_group_filter' ? /^UPDATE groups/ : /^UPDATE user_contacts/);
        assert.equal(args[0], key);
        assert.equal(args[1], false);
        return { rows: [{ name: 'יעד' }] };
      } };
      const reply = await handleSystemAction(pool, 'owner', 'אישור');
      assert.equal(calls, 2);
      assert.match(reply, /חסמתי.*השינוי פעיל/);
    }
  }
});
