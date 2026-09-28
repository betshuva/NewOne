# Web scan progress and video overlays — September 28, 2026

Web deployment: `20260928205542`.

Private and group chats reconcile local upload progress with the owner's server
scan record using a bounded client upload identity. Pending visual media keeps
its content URLs redacted and displays one progress card with the correct media
type, including after a history refresh or reopening the conversation. Identical
filenames do not merge separate uploads. The server adds a nullable
`stored_files.client_upload_id` column and returns it on owner-only scan rows.

Native web video players stop receiving pointer events while covered by the
attachment menu or camera dialog. The barrier lasts through closing animations
and works across nested navigators; it restores pointer interaction after close.
Other modal routes also disable pointer events on videos on their covered route.

Validation:

- 28 focused Flutter tests passed, covering private/group upload reconciliation,
  refreshed pending video, attachment navigation and filtering.
- Six Chromium widget tests passed, including nested navigation, video progress
  and camera capture behavior.
- A compiled browser fixture placed the video-capture menu item over one of four
  native video elements. A real mouse click opened the camera and began recording;
  background videos recorded zero play events. Closing the camera restored their
  pointer interaction. No JavaScript errors occurred.
- Node suite: 1,064 passed, 231 opt-in tests skipped, zero failures. The upload
  handler tests cover persistence and validation of the new correlation field.
- Targeted Dart analysis found no issues; release web build and both deployment
  tests passed.
- The backend restarted successfully and the additive schema was verified.
- Live HTML, bootstrap, application JavaScript and audit font returned HTTP 200
  over verified TLS and matched local SHA-256 values. Desktop and mobile Chromium
  loaded deployment `20260928205542` without JavaScript errors.

The existing downloadable Android release remains 1.3.37+257. This deployment
updates the web application and backend.
