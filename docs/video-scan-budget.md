# Video Scan Budget

Video moderation uses a durable PostgreSQL ledger, independent of queue rows
and stored-file deletion. The canonical identity is the uploader ID plus the
SHA-256 of the actual video bytes. A policy-version change does not grant a new
allowance, except for a provably unstarted, zero-request OpenAI credit preflight
stop when explicitly changing to a policy that no longer requires OpenAI.

## Limits

After local decoding, freeze the ordered JPEG hashes and timestamps for the
actual selected frames: start, middle, end, and each five-second interval.
Duplicate indices are scanned once; scene changes add no extra samples.
Require the reported sample count to match the manifest. At most 90 frames are accepted; invalid or
oversized manifests stop before any paid provider request.

For N selected frames, maximum attempted operations are:

| Provider | Operations per frame | Limit |
| --- | --- | --- |
| Google Vision | SafeSearch, objects, faces | 3N |
| OpenAI | Person classification, modesty | 2N |
| Gemini | Modesty | N |
| All providers | | 6N |

These are ceilings, not a requirement to run every operation. Reservations are
committed before HTTP requests and count failures, timeouts and unknown results.
One operation per frame/provider/type is allowed. Successful operation results
are reusable; Gemini format repair is disabled for budgeted videos. Reuploading
the same bytes or adding another destination never replenishes the allowance.
This limits request counts, not a fixed currency amount: token use and provider
pricing determine actual charges.

### Optional OpenAI

With `MODERATION_OPENAI_REQUIRED=false`, OpenAI stays enabled, but Google Vision
and Gemini can complete a scan when OpenAI is unavailable. Healthy OpenAI person
reviews still run; an unavailable or unresolved result uses one Gemini person
review as fallback. A frame that used that fallback skips the additional OpenAI
modesty request. A stored credit suspension is respected, not cleared or retried.
Guide and information-chat configuration is unchanged.

This policy freezes `google_gemini_optional_openai` in the ledger. Its caps are
3N Google Vision, 2N OpenAI, 2N Gemini, with an overriding **6N total**, not 7N.
The two Gemini operations are person presence and modesty. Failed OpenAI calls
still consume their reservations; their confirmed failure is cached, never
retried or refunded. An unknown in-flight call remains a terminal recovery stop.
Only known failed optional OpenAI operations may remain in a completed scan.
Gemini/Google failure, uncertainty and the original deadline/cap remain enforced.

Old spent ledgers never gain allowances. Only old required-OpenAI ledgers stopped
for `credit_balance_exhausted`, with no manifest, zero usage, no operation rows
and no unknown legacy activity, may transition on a new upload. The same ledger
ID and original stop are retained in `policy_history`; concurrent requests can
acquire it only once. Already stopped uploads are not automatically resent.

`MODERATION_OPENAI_ENABLED=false` is a separate explicit disabling mode, with
5N total (3N Google and 2N Gemini). It is not needed for optional OpenAI and is
not enabled by the optional-mode rollout. Default configuration retains the
original required-OpenAI policy. Cache versions include the provider policy.

## Completion And Failure

The processing deadline is five minutes from first acquisition, excluding queue
wait. A 30-second lease is renewed every ten seconds. After restart, completed
operations may be reused within the original deadline; unknown in-flight
operations cause terminal failure rather than a potentially paid retry.

Required-provider failure, credit exhaustion, deadline expiry, invalid manifest,
unknown historical spending or unavailable budget persistence stops the scan.
The stored file becomes `moderation_status='stopped'`, is removed from the queue,
is not delivered and cannot be downloaded as approved media. A final successful
request exactly at the cap may complete normally. Live duplicate workers wait
for the canonical scan instead of opening another budget.

The chat displays the stop reason and used/allowed operations. Audit events
record the stop and per-provider counts. Existing videos with unaccounted prior
attempts are conservatively stopped; historical charges are never reconstructed
by treating missing records as zero.

## Provider Suspension

An OpenAI `credit_balance_exhausted` response persists a suspension associated
with the SHA-256 of that credential. It blocks subsequent OpenAI calls. Under
the required-OpenAI policy it also preflights new video scans before they spend
on other providers; optional OpenAI does not stop the other providers. No API key is stored in
the ledger. Requests already in flight cannot be refunded or recalled.

There is no automatic suspension reset and no automatic video-budget refill.
Restoring account credit alone does not restart stopped videos. Provider
clearance requires an explicit administrative action; changing models, deleting
queue rows or deleting a stored file is not authorization for extra attempts.

The server-local clearance command defaults to a read-only dry run:

```sh
node scripts/clear-moderation-provider-suspension.js --provider openai --actor ADMIN_UUID --reason credits_restored
```

Only add `--confirm` after verifying the account is funded. The actor must have
current administrative edit permission. Clearance and its audit event commit
together, and the command never changes any video's allowance or stopped state.
It reads credentials from the same environment files as the server; do not pass
an API key on the command line.

## Verification

All provider HTTP calls in automated tests are mocked. Ledger integration tests
require `VIDEO_SCAN_TEST_DATABASE_URL` pointing to a disposable PostgreSQL
database. They cover concurrency, independent-process restart, immutable frame
selection, exact caps, failures, fixed deadlines and persistent suspension.

## Deployment

On 2026-09-25, the backend enabled `MODERATION_OPENAI_REQUIRED=false` while
leaving both OpenAI enable flags unchanged (enabled). Guide/information chats
were not modified. The optional-provider schema and caps were verified on the
live database using read-only queries, and the public version endpoint returned
HTTP 200 after restart. No stopped uploads were automatically requeued.
Validation: 985 ordinary Node tests passed (156 opt-in tests skipped), and 87
focused tests passed, including the disposable-PostgreSQL ledger tests. The
existing Gemini model's availability was checked with a read-only model lookup;
no live paid scan was run as a test. This backend rollout requires no new APK.

Published web build `e6af6e57666c2186` on 2026-09-25. The public HTML, bootstrap
and JavaScript returned HTTP 200 and matched the built SHA-256 values. Backend
startup created the three ledger/suspension tables and returned HTTP 200 from
the version endpoint. No live provider requests were made for verification.

Validation: 905 ordinary Node tests passed (137 opt-in tests skipped), 77 focused
PostgreSQL integration tests passed against a disposable database, and 18 Flutter
widget tests passed including phone and desktop layouts. Targeted Flutter
analysis and the web release build passed. Android APK remains 1.3.32; the
server-side quota protects requests from existing APKs, while the new stopped
card is included in the published web build.

### Frame sampling

New video scans use the first, middle and last decodable frames, plus targets every
5 seconds. Overlapping targets share one frame. At least three distinct decodable
frames are required. Scene changes no longer add samples. The manifest is frozen
before provider calls; completed scans retain their existing evidence.
