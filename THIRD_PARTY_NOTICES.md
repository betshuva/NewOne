# Betshuva third-party notices and review status

Last reviewed: 2026-08-21

This document records third-party software and model provenance. It is not a
replacement for the complete licence texts generated with a Flutter build.
User-uploaded content is outside this inventory.

## Distributed Flutter application

Flutter's generated `NOTICES` file is included in the application build and is
available through the in-app open-source licences screen. The deployed web
build also exposes it as `assets/NOTICES`.

The application directly depends on Flutter packages including `http`,
`shared_preferences`, `socket_io_client`, `image_picker`, `file_picker`,
Firebase, `flutter_local_notifications`, `flutter_contacts`, Google Sign-In,
`geolocator`, `url_launcher`, `record`, `audioplayers`, `path_provider`,
`crypto`, `flutter_webrtc`, and `permission_handler`. Their exact versions and
licence notices are recorded by `flutter_app/pubspec.lock` and the generated
Flutter `NOTICES` file.

### Vendored `record_android` 1.3.2

Source: <https://github.com/llfbandit/record/tree/master/record_android>

The vendored `LICENSE` is preserved verbatim from upstream. It contains the
original copyright attribution to “openapi4j authors”. The official pub.dev
package catalogue classifies `record_android` as BSD-3-Clause. The attribution
is therefore retained exactly as supplied instead of being rewritten locally.

**Status: documented.** Include the unmodified BSD-3-Clause text in generated
application notices whenever this vendored override is distributed.

## Server-side Node.js dependencies

These direct dependencies are not bundled into the Flutter client. Licences
were read from the installed package metadata for the locked versions:

| Package | Version | Licence |
|---|---:|---|
| bcryptjs | 3.0.3 | BSD-3-Clause |
| cors | 2.8.6 | MIT |
| dotenv | 17.4.2 | BSD-2-Clause |
| express | 5.2.1 | MIT |
| firebase-admin | 13.10.0 | Apache-2.0 |
| jsonwebtoken | 9.0.3 | MIT |
| mammoth | 1.12.0 | BSD-2-Clause |
| multer | 2.2.0 | MIT |
| nodemailer | 8.0.5 | MIT-0 |
| pdf-parse | 1.1.4 | MIT |
| pg | 8.22.0 | MIT |
| sharp | 0.35.3 | Apache-2.0 |
| socket.io | 4.8.3 | MIT |
| socket.io-client | 4.8.3 | MIT |

`sharp` uses libvips, which includes LGPL-licensed components. Normal hosted
operation does not distribute the server dependencies. If a server image,
Docker image, appliance, or installer is distributed, generate and ship a
complete dependency notice/SBOM and satisfy the applicable LGPL obligations.

## Machine-learning models

### Falconsai NSFW image detection

Model: <https://huggingface.co/Falconsai/nsfw_image_detection>

Pinned revision: `63e0a066bb08d2ae47324b540fba3adfd4536569`

Recorded licence: Apache-2.0. Runtime and behavioural details are documented
in `local_moderation/README.md`.

### Face detection, landmarks, age and gender weights

Previously copied face-api.js model weights had no explicit model licence in
this project and were not loaded by the production server or Flutter client.
They and their unused standalone test script were removed on 2026-08-21. They
must not be restored without an exact source revision and explicit permission
covering commercial use and redistribution of the weights.

## Application-owned and branded assets

- Primary logo and generated launcher icons: Yaniv Eliyahu declared himself
  the creator and copyright owner on 2026-08-21. The covered files are listed
  in `ASSET_OWNERSHIP_DECLARATION.md`; retain the editable sources and metadata.
- Google Play feature graphics: Yaniv Eliyahu declared himself the creator and
  copyright owner on 2026-08-21. Third-party marks or embedded materials, if
  any, remain subject to their respective terms.
- Google “G” branding: use the official asset only for Google authentication
  and follow Google's current branding guidelines.
- Profile, group, chat, and listing images are user-uploaded content and are
  governed by the service terms and reporting process.

## Release checklist

1. Keep the upstream BSD-3-Clause notice for vendored `record_android`.
2. Do not restore removed face model weights without explicit model terms.
3. Retain a signed copy of the asset ownership declaration and source files.
4. Keep the generated Flutter `NOTICES` in every APK and web release.
5. Generate a fresh third-party inventory/SBOM if the backend is distributed.
6. Record the source and licence before adding fonts, music, stock media,
   icons, models, or other third-party assets.
