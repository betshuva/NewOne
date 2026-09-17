"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { Client } = require("pg");
const { SCHEMA, registerCalendar } = require("../server/calendar");

const id = (n) => `34000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const base = {
  title: "מפגש",
  notes: "פרטי האירוע",
  location: "אולם",
  start: "2026-10-20T09:00",
  end: "2026-10-20T10:00",
  timezone: "Asia/Jerusalem",
  all_day: false,
  color: "blue",
  reminder_minutes: 15,
  invitees: [],
};
const emptySummary = {
  total: 0,
  accepted: 0,
  maybe: 0,
  pending: 0,
  declined: 0,
};

test(
  "calendar attendance DB: organizer counts, guest privacy and lifecycle updates",
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
      await db.query(`
        CREATE TEMP TABLE users(id UUID PRIMARY KEY,name TEXT,city TEXT,country TEXT,
          latitude DOUBLE PRECISION,longitude DOUBLE PRECISION,birth_date DATE);
        CREATE TEMP TABLE user_contacts(owner_id UUID,contact_id UUID);
        CREATE TEMP TABLE blocked_users(blocker_id UUID,blocked_id UUID);
      `);
      await db.query(
        SCHEMA.replaceAll(
          "CREATE TABLE IF NOT EXISTS",
          "CREATE TEMP TABLE IF NOT EXISTS",
        ),
      );
      for (let n = 1; n <= 6; n++) {
        await db.query(
          "INSERT INTO users(id,name,birth_date) VALUES($1,$2,DATE '1990-01-01')",
          [id(n), `person${n}`],
        );
        if (n > 1)
          await db.query("INSERT INTO user_contacts VALUES($1,$2)", [id(1), id(n)]);
      }
      let queries = [];
      const query = (sql, values) => {
        queries.push(sql);
        return db.query(sql, values);
      };
      const pool = {
        query,
        connect: async () => ({ query, release() {} }),
      };
      const handlers = new Map();
      const app = {};
      for (const method of ["get", "post", "put", "delete"])
        app[method] = (path, _auth, handler) =>
          handlers.set(`${method} ${path}`, handler);
      registerCalendar(app, { auth() {}, getPool: async () => pool });
      const req = async (method, path, user, { body = {}, params = {}, query = {} } = {}) => {
        let status = 200;
        let result;
        await handlers.get(`${method} /api/calendar/${path}`)(
          { user: { id: id(user) }, body, params, query },
          {
            set() { return this; },
            status(value) { status = value; return this; },
            json(value) { result = JSON.parse(JSON.stringify(value)); },
          },
        );
        return { status, body: result };
      };
      const create = async (patch = {}) => {
        const result = await req("post", "events", 1, { body: { ...base, ...patch } });
        assert.equal(result.status, 201);
        return result.body.ids;
      };
      const list = async (user) => {
        const result = await req("get", "events", user, {
          query: { start: "2026-10-01", end: "2026-11-01" },
        });
        assert.equal(result.status, 200);
        return result.body.events;
      };
      const respond = async (eventId, user, response, version = 1) => {
        const result = await req("post", "events/:id/respond", user, {
          params: { id: eventId }, body: { response, version },
        });
        assert.equal(result.status, 200);
      };
      const [personalId] = await create();
      const [eventId] = await create({ invitees: [id(2), id(3), id(4), id(5)] });
      await respond(eventId, 2, "accepted");
      await respond(eventId, 3, "maybe");
      await respond(eventId, 5, "declined");
      // Historical rows must neither count the owner nor hide organizer controls.
      await db.query(
        "INSERT INTO calendar_attendees(event_id,user_id,response) VALUES($1,$2,'accepted')",
        [eventId, id(1)],
      );

      queries = [];
      const owned = await list(1);
      assert.equal(
        queries.filter((sql) => sql.includes("GROUP BY event_id")).length,
        1,
        "load all owned-event counts in one aggregate query",
      );
      assert.deepEqual(owned.find((e) => e.id === personalId).attendee_summary, emptySummary);
      const mixed = owned.find((e) => e.id === eventId);
      assert.equal(mixed.response, null);
      assert.deepEqual(mixed.attendee_summary, {
        total: 4, accepted: 1, maybe: 1, pending: 1, declined: 1,
      });
      const guests = await req("get", "events/:id/attendees", 1, {
        params: { id: eventId },
      });
      assert.equal(guests.status, 200);
      assert.deepEqual(guests.body.map((a) => a.user_id), [id(2), id(3), id(4), id(5)]);

      for (const user of [2, 3, 4, 5, 6]) {
        queries = [];
        const visible = await list(user);
        assert.equal(queries.filter((sql) => sql.includes("GROUP BY event_id")).length, 0);
        assert.equal(visible.length, user === 2 || user === 3 ? 1 : 0);
        for (const event of visible) {
          assert.equal(Object.hasOwn(event, "attendee_summary"), false);
          assert.equal(Object.hasOwn(event, "attendees"), false);
          assert.equal(event.response, user === 2 ? "accepted" : "maybe");
        }
        const denied = await req("get", "events/:id/attendees", user, {
          params: { id: eventId },
        });
        assert.equal(denied.status, 404);
        assert.equal(Object.hasOwn(denied.body, "attendee_summary"), false);
      }

      // Non-time edits preserve responses, and removing an invitee changes the denominator.
      const edit = await req("put", "events/:id", 1, {
        params: { id: eventId },
        body: { ...base, title: "מפגש מעודכן", version: 1, invitees: [id(2), id(3), id(4)] },
      });
      assert.equal(edit.status, 200);
      assert.deepEqual((await list(1)).find((e) => e.id === eventId).attendee_summary, {
        total: 3, accepted: 1, maybe: 1, pending: 1, declined: 0,
      });
      const rescheduled = {
        ...base, start: "2026-10-20T11:00", end: "2026-10-20T12:00",
        invitees: [id(2), id(3), id(4)],
      };
      const move = await req("put", "events/:id", 1, {
        params: { id: eventId }, body: { ...rescheduled, version: 2 },
      });
      assert.equal(move.status, 200);
      assert.deepEqual((await list(1)).find((e) => e.id === eventId).attendee_summary, {
        total: 3, accepted: 0, maybe: 0, pending: 3, declined: 0,
      });
      assert.equal((await list(2)).length, 0);
      await respond(eventId, 2, "accepted", 3);
      assert.equal((await list(1)).find((e) => e.id === eventId).attendee_summary.accepted, 1);
      assert.equal((await list(2)).length, 1);
      const removeAll = await req("put", "events/:id", 1, {
        params: { id: eventId }, body: { ...rescheduled, invitees: [], version: 3 },
      });
      assert.equal(removeAll.status, 200);
      assert.deepEqual((await list(1)).find((e) => e.id === eventId).attendee_summary, emptySummary);
      assert.equal((await list(2)).length, 0);

      const recurringIds = await create({ invitees: [id(2)], repeat: "daily", count: 2 });
      await respond(recurringIds[0], 2, "accepted");
      const recurring = await list(1);
      assert.deepEqual(recurring.find((e) => e.id === recurringIds[0]).attendee_summary, {
        ...emptySummary, total: 1, accepted: 1,
      });
      assert.deepEqual(recurring.find((e) => e.id === recurringIds[1]).attendee_summary, {
        ...emptySummary, total: 1, pending: 1,
      });
      const cancel = await req("delete", "events/:id", 1, {
        params: { id: recurringIds[0] }, body: { version: 1 },
      });
      assert.equal(cancel.status, 200);
      assert.equal((await list(1)).some((e) => e.id === recurringIds[0]), false);
      assert.equal((await list(2)).some((e) => e.id === recurringIds[0]), false);
      assert.equal((await list(1)).some((e) => e.id === recurringIds[1]), true);
    } finally {
      await db.end();
    }
  },
);
