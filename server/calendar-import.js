"use strict";

// Import only the data explicitly shared by the user. Parsing never downloads
// ATTACH/URL resources or reads the rest of a device calendar.
const ICAL = require("ical.js");
const crypto = require("node:crypto");
const { DateTime, IANAZone } = require("luxon");
const MAX_BYTES = 512 * 1024;
const MAX_EVENTS = 50;
const fail = (status, message) => Object.assign(new Error(message), { status });
const hash = (value) => crypto.createHash("sha256").update(value).digest("hex");
const civil = (dt) => dt.toFormat("yyyy-MM-dd'T'HH:mm");

const SCHEMA = `
CREATE TABLE IF NOT EXISTS calendar_event_imports (
 owner_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 source_key TEXT NOT NULL,
 event_id UUID NOT NULL REFERENCES calendar_events(id) ON DELETE CASCADE,
 event_ids UUID[] NOT NULL,
 fingerprint TEXT NOT NULL,
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 PRIMARY KEY(owner_id,source_key)
);`;

function clipped(value, limit, label, warnings) {
  const text = String(value ?? "").replace(/\u0000/g, "").trim();
  if (text.length > limit) warnings.push(`${label} קוצר כדי להתאים ליומן. ניתן לערוך לפני השמירה.`);
  return text.slice(0, limit);
}

function checkedTime(property, fallbackZone, warnings) {
  if (!property) throw fail(400, "לא נמצא תאריך התחלה באירוע המשותף");
  const raw = property.jCal[3];
  if (typeof raw !== "string") throw fail(400, "תאריך האירוע אינו תקין");
  // ICAL.Time normalizes invalid civil dates; reject them before that happens.
  const date = DateTime.fromISO(raw, { zone: "UTC" });
  if (!date.isValid) throw fail(400, "תאריך האירוע אינו תקין");
  const time = property.getFirstValue();
  const tzid = property.getParameter("tzid");
  const isUtc = raw.endsWith("Z");
  let zone;
  let instant;
  if (time.isDate) {
    zone = tzid && IANAZone.isValidZone(tzid) ? tzid : fallbackZone;
    instant = DateTime.fromISO(raw, { zone });
  } else if (isUtc) {
    if (tzid) throw fail(400, "אירוע UTC אינו יכול לכלול אזור זמן נוסף");
    zone = "UTC";
    instant = DateTime.fromISO(raw, { zone });
  } else if (tzid && IANAZone.isValidZone(tzid)) {
    zone = tzid;
    instant = DateTime.fromISO(raw, { zone });
    if (instant.toFormat("yyyy-MM-dd'T'HH:mm:ss") !== raw || instant.getPossibleOffsets().length > 1)
      throw fail(400, "שעת האירוע אינה חד־משמעית עקב מעבר שעון. יש לבחור שעה מפורשת");
  } else if (tzid && time.zone?.tzid !== "floating") {
    // Embedded VTIMEZONE definitions can describe non-IANA calendar zones.
    // Convert their resolved instant to UTC instead of guessing a local zone.
    zone = "UTC";
    instant = DateTime.fromSeconds(time.toUnixTime(), { zone });
    warnings.push(`אזור הזמן ${String(tzid).slice(0, 100)} הומר ל־UTC לפי הגדרתו בקובץ.`);
  } else if (tzid) {
    throw fail(400, `אזור הזמן ${String(tzid).slice(0, 100)} אינו מוכר. יש לשתף אירוע עם אזור זמן תקין`);
  } else {
    zone = fallbackZone;
    instant = DateTime.fromISO(raw, { zone });
    if (!time.isDate) {
      if (instant.toFormat("yyyy-MM-dd'T'HH:mm:ss") !== raw || instant.getPossibleOffsets().length > 1)
        throw fail(400, "שעת האירוע אינה חד־משמעית עקב מעבר שעון");
      warnings.push(`לא צוין אזור זמן; מוצג לפי ${zone}. יש לוודא את השעה לפני השמירה.`);
    }
  }
  if (!instant.isValid) throw fail(400, "תאריך האירוע אינו תקין");
  if (instant.second || instant.millisecond) warnings.push("שעות האירוע עוגלו לדקה. יש לוודא את השעות לפני השמירה.");
  return { dt: instant.startOf("minute"), zone, allDay: time.isDate,
    embeddedZone: Boolean(tzid && !IANAZone.isValidZone(tzid) && !time.isDate) };
}

