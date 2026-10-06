# Mac release tools

This SwiftPM package owns build-time Mac inspection and packaging. It has no
external package dependencies and does not link the native app, Sparkle or the
Elixir host. Nothing in this package belongs in a shipped app bundle.

Run its independent formatter, package tests and release build with:

```sh
./scripts/check mac-release
```

From this directory, independently verify the exact pinned Sparkle 2.10.0 ZIP:

```sh
swift run frameshift-mac-release verify-sparkle-archive /absolute/path/to/archive.zip
```

The command reads and hashes a protected regular file with exactly one link,
checks the fixed 10,193,895-byte size and SHA-256, and prints a fixed success
line. Usage errors exit 64; admission refusals exit 65 without printing input
paths or bytes. It does not fetch, extract, resolve, repair a compiler cache or
qualify the framework. Existing release wrappers still use their original
implementation until their individual ports pass parity.

`AdmittedFile` bounds descriptor reads/hashes and checks named/descriptor custody
before returning a result. Buffered reads cap at 16 MiB; streaming hashes cap at
8 GiB, with profile-specific smaller limits. The consuming operation owns parent
directory admission. A monotonic deadline is checked between synchronous file
operations and cannot preempt an already blocked filesystem call.

See the [owning contract](../../docs/host/macos.md#native-release-input-foundation),
[migration sequence](../../docs/architecture/implementation-plan.md#release-tooling-migration)
and [verification map](../../docs/architecture/verification.md#installed-product-and-guide).
