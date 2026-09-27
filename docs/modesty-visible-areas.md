# Visible clothing assessment

The shared OpenAI/Gemini modesty prompt evaluates only pixels inside the image.
Missing lower-body or other out-of-frame areas are not a reason for uncertainty
or rejection. Visible violations still follow the existing clothing policy;
blur or ambiguous clothing inside the frame remains unresolved.

Gemini's response schema includes visibleAreasDecision and uncertaintyReason.
The shared parser can normalize uncertain to modest only with explicit compliant
visible areas, out_of_frame_only uncertainty, false violationClearlyVisible and
nonempty textual visible evidence. It preserves the provider's original decision
and reason. Missing or inconsistent scope never gains this exception.
Provider HTTP errors, invalid responses, safety blocks and budget stops retain
their existing handling. No additional review calls are introduced.

The audit finding out_of_frame_ignored explains the policy in Hebrew. The
moderation cache version is 2026-09-27-visible-clothing-17 plus provider policy.
Previously stopped scans and their consumed budgets are not reset or resubmitted
by this deployment. Historical audit results are not rewritten.

Regression coverage includes cropped compliant frames through the image and
video pipeline, visible violations, ambiguous visible areas, unavailable optional
OpenAI, required-provider errors, invalid scope and audit presentation.
