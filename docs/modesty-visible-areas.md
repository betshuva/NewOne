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
moderation cache version is 2026-10-01-corroborated-clothing-20 plus provider policy.
Previously stopped scans and their consumed budgets are not reset or resubmitted
by this deployment. Historical audit results are not rewritten.

Regression coverage includes cropped compliant frames through the image and
video pipeline, visible violations, ambiguous visible areas, unavailable optional
OpenAI, required-provider errors, invalid scope and audit presentation.

An uncertain Gemini result with a contradictory `violationClearlyVisible=true`
can be approved when both Gemini and OpenAI explicitly mark visible areas
`compliant`, provide visible evidence, report no ambiguity inside the frame,
and finish with confidence of at least 0.85. OpenAI must additionally return
`modest` and `violationClearlyVisible=false`. Google and local safety must be
available and clean, and person classification must be resolved. No additional
provider call is made to resolve this case. Missing reviewers, explicit Gemini
violations and genuinely ambiguous visible areas do not gain this exception.
Original provider fields remain in the audit, with the final resolution marked
`corroborated_compliant_gemini_flag`. This does not manually approve an entire
video with other unresolved or unscanned frames, or resubmit historical scans.
