# Compact attachment menu — 2026-09-23

Private and group conversations now use the same compact RTL menu. Its right
edge aligns with the paperclip button and it opens above the composer, bounded
by screen safe areas and the keyboard. It scrolls when enlarged text leaves
insufficient space. The underlying conversation remains visible.

The first level contains Upload files, Capture and record, Scan document, and
Share contact. Android also retains Paste image. Capture and record contains
photo, video, and voice actions; Share contact contains another contact and the
user's own details. Screenshot capture is removed from the attachment menu.
The other existing screenshot entry points are outside this change.

Upload files opens one multi-select picker for images, video, audio, PDF, DOCX,
and XLSX, with a maximum of 20 files per selection. Existing per-file upload,
moderation, recipient policy, video duration, and size checks remain active.
Image-only selections retain duplicate elimination and their upload queue.
Mixed selections use the existing per-file send paths in selection order.
Recorded voice still explicitly identifies its audio MIME type; imported WebM
uses the video MIME type instead of being incorrectly tagged as voice audio.

The shared UI is in `flutter_app/lib/chat_attachment_menu.dart`; supported
extensions are in `flutter_app/lib/chat_attachment_files.dart`. Both chat
screens keep their existing camera, voice, document scanner, and send handlers.

Validation: 38 Flutter tests pass for nested navigation, enlarged text, anchor
positioning, cancellation, mixed file selection, blocked recipient/group image
policy, honest document progress, size rejection, capture naming, voice uploads,
and sender filtering. Fifteen targeted Node checks also pass.
