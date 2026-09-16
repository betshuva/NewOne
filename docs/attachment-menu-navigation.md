# Attachment menu navigation — release 1.3.25

The private-chat attachment menu opens on the root navigator, while desktop
conversations live in a nested navigator. Camera, gallery, document, video,
audio and contact actions previously popped the chat navigator, leaving the
attachment menu open and potentially disposing the conversation.

All nine actions now dismiss the dialog using its own context before starting
the selected workflow. Reduced internal option padding prevents vertical
content overflow while retaining the existing 72-pixel row height.

## Release

- Android: 1.3.25, versionCode 245, package com.betshuva.app.
- Web build: 20260916151350.
- APK: https://betshuva.com/betshuva-app/betshuva-1.3.25.apk
- SHA-256: `dca80c28050ed43dcc77a41d8dce6f1c7a5c7ffd32ca61b000bb1cd792205bba`.
- Signing certificate matches the published 1.3.24 APK.

## Validation

- Three Flutter widget tests passed: camera/gallery cancellation closes the
  menu without replacing the chat in direct and nested navigators; chat
  lifecycle listeners remain correct. The navigation regression fails with
  the old pop target. Actual device camera capture/upload was not tested.
- Six targeted Node attachment-policy and web-deployment checks passed.
- The broader conversation regression suite has 38 passes and three failures
  in both HEAD 57bcc50 and the release source: stable image tile height,
  desktop document callback, and first-message receiving-filter choice.
  Its current-release download-link check passes in both versions.
- Public api/version and version.json return 1.3.25 (metadata build 245).
- Both versioned APK and app-release.apk return HTTP 200; complete downloads
  match the signed APK SHA-256. The checksum sidecar matches too.
- Live index.html, flutter_bootstrap.js and main.dart.js return HTTP 200 and
  match the deployed artifacts; the bootstrap uses the web build ID above.
