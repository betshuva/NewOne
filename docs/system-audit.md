# System Audit

## Operator Views

The system audit is available from the administration screen in
Flutter (`SystemAuditScreen`) and from `admin.html` via `admin-audit.html`.
The existing filter timeline and activity log remain available.

Web and Android administrators with edit permission can select up to 200
individual records, select the displayed records, or delete the whole journal.
Every deletion requires confirmation. `GET /api/admin/audit/deletion-preview`
returns the count and root-event boundary for an all-journal deletion; DELETE
`/api/admin/audit/records` requires `DELETE_ALL_AUDIT` plus that boundary, or
`DELETE_SELECTED_AUDIT` plus explicit operation/event IDs. Account identity and
edit permission are checked on the server. A selected operation includes its
children; a selected child leaves other children intact. Root events cannot be
deleted individually. Selected batches are atomic. Whole-journal deletion runs
in atomic batches of at most 100 operations under the fixed root-event boundary,
leaving operations created beyond it and the deletion audit records intact.
If a later batch fails, clients report progress and require a refresh before
another attempt. Business messages, files and other data are unaffected.

The operations table expands into explicitly correlated events. A separate
all-events table supports investigations across operations. Filters include
date range, initiator UUID or short ID, action, category, status, target and
source. A target filter can match the root or an explicitly linked child event.
Changing filters refreshes the results. Rows use keyset pagination and
deduplication; automatic updates retain the applied filters and reading position.

The web operations view has separate Action and Sub-action columns. Each data
row repeats its primary action and shows the actual child event with its ordinal
(`1 of N`). There is no separate group heading row. Collapsing a group keeps its
first matching child event visible; expanding shows the remaining children
without duplicating that first row. Existing group colors and column width/order
preferences are retained. Operations without children show an explicit empty
state without inventing an event or ordinal.

The opt-in `steps=1` operations response includes `first_sub_event`, fetched for
the whole parent page in one additional query. Child responses with `steps=1`
include string-valued `sub_event_index` and `sub_event_total`, ranked by timestamp
at millisecond precision and event ID before filtering/pagination, excluding the
root event. Thus filtered rows retain their original positions. In this view,
`action` filters primary actions and `kind` filters child events independently.
The separate all-events view and existing API clients retain their behavior.

In the web audit, drag a column heading to reorder its header, width, and cells,
including expanded child events. Focus a heading and use Alt+Left/Right for the
same action with a keyboard. The order is stored in `audit_column_orders` for the
authenticated administrator, separately for operations and events, and loaded
on every visit from any device. The reset button restores the default order for
the current view. A visible status confirms server saves and offers retry when
loading or saving fails. GET `/api/admin/audit/column-order` and PUT
`/api/admin/audit/column-order/:mode` use admin authentication; users can only
change their own layout, including administrators with view permission.

Drag the left edge of a web column heading to resize it (48–1,200 pixels), or
focus its resize handle and use Left/Right in 10-pixel steps. Escape cancels an
active drag. Widths follow column IDs through reordering and apply to expanded
child rows too. They are stored per administrator and view in the
`column_widths` field of `audit_column_orders`, loaded with the column order,
and saved through PUT `/api/admin/audit/column-widths/:mode`. Reset widths
restores the current view's defaults without changing its order. A separate
save status and retry button report failures; automatic updates pause during
resizing. Run the existing schema initializer before serving the updated API.

The detail view includes operation and parent IDs, executor, reason code and
allowlisted metadata. CSV export uses the authenticated admin session, an
explicit date range of at most 31 days, and at most 5,000 rows. Truncation is
reported, and spreadsheet formulas are escaped. No tokens go into URLs.

### Scoped Administrator Deletion

The catalog returns `canDelete: true` only for an administrator with the existing
`edit` permission. Both deletion endpoints require the normal admin middleware,
an authenticated user, and that same edit permission on the actual request:

- `DELETE /api/admin/audit/operations/:id` physically removes the selected
  primary operation and all of its audit events only.
