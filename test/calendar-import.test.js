"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { Client } = require("pg");
const { SCHEMA, registerCalendar, validateEvent, occurrences } = require("../server/calendar");
const { parseCalendarShare, parseCalendarDraft, signImportToken, verifyImportToken, MAX_BYTES } = require("../server/calendar-import");
const calendar = (contents) => `BEGIN:VCALENDAR\r\nVERSION:2.0\r\n${contents}\r\nEND:VCALENDAR\r\n`;
const event = (extra = "", times = "DTSTART;TZID=Asia/Jerusalem:20261020T090000\r\nDTEND;TZID=Asia/Jerusalem:20261020T100000") =>
  `BEGIN:VEVENT\r\nUID:shared-event@example.test\r\nSUMMARY:פגישה\r\n${times}\r\n${extra}\r\nEND:VEVENT`;
const first = (contents) => parseCalendarShare(calendar(contents)).drafts[0];

test("ICS import keeps Hebrew text, folded lines, escaped characters and IANA timezone", () => {
  const entry = first(event("DESCRIPTION:שורה ראשונה\\nשורה שנייה\\, הערה\r\nLOCATION:בית ה\r\n כנסת"));
  assert.equal(entry.draft.location, "בית הכנסת");
  assert.equal(entry.draft.notes, "שורה ראשונה\nשורה שנייה, הערה");
  assert.equal(entry.draft.timezone, "Asia/Jerusalem");
  assert.equal(entry.draft.start, "2026-10-20T09:00");
  assert.deepEqual(entry.draft.invitees, []);
  assert.equal(entry.requires_single_occurrence, false);
  assert.doesNotThrow(() => validateEvent(entry.draft));
});

test("UTC instants and floating times are distinct; missing zone has a visible warning", () => {
  const utc = first(event("", "DTSTART:20261020T060000Z\r\nDTEND:20261020T070000Z"));
  assert.equal(utc.draft.timezone, "UTC");
  assert.equal(utc.draft.start, "2026-10-20T06:00");
  const floating = parseCalendarShare(calendar(event("", "DTSTART:20261020T090000\r\nDTEND:20261020T100000")), "America/New_York").drafts[0];
  assert.equal(floating.draft.timezone, "America/New_York");
  assert.match(floating.warnings.join(" "), /לא צוין אזור זמן/);
});

test("all-day DTEND stays exclusive and absent end is the following calendar day", () => {
  const allDay = first(event("", "DTSTART;VALUE=DATE:20261020\r\nDTEND;VALUE=DATE:20261023"));
  assert.equal(allDay.draft.all_day, true);
  assert.equal(allDay.draft.end, "2026-10-23T00:00");
  assert.equal(first(event("", "DTSTART;VALUE=DATE:20261020")).draft.end, "2026-10-21T00:00");
  assert.equal(occurrences(validateEvent(allDay.draft)).length, 1);
});

test("positive DURATION and missing timed end are handled explicitly", () => {
  assert.equal(first(event("DURATION:PT90M", "DTSTART:20261020T090000Z")).draft.end, "2026-10-20T10:30");
  const noEnd = first(event("", "DTSTART:20261020T090000Z"));
  assert.equal(noEnd.draft.end, "2026-10-20T10:00");
  assert.match(noEnd.warnings.join(" "), /לא צוינה שעת סיום/);
  assert.throws(() => first(event("DURATION:PT1H")), { status: 400 });
  assert.throws(() => first(event("DURATION:-PT1H", "DTSTART:20261020T090000Z")), { status: 400 });
});

test("finite native recurrences preserve local time, including UTC UNTIL across DST", () => {
  const weekly = first(event("RRULE:FREQ=WEEKLY;BYDAY=TU;COUNT=2"));
  assert.equal(weekly.draft.repeat, "weekly");
  const times = occurrences(validateEvent(weekly.draft));
  assert.equal(times[0].start, "2026-10-20T06:00:00.000Z");
  assert.equal(times[1].start, "2026-10-27T07:00:00.000Z");
  const until = first(event("RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL=20261027T070000Z"));
  assert.equal(until.draft.count, 2);
  assert.equal(first(event("RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL=20261027T065959Z")).draft.count, 1);
  const floatingUntil = first(event("RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL=20261027T070000", "DTSTART:20261020T090000\r\nDTEND:20261020T100000"));
  assert.equal(floatingUntil.draft.count, 1);
  const daily = first(event("RRULE:FREQ=DAILY;INTERVAL=3;COUNT=4"));
  assert.equal(daily.draft.interval, 3);
  assert.equal(occurrences(validateEvent(daily.draft)).length, 4);
});

