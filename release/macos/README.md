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

`AppleCommand` and `OwnedCommand` execute fixed Apple tools with bounded argument
arrays, closed stdin and fairly drained output. Timeout/cancellation/flood returns
a refusal after at most one TERM to the owned child. The retained monitor still
observes actual exit; `status()` and `observeExit(seconds:)` never repeat a signal
or effect. Failed native producers retain their private pending stage and never
promote late output. This owner claims only its direct child; inherited pipes
held by descendants refuse separately.

`NativePropertyList` preflights XML/bplist00 structure and expansion before
typed Foundation decoding. It preserves boolean/integer/real distinctions and
Unicode value bytes, with input/depth/node/string and compact-metadata bounds.
Declared entities, duplicate keys, cyclic/out-of-range references and unsupported
metadata types refuse. `verify-sparkle-plist /absolute/path/to/Info.plist` checks
the seven pinned SDK identity fields only; it does not qualify CPU headers,
framework contents or signatures.

`MachOInspector` uses scoped random-access descriptor reads for bounded thin/fat
loader metadata. It preserves CPU/file type/minimum, import order and run paths
without executing code or loading the whole file. The borrowed view refuses
after closure, including descriptor-number reuse. Inspect one file with:

```sh
swift run frameshift-mac-release inspect-macho /absolute/path/to/native-file
```

Output is a bounded JSON slice array plus LF; failures retain the fixed 64/65
usage/admission convention. This does not resolve imports or verify code seals.
The complete closure gate and production wrappers remain separate RT2 work.

See the [loader metadata contract](../../docs/host/macos.md#native-release-loader-metadata),
[plist contract](../../docs/host/macos.md#native-release-property-lists),
[child contract](../../docs/host/macos.md#native-release-child-custody) and
the [owning contract](../../docs/host/macos.md#native-release-input-foundation),
[migration sequence](../../docs/architecture/implementation-plan.md#release-tooling-migration)
and [verification map](../../docs/architecture/verification.md#installed-product-and-guide).
