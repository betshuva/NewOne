# Short user numbers in capture filenames

Each account has a database-assigned `short_id` (a unique PostgreSQL bigint identity). The migration fills existing accounts and the identity default assigns new accounts their number. Repeating startup does not change existing assignments. Deleted numbers are not reused. UUIDs remain the keys used by authentication, permissions, and relationships.

The authenticated profile and login responses expose the assigned number. Capture filenames prefer it for photos, videos, and voice recordings. PostgreSQL returns bigint values as strings, which avoids precision loss in the web client. A session still loading its profile can use its UUID temporarily; the upload API replaces a legacy generated filename's UUID with the authenticated creator's number before storing or returning the filename. The timestamp, collision suffix, and actual file extension are preserved, including MP3 conversion. Files belonging to a different creator and arbitrary imported names are preserved. Existing stored files are not renamed.

Validation covers repeatable migration and backfill, unique/non-null assignments, refusal of explicit identity values, non-reuse after deletion, creator-scoped legacy conversion, upload/storage/response names after MP3 conversion, and photo/audio capture in private and group chats. Database tests use temporary tables only.