test("unsupported recurrence never silently changes its meaning", () => {
  for (const rule of ["FREQ=YEARLY", "FREQ=DAILY;COUNT=105", "FREQ=WEEKLY;INTERVAL=2;COUNT=2",
    "FREQ=MONTHLY;BYDAY=1MO;COUNT=2", "FREQ=MONTHLY;COUNT=2"]) {
    const entry = first(event(`RRULE:${rule}`, "DTSTART;TZID=Asia/Jerusalem:20260131T090000\r\nDTEND;TZID=Asia/Jerusalem:20260131T100000"));
    assert.equal(entry.requires_single_occurrence, true, rule);
    assert.equal(entry.draft.repeat, "none");
    assert.match(entry.warnings.join(" "), /המופע המשותף בלבד/);
  }
  assert.equal(first(event("RDATE;TZID=Asia/Jerusalem:20261027T090000")).requires_single_occurrence, true);
  assert.equal(first(event("RRULE:FREQ=WEEKLY;COUNT=3\r\nEXDATE;TZID=Asia/Jerusalem:20261027T090000")).requires_single_occurrence, true);
});

test("bad dates, unknown timezone and ambiguous/nonexistent local times are rejected", () => {
  for (const time of ["DTSTART:20260230T090000Z", "DTSTART;TZID=Bad/Zone:20261020T090000",
    "DTSTART;TZID=Asia/Jerusalem:20260327T023000", "DTSTART;TZID=Asia/Jerusalem:20261025T013000"])
    assert.throws(() => first(event("", time)), { status: 400 });
  assert.equal(first(event("", "DTSTART:20240229T090000Z")).draft.start, "2024-02-29T09:00");
});

test("embedded non-IANA VTIMEZONE is resolved without guessing a timezone", () => {
  const zone = "BEGIN:VTIMEZONE\r\nTZID:CustomTest\r\nBEGIN:STANDARD\r\nDTSTART:19700101T000000\r\nTZOFFSETFROM:+0200\r\nTZOFFSETTO:+0200\r\nEND:STANDARD\r\nEND:VTIMEZONE";
  const entry = parseCalendarShare(calendar(`${zone}\r\n${event("", "DTSTART;TZID=CustomTest:20261020T090000\r\nDTEND;TZID=CustomTest:20261020T100000")}`)).drafts[0];
  assert.equal(entry.draft.timezone, "UTC");
  assert.equal(entry.draft.start, "2026-10-20T07:00");
  assert.match(entry.warnings.join(" "), /הומר ל־UTC/);
  const recurring = parseCalendarShare(calendar(`${zone}\r\n${event("RRULE:FREQ=WEEKLY;COUNT=2", "DTSTART;TZID=CustomTest:20261020T090000\r\nDTEND;TZID=CustomTest:20261020T100000")}`)).drafts[0];
  assert.equal(recurring.requires_single_occurrence, true);
});

test("external attendees and attachments do not become invitations or downloads", () => {
  const entry = first(event("ATTENDEE:mailto:private@example.test\r\nATTACH:https://127.0.0.1/private\r\nURL:https://example.test/event"));
  assert.deepEqual(entry.draft.invitees, []);
  assert.match(entry.warnings.join(" "), /אינם מוזמנים אוטומטית/);
  assert.match(entry.warnings.join(" "), /לא הורדו/);
  assert.equal(entry.draft.notes, "https://example.test/event");
});

test("bounded ICS, multiple events and cancellation are handled without partial parsing", () => {
  assert.throws(() => parseCalendarShare("x".repeat(MAX_BYTES + 1)), { status: 400 });
  assert.throws(() => parseCalendarShare(calendar(Array(51).fill(event()).join("\r\n"))), { status: 400 });
  assert.throws(() => parseCalendarShare("this is not an event"), { status: 400 });
  const result = parseCalendarShare(calendar(`${event("STATUS:CANCELLED")}\r\n${event().replace("shared-event", "other-event")}`));
  assert.equal(result.drafts.length, 1);
  assert.match(result.warnings.join(" "), /בוטל/);
});

