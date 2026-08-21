# Betshuva asset provenance

This inventory covers application-owned and third-party assets bundled with or
displayed by Betshuva. It does not cover content uploaded by users.

| Asset | Use | Recorded source | Status / required evidence |
|---|---|---|---|
| `flutter_app/icon_source.png` | Primary application logo | Added to this repository in commit `d0f51bc` and later revised | Ownership is not proved by Git history. Keep the original design file, designer invoice, and a signed copyright assignment or commercial-use licence. |
| Android, iOS, macOS and web launcher icons | Generated application icons | Derivatives of `icon_source.png` | Covered only after rights in the primary logo are documented. |
| `google-play-feature-graphic-*.png` | Google Play marketing artwork | Locally produced marketing files using the Betshuva branding and text | Preserve the editable/source file and record the creator. Verify that every embedded element originated from the Betshuva logo or another documented source. |
| Material Icons and Flutter framework assets | Interface icons and runtime assets | Flutter SDK / Material Icons | Open-source licences are bundled in Flutter's generated `NOTICES` file and exposed in the application's “Open-source licences” screen. |
| Google “G” shown on sign-in buttons | Google authentication branding | Official Google Identity asset: `https://developers.google.com/static/identity/images/g-logo.png` | Use only inside the “Continue with Google” action and follow Google's current branding guidelines. Do not recolour or reshape it. |
| Images shown in profiles, chats, groups and listings | User content | Uploaded by users and served by the application | Outside this inventory; governed by the Terms of Use and the content/reporting process. |

## Release checklist

1. Confirm a signed assignment or commercial-use licence exists for the logo.
2. Confirm every new marketing image has a creator and source recorded here.
3. Keep Flutter/Dart and Node dependency licence notices with distributed builds.
4. Recheck Google Identity branding requirements when the sign-in UI changes.
5. Do not add stock photos, fonts, music or icons without recording their licence.
