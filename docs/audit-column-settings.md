# Audit column settings

The **הגדרות עמודות** button opens a searchable, numbered list of the current
view's columns. Moving a column to position 1..N shifts all intervening columns;
positions are always unique and contiguous, including while searching the list.
Operations and events have independent preferences, saved under the authenticated
account and loaded on another device. Existing column colors, widths and drag
reordering remain available.

Format choices follow the data type: default, text, number, currency, percentage,
date/time or duration. Number formats support 0–10 decimal places and optional
thousands grouping. Currency changes the symbol without exchanging the amount.
Percent follows Excel's fraction convention; the confidence field is already
stored as a percentage and is not multiplied again. Date presets use local
24-hour time and include hundredths. Durations use minutes:seconds,
hours:minutes:seconds or seconds, with up to 3 decimals, never wrapping at 24
hours. Formatting a duration as a number shows seconds. Controls/previews retain
their native rendering and can still be repositioned.

The editor previews the first available row or an explicitly labelled sample.
Changes are draft-only until Save; Cancel discards them, and Reset resets order
and formats in the draft, preserving widths. Save updates order and formats in
one SQL upsert. Failed saves keep the draft for retry without changing the table.
Pending drag-order saves must finish before the editor opens. Auto-refresh pauses
while editing. Keyboard controls and a stacked mobile layout are supported.

Only display text changes. Sorting, filtering, audit calculations, JSON details
and CSV exports continue using original values. Numeric formatting uses decimal
string/BigInt rounding to preserve large integer identifiers and small costs;
missing and nonnumeric values are not converted to zero. Existing click handlers,
cost provenance and status icons remain intact.

`audit_column_orders.column_formats` is additive JSONB state. The new atomic
`PUT /api/admin/audit/column-settings/:mode` validates the complete permutation and
all format options. `GET /api/admin/audit/column-order?formats=1` includes formats;
existing clients retain the previous response shape. Older order/width writes do
not overwrite formats. The shared engine in `server/audit-column-formats.js` is
embedded in the standalone admin HTML; a parity test prevents divergence. Format
strings are preset values, never executable expressions or HTML.

Validation: disposable PostgreSQL schemas for authentication, account isolation,
atomic persistence, compatibility and validation; pure tests for permutations,
precision and time formats; desktop/mobile browser tests for preview, reordering,
failed saves, reload, cancellation/reset and original-value sorting. Live
verification uses GET requests only, without changing anyone's saved preferences.
Deployment is web/server only, with no Git action or APK build.