- `DELETE /api/admin/audit/events/:id` physically removes exactly the selected
  child event. Surviving descendants are not deleted; immediate children's
  `parent_event_id` becomes NULL, without inventing a replacement parent.
- The JSON body must contain `{"confirmId":"<exact URL ID>"}`. Invalid identifiers
  or missing/mismatched confirmation return 400; insufficient permission returns
  403, missing records return 404. A root event cannot be removed individually:
  this returns 409 `AUDIT_ROOT_EVENT`. Both event list APIs expose `root_event_id`
  so clients do not need to guess from an event kind.
- Success returns `{"deleted":true,"operationId":"...","deletedEvents":1}`,
  with the actual count. An operation deletion counts all removed events.

Deletion, identity markers, parent rewrites, projection rebuilding and a distinct
`audit_delete_operation`/`audit_delete_event` administrator action commit in one
transaction. Failure returns 503 and rolls back every change. The administrator
action records the authenticated actor, deleted audit identity and count, not
the removed content. These exact DELETE routes bypass generic HTTP audit-root
creation so failed requests do not create unrelated deletion roots. Other
auditing remains active. No files, messages, queue rows or other business data
are changed by these endpoints, including the audit IDs those rows already hold.

Ordinary UPDATE/DELETE/TRUNCATE guards remain active. A transaction-local scope
allows only the chosen operation, the exact child, that child's parent-link
rewrites and bounded projection fields. No triggers are globally disabled.
Surviving operation counts, status/source/reason and duration/latest timestamp
are derived from actual remaining events, including scan-outcome precedence.
Media/capture/recipient facts are cleared if their supporting `upload_context`
evidence is removed. Where matching evidence remains, the original authoritative
identity snapshot is kept; a renamed or deleted user is not looked up again.

`audit_deleted_operations` retains only deleted operation UUIDs;
`audit_deleted_events` retains only deleted event IDs and their operation UUIDs.
These identity-only markers contain no event content, names or timestamps. They
prevent already-running work from recreating deleted history or breaking future
business writes that still carry a deleted audit reference. Event inserts take
a shared transaction advisory lock per operation, while deletion takes the
matching exclusive lock. Only explicitly deleted operations suppress late audit
events; only explicitly deleted parents from the same operation normalize to
NULL. Unknown operation IDs and wrong-operation parents still fail foreign-key
validation. Deleted operation identities cannot be reused for a new root.

Deletion uses the application's normal PostgreSQL READ COMMITTED transactions,
a ten-second lock timeout and a thirty-second statement timeout. Timeouts are
errors, never partial success. Identity markers and the deletion record have no
new automatic expiry policy.

### Column Filters

List and export requests accept `columnFilters`, a JSON object limited to 16 KiB.
Each whitelisted column contributes an AND condition, in addition to the
existing top-level filters. Values within a column are ORed. Filters on a
displayed target column match that row's target by default, unlike the broader top-level
target filter that also finds a root through its linked events.

- Operations: `created_at`, `action`, `initiator_id`, `target_type`, `target_id`,
  `source`, `status`, `reason_code`, `event_count`, `duration_ms`.
- Events: `created_at`, `kind`, `executor_id`, `target_type`, `target_id`,
  `source`, `status`, `reason_code`, `attempt`, `operation_id`, `parent_event_id`.
- Both modes additionally support `check_type` and `check_outcome`. Operation
  filters match actual child check evidence, including in the default root mode;
  positive check predicates must match the same event. Labels are localized in
  facets and CSV includes the stable codes plus `checkLabel`/`checkResultLabel`.
- Both modes additionally support `media_type`, `capture_kind`, `recipient_type`
  and `recipient_id`. These fields always filter the operation context, including
  when `match=chain`; an unrelated child target is not an intended recipient.
- Text/identity columns use `{"values":["value",null],"exclude":false}` with at
  most 100 distinct choices. `null` is a database NULL, distinct from an empty
  string. An empty inclusion matches nothing; an empty exclusion adds no
  constraint. Exclusion retains NULL unless NULL itself is excluded.
