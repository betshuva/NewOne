# Support issue follow-up (1.3.35)

The guide can count the current user's personal media by type through the
`media` data-plan kind. This kind accepts count requests only, uses the same
owner-scoped, deduplicated SQL as the personal media library, and never accepts
another user's identity from the model.

Guide message drafts can include groups with `includeGroups=1` on the recipient
list. Older clients retain their contacts-only response. Group confirmation
accepts exactly one destination, reuses the ordinary group send handler and its
membership, teen, content and send-permission checks, and commits the message
with the existing draft receipt. Delivery effects run after commit. Retries
return the saved receipt instead of sending twice.

Verified built-in stickers sent to Israel are persisted without generating an
assistant answer. A caller's claim that a file is a sticker does not exempt it:
file classification comes from approved stored-file metadata; sticker IDs pass
the normal server allowlist. Ordinary image questions remain supported. Voice recordings are delivered as
audio only; transcription and voice-question processing are disabled.

Image classification symbols open a scan explanation with recorded categories,
uncertainty and available status/reason. The blocked-image marker also opens
its existing details, now including classification. Missing explanations are
reported as missing rather than fabricated.

The support closure operation uses the normal administrative endpoint with an
individual response per issue. Implemented items and existing capabilities are
described separately from device-specific or underspecified reports that were
not reproduced. Those reports are administratively closed, not claimed fixed.