function repeatDraft(component, start, warnings, hasExceptions) {
  const rules = component.getAllProperties("rrule");
  if (!rules.length && !hasExceptions && !component.getAllProperties("rdate").length &&
      !component.getAllProperties("exdate").length) return { repeat: "none", single: false };
  const unsupported = () => {
    warnings.push("לא ניתן לשמר ביומן את כל כללי החזרה של האירוע הזה. אפשר לייבא במפורש את המופע המשותף בלבד.");
    return { repeat: "none", single: true };
  };
  if (hasExceptions || rules.length !== 1 ||
      component.getAllProperties("rdate").length || component.getAllProperties("exdate").length)
    return unsupported();
  const rule = rules[0].getFirstValue();
  const interval = rule.interval || 1;
  const parts = rule.parts || {};
  const allowed = rule.freq === "WEEKLY" ? ["BYDAY"] : [];
  if (Object.keys(parts).some((key) => !allowed.includes(key)) ||
      !["DAILY", "WEEKLY", "MONTHLY"].includes(rule.freq) ||
      (rule.freq === "DAILY" ? interval < 1 || interval > 7 : interval !== 1) ||
      (rule.freq === "MONTHLY" && start.day > 28) ||
      (!rule.count && !rule.until)) return unsupported();
  const result = { repeat: rule.freq.toLowerCase(), interval, single: false };
  if (rule.freq === "WEEKLY") {
    const days = parts.BYDAY || ["MO", "TU", "WE", "TH", "FR", "SA", "SU"].slice(start.weekday - 1, start.weekday);
    const values = days.map((day) => ({ MO: 1, TU: 2, WE: 3, TH: 4, FR: 5, SA: 6, SU: 7 })[day]);
    // COUNT assumes DTSTART is the first actual instance, unlike our editor's
    // next-matching-weekday behavior when the initial date is not selected.
    if (values.some((day) => !day) || !values.includes(start.weekday)) return unsupported();
    result.weekdays = values;
  }
  if (rule.count) {
    if (!Number.isInteger(rule.count) || rule.count < 1 || rule.count > 104 || rule.until) return unsupported();
    result.end_type = "count";
    result.count = rule.count;
  } else {
    // UNTIL with a clock can end before an occurrence on its final civil day.
    // Convert to a finite COUNT by walking the bounded source recurrence.
    const unbounded = rule.toJSON();
    delete unbounded.until;
    const iterator = new ICAL.Recur(unbounded).iterator(component.getFirstPropertyValue("dtstart"));
    const until = rule.until.isDate
      ? DateTime.fromObject({ year: rule.until.year, month: rule.until.month, day: rule.until.day }, { zone: start.zoneName }).endOf("day")
      : rule.until.zone?.tzid === "floating"
        ? DateTime.fromObject({ year: rule.until.year, month: rule.until.month, day: rule.until.day,
          hour: rule.until.hour, minute: rule.until.minute, second: rule.until.second }, { zone: start.zoneName })
        : DateTime.fromSeconds(rule.until.toUnixTime(), { zone: "UTC" });
    let count = 0;
    while (count <= 104) {
      const next = iterator.next();
      if (!next) break;
      const instant = DateTime.fromObject({ year: next.year, month: next.month, day: next.day,
        hour: next.hour, minute: next.minute, second: next.second }, { zone: start.zoneName });
      if (!instant.isValid || instant > until) break;
      count++;
    }
    if (count < 1 || count > 104) return unsupported();
    result.end_type = "count";
    result.count = count;
  }
  return result;
}

function sourceIdentity(uid, recurrenceId, draft) {
  const fingerprint = hash(JSON.stringify(draft));
  return {
    source_key: uid ? hash(JSON.stringify(["ics", uid, recurrenceId || ""])) : hash(`event:${fingerprint}`),
    fingerprint,
  };
}

