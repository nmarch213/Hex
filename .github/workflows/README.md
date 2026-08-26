# GitHub Actions

`ci.yml` runs the checks that do not require private credentials:

- Effect service type checking, tests, production build, dependency audit, operational shell-script checks, and authenticated HTTP smoke test on Linux.
- Hardened Compose rendering plus both fake-adapter and real-production-entrypoint container smoke tests. The production test uses a bounded local upstream stub so it exercises production configuration and logging without fetching the speech model.
- `HexCore` tests, an unsigned build of the original macOS app, Swift 6 strict-concurrency checks, mailbox smoke coverage, unsigned Debug and Release iOS Simulator builds, and an unsigned generic-device Release build on macOS. XcodeGen is downloaded at a pinned version and verified checksum.

Signed iPhone installation and the macOS release pipeline remain local because they require the Owner's Apple signing and notarization credentials. See [`docs/release-process.md`](../../docs/release-process.md) for the local release workflow.
