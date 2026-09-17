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

## Personal library and forwarding — 2026-09-17

- The library groups approved, unpurged files with identical SHA-256 contents
  and media type within one owner before pagination. Different resized bytes,
  files without a verified hash, and pending/rejected records remain separate.
  Destinations and protection references include every copy. `duplicateIds`
  records the owned copies; `storageBytes` includes the physical bytes still
  stored. Grouping itself does not remove files or change existing messages.
- `PATCH /api/media-library/:id` accepts `{name}` and returns `{item}`. It changes
  the owner's names for the grouped copies, preserves the extension, and leaves
  paths, URLs and past message filenames intact. Name search matches all member
  names before a rename as well.
- New uploads reuse an owned, approved, unpurged local exact file only when its
  completed moderation result matches the current version. Sender and recipient
  filters still run for every attempt. Listing and other uploads stay separate
  because their cleanup rules differ. `upload-reuse.js` serializes identical
  requests in the current single API process; multiple API processes would need
  a shared lock. Cloud-only files cause the supplied bytes to be stored again
  instead of relying on a potentially disconnected cloud account.
  Pending/rejected attempts keep the existing scan workflow.
- Recipient search and selection live in persistent modal state, with user/group
  ID namespaces. Search, keyboard and window changes preserve checked targets.
  A source item loses selection only after every chosen target accepts it.
- Media selection stores item snapshots across filtering, pagination and
  grid/list/table changes. Approved files can be forwarded even when protected
  from deletion. Account and receiving-filter changes invalidate selection.
  Explicit group deletion confirms the copy count and uses the guarded deletion
  endpoint for every copy; partial failures retain the remaining selection.

Focused verification includes `test/upload-reuse.test.js`,
`test/media-library-catalog-db.test.js`, `test/filter-media-history.test.js`,
`flutter_app/test/incoming_share_flow_test.dart` and
`flutter_app/test/personal_media_screen_test.dart`.

Validation for this update: 118 focused Node/DB tests passed, including upload
reuse, library grouping/rename, receiving filters, retention and guarded deletion.
All 29 forwarding/media widget tests also passed on Chrome; scoped Flutter
analyzer reported no issues. Web release: `20260917143835`.