test("typed Android calendar extras preserve epochs and do not trust external invitees", () => {
  const entry = parseCalendarDraft({ title: "אירוע בטלפון", start_epoch_ms: Date.parse("2026-10-20T06:00:00Z"),
    end_epoch_ms: Date.parse("2026-10-20T07:00:00Z"), timezone: "Asia/Jerusalem",
    invitees: ["attacker"], external_id: "phone-event", recurrence: "weekly" }).drafts[0];
  assert.equal(entry.draft.start, "2026-10-20T09:00");
  assert.deepEqual(entry.draft.invitees, []);
  assert.equal(entry.requires_single_occurrence, true);
  assert.doesNotThrow(() => validateEvent(entry.draft));
  const native = parseCalendarDraft({ title: "אירוע מהיומן", beginTime: Date.parse("2026-10-20T06:00:00Z"),
    endTime: Date.parse("2026-10-20T07:00:00Z"), eventTimezone: "Asia/Jerusalem",
    description: "תיאור מהטלפון", eventLocation: "ירושלים" }).drafts[0];
  assert.equal(native.draft.start, "2026-10-20T09:00");
  assert.equal(native.draft.notes, "תיאור מהטלפון");
  const nativeDay = parseCalendarDraft({ beginTime: Date.parse("2026-10-20T00:00:00Z"),
    endTime: Date.parse("2026-10-21T00:00:00Z"), eventTimezone: "Asia/Jerusalem", allDay: true }).drafts[0];
  assert.equal(nativeDay.draft.start, "2026-10-20T00:00");
  assert.equal(nativeDay.draft.end, "2026-10-21T00:00");
  assert.doesNotThrow(() => validateEvent(nativeDay.draft));
});

test("import authorization expires, binds the actor and rejects changed claims", () => {
  const entry = first(event());
  const token = signImportToken(entry, "alice", "test-secret", 1000000);
  assert.equal(verifyImportToken(token, "alice", "test-secret", 1000000).key, entry.source_key);
  assert.throws(() => verifyImportToken(token, "bob", "test-secret", 1000000), { status: 403 });
  assert.throws(() => verifyImportToken(token, "alice", "test-secret", 1900000), { status: 403 });
  assert.throws(() => verifyImportToken(`${token[0] === "e" ? "f" : "e"}${token.slice(1)}`, "alice", "test-secret", 1000000));
  assert.throws(() => verifyImportToken(token, "alice", "another-secret", 1000000), { status: 403 });
});

