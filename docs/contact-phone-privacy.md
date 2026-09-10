# Contact phone privacy — 10 September 2026

Saving a contact, opening a private conversation, joining a group, accepting a friendship request or appearing in the adult directory does not grant access to another account's phone number.

Contact provenance is separate from disclosure consent. `user_contacts.contact_source` records `unknown`, `in_app`, `phone_import`, `phone_manual` or `email_import`. Existing rows default to `unknown`. A `known_phone_hash` is written only when the authenticated viewer supplies a complete number that the server matches to that contact's current normalized number. Supplying a source label or matching an email does not establish phone knowledge. Import matching can upgrade an already saved contact in one bulk query, but never creates additional contacts or grants the reverse direction. New phone invitations also retain only the inviter's verified knowledge of the exact invited number.

The directed `contact_phone_permissions` table records pending, approved, declined and revoked decisions by phone owner and viewer. An approved grant is tied to the normalized phone fingerprint; changing the number invalidates the grant and any old-number knowledge. Both directions of blocking override access. Fresh requests and disclosures require adult accounts on both sides; previously known numbers remain governed by exact knowledge. Requests are idempotent while pending, and a declined or revoked request cannot be resent for 24 hours.

The user's requested initial filter/friendship flow preselects sharing and, when appropriate, requesting the other number. Merely opening the screen does nothing. The confirmation button and explanatory copy identify the sharing/request action. Unchecking a pending disclosure request declines it. Existing settings respect the current sharing choice. Each direction requires its own owner's decision; changing a group filter never grants access to the entire group.

Server integration:

- `GET /api/users`, `/api/users/directory`, `/api/users/search` and `POST /api/contacts/match` apply the central phone projection. Phone search is exact, so partial queries cannot reconstruct a hidden phone. These responses carry phone visibility and provenance metadata and disable caching.
- `POST /api/contacts/save/:userId` verifies `knownPhone` instead of trusting the claimed import source. Requests are rate limited.
- `GET` and `PUT /api/contacts/:userId/phone-sharing` read and change directed choices. The actor comes exclusively from authentication; request bodies cannot choose the owner of a grant.
- Filter settings/comparison and incoming friendship requests include `phoneSharing`. Filter confirmation and friendship acceptance process explicit choices in the same transaction as the existing action. Notifications are emitted only after commit.
- `GET /api/phone-sharing/requests` and `/api/phone-sharing/grants` list current incoming requests and recipients of the viewer's grants. Neither response includes phone numbers.
- The guide, its recipient picker and newly generated tables/exports use the same SQL phone permission rule. Socket refresh events contain only the other user's identifier, never a phone number.

The Flutter client clears unauthorized numbers rather than merging a stale value back into a refreshed contact. Contact displays distinguish known-phone contacts from saved app contacts, and the privacy screen allows reviewing and revoking grants. A missing own number is explained without preventing filter setup.

An explicitly published listing phone and an owner's manually shared contact card remain deliberate publication/sharing actions. Revocation prevents future authorized retrieval; it cannot erase a number already copied by its recipient or embedded in an older message or exported file.

Validation uses synthetic accounts and PostgreSQL temporary tables with transaction rollback. It does not send messages or create phone requests for real users. Coverage includes exact-number proof, email-only matches, legacy contacts, directed consent, default selection without side effects, request/approval/revocation, changed numbers, blocking, age restrictions, metadata-only notifications, guide exports and contact-source persistence.

Release validation:

- 82 focused backend/SQL/route tests passed, including the guide and its exports. The policy and phone routes contributed 22 tests; guide and message-recipient coverage contributed 60.
- 44 Flutter tests passed, including 21 phone-sharing tests and 23 group/friend/lifecycle regressions. Targeted Dart analysis reported no issues, and the release web build succeeded.
- The full Node run passed 531 tests, skipped 14 optional tests and reported six existing source-layout assertion failures. Running the relevant tests with the pre-change Flutter source reproduced all six failures; they concern blocked-image artwork/layout, scroll image heights, desktop document routing and the empty-group form.
- The schema migration marked existing contact origins unknown and granted no new phone access. Backend restart and public HTTP checks succeeded. Published web release `1b5589c88f33c172` matches the local compiled JavaScript hash; all three new phone-reading route checks reject anonymous access with HTTP 401.
