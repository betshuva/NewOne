"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { Client } = require("pg");
const {
  SCHEMA,
  CITIES,
  validateEvent,
  validateSettings,
  occurrences,
  holidays,
  registerCalendar,
  runReminders,
} = require("../server/calendar");
const id = (n) => `33000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const base = {
  title: "פגישה",
  notes: "פרטי האירוע",
  location: "משרד",
  start: "2026-10-20T09:00",
  end: "2026-10-20T10:00",
  timezone: "Asia/Jerusalem",
  all_day: false,
  color: "blue",
  reminder_minutes: 15,
  invitees: [],
};
test("calendar validates dates, DST gaps, ambiguous times and request limits", () => {
  assert.equal(validateEvent(base).title, "פגישה");
  for (const patch of [
    { start: "2026-02-30T09:00" },
    { end: base.start },
    { title: "" },
    { timezone: "bad/zone" },
    { invitees: ["invalid"] },
    { repeat: "weekly", count: 105 },
    { reminder_minutes: -1 },
    { start: "2026-03-27T02:30" },
    { start: "2026-10-25T01:30" },
    { all_day: true },
  ])
    assert.throws(() => validateEvent({ ...base, ...patch }));
  assert.throws(() => validateSettings({ ...CITIES[0], latitude: NaN }));
  assert.throws(() => validateSettings({ ...CITIES[0], israel: "yes" }));
});
test("weekly events preserve local hour across Israel DST and monthly dates stay valid", () => {
  const e = occurrences(validateEvent({ ...base, repeat: "weekly", count: 2 }));
  assert.equal(e[0].start, "2026-10-20T06:00:00.000Z");
  assert.equal(e[1].start, "2026-10-27T07:00:00.000Z");
  const monthly = occurrences(
    validateEvent({
      ...base,
      start: "2027-01-31T09:00",
      end: "2027-01-31T10:00",
      repeat: "monthly",
      count: 3,
    }),
  );
  assert.ok(monthly[1].start.startsWith("2027-02-28"));
  assert.ok(monthly[2].start.startsWith("2027-03-31"));
});
test("holiday provider requests both exit methods without replacing candle lighting", async () => {
  const requests = [];
  const fetcher = async (url) => {
    const p = new URL(url).searchParams;
    requests.push(p);
    return {
      ok: true,
      json: async () => ({
        items:
          p.get("m") === "72"
            ? [
                {
                  date: "2040-05-05T20:42:00+03:00",
                  category: "havdalah",
                  hebrew: "הבדלה",
                },
                {
                  date: "2040-05-04T19:00:00+03:00",
                  category: "candles",
                  hebrew: "לא להשתמש",
                },
              ]
            : [
                {
                  date: "2040-05-04T18:30:00+03:00",
                  category: "candles",
                  hebrew: "הדלקת נרות",
                },
                {
                  date: "2040-05-05T20:10:00+03:00",
                  category: "havdalah",
                  hebrew: "הבדלה",
                },
              ],
      }),
    };
  };
  const rows = await holidays(CITIES[0], "2040-05-01", "2040-05-10", fetcher);
  assert.equal(rows.length, 4);
  assert.equal(rows.filter((r) => r.category === "candles").length, 1);
  assert.ok(rows.some((r) => r.category === "rabbeinu_tam"));
  assert.equal(requests[0].get("tzid"), "Asia/Jerusalem");
  assert.equal(requests[0].get("b"), "40");
  assert.equal(requests[1].get("M"), null);
});

test(
  "calendar DB: privacy, invitations, conflict protection, cancellation, reminders and cascades",
  { skip: process.env.RUN_DB_TESTS !== "1" },
  async () => {
    const db = new Client({
      connectionString: process.env.DATABASE_URL,
      ssl:
        process.env.DB_SSL === "true"
          ? {
              rejectUnauthorized:
                process.env.DB_REJECT_UNAUTHORIZED !== "false",
            }
          : false,
    });
    await db.connect();
    try {
      await db.query("SET search_path=pg_temp");
      await db.query(
        `CREATE TEMP TABLE users(id UUID PRIMARY KEY,name TEXT);CREATE TEMP TABLE user_contacts(owner_id UUID,contact_id UUID);CREATE TEMP TABLE blocked_users(blocker_id UUID,blocked_id UUID);`,
      );
      // Every relation lives only on this connection, never in the application's schema.
      await db.query(
        SCHEMA.replaceAll(
          "CREATE TABLE IF NOT EXISTS",
          "CREATE TEMP TABLE IF NOT EXISTS",
        ),
      );
      for (let n = 1; n <= 4; n++)
        await db.query("INSERT INTO users VALUES($1,$2)", [
          id(n),
          `person${n}`,
        ]);
      await db.query("INSERT INTO user_contacts VALUES($1,$2),($1,$3)", [
        id(1),
        id(2),
        id(4),
      ]);
      const pool = {
        query: db.query.bind(db),
        connect: async () => ({ query: db.query.bind(db), release() {} }),
      };
      const handlers = new Map(),
        app = {};
      for (const method of ["get", "post", "put", "delete"])
        app[method] = (path, auth, handler) =>
          handlers.set(`${method} ${path}`, handler);
      registerCalendar(app, {
        auth() {},
        getPool: async () => pool,
        canInvite: async (_db, _uid, target) => target !== id(4),
      });
      const req = async (
        method,
        path,
        user = 1,
        body = {},
        params = {},
        query = {},
      ) => {
        let status = 200,
          result;
        await handlers.get(`${method} /api/calendar/${path}`)(
          { user: { id: id(user) }, body, params, query },
          {
            set() {
              return this;
            },
            status(s) {
              status = s;
              return this;
            },
            json(x) {
              result = JSON.parse(JSON.stringify(x));
            },
          },
        );
        return { status, body: result };
      };
      assert.equal(
        (await req("post", "events", 1, { ...base, invitees: [id(3)] })).status,
        403,
      );
      assert.equal(
        (await req("post", "events", 1, { ...base, invitees: [id(4)] })).status,
        403,
      );
      const create = await req("post", "events", 1, {
        ...base,
        invitees: [id(2)],
      });
      assert.equal(create.status, 201);
      const eventId = create.body.ids[0];
      const range = { start: "2026-10-01", end: "2026-11-01" };
      const list = async (u) =>
        (await req("get", "events", u, {}, {}, range)).body.events;
      assert.equal((await list(1)).length, 1);
      assert.equal((await list(2)).length, 0);
      assert.equal((await list(3)).length, 0);
      assert.equal(
        (await req("get", "events/:id/attendees", 3, {}, { id: eventId }))
          .status,
        404,
      );
      assert.equal(
        (
          await req(
            "post",
            "events/:id/respond",
            3,
            { response: "accepted", version: 1 },
            { id: eventId },
          )
        ).status,
        404,
      );
      assert.equal(
        (
          await req(
            "put",
            "events/:id",
            2,
            { ...base, version: 1 },
            { id: eventId },
          )
        ).status,
        404,
      );
      assert.equal(
        (
          await req(
            "post",
            "events/:id/respond",
            2,
            { response: "accepted", version: 1 },
            { id: eventId },
          )
        ).status,
        200,
      );
      assert.equal((await list(2)).length, 1);
      assert.equal(
        (
          await req(
            "put",
            "events/:id",
            1,
            {
              ...base,
              invitees: [id(2)],
              start: "2026-10-20T11:00",
              end: "2026-10-20T12:00",
              version: 1,
            },
            { id: eventId },
          )
        ).status,
        200,
      );
      assert.equal(
        (await list(2)).length,
        0,
        "time changes require RSVP again",
      );
      assert.equal(
        (
          await req(
            "post",
            "events/:id/respond",
            2,
            { response: "accepted", version: 1 },
            { id: eventId },
          )
        ).status,
        409,
      );
      assert.equal(
        (
          await req(
            "post",
            "events/:id/respond",
            2,
            { response: "accepted", version: 2 },
            { id: eventId },
          )
        ).status,
        200,
      );
      assert.equal(
        (await req("delete", "events/:id", 1, { version: 1 }, { id: eventId }))
          .status,
        409,
      );
      assert.equal(
        (await req("delete", "events/:id", 1, { version: 2 }, { id: eventId }))
          .status,
        200,
      );
      assert.equal((await list(1)).length, 0);
      assert.equal((await list(2)).length, 0);
      assert.ok(
        (await req("get", "inbox", 2)).body.notices.some((n) =>
          n.message.includes("בוטל"),
        ),
      );
      // A zero-minute reminder fires just after the start; pending guests receive none.
      const reminderId = (
        await req("post", "events", 1, { ...base, invitees: [id(2)] })
      ).body.ids[0];
      await db.query(
        "UPDATE calendar_events SET starts_at=now()-interval '10 seconds',ends_at=now()+interval '1 hour',reminder_minutes=0 WHERE id=$1",
        [reminderId],
      );
      const pushes = [];
      await runReminders(
        async () => pool,
        async (uid) => pushes.push(uid),
      );
      await runReminders(
        async () => pool,
        async (uid) => pushes.push(uid),
      );
      assert.deepEqual(pushes, [id(1)]);
      // All-day dates must not shift or disappear for participants across the date line.
      const allDay = await req("post", "events", 1, {
        ...base,
        title: "יום שלם",
        timezone: "Pacific/Kiritimati",
        all_day: true,
        start: "2026-12-20T00:00",
        end: "2026-12-21T00:00",
        reminder_minutes: null,
      });
      assert.equal(allDay.status, 201);
      await req("put", "settings", 1, {
        ...CITIES[0],
        city: "Pago Pago",
        timezone: "Pacific/Pago_Pago",
        israel: false,
        latitude: -14.27,
        longitude: -170.7,
      });
      const civilDay = await req(
        "get",
        "events",
        1,
        {},
        {},
        { start: "2026-12-20", end: "2026-12-21" },
      );
      assert.equal(civilDay.body.events.length, 1);
      assert.equal(civilDay.body.events[0].start_local, "2026-12-20T00:00");
      await db.query("DELETE FROM users WHERE id=$1", [id(1)]);
      assert.equal(
        (await db.query("SELECT * FROM calendar_events")).rowCount,
        0,
      );
      assert.equal(
        (await db.query("SELECT * FROM calendar_attendees")).rowCount,
        0,
      );
    } finally {
      await db.end();
    }
  },
);
