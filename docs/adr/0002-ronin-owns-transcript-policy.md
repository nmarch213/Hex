---
status: accepted
---

# Ronin owns transcript policy

Ronin is canonical for the versioned Transcript Profile and applies the Transcript Profile Revision selected at the start of a remote Dictation. Profile edits use strong ETags and `If-Match`; stale edits fail instead of silently overwriting another device. Device Interaction Settings remain local because they govern platform interaction rather than the meaning of the Final Transcript.

Normal remains the deterministic Hex pipeline. Casual and professional are Transcript Styles applied on Ronin through an optional isolated Transcript Rewriter, never client-specific prompts or Transcript Transforms. The rewriter implementation, its exact pipeline position, and its latency budget remain rollout decisions.
