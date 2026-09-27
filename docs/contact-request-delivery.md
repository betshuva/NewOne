# Private sends before contact approval

HTTP and Socket private sends use the same contact request queue for text,
stickers, images (including GIFs), video, audio, and documents. Shared contacts,
locations, and links use the normal text path. Earlier message history and a
marketplace inquiry do not bypass the recipient's current contact approval.
Official assistants and self-conversations retain their existing behavior.

Safety/moderation, source-file access, account blocks and teen restrictions
remain prerequisites. For a noncontact, a safe upload is not rejected by the
recipient's provisional defaults: the request waits for their explicit choice.
The background scanner atomically transfers approved media from pending_scans
to message_requests instead of rejecting it for missing contact approval.

Accepting a request resolves every pending item from the sender using the selected
filter capped by enforced general preferences. Every attachment is checked against
its actual stored type, current safety state and sender access. Only allowed items
are persisted as messages and emitted to the recipient. Other items remain as
sender-only rejected request history with an exact reason and code. Text/audio and
nonhuman-image defaults still follow the existing content-filter policy; this
change does not introduce new filter switches.

Decline resolves all pending items from that sender with contact_request_declined.
A per-direction transaction lock serializes queue insertion and decisions. File
request retries reuse the same pending item; HTTP clientMessageId remains
idempotent. Concurrent acceptance cannot duplicate messages. Request content uses
the existing encrypted message-at-rest adapter.

Web history and real-time refresh distinguish awaiting_contact_approval,
rejected_request and actually sent messages. Forwarding counts a pending request
as pending, never as a completed delivery. The system audit projects the current
request state and the accepted message association, retaining rejection reasons.
Media-deletion previews count only active pending requests.

Previously rejected attempts are not re-sent during deployment. The sender must
initiate a new send if they want to retry one. No existing contact settings or
business messages are modified by the schema upgrade.

Validation uses disposable PostgreSQL schemas and local Flutter/widget fixtures.
Production verification is read-only (GET and read-only SQL), with no test messages
sent to users. Release scope is web plus its server; no Git actions or APK build.


## Recipient-only sending policy

Sending to another private account or group no longer applies the sender's own
receiving/viewing category preferences. Both transports, immediate/cached uploads,
contact-request approval and background scans use the destination's policy.
Group-level restrictions and each recipient's settings still apply. The stored
file type, rather than a client-supplied label, determines the policy and message
type. Safe shared GIFs can wait for contact approval just like other attachments.

Personal history/media viewing, profile/standalone media and self-conversations
retain their existing filters. Moderation, file ownership/access, recipient blocks,
teen restrictions and group membership/send permissions remain enforced. No
previously blocked attempts are automatically sent again. This is a server-side
web update; it requires neither new web assets nor an APK build.
