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

Six framework groups, four compiler capture groups, one development preparation
group and three Swift updater preparation groups require
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
equality and remaining native producer/library cutover retain separate RT2 gates.

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

Prepare only an unpublished private development stage with:

```sh
swift run frameshift-mac-release prepare-development-bundle /absolute/path/to/.package.ABC123/Frameshift.app arm64
```

`DevelopmentBundlePreparer` owns sequential Apple children and retains the exact
last child after refusal. Complete custody checks bracket each command; only
its named code, plist and fixed seal paths may change. It derives the actual
minimum, removes unused selected-toolchain paths, and signs inside out before
strict complete admission. It never rewrites native minima/imports, deletes a
failed stage, publishes or replaces accepted output. The five-minute job admits
at most 512 children with 15-second/64-KiB-per-pipe limits. Success prints the
existing development-bundle line; usage/refusal exits are 64/1. Retained producer
libraries and the full-host packaging script still require cutover qualification.
The explicit observed Swift updater profile uses
`prepare-swift-updater-bundle PRIVATE_APP CPU` or
`DevelopmentBundlePreparer.prepareSwiftUpdater(_:architecture:)`. It accepts
only the main shell's Swift system/optional selected `swift-6.2/macosx` search
paths and the owned framework path, removes the first two and retains unchanged
strict final inspection. Legacy preparation never falls back to this profile.
Actual source/cache/CPU/package and shipping controller joins remain separate.

The application default Swift Build engine uses the separately qualified
`swift-updater-shell-preparation-v2` operation:
`prepare-swiftbuild-updater-bundle PRIVATE_APP CPU` or
`DevelopmentBundlePreparer.prepareSwiftBuildUpdater(_:architecture:)`. Its
incoming paths are exactly Swift system, executable directory, selected
`swift-6.2/macosx`, then the explicitly linked app Frameworks path. It removes
the first three and preserves imports/deployment headers before strict final
admission. Both profiles refuse the other's shape; no implicit fallback or
retained-receipt relabeling occurs.

`native-updater-fixture.mjs ARCHIVE CACHE_FRAMEWORK PROBE_EXECUTABLE` joins the
actual release-built `frameshift-updater-probe` to original archive/cache
admission, private CPU staging, v2 preparation and strict seals. Its disposable
unique defaults domain checks stopped SDK preference preservation and is removed
by the probe. Failure retains private work. It does not start/check an updater,
use production pins or prove installed behavior.

`compile-updater-inputs REPOSITORY` selects the separate fixed root release-build
producer. `SwiftPMInputCapture.compileUpdater` holds the original admitted
manifest/state/ZIP and complete SDK cache through one owned default Swift Build
child, disabling resolution/netrc/Keychain. The actual main executable must
import pinned Sparkle; the unchanged bare 86-file observation is returned only
after closing custody. The shared job limit is 180 seconds, with a 120-second/
512-KiB-per-pipe compiler bound. Missing SDK, child failure or changed input
refuses with scratch and actual child custody retained; no receipt/publication
authority follows. Local packaging calls this producer before copying/deriving
the SDK, then selects v2 preparation. Source-bound universal/candidate and
installed/production joins remain independent.

Inspect the exact private generation SDK descriptors with:

```sh
swift run frameshift-mac-release verify-generation-resources /absolute/path/to/private/resources
```

`PinnedGenerationResources` admits only current nonroot-user 0700 directory
custody and the two single-link 0600 pinned files. It preflights both names/files
before protected hashes and repeats complete descriptor/namespace custody.
The fixed schema-one observation preserves existing bytes, includes no private
path and is bounded to 64 KiB including LF; usage/admission exits are 64/1.
No SDK/model/network operation or repair occurs. `scripts/check-sdk-resources` uses
`PinnedGenerationResources` through the separate release-built tool; exact weight
bytes and shipping-worker qualification are independent.

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

Derive a single CPU into an unpublished private app with no Frameworks directory:

```sh
swift run frameshift-mac-release stage-sparkle-framework /absolute/path/to/archive.zip /private/stage/.package.Example/Frameshift.app arm64
```

`SparkleFrameworkStager` reuses exact original ZIP admission, copies the fixed
SDK tree with owned `ditto`, then derives only five binaries with owned `lipo`.
Its private work stays inside Frameworks; common bytes, modes, aliases and
unrelated app identities remain exact. It returns the existing schema-one
source/derived observation below 64 KiB including LF. It does not access or
repair the compiler cache, sign the app or publish a result. The one-writer
stage has a two-minute job budget and fifteen-second/64-KiB child bounds;
refusal retains all failed work and the exact last child until its exit is
known. Only fully checked scratch/work is removed. CPU assembly and actual
source-bound packaging/library cutover still require separate qualification.

Child-bearing CLI commands borrow the same `OwnedCommand` objects used by the
library. On failure they print their fixed refusal, then retain those owners
until each direct child is known not-started or reaped. This read-only wait
ignores the failed caller's task cancellation, sends no further signal and
never promotes late bytes or removes failed scratch. Running/unconfirmed custody
can keep the CLI alive beyond the admission deadline; external process termination
does not prove child/descendant exit and creates no cross-process recovery journal.
Independent GUI observations keep their finite cancellable exit API.

The existing `scripts/check-macos-closure` and `scripts/check-sdk-resources`
wrappers now build this development tool and execute its completed binary.
They preserve caller-relative input, record bytes and fixed 64/1 messages;
a failed build emits no observation. Concurrent SwiftPM diagnostics stay outside
admission output. Use `scripts/check mac-release` for compiler diagnostics.
Remaining Node library/producer integrations still require their own cutover.

Capture the original SDK inputs recorded by the actual root-package compiler:

```sh
swift run frameshift-mac-release capture-swiftpm-inputs /absolute/path/to/repository
```

`SwiftPMInputCapture` uses POSIX `realpath` for the exact package identity and
retains no-follow parent descriptors across a separately scratched SwiftPM
manifest child. Strict bounded JSON admits only workspace versions six/seven,
the fixed root `macos` artifact, URL/checksum/path and empty dependency/prebuilt
sets. The manifest/state and original ZIP/cache custody remain unchanged; no
fetch, resolve, compile, thin, sign or cache repair is performed. Success returns
the existing ordered bare 86-file JSON array, or `[]` for no binary target;
`inventoryEntries` charges all 152 SDK/archive members to the producer's shared
ceiling. Output is below 64 KiB including LF. Fixed usage/admission exits are
64/1. Incomplete scratch and owned child custody remain retained; cancellation
never admits a late result. Existing compiler/receipt consumers remain on their
current implementation until the individual integration cutover is qualified.

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