- `created_at` uses timezone-qualified ISO `from` (inclusive) and `to`
  (exclusive). Either bound may be omitted.
- Counts, duration and attempt use inclusive `min`/`max` decimal strings, bounded
  by nonnegative signed bigint. This retains precision above JavaScript's safe
  integer range. UUID identities and positive bigint parent IDs are validated.

`GET /api/admin/audit/filter-options` accepts `mode`, `column`, optional literal
case-insensitive `search` (up to 100 characters), and the same filters. It
removes only the selected column's own filter and ignores pagination, then
returns up to 100 distinct values across the entire matching dataset:
`{"options":[{"value":"stable-id","label":"name / ID / stable-id"}],"hasMore":false}`.
Identity labels use recorded snapshots, including the initiator's short ID;
their values remain stable IDs. A NULL option has a NULL value. Date/numeric
columns use ranges, not distinct-value options. Pagination and CSV reuse the
same column predicates; CSV still requires its explicit top-level date range.
Action, status and event-kind options search both stable codes and their Hebrew
display labels. The catalog's `eventKinds` map shares these labels with clients;
unrecognized codes retain their original text.

### User Action Hierarchy

The primary clients request operations with `scope=user&match=chain`. API
defaults are unchanged: omitting both options retains the original operation
queries. `scope=all` and `match=root` are explicit versions of those defaults.

`scope=user` requires a recorded root event belonging to the same operation,
with an executor type of `user`, `admin` or `client` and an executor UUID matching
the non-NULL initiating user UUID. An owner/initiator field alone does not prove
a user initiated a worker or system task. Known automatic telemetry actions
`report_message_read` and `register_device` are excluded from this primary view.
This is evidence-based classification, not proof of a physical UI gesture;
instrumented actions without sufficient initiating evidence remain accessible
in the separate all-events view. No historical records are changed or inferred.

In `match=chain` operations queries:

- Top-level `action`, `category`, initiating user, operation dates, numeric
  counts and duration still constrain the primary operation. In particular,
  choosing top-level `action=upload_file` can be combined with a child-kind
  header filter such as `columnFilters.action.values=["scan_attempt_failed"]`.
- Header `action` matches either the primary action or a child event kind.
  Header and top-level status, source, target and reason filters match the
  primary operation or a child linked by its explicit `operation_id`. The
  exact `root_event_id` is excluded from child candidates to avoid duplicating
  the initial root event as a separate action.
- All positive common-column predicates must match the **same** candidate row.
  A failed scanner event cannot combine with the source or target from an
  unrelated successful storage event. Target type and ID remain paired.
- Exclusions are chain-wide: an explicitly excluded value anywhere in the
  root or recorded children removes that operation. A different passing child
  cannot neutralize the exclusion. NULL participates only when explicitly
  selected; empty inclusion matches nothing and empty exclusion adds no guard.
- Facets omit only their own column predicate. Common-column options come from
  compatible matching root/child rows, including localized child-kind labels.
  Other operation constraints and exclusion guards stay in force. CSV uses
  identical scope and matching semantics.

Opt-in operation responses and operation CSV add `sub_event_count`,
`latest_event_kind`, `latest_event_status` and `latest_event_at`. Child counts
are the actual recorded rows excluding only the exact root event, not an
expected workflow length or a count of completed work. Latest evidence is the
last appended child by event ID; fields are NULL when no child exists. Summary
aggregation runs only after selecting the bounded operation page. Historical
pending/running evidence is not interpreted as a currently active step.

Clients display separately expandable child rows with a stable operation-color
marker. Child requests retain their existing descending-ID cursor contract;
clients sort a copy of loaded evidence chronologically for presentation while
preserving the cursor and complete audit history. Color identifies the primary
operation, not the user or success/failure status. The finite palette can repeat
across operations, so identity is always also conveyed by the row hierarchy and
operation ID. Expanded-state and automatic-update behavior remain unchanged.

