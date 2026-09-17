# Emoji and user sticker library

The composer emoji button opens the user's 150 supplied images immediately in one searchable grid. There are no category selectors, library folders, or emoji/sticker tabs. Selecting an image sends it as a separate image message through the existing upload flow in both private and group conversations, preserving the message draft. The catalog is fetched when the picker opens, with the bundled user catalog as a fallback. Historical message assets remain available so existing conversations can still display their images.

Emoji-only text uses the same font size and message bubble as other text in private and group conversations. Actual image stickers and historical built-in sticker messages retain their media rendering. The previous AI, smile, family and animation catalogs remain excluded from the picker.

The six source files in `/home/yaniv/Emoji` produce 150 entries: 48 watercolor symbols, 49 greetings (including the large house), 45 short expressions, six illustrated cards, and two Israel illustrations. `scripts/import-user-stickers.cjs` imports the existing artwork without redrawing it; the irregular greeting sheet has explicit cell boundaries. Source files are preserved.

The server reads `expression-library/catalog.json` dynamically. The Flutter fallback catalog is `flutter_app/assets/stickers/user-catalog.json`; it lists only the replacement collection. Both private and group selections download a single PNG and send it through the existing image upload flow. The group handler previously lacked the remote-catalog branch and now handles it.

Validation: Flutter analysis passed; the existing Node suite passed (304 tests, two optional database tests skipped), plus two catalog/group regression checks passed. The catalog check executes the server catalog function, verifies all 150 image files decode, and checks the bundled fallback count. Representative atlas cells were visually inspected and irregular lower rows corrected. No physical-device test was available.

Release: web and Android 1.3.21+241.

## Release 1.3.22+242 — no sticker content scans

Exact library-file hashes now identify stickers independently of a client flag, including forwarded/re-uploaded copies. Recognized stickers skip visual fingerprinting, moderation cache lookup, all image-analysis providers, and automatic scan reports. The central image scanner also returns the same no-scan result for recognized library bytes, covering explicit rescan paths. Unknown images retain their existing moderation flow. This is library recognition, not a content scan.

Private and group sticker uploads no longer show a scanning progress card/dialog; web sticker uploads no longer request a scan report. Recipient and group delivery permissions remain enforced. Four regression tests cover provider bypass, ordinary-image moderation, and upload report/cache exclusion.

Release verification: APK package `com.betshuva.app`, versionName `1.3.22`, versionCode `242`. Signature verified and signing certificate matches the previous downloadable APK. Both public APK URLs were fully downloaded and matched SHA-256 `65fdece2553772f61cf2bcf45714e9e057858536cb5a99341009d16d0914a88e` (134,270,300 bytes). No physical-device installation was performed.

## Release 1.3.23+243 — emoji inside message text

The composer opens on Unicode emoji and keeps image stickers in a separate tab. Both private and group chats preserve existing text and the selection while the picker or its search field has focus. Selecting an emoji performs no message send or media upload; the composer sends one combined text message after the user presses send. Emoji-only text is no longer treated as a large sticker.

The displayed application version and support issue metadata now match the release version; the previous hardcoded `1.3.14` could misidentify newer installed builds.

Validation: eight picker tests, ten private/group integration tests, ten existing chat/rendering checks, and seven Node asset/catalog/moderation checks passed. Three additional render checks cover desktop, mobile, and an open mobile keyboard with enlarged text. Native-device installation is not part of this validation.

Release verification: web build `20260910184856` matches the published JavaScript, and its emoji catalog and SVG files are accessible. Android package `com.betshuva.app` has versionName `1.3.23`, versionCode `243`, and the same signing certificate as the preceding release. Both public APK downloads match SHA-256 `05a54e6910f0d28892efda153e7fc9929c2003e3b30150d9664edb218fab6c44` (136,351,512 bytes). `/api/version` advertises the versioned APK after publication.

## Single image picker — September 17, 2026

All 150 user-supplied PNGs now replace the Unicode picker in one flat, searchable list. The header and image grid scroll together so an open keyboard also fits short landscape screens. Private-chat access follows the recipient's image permission. Existing text drafts and historical assets are preserved.

Validation: 12 private/group widget tests passed, covering all 150 images, bundled-catalog fallback, first/last image delivery without duplicate sends, draft preservation, image permissions, and three keyboard-open mobile viewports including landscape. Six existing Node catalog/moderation checks passed, and all 150 public PNG URLs returned HTTP 200 with matching file sizes. Flutter analysis passed. Published as a web update; no Android APK rebuild is included.

## Restored standard emoji alongside custom images — September 18, 2026

The web composer offers both the existing 150 custom images under “של בתשובה” and the restored 171 standard Unicode emoji under “רגילים”. The custom collection opens first. Both private and group chats insert the chosen emoji at the preserved caret, replacing selected text when applicable. Selection does not send a message or upload media; the user sends the combined draft explicitly. Custom images remain small inline images in the draft and message, using the existing encoded-text format. Unicode emoji remain ordinary text.

The standard picker retains its eight categories, Hebrew search, accessible labels and bundled Twemoji SVG artwork. Both collection views scroll their header, controls and results together to fit screens with an open keyboard. This update uses the existing catalogs and changes the web client only.

Validation: 11 standalone picker tests, 11 inline-image/controller tests, and all 21 private/group integration cases passed with native Flutter testing. The 21 integration cases also passed in Chrome, including both lists on three keyboard-open viewports. Thirteen Node asset/catalog/moderation checks passed, and Flutter analysis reported no issues.
