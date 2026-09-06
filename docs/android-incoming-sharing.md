# Android sharing into Betshuva

Implemented for app version 1.3.15+235.

## Behavior

- Android registers both `ACTION_SEND` and `ACTION_SEND_MULTIPLE` with `*/*`, so gallery/files apps can offer Betshuva for single, multiple, and mixed selections.
- Native code combines and deduplicates `EXTRA_STREAM` and `ClipData` URIs, copies content streams off the UI thread, and preserves the name and MIME type of each file. Unreadable items are reported while the other items remain available.
- A queue holds incoming shares until the authenticated Flutter screen consumes them, including cold starts and shares received while another share is being handled. Launch intents are consumed once.
- All selected files enter one destination/confirmation sheet. Each uses the existing upload, content scan and recipient/group filters. A rejected, failed or pending file does not stop the rest of the batch; results distinguish delivered and pending items.
- Direct Share publishes up to four recent private conversations on Android 10+. A selected contact is validated against the current account and fresh destination list, then preselected in a confirmation sheet. No content is sent until the user confirms. Removed contacts and logout remove suggestions. Android determines whether and where suggestions appear.
- Copied files are removed after handling/cancellation. Files left by an interrupted session expire after 24 hours on a subsequent launch.

## Formats and limits

The existing server allowlist still applies: JPEG, PNG, WebP, GIF; MP4, WebM, MOV; PDF, DOCX, XLSX; and supported audio formats. This change does not make every arbitrary document format acceptable to the server. Native imports cap individual files at 50 MB and selections at 100 files, with visible errors; the existing server may enforce lower limits by format.

## Verification

- `flutter analyze --no-pub`: no issues.
- `flutter test --no-pub test/incoming_share_test.dart test/incoming_share_flow_test.dart`: 6 passed. Covers multi-photo order, mixed MIME types, text-only input, wrong-account and stale targets, confirmation before sending, and continuing after pending/rejected uploads.
- `node --test test/content-filter-policy.test.js test/conversation-scroll-lock.test.js test/blocked-upload-recipient.test.js`: 50 passed.
- Debug and release APKs compiled. Release APK version 1.3.15+235 passed apksigner verification; inspected packaged manifest and share-target resource for `SEND`, `SEND_MULTIPLE`, wildcard MIME and shortcuts metadata.
- Release artifact: `flutter_app/build/app/outputs/flutter-apk/app-release.apk` (approximately 133.6 MB). Not published or installed on a device.

No device is connected to ADB. These device checks remain necessary after installation:

1. Gallery: share one image, then two or more images; verify the item count and destination confirmation.
2. Share multiple videos, multiple PDF/Office documents, and a mixed selection from Files; verify every supported file arrives or is explicitly reported pending/rejected.
3. Repeat from a closed app, foreground app, and while a prior confirmation is open. Repeat after signing in when the app initially opens at login.
4. Open Betshuva with recent conversations, then use Android's share sheet to select a Betshuva contact. Verify the chosen recipient is preselected and nothing sends before confirmation.
5. Cancel, remove/block a contact, and sign out/switch accounts. Check stale suggestions cannot send to the former account's recipients.
6. Verify a failed or unreadable item doesn't suppress the remaining items, and files awaiting moderation are delivered only via the existing approval process.

References: [Android receiving shares](https://developer.android.com/develop/ui/compose/sharing/receive), [Android Direct Share](https://developer.android.com/develop/ui/compose/sharing/direct-share-targets).