### Media and Intended Recipients

New uploads append an `upload_context` event after the server has validated the
recipient and restored request correlation following multipart parsing. Its
allowlisted details are `mediaType` (`video`, `image`, `audio`, `document`),
optional `captureKind` (`camera_video`, `camera_image`, `microphone`), and optional
`recipientType` (`user`, `group`) plus `recipientId` (UUID). The upload handler
must authorize the recipient before appending these details; the projection
trigger is not an authorization boundary.

The event trigger enriches nullable operation fields `media_type`, `capture_kind`,
`recipient_type`, `recipient_id`, `recipient_name` and `recipient_short_id`.
Recipient identity comes from server-side users/groups, not client-supplied
names or short IDs. The first known identity snapshot is retained, including
after a later rename/deletion. Recipient-less library uploads and old records
remain NULL. Flat and nested event responses inherit this operation context;
it is intended-recipient context, not evidence that each event delivered media.
Facets show the recorded name/short ID while filtering stable UUIDs, and both
CSV modes include these snapshots with their usual formula escaping.

Capture kind is an explicit report by the recording client and must agree with
the media type. A video file or a camera-like filename alone cannot prove a new
recording; clients label such rows as video uploads rather than recordings.
The stored primary action remains `upload_file` so existing action filters remain
compatible. No historical media/recipient links are inferred or backfilled.

`blob_upload_started` and `blob_upload_finished` describe actual transfers to
storage, not recipient delivery. Existing file, moderation, scan, message and
provider events remain separate evidence under their explicit operation IDs.

### Scan Results and Images

Both clients display each recorded check's purpose and result in separate
columns, with the provider, video frame number and sample timestamp when
available. Results contain allowlisted findings and bounded counts/confidence,
not provider prompts, raw replies, private transcripts or untrusted reasons.
Completion of one check is not approval of the entire file. Cached results,
skipped checks, provider failures and budget stops are explicitly distinguished.
Legacy checks with no recorded result say that the result was not recorded;
neither clients nor the API invent historical findings.

Actual provider calls retain their existing usage accounting. Local, cached and
preflight-stopped checks append semantic audit evidence without another charged
usage row or another provider request. These changes do not change scan budgets.

New image/frame checks can include a thumbnail of the exact input image, shared
by checks of the same frame. Clicking it opens a larger preview. The
image is re-encoded without metadata, at most 768 pixels per side and 512 KiB;
thumbnails are at most 120 by 90 pixels and 24 KiB. This is an inspection copy,
not an original-resolution download. Old records without a saved preview have
no thumbnail; audio and text-only checks have none either.

`GET /api/admin/audit/events/:id/preview?size=thumb|full` requires the existing
authenticated administrator with view or edit permission. The server resolves
the exact event, preview and source-file binding on every request. Images are
private database bytes, not public media URLs. Responses use `private, no-store`
and `nosniff`; clients fetch with the authenticated session rather than placing
credentials in URLs. Removing an event makes its preview URL unavailable.
Removing the source file cascades deletion of its preview bytes. Purging source
content also deletes previews, except rejected still images retained for
administrator review. Expired previews for other media are denied immediately
and removed in bounded periodic cleanup batches.

### Automatic Updates

Both audit clients poll while visible every five seconds after the preceding
cycle finishes. They pause for dialogs, exports, foreground loading, hidden
pages/application states and (in Flutter) covered routes. Failed cycles retain
the previous data and show a stale-data error, with retries backing off up to
60 seconds. Requests are read-only; polling never exports CSV or writes audit
events. Manual filtering, pagination, account changes and disposal invalidate
in-flight results.

A cycle refetches the loaded prefix, not only the newest page, so updated
statuses and rows entering/leaving a filter are reconciled. The original oldest
loaded boundary and opaque continuation cursor are retained; the last response
page is trimmed at that boundary. Fully loaded views continue through the end.
Open operations retain their expanded state and refresh their loaded event
prefix when their event count changes, including previously cached expansions.
Reading position is restored by a visible row anchor; readers already at the
top stay at the top. Unchanged data does not rebuild the table.

