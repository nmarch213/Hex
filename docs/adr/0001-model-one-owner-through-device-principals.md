---
status: accepted
---

# Model one Owner through revocable Device Principals

Hex has exactly one Owner and no account system. Each installed client acts as a separate Device Principal with its own revocable Device Credential; Ronin-local administration enrolls, rotates, and revokes those principals. This replaces the prototype's shared bearer secret without introducing users, passwords, organizations, OAuth, or public registration, and lets a lost phone be revoked without disrupting the Owner's other devices.

Tailscale remains an independent outer reachability boundary. Device Credentials are not synchronized through the Transcript Profile.
