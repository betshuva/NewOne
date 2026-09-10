# Received media ownership

Delivered attachments are retained in each recipient's personal media library.
`server/received-media.js` owns the schema, migration, worker and message URL
resolution. The worker runs on the API process; approved copies enter the
existing personal Drive backup worker under their recipient's own key/settings.

- A message trigger records private recipients and the group's approved
  `delivery_summary.deliveredTo` recipients. Pending contact requests and
  destination-filtered group members do not create receipts.
- Existing visible delivered history is queued once. Authorized history reads
  also cover older group messages and accepted invitations after filtering.
- A SHA-256 hash identifies exact file contents. `personal_media_content` has
  one canonical file per user/hash; another delivery reuses that file, including
  an existing owned upload. Messages themselves remain separate.
- New copies have separate paths and `stored_files.user_id`, with
  `context_type='received'`. Deleting a source, group or message does not cascade
  into a ready personal file. Generated guide spreadsheets keep private routes.
- Only approved source bytes are copied. Existing classification is retained;
  copies do not enqueue shadow scans or inflate scan statistics. A global
  rejection propagates to received copies with the same hash. A rejected
  personal URL never falls back to its original approved source URL.
- Normal conversation cleanup keeps files and queued receipts. Explicit media
  deletion cancels queued receipts and records a media deletion cutoff, including
  for a delayed transaction that commits after the clear. Ready copies cannot
  be deleted while another visible personal conversation uses them.
- Canonical hash locks and owner locks protect concurrent saves and cleanup.
  Failed reads use persistent backoff. Ready/deleted receipts are never
  automatically recreated by a subsequent history read.

The sender's original URL remains protected by existing references while a
recipient copy is pending. History uses the recipient's personal URL once ready.
An already received local file is independent of Drive connectivity; automatic
Drive backup requires the recipient's connected account and enabled settings.

Run isolated database/file regression tests with `RUN_DB_TESTS=1` and the usual
database environment using `node --test test/received-media-db.test.js
test/received-media-library-db.test.js test/conversation-history-db.test.js
test/conversation-media-delete-db.test.js`. Tests use isolated schemas or
temporary tables, temporary files, and mocked cloud operations.