function readCalendarShare(ics, fallbackZone = "Asia/Jerusalem") {
  if (typeof ics !== "string" || !ics.trim() || Buffer.byteLength(ics, "utf8") > MAX_BYTES)
    throw fail(400, "יש לשתף קובץ אירוע תקין, עד 512KB");
  if (!IANAZone.isValidZone(fallbackZone)) throw fail(400, "אזור הזמן שנבחר אינו תקין");
  let root;
  try { root = new ICAL.Component(ICAL.parse(ics.replace(/^\uFEFF/, ""))); }
  catch { throw fail(400, "לא ניתן לקרוא את קובץ האירוע. יש לשתף קובץ ICS תקין"); }
  if (root.name !== "vcalendar") throw fail(400, "זה אינו קובץ אירוע ICS");
  if (root.getFirstPropertyValue("method")?.toUpperCase() === "CANCEL")
    throw fail(400, "זהו ביטול אירוע ולא אירוע חדש. יש לבדוק את האירוע הקיים ביומן");
  const version = root.getFirstPropertyValue("version");
  if (version && version !== "2.0") throw fail(400, "קובץ האירוע משתמש בפורמט ישן. יש לשתף קובץ ICS בגרסה 2.0");
  const events = root.getAllSubcomponents("vevent");
  if (!events.length || events.length > MAX_EVENTS) throw fail(400, "אפשר לייבא עד 50 אירועים בכל פעם");
  const uidCounts = new Map();
  for (const event of events) {
    const uid = event.getFirstPropertyValue("uid");
    if (uid) uidCounts.set(uid, (uidCounts.get(uid) || 0) + 1);
  }
  const drafts = [];
  const warnings = [];
  for (const component of events) {
    if (component.getFirstPropertyValue("status")?.toUpperCase() === "CANCELLED") {
      warnings.push("אירוע שבוטל במקור לא נוסף לייבוא.");
      continue;
    }
    const localWarnings = [];
    const start = checkedTime(component.getFirstProperty("dtstart"), fallbackZone, localWarnings);
    const endProperty = component.getFirstProperty("dtend");
    const duration = component.getFirstPropertyValue("duration");
    if (endProperty && duration) throw fail(400, "אירוע אינו יכול לכלול גם שעת סיום וגם משך");
    let end;
    if (endProperty) {
      end = checkedTime(endProperty, start.zone, localWarnings);
      if (end.allDay !== start.allDay) throw fail(400, "תאריכי ההתחלה והסיום של האירוע אינם מאותו סוג");
    } else if (duration) {
      if (duration.isNegative || duration.toSeconds() <= 0) throw fail(400, "משך האירוע אינו תקין");
      if (start.allDay && (duration.hours || duration.minutes || duration.seconds))
        throw fail(400, "אירוע של יום שלם אינו יכול לכלול משך בשעות");
      end = { dt: start.dt.plus({ weeks: duration.weeks, days: duration.days, hours: duration.hours,
        minutes: duration.minutes, seconds: duration.seconds }).startOf("minute") };
    } else {
      end = { dt: start.dt.plus(start.allDay ? { days: 1 } : { hours: 1 }) };
      if (!start.allDay) localWarnings.push("לא צוינה שעת סיום; הוצע משך של שעה. ניתן לשנות לפני השמירה.");
    }
    const uid = String(component.getFirstPropertyValue("uid") || "").slice(0, 2000);
    const recurrenceId = component.getFirstPropertyValue("recurrence-id")?.toString() || "";
    const repeat = repeatDraft(component, start.dt, localWarnings, Boolean(recurrenceId ||
      (uid && uidCounts.get(uid) > 1) || (start.embeddedZone && component.getAllProperties("rrule").length)));
    const eventUrl = component.getFirstPropertyValue("url");
    const description = component.getFirstPropertyValue("description") || "";
    const draft = {
      title: clipped(component.getFirstPropertyValue("summary"), 160, "שם האירוע", localWarnings) || "אירוע משותף",
      notes: clipped(eventUrl ? `${description}${description ? "\n" : ""}${eventUrl}` : description, 4000, "התיאור", localWarnings),
      location: clipped(component.getFirstPropertyValue("location"), 300, "המיקום", localWarnings),
      start: civil(start.dt), end: civil(end.dt.setZone(start.zone)), timezone: start.zone,
      all_day: start.allDay, color: "blue", reminder_minutes: 15, invitees: [],
      ...Object.fromEntries(Object.entries(repeat).filter(([key]) => key !== "single")),
    };
    if (component.getAllProperties("attendee").length)
      localWarnings.push("משתתפים מהיומן המקורי אינם מוזמנים אוטומטית; האירוע נשמר ביומן האישי שלך.");
    if (component.getAllProperties("attach").length)
      localWarnings.push("קבצים וקישורים מצורפים לא הורדו. ניתן לשתף אותם בנפרד בשיחה.");
    drafts.push({ draft, ...sourceIdentity(uid, recurrenceId, draft),
      warnings: [...new Set(localWarnings)], requires_single_occurrence: repeat.single });
  }
  if (!drafts.length) throw fail(400, "בקובץ אין אירועים פעילים לייבוא");
  return { drafts, warnings: [...new Set(warnings)] };
}

