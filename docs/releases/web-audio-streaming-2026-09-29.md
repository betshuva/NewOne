# Audio streaming and filenames — September 29, 2026

Web deployment: `20260928211524` (UTC build identifier).

Audio players load the media URL directly, allowing the browser to buffer and
request byte ranges. They no longer download the entire recording into Dart
memory and encode it as a data URI before becoming playable. Saved progress
loads alongside media preparation. Source replacement retains its separate
player and generation checks, and media errors expose the retry control.

Private chats, group chats and media-library players display the original
filename above the controls. Long names wrap to two lines with a tooltip showing
the full name; missing metadata falls back to the URL filename without query
parameters. Per-user resume and native seeking remain available.

Validation:

- Six focused native Flutter tests passed; all four audio tests also passed in
  Chromium, covering source errors/retry, stale preparation, names, seeking and
  user-scoped progress across remounts and file changes.
- A compiled browser fixture served a 15,876,044-byte WAV at about 256 KiB/s.
  The player was ready in 957 ms. It sought to the middle and began playing with
  only 344,064 bytes transferred (about 2.2%), using a second HTTP range request
  starting at byte 7,929,856. Neither request needed to complete. Switching files
  and returning restored approximately 90.10 seconds without autoplay or errors.
- Two large existing live audio files returned HTTP 206 for a one-byte range,
  with the correct audio MIME type and total length; the recordings themselves
  were not downloaded for this check.
- Node suite: 1,064 passed, 231 opt-in tests skipped, zero failures. Release web
  build and both web deployment tests passed.
- Dart analysis reports only the two pre-existing upload-helper warnings at
  main.dart lines 2076 and 2094; no additional diagnostics remain.
- Live HTML, bootstrap and application JavaScript returned HTTP 200 over verified
  TLS and matched the deployed local SHA-256 values.