Each cycle is capped at 20 requests of at most 200 rows, including expanded
chains. An incomplete or over-budget cycle is not applied partially. Manual
refresh resets the loaded range to its initial page. These separate paginated
reads are eventually consistent, not a database-wide snapshot or a push stream.

## Data Model

- `audit_operations`: a projection of the root action, initiating user snapshot,
  target, media/capture context, intended recipient snapshot, outcome, event count
  and time span.
- `audit_events`: append-only evidence outside explicit administrator deletion,
  with an operation ID, optional parent
  event ID, millisecond UTC timestamp, actual executor type, source, outcome,
  reason, target, attempt and safe structured details.
- `audit_metadata`: recording start time. This is not a historical backfill.
- `audit_deleted_operations` / `audit_deleted_events`: identity-only deletion
  markers used to handle late asynchronous audit writes safely.
- `audit_scan_previews`: private bounded image copies, deduplicated per source
  file and input hash, accessible only through a surviving authorized audit event.

An event's composite foreign key requires its parent to belong to the same
operation. Root actions and their first event are created atomically. Events
update the operation projection. Ordinary UPDATE, DELETE and TRUNCATE are
rejected; the generic admin editor does not expose these tables. This is not
cryptographic protection against a database owner who can disable triggers.

User identity snapshots survive removal of the original user. Access and
retention must therefore be governed as administrative audit data; this change
does not implement automatic expiry or a new retention policy.

`duration_ms` is the span from the root to the latest recorded event, not CPU
time, request latency or time spent scanning. Event IDs order recorded inserts,
not global transaction commit order.

## Coverage and Causality

Authenticated HTTP mutations create a server-generated root before executing.
The response records the outcome of handling that request. If the audit root
cannot be persisted, the mutation receives 503 rather than silently proceeding
without a root. Read-only endpoints and filter-display telemetry do not create
request roots. Authentication activity is mirrored where existing explicit
activity logging exists; there is no claim to capture every failed login.

The primary private/group message paths (HTTP and socket), media uploads and
queued scan delivery persist explicit audit IDs on business rows. Database
triggers record file persistence/moderation transitions, queue insertion and
attempts/removal, message persistence and delivery summary changes in the same
transaction as those changes. Audit correlation IDs survive restarts and orphan
recovery, even when recovery creates a new queue row.
Legacy rows without audit IDs are not assigned invented history.

Pending processing restores the initiating operation from the queue, with a
worker executor. It clears any inherited upload context for legacy rows. A
transactional terminal scan event records completion or blocking before the
queue row is removed. A failed attempt does not imply the queued workflow has
permanently failed. A client disconnect is recorded as an unknown outcome, not
as evidence that business writes were rolled back.

Explicit filter decisions are forwarded transactionally. Filter setting
transactions propagate actor and audit IDs with `SET LOCAL`, never a persistent
pooled-session setting. Before/after filter metadata contains boolean policy
fields only. The existing filter timeline remains the detailed source for
legacy snapshots and client-reported display evidence.

Subsequent HTTP sends are separate actions from earlier uploads. Reusing a file
records a reference, not a claim that the new action caused the old scan.
Sibling events under a known request root do not assert dependencies on one
another. Idempotent private-message retries reuse the saved message result and
record a replay observation without creating another message.

File updates require explicit transaction-local correlation. A later untagged
rescan is not attributed to the file's original upload; its existing filter
journal/activity evidence remains separate. A terminal scan result also takes
precedence over a delayed HTTP response when updating the operation outcome.

Existing activity calls provide broader coverage of accounts, groups, backup,
support and administration. Those mirrors are explicitly observations and are
best effort, not atomic evidence for every business write. Known background
activities use a worker executor rather than attributing execution to the file
owner. Other uninstrumented background workflows remain outside complete causal
coverage. The API catalog exposes coverage rather than claiming a complete past.

