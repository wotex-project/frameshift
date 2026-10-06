# Mac release tools

This SwiftPM package owns build-time Mac inspection and packaging. It has no
external package dependencies and does not link the native app, Sparkle or the
Elixir host. Nothing in this package belongs in a shipped app bundle.

Run its independent formatter, package tests and release build with:

```sh
./scripts/check mac-release
```

The two generation-resource live-cohort groups require
`FRAMESHIFT_SDK_RESOURCES_FIXTURE=/absolute/path/to/private/resources` containing
the exact pinned JSON files. Without it they are explicitly skipped; synthetic
refusal fixtures do not establish a passing real cohort.

Six additional live SDK groups require
`FRAMESHIFT_SPARKLE_ARCHIVE=/absolute/path/to/the/pinned/archive.zip`. The synthetic
archive-refusal group remains runnable without that input.

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
Observe one complete bundle without executing its native code with:

```sh
swift run frameshift-mac-release check-bundle /absolute/path/to/Frameshift.app arm64
```

The CPU argument also accepts `x86_64` and `universal`. `NativeBundleInspector`
streams a bounded directory inventory, hashes every regular file, checks native
roles/CPUs/minima/imports and exact pinned Sparkle aliases, then repeats the
whole inventory to confirm custody. Output preserves the existing schema-two
observation bytes and is bounded to 16 MiB including LF. Usage exits 64; bundle
refusals exit 1 with fixed text and no observation. SDK resource/archive/cache
equality and production-wrapper cutover remain separate RT2 gates.

Join strict static signatures to that observation with:

```sh
swift run frameshift-mac-release verify-development-bundle /absolute/path/to/Frameshift.app arm64
```

`NativeSignatureVerifier` explicitly validates every native member and fixed
Sparkle container with strict all-architecture/nested Security API checks. It
requires an ad-hoc outer app and repeats complete closure/custody admission.
Success emits the unchanged observation; usage/admission exits are 64/1 with
fixed text. It performs no signing, repair, candidate execution or network
trust evaluation. Unsealed SDK bytes still need exact archive/resource admission;
static seals do not establish Developer ID, notarization or installed behavior.

Inspect the exact private generation SDK descriptors with:

```sh
swift run frameshift-mac-release verify-generation-resources /absolute/path/to/private/resources
```

`PinnedGenerationResources` admits only current nonroot-user 0700 directory
custody and the two single-link 0600 pinned files. It preflights both names/files
before protected hashes and repeats complete descriptor/namespace custody.
The fixed schema-one observation preserves existing bytes, includes no private
path and is bounded to 64 KiB including LF; usage/admission exits are 64/1.
No SDK/model/network operation or repair occurs. The existing wrapper remains on
its current implementation until its qualified cutover; exact weight bytes and
shipping-worker qualification are independent.

Compare the actual compiler framework with its separately pinned original ZIP:

```sh
swift run frameshift-mac-release verify-sparkle-framework /absolute/path/to/archive.zip /absolute/path/to/Sparkle.framework
```

`PinnedSparkleFramework` extracts only the fixed framework into new private
scratch through an owned Apple child, hashes all 85 files, compares 57 directory
modes/nine aliases and records both CPU headers for the five native roles.
Complete original/copy/cache/extracted custody is repeated before returning the
existing schema-one observation, bounded to 64 KiB including LF. Usage/admission
exits are 64/1 with fixed text. Failures retain scratch and any owned monitor;
only completed verified scratch is removed. Cancellation after child success
still refuses. This does not resolve/repair the compiler workspace, derive CPU
code, re-sign, execute the SDK or establish upstream build/license/release trust.

See the [updater material contract](../../docs/host/macos.md#pinned-updater-material-and-private-cpu-derivation),
[generation resource contract](../../docs/architecture/content-pipeline.md#pinned-sdk-resource-custody-check),
[signature contract](../../docs/host/macos.md#native-release-development-signatures),
[closure contract](../../docs/host/macos.md#native-closure-admission),
[loader metadata contract](../../docs/host/macos.md#native-release-loader-metadata),
[plist contract](../../docs/host/macos.md#native-release-property-lists),
[child contract](../../docs/host/macos.md#native-release-child-custody) and
the [owning contract](../../docs/host/macos.md#native-release-input-foundation),
[migration sequence](../../docs/architecture/implementation-plan.md#release-tooling-migration)
and [verification map](../../docs/architecture/verification.md#installed-product-and-guide).
