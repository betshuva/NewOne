# Messaging fixes — 6 September 2026

Client version: 1.3.16+236. Includes the earlier multiple-file Android sharing and Direct Share work.

## Changes

- Android launcher badge: FCM chat/group notifications now have conversation tags. After reading, opening the app, or refreshing conversation state, the client obtains unread counts and cancels only read notifications that predate the count request. A failed/partial response retains notifications. Ongoing call notifications are excluded. Legacy notifications are cleared only when there are no unread messages or contact requests.
- Screenshot moderation: an unresolved image category remains pending for another verification instead of reaching the final recipient-filter rejection. Explicit safety/modesty blocks remain in force. The previous clean-safety/modesty-disagreement path also requires a resolved category. Cache version was advanced, and destination-rejection records retain the complete verification provenance.
- The reported first/second screenshot attempts had different content hashes. Earlier destination rejection records omitted external-verification details, so the exact provider history of those old attempts cannot be reconstructed. This change fixes the uncertainty handling; it does not establish that every possible screenshot false positive is eliminated.
- Emoji reactions: six reactions with one per user per message, replacement/removal, persisted aggregate counts and own-selection state. API checks participants, active group membership, deletion, blocking and group content filters. Visible Flutter message widgets refresh counts every 15 seconds while the app is resumed.
- Self conversation: “הודעות לעצמי” is available in the conversation list, including before the first message. Text and approved attachments bypass contact-request creation, while moderation remains enforced. Own messages do not create unread counts or chat pushes.
- Voice questions to either built-in assistant use the approved audio transcript. Empty/unintelligible audio requests a new recording. Delayed scan approval also invokes the assistant and reconciles the pending outgoing message. Responses remain text; this is not a live spoken conversation or text-to-speech feature.
- Guide: a first-question screenshot bug report is handled as a bug rather than generic screenshot instructions. Feature knowledge includes self notes, reactions and voice questions.

## Validation

- Server suite: 294 passed, one opt-in database test skipped; two additional self-delivery route tests passed.
- Opt-in reactions PostgreSQL tests: 6 passed using TEMP tables inside a transaction rolled back afterwards. No production rows were changed.
- Flutter: incoming-share parsing/flow tests passed (6); notification reconciliation and reaction widget tests passed (5).
- Flutter analyzer: no issues.
- Release APK 1.3.16+236 compiled successfully (133.7 MB); apksigner verified its v2 signature and the packaged version was checked.

## Activation and device checks

The server update was activated on 6 September 2026 following explicit user authorization. The verified application process was sent SIGTERM under its owning user and systemd Restart=always started the new process (PID 3270599). Startup migration completed, all four backup workers reported ready, and read-only PostgreSQL checks confirmed message_reactions with its primary key, two foreign keys and emoji check constraint. Public app returned HTTP 200; the new reactions route and unread route returned the expected unauthenticated HTTP 401. The service remained active with no further restart during verification. Install APK 1.3.16+236 for Android/client changes. No app-store or web-client release was performed.

On an Android phone verify: read all chats and inspect launcher badge; retain an unread chat while reading another; receive a new message during a refresh; share multiple images/videos/documents; select a Direct Share recipient and confirm; react from two accounts; write/upload to self; send clear/silent/rejected/pending-scan audio to both assistants. Re-test the reported screenshot with its original bytes and inspect retained moderation details.

No connected phone/emulator was available, so these device checks remain outstanding. Support tickets were not marked resolved and no user notifications were sent.
