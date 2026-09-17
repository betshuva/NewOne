# Profile picture filtering — 17 September 2026

Profile pictures now follow the viewer's saved general image preferences. The
reported account had `women: false`, but conversation and friend-discovery
responses returned a legacy profile image without consulting those preferences.

`server/profile-image-policy.js` batches the image metadata lookup and projects
blocked `profile_pic_url` values to `null`, preserving the contact and its other
fields. This applies to conversations, directory/search/contact matching,
friendship requests, group pictures and members, nearby/blocked users,
phone-sharing cards, and marketplace seller pictures. These personalized
responses disable caching. New-user broadcasts do not distribute profile images.

Approved uploads use their stored image classification. Every detected category
must be permitted; pending, rejected, removed, or non-image uploads remain hidden.
Unclassified legacy and external photos are hidden whenever any image category
is restricted. The account owner's gender is not used as an image classification.
The built-in guide and information-service assets have known fallback categories.
The historical demonstration portraits additionally use reviewed, byte-verified
metadata as described below. Emoji avatars remain available.

Profile image filtering uses the general preferences independently of the switch
that caps friend/group message overrides. Existing preferences and stored photos
are not changed. Own-profile editing remains available.

The web client omits raster photos from cached conversation rows until the server
refreshes them. Saving the general filter invalidates mounted profile pictures
and immediately refreshes conversation data. In-flight responses from an older
filter revision cannot reapprove images for the current revision.

Validation includes behavioral policy and actual API-handler tests, PostgreSQL
temporary-table checks with rollback, and read-only checks against the reported
account. After the backend restart, the existing contact image was absent from
that account's conversation, directory, and search responses, and its saved
preferences were unchanged.

Release checks:

- 44 focused Node tests passed; two optional database suites were skipped in
  that invocation, then run explicitly with all 22 database tests passing.
- 46 Flutter widget tests passed, including cache loading, immediate filter-save
  invalidation, the own-photo approval boundary, adding friends, desktop settings,
  conversation cleanup, group contacts, and phone-sharing behavior.
- Targeted Flutter analysis reported no issues.
- The broad Node run reported 544 passes, 15 optional skips, and seven source-layout
  assertion failures outside the avatar changes. The focused filtering/API and
  profile-tap suites passed.
- The application server was restarted and remained active. Public unauthenticated
  checks returned HTTP 200 for the app and HTTP 401 for protected search.

Web-only release `20260916220522` was published. Public HTML/bootstrap keys and the
compiled JavaScript SHA-256 `ebc569f2a4151a4d195734eae626a3a9ea9de793877b683f4e5858cae6984207` match the local build.
No Git operations or APK builds were performed.


## Reviewed historical portraits follow-up

Ben-Ori's profile uses `demo-historical/first-temple-man.webp?v=painted1`, one
of the pre-existing demonstration portraits that had no `stored_files` row.
Twelve historical portraits/group images were visually reviewed and their exact
SHA-256 hashes and detected categories recorded in `profile-image-assets.js`.
The projector resolves this metadata only when no stored-file record exists.
Pending/rejected scans, purged files, and existing classifications retain priority.

The resolver accepts only the exact application-local catalog URLs, including the
explicit `?v=painted1` alias. It verifies file identity and bytes, refuses symlinks,
and invalidates cached decisions when the file changes. A replacement image with
a different hash requires a new review. No source pictures, database records,
user preferences, or other external photos are reclassified implicitly.
Normal user uploads continue through the existing image scanning pipeline;
unclassified external profile pictures retain the conservative policy.

All 46 focused policy, resolver, and API-handler tests passed. The deployment
integrity check is enabled with `RUN_PROFILE_ASSET_TESTS=1`; ordinary resolver
tests use temporary fixtures because production uploads are not in source control.
Read-only projection using Aviv's saved preferences showed Ben-Ori's photo and
continued to hide Abigail's. This follow-up changes backend metadata resolution;
the previously deployed web client already consumes the filtered URLs.