## Outcome Meanings

- `message_persisted`: the database contains the message; not proof of delivery.
- `media_moderation_changed`: scan state changed; approval is not recipient
  permission or delivery.
- `server_message_status_changed`: the existing server status marker changed.
  In particular, the current online-user heuristic is not a device ACK.
- `push_provider_result`: FCM accepted or rejected requests; not device delivery.
- `http_response`: the server returned an HTTP outcome, not a recipient receipt.
- Provider calls, activity mirrors and response/push observations are best
  effort. Core business-row trigger evidence is transactional.

There is no new durable notification outbox or verified device/read ACK in this
change. A crash can leave a root with no final response observation. Operators
must inspect the recorded business events rather than assuming success or loss.

## Privacy and Access

All six `/api/admin/audit/*` GET endpoints and both DELETE endpoints require the existing `adminAuth`
middleware, including its current database permission check. Responses are
`no-store`. The page itself contains no private data without authenticated API
access. The journal stores names and IDs for audit identity, but not plaintext message bodies, recordings, transcripts, file URLs, access tokens,
email addresses or telephone numbers. Sending request context can now retain a
bounded encrypted attempted body and filename, so rejected sends remain inspectable.
Authenticated dispatch responses resolve linked business messages, decrypt their
text in memory and expose a 160-character preview with the full text available
on demand in the table. Existing records without message evidence remain unknown. Context IDs are generated or loaded by the server; client
headers cannot inject an operation ID. Details pass an explicit allowlist.

## Initialization and Verification

`startServer` calls `ensureSystemAuditSchema` after the business schemas and
pending queue exist, before recovery, workers and HTTP listening. Run the schema
setup before starting independently managed workers. Initializing the schema is
idempotent; it does not copy old events into causal chains.

Focused tests:

```sh
node --test test/system-audit*.test.js test/admin-system-audit.test.js
RUN_DB_TESTS=1 DATABASE_URL=postgresql://postgres@127.0.0.1:54320/audit_test DB_SSL=false node --test test/system-audit.test.js test/system-audit-column-filters.test.js test/system-audit-hierarchy.test.js test/system-audit-media.test.js test/system-audit-delete.test.js
cd flutter_app
flutter test test/system_audit_screen_test.dart
```

The database command assumes a disposable PostgreSQL instance is already
listening on the example port; replace it with the isolated test instance's
actual connection. Do not load production dotenv credentials for these tests.
The database tests create and drop a unique isolated schema; they must never
initialize the application's live schema as a test fixture. Browser checks use
synthetic intercepted API responses, including desktop/mobile table layout,
expanded events, safe details and export. Publishing the server/HTML or building
an APK is a separate release step; source changes alone are not a live rollout.

### Human-readable changes in the web history

The operation and event tables show context, before, after and a Hebrew
explanation beside the event. Each filter setting has its own before and after columns. False is a recorded
blocked value; a dash means that no value was recorded for that field. Status transitions use the recorded
previousStatus/nextStatus. A successful HTTP response is described separately
from a persisted business change; disconnected requests keep an unknown result.
These columns use existing audit details, without backfilling old history.
Their widths and positions are account-persisted, and older layouts gain the
new columns beside the sub-action while retaining existing relative order.

### Whole-operation outcome in collapsed rows

The web step view uses separate columns for authoritative operation status,
child status, outcome reason and reason code, including in the collapsed row. The `steps=1` operations API supplies
`outcome_event` and `scan_summary` independently of child filters and pagination.
A duplicate generic scan completion can use a preceding detailed completion of
the same outcome for its reason and provider-call budget. A later scan attempt
or an intervening different scan outcome prevents reusing that evidence.
Budget usage describes consumed provider calls, not successfully completed checks.
No audit history is rewritten and group colors, layout and collapse are retained.

### Separate initiator and executor identities

