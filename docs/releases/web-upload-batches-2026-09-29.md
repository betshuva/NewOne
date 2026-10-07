# Upload batches and two-minute video

Web deployment: `20260929201500` (UTC build identifier).

Private and group chats accept up to 100 attachments per selection. Image-only
batches keep two uploads in flight; mixed selections send one file at a time.
Selections above the limit show a notice and process the first 100 files.

The sender sees `מעלה N קבצים` at the start and `סוף העלאת N קבצים` when the
queue finishes. These are local conversation notices, preserved in chronological
order during history refreshes. They are not sent to other participants or saved
as server messages. Individual failures and pending scans retain their existing
reporting; queue completion does not mean every file was accepted. Unexpected
queue interruption displays an interruption notice instead of completion.

Web video recording stops at two minutes and displays a minutes/seconds
countdown. Upload validation, the Node server and the video moderation service
use the same 120-second limit. The 50 MiB video size limit and content checks
continue to apply. The in-app guide describes the updated limits.

Validation:

- 15 Flutter tests passed for batch boundaries, history reconciliation, mixed
  attachments and 101-file selections in both private and group chats, including
  actual queue concurrency and completion timing.
- Four Chromium camera tests passed, including recording, the 02:00 countdown,
  preview continuity and manual stop.
- Eight Python video-service tests passed, including 120/121-second boundaries
  with both known and missing duration metadata.
- Node suite: 1,073 passed, 233 opt-in tests skipped, zero failures. The guide and
  web-camera checks also passed after the guide text update.
- Targeted Dart analysis has only existing diagnostics: two upload-helper
  warnings and one brace-style suggestion in the attachment format parser.
- Release build and both deployment checks passed. Public HTML, bootstrap and
  application JavaScript returned HTTP 200 and matched local SHA-256 hashes.
  The restarted backend returned HTTP 200; the running video service reports a
  120-second limit and a healthy status.

Deployment scope: web, Node backend and local video moderation service.
# Completion order correction (2026-10-01)

Completion notices now persist the batch's upload request IDs and delivered
message IDs. History refreshes place the notice after the last matching file,
including pending, rejected and subsequently delivered media, regardless of
device/server clock differences. The server exposes upload IDs only to their
owner. Old completion notices can recover their position when every batch
member is identifiable from request timestamps; incomplete matches retain the
original chronological placement.
