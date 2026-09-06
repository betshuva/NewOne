# Right-aligned conversations — 6 September 2026

Version 1.3.17+237 implements the user's request for both conversation lists and all message bubbles to align to the right.

- Conversation lists explicitly inherit RTL layout and right text alignment, for friends and groups.
- Private incoming/outgoing message bubbles share right alignment, including attachments, scan states, stickers and image albums.
- Group message rows and their content use RTL start alignment, regardless of sender.
- Existing incoming/outgoing colors and delivery indicators continue distinguishing authorship. Private bubble corners now match their right-hand placement.
- The former guide-only alignment override is no longer needed.

Validation: Flutter analyzer clean; 57 existing conversation/guide tests passed. Release builds cover web and Android. Device interaction has not been tested on a connected phone.

Deployment: web release is live and its build ID was verified in the public HTML. Signed Android APK 1.3.17+237 was published as betshuva-1.3.17.apk and the version API metadata was updated after signature/version verification.

## Private-chat avatars — 1.3.18+238

Extended the existing guide avatar row to ordinary private conversations: each regular message shows the actual sender’s profile avatar at its right, with the existing fallback when no photo is present. Outgoing messages show the current user; incoming messages show the friend. The shared wrapper also covers regular attachments, stickers and scan-state bubbles. All-right message alignment, selection handling and author colors remain. Flutter analyzer and 57 existing conversation/guide tests passed.

Version 1.3.18+238 web build deployed and verified publicly. Android APK signature and packaged version verified before publishing the versioned APK and updating version.json.