Both web views have independent initiator and executor columns. Operation rows
use the parent's recorded initiator and the current child's recorded executor.
Names, identifiers and executor type each have their own columns. The action
cell contains only the action name.
Recipient identity remains separate; missing initiators are never inferred from
the executor or recipient. System executor api is labeled as the server.

The operations API accepts executor_id filters/facets/sorting on child events;
events accept initiator_id from the parent operation. First-step and expanded
queries retain initiator filters on the parent rather than rewriting them to
executor filters. Old saved layouts gain the missing identity column adjacent
to the existing identity column, retaining widths and existing relative order.

### Minutes and seconds in the web history

Elapsed time is measured from operation creation to each event. Total time uses
the operation's recorded duration_ms (through the last recorded event, including
waiting), independently of child filters or loaded pages. Both operation and
event views show these separately. The total has its own column and remains visible when collapsed. This is recorded time, not a live stopwatch.

Display uses total minutes and seconds (02:35, 60:00), with <00:01 for positive
subsecond durations and 00:00 for exact zero. Missing/invalid data is a dash.
Bigint duration strings are formatted without floating-point loss. Total-duration
filters accept minutes:seconds, optionally .SSS, and send millisecond bounds to
the unchanged numeric API. Saved legacy bounds keep their subsecond precision.
Old column layouts gain the new elapsed/total fields beside the existing total
field or details, without resetting saved widths or existing relative order.

### One value per web table column

Both views use stable column schemas, with a single recorded value per data
cell. Operation/event/parent identifiers, attempt, target
type and identifier, recipient name/type/identifier, actor names/identifiers,
HTTP response code and affected-record count are separate. Selection, preview,
findings and row actions are utility columns. Detailed check findings remain
available in a dedicated dialog, while outcome, provider, frame index/time,
cache use, person/face counts and confidence each have independent fields.

Global events receive current_operation_status/reason_code/status_source from
the parent operation. These are distinct from the stage's own status and the
historical operation_status recorded by that event. Scan call usage and limit
are displayed separately: the step view uses the operation's matching outcome
evidence, while the event view uses that event's recorded budget snapshot.

The browser inserts newly added fields without changing the relative order of
existing saved columns. Widths remain keyed by the original IDs. The server
accepts complete older layouts and adds the new columns, while rejecting
unknown IDs, duplicate IDs and missing required legacy fields. No historical
records are changed or duplicated by splitting the display columns.

### Filtering the displayed action

The web action column filters by `display_action`, derived from the same recorded
action/media/capture fields used by its cell label. Captured video, captured
images, microphone recordings and selected media uploads are distinct values.
This parent-level filter works in operation and event views, including search,
multiple selections, exclusions, sorting and CSV exports. Unknown media context
retains the generic upload label; incompatible capture/media fields do not imply
a camera recording. Existing raw `action` filters keep their original meaning.
Column IDs, saved ordering/widths, recorded data and group colors are unchanged.

### Filtering and sorting every data field

Every data header now maps to a validated server filter and sort key; preview,
findings and action buttons are utility headers. Added fields include separate
identity IDs, operation/stage status and reasons, counts, attempt and parent IDs,
provider/frame/cache metadata, and each recorded before/after setting. Numeric
columns use ranges; elapsed, frame and total times accept minutes:seconds with
optional fractions. Enum facets show the same translated labels as the table.

Operation-level status, reasons and scan budgets use parent evidence independently
of child filters. Step predicates intersect on the same child; numbering counts
the full operation before filtering. Sorting a new step field orders groups by
their first matching displayed step. Sorting enum/reason fields uses the displayed
label, and existing cursor tie breakers and page limits remain in force. Missing
or malformed numeric metadata becomes an empty value rather than a query error.
Historical records and column layout storage are unchanged.

### Timestamp display

Local timestamps in both table views, recording-start metadata and the last
update indicator use `DD/MM/YY HH:mm:ss.SS`: 24-hour time and two fractional
digits. Hundredths are truncated from stored milliseconds without rounding into
the next second or date. Storage, API/CSV timestamps, date-filter precision and
elapsed/total duration formatting retain their existing representations.

