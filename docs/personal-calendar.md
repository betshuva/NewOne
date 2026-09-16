# Personal calendar

The fixed “לוח שנה” conversation entry opens a private calendar in the desktop detail pane or a full-screen route on mobile. Day/week timelines and a month grid support timed and all-day events, overlapping appointments, colors, notes, locations, and finite daily/weekly/Gregorian-monthly series (up to 104 occurrences). Editing or cancelling a series occurrence affects that occurrence only.

Friends can be invited from the owner's contacts. Pending invitations are separate from the calendar; accepting or replying “maybe” adds the event to the invitee's view. Only the owner can edit, cancel, or inspect the full attendee list. Time changes require a new response. Updates and reminders are persisted in the calendar inbox and also sent through the existing push service, subject to device notification permission. Reminder claiming prevents duplicate inbox entries across worker ticks. Calendar data belongs to the account and is removed by account/data deletion.

Choose a city, IANA time zone, Israel/Diaspora schedule and candle-lighting offset before displaying religious times. Hebcal's public REST API provides Hebrew dates, holidays, candle lighting and 8.5-degree nightfall. A second query adds the explicitly labelled fixed 72-minute Rabbeinu Tam calculation, including night-time candle lighting when holy days continue into each other. Responses are cached server-side for 24 hours, bounded to 128 date/location combinations. Only dates and location parameters are sent to Hebcal, never appointments or account identifiers. Failures display an availability message without suppressing personal events.

Events store UTC instants with their original IANA zone. Repeats preserve civil time across DST. Nonexistent and ambiguous event times are rejected with a user-facing explanation. All-day dates remain calendar dates across participant time zones. The client renders server-provided civil date/time values independently of the browser time zone.

## Validation

- Flutter analyzer: no issues.
- Calendar UI and conversation navigation tests: 12 tests covering desktop/mobile entry, day/week/month, overlapping events, creating an invitation, RSVP, and holiday-provider failures.
- Calendar server/database and account-deletion tests: 11 tests, including real PostgreSQL TEMP tables (no production rows written), access isolation, stale-version rejection, re-approval after rescheduling, cancellation, DST recurrence, all-day dates across the date line, reminder deduplication and account cascades.
- Live read-only Hebcal checks: Jerusalem and New York, Rosh Hashanah spanning Shabbat, plus Shabbat and Yom Kippur exit times.
- Broader Node suite: 534 passed, 15 skipped, 7 pre-existing failures. All seven were reproduced against HEAD versions of the application/server sources: blocked-image-without-guide-art, blocked-upload-recipient, conversation-scroll-lock (3), group-message-content-layout, self-group-web. These source-pattern checks are unrelated to the calendar.

## Deployment

`server/calendar.js` exports an idempotent additive schema applied after the existing startup migrations. No separate database credentials or external calendar connection is required. The reminder worker runs in the primary application process every 30 seconds. The existing Flutter web release process builds the client; no Android binary is included in this web release.

Source: https://www.hebcal.com/home/195/jewish-calendar-rest-api
