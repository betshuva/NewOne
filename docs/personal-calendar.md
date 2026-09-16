# Personal calendar

The fixed “לוח שנה” conversation entry opens a private calendar in the desktop detail pane or a full-screen route on mobile. Day/week timelines and a month grid support timed and all-day events, overlapping appointments, colors, notes, locations, and finite daily/weekly/Gregorian-monthly series (up to 104 occurrences). Editing or cancelling a series occurrence affects that occurrence only.

Friends can be invited from the owner's contacts. Pending invitations are separate from the calendar; accepting or replying “maybe” adds the event to the invitee's view. Only the owner can edit, cancel, or inspect the full attendee list. Time changes require a new response. Updates and reminders are persisted in the calendar inbox and also sent through the existing push service, subject to device notification permission. Reminder claiming prevents duplicate inbox entries across worker ticks. Calendar data belongs to the account and is removed by account/data deletion.

Calendar location defaults to an explicit saved calendar choice, then the profile city, then available automatic location, and finally Jerusalem. Defaults display holidays immediately. The location dialog uses the same searchable locality picker as profile/listing forms, without editable coordinates. A searchable IANA time-zone list allows a separate choice; changing a city fills its zone and Israel/Diaspora schedule, while preserving explicit overrides made before saving a typed city. Candle lighting uses a fixed 15-minute advance for every city. The server enforces this for existing saved preferences, location defaults and older clients; the preference field is removed. After-nightfall candle lighting between consecutive holy days follows the provider's calendar rules. Hebcal's public REST API provides Hebrew dates, holidays, candle lighting and 8.5-degree nightfall. A second query adds the explicitly labelled fixed 72-minute Rabbeinu Tam calculation, including night-time candle lighting when holy days continue into each other. Responses are cached server-side for 24 hours, bounded to 128 date/location combinations. Only dates and location parameters are sent to Hebcal, never appointments or account identifiers. Failures display an availability message without suppressing personal events.

Device location is used automatically only when permission is already granted. The current-location button can request permission; unavailable location keeps the Jerusalem fallback. Automatic defaults never overwrite an explicit calendar choice. City centers and time zones are resolved locally on the server using public data (data.gov.il, GeoNames, geo-tz), without sending the user's GPS coordinates to a geocoding API. A city that cannot be resolved gets an explicit error instead of saving stale coordinates.

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

Published web build: `20260916232130`. The calendar settings source migration is installed. Authenticated read-only checks of settings, city resolution and events returned HTTP 200; unauthenticated location access returned HTTP 401. Published index/bootstrap/application/icon-font hashes match the tested build.

Location update validation: 27 Flutter widget tests cover the shared autocomplete (including stale responses and Hebrew spelling aliases), city resolution, timezone selection with a mobile keyboard, preservation of manual overrides, permission/fallback precedence, and existing calendar navigation. The release web build and targeted Flutter analysis passed.

The location update also passed 12 server/account tests (including isolated PostgreSQL TEMP tables) and both deployment checks.

## Public location data

`server/data/calendar-locations.json` contains public city-center data from data.gov.il and GeoNames, with reviewed Hebrew aliases. Rows are `[name, latitude, longitude, countryCode, timezone, aliases, optionalGovernmentLocalityCode]`. The current snapshot resolves 1,192 of 1,285 official localities; unsupported/ambiguous names report an error. Automatic Israeli matching uses verified official locality rows. Coordinates are approximate city centers, not a user's precise stored position.

GeoNames data is adapted under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/); source URLs, snapshot date, and alias corrections are retained in the JSON. Government ITM centers are converted to WGS84. Time-zone boundaries use the server-only geo-tz package.

To reproduce a candidate snapshot, install build-only `proj4` outside the application, run `scripts/build-calendar-location-data.py` with explicit `--source-dir` and `--output`, then run `scripts/review-calendar-location-data.py` with that source directory plus `--input` and `--output`. The review pass asserts source record identities and stops if upstream names/coordinates changed; inspect those changes before replacing the committed snapshot. Neither script processes user locations.

Fixed candle-lighting update: direct Hebcal checks with `b=15` for 25 September 2026 returned Jerusalem 18:17, Tel Aviv 18:18 and Haifa 18:17. The same fixed parameter is used for the normal and Rabbeinu Tam requests.

Fixed-15 validation: 6 server tests including isolated PostgreSQL integration, 16 Flutter widget tests and both deployment checks passed; targeted Flutter analysis is clean. Live authenticated reads for two existing accounts returned fixed-15 settings and holiday data successfully; published files match the tested build, and the removed input label is absent from the deployed application.
