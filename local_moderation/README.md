# Local image moderation

This internal service runs `Falconsai/nsfw_image_detection` locally. Uploaded
images are processed in memory, are not persisted by this service, and are not
sent to Hugging Face or another external API at runtime.

The model is pinned to revision
`63e0a066bb08d2ae47324b540fba3adfd4536569` and is distributed under the
Apache-2.0 license. Model card:
https://huggingface.co/Falconsai/nsfw_image_detection

The application consumes the result as an additional general-NSFW signal. It
is displayed and recorded, but does not approve an image or change the strict
modesty decision. A general NSFW model is not a reliable judge of stricter
clothing and modesty rules (for example, it may consider a shirtless man safe).
