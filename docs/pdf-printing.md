# PDF Printing

The shared in-app PDF viewer (private chats, groups, media library and embedded
desktop viewer) exposes a print icon and a compact document menu. The menu
retains download and zoom and adds opening the existing document URL in an
external application/tab.

Printing uses the existing `printing` plugin and `pdfrx` document. It does not
make a second network request, attach a session token to a URL, or generate a
screenshot of the visible page. The entire opened document is encoded once per
print request, with PDF security preserved and dynamic re-layout disabled.
Printing remains disabled until the document is loaded and its permissions
allow printing. Duplicate taps are disabled while the platform dialog is active.

Cancellation produces no success notification. Errors offer external opening;
external-opening errors offer the existing download action. The browser/device
chooses the external handler and available printers. A mobile browser may use
the printing plugin's PDF download fallback. An installed Android app must be
updated to receive these new client controls.

Tests: `flutter test test/pdf_document_actions_test.dart
test/pdf_preview_lifecycle_test.dart` covers exact bytes, one encoding, fixed
layout, loading, cancellation, errors, external launch, narrow toolbar layout,
closing during printing and the existing preview lifecycle. Platform dialogs
are mocked; physical printing is not asserted.
