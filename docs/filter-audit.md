# Filter history and image chronology

`server/filter-audit.js` installs a durable audit ledger when the server's existing migrations finish. It records server timestamps, monotonic event IDs, database transaction IDs, viewer/actor IDs, scope, and optional message/file IDs. It does not copy message text, image bytes, media URLs, or raw classifier diagnostics.

The initial `filter_baseline` rows describe settings at installation. They are explicitly labelled `installation_baseline`; they do not invent timestamps for older settings or messages. New contact/group membership baselines likewise describe the initial state observed at creation/joining.

Database triggers save `filter_changed` in the same transaction as changes to general, contact, group, and group-member filters. The event contains previous and next JSON settings, including enforcement. Unchanged JSON creates no event. Authentication code sets the transaction-local `app.actor_id`; changes without that context retain an unknown actor instead of guessing. Audit rows reject normal SQL UPDATE and DELETE and do not cascade when application entities are deleted.

Image/video persistence records `delivery_persisted` with the effective receiving policy, general/scoped policy inputs, group filter where relevant, policy revision IDs, and compact classification. Group events follow the persisted per-recipient delivery summary; blocked members get `delivery_blocked_persisted`. These are persistence-time observations, not assertions that bytes were rendered. Shared viewer-row locks serialize these snapshots with preference changes. Group snapshots additionally lock the creator and group row and store the effective `groupPolicy` plus its revision IDs, so an in-flight send can be distinguished from a later group-policy change even when its old recipient plan allowed delivery. `image_classified` preserves scan-status/classification transitions independently.

Actual visual-content rejection branches call `recordFilterDecision` with the exact filter used, compact classification, reason code, source, and message/file IDs. They cover direct HTTP/socket sends, group sends and per-member delivery plans, recipient/group upload checks, and delayed scan decisions. Delayed rejections are recorded inside the existing scan-completion transaction. Decision-time policy snapshots and persistence-time snapshots remain distinguishable. Event IDs order allocation; transaction IDs and the linked policy snapshot explain concurrent operations rather than pretending allocation order is global commit order.

`POST /api/filter-display-events` accepts authenticated `displayed`/`hidden` browser reports for actual accessible image/video messages. It checks direct-conversation access, active group membership and join time, conversation clears, and personal/global deletion. It labels browser timestamps and visibility as client reports, not independently proven display. Reports are deduplicated for 24 hours per viewer/message/event and current server policy/history revision, with a maximum of 200 recorded display reports per viewer/day. A policy change, per-image hide/keep action, or restoration changes the dedup revision without requiring the browser to supply one. Flooded, missing, offline, or disabled clients therefore do not imply that no display occurred.

`GET /api/admin/filter-timeline` requires the existing admin authorization middleware. It supports `userId`, `messageId`, `fileId`, `limit` (maximum 200), and `before` (event-ID cursor), returning `{events,nextCursor,recordingStartedAt}`. Selecting an image also includes relevant policy baselines/changes and per-image history choices, allowing administrators to compare the snapshot used for delivery with subsequent changes. Pagination sorts event IDs descending. Responses are not cached.

## Verification

Run the focused unit and isolated PostgreSQL tests with:

```sh
RUN_DB_TESTS=1 node -r dotenv/config --test test/filter-audit.test.js test/filter-media-history.test.js test/self-conversation-delivery.test.js
```

Database tests create uniquely named isolated schemas and drop them afterward. They cover atomic rollback, idempotence, immutable snapshots, group delivery outcomes, two-client lock ordering, authenticated ownership checks, telemetry limits/restoration deduplication, and image timeline pagination. They do not modify application users, preferences, or messages.

## Existing-image choices

The four filter PUT endpoints (general, contact, group, personal group) use one transaction and an owner lock. When a proposed change newly blocks categories in received image history, a first save returns HTTP 409 `EXISTING_MEDIA_CHOICE_REQUIRED` and `affectedCount` without changing settings or recording a change. The web dialog resubmits the same settings with `existingMediaAction` (`keep`, `hide`, or `delete`); cancelling preserves the saved policy. General changes evaluate each conversation's effective policy, including enforcement changes. Scoped choices affect only that user's history in the selected conversation/group; a group administrator's choice never deletes other members' history.

`user_message_filter_actions` stores decisions for exact message IDs. `keep` therefore cannot exempt future images. `hide` removes media URLs from history/socket/library responses while retaining a placeholder. Explicit restore creates a per-image keep decision and a `history_restored` event. `delete` writes only the user's deletion ledger, cancels queued received copies, and removes unreferenced personal copies using the existing ownership/backup checks. Shared source files and other people's copies are preserved. Cleanup failures or files still referenced elsewhere do not restore deleted messages; any remaining received copy preview is hidden. `history_action`, `history_image_action`, and `history_cleanup` preserve the selected action and cleanup outcomes.

Personal history is re-evaluated on each read and live delivery. Received copies in My Media use the same decisions; ordinary conversation clearing still preserves files as before. Source policy failures fail closed; a failed personal-copy lookup can fall back only to an already-filtered source. Flutter clears old receiving-image state on local/socket changes, rejects stale history requests, and obtains fresh server history before presenting cached received images. Fullscreen previews close on preference changes. The private contact filter card displays the current effective filter.

The standalone web admin and the web app's existing admin screen expose the timeline. Browser observations remain client reports, not proof of human attention; recording starts at deployment and does not reconstruct unrecorded historical order.

## Deployed verification — 2026-09-17

Web release `20260916232412`; JavaScript SHA-256 `2fcee6d012cad0a5650d4eed14fdfd743a9793b9b26883b2867e7eb0ed8e47cf`. Public HTML/bootstrap cache keys and JavaScript bytes match the built and deployed artifacts. The application service was restarted and is active.

Authenticated loopback checks confirmed Aviv’s saved settings are unchanged, the reported male photo has no returned media URL and is marked hidden, its received-library copy is also hidden, the contact card now blocks men/women, and the admin timeline is available only with admin authentication. Recording began at `2026-09-16T23:21:29.795Z`. No user preferences were changed by validation.

Validation: 13 audit and 12 history database tests pass in isolated schemas; the wider focused backend run passed 66 checks before the final retained-copy additions, which passed separately. Flutter’s 54-test regression run and final 22-test library/history extension passed; 3 timeline widget tests and 8 standalone admin tests also passed, along with full Flutter analysis.

The broad Node suite is not fully green: its last run had 580 passes, 38 skips, seven pre-existing source-layout assertion failures, and one intermittent calendar fixture failure (the calendar file passed separately: 5 passed, 1 skipped). The new filter/history/audit checks pass. No Git operations or APK build were performed.
