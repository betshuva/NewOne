# Automatic local media release after verified Drive backup

Media referenced by messages, recipient copies, profiles and other application
content can now release its local bytes. Logical file records, URLs, messages,
ownership, filters and permanent-deletion guards remain intact. Existing public
media and authenticated generated-document readers restore content from Drive.

The automatic worker runs every ten seconds and drains full batches with a short
delay. Candidates require enabled automatic backup, a connected account, a
server-managed key, matching content hashes, successful restore verification,
approved moderation and no pending scan. Before each unlink the worker downloads
the encrypted backup afresh, validates its checksum, decrypts it and validates
the plaintext checksum and size. Database locks recheck eligibility; an update
failure restores the local bytes. Failed cloud checks retain local files and
defer retry for five minutes.

Turning off future automatic backups no longer disables delivery of files already
in Drive. Media delivery supports normal, open-ended and suffix byte ranges;
temporary playback caching stays encrypted and retains its existing expiry.
The backup status endpoint uses the same eligibility conditions as the worker.
Web settings describe automatic release and opening media from the cloud.

Validation:

- Full Node suite: 1,079 passed, 234 skipped, no failures.
- PostgreSQL tests in temporary tables: 20 passed. Includes active references,
  opt-out, disconnected accounts, pending moderation, missing/corrupt backups,
  wrong encryption keys and rollback after unlink.
- Flutter media/storage tests: 50 passed.
- Drive delivery test verifies full content, HEAD, ranges, encrypted cache reuse
  and rejection of corrupted content.
- Live canary: released one existing file, opened its original HTTPS URL and
  matched the downloaded SHA-256 to its stored content hash.
- Initial release cohort: 570 files, 859,740,570 bytes. Each is verified from
  Drive before its local copy is removed.

Snapshot of the initial cohort is stored privately at
`/tmp/newone-auto-release-before.json` for verification during this rollout.

Rollout completed: all 570 cohort records have `released_at`, and none of their
local paths exists. Released source bytes total 859,740,570 (819.9 MiB); no files
were deferred for failed verification. Original public URLs for an image,
document, audio recording and video returned bytes matching their stored SHA-256;
audio/video suffix ranges also passed. Web build `20260929213602` was checked
against the live index, bootstrap and JavaScript bytes. Backend remains active.
