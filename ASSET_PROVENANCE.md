# Betshuva asset provenance

This inventory covers application-owned and third-party assets bundled with or
displayed by Betshuva. It does not cover content uploaded by users.

Betshuva is operated by Betshuva Digital Solutions Ltd (בתשובה פתרונות
דיגיטליים בע״מ), Israeli company no. 517401238. Assets originally created by
Yaniv Eliyahu are intended to be assigned to the company under
`INTELLECTUAL_PROPERTY_ASSIGNMENT.md`; the assignment should be marked complete
here only after that document has been signed by both parties.

| Asset | Use | Recorded source | Status / required evidence |
|---|---|---|---|
| `flutter_app/icon_source.png` | Primary application logo | Created by Yaniv Eliyahu; added in commit `d0f51bc` and later revised | Creator ownership declaration recorded in `ASSET_OWNERSHIP_DECLARATION.md`. Preserve original editable files and metadata. |
| Android, iOS, macOS and web launcher icons | Generated application icons | Derivatives of the Yaniv Eliyahu-created `icon_source.png` | Covered by the recorded creator declaration to the extent they contain only the original logo. |
| `google-play-feature-graphic-*.png` | Google Play marketing artwork | Created by Yaniv Eliyahu using the Betshuva branding and text | Creator ownership declaration recorded in `ASSET_OWNERSHIP_DECLARATION.md`. Third-party marks or elements, if any, remain subject to their own terms. |
| Material Icons and Flutter framework assets | Interface icons and runtime assets | Flutter SDK / Material Icons | Open-source licences are bundled in Flutter's generated `NOTICES` file and exposed in the application's “Open-source licences” screen. |
| Google “G” shown on sign-in buttons | Google authentication branding | Official Google Identity asset: `https://developers.google.com/static/identity/images/g-logo.png` | Use only inside the “Continue with Google” action and follow Google's current branding guidelines. Do not recolour or reshape it. |
| Images shown in profiles, chats, groups and listings | User content | Uploaded by users and served by the application | Outside this inventory; governed by the Terms of Use and the content/reporting process. |

## Release checklist

1. Retain a signed copy of `ASSET_OWNERSHIP_DECLARATION.md` with the original editable source files.
2. Confirm every new marketing image has a creator and source recorded here.
3. Keep Flutter/Dart and Node dependency licence notices with distributed builds.
4. Recheck Google Identity branding requirements when the sign-in UI changes.
5. Do not add stock photos, fonts, music or icons without recording their licence.
