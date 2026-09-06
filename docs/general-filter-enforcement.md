# General filter enforcement — 1.3.19+239

The top-level switch “אכיפת הסינון הכללי בכל המערכת” appears in the registration filter step, legacy registration filter selector and general content-filter settings.

Copy: “הסינון הכללי משמש כברירת המחדל בשיחות עם חברים ובקבוצות. כשהאפשרות פעילה, אפשר להחמיר בסינון של חבר או קבוצה, אך לא להתיר תוכן שחסום בסינון הכללי. כשהאפשרות כבויה, ניתן להתאים את הסינון בנפרד לכל חבר או קבוצה.”

The flag is stored as `users.content_filter.enforceGeneralFilter`. It defaults to false, including existing accounts. Registration validates its boolean type. General-settings PUT preserves an existing flag when older clients omit it, and accepts explicit true/false to enable/disable it.

`resolveScopedContentFilter` and the SQL function `betshuva_effective_filter` implement the same policy. With enforcement off, the scoped filter replaces the general settings; without an override it inherits them. With enforcement on, the effective value for each category is general AND scoped. Existing scoped overrides are capped at read/delivery time, so stale or more permissive values cannot bypass the general restriction. Disabling enforcement permits stored overrides again. Universal moderation is unchanged.

Applied to private recipient policies, conversation-list policy metadata, group creator policy, per-member delivery plans, group history/reactions, invitations and scoped-settings responses. Pending media delivery rechecks the current destination policy for every file type after scanning. Accepting a contact request cannot deliver content outside an enforced filter. New group creation and friend/group invitation dialogs initialize from the account’s actual general settings.

Validation:

- 297 server tests passed, 2 opt-in DB tests skipped in the regular suite.
- Two additional registration tests passed.
- Opt-in DB tests: 7 passed; SQL/JavaScript parity checked across all 64 category combinations with enforcement on/off and three scoped variants (384 comparisons). Legacy flag preservation and explicit disabling/enabling checked. TEMP tables/functions were rolled back.
- Flutter analyzer: no issues.
- Server restarted successfully; migration installed the SQL function, four backup workers started, and public filter API returned expected unauthenticated HTTP 401. Read-only verification of the live function confirmed enforced overrides are capped.

No existing account was opted into enforcement. No support messages were sent. This does not erase previously downloaded/cached content from a device; scope overrides and current delivery are evaluated using the saved policy.

Web release deployed and public build ID verified. Signed Android APK 1.3.19+239 built and published after signature and version checks. Version API points to the new APK.