test("calendar import DB: preview never writes; repeated imports are isolated, moderated and deduplicated", {
  skip: process.env.RUN_DB_TESTS !== "1",
}, async () => {
  const db = new Client({ connectionString: process.env.DATABASE_URL, ssl: process.env.DB_SSL === "true" ? {
    rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== "false",
  } : false });
  await db.connect();
  try {
    await db.query("SET search_path=pg_temp");
    await db.query("CREATE TEMP TABLE users(id UUID PRIMARY KEY,name TEXT,city TEXT,country TEXT,latitude DOUBLE PRECISION,longitude DOUBLE PRECISION,birth_date DATE); CREATE TEMP TABLE user_contacts(owner_id UUID,contact_id UUID); CREATE TEMP TABLE blocked_users(blocker_id UUID,blocked_id UUID)");
    await db.query(SCHEMA.replaceAll("CREATE TABLE IF NOT EXISTS", "CREATE TEMP TABLE IF NOT EXISTS"));
    const alice = "45000000-0000-4000-8000-000000000001", bob = "45000000-0000-4000-8000-000000000002";
    await db.query("INSERT INTO users(id,name,birth_date) VALUES($1,'Alice','1990-01-01'),($2,'Bob','1990-01-01')", [alice, bob]);
    const handlers = new Map(), app = {};
    for (const method of ["get", "post", "put", "delete"]) app[method] = (path, _auth, handler) => handlers.set(`${method} ${path}`, handler);
    let moderated = 0, pushes = 0;
    registerCalendar(app, { auth() {}, importSecret: "test-secret", sendPush: async () => pushes++,
      getPool: async () => ({ query: db.query.bind(db), connect: async () => ({ query: db.query.bind(db), release() {} }) }),
      validateShared: async (text) => { moderated++; if (text.includes("blocked")) throw Object.assign(new Error("blocked"), { status: 422 }); } });
    const call = async (path, body, owner = alice) => {
      let status = 200, result;
      await handlers.get(`post /api/calendar/${path}`)({ body, user: { id: owner } }, {
        set() {}, status(value) { status = value; return this; }, json(value) { result = value; },
      });
      return { status, body: result };
    };
    const preview = await call("import/preview", { ics: calendar(event("RRULE:FREQ=WEEKLY;COUNT=2")), timezone: "Asia/Jerusalem" });
    assert.equal(preview.status, 200);
    assert.equal((await db.query("SELECT COUNT(*)::int n FROM calendar_events")).rows[0].n, 0);
    const entry = preview.body.drafts[0];
    const payload = { ...entry.draft, import_key: entry.import_key };
    const saved = await call("events", payload);
    assert.equal(saved.status, 201);
    assert.equal(saved.body.ids.length, 2);
    assert.equal(moderated, 1);
    const again = await call("events", payload);
    assert.equal(again.status, 200);
    assert.equal(again.body.already_imported, true);
    assert.deepEqual(again.body.ids, saved.body.ids);
    for (const edit of [{ title: "עריכה חדשה בייבוא" }, { start: "2026-10-20T09:30", end: "2026-10-20T10:30" },
      { count: 3 }, { reminder_minutes: 30 }]) {
      const editedReplay = await call("events", { ...payload, ...edit });
      assert.equal(editedReplay.status, 409);
      assert.match(editedReplay.body.error, /השינויים מהייבוא לא נשמרו/);
    }
    assert.equal((await db.query("SELECT title FROM calendar_events WHERE id=$1", [saved.body.ids[0]])).rows[0].title, "פגישה");
    await db.query("UPDATE calendar_events SET notes='שינוי אישי ביומן' WHERE id=$1", [saved.body.ids[0]]);
    assert.equal((await call("events", payload)).status, 409);
    assert.equal((await db.query("SELECT notes FROM calendar_events WHERE id=$1", [saved.body.ids[0]])).rows[0].notes, "שינוי אישי ביומן");
    await db.query("UPDATE calendar_events SET notes='' WHERE id=$1", [saved.body.ids[0]]);
    assert.equal((await call("events", payload)).body.already_imported, true);
    assert.equal((await db.query("SELECT COUNT(*)::int n FROM calendar_events")).rows[0].n, 2);
    assert.equal((await db.query("SELECT COUNT(*)::int n FROM calendar_attendees")).rows[0].n, 0);
    assert.equal((await db.query("SELECT COUNT(*)::int n FROM calendar_notices")).rows[0].n, 0);
    assert.equal(pushes, 0);
    assert.equal((await call("events", payload, bob)).status, 403);
    const bobPreview = await call("import/preview", { ics: calendar(event("RRULE:FREQ=WEEKLY;COUNT=2")), timezone: "Asia/Jerusalem" }, bob);
    assert.equal((await call("events", { ...bobPreview.body.drafts[0].draft, import_key: bobPreview.body.drafts[0].import_key }, bob)).status, 201);
    const changed = await call("import/preview", { ics: calendar(event("DESCRIPTION:updated")), timezone: "Asia/Jerusalem" });
    assert.equal((await call("events", { ...changed.body.drafts[0].draft, import_key: changed.body.drafts[0].import_key })).status, 409);
    const unsafe = await call("import/preview", { ics: calendar(event("DESCRIPTION:blocked").replace("shared-event", "unsafe-event")), timezone: "Asia/Jerusalem" });
    assert.equal((await call("events", { ...unsafe.body.drafts[0].draft, import_key: unsafe.body.drafts[0].import_key })).status, 422);
    const one = await call("import/preview", { ics: calendar(event("RRULE:FREQ=YEARLY").replace("shared-event", "yearly-event")), timezone: "Asia/Jerusalem" });
    const single = { ...one.body.drafts[0].draft, import_key: one.body.drafts[0].import_key };
    assert.equal((await call("events", single)).status, 400);
    assert.equal((await call("events", { ...single, import_single_occurrence: true })).status, 201);
    assert.equal((await db.query("SELECT COUNT(*)::int n FROM calendar_events")).rows[0].n, 5);
    assert.equal((await db.query("SELECT COUNT(*)::int n FROM calendar_event_imports")).rows[0].n, 3);
  } finally { await db.end(); }
});
