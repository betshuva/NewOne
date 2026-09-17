"use strict";
const { DateTime, IANAZone } = require("luxon");
const crypto = require("node:crypto");
const { createLocationResolver, timezoneList } = require("./calendar-location");
const { CANDLE_LIGHTING_MINUTES } = require("./calendar-policy");
const SCHEMA = `
CREATE TABLE IF NOT EXISTS calendar_settings (
 user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
 city TEXT NOT NULL, latitude DOUBLE PRECISION NOT NULL, longitude DOUBLE PRECISION NOT NULL,
 timezone TEXT NOT NULL, israel BOOLEAN NOT NULL, candle_minutes INTEGER NOT NULL DEFAULT ${CANDLE_LIGHTING_MINUTES},
 source TEXT NOT NULL DEFAULT 'saved'
);
ALTER TABLE calendar_settings ADD COLUMN IF NOT EXISTS source TEXT NOT NULL DEFAULT 'saved';
ALTER TABLE calendar_settings ALTER COLUMN candle_minutes SET DEFAULT ${CANDLE_LIGHTING_MINUTES};
CREATE TABLE IF NOT EXISTS calendar_events (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), owner_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 series_id UUID, title TEXT NOT NULL, notes TEXT NOT NULL DEFAULT '', location TEXT NOT NULL DEFAULT '',
 starts_at TIMESTAMPTZ NOT NULL, ends_at TIMESTAMPTZ NOT NULL CHECK(ends_at>starts_at),
 timezone TEXT NOT NULL, all_day BOOLEAN NOT NULL DEFAULT FALSE, color TEXT NOT NULL DEFAULT 'blue',
 reminder_minutes INTEGER, version INTEGER NOT NULL DEFAULT 1, cancelled BOOLEAN NOT NULL DEFAULT FALSE,
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS calendar_events_owner_time ON calendar_events(owner_id,starts_at);
CREATE INDEX IF NOT EXISTS calendar_events_owner_series ON calendar_events(owner_id,series_id) WHERE series_id IS NOT NULL;
ALTER TABLE calendar_events ADD COLUMN IF NOT EXISTS reminder_version INTEGER;
UPDATE calendar_events SET reminder_version=version WHERE reminder_version IS NULL;
ALTER TABLE calendar_events ALTER COLUMN reminder_version SET DEFAULT 1;
ALTER TABLE calendar_events ALTER COLUMN reminder_version SET NOT NULL;
CREATE TABLE IF NOT EXISTS calendar_attendees (
 event_id UUID REFERENCES calendar_events(id) ON DELETE CASCADE,
 user_id UUID REFERENCES users(id) ON DELETE CASCADE,
 response TEXT NOT NULL DEFAULT 'pending' CHECK(response IN ('pending','accepted','maybe','declined')),
 PRIMARY KEY(event_id,user_id)
);
CREATE INDEX IF NOT EXISTS calendar_attendees_user ON calendar_attendees(user_id,event_id);
CREATE TABLE IF NOT EXISTS calendar_notices (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 event_id UUID REFERENCES calendar_events(id) ON DELETE CASCADE, message TEXT NOT NULL,
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(), read_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS calendar_notices_user ON calendar_notices(user_id,created_at DESC);
CREATE TABLE IF NOT EXISTS calendar_reminders (
 event_id UUID REFERENCES calendar_events(id) ON DELETE CASCADE,
 user_id UUID REFERENCES users(id) ON DELETE CASCADE, version INTEGER NOT NULL,
 PRIMARY KEY(event_id,user_id,version)
);`;
const CITIES = [
  ["ירושלים", 31.778, 35.235, "Asia/Jerusalem", true],
  ["תל אביב", 32.0853, 34.7818, "Asia/Jerusalem", true],
  ["חיפה", 32.794, 34.9896, "Asia/Jerusalem", true],
  ["בני ברק", 32.0849, 34.8352, "Asia/Jerusalem", true],
  ["פתח תקווה", 32.0871, 34.8875, "Asia/Jerusalem", true],
  ["אשדוד", 31.8044, 34.6553, "Asia/Jerusalem", true],
  ["באר שבע", 31.252, 34.7915, "Asia/Jerusalem", true],
  ["בית שמש", 31.746, 34.988, "Asia/Jerusalem", true],
  ["נתניה", 32.3215, 34.8532, "Asia/Jerusalem", true],
  ["טבריה", 32.794, 35.531, "Asia/Jerusalem", true],
  ["צפת", 32.965, 35.498, "Asia/Jerusalem", true],
  ["אילת", 29.558, 34.948, "Asia/Jerusalem", true],
  ["לונדון", 51.5074, -0.1278, "Europe/London", false],
  ["ניו יורק", 40.7128, -74.006, "America/New_York", false],
  ["פריז", 48.8566, 2.3522, "Europe/Paris", false],
].map(([city, latitude, longitude, timezone, israel]) => ({
  city,
  latitude,
  longitude,
  timezone,
  israel,
  candle_minutes: CANDLE_LIGHTING_MINUTES,
}));
const fail = (status, message) => Object.assign(new Error(message), { status });
const defaultLocationResolver = createLocationResolver(CITIES);
function validateSettings(b) {
  if (
    !b ||
    typeof b.city !== "string" ||
    !b.city.trim() ||
    b.city.length > 100 ||
    typeof b.latitude !== "number" ||
    !Number.isFinite(b.latitude) ||
    Math.abs(b.latitude) > 65 ||
    typeof b.longitude !== "number" ||
    !Number.isFinite(b.longitude) ||
    Math.abs(b.longitude) > 180 ||
    !IANAZone.isValidZone(b.timezone) ||
    typeof b.israel !== "boolean"
  )
    throw fail(
      400,
      "יש לבחור עיר ואזור זמן תקינים (קו רוחב עד 65 מעלות)",
    );
  return {
    city: b.city.trim(),
    latitude: b.latitude,
    longitude: b.longitude,
    timezone: b.timezone,
    israel: b.israel,
    candle_minutes: CANDLE_LIGHTING_MINUTES,
  };
}
function validateEvent(b) {
  if (
    !b ||
    typeof b.title !== "string" ||
    !b.title.trim() ||
    b.title.length > 160 ||
    typeof (b.notes ?? "") !== "string" ||
    (b.notes ?? "").length > 4000 ||
    typeof (b.location ?? "") !== "string" ||
    (b.location ?? "").length > 300 ||
    !IANAZone.isValidZone(b.timezone) ||
    typeof b.all_day !== "boolean" ||
    !["blue", "green", "purple", "orange", "red"].includes(b.color) ||
    ![null, 0, 5, 10, 15, 30, 60, 1440].includes(b.reminder_minutes)
  )
    throw fail(400, "פרטי האירוע אינם תקינים");
  const parse = (value) => {
    if (
      typeof value !== "string" ||
      !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(value)
    )
      throw fail(400, "תאריך או שעה אינם תקינים");
    const dt = DateTime.fromISO(value, { zone: b.timezone });
    if (!dt.isValid || dt.toFormat("yyyy-MM-dd'T'HH:mm") !== value)
      throw fail(400, "השעה אינה קיימת בתאריך זה עקב מעבר שעון");
    if (dt.getPossibleOffsets().length > 1)
      throw fail(
        400,
        "השעה חוזרת פעמיים במעבר שעון. בחרו שעה מחוץ לטווח המעבר",
      );
    return dt;
  };
  const start = parse(b.start),
    end = parse(b.end);
  if (
    end <= start ||
    end.diff(start, "days").days > 31 ||
    start.year < 2020 ||
    start.year > 2100
  )
    throw fail(400, "סיום האירוע חייב להיות אחרי ההתחלה, עד 31 ימים");
  if (b.all_day && (start.hour || start.minute || end.hour || end.minute))
    throw fail(400, "אירוע של יום שלם חייב להתחיל ולהסתיים בחצות");
  const repeat = b.repeat || "none",
    end_type = repeat === "none" ? "count" : (b.end_type ?? "count"),
    count = repeat === "none" ? 1 : b.count,
    interval = repeat === "daily" ? (b.interval ?? 1) : 1;
  if (
    !["none", "daily", "weekly", "monthly"].includes(repeat) ||
    !["count", "until"].includes(end_type) ||
    (end_type === "count" &&
      (!Number.isInteger(count) || count < 1 || count > 104))
  )
    throw fail(400, "ניתן ליצור עד 104 מופעים");
  if (!Number.isInteger(interval) || interval < 1 || interval > 7)
    throw fail(400, "בחזרה יומית יש לבחור מרווח של 1 עד 7 ימים");
  let until = null;
  if (end_type === "until") {
    until = b.until;
    const date = typeof until === "string"
      ? DateTime.fromISO(until, { zone: "UTC" }) : null;
    if (!/^\d{4}-\d{2}-\d{2}$/.test(until ?? "") ||
        !date?.isValid || date.toISODate() !== until ||
        until < start.toISODate() || date.year > 2100)
      throw fail(400, "תאריך סיום החזרה חייב להיות ביום תחילת האירוע או אחריו");
  }
  const weekdays = repeat === "weekly" ? (b.weekdays ?? [start.weekday]) : [];
  if (!Array.isArray(weekdays) ||
      (repeat === "weekly" && !weekdays.length) || weekdays.length > 7 ||
      weekdays.some((day) => !Number.isInteger(day) || day < 1 || day > 7))
    throw fail(400, "יש לבחור לפחות יום אחד בשבוע");
  if (
    !Array.isArray(b.invitees) ||
    b.invitees.length > 50 ||
    b.invitees.some((x) => typeof x !== "string" || !UUID.test(x))
  )
    throw fail(400, "רשימת המוזמנים אינה תקינה");
  return {
    ...b,
    title: b.title.trim(),
    notes: b.notes || "",
    location: b.location || "",
    repeat,
    count,
    interval,
    weekdays: [...new Set(weekdays)].sort((a, b) => a - b),
    end_type,
    until,
    start,
    end,
    invitees: [...new Set(b.invitees)],
  };
}
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function seriesRevision(rows) {
  const versions = rows.map((row) => [row.id, row.version])
    .sort(([a], [b]) => a.localeCompare(b));
  return crypto.createHash("sha256").update(JSON.stringify(versions)).digest("hex");
}
// UTC here is a civil-calendar calculation space, not an instant conversion.
// Apply the real zone only after date arithmetic so DST gaps cannot silently
// move an occurrence, and months with fewer days retain the event's duration.
const civilTime = (dt) => dt.setZone("UTC", { keepLocalTime: true });
function occurrenceTimes(startCivil, endCivil, e) {
  const resolve = (civil) => {
    const local = civil.setZone(e.timezone, { keepLocalTime: true });
    if (!local.isValid ||
        local.toFormat("yyyy-MM-dd'T'HH:mm") !== civil.toFormat("yyyy-MM-dd'T'HH:mm") ||
        local.getPossibleOffsets().length > 1)
      throw fail(400, "אחד ממופעי הסדרה נופל בשעת מעבר שעון. בחרו שעה אחרת");
    return local;
  };
  const start = resolve(startCivil), end = resolve(endCivil);
  if (end <= start || start.year < 2020 || start.year > 2100 ||
      end.diff(start, "days").days > 31 ||
      (e.all_day && (start.hour || start.minute || end.hour || end.minute)))
    throw fail(400, "אחד ממופעי הסדרה אינו בטווח תאריכים או שעות תקין");
  return { start: start.toUTC().toISO(), end: end.toUTC().toISO() };
}
function occurrences(e) {
  const result = [], anchor = civilTime(e.start);
  const duration = civilTime(e.end).toMillis() - anchor.toMillis();
  const endType = e.end_type ?? "count";
  const weekdays = e.weekdays ?? [e.start.weekday];
  for (let i = 0; ; i++) {
    if (endType === "count" && result.length >= e.count) break;
    const start = e.repeat === "monthly" ? anchor.plus({ months: i })
      : anchor.plus({ days: i * (e.repeat === "daily" ? (e.interval ?? 1) : 1) });
    if (endType === "until" && start.toISODate() > e.until) break;
    if (e.repeat === "weekly" && !weekdays.includes(start.weekday)) continue;
    if (result.length >= 104)
      throw fail(400, "טווח החזרה כולל יותר מ־104 מופעים. יש לבחור תאריך סיום מוקדם יותר");
    result.push(occurrenceTimes(start, start.plus({ milliseconds: duration }), e));
    if (e.repeat === "none") break;
  }
  if (!result.length) throw fail(400, "אין מופעים בימים ובטווח התאריכים שנבחרו");
  return result;
}
const cache = new Map();
async function holidays(settings, start, end, fetcher = fetch) {
  const p = new URLSearchParams({
    v: "1",
    cfg: "json",
    start,
    end,
    maj: "on",
    min: "on",
    mod: "on",
    nx: "on",
    mf: "on",
    ss: "on",
    s: "on",
    d: "on",
    leyning: "off",
    c: "on",
    geo: "pos",
    latitude: String(settings.latitude),
    longitude: String(settings.longitude),
    tzid: settings.timezone,
    i: settings.israel ? "on" : "off",
    b: String(CANDLE_LIGHTING_MINUTES),
    lg: "he",
    M: "on",
  });
  const key = p.toString();
  const cached = cache.get(key);
  if (cached && cached.expires > Date.now()) return cached.data;
  const get = async (params) => {
    const r = await fetcher(`https://www.hebcal.com/hebcal?${params}`, {
      signal: AbortSignal.timeout(12000),
    });
    if (!r.ok) throw Error("Holiday provider unavailable");
    const b = await r.json();
    if (!Array.isArray(b.items)) throw Error("Invalid holiday response");
    return b.items;
  };
  const rt = new URLSearchParams(p);
  rt.delete("M");
  rt.set("m", "72");
  const [normal, tam] = await Promise.all([get(p), get(rt)]);
  const items = normal.map((x) => ({
    date: x.date,
    title: x.hebrew || x.title,
    category: x.category,
    subcategory: x.subcat || "",
    memo: x.memo || "",
  }));
  for (const x of tam) {
    if (x.category === "havdalah")
      items.push({
        date: x.date,
        title: "רבנו תם — 72 דקות אחרי השקיעה",
        category: "rabbeinu_tam",
      });
    // When Shabbat/one festival day leads directly into another festival day,
    // Hebcal emits night-time candle lighting instead of a Havdalah event.
    // Preserve the normal time and show the later 72-minute alternative too.
    if (
      x.category === "candles" &&
      normal.some(
        (n) =>
          n.category === "candles" &&
          n.date.slice(0, 10) === x.date.slice(0, 10) &&
          n.date !== x.date,
      )
    ) {
      items.push({
        date: x.date,
        title: "הדלקת נרות לחג לפי רבנו תם — 72 דקות",
        category: "rabbeinu_tam",
      });
    }
  }
  const data = items.sort((a, b) => a.date.localeCompare(b.date));
  if (cache.size >= 128) cache.delete(cache.keys().next().value);
  cache.set(key, { expires: Date.now() + 86400000, data });
  return data;
}
function serialize(e, zone) {
  if (e.all_day) zone = e.timezone;
  return {
    ...e,
    start_local: DateTime.fromJSDate(new Date(e.starts_at), { zone }).toFormat(
      "yyyy-MM-dd'T'HH:mm",
    ),
    end_local: DateTime.fromJSDate(new Date(e.ends_at), { zone }).toFormat(
      "yyyy-MM-dd'T'HH:mm",
    ),
    event_start_local: DateTime.fromJSDate(new Date(e.starts_at), {
      zone: e.timezone,
    }).toFormat("yyyy-MM-dd'T'HH:mm"),
    event_end_local: DateTime.fromJSDate(new Date(e.ends_at), {
      zone: e.timezone,
    }).toFormat("yyyy-MM-dd'T'HH:mm"),
  };
}
function registerCalendar(
  app,
  {
    auth,
    getPool,
    sendPush = async () => {},
    canInvite = async () => true,
    validateShared = async () => {},
    resolveLocation = defaultLocationResolver,
    fetchHolidays = holidays,
  },
) {
  const wrap = (fn) => async (req, res) => {
    try {
      res.set("Cache-Control", "no-store");
      await fn(req, res);
    } catch (e) {
      if (!e.status) console.error("[calendar]", e.message);
      res.status(e.status || 500).json({
        error: e.status ? e.message : "לא ניתן להשלים את הפעולה ביומן כרגע",
      });
    }
  };
  const settingsFor = async (db, uid) => {
    const saved = (
      await db.query("SELECT * FROM calendar_settings WHERE user_id=$1", [uid])
    ).rows[0];
    // Legacy saved offsets remain readable, but cannot override the fixed policy.
    return saved
      ? { ...saved, candle_minutes: CANDLE_LIGHTING_MINUTES }
      : null;
  };
  const effectiveSettings = async (db, uid) => {
    const saved = await settingsFor(db, uid);
    if (saved && saved.source !== "location")
      return { settings: saved, source: "saved" };
    const profile =
      (
        await db.query(
          `SELECT city,country,latitude,longitude,
                  (birth_date IS NULL OR birth_date > CURRENT_DATE - INTERVAL '18 years') AS is_teen
           FROM users WHERE id=$1`,
          [uid],
        )
      ).rows[0] || {};
    if (profile.city?.trim()) {
      try {
        return {
          settings: await resolveLocation({
            city: profile.city,
            country: profile.country,
          }),
          source: "profile",
        };
      } catch (error) {
        if (!error.status) throw error;
      }
    }
    if (
      !profile.is_teen &&
      profile.latitude != null &&
      profile.longitude != null
    ) {
      try {
        return {
          settings: await resolveLocation({
            latitude: profile.latitude,
            longitude: profile.longitude,
          }),
          source: "location",
        };
      } catch (error) {
        if (!error.status) throw error;
      }
    }
    if (saved && !profile.is_teen)
      return { settings: saved, source: "location" };
    return { settings: CITIES[0], source: "default" };
  };
  const getSettings = async (db, uid) =>
    (await effectiveSettings(db, uid)).settings;
  const settingsPayload = async (db, req) => {
    const result = await effectiveSettings(db, req.user.id);
    return {
      ...result,
      configured: true,
      saved: result.source === "saved",
      cities: CITIES,
      timezones: timezoneList(),
      location_allowed: req.user.isTeen !== true,
      today: DateTime.now().setZone(result.settings.timezone).toISODate(),
    };
  };
  const notice = async (db, uid, eventId, message) => {
    await db.query(
      "INSERT INTO calendar_notices(user_id,event_id,message) VALUES($1,$2,$3)",
      [uid, eventId, message],
    );
  };
  const push = (uid, message) =>
    Promise.resolve(
      sendPush(uid, "לוח שנה", message, { type: "calendar" }),
    ).catch((e) => console.error("[calendar push]", e.message));
  const assertInvitees = async (db, uid, ids) => {
    if (ids.includes(uid)) throw fail(400, "אין צורך להזמין את עצמך");
    for (const id of ids) {
      const r = await db.query(
        `SELECT 1 FROM user_contacts c JOIN users u ON u.id=c.contact_id WHERE c.owner_id=$1 AND c.contact_id=$2 AND NOT EXISTS(SELECT 1 FROM blocked_users b WHERE (b.blocker_id=$1 AND b.blocked_id=$2) OR (b.blocker_id=$2 AND b.blocked_id=$1))`,
        [uid, id],
      );
      if (!r.rowCount || !(await canInvite(db, uid, id)))
        throw fail(403, "ניתן להזמין רק חברים מורשים מאנשי הקשר");
    }
  };
  app.get(
    "/api/calendar/settings",
    auth,
    wrap(async (req, res) => {
      const db = await getPool();
      res.json(await settingsPayload(db, req));
    }),
  );
  app.get(
    "/api/calendar/location",
    auth,
    wrap(async (req, res) => {
      if (
        !(typeof req.query.city === "string" && req.query.city.trim()) &&
        req.user.isTeen
      )
        throw fail(403, "שיתוף מיקום אינו זמין בחשבון נוער");
      res.json({ settings: await resolveLocation(req.query) });
    }),
  );
  app.post(
    "/api/calendar/location/default",
    auth,
    wrap(async (req, res) => {
      if (req.user.isTeen) throw fail(403, "שיתוף מיקום אינו זמין בחשבון נוער");
      const db = await getPool();
      const current = await effectiveSettings(db, req.user.id);
      if (current.source === "default") {
        const s = validateSettings(
          await resolveLocation({
            latitude: req.body?.latitude,
            longitude: req.body?.longitude,
          }),
        );
        // A manual choice made concurrently in another tab always wins.
        if ((await effectiveSettings(db, req.user.id)).source === "default")
          await db.query(
            `INSERT INTO calendar_settings(user_id,city,latitude,longitude,timezone,israel,candle_minutes,source)
          VALUES($1,$2,$3,$4,$5,$6,$7,'location') ON CONFLICT(user_id) DO NOTHING`,
            [
              req.user.id,
              s.city,
              s.latitude,
              s.longitude,
              s.timezone,
              s.israel,
              s.candle_minutes,
            ],
          );
      }
      res.json(await settingsPayload(db, req));
    }),
  );
  app.put(
    "/api/calendar/settings",
    auth,
    wrap(async (req, res) => {
      const db = await getPool();
      const current = await getSettings(db, req.user.id);
      const location =
        req.body?.city === current.city
          ? current
          : await resolveLocation({
              city: req.body?.city,
              country: req.body?.country,
            });
      const s = validateSettings({
        ...req.body,
        latitude: location.latitude,
        longitude: location.longitude,
      });
      await db.query(
        `INSERT INTO calendar_settings(user_id,city,latitude,longitude,timezone,israel,candle_minutes,source) VALUES($1,$2,$3,$4,$5,$6,$7,'saved') ON CONFLICT(user_id) DO UPDATE SET city=$2,latitude=$3,longitude=$4,timezone=$5,israel=$6,candle_minutes=$7,source='saved'`,
        [
          req.user.id,
          s.city,
          s.latitude,
          s.longitude,
          s.timezone,
          s.israel,
          s.candle_minutes,
        ],
      );
      res.json({ ok: true });
    }),
  );
  app.get(
    "/api/calendar/contacts",
    auth,
    wrap(async (req, res) => {
      const db = await getPool();
      const rows = (
        await db.query(
          `SELECT u.id,u.name FROM user_contacts c JOIN users u ON u.id=c.contact_id WHERE c.owner_id=$1 AND u.id<>$1 AND NOT EXISTS(SELECT 1 FROM blocked_users b WHERE (b.blocker_id=$1 AND b.blocked_id=u.id) OR (b.blocker_id=u.id AND b.blocked_id=$1)) ORDER BY u.name`,
          [req.user.id],
        )
      ).rows;
      const allowed = [];
      for (const row of rows)
        if (await canInvite(db, req.user.id, row.id)) allowed.push(row);
      res.json(allowed);
    }),
  );
  app.get(
    "/api/calendar/events",
    auth,
    wrap(async (req, res) => {
      const db = await getPool(),
        s = await getSettings(db, req.user.id);
      const start = DateTime.fromISO(String(req.query.start), {
          zone: s.timezone,
        }),
        end = DateTime.fromISO(String(req.query.end), { zone: s.timezone });
      if (
        !/^\d{4}-\d{2}-\d{2}$/.test(req.query.start) ||
        !/^\d{4}-\d{2}-\d{2}$/.test(req.query.end) ||
        !start.isValid ||
        !end.isValid ||
        end <= start ||
        end.diff(start, "days").days > 62
      )
        throw fail(400, "טווח התאריכים אינו תקין");
      const rows = (
        await db.query(
          `SELECT e.*,u.name AS owner_name,a.response FROM calendar_events e JOIN users u ON u.id=e.owner_id LEFT JOIN calendar_attendees a ON a.event_id=e.id AND a.user_id=$1 AND e.owner_id<>$1 WHERE NOT e.cancelled AND (e.owner_id=$1 OR a.response IN ('accepted','maybe')) AND ((NOT e.all_day AND e.starts_at<$3 AND e.ends_at>$2) OR
          (e.all_day AND (e.starts_at AT TIME ZONE e.timezone)::date<$5::date
            AND (e.ends_at AT TIME ZONE e.timezone)::date>$4::date)) ORDER BY e.starts_at`,
          [
            req.user.id,
            start.toUTC().toISO(),
            end.toUTC().toISO(),
            start.toISODate(),
            end.toISODate(),
          ],
        )
      ).rows;
      const ownedIds = rows
        .filter((e) => e.owner_id === req.user.id)
        .map((e) => e.id);
      const ownedSeriesIds = [...new Set(rows
        .filter((e) => e.owner_id === req.user.id && e.series_id)
        .map((e) => e.series_id))];
      const seriesRevisions = new Map();
      if (ownedSeriesIds.length) {
        // Include members outside the visible range: changing any occurrence
        // must invalidate a previously opened editor for the whole series.
        const members = (await db.query(
          `SELECT id,version,series_id FROM calendar_events WHERE owner_id=$1
           AND series_id=ANY($2::uuid[]) AND NOT cancelled ORDER BY series_id,id`,
          [req.user.id, ownedSeriesIds],
        )).rows;
        const bySeries = new Map();
        for (const member of members) {
          if (!bySeries.has(member.series_id)) bySeries.set(member.series_id, []);
          bySeries.get(member.series_id).push(member);
        }
        for (const [seriesId, events] of bySeries)
          seriesRevisions.set(seriesId, seriesRevision(events));
      }
      const summaries = new Map();
      if (ownedIds.length) {
        const counts = (
          await db.query(
            `SELECT event_id,COUNT(*)::int AS total,
              COUNT(*) FILTER (WHERE response='accepted')::int AS accepted,
              COUNT(*) FILTER (WHERE response='maybe')::int AS maybe,
              COUNT(*) FILTER (WHERE response='pending')::int AS pending,
              COUNT(*) FILTER (WHERE response='declined')::int AS declined
             FROM calendar_attendees
             WHERE event_id=ANY($1::uuid[]) AND user_id<>$2
             GROUP BY event_id`,
            [ownedIds, req.user.id],
          )
        ).rows;
        for (const { event_id, ...summary } of counts)
          summaries.set(event_id, summary);
      }
      // Attendance counts are visible only to the organizer, including zero
      // counts for personal events. A legacy self-invitation is not a guest.
      for (const e of rows) {
        if (e.owner_id === req.user.id)
          e.attendee_summary = summaries.get(e.id) || {
            total: 0,
            accepted: 0,
            maybe: 0,
            pending: 0,
            declined: 0,
          };
        if (e.owner_id === req.user.id && e.series_id)
          e.series_revision = seriesRevisions.get(e.series_id);
      }
      res.json({
        events: rows.map((e) => serialize(e, s.timezone)),
        timezone: s.timezone,
      });
    }),
  );
  app.get(
    "/api/calendar/holidays",
    auth,
    wrap(async (req, res) => {
      const s = await getSettings(await getPool(), req.user.id);
      const start = String(req.query.start),
        end = String(req.query.end);
      const a = DateTime.fromISO(start),
        b = DateTime.fromISO(end);
      if (
        !/^\d{4}-\d{2}-\d{2}$/.test(start) ||
        !/^\d{4}-\d{2}-\d{2}$/.test(end) ||
        !a.isValid ||
        !b.isValid ||
        b < a ||
        b.diff(a, "days").days > 62
      )
        throw fail(400, "טווח התאריכים אינו תקין");
      res.json({
        items: await fetchHolidays(s, start, end),
        configured: true,
        source: "Hebcal",
        settings: s,
      });
    }),
  );
  app.get(
    "/api/calendar/inbox",
    auth,
    wrap(async (req, res) => {
      const db = await getPool(),
        s = await getSettings(db, req.user.id);
      const invitations = (
        await db.query(
          `SELECT e.*,u.name AS owner_name,a.response FROM calendar_attendees a JOIN calendar_events e ON e.id=a.event_id JOIN users u ON u.id=e.owner_id WHERE a.user_id=$1 AND a.response='pending' AND NOT e.cancelled AND e.ends_at>now() ORDER BY e.starts_at LIMIT 200`,
          [req.user.id],
        )
      ).rows;
      const notices = (
        await db.query(
          "SELECT id,event_id,message,created_at FROM calendar_notices WHERE user_id=$1 AND read_at IS NULL ORDER BY created_at DESC LIMIT 100",
          [req.user.id],
        )
      ).rows;
      res.json({
        invitations: invitations.map((e) => serialize(e, s.timezone)),
        notices,
      });
    }),
  );
  app.post(
    "/api/calendar/notices/read",
    auth,
    wrap(async (req, res) => {
      if (
        !Array.isArray(req.body.ids) ||
        req.body.ids.length > 100 ||
        req.body.ids.some((x) => !UUID.test(x))
      )
        throw fail(400, "רשימה לא תקינה");
      await (
        await getPool()
      ).query(
        "UPDATE calendar_notices SET read_at=now() WHERE user_id=$1 AND id=ANY($2::uuid[])",
        [req.user.id, req.body.ids],
      );
      res.json({ ok: true });
    }),
  );
  app.get(
    "/api/calendar/summary",
    auth,
    wrap(async (req, res) => {
      const db = await getPool(),
        uid = req.user.id,
        s = await getSettings(db, uid);
      const next = (
        await db.query(
          `SELECT e.*,u.name AS owner_name FROM calendar_events e JOIN users u ON u.id=e.owner_id WHERE NOT cancelled AND ends_at>now() AND (owner_id=$1 OR EXISTS(SELECT 1 FROM calendar_attendees a WHERE a.event_id=e.id AND a.user_id=$1 AND a.response='accepted')) ORDER BY starts_at LIMIT 1`,
          [uid],
        )
      ).rows[0];
      const pending = (
        await db.query(
          `SELECT COUNT(*)::int AS n FROM calendar_attendees a JOIN calendar_events e ON e.id=a.event_id WHERE a.user_id=$1 AND a.response='pending' AND NOT e.cancelled AND e.ends_at>now()`,
          [uid],
        )
      ).rows[0].n;
      const unread = (
        await db.query(
          "SELECT COUNT(*)::int AS n FROM calendar_notices WHERE user_id=$1 AND read_at IS NULL",
          [uid],
        )
      ).rows[0].n;
      res.json({
        next: next ? serialize(next, s.timezone) : null,
        pending: pending + unread,
      });
    }),
  );
  app.post(
    "/api/calendar/events",
    auth,
    wrap(async (req, res) => {
      const e = validateEvent(req.body);
      if (e.invitees.length)
        await validateShared([e.title, e.notes, e.location].join("\n"));
      const times = occurrences(e),
        db = await getPool(),
        c = await db.connect();
      const ids = [];
      try {
        await c.query("BEGIN");
        await assertInvitees(c, req.user.id, e.invitees);
        const series = times.length > 1 ? crypto.randomUUID() : null;
        for (const t of times) {
          const row = (
            await c.query(
              `INSERT INTO calendar_events(owner_id,series_id,title,notes,location,starts_at,ends_at,timezone,all_day,color,reminder_minutes) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) RETURNING id`,
              [
                req.user.id,
                series,
                e.title,
                e.notes,
                e.location,
                t.start,
                t.end,
                e.timezone,
                e.all_day,
                e.color,
                e.reminder_minutes,
              ],
            )
          ).rows[0];
          ids.push(row.id);
          for (const uid of e.invitees)
            await c.query(
              "INSERT INTO calendar_attendees(event_id,user_id) VALUES($1,$2)",
              [row.id, uid],
            );
        }
        for (const uid of e.invitees)
          await notice(
            c,
            uid,
            ids[0],
            `הזמנה: ${e.title}${ids.length > 1 ? ` (${ids.length} מופעים)` : ""}`,
          );
        await c.query("COMMIT");
      } catch (err) {
        await c.query("ROLLBACK");
        throw err;
      } finally {
        c.release();
      }
      for (const uid of e.invitees) push(uid, `הזמנה חדשה: ${e.title}`);
      res.status(201).json({ ids });
    }),
  );
  app.get(
    "/api/calendar/events/:id/attendees",
    auth,
    wrap(async (req, res) => {
      if (!UUID.test(req.params.id)) throw fail(404, "האירוע לא נמצא");
      const db = await getPool();
      if (
        !(
          await db.query(
            "SELECT 1 FROM calendar_events WHERE id=$1 AND owner_id=$2",
            [req.params.id, req.user.id],
          )
        ).rowCount
      )
        throw fail(404, "האירוע לא נמצא");
      res.json(
        (
          await db.query(
            "SELECT a.user_id,u.name,a.response FROM calendar_attendees a JOIN users u ON u.id=a.user_id WHERE event_id=$1 AND a.user_id<>$2 ORDER BY u.name",
            [req.params.id, req.user.id],
          )
        ).rows,
      );
    }),
  );
  app.put(
    "/api/calendar/events/:id",
    auth,
    wrap(async (req, res) => {
      if (!UUID.test(req.params.id)) throw fail(404, "האירוע לא נמצא");
      const scope = req.body.scope ?? "single";
      if (!["single", "series"].includes(scope))
        throw fail(400, "יש לבחור עדכון מופע יחיד או כל המופעים");
      const e = validateEvent({ ...req.body, repeat: "none" });
      if (e.invitees.length)
        await validateShared([e.title, e.notes, e.location].join("\n"));
      const db = await getPool(),
        c = await db.connect();
      let targets = [], updated = 0;
      try {
        await c.query("BEGIN");
        const selected = (
          await c.query(
            "SELECT * FROM calendar_events WHERE id=$1 AND owner_id=$2 AND NOT cancelled",
            [req.params.id, req.user.id],
          )
        ).rows[0];
        if (!selected) throw fail(404, "האירוע לא נמצא");
        if (scope === "series" && !selected.series_id)
          throw fail(400, "האירוע אינו חלק מסדרה");
        // Do not lock the selected occurrence first: simultaneous edits from
        // different occurrences must acquire all series locks in the same order.
        // Non-key locks also allow reminder claims to check their event foreign
        // keys without introducing a competing lock order across the series.
        const rows = (
          await c.query(
            scope === "series"
              ? "SELECT * FROM calendar_events WHERE series_id=$1 AND owner_id=$2 AND NOT cancelled ORDER BY id FOR NO KEY UPDATE"
              : "SELECT * FROM calendar_events WHERE id=$1 AND owner_id=$2 AND NOT cancelled FOR NO KEY UPDATE",
            [scope === "series" ? selected.series_id : selected.id, req.user.id],
          )
        ).rows;
        const old = rows.find((row) => row.id === selected.id);
        if (!old) throw fail(404, "האירוע לא נמצא");
        if (old.version !== req.body.version)
          throw fail(409, "האירוע השתנה. יש לרענן ולנסות שוב");
        if (scope === "series" &&
            (typeof req.body.series_revision !== "string" ||
             req.body.series_revision !== seriesRevision(rows)))
          throw fail(409, "אחד ממופעי הסדרה השתנה. יש לרענן ולנסות שוב");
        const attendees = (
          await c.query(
            "SELECT event_id,user_id FROM calendar_attendees WHERE event_id=ANY($1::uuid[])",
            [rows.map((row) => row.id)],
          )
        ).rows;
        const previousByEvent = new Map(rows.map((row) => [row.id, []]));
        for (const attendee of attendees)
          previousByEvent.get(attendee.event_id).push(attendee.user_id);
        await assertInvitees(
          c,
          req.user.id,
          e.invitees.filter((uid) =>
            rows.some((row) => !previousByEvent.get(row.id).includes(uid))),
        );
        const localStart = (row) => civilTime(DateTime.fromJSDate(
          new Date(row.starts_at), { zone: row.timezone }));
        const anchor = civilTime(e.start);
        const shift = anchor.toMillis() - localStart(old).toMillis();
        const duration = civilTime(e.end).toMillis() - anchor.toMillis();
        const selectedScheduleChanged =
          new Date(old.starts_at).getTime() !== e.start.toMillis() ||
          new Date(old.ends_at).getTime() !== e.end.toMillis() ||
          old.timezone !== e.timezone || old.all_day !== e.all_day;
        // Validate every new endpoint before writing any event. The relative
        // local dates also support older series with no stored recurrence rule.
        const changes = rows.map((row) => {
          // A rename or notes edit must retain exceptions edited separately,
          // including their duration, zone and all-day setting.
          if (!selectedScheduleChanged) return {
            row, start: new Date(row.starts_at).toISOString(),
            end: new Date(row.ends_at).toISOString(), timezone: row.timezone,
            all_day: row.all_day, timeChanged: false,
          };
          const start = localStart(row).plus({ milliseconds: shift });
          const times = occurrenceTimes(start, start.plus({ milliseconds: duration }), e);
          const timeChanged =
            new Date(row.starts_at).getTime() !== Date.parse(times.start) ||
            new Date(row.ends_at).getTime() !== Date.parse(times.end) ||
            row.all_day !== e.all_day;
          return { row, ...times, timezone: e.timezone, all_day: e.all_day, timeChanged };
        });
        for (const change of changes) {
          const { row, start, end, timezone, all_day, timeChanged } = change;
          await c.query(
            `UPDATE calendar_events SET title=$2,notes=$3,location=$4,starts_at=$5,ends_at=$6,timezone=$7,all_day=$8,color=$9,reminder_minutes=$10,version=version+1,reminder_version=reminder_version+$11,updated_at=now() WHERE id=$1`,
            [row.id, e.title, e.notes, e.location, start, end, timezone,
              all_day, e.color, e.reminder_minutes,
              timeChanged || row.reminder_minutes !== e.reminder_minutes ? 1 : 0],
          );
          await c.query(
            "DELETE FROM calendar_attendees WHERE event_id=$1 AND NOT(user_id=ANY($2::uuid[]))",
            [row.id, e.invitees],
          );
          if (timeChanged)
            await c.query(
              "UPDATE calendar_attendees SET response='pending' WHERE event_id=$1",
              [row.id],
            );
          for (const uid of e.invitees)
            await c.query(
              "INSERT INTO calendar_attendees(event_id,user_id) VALUES($1,$2) ON CONFLICT DO NOTHING",
              [row.id, uid],
            );
        }
        targets = [...new Set([...attendees.map((a) => a.user_id), ...e.invitees])];
        const timeChanged = changes.some((change) => change.timeChanged);
        const subject = scope === "series" ? "סדרת האירועים" : "האירוע";
        for (const uid of targets)
          await notice(
            c,
            uid,
            old.id,
            e.invitees.includes(uid)
              ? `${subject} עודכ${scope === "series" ? "נה" : "ן"}: ${e.title}${timeChanged ? " — יש לאשר את השעה החדשה" : ""}`
              : `ההזמנה בוטלה: ${old.title}`,
          );
        await c.query("COMMIT");
        updated = rows.length;
      } catch (err) {
        await c.query("ROLLBACK");
        throw err;
      } finally {
        c.release();
      }
      for (const uid of targets) push(uid, "אירוע ביומן עודכן");
      res.json({ ok: true, updated });
    }),
  );
  app.delete(
    "/api/calendar/events/:id",
    auth,
    wrap(async (req, res) => {
      if (!UUID.test(req.params.id)) throw fail(404, "האירוע לא נמצא");
      const db = await getPool(),
        c = await db.connect();
      let ids = [];
      try {
        await c.query("BEGIN");
        const e = (
          await c.query(
            "SELECT * FROM calendar_events WHERE id=$1 AND owner_id=$2 AND NOT cancelled FOR UPDATE",
            [req.params.id, req.user.id],
          )
        ).rows[0];
        if (!e) throw fail(404, "האירוע לא נמצא");
        if (req.body.version !== e.version)
          throw fail(409, "האירוע השתנה. יש לרענן");
        const rows = (
          await c.query(
            "SELECT user_id FROM calendar_attendees WHERE event_id=$1",
            [e.id],
          )
        ).rows;
        ids = rows.map((x) => x.user_id);
        await c.query(
          "UPDATE calendar_events SET cancelled=TRUE,version=version+1,updated_at=now() WHERE id=$1",
          [e.id],
        );
        for (const uid of ids)
          await notice(c, uid, e.id, `האירוע בוטל: ${e.title}`);
        await c.query("COMMIT");
      } catch (err) {
        await c.query("ROLLBACK");
        throw err;
      } finally {
        c.release();
      }
      for (const uid of ids) push(uid, "אירוע ביומן בוטל");
      res.json({ ok: true });
    }),
  );
  app.post(
    "/api/calendar/events/:id/respond",
    auth,
    wrap(async (req, res) => {
      if (
        !UUID.test(req.params.id) ||
        !["accepted", "maybe", "declined"].includes(req.body.response)
      )
        throw fail(400, "תשובה לא תקינה");
      const db = await getPool(),
        c = await db.connect();
      let owner;
      try {
        await c.query("BEGIN");
        const e = (
          await c.query(
            "SELECT * FROM calendar_events WHERE id=$1 AND NOT cancelled FOR UPDATE",
            [req.params.id],
          )
        ).rows[0];
        if (!e) throw fail(404, "ההזמנה לא נמצאה");
        if (e.version !== req.body.version)
          throw fail(409, "האירוע השתנה. יש לרענן את ההזמנה");
        const r = await c.query(
          "UPDATE calendar_attendees SET response=$3 WHERE event_id=$1 AND user_id=$2 RETURNING user_id",
          [e.id, req.user.id, req.body.response],
        );
        if (!r.rowCount) throw fail(404, "ההזמנה לא נמצאה");
        const name = (
          await c.query("SELECT name FROM users WHERE id=$1", [req.user.id])
        ).rows[0].name;
        owner = e.owner_id;
        await notice(
          c,
          owner,
          e.id,
          `${name}: ${{ accepted: "אישר/ה", maybe: "אולי", declined: "דחה/תה" }[req.body.response]} — ${e.title}`,
        );
        await c.query("COMMIT");
      } catch (err) {
        await c.query("ROLLBACK");
        throw err;
      } finally {
        c.release();
      }
      push(owner, "התקבלה תשובה להזמנה ביומן");
      res.json({ ok: true });
    }),
  );
}
async function runReminders(getPool, sendPush) {
  const db = await getPool();
  // Claim and persist together so overlapping ticks never create duplicate reminders.
  const rows = (
    await db.query(`WITH due AS (
 SELECT e.id,e.title,e.reminder_version AS version,e.owner_id AS user_id FROM calendar_events e WHERE NOT e.cancelled AND e.reminder_minutes IS NOT NULL AND e.starts_at>now()-interval '5 minutes' AND e.ends_at>now() AND e.starts_at-make_interval(mins=>e.reminder_minutes)<=now()
 UNION SELECT e.id,e.title,e.reminder_version AS version,a.user_id FROM calendar_events e JOIN calendar_attendees a ON a.event_id=e.id WHERE NOT e.cancelled AND a.response='accepted' AND e.reminder_minutes IS NOT NULL AND e.starts_at>now()-interval '5 minutes' AND e.ends_at>now() AND e.starts_at-make_interval(mins=>e.reminder_minutes)<=now()
 ), claimed AS (INSERT INTO calendar_reminders(event_id,user_id,version) SELECT id,user_id,version FROM due ON CONFLICT DO NOTHING RETURNING *)
 INSERT INTO calendar_notices(user_id,event_id,message) SELECT c.user_id,c.event_id,'תזכורת: '||d.title FROM claimed c JOIN due d ON d.id=c.event_id AND d.user_id=c.user_id AND d.version=c.version RETURNING user_id,message`)
  ).rows;
  for (const r of rows)
    await sendPush(r.user_id, "לוח שנה", r.message, { type: "calendar" }).catch(
      (e) => console.error("[calendar reminder push]", e.message),
    );
}
module.exports = {
  SCHEMA,
  CITIES,
  validateSettings,
  validateEvent,
  occurrences,
  holidays,
  serialize,
  registerCalendar,
  runReminders,
};
