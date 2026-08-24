---
status: accepted
---

# Discard idle audio during iOS warm capture

The custom keyboard and containing app communicate through a polled App Group mailbox. The containing app keeps one audio resource warm during an explicitly armed session, but an armed session is not itself a Recording Session.

The audio callback discards every buffer while the gate is idle. Only buffers received after the host atomically accepts Begin and before it accepts Finish enter Captured Audio. Buffers that arrive while the per-request file is being prepared are bounded and ordered ahead of later live buffers.

Writer admission is capped independently by buffer count and byte count. Exceeding either bound fails the Recording Session closed instead of dropping samples or allowing an unbounded queue. Disarm, expiry, lock, lifecycle failure, and cancellation delete any partial artifact. Process termination cannot run cleanup code, so the next host launch or arm must remove orphaned Captured Audio before microphone access is allowed.

This preserves the production privacy boundary in issues #13 and #14. First-word latency is measured from accepted Begin on a physical phone; reducing it must not retain audio outside a Recording Session without a new approved decision.