function parseCalendarShare(ics, fallbackZone) {
  try { return readCalendarShare(ics, fallbackZone); }
  catch (error) {
    if (error.status) throw error;
    throw fail(400, "פרטי האירוע בקובץ אינם תקינים. יש לשתף קובץ ICS תקין");
  }
}

function parseCalendarDraft(event, fallbackZone = "Asia/Jerusalem") {
  if (!event || typeof event !== "object" || Array.isArray(event)) throw fail(400, "פרטי האירוע אינם תקינים");
  const timezone = event.timezone || event.eventTimezone || fallbackZone;
  if (!IANAZone.isValidZone(timezone)) throw fail(400, "אזור הזמן של האירוע אינו תקין");
  const warnings = [];
  const allDay = event.all_day === true || event.allDay === true;
  const startMillis = event.start_epoch_ms ?? event.beginTime;
  const endMillis = event.end_epoch_ms ?? event.endTime;
  let start = event.start, end = event.end;
  if (Number.isSafeInteger(startMillis)) {
    const date = DateTime.fromMillis(startMillis, { zone: allDay ? "UTC" : timezone });
    start = allDay ? `${date.toISODate()}T00:00` : civil(date);
    if (Number.isSafeInteger(endMillis)) {
      const dateEnd = DateTime.fromMillis(endMillis, { zone: allDay ? "UTC" : timezone });
      end = allDay ? `${dateEnd.toISODate()}T00:00` : civil(dateEnd);
    }
  }
  if (typeof start !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(start))
    throw fail(400, "לא נמצא תאריך התחלה תקין באירוע המשותף");
  if (end == null) {
    end = civil(DateTime.fromISO(start, { zone: timezone }).plus(allDay ? { days: 1 } : { hours: 1 }));
    if (!allDay) warnings.push("לא צוינה שעת סיום; הוצע משך של שעה. ניתן לשנות לפני השמירה.");
  }
  const draft = {
    title: clipped(event.title, 160, "שם האירוע", warnings) || "אירוע משותף",
    notes: clipped(event.notes ?? event.description, 4000, "התיאור", warnings),
    location: clipped(event.location ?? event.eventLocation, 300, "המיקום", warnings),
    start, end, timezone, all_day: allDay,
    color: "blue", reminder_minutes: 15, repeat: "none", invitees: [],
  };
  const single = Boolean(event.recurrence);
  if (single) warnings.push("פרטי החזרה אינם נתמכים בשיתוף זה. אפשר לייבא במפורש את המופע המשותף בלבד.");
  return { drafts: [{ draft, ...sourceIdentity(String(event.external_id || "").slice(0, 2000), "", draft),
    warnings, requires_single_occurrence: single }], warnings: [] };
}

function signImportToken(entry, owner, secret, now = Date.now()) {
  const data = Buffer.from(JSON.stringify({ owner, key: entry.source_key, fingerprint: entry.fingerprint,
    single: entry.requires_single_occurrence === true, exp: Math.floor(now / 1000) + 900 })).toString("base64url");
  return `${data}.${crypto.createHmac("sha256", secret).update(data).digest("base64url")}`;
}

function verifyImportToken(token, owner, secret, now = Date.now()) {
  if (typeof token !== "string" || token.length > 4096) throw fail(400, "אישור הייבוא אינו תקין. יש לפתוח את האירוע מחדש");
  const pieces = token.split(".");
  if (pieces.length !== 2 || !pieces.every((piece) => /^[A-Za-z0-9_-]+$/.test(piece)))
    throw fail(400, "אישור הייבוא אינו תקין. יש לפתוח את האירוע מחדש");
  const expected = crypto.createHmac("sha256", secret).update(pieces[0]).digest();
  const received = Buffer.from(pieces[1], "base64url");
  if (received.length !== expected.length || !crypto.timingSafeEqual(received, expected))
    throw fail(403, "אישור הייבוא אינו תקין");
  let claims;
  try { claims = JSON.parse(Buffer.from(pieces[0], "base64url").toString("utf8")); }
  catch { throw fail(400, "אישור הייבוא אינו תקין"); }
  if (claims.owner !== owner || !Number.isInteger(claims.exp) || claims.exp <= Math.floor(now / 1000) ||
      !/^[a-f0-9]{64}$/.test(claims.key || "") || !/^[a-f0-9]{64}$/.test(claims.fingerprint || ""))
    throw fail(403, "אישור הייבוא פג או שייך לחשבון אחר. יש לפתוח את האירוע מחדש");
  return claims;
}

module.exports = { SCHEMA, MAX_BYTES, MAX_EVENTS, parseCalendarShare, parseCalendarDraft,
  signImportToken, verifyImportToken };