### Expanding a complete operation

Opening an operation follows all child-event cursors automatically, in batches
of up to 200, until the server reports the end. There is no manual child pager
or displayed-row limit. Filters, sorting and original ordinals remain applied.
The complete result is committed together; a failed or stalled cursor chain
shows a retry action instead of presenting a partial chain as complete.
Collapsing an operation or all operations cancels pending child loads.
Automatic refresh also reads the complete expanded chain when its event count
changes. Main operation/event-list pagination remains independent.

### Combined step column

The operation view combines ordinal and total in one `שלב` column, for example
`1 מתוך 136`. Its stable layout ID remains step_index; the old step_total header
is removed without resetting other columns or saved widths. Old tabs can still
save their layout and legacy widths. The combined filter dialog selects either
step index or total, with numeric bounds and ascending/descending sort actions.
Server predicates and original ordinals remain separate and unchanged.


### Sending and delivery evidence (web)

The web requests `dispatch=1` in both audit views. Each operation has independent
columns for sending state, non-send reason/code, delivery state, recipient counts,
message type, content, filename and message ID. A separate recipient-details
button shows the group's accepted and blocked members and recorded reasons.
Every scalar data column supports server filtering and sorting; content filters
and sorting use the same 160-character decrypted preview displayed in the grid.
The full text is available through the content button. New column IDs migrate
into saved layouts without resetting existing order or widths.

`system_audit_dispatch` is a read-only projection, independent of child-event
filters. HTTP 200, successful scans and push-provider acceptance never prove
sending. A linked message row means saved for sending on the server, not a
verified recipient-device delivery. Existing `message_status.delivered` is
explicitly labelled as a server marker; `read` is labelled as a reported read.
Group counts describe the persisted distribution plan, never device receipts.
A missing distribution plan or missing historical source stays unknown.

Message links are taken from explicit message event IDs, including replay IDs.
An upload can resolve a later send only through the exact stored file, sender,
explicit destination and a message created after the upload. Another recipient's
forward is not borrowed. Guide filter notices are excluded. Existing snapshot
recipient names are retained; missing historical names resolve from the recorded
recipient ID and current user/group record, without guessing from the actor.
Future sending roots snapshot the validated recipient through the existing audit
projection. System broadcasts expose the actual persisted recipient list.

Future HTTP/socket rejections retain a bounded server explanation and code.
Socket denials for nonmembers and administrator-only groups are now explained.
Group delivery plans retain the applicable group/member policy reason. Historical
rows cannot recover explanations that were never recorded and say so explicitly.

The dispatch projection does not rewrite old events or business messages. The
normal admin authorization and `no-store` handling apply. For sorting/filtering
content, decrypted previews are passed as a parameterized request-local JSON map;
plaintext is never written back into tables. The same process handles encrypted
attempted filenames. Values in cells and detail dialogs are rendered as text.

### Blocked image previews

Rejected still images retain their bounded scan preview for administrator review
in the system audit. The original file and the
uploader's temporary preview still expire after two minutes. Public media access
remains blocked. The administrator preview requires an authenticated view/edit
administrator, uses no-store headers, and is fetched with bearer authorization.
Deleting the stored file or account deletes the scan preview through its foreign
key. Historical images already purged before this change cannot be recovered;
their rejection reason remains visible with an unavailable-image placeholder.

### Representative image in the web audit

The web client requests `previews=1`. List responses attach `operationPreview` in
one batch query for the returned operations. Every step shows the same source
image; video operations always show frame index 0, even when another frame's
provider calls finish earlier. Non-check steps and collapsed operations show the
same image. Selection is independent of step filters and pagination. The modal
caption identifies the uploaded image or first video frame, not the current
check's frame. Individual check evidence and authenticated event preview URLs
remain unchanged. Missing/deleted first frames are never replaced with later
frames presented as the first.
