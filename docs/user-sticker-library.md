# User sticker library — 2026-09-07

The expression picker now shows only the user's supplied collection, with Hebrew search. The previous emoji, AI, smile, family, sticker and animation tabs and the legacy picker fallback have been removed from this picker. Historical message assets remain available so existing conversations can still display their images.

The six source files in `/home/yaniv/Emoji` produce 150 entries: 48 watercolor symbols, 49 greetings (including the large house), 45 short expressions, six illustrated cards, and two Israel illustrations. `scripts/import-user-stickers.cjs` imports the existing artwork without redrawing it; the irregular greeting sheet has explicit cell boundaries. Source files are preserved.

The server reads `expression-library/catalog.json` dynamically. The Flutter fallback catalog is `flutter_app/assets/stickers/user-catalog.json`; it lists only the replacement collection. Both private and group selections download a single PNG and send it through the existing image upload flow. The group handler previously lacked the remote-catalog branch and now handles it.

Validation: Flutter analysis passed; the existing Node suite passed (304 tests, two optional database tests skipped), plus two catalog/group regression checks passed. The catalog check executes the server catalog function, verifies all 150 image files decode, and checks the bundled fallback count. Representative atlas cells were visually inspected and irregular lower rows corrected. No physical-device test was available.

Release: web and Android 1.3.21+241.

## Release 1.3.22+242 — no sticker content scans

Exact library-file hashes now identify stickers independently of a client flag, including forwarded/re-uploaded copies. Recognized stickers skip visual fingerprinting, moderation cache lookup, all image-analysis providers, and automatic scan reports. The central image scanner also returns the same no-scan result for recognized library bytes, covering explicit rescan paths. Unknown images retain their existing moderation flow. This is library recognition, not a content scan.

Private and group sticker uploads no longer show a scanning progress card/dialog; web sticker uploads no longer request a scan report. Recipient and group delivery permissions remain enforced. Four regression tests cover provider bypass, ordinary-image moderation, and upload report/cache exclusion.

Release verification: APK package `com.betshuva.app`, versionName `1.3.22`, versionCode `242`. Signature verified and signing certificate matches the previous downloadable APK. Both public APK URLs were fully downloaded and matched SHA-256 `65fdece2553772f61cf2bcf45714e9e057858536cb5a99341009d16d0914a88e` (134,270,300 bytes). No physical-device installation was performed.
