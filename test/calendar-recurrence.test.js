"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { Client } = require("pg");
const { DateTime } = require("luxon");
const { SCHEMA, validateEvent, occurrences, registerCalendar, runReminders } = require("../server/calendar");

const id = (n) => `35000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const base = {
  title: "מפגש חוזר", notes: "הערות", location: "ירושלים",
  start: "2026-10-20T09:00", end: "2026-10-20T10:00",
  timezone: "Asia/Jerusalem", all_day: false, color: "blue",
  reminder_minutes: 15, invitees: [],
};
const expand = (patch) => occurrences(validateEvent({ ...base, ...patch }));
const wall = (value) => DateTime.fromISO(value, { zone: base.timezone }).toFormat("yyyy-MM-dd'T'HH:mm");

test("daily intervals retain local time across DST and until includes the final date", () => {
  const rows = expand({ repeat: "daily", interval: 3, end_type: "until", until: "2026-10-29" });
  assert.deepEqual(rows.map((r) => wall(r.start)), [
    "2026-10-20T09:00", "2026-10-23T09:00", "2026-10-26T09:00", "2026-10-29T09:00",
  ]);
  assert.equal(rows[0].start, "2026-10-20T06:00:00.000Z");
  assert.equal(rows[2].start, "2026-10-26T07:00:00.000Z");
  assert.equal(expand({ repeat: "daily", interval: 7, count: 3 }).length, 3);
});

test("weekly selected weekdays start on or after the chosen date with no duplicates", () => {
  const rows = expand({ repeat: "weekly", weekdays: [7, 2, 4, 2], count: 6 });
  assert.deepEqual(rows.map((r) => wall(r.start)), [
    "2026-10-20T09:00", "2026-10-22T09:00", "2026-10-25T09:00",
    "2026-10-27T09:00", "2026-10-29T09:00", "2026-11-01T09:00",
  ]);
  assert.deepEqual(expand({ repeat: "weekly", weekdays: [7], count: 2 }).map((r) => wall(r.start)), [
    "2026-10-25T09:00", "2026-11-01T09:00",
  ]);
  assert.equal(expand({ repeat: "weekly", weekdays: [2, 4], end_type: "until", until: "2026-10-22" }).length, 2);
  assert.equal(expand({ repeat: "weekly", count: 2 })[1].start, "2026-10-27T07:00:00.000Z");
});

test("monthly short-month dates recover the original date and preserve overnight/all-day durations", () => {
  const rows = expand({ repeat: "monthly", count: 3, start: "2027-01-31T22:00", end: "2027-02-01T01:00" });
  assert.deepEqual(rows.map((r) => wall(r.start)), [
    "2027-01-31T22:00", "2027-02-28T22:00", "2027-03-31T22:00",
  ]);
  assert.deepEqual(rows.map((r) => wall(r.end)), [
    "2027-02-01T01:00", "2027-03-01T01:00", "2027-04-01T01:00",
  ]);
  const allDay = expand({ repeat: "monthly", count: 2, all_day: true, start: "2027-01-31T00:00", end: "2027-02-02T00:00" });
  assert.equal(wall(allDay[1].end), "2027-03-02T00:00");
});

test("recurrence rejects invalid rules, empty ranges and excessive series instead of truncating", () => {
  for (const patch of [
    { repeat: "daily", interval: 0, count: 2 },
    { repeat: "daily", interval: 8, count: 2 },
    { repeat: "daily", interval: "2", count: 2 },
    { repeat: "weekly", weekdays: [], count: 2 },
    { repeat: "weekly", weekdays: [0], count: 2 },
    { repeat: "weekly", weekdays: [8], count: 2 },
    { repeat: "weekly", weekdays: ["2"], count: 2 },
    { repeat: "daily", end_type: "forever", count: 2 },
    { repeat: "daily", end_type: "until", until: "2026-02-30" },
    { repeat: "daily", end_type: "until", until: "2026-10-19" },
    { repeat: "weekly", weekdays: [7], end_type: "until", until: "2026-10-21" },
    { repeat: "daily", end_type: "until", until: "2027-10-20" },
    { repeat: "daily", count: 105 },
  ]) assert.throws(() => expand(patch), { status: 400 }, JSON.stringify(patch));
  assert.equal(expand({ repeat: "daily", count: 104 }).length, 104);
});

test("generated occurrences reject nonexistent and ambiguous start or end times", () => {
  for (const patch of [
    { start: "2026-03-26T02:30", end: "2026-03-26T03:30", repeat: "daily", count: 2 },
    { start: "2026-10-24T00:30", end: "2026-10-24T01:30", repeat: "daily", count: 2 },
  ]) assert.throws(() => expand(patch), { status: 400 });
});

test("reminder migration preserves legacy claims and is safe to run again", {
  skip: process.env.RUN_DB_TESTS !== "1",
}, async () => {
  const db = new Client({ connectionString: process.env.DATABASE_URL, ssl: process.env.DB_SSL === "true" ? {
    rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== "false",
  } : false });
  await db.connect();
  try {
    await db.query("SET search_path=pg_temp");
    await db.query("CREATE TEMP TABLE users(id UUID PRIMARY KEY)");
    const schema = SCHEMA.replaceAll("CREATE TABLE IF NOT EXISTS", "CREATE TEMP TABLE IF NOT EXISTS");
    await db.query(schema);
    await db.query("INSERT INTO users VALUES($1)", [id(1)]);
    await db.query("INSERT INTO calendar_events(id,owner_id,title,starts_at,ends_at,timezone,version) VALUES($1,$2,'legacy',now(),now()+interval '1 hour','Asia/Jerusalem',5)", [id(10), id(1)]);
    await db.query("INSERT INTO calendar_reminders VALUES($1,$2,5)", [id(10), id(1)]);
    await db.query("ALTER TABLE calendar_events DROP COLUMN reminder_version");
    await db.query(schema);
    assert.equal((await db.query("SELECT reminder_version FROM calendar_events")).rows[0].reminder_version, 5);
    await db.query("UPDATE calendar_events SET version=6");
    await db.query(schema);
    assert.equal((await db.query("SELECT reminder_version FROM calendar_events")).rows[0].reminder_version, 5);
    assert.equal((await db.query("SELECT version FROM calendar_reminders")).rows[0].version, 5);
  } finally {
    await db.end();
  }
});

test("calendar recurrence DB: bulk edits isolate series, preserve responses, reset changed times and roll back invalid changes", {
  skip: process.env.RUN_DB_TESTS !== "1",
}, async () => {
  const db = new Client({ connectionString: process.env.DATABASE_URL, ssl: process.env.DB_SSL === "true" ? {
    rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== "false",
  } : false });
  await db.connect();
  try {
    await db.query("SET search_path=pg_temp");
    await db.query(`
      CREATE TEMP TABLE users(id UUID PRIMARY KEY,name TEXT,city TEXT,country TEXT,latitude DOUBLE PRECISION,longitude DOUBLE PRECISION,birth_date DATE);
      CREATE TEMP TABLE user_contacts(owner_id UUID,contact_id UUID);
      CREATE TEMP TABLE blocked_users(blocker_id UUID,blocked_id UUID);
    `);
    await db.query(SCHEMA.replaceAll("CREATE TABLE IF NOT EXISTS", "CREATE TEMP TABLE IF NOT EXISTS"));
    for (let n = 1; n <= 4; n++) await db.query("INSERT INTO users(id,name,birth_date) VALUES($1,$2,DATE '1990-01-01')", [id(n), `person${n}`]);
    await db.query("INSERT INTO user_contacts VALUES($1,$2),($1,$3)", [id(1), id(2), id(3)]);
    const pool = { query: db.query.bind(db), connect: async () => ({ query: db.query.bind(db), release() {} }) };
    const app = {}, handlers = new Map();
    for (const method of ["get", "post", "put", "delete"]) app[method] = (path, _auth, handler) => handlers.set(`${method} ${path}`, handler);
    registerCalendar(app, { auth() {}, getPool: async () => pool });
    const req = async (method, path, body, eventId, user = 1, query = {}) => {
      let status = 200, result;
      await handlers.get(`${method} /api/calendar/${path}`)({ user: { id: id(user) }, body, params: { id: eventId }, query }, {
        set() { return this; }, status(s) { status = s; return this; }, json(value) { result = value; },
      });
      return { status, body: result };
    };
    const create = async (patch = {}) => {
      const result = await req("post", "events", { ...base, ...patch });
      assert.equal(result.status, 201, JSON.stringify(result.body));
      return result.body.ids;
    };
    const rows = async (ids) => (await db.query("SELECT *,to_char(starts_at AT TIME ZONE timezone,'YYYY-MM-DD\"T\"HH24:MI') AS wall_start,to_char(ends_at AT TIME ZONE timezone,'YYYY-MM-DD\"T\"HH24:MI') AS wall_end FROM calendar_events WHERE id=ANY($1::uuid[]) ORDER BY starts_at", [ids])).rows;
    const responses = async (ids) => (await db.query("SELECT user_id,response FROM calendar_attendees WHERE event_id=ANY($1::uuid[]) ORDER BY user_id", [ids])).rows;
    const snapshot = async (eventId) => {
      const event = (await rows([eventId]))[0];
      const date = DateTime.fromJSDate(event.starts_at, { zone: base.timezone }).startOf("day");
      const result = await req("get", "events", {}, null, 1, { start: date.toISODate(), end: date.plus({ days: 1 }).toISODate() });
      assert.equal(result.status, 200, JSON.stringify(result.body));
      return result.body.events.find((e) => e.id === eventId);
    };
    const editSeries = async (eventId, body, user = 1) => req("put", "events/:id", {
      ...body, series_revision: (await snapshot(eventId)).series_revision,
    }, eventId, user);
    const ids = await create({ repeat: "weekly", weekdays: [2], count: 4, invitees: [id(2)] });
    assert.equal(new Set((await rows(ids)).map((r) => r.series_id)).size, 1);
    assert.ok((await rows(ids))[0].series_id);
    const unrelated = await create({ repeat: "daily", count: 2 });
    for (const eventId of ids) assert.equal((await req("post", "events/:id/respond", { response: "accepted", version: 1 }, eventId, 2)).status, 200);
    assert.equal((await req("delete", "events/:id", { version: 1 }, ids[3])).status, 200);
    await db.query("DELETE FROM calendar_notices");

    const second = { ...base, start: "2026-10-27T09:00", end: "2026-10-27T10:00", invitees: [id(2)] };
    const edit = { ...second, title: "עודכן לכל הסדרה", scope: "series", version: 1 };
    assert.equal((await req("put", "events/:id", edit, ids[1], 2)).status, 404);
    assert.equal((await req("put", "events/:id", edit, ids[1])).status, 409, "series edits require a complete series snapshot");
    assert.equal((await editSeries(ids[1], edit)).status, 200);
    let events = await rows(ids);
    assert.ok(events.slice(0, 3).every((r) => r.title === edit.title && r.version === 2));
    assert.equal(events[3].title, base.title, "cancelled occurrences remain unchanged");
    assert.equal(events[3].cancelled, true);
    assert.ok((await rows(unrelated)).every((r) => r.title === base.title && r.version === 1));
    assert.ok((await responses(ids.slice(0, 3))).every((r) => r.response === "accepted"));
    assert.equal((await db.query("SELECT * FROM calendar_notices WHERE user_id=$1", [id(2)])).rowCount, 1, "one update notice per recipient, not per occurrence");
    assert.equal((await req("put", "events/:id", edit, ids[1])).status, 409, "stale series edit is rejected");

    const single = { ...second, notes: "מופע נבחר בלבד", scope: "single", version: 2 };
    assert.equal((await req("put", "events/:id", single, ids[1])).status, 200);
    events = await rows(ids);
    assert.equal(events[0].notes, base.notes);
    assert.equal(events[1].notes, single.notes);
    assert.equal(events[2].notes, base.notes);
    const shifted = { ...second, title: "הוזז", start: "2026-10-28T10:00", end: "2026-10-28T11:30", invitees: [id(2), id(3)], scope: "series", version: 3 };
    assert.equal((await editSeries(ids[1], shifted)).status, 200);
    events = await rows(ids);
    assert.deepEqual(events.slice(0, 3).map((r) => r.wall_start), ["2026-10-21T10:00", "2026-10-28T10:00", "2026-11-04T10:00"]);
    assert.deepEqual(events.slice(0, 3).map((r) => r.wall_end), ["2026-10-21T11:30", "2026-10-28T11:30", "2026-11-04T11:30"]);
    assert.equal(events[0].starts_at.toISOString(), "2026-10-21T07:00:00.000Z");
    assert.equal(events[1].starts_at.toISOString(), "2026-10-28T08:00:00.000Z");
    assert.equal((await responses(ids.slice(0, 3))).length, 6);
    assert.ok((await responses(ids.slice(0, 3))).every((r) => r.response === "pending"));
    const beforeInvalid = await rows(ids);
    assert.equal((await editSeries(ids[1], { ...shifted, version: 4, invitees: [id(4)] })).status, 403);
    assert.deepEqual(await rows(ids), beforeInvalid);

    const spring = await create({ start: "2026-03-19T02:30", end: "2026-03-19T03:30", repeat: "weekly", count: 2 });
    const springBefore = await rows(spring);
    const invalid = await editSeries(spring[0], { ...base, start: "2026-03-20T02:30", end: "2026-03-20T03:30", scope: "series", version: 1 });
    assert.equal(invalid.status, 400, "a later occurrence in the DST gap rejects the entire update");
    assert.deepEqual(await rows(spring), springBefore);
    const one = await create();
    assert.equal((await req("put", "events/:id", { ...base, scope: "series", version: 1 }, one[0])).status, 400);

    const until = await create({ repeat: "daily", interval: 2, end_type: "until", until: "2026-10-24" });
    assert.equal(until.length, 3);
    assert.ok((await rows(until)).every((r) => r.series_id));

    // A peer outside the selected day's loaded range is still part of the revision.
    const custom = await create({ repeat: "weekly", count: 2, invitees: [id(2)] });
    const stale = await snapshot(custom[0]);
    assert.equal(typeof stale.series_revision, "string");
    assert.equal((await req("put", "events/:id", { ...second, end: "2026-10-27T11:00", version: 1 }, custom[1])).status, 200);
    const renameAll = { ...base, title: "שם חדש", invitees: [id(2)], scope: "series", version: 1 };
    assert.equal((await req("put", "events/:id", { ...renameAll, series_revision: stale.series_revision }, custom[0])).status, 409, "stale peer change cannot be overwritten");
    assert.equal((await req("post", "events/:id/respond", { response: "accepted", version: 2 }, custom[1], 2)).status, 200);
    assert.equal((await editSeries(custom[0], renameAll)).status, 200);
    const customized = await rows(custom);
    assert.deepEqual(customized.map((e) => e.wall_end), ["2026-10-20T10:00", "2026-10-27T11:00"], "a title-only series edit preserves per-occurrence customized durations");
    assert.equal((await responses([custom[1]]))[0].response, "accepted");

    const nearNow = DateTime.now().setZone(base.timezone).startOf("minute").plus({ minutes: 2 });
    const reminderBody = { ...base, title: "תזכורת אחת", start: nearNow.toFormat("yyyy-MM-dd'T'HH:mm"), end: nearNow.plus({ hours: 1 }).toFormat("yyyy-MM-dd'T'HH:mm"), reminder_minutes: 15 };
    const reminders = await create(reminderBody);
    const pushes = [];
    await runReminders(async () => pool, async (uid, _title, message) => pushes.push({ uid, message }));
    assert.equal(pushes.filter((p) => p.message.includes("תזכורת אחת")).length, 1);
    assert.equal((await req("put", "events/:id", { ...reminderBody, notes: "עוד פרטים", version: 1 }, reminders[0])).status, 200);
    await runReminders(async () => pool, async (uid, _title, message) => pushes.push({ uid, message }));
    assert.equal(pushes.filter((p) => p.message.includes("תזכורת אחת")).length, 1, "metadata edit does not resend a claimed reminder");
  } finally {
    await db.end();
  }
});
