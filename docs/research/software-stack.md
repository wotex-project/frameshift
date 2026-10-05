# Software Stack Research

**Research date:** 2026-09-22
**Architecture review:** 2026-09-23

**Outcome:** use a portable Elixir/OTP host core, a thin SwiftUI shell on macOS,
and an isolated Zig host renderer. Ubuntu and Pi 5 hosts use platform adapters
around the same core. A dedicated Pi 5 appliance uses Nerves. MCU firmware
language and toolchain are selected for the exact hardware. No project-owned
Python code or Membrane is part of the stack.
The public static guide shares a small Gleam decision kernel with the host;
it does not host Elixir execution or control frames in the browser. The
[installation contract](../architecture/install-and-guide.md) defines its
cross-target and distribution gates.

**Companion-platform decision, 2026-09-24:** Phoenix + Ash/AshPostgres and
phoenix-assets + Svelte 5/SvelteKit provide the separate visual configurator.
Embedded Refpath executes Frameshift-owned packs; bounded read-only Beamlens
provides server investigations. The retained v1 Gleam physical checks and
targeted ExMaude tests extend the existing model. Optional classifiers require project-specific
evaluation and do not change the language boundary. The 2026-09-25
[Conjunct integration](../architecture/conjunct-integration.md) retains this
host while assigning successor generic physical/procedure/viewer semantics to
Conjunct; the v1 code remains for replay and migration.
Frameshift is its first modular product consumer. A parts/shopping list is a
composition output; transactional service implementation is on hold. See the
[platform specification](../architecture/build-platform.md) and
[dated dependency/model research](build-platform-decisions.md).

## Recommended topology

```text
macOS menu-bar app (SwiftUI; first host shell)
  | Apple APIs: MenuBarExtra, Vision, Core Image, Keychain, ServiceManagement
  | local authenticated IPC
  v
Frameshift Core (Elixir/OTP release)
  | library, recipes, jobs, frame registry, discovery, protocol client
  | supervised executable port
  +--> Frameshift Raster (Zig)
  |      crop, scale, palette mapping, dithering, pixel transforms
  |
  +--> AI provider adapters
         local MediaGenerationKit / local Ollama / optional cloud APIs

LAN: W3C WoT TD/TM + advertised authenticated Forms
     reference HTTPS binding; qualified constrained bindings may coexist
  v
Thin Frame Agent (MCU-class; exact firmware toolchain unselected)
  | verified asset store, desired/current state, playlist, health
  +--> Photo adapter
  +--> Paper adapter
  +--> Pixel timed-parallel/DMA adapter
```

This is one product with explicit process boundaries, not a collection of
microservices. The boundaries isolate native crashes, protect secrets, and let
the platform shell restart without interrupting queued work.
On Linux, a local command CLI and platform adapters replace Apple-only
facilities; the core, renderer wire contract, and frame protocol remain shared.

## Elixir/OTP host core

Elixir owns state machines, supervision, job cancellation, bounded concurrency,
frame coordination, and protocol semantics. The first implementation is an OTP
release run as a per-user process. It exposes a local Unix domain socket to the
Mac shell. Linux hosts retain the authenticated local boundary; the host must
not open a general LAN control port.

Selected libraries and bounded candidates are tracked independently:

| Need | Candidate | Use boundary |
| --- | --- | --- |
| WoT value/runtime | Wotex `wotex` and `wotex_runtime`, both pinned to `c8c727a7c8c18fec82d80cc5ba88d246af3c67fc` | Bounded TD/TM admission, extension preservation, deterministic Form selection, typed requests/results, and explicit credential/transport ports. Frameshift retains state, policy, binary assets, and effect truth. |
| WoT HTTP mapping | Pinned `wotex_binding_http` plus a Frameshift-owned client | JSON Property/Action and SSE mapping only. It is not the binary artifact binding, TLS policy, HTTP server, or physical-effect proof. |
| HTTP client | `Mint` one-shot connections | Keep client certificates and keys inside one caller-owned callback; resolve and authorize every destination, disable pooling/proxies/redirects/retries, pin the frame SPKI, and enforce an absolute operation deadline plus incremental response bounds. |
| HTTP server for simulator/optional Nerves bridge | `Plug` + `Bandit` | Small explicit router; not a dependency of MCU firmware. |
| Metadata database | Direct Exqlite/SQLite under D-010 | Host only; one writer, durable transactions, database-enforced invariants, content-store reconciliation, and consistent backup. See the [persistence review](embedded-persistence.md). |
| Host JSON | `Jason` or OTP-native equivalent available at implementation time | Bounded decode; reject duplicate/unknown required fields; preserve TD extensions. MCU parsing is selected with its exact firmware stack. |
| Discovery | macOS Network framework/Bonjour through Swift; `mdns_lite` on Nerves | Advertise only the privacy-minimal introduction record. |

The selected Wotex packages are fetched from their upstream Git repository at
the immutable revision recorded in [protocol foundations](protocol-foundations.md).
The lockfile records the same full commit for all three packages; the sibling
checkout is not a build input. Their Apache-2.0 files and Wotex's bundled W3C
schema notice were inspected at that revision. Repository-wide third-party
notice assembly remains a separate distribution gate.

Req remains suitable for ordinary non-secret HTTP, but its normal Finch path
pools connection configuration. Passing a client certificate or private key in
those options would retain the credential beyond Wotex's immediate callback.
The reference frame client therefore uses processless Mint directly and closes
each connection before returning. Elixir ports are the preferred boundary for
the Zig raster worker because an external process can be supervised and
restarted without loading native code into the BEAM. See the current [Mint documentation](https://hexdocs.pm/mint/),
[Bandit documentation](https://bandit.hexdocs.pm/readme.html), and
[Elixir Port documentation](https://elixir.hexdocs.pm/Port.html).

### Host persistence

The normative domain boundaries, persistence choice, platform ports, and
qualification gates are in [Portable Host Core](../architecture/host-core.md).

The database stores metadata, never the only copy of artwork bytes. Masters and
derivatives live in a content-addressed directory. Database rows point to
digests and record provenance. Every write follows this order:

1. stream bytes to a temporary file while hashing;
2. validate declared type, decoded dimensions, and limits;
3. flush and atomically rename to the digest path;
4. commit the metadata transaction;
5. enqueue derivative work.

Startup reconciliation removes abandoned temporary files after a grace period
and records orphaned digest files for later adoption or collection. It never
deletes pinned, referenced, current, or previous-known-good content.

## Thin frame runtime

The frame runtime has the same explicit ownership model as an OTP design, but
must fit an MCU power and depth envelope:

```text
FrameAgent
  Network
  Identity
  AssetStore
  ProtocolServer
  DesiredState
  DisplaySupervisor
    DisplayAdapter
  PlaylistScheduler
  Health
```

An adapter fault must not corrupt the asset store or networking. `DesiredState`
serializes display changes so two host requests cannot drive hardware
concurrently. The adapter reports prepared, refreshing, displayed, or failed;
only displayed advances `currentAsset`.

Exact firmware tooling and networking silicon are deliberately not selected:
the choice must demonstrate Wi-Fi, mutual TLS, secure key storage, atomic flash
slots, measured power/refresh behavior, and a pinned reproducible build. A
factory-programmed network coprocessor is acceptable if its protocol and
update lifecycle are documented.

The Paper frame cannot remain available on the LAN while asleep. It wakes on a
timer or button, checks the host outbox for a committed still, refreshes if
needed, then powers down its radio and display rails. The protocol therefore
supports host push for continuously powered frames and authenticated pull for
sleeping frames.

### Nerves appliance boundary

The official Pi 5 Nerves system is the selected base for a separately
qualified, always-powered external bridge/appliance. It is not inside a
reference frame. The image has its own signed firmware validation/revert,
persistent `/data`, identity provisioning, and bounded logging gates; see
[Linux and Pi hosts](../host/linux.md). A full library on the appliance uses
the same SQLite/object store. Nerves does not alter MCU controller selection.
Source: [Nerves Pi 5 system](https://github.com/nerves-project/nerves_system_rpi5).

### Firmware updates

Firmware updates must be signed and atomic before remote update is enabled.
The frame needs two firmware slots or an equivalent recoverable scheme.
The MCU implementation must continue to display the last valid image during
update, reboot, failed download, or unavailable update service.

## Swift/SwiftUI boundary

Swift owns only what is genuinely native to macOS:

- `MenuBarExtra` and the popover-like window;
- file pickers, drag/drop, pasteboard, notifications, and accessibility;
- Keychain/Secure Enclave credentials;
- Bonjour browsing and Network framework connections when advantageous;
- Vision classification and feature prints;
- Core Image/Image I/O decode and preview;
- MediaGenerationKit integration;
- `SMAppService` lifecycle registration.

Apple documents `MenuBarExtra` window style for data-rich menu extras and
`LSUIElement` for hiding the Dock icon. The packaged app uses a menu-bar agent
with the selected artwork retained as its Finder icon. `SMAppService` is the
supported control surface for bundled login items and launch agents. Sources: [MenuBarExtra](https://developer.apple.com/documentation/SwiftUI/MenuBarExtra)
and [Service Management](https://developer.apple.com/documentation/servicemanagement/).

The Swift layer must not duplicate library, recipe, scheduling, or frame state.
It submits commands and subscribes to snapshots from the Elixir core.

### Native Vision source check

Observed on 2026-10-04: the installed MacOSX27.0 SDK (`26A425`) exposes
`VNClassifyImageRequest` revisions 1/2 and
`VNGenerateImageFeaturePrintRequest` revisions 1/2. Its header makes feature
revision 2 available from macOS 14 and associates it with classifier revision
2. `VNObservation` conforms to `NSSecureCoding`;
`VNFeaturePrintObservation` supplies element type/count/data and
`computeDistance`, which refuses non-comparable prints. Its distance description
orders greater values as more dissimilar, not a normalized probability.

The SDK's `VNRequest.cancel` documentation promises an attempt to abort as soon
as possible, with cancelled results absent. It does not supply an enforceable
thread-termination deadline. The selected adapter therefore bounds caller wait
and retains its sole worker slot until execution exits; a timer alone cannot
authorize another native inference worker. The older `usesCPUOnly` switch is
deprecated from macOS 14, so it is not used to claim local execution or hardware
qualification. Vision owns its supported native compute-device selection.

Primary locators are Apple's
[classification request](https://developer.apple.com/documentation/vision/vnclassifyimagerequest),
[feature-print request](https://developer.apple.com/documentation/vision/vngenerateimagefeatureprintrequest),
[feature-print observation](https://developer.apple.com/documentation/vision/vnfeatureprintobservation),
and [cancellation](https://developer.apple.com/documentation/vision/vnrequest/cancel()).
The installed SDK headers `VNClassifyImageRequest.h`,
`VNGenerateImageFeaturePrintRequest.h`, `VNObservation.h` and `VNRequest.h`
were inspected at those exported boundaries. The source check supports a
bounded adapter implementation; accuracy, exact installed producer/consumer
behavior, oldest-supported-macOS execution and local-only traffic measurements
require separate recorded tests.

### Native Mac bundle closure

Observed 2026-10-05 on Apple Silicon macOS 27.0.1 with Xcode SDK 27.0
(`26A425`) and Swift 6.4. The development bundle's declared minimum of macOS
14 conflicted with actual Mach-O headers: the Zig worker required 27.0.1,
Exile required 27.0, and OTP 29.1 required 15.0. Five upstream grammar files
were group-writable. The Swift shell had an absolute Xcode Swift 6.2 RPATH
although its recorded imports were Apple system libraries, without `@rpath`
imports. These are inspections of this bundle, not observations on older Macs.

Apple recommends repairing library paths in the build system where possible;
changing them with `install_name_tool` invalidates existing signatures and
requires signing again. Its
[nonstandard bundle guidance](https://developer.apple.com/documentation/xcode/embedding-nonstandard-code-structures-in-a-bundle)
also distinguishes runtime-writable state from immutable bundle content. The
development stage retains the OTP layout while signing native leaves before
the enclosing app; installed Developer ID/hardened-runtime qualification of
that nonstandard layout is still required.

Loader metadata was reviewed against Apple's
[Mach-O declarations at XNU f6217f8](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/EXTERNAL_HEADERS/mach-o/loader.h)
and [fat wrapper declarations](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/EXTERNAL_HEADERS/mach-o/fat.h).
The installed SDK's `mach-o/fat.h` additionally declares the 64-bit fat wrapper.
The bounded reader checks regions before allocation, generic arm64/x86_64
subtypes, file types, macOS deployment commands and loader strings. It accepts
system and explicit bundle-relative imports, refusing inherited run-path
resolution. Static parsing cannot establish older-OS symbol availability,
runtime `dlopen` behavior or code-signing policy.

The pinned Zig 0.16.0 `std/Target/Query.zig` accepts versioned OS targets;
`aarch64-macos.14.0` builds the worker with an observed 14.0 header. Exile
0.15.0's Makefile invokes the compiler directly and respects
`MACOSX_DEPLOYMENT_TARGET`. Exqlite 0.42.0 needs a clean native build and
`:elixir_make`'s actual `:force_build` application setting: a nonempty
`EXQLITE_USE_SYSTEM`, even `0`, selects system SQLite and cannot request the
vendored closure. Packaging unsets that variable and rebuilds the vendored
NIF; observed Exile, spawner and SQLite headers then require 14.0. No load
command is patched to lower its minimum.

The new static gate inspects 24 native files in the freshly signed development
app, including OTP crypto/ASN.1 and dynamically opened Exile/SQLite code.
The bundle declares its actual greatest native minimum, 15.0.0. Small actual
arm64, x86_64 and universal compiler fixtures establish CPU/deployment parsing,
contained/missing loader targets, exact unused-toolchain-path removal and
nested ad-hoc signing. Malformed regions, unsafe modes, changing inodes,
links, sparse oversized files and oversized namespaces refuse. These fixtures
do not qualify Intel execution, a universal host release, macOS 14 or 15
runtime behavior, production signatures or a DMG. See the
[Mac closure contract](../host/macos.md#native-closure-admission).

### Development disk-image source and readback

Observed 2026-10-05 with the same Mac/SDK cohort. Apple's
[packaging guidance](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
specifies a staged product directory, `ditto`, disk-image creation and a
separate distribution-signing/notarization path. The installed macOS 27
`hdiutil create/attach/detach` help now warns that these commands are deprecated
in favor of `diskutil image`/`diskutil eject`, but still exposes the compatible
UDZO, HFS+, checksum, read-only, explicit mountpoint and no-autoopen options.
The candidate uses that inspected compatibility surface; no assertion is made
about the replacement API or tools on an older build host.

The complete current ad-hoc app produces a 23,531,333-byte development DMG.
Its SHA-256 is retained in private metadata beside the exact 281,753-byte
bundle observation, including 98 directory paths/modes. Actual read-only mount,
app inventory, native closure,
ad-hoc seals, reading text and `/Applications` link agree; detach restores
the original private mountpoint. A second invocation repeats mounted readback
with the same retained archive bytes and hash, rather than rebuilding it.
These results concern this local container, not a publicly authenticated image.

Small compiler fixtures include a universal app's exact mounted readback and
unchanged replay. Changed archive bytes, metadata aliases/permissions, a
changed independently re-signed source, failed creation and incomplete rerun
refuse without replacing retained custody. A lost response after an actual
attach still detaches its private mount before refusing completion. An injected
detach refusal preserves the actual read-only mounted filesystem and pending
workspace; fixture cleanup then explicitly detaches it. The tool boundary
limits child output and kills a timed-out child, without claiming that process
exit removes an OS mount. The
[development image contract](../host/macos.md#development-disk-image-custody)
keeps stable source, licenses, universal host assembly, production signatures,
notarization, Gatekeeper and installed/update evidence separate.

### Universal development join source and consumer

Observed 2026-10-05 with the same Mac/SDK cohort. Apple's
[universal binary guidance](https://developer.apple.com/documentation/apple-silicon/building-a-universal-macos-binary)
describes separate arm64/x86_64 compilation and merging the results with `lipo`.
The installed tool exposes `-create`, `-archs` and `-verify_arch`; the fixture
uses actual separately compiled executables and dylibs. Native code is signed
again after merging, with all leaves before the enclosing app. Cross-compiling
and inspecting Intel code on this Mac is not native Intel execution evidence.

The consumer checks all required and additional native files, rather than just
the Swift shell. Common file bytes/modes and directory paths/modes must agree;
the two parsed plists must agree except their observed OS minima. Only the
enclosing regenerated `CodeResources` and plist are excluded from raw common
byte comparison. Conflicting BEAM/configuration/resource files cannot be
silently taken from one CPU build. The current core build configuration contains
an absolute default renderer path, while its runtime configuration and bundled
launcher supply the shipped worker path. Actual independent producer builds
must make retained common configuration/BEAM bytes agree; the join refuses
instead of rewriting those opaque artifacts to conceal a producer difference.

Six fixture groups pass exact merged CPU/type/minimum/seal checks, native arm64
fixture execution, retained replay and the actual mounted universal DMG consumer.
Directory drift, common bytes, plist identity, wrong/fat CPU input, file-set/type
conflict, failed merge, an input changed during merge, metadata aliases and
output/namespace changes during replay refuse while retaining custody. Closure
observation schema v2 now records directory paths/modes, including empty
directories; their drift changes the recorded observation. This bounds a
development assembly mechanism. The full matching Intel/Apple Silicon host
producer, source/license cohort, older-OS/Intel execution and production signing
remain independent requirements under the
[join contract](../host/macos.md#universal-development-bundle-join).

### Tagged native Mac source and producer

Observed 2026-10-05 with macOS 27.0.1 (`26A434`), Xcode 27.0 (`27A266a`),
SDK 27.0 (`26A425`), Swift 6.4, Elixir 1.20.4/OTP 29.1 and Zig 0.16.0.
The exact clean isolated test tag binds source commit
`73ae9f4823515b448fce761b67a3da04cf5e55b2` and source-input SHA-256
`b03d625b512457fd5e0a41adb99fd35521ec6ec9be24cb3e6eeb8bf89dbf5d07`.
The native producer captures 1,464 dependency/Gleam source-material files
(21,873,908 bytes), excluding private Git metadata and generated native code.
These are inspected local cache bytes, not authenticated upstream provenance.

The clean recipe compiles the native compiler/runtime dependencies in a separate
Mix VM before rebuilding Exile and vendored SQLite. Elixir 1.20.4's
[dependency task](https://github.com/elixir-lang/elixir/blob/v1.20.4/lib/mix/lib/mix/tasks/deps.compile.ex)
loads cached dependency status and compiles selected dependency names; the
fresh producer checks this actual startup boundary rather than inheriting a
warm build's helper modules. Source/material/tool observations are repeated
after building and copying, alongside shell and core release descriptors.

The retained app has 1,417 files, 96 directories, 24 native items and
39,261,132 bytes, with actual minimum 15.0.0. Its 527,900-byte candidate record
has SHA-256
`c5e650ae2b70bd297123f51959ccb09e373713bc12dec2a1a341c074be7524b5`.
Actual packaged authenticated Swift/core IPC, PNG import, restart and offline
backup/verify/restore/refusal checks pass. A no-build replay preserves the source
and record hashes. Six fixture groups cover hidden source, material, tool,
version, physical-CPU and copied-byte changes, aliases, unknown/incomplete
output and finite tool refusal. Publication authority is `none`; this test tag
does not qualify native Intel, upstream provenance, licenses, older-OS execution,
production signatures or installed distribution. See the
[producer contract](../host/macos.md#tagged-native-mac-build-candidate).

### Source-bound Mac candidate consumer

Observed 2026-10-05 on the same Mac cohort. The source-bound consumer admits
each retained canonical candidate record against an independently supplied
SHA-256 and the actual frozen Git/Mix source record. It joins source/product/
version identities, exact single-CPU bundle observations, native seals and
actual core descriptors. Matching compiler identities exclude CPU-target and
host scheduler details while preserving exact Xcode/SDK, Swift compiler,
Elixir/ERTS and Zig versions. Ordered captured dependency-material facts agree
without discarding differing common BEAM/configuration/resource bytes.

Seven fixture groups join actual separate CPU compiler-role apps, merge all
seven native roles, execute the arm64 fixture and preserve an unchanged replay.
Wrong source/digest/material/compiler/execution/runtime records, record aliases,
noncanonical/oversized metadata, hidden source or record changes during merging
and changed parent/universal custody refuse. A late universal mutation during
input rechecking is detected by final app/child-record admission. The captured
full 24-native-file arm64 host passes the same receiver against candidate SHA-256
`c5e650ae2b70bd297123f51959ccb09e373713bc12dec2a1a341c074be7524b5`.

The receiver validates retained producer assertions and byte custody; it does
not recreate remote/native execution or authenticated dependency provenance.
The full universal host still needs the matching native Intel producer and
installed execution. Parent/child records have publication authority `none`;
source joining and independent digests do not grant production distribution.
See the [source-cohort contract](../host/macos.md#source-bound-universal-candidate).

### Mac native candidate archive consumer

Observed 2026-10-05 on the same Mac cohort. The system producer reports
`bsdtar 3.5.3 - libarchive 3.7.4`; POSIX USTAR with `COPYFILE_DISABLE=1`
preserves the admitted app's ordinary bytes and modes without AppleDouble
extension members. The shared release reader uses separate fixed Ubuntu and
Mac root profiles, compares every regular member with the opened archive
payload and checks exact directory names/modes. A same-size byte substitution
therefore refuses before candidate metadata can redefine those bytes.

Five Mac fixture groups stage and replay actual BSD archives for separate CPU
compiler candidates, then enter the existing source-bound universal join. Wrong
transport/source/CPU/profile, same-size candidate-record replacement, added
directories and source/namespace changes during readback refuse. Five shared
USTAR groups retain the malformed header/path/type/padding/terminator and exact
65,536-member limits, alongside descriptor/byte custody checks.

The complete retained arm64 host passes a 40,922,624-byte archive with SHA-256
`da96cf5c819b34fc927087d67c7def712a6af86a8a809f8207400392009131b3`.
Candidate record SHA-256 remains
`c5e650ae2b70bd297123f51959ccb09e373713bc12dec2a1a341c074be7524b5`.
An unchanged replay preserves the exact source, app, archive and handoff record.
Both retained full Ubuntu candidates also reverify their GNU USTAR payloads
through the shared reader without rebuilding or replacing custody. This is
local software transport, not hosted Actions/native Intel execution or upstream
authentication; publication authority is `none`. See the
[Mac archive contract](../host/macos.md#native-candidate-archive-handoff).

### Native Mac workflow profile

Observed 2026-10-05 using `gh` against runner-images commit
`6d942e630479cd99a93dadfc766af11242bfa402`. The
[runner labels](https://github.com/actions/runner-images/blob/6d942e630479cd99a93dadfc766af11242bfa402/README.md)
select `macos-26` for arm64 and `macos-26-intel` for x64. The inspected
[arm64 image](https://github.com/actions/runner-images/blob/6d942e630479cd99a93dadfc766af11242bfa402/images/macos/macos-26-arm64-Readme.md)
reports 26.6.2 (`25G83`, image `20260907.0351.1`), while the
[Intel image](https://github.com/actions/runner-images/blob/6d942e630479cd99a93dadfc766af11242bfa402/images/macos/macos-26-Readme.md)
reports 26.6.1 (`25G76`, image `20260824.0517.1`). Both list Xcode 26.6
(`17F113`) at `/Applications/Xcode_26.6.app` with SDK 26.5. These are dated
provider declarations; the workflow asserts the selected profile and records
actual tool/OS observations instead of assuming `macos-latest` is stable.

Apple's inspected
[XNU CPU selector](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/kern_mib.c)
sets `arm64_flag` to 1 for the arm64 kernel and 0 otherwise, exposing it as
`hw.optional.arm64`. Together with `uname -m`, this refuses an x86_64 process
translated on an arm64 kernel. It does not independently authenticate hosted
hardware or exclude every possible emulated environment.

The authored manual workflow reuses exact read-only remote/tag/source admission,
builds and checks the retained packaged host, writes BSD USTAR without
AppleDouble metadata, runs archive receiver/replay checks, rechecks remote
identity and uploads only the verified single file under a unique run/attempt.
Source, archive and candidate digests remain explicit in the job summary.
Credential/pinned/manual/target/transport invariants and the existing real
source/refusal fixtures complement local full producer/consumer evidence.
No hosted workflow was dispatched; full native Intel/common-byte acceptance,
upstream provenance/licenses, signing and installed distribution remain open
under the [workflow contract](../host/macos.md#native-mac-candidate-workflow).

## Zig boundary

The existing project-owned host raster executable is Zig. It accepts a
length-framed binary protocol on stdin/stdout and never receives credentials.
MCU firmware uses the exact controller's qualified SDK/language after a
reproducible build, signed update, TLS, and power/refresh spike. Keeping Zig
there is allowed only if it passes those gates.

The raster protocol carries a versioned job header and bounded canonical pixel
bytes on stdin/stdout. It emits one framed terminal result. The Elixir owner
enforces dimensions, output size and wall-clock deadline; installed process
memory limits require target-specific qualification. A crash fails one job
and restarts the port without automatic effect replay.

Zig is not a reason to rewrite high-quality system facilities. SQLite, image
codecs supplied by Apple, and vendor kernel drivers can remain upstream native
dependencies when their license and attack surface are reviewed. Keep the
existing Zig renderer while it passes its isolated-worker gates.

### Linux codec source cohort

**Source observation:** 2026-10-05; source inspection supports implementation,
not an installed release or measured color profile.

Linux needs original-byte decoding, orientation and canonical sRGB conversion;
the existing Zig raster input is already canonical RGBA8. Rewriting PNG/JPEG
decoders in Zig would add an unnecessary parser. Apple ImageIO remains the Mac
adapter. A system libpng/libjpeg/LittleCMS wrapper would require a C-memory and
target shared-library closure; the selected first Linux profile instead uses a
small isolated Rust executable with pinned upstream libraries. This keeps
Elixir orchestration and Zig raster behavior intact. Rust is selected for this
adapter's memory-safe producer boundary, not as a new host or generic engine.

The accepted software profiles are static PNG and the bounded 8-bit JPEG
subset below. Complete-container, primary Exif, assembled ICC, entropy
completion and cross-target bytes pass their software fixtures; CMYK/YCCK and
unqualified HDR/multiple-image/metadata extensions remain explicit refusals. The direct PNG
API exposes raw color chunks, unlike a convenience image wrapper that loses
precedence information and defaults malformed orientation to no transform.

| Producer | Exact inspected source / license | Consequence for this adapter |
| --- | --- | --- |
| PNG 0.18.1 | [image-png `2a3f980`](https://github.com/image-rs/image-png/tree/2a3f980245e3ae38b82ade96533e7b450e8477bb), `src/decoder/{mod,stream,zlib}.rs`, `CHANGES.md`; MIT OR Apache-2.0 | `new_with_limits`, checked optional output size, `EXPAND`, `finish` and raw color/Exif fields support bounded decoding. Explicitly enable Adler-32: its default ignores it. `zlib.rs` also tolerates missing checksums after enough output and ignores trailing compressed data; an independent bounded stream pass requires the exact scanline count, complete checksum and no second stream. `parse_iccp` discards parsing errors, so validate/inflate ICC separately and disable that upstream path. The changelog's duplicate-APNG tolerance is unsuitable for stillness admission: reject every animation marker in the container envelope. |
| moxcms 0.9.1 | [source `1e5305c`](https://github.com/awxkee/moxcms/tree/1e5305c77a0523acbd96721385ebe6dadfab6bc9), `profile.rs`, `transform.rs`, `trc.rs`, `writer.rs`; BSD-3-Clause OR Apache-2.0 | Use bounded `ParsingOptions`, complete matrix/gray profiles and row transforms. Disable default SIMD/LUT features and force relative colorimetric/fixed-point options. The release accepts zero-version ICC; this product profile deliberately requires v2/v4. Its gray-profile writer emits unaligned tag offsets in a generated fixture; keep decoder refusal and pad test-producer tags to conforming boundaries. No claim that its writer is a production source encoder. |
| kamadak-exif 0.6.1 | [tag source `52b53a2`](https://github.com/kamadak/exif-rs/tree/52b53a236b95b364c70d020b420148e0e25de4af), `reader.rs`, `tiff.rs`, `NEWS`; BSD-2-Clause | Default reader refuses partial parse errors. Iterate all fields because `get_field` would conceal duplicates; bound raw Exif before parsing and own primary orientation type/count/range. All 18 published `src/`, NEWS, LICENSE and README blobs match that tag. The crate's recorded VCS commit `ba531e6bb523bf7c01849cf8e679beff4ef960b0` is unavailable through GitHub; the lockfile checksum and compared source blobs establish the inspected cohort, not that unavailable ref. |
| flate2 1.1.10 | [source `ed93d4f`](https://github.com/rust-lang/flate2-rs/tree/ed93d4fc60eaf876c6aded741bf992d524551930), Rust backend; MIT OR Apache-2.0 | Inflate ICC through an output-limited checked zlib reader; require exact compressed-input consumption. No system zlib runtime. |
| crc32fast 1.5.2 and SHA-2 0.11.0 | [CRC source `7eb0b8a`](https://github.com/srijs/rust-crc32fast/tree/7eb0b8a2c9b246d27dc4cb5a53d3fc3b43a4bb83), [SHA source `ffe0939`](https://github.com/RustCrypto/hashes/tree/ffe093984c004769747e998f77da8ff7c0e7a765/sha2); MIT OR Apache-2.0 | Check all envelope CRCs and fingerprint exact source-color bytes. SHA-2's current edition/digest API is supported by pinned Rust 1.97.1; integer hash backend differences do not change digests. |

The current [PNG Recommendation](https://www.w3.org/TR/2025/REC-png-3-20250624/)
owns container ordering, alpha and color precedence. The adapter accepts a
smaller explicitly tested SDR profile; unknown transfer functions, LUT/HDR
profiles and unsupported primaries refuse rather than becoming assumed sRGB.
Original bytes preserve metadata that is not projected into the canonical
master. ICC, cICP and power-gamma interpretation retain separate digests.

`codec/Cargo.lock` fixes transitive versions and registry checksums. Native
changelog review includes PNG 0.18.1's checked sizes/chunk skipping and animation
tolerance, moxcms 0.9.1's version relaxation, flate2 1.1.10's refusal of incomplete
streams at EOF, crc32fast 1.5.2's integer tail-block changes and SHA-2 0.11.0's
digest API/MSRV migration. Exif's opt-in partial-reader mode remains disabled;
its 0.6.1 `Sync` fix introduces no different orientation admission. The adapter
explicitly exercises refusal paths that differ from convenient producer defaults.
Native
fixtures test actual library exports and complete process framing. Before
shipping, independently verify Ubuntu amd64/arm64 binary/runtime closure,
the common golden corpus, OS memory/deadline enforcement, dependency advisories
and the complete license-notice inventory. A mismatch invalidates that target's
codec admission; it does not authorize an alternate decoder or an automatic
fallback. The [content pipeline](../architecture/content-pipeline.md#linux-native-normalization)
owns requirements, while the [verification ledger](../architecture/verification.md)
records actual executions.

#### JPEG admission source review

**Observation and experiment:** 2026-10-05. The crates.io sparse index reports
zune-jpeg 0.5.15 as the latest stable release and 0.5.16-rc2 as the newest
candidate; jpeg-decoder 0.3.2 and fixture-only jpeg-encoder 0.7.1 are current
published versions. These are dated observations, not future upgrade claims.

The initial candidates fail complete-image admission. With scalar code and
strict mode, zune-jpeg [0.5.15 source `31d81fe`](https://github.com/etemesi254/zune-image/tree/31d81fed7551c8ccea456d9d8e2b1fd8bebb6995/crates/zune-jpeg)
and [0.5.16-rc2 `c93e77f`](https://github.com/etemesi254/zune-image/tree/c93e77f5652f76fa77bf7a3823f360f65ceaab6f/crates/zune-jpeg)
accept every tested truncation of a generated 32×24 RGB baseline's 1,299-byte
entropy segment, including zero retained entropy bytes followed by EOI. They
also accept all nine first-scan truncations of the progressive counterpart.
jpeg-decoder 0.3.2 behaves the same without a patch. This is actual code
execution against those fixtures, not a claim about every possible JPEG.
A marker walk cannot detect fabricated decoded coefficients after an early EOI.

zune's `bitstream.rs` pads after markers and its baseline `mcu.rs` contains
successful early returns. The packaged changelog ends at 0.5.7 and includes
truncation tolerance; missing later entries do not establish strict admission.
The [August 25 truncation change](https://github.com/etemesi254/zune-image/pull/431)
addresses reader EOF and resumable output, which does not resolve the forged-EOI
experiment. zune-core 0.5.3's recorded VCS ref is unavailable through GitHub;
its packaged sources do not all match the JPEG source revision. Neither crate
is selected in this codec. zenjpeg 0.8.4 exposes strictness/resource controls,
but its larger encoder/HDR dependency surface and AGPL-3.0-only/commercial
license would introduce independent scope and licensing decisions; it is not
selected or claimed to pass these experiments. A C libjpeg wrapper would change
the memory-safe producer and native closure boundary and is not needed for the
bounded correction below.

The selected implementation source is
[jpeg-decoder `eb2d7c0`](https://github.com/image-rs/jpeg-decoder/tree/eb2d7c0f6a2d0298aba7a7f8b9ca1440353e8f8c),
MIT OR Apache-2.0. All 21 published Rust source, README, changelog and license
blobs match that revision. `huffman.rs` currently pads its lookahead with zero
bits after markers; consumption does not distinguish those bits from source.
The maintained vendored patch records actual-bit availability independently,
refuses consumption beyond it, checks all-one terminal padding, refuses excess
EOB runs/terminal restarts and selects the immediate worker. Platform-independent
compilation forbids unsafe code and removes SIMD dispatch. No JPEG entropy,
IDCT or upsampling algorithm is reimplemented. The original source manifest,
license texts and exact patch are retained beside the vendored owner. Replacing
that patch requires the same refusal and byte corpus, not a version-only update.

The 0.3.2 changelog fixes a prediction panic; earlier documented behavior includes
rendering incomplete progressive coefficients, ignoring extraneous entropy and
non-identical SIMD output. The adapter owns full segment admission, complete
coefficient scan progression and explicit color transforms; it does not infer
strictness from this changelog or the decoded-buffer limit. That limit checks
output size and does not cover internal coefficient allocations. Common source
bounds and restricted sampling bound padded geometry; installed RSS enforcement
is still an independent acceptance gate.

Fixture encoding uses [jpeg-encoder 0.7.1 `baf4019`](https://github.com/vstroebel/jpeg-encoder/tree/baf40191ae25a32e56a884fa6e001c4fe938d451),
`(MIT OR Apache-2.0) AND IJG`; all 16 published Rust/README/license blobs match.
It is a development dependency, not a shipped encoder or proof of arbitrary
camera compatibility. The package has no changelog and its GitHub release body
is empty. Exact v0.7.0–v0.7.1 source changes add block alignment, opt-in box-average
chroma, quality accessors and the missing IJG license text. Fixtures retain the
explicit nearest-sample/default scalar encoding cohort; these source changes
do not authorize enabling encoder SIMD or a product export path. Its sampling, progressive and restart exports generate
positive inputs and systematic entropy-deletion counterexamples.

[ITU T.81](https://www.w3.org/Graphics/JPEG/itu-t81.pdf), B.1.1.2/B.1.1.5,
B.2 and F.1.2.3, supplies marker lengths, stuffing, scan structure and all-one
Huffman padding. [CIPA Exif standards](https://www.cipa.jp/e/std/std-sec.html)
currently list Exif 3.1; the admitted legacy color/orientation subset is narrower.
The [Exif 2.3 text](https://www.cipa.jp/std/documents/e/DC-008-2012_E.pdf),
4.6.5, defines ColorSpace 1/65,535 and gamma. The adapter refuses unqualified
3.x/alternate color declarations instead of assuming their semantics. Restricting
APP segments also refuses MPF/MPO, gain-map/HDR and unknown extension declarations
before they can be silently discarded by the decoder. This is a bounded JPEG
profile, not conformance to every T.81/Exif extension or measured color proof.

The patched probe preserves complete baseline/progressive fixtures and rejects
all 1,308 tested first-scan truncations. Eighteen maintained JPEG tests now
extend this to every scan, orientation, assembled RGB/gray ICC, explicit Exif
color, padding/EOB/restart rules, metadata/geometry/scan bounds and process
framing. The unchanged forty PNG vectors and 98 JPEG vectors match macOS arm64,
pinned Linux arm64 and emulated amd64. Actual authenticated upload/CLI/Library
fixtures retain the exact fixed JPEG original, pixels, media/cohort provenance
and durable result across a complete host-VM restart. These are software
fixtures; installed Ubuntu, OS memory enforcement, physical storage and
measured display color remain independent evidence.

Cargo-audit **0.22.1** reports no vulnerabilities or warnings for all 29 entries
in this lock against [RustSec `ef6173c`](https://github.com/RustSec/advisory-db/tree/ef6173cbc5c50ec8166f9a5b28f07834144373ee),
retrieved through `gh` on 2026-10-05. This includes fixture dependencies and the
pinned source-patched package. An advisory scan does not audit the local patch
or replace source/refusal tests; the maintained source-check reverses that
patch and checks every preserved upstream file hash.

#### Codec process transport cohort

**Source observation:** 2026-10-05. The selected transport is Exile **0.15.0**,
[tagged source `a4f29f3`](https://github.com/akash-akya/exile/tree/a4f29f31adc3c6bd2fe43ac62dc07a9eeb3bf413)
under Apache-2.0. All sixteen published `lib/`, `c_src/`, Makefile, README,
license and Mix source blobs match that tag. `apps/core/mix.lock` records the
published checksum `eb520ea43e26793abff619d3bc3fda358b6bed5ea8ed4d3715f66b4b27ca438b`.
The [September 14 release notes](https://github.com/akash-akya/exile/releases/tag/v0.15.0)
separate cancellation timeouts/input-producer failures and fix startup failure
handling/stale native builds; source and target fixtures remain necessary.

Plain OTP ports do not supply stdin close while continuing to consume stdout;
closing a port alone does not establish native termination. Exile's public
`start_link`, `write`, `close_stdin`, bounded `read`, `kill` and owner-only
`await_exit` match this one-shot boundary. It uses a small C NIF for nonblocking
descriptor IO/signals and an exec helper, not an in-process image parser.
`Exec.start` has separate two-second accept/descriptor-handshake timeouts;
these do not bound decoding. IO and `kill` calls can wait indefinitely at the
GenServer boundary, so the host's deadline/watchdog and retained reservation
must remain independent of those calls.

Three source details materially constrain integration:

- `process/exec.ex` creates its random handshake socket directly in
  `System.tmp_dir!()` without a peer-UID check. Its socket is protected by an
  already-private service temporary directory, selected once before runtime;
  per-job environment or working-directory options do not change that parent.
- Exec environment options inherit unspecified variables. Run the exact
  staged binary through protected `/usr/bin/env -i`; normal stderr goes to
  `/dev/null`. Admit/mark the primary Logger privacy filter before original
  writes because `process.ex` has no redacting `format_status` callback.
- `await_exit` closes owned pipes and escalates through SIGTERM/SIGKILL, with
  a 500 ms SIGKILL grace. `watcher.ex` also attempts owner-death cleanup, but
  a cleanup attempt is not an exit receipt. Preserve unknown custody and fence
  replacement with the exclusive staging directory.

The Makefile marks both `priv/exile.so` and `priv/spawner` phony. Target
qualification nevertheless compiles them freshly for each architecture against
the pinned Linux/OTP image's headers: copying host-built NIFs or trusting a cached Mix dependency would not
establish ABI closure. The Linux fixture uses portable locked BEAM code with
new target native artifacts; it does not load the Mac SQLite NIF or claim an
installed Ubuntu release. Reaping, backpressure, replacement refusal and
logging fault injection are consumer acceptance, while complete VM/service
shutdown and resource enforcement remain installed-release gates.

The Linux index fixes Elixir 1.20.4 and **OTP 29.1.1**; local native core tests
use `.mise.toml`'s OTP 29.1. The fixture checks its exact version rather than
claiming identical runtime versions. On this arm64 Docker VM, the emulated
amd64 runtime fails during `prim_tty` NIF startup with default dual JIT mapping;
`+JMsingle true` permits that bootstrap. OTP's
[29.1 runtime documentation](https://github.com/erlang/otp/blob/OTP-29.1/erts/doc/references/erl_cmd.md#L793)
describes this switch for user-mode emulators. The fixture selects it only when
target and Docker-daemon architectures differ; native targets keep the default.
That emulated run does not qualify native amd64 performance, the default JIT
memory protection or an installed release.

## Explicit exclusions

- **Membrane:** no role because Frameshift has no video, audio, animation, or
  streaming pipeline.
- **A browser/Electron shell:** unnecessary for a tiny menu-bar utility and
  weaker access to the desired native lifecycle and Vision APIs.
- **In-process NIFs for custom raster work:** a memory error can crash the BEAM;
  an executable port is the safer first boundary.
- **Project-owned Python:** absent from application, firmware, scripts, tests,
  and examples. Pinned upstream build tools may require it inside an isolated
  reproducible firmware/system build environment.

## Qualification gates

The stack is release-qualified only after these gates:

1. bundle and notarize a Swift menu app with a per-user Elixir release;
2. survive core and raster-worker crashes without losing a queued job;
3. measure idle RSS and wakeups on the oldest supported Mac;
4. retain a frame asset across abrupt power loss and complete a signed firmware
   rollback on the selected MCU;
5. drive one exact display revision for whichever hardware track is being
   implemented; each other adapter qualifies independently when its track is
   chosen;
6. prove the selected MCU toolchain and Wi-Fi/TLS path before naming any
   controller reference hardware, plus sleep current for Paper or refresh under
   load for Pixel when those tracks are chosen.

### Ubuntu runtime and service source review

**Observation:** 2026-10-05. Ubuntu's [release-cycle table](https://ubuntu.com/about/release-cycle)
keeps 24.04 LTS in standard security maintenance through May 2029. Select it as
the first bounded packaging baseline, rather than infer ABI compatibility from
the existing Debian trixie fixtures or automatically add each newer LTS. This
selection is an implementation target; it is not an installed qualification.

The Hex-maintained `hexpm/elixir:1.20.4-erlang-29.1-ubuntu-noble-20260911`
[image](https://hub.docker.com/r/hexpm/elixir/tags?name=1.20.4-erlang-29.1-ubuntu-noble)
has immutable index digest
`sha256:5b77ba2dec41d6d1716b354bbca92cd9359ed02b273f92eeabd0c92f9c9bdeee`,
amd64 manifest `c86fb7f726be9f0407db55afe38a2450fe3c4836ecafe9871ad1d1a26c044fd7`
and arm64 manifest `9fec2080e5bb7e287689eb3a39465b0d8683758b73e75fe7805f0337721cd205`.
The current official `ubuntu:24.04` runtime index is pinned to
`sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55`.
Image tags are dated observations; the build must use these digests and check
OS/version/architecture, not resolve a mutable tag on each run.

The [Hex bob source](https://github.com/hexpm/bob/tree/f9a485b487a44c21fffa4571fcecae1e8fc1913e/priv/scripts/docker)
uses target-native OTP builds with SSL and dirty schedulers and an OTP-major
Elixir archive. Current bob source alone cannot establish the pinned image's
producer inputs. An actual arm64
probe reports Ubuntu 24.04.5, OTP 29.1 / ERTS 17.1 and Elixir 1.20.4. `ldd` on
BEAM requires libtinfo, libstdc++, libm, libgcc and libc; crypto requires
libcrypto.so.3. Inspect every final shipped ELF/NIF/helper and test the release
in a clean runtime image; this sample does not establish the whole closure.

Ubuntu noble's [systemd.exec](https://manpages.ubuntu.com/manpages/noble/man5/systemd.exec.5.html)
255.4 documents that StateDirectory/RuntimeDirectory can recursively change
ownership when existing owners differ and normalize final permissions. That
behavior would hide a custody mismatch before application refusal. Use a small
root-owned pre-start provisioning helper that validates fixed ancestors/final
inodes, creates only missing directories and refuses mismatches. Persistent
private temporary custody deliberately keeps unknown import/native fences across
stops and reboot; a blanket systemd runtime cleanup would erase that evidence.

The [systemd service](https://manpages.ubuntu.com/manpages/noble/man5/systemd.service.5.html)
and [resource-control](https://manpages.ubuntu.com/manpages/noble/man5/systemd.resource-control.5.html)
contracts supply a dedicated User/Group, privileged maintenance prefix, bounded
restart/stop, control-group termination and explicit memory/task limits. Keep
BEAM JIT and native helper execution inside actual acceptance instead of assuming
any hardening directive is compatible. [Debian maintainer-script policy](https://www.debian.org/doc/debian-policy/ch-maintainerscripts.html)
requires safe repeated execution and defines failed-install/upgrade argument
forms. The DEB must retain private data and accounts on removal/purge and refuse
downgrades before unpack; script success alone is not an installed systemd test.

### Ubuntu DEB lifecycle source and fixture review

**Observation:** 2026-10-05. Current
[Debian maintainer-script policy](https://www.debian.org/doc/debian-policy/ch-maintainerscripts.html)
sections 6.2 and 6.5–6.6 require idempotency, bound which dependencies each phase
may assume and define upgrade failure unwind. Pre-install cannot depend on the
new package's files; post-removal must skip unavailable nonessential helpers.
The unpack contract explicitly follows existing directory symlinks. Therefore
pre-install embeds the archive's directory footprint and validates its root
ownership, real type and expected mode before dpkg may write beneath it.
It separately admits service-owned private state and a retained root-owned,
bounded version watermark; removal/purge cannot enable lower-version adoption.
Configuration revalidates that watermark before atomic synchronized publication,
including retries that do not run pre-install.

The selected Ubuntu 24.04 images install `init-system-helpers` **1.66ubuntu1**.
Actual source inspection gives `/usr/bin/deb-systemd-helper` SHA-256
`a895d5f077651960b6ca4ed9c53f8b36eae422ae170f61c972d0c6579e9f8732`
and `/usr/bin/deb-systemd-invoke` SHA-256
`92eadae89f4df4cd6088f6316f5390b685faf8d0e312a4e5af3a507caaf81bdb`.
The [Ubuntu invoke contract](https://manpages.ubuntu.com/manpages/noble/man1/deb-systemd-invoke.1p.html)
and selected source ask policy-rc.d before service actions. Policy status 101
returns success without acting, so a live service must be checked again after
stop; zero alone cannot authorize replacing runtime bytes. A disabled inactive
unit is not started. A previously active but disabled unit needs an admitted
private marker to restore its previous activity after stop or failed pre-install;
never unmask or grant user memberships as part of that recovery.

`release/linux/make-deb` inspects every ELF machine and derives versioned linked
library dependencies with target `dpkg-shlibdeps`; CA certificates and dynamically
loaded SCTP remain explicit dependencies. Avahi/D-Bus and runtime/provisioning
helpers are separately declared. `record-package.mjs` rejects mismatched runtime
identity and records every closure/packaging input, while the artifact records
the actual build-package versions. Pinned image identity does not pin future apt
repository contents; recorded installed versions are observations, not a claim
of independently reproducible archive bytes.

The `linux-deb` fixture performs actual dpkg lifecycle on both target architectures,
with no customer language tools or execution network. It retains exact Library,
credential sentinel, ownership/modes and unknown crash-custody bytes through
upgrade/remove/purge/reinstall. Controlled systemctl responses additionally test
Ubuntu helper and package-script refusal/error-unwind. This is joined package
software evidence; it does not establish booted systemd, native amd64 JIT,
physical storage/power, customer licensing/signing or publication.

### Packaged offline Library and identity join

**Observation:** 2026-10-05. Ubuntu's selected `util-linux` is
**2.39.3-9ubuntu6.6**. Its [flock command contract](https://manpages.ubuntu.com/manpages/noble/man1/flock.1.html)
supports exclusive nonblocking directory locks and a chosen contention exit code.
Upstream [v2.39.3 `sys-utils/flock.c`](https://github.com/util-linux/util-linux/blob/v2.39.3/sys-utils/flock.c)
(blob `6079920dff6bfa61d41ebdfa398cb2e189a635e5`, obtained through `gh`) opens
read-only by default, uses `LOCK_NB` for nonblocking acquisition and, in its
normal command mode, forks and waits for the child before returning. No close
option is requested; inherited custody can retain a lock. This upstream source
is not proof of identical Ubuntu patch inputs. Actual selected-package tests
join the documented syscall/process behavior to the packaged VM.

Lock the real admitted private data-directory inode, avoiding a removable
lockfile. The supervising process and existing live-socket check complement a
bounded clean-environment systemd status query for offline write operations.
A manager present with any state other than `inactive` refuses; unavailable or
hung status refuses after the finite query deadline. Verification of a named
backup needs no host-writer lock. These checks coordinate managed entrypoints,
not arbitrary database VMs or a replacement of the owned directory.

The existing `Frameshift.Library.Maintenance` and `Backup` already serialize,
verify and stage Library exports/restores. The Linux package therefore adds only
thin role/environment/locking entrypoints and an optional root provisioning
mode for private `/var/backups/frameshift`; it does not invent another format or
copy the whole service data directory. Restore is an absent candidate, never
implicit activation or replacement of the package watermark, credentials or
unknown import/codec custody. Private keys remain under the existing protected
stdin import and separately administered encrypted backup/re-pairing contract.

Actual arm64 and emulated amd64 DEBs pass early/live contention, concurrent
managed-start refusal, caller-environment isolation, literal path arguments,
private backup-root mode/symlink refusal, exact original/pixel/actor-receipt
backup/restore, corrupt-input and existing-destination refusal, fresh-VM
readback and verification while the host runs. A real generated certificate/key
PEM installs and replays through the public packaged identity command and resolves
as the service UID. Artwork exports/restores exclude the credential directory,
package watermark and temporary custody. Actual dpkg lifecycle preserves both
backups/restored candidates and private key bytes. Controlled manager-query
states/failure/deadline exercise the refusal contract; no booted-manager,
physical-storage or encrypted-key-backup qualification follows.

### Stable source record boundary

**Observation:** 2026-10-05. Git's current
[ls-files documentation](https://git-scm.com/docs/git-ls-files) defines stage-zero
index entries with mode/object identity and unquoted NUL-delimited paths.
[Git status](https://git-scm.com/docs/git-status) reports index/working-tree
changes, but a clean-looking status is insufficient for a frozen installer
input. Actual fixtures set `--assume-unchanged` and `core.fileMode=false`, then
change file content/mode while status stays empty. The selected implementation
therefore compares stage-zero index with the committed tree, hashes actual
regular descriptors and compares their Git blob identity and executable modes,
then repeats source capture before recording or verifying. Actual replacement-ref
and caller Git-directory/index/work-tree fixtures additionally establish that the
collector uses literal committed objects from the selected checkout. Hidden FIFO
replacement refuses before a reader opens or any output is created.

The existing versioned-docs tag/commit predicate now lives in `release/source.mjs`
and remains re-exported by the documentation owner. Source capture reads the
actual production Mix project configuration through `Mix.Project.in_project/3`
in a fixed standalone Elixir script. It does not start the product, load its
runtime configuration, compile dependencies or infer the app version from a
filename. Repository tests use real Git/Mix projects, including a version query
that deliberately mutates hidden source; no partial record publishes.

`release-source-inputs` is deliberately distinct from the signed artifact manifest
and each target's resolved-material/build record. Its deterministic private
record exposes hashes/relative paths and no publication authority. It cannot
prove ignored dependency cache bytes, native artifacts, an owner-authorized
remote tag, license selection, signing or installed qualification. Those remain
producer/workflow gates even after source capture passes.

### Tagged Ubuntu build and package handoff

**Observation:** 2026-10-05. The current
[Mix 1.20.4 release contract](https://mix.hexdocs.pm/Mix.Tasks.Release.html)
requires matching target architecture, OS and ABI for the runtime and NIFs,
and describes a build-only single JIT mapping for emulation. Frameshift keeps
its pinned Ubuntu 24.04 target compilation and ELF inspection; a stable tag does
not authorize copying a Mac NIF or relabelling a development runtime. The
[selected Ubuntu dpkg-deb interface](https://manpages.ubuntu.com/manpages/noble/man1/dpkg-deb.1.html)
supplies archive metadata and root-owned package construction. Final package
version is the stable application version, with no development fixture suffix.

`release/linux/prepare-context` now owns the preparation shared by development
and tagged candidates. Tagged source capture is checked before and after that
work; every copied project input is compared with the frozen inventory. Actual
dependency caches, tool archives and native bytes are additionally inventoried,
with their provenance assertion limited to captured bytes. The native build
consults generated core `.app`, `.rel` and start metadata; package construction
repeats the version check in a clean bundled VM. Runtime-to-package copying and
post-build context checks retain exact hashes rather than relying on filenames.

Private candidate records never grant release authority. Fixture source has an
isolated test-only tag/version; complete source/runtime/package/artifact records
remain separate from trusted signing, notices, qualified installed runners and
public channel acceptance. An identical retained candidate verifies without a
new build, because repeating a build does not itself establish identical bytes.

### GitHub candidate workflow and action scope

**Observation:** 2026-10-05, using `gh` to read current upstream releases and
exact action source. GitHub's current
[reference endpoint](https://docs.github.com/en/rest/git/refs#get-a-reference)
returns one exact ref or refusal, while matching-ref enumeration can return
other names. The candidate gate uses only the exact endpoint and computed
repository paths. It peels the
[annotated-tag object](https://docs.github.com/en/rest/git/tags#get-a-tag)
with bounded depth/deadline, ignores returned URLs and checks the independently
supplied commit. Local source verification is bracketed by remote checks;
target jobs compare the canonical source-record digest before compilation.

[GitHub's runner matrix](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
lists native Ubuntu 24.04 amd64 and arm64 labels. The workflow additionally
checks the runner OS/package CPU and Docker daemon architecture. Those choices
do not qualify an unexecuted job or booted service; local arm64/emulated amd64
candidate evidence remains its own tier.

[mise-action 5.1.1](https://github.com/jdx/mise-action/releases/tag/v5.1.1), source
`2d8d4cafcbd33be2ea37d2b6f5ad595363d1f1ca`, retains its GitHub token inside
the action by default. Both workflows explicitly keep persistence disabled;
only `gh` steps get an explicit contents-read token. Current
[checkout 7.0.1](https://github.com/actions/checkout/releases/tag/v7.0.1), source
`3d3c42e5aac5ba805825da76410c181273ba90b1`, preserves nonpersistent credentials
and its refusal of unsafe privileged fork checkout. Existing QEMU 4.4.0 is
pinned to `99012661954931238ded8c8b007157a8430204e1` without changing its selected
emulation image. These are action source/changelog observations and local
workflow syntax checks, not execution of the hosted runners.

[upload-artifact 7.0.1](https://github.com/actions/upload-artifact/blob/043fb46d1a93c77aae656e7c1c64a875d1fc6a0a/README.md#permission-loss)
does not preserve file modes through its zipped upload. It documents direct
TAR upload for that requirement. Candidate attempts therefore retain a single
TAR with private records and executable modes, use distinct run/attempt names,
disable overwrite and have finite retention. Their unsigned records carry no
publication authority; a later receiver must verify retained candidate and
archive bytes before release acceptance rather than treating an Actions ID or
digest as a customer manifest signature.

### Bounded candidate TAR consumer

**Observation:** 2026-10-05. GNU tar 1.35's
[POSIX USTAR header definition](https://www.gnu.org/s/tar/manual/html_node/Standard.html)
defines fixed 512-byte headers, octal metadata, a header checksum, name/prefix
fields and distinct link/device/extension types. Its
[portability guidance](https://www.gnu.org/software/tar/manual/html_node/Portability.html)
and [`--hard-dereference` option](https://www.gnu.org/software/tar/manual/tar.html)
support a deliberately narrow producer: uncompressed USTAR, one candidate root,
and hard-linked files copied as regular members. Extended tar formats and
unrestricted extraction add no required capability to this retained-byte path.

`release/ustar.mjs` verifies a separately supplied transport hash through
one bounded regular descriptor before interpreting those headers. It admits
only safe regular files/directories, bounds bytes/member count/time/free space,
creates exclusive private output names and preserves admitted modes without
restoring archived ownership. Candidate/source verification remains a separate
semantic check. Every regular member is compared byte-for-byte through bounded
no-follow descriptors against its admitted archive payload, including same-size
substitutions. Exact extracted directory names and modes matter on replay;
file hashes alone cannot detect an added empty directory or changed directory
permissions. The final record has no release authority and no manifest v1 fields.

Actual system USTAR producer fixtures cover extraction/custody and malformed
headers, paths, types, padding, terminators, metadata limits and the 65,536-entry
boundary. A pinned Ubuntu build image's GNU tar separately joins both retained
full-product arm64 and emulated-amd64 candidates to exact-source verification,
unchanged no-build replay and wrong-digest refusal. This is archive/software
evidence, not a hosted Actions transfer, native installed service, signing,
license review or public-channel release.

### Local manifest input custody

**Observation:** 2026-10-05. Exact
[Node 26.9.0 filesystem documentation](https://github.com/nodejs/node/blob/v26.9.0/doc/api/fs.md)
(blob `315ecdb97c430c5b1c38c3519ea609ac3784a9f4`, inspected using `gh`)
defines no-follow/nonblocking flags and fixed-position descriptor reads. Its
abort documentation explicitly distinguishes cancelled buffering from an
interrupted operating-system request. Local processing budgets therefore do
not establish a hard filesystem-syscall deadline.

Source inspection found unrestricted metadata/trust reads in the manifest
verifier and guide, blocking descriptor opens in the signer/archive reader,
and raw signed-input reads/copies in the site assembler. Real fixtures reproduced
accepted metadata symlinks, a stalled FIFO without a writer, loose trust-file
whitespace and direct archive-name traversal. A size test also distinguishes
bounded admission from rejecting oversized JSON only after loading it.

`release/files.mjs` now owns shared local release input admission. It refuses
nonregular names before opening, bounds descriptor reads, matches named/descriptor
identity and actual count, and enforces separately protected trust/private-key
custody. Guide and assembler consumers use that same boundary, retaining bounded
public metadata bytes for staging instead of copying unadmitted names. Raw
filesystem mutation fixtures and bounded CLI FIFO children pass. These findings
and checks establish local software behavior; they do not qualify a production
trust root, installed signing identity, hostile administrator, storage device
or public release channel.

### Existing public release reconciliation

**Observation:** 2026-10-05. Current GitHub
[release endpoints](https://docs.github.com/en/rest/releases/releases),
[asset endpoints](https://docs.github.com/en/rest/releases/assets) and
[repository metadata](https://docs.github.com/en/rest/repos/repos#get-a-repository)
are inspected under API version `2026-03-10`. A published tag lookup is not draft
enumeration: the release-list documentation limits draft visibility to users
with push access. A 404 therefore cannot prove there is no draft to reconcile.
Asset responses provide IDs, names, state, size, browser URL and SHA-256 metadata.
The API documents interrupted `starter` assets; automatic deletion cannot be
inferred safe from that state alone.

`release/channel.mjs` uses computed bounded `gh` GET endpoints and separately
verified signed local files. The selected profile observes only the manifest's
archives plus its detached JSON/signature/public key. Public URLs and channel
size limits are checked before networking. API digests are compared when present;
anonymous size/hash readback establishes actual served bytes. The observer then
checks local material and remote repository/release/asset identity again. It
never changes visibility, refs, releases, uploads or existing assets, and grants
no source, installer, licensing or publication authority.

Signed local/software fixtures cover complete/missing/draft/partial/conflicting
states, zero-request invalid inputs, absent API digests, served-byte tampering,
in-flight changes, request bounds and CLI exit/refusal semantics. A real `gh`
read checks the upstream checkout repository, v7.0.1 release/asset endpoint and
a distinct missing published-tag response. That transport observation does not
create a Frameshift release or qualify its public bytes.

### Local Mac channel material and Sparkle signature profile

**Observation:** 2026-10-05. `gh` resolves the current
[Sparkle 2.10.0 release](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0)
to commit `eef1a539a373c1f1a320624b1130fc5de7b2e100`. Its changelog raises the
minimum OS to 12.0 and recommends an explicit minimum-system field for manually
created feeds. That does not lower Frameshift's app/runtime minimum. The
[publication guide](https://sparkle-project.org/documentation/publishing/)
places version fields at item level and permits the same DMG for direct and
updater delivery. The [Homebrew Cask cookbook](https://docs.brew.sh/Cask-Cookbook)
owns version/SHA-256/URL, minimum OS and accurate in-app-update declarations.

Exact [archive verification source](https://github.com/sparkle-project/Sparkle/blob/eef1a539a373c1f1a320624b1130fc5de7b2e100/Autoupdate/SUSignatureVerifier.m)
verifies ordinary Ed25519 against the full archive bytes. Its
[`sign_update`](https://github.com/sparkle-project/Sparkle/blob/eef1a539a373c1f1a320624b1130fc5de7b2e100/sign_update/main.swift)
reads keys even in verification mode, making it unsuitable as a public-key-only
publisher verifier. The host's Node verifier instead admits separately pinned
32-byte public material and the exact signed DMG, with independent manifest and
Sparkle signature checks. The
[current secret decoder](https://github.com/sparkle-project/Sparkle/blob/eef1a539a373c1f1a320624b1130fc5de7b2e100/common_cli/Secret.swift)
accepts a 32-byte seed for newly generated keys. The isolated fixture uses this
format in a private file, without accessing any personal Keychain.

The upstream TAR fetched with `gh` is 16,319,840 bytes and SHA-256
`c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c`, matching the
release API's digest. Only `bin/sign_update` is extracted; its SHA-256 is
`43c249771bafc3aa581228abae00731a012d324691b8292860896635050be76b`.
On macOS 27.0.1 arm64 / Node 26.9.0, actual upstream signing matches Node signing
byte-for-byte; each verifier accepts the other's signature. The input bytes and
tool remain unchanged. This establishes the inspected signature profile, not
upstream binary derivation, production keys or an installed update.

Eleven channel groups pass exact tuple derivation, real Ruby/XML parsing of
quoted/escaped URLs, separate signature/hash refusal, bounded grammar/custody,
minimum declaration, missing target, unsafe/partial output, fixed FIFO/CLI
refusal and unchanged replay. Protected-seed signing, public-key-only verification
after deleting the ephemeral seed, signed-feed/footer/record tamper and an
authentically resigned but noncanonical OS declaration are also exercised. The
generator records local authority `none` and
separates the declared OS from qualification. Final app/version/key/updater
joining, runtime signed-feed enforcement, Developer ID/notarization, real tap, public readback and
installed update/removal remain open.

Apple's current [CFBundleVersion contract](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleversion),
read as its official Markdown representation on this date, defines one to three
numeric components, including non-negative zero values, and requires increasing
build identity before distribution. Frameshift uses its stable three-component
version for both build/display fields. Native producers check source, built and
copied plist values; source-bound receivers recheck them before/after joining.
Compiler fixtures refuse a clean tagged source with counter `1`, a changed built
counter and a resealed/fully admitted received app with the wrong counter. These
checks do not modify any retained archive or establish a running updater.

Exact [feed-signing source](https://github.com/sparkle-project/Sparkle/blob/eef1a539a373c1f1a320624b1130fc5de7b2e100/common_cli/Signing.swift)
appends a signature comment with the unsigned body's exact byte count. The
[runtime extractor](https://github.com/sparkle-project/Sparkle/blob/eef1a539a373c1f1a320624b1130fc5de7b2e100/Sparkle/SPUExtractSignedFeed.m)
locates and verifies that message. With the same exact upstream tool and
ephemeral seed, Node's complete feed bytes equal `sign_update
--disable-signing-warning -p` output, and upstream verification accepts them.
The fixture accesses no personal Keychain and creates no customer channel.
The protected local signer first binds its seed to the separately supplied
public key; the later consumer uses only public material and requires the
verified body to equal its regenerated canonical XML. Positive signing and
verification CLI cases and real signed XML parsing pass within the eleven
groups. This establishes local cryptographic/byte interoperability; application
settings, native framework custody and installed update behavior need their own
qualification.

### Sparkle framework custody and native consumer

**Observation:** 2026-10-06. The exact 2.10.0
[`Package.swift`](https://github.com/sparkle-project/Sparkle/blob/eef1a539a373c1f1a320624b1130fc5de7b2e100/Package.swift)
pins `Sparkle-for-Swift-Package-Manager.zip` with SHA-256
`17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959`.
The 10,193,895-byte asset fetched with `gh` matches that checksum. Its real
framework uses `Versions/B` and nine symlinks. Five Mach-O files contain arm64
and x86_64 slices, each declaring macOS 12.0; all inspected imports are Apple
system paths and these files have no run paths. The framework plist identifies
`org.sparkle-project.Sparkle`, display version 2.10.0 and build 2064. These are
observations of exact fetched bytes, not independent upstream build derivation.

The current [setup guide](https://sparkle-project.org/documentation/)
requires custom packagers to preserve symlinks/permissions and supplies an
explicit framework run path for non-Xcode builds. The
[manual signing guide](https://sparkle-project.org/documentation/sandboxing/#code-signing)
requires nested helpers/containers to be signed before their enclosing
framework. The existing release gate's blanket link and inherited-run-path
refusals therefore need a narrow evidenced profile, rather than flattened
framework copies or a generic dyld search approximation. The owning Mac contract
now defines that exact profile and records links separately from regular files.

Four compiled framework fixture groups and ten existing closure groups pass on
macOS 27.0.1 arm64 / Xcode 27. The actual pinned SDK fixture copies admitted
archive bytes into a private stage, compiles a real Objective-C consumer, checks
all nine aliases and both CPU metadata, signs nested code/containers outward,
verifies strict complete seals, and runs the arm64 consumer. The real
`SPUStandardUpdaterController` initializes with `startingUpdater: false` and
has an updater; no update check, network channel or signing key is used. This
qualifies this minimal native join, not the Frameshift application, Intel/older
OS execution, Developer ID, installed update or publication. Frozen SDK source
admission, architecture thinning/merging and app shutdown/settings remain
independent work.

The Mac candidate USTAR reader now admits only these nine exact paths/targets,
with zero link payload and complete real terminal members/parents checked before
output creation. Four new archive groups and five shared Ubuntu groups pass
alias/target/payload/mode/parent/partial/dangling refusals and immutable public
readback. Ubuntu and material profiles retain complete symbolic-link refusal.
The actual pinned SDK's ad-hoc fixture passes BSD USTAR extraction/readback,
identical full closure and strict nested seals after transport. All eight Ubuntu
candidate groups and seventeen Mac/Linux candidate/receipt receiver groups also
pass, including private CLI replay. This is parser/native-fixture evidence; it does not
create a frozen SDK source receipt, a source-bound full updater candidate or an
installed release. The fixed framework profile lives beside the shared archive
reader so isolated Linux receivers include its transitive source input.

A separate Swift 6.4 binary-target consumer pins the exact upstream URL/checksum,
imports the public updater controller and compiles in release mode. SwiftPM
workspace schema seven records that binary origin. Its copied framework is
byte-identical to the source artifact, including the original ad-hoc signatures,
and retains both CPUs. The linked Swift executable imports the expected
`@rpath/Sparkle.framework/Versions/B/Sparkle`; it also contains Apple's Swift
system path, a selected-toolchain path and the explicitly supplied owned
Frameworks path. This compiler observation does not establish a self-contained
running app; packaging must admit the actual cache and eliminate the unwanted
external search path under a bounded rule.

The material consumer verifies archive size/hash before invoking extraction
on those fixed admitted bytes, compares all 85 regular files, 57 directories and
nine aliases with the actual SwiftPM framework, and preserves pre/post archive
and cache custody. Six groups pass exact archive/cache/CLI admission and
same-size changed archive/cache, extra/missing member, altered alias, hard link,
unsafe mode, nonprivate stage and unsupported CPU refusal. Real `lipo` derives
all five native files for both CPUs in private unpublished stages; loader
metadata, every common file and alias, and per-slice signature verification
pass. This closes the local archive/cache/derivation experiment. Frozen
source/compiler joins, final app sealing, universal SDK assembly, runtime client,
upstream build derivation, license review and installed update remain separate.

The universal merger now compares complete fixed alias inventories and admits
differences in only the four actual SDK `CodeResources` paths. They encode
per-CPU nested seals and are regenerated after actual native merging; every
other SDK resource/header/plist remains byte-bound. Native and all four nested
container seals verify before and after assembly. Three actual-archive groups
and fourteen existing universal/DMG groups pass on the same Mac: twelve native
fixture roles with both CPUs, exact aliases, strict signatures, real arm64
stopped-controller execution, immutable no-effect replay, conflicting headers/
unknown signature paths and an outer-app-only reseal with corrupt nested bytes.
This qualifies the local merger with real SDK bytes and cross-compiled native
fixture roles; it does not establish a full native Intel producer, source-bound
universal host, installed update or production signing.

The independent updater source receipt uses SwiftPM's real `dump-package`
parser, rather than a source-text approximation, to bind the exact binary URL
and checksum to the frozen package manifest hash. Actual admitted ZIP/cache
facts and the verifier-source observation join the frozen product/tag/version/
commit/source-input digest in a canonical private record. Five groups pass real
Git/Mix/SwiftPM/SDK producer and independently pinned consumer checks, unchanged
inode/time on replay, wrong source/pin/profile/schema/digest, hard-link/alias/
unknown/partial output refusal and a same-byte cache rewrite during the second
manifest child. That last case requires pre/post inode/time custody as well as
hash equality and leaves the incomplete receipt marker retained. This is input
receipt evidence; captured compiler/native candidates, transported material,
application update behavior and remote/installed/rights proof remain separate.

The native candidate and material receivers consume that independently pinned
SDK receipt. They require the embedded framework and its 86 captured binary
inputs together, compare every original framework/archive path, mode, length
and hash, and preserve the separate core/Gleam source-file count and three
generated-input exceptions. Three actual SDK/compiler groups pass both CPU
joins, fourth-receipt BSD USTAR transport, immutable CLI replay, wrong receipt/
package/digest/input scope, missing/unsafe/extra member and child-time receipt
replacement refusal. The receiver recomputes and compares the joined receipt;
transport hashes alone cannot admit a semantically conflicting join. No-updater
and Ubuntu receipt profiles remain unchanged. These are retained-purpose native
consumer observations; the production compiler's SwiftPM-input capture and full
host updater integration still require their own join. Publication authority is
`none`; original universal SDK hashes do not describe newly thinned/resealed
app binaries or attest remote native execution.

### AppKit owned-core quit and modal-loop delivery

**Observation:** 2026-10-06. Apple's current
[`applicationShouldTerminate(_:)`](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldterminate(_:))
and [`reply(toApplicationShouldTerminate:)`](https://developer.apple.com/documentation/appkit/nsapplication/reply(toapplicationshouldterminate:))
contracts support a deferred termination decision and later main-thread reply.
[`Process.terminate()`](https://developer.apple.com/documentation/foundation/process/terminate())
sends SIGTERM, which a child may ignore;
[`isRunning`](https://developer.apple.com/documentation/foundation/process/isrunning)
reports actual launch/exit state rather than successful signal delivery. The
shell retains only successfully launched `Process` objects, so false here is
observed exit rather than an unlaunched object. Signalling and immediately
clearing custody did not implement the existing safe-quit requirement.

Three real-process fixtures pass cooperative exit, an explicitly TERM-ignoring
child with readiness confirmation and bounded uncertain/later read-only recovery,
and cancelled observation with the child still running. All 88 Swift tests in
20 suites and shell checks pass on macOS 27.0.1 arm64 / Xcode 27 / Swift 6.4.
A native diagnostic clone of the fresh ad-hoc package uses the production
coordinator and actual OTP launcher. Quit invoked inside an actor job reproduced
a deferred modal loop that prevented the queued main-actor observer from
starting. Running observation off that actor and posting its reply through the
main run loop fixes this fixture: ready/deferred/confirmed events, zero app exit,
the recorded OTP PID gone and PID file removed all pass. Original app and probe
bytes/seals remain unchanged. Fresh packaging, authenticated IPC and offline
backup/verify/restore/refusal checks pass separately.

This qualifies the programmatic AppKit/idle-core software join. The native UI
provider did not expose the packaged agent; keyboard quit, VoiceOver and the
uncertain-alert interaction remain unobserved. Active codec-child quit and
installed Sparkle/background lifecycle remain separate evidence requirements.

### Locked core dependency source admission

**Observation:** 2026-10-05. Inspected Hex 2.5.1
[`Hex.SCM`](https://github.com/hexpm/hex/blob/v2.5.1/lib/hex/scm.ex)
compares registry inner/outer checksums and writes a binary schema-two `.hex`
manifest after extraction. The eight-field Mix Hex lock carries both checksums;
matching a filename or manifest alone does not establish extracted source bytes.
The selected offline gate compares the archive's outer SHA-256 with the frozen
lock before invoking any archive parser, then compares identity/inner checksum,
raw metadata, SCM fields and every admitted file's bytes and permissions.
This relies on the caller-approved lock; it does not independently authenticate
the registry or publisher.

The pinned
[`mix_hex_tarball`](https://github.com/hexpm/hex/blob/v2.5.1/src/mix_hex_tarball.erl)
parser exports memory-only unpacking with explicit compressed/expanded ceilings.
Its vendored hex_core revision is 0.18.0 (`d6a6a5a`). The selected profile uses
64 MiB input and 128 MiB expansion. The vendored
[`mix_hex_erl_tar`](https://github.com/hexpm/hex/blob/v2.5.1/src/mix_hex_erl_tar.erl)
memory extractor returns regular-file contents while omitting other types.
A separate bounded table inspection is therefore necessary to refuse links,
FIFOs, devices, unsafe paths and duplicates before projecting file facts.
The bounded inflate loop uses OTP's
[`safeInflate`](https://www.erlang.org/doc/apps/erts/zlib.html#safeInflate/2),
counts each output chunk and refuses over-budget expansion before accumulation.
No source archive is extracted to disk by the verifier.

Literal Git lock commits and sparse prefixes are compared through sanitized,
replacement-free Git tree queries; actual bytes must match committed blob hashes
and modes. Fetch protocols are disabled for those queries. The three current
Wotex dependencies retain their sparse `packages/…` prefix inside each checkout.
Source inspection of the admitted package build files identifies five generated
EarmarkParser/Erlex `.erl` files from locked `.xrl`/`.yrl` grammars and
FileSystem's generated `priv/mac_listener`, alongside Exile/Exqlite native outputs.
Only these exact generated-source pairs are excluded; arbitrary `.erl` additions
refuse. Existing archive members always override exclusions. These generated
bytes still require independent producer qualification.

Eight real Hex/Git fixture groups cover admission/replay, hidden byte/mode/lock
changes, SCM/metadata/checksum conflicts, aliases/special files, namespace changes,
malformed members and finite resource/child refusal. The isolated exact-source
core cohort passes all 39 Hex archives and three pinned Git dependencies, retaining
1,380 admitted file facts. Receipt replay preserves inode and timestamp. This is
local source-byte evidence, not license approval, compiler authenticity, a clean
runtime derivation, hosted execution or a public release. The
[owning contract](../architecture/release-manifest.md#locked-core-dependency-source-bytes)
keeps Gleam/other-component material and producer joins separate.

### Locked Gleam dependency source admission

**Observation:** 2026-10-05. Gleam 1.18.1, revision
`4a83802ca33a8a96227a1b332768725f232f9779`, implements a deliberate generated
manifest serializer in
[`compiler-core/src/manifest.rs`](https://github.com/gleam-lang/gleam/blob/4a83802ca33a8a96227a1b332768725f232f9779/compiler-core/src/manifest.rs).
It orders package/requirement entries, writes literal name/version/build-tool/
requirement/optional-OTP-app fields and distinguishes Hex checksums from Git/local
sources. The selected offline profile accepts the current generated Hex form;
unconsumed syntax, duplicate/ambiguous fields or unsupported sources refuse.
It does not introduce a general TOML parser or dependency resolver.

The inspected
[`HexDownloader`](https://github.com/gleam-lang/gleam/blob/4a83802ca33a8a96227a1b332768725f232f9779/compiler-core/src/hex.rs)
addresses cached archives by their outer checksum. Existing archive/source paths
short-circuit download/extraction; their presence alone therefore cannot establish
current byte agreement with the lock. The offline gate hashes each bounded
archive before pinned Hex memory parsing and compares every delivered source
file's byte hash and permissions. Unlike generated core lexer outputs, supplier
Erlang files shipped in these archives are part of admitted source.

Gleam's
[`LocalPackages`](https://github.com/gleam-lang/gleam/blob/4a83802ca33a8a96227a1b332768725f232f9779/compiler-cli/src/dependencies.rs)
records fetched package versions and Git state in `packages.toml`. The selected
Hex-only profile requires exactly the locked name/version pairs and empty Git
state, with bounded root metadata and source/cache namespaces. An empty regular
`gleam.lock` is inspected but operating-system compiler-lock ownership is not
claimed.

Six real archive/source fixture groups pass, including the actual 128-package
literal boundary and successful private CLI replay. The combined core/Gleam
suite passes fourteen groups. The exact isolated source cohort admits
`gleam_stdlib` 1.0.5 and `gleeunit` 1.11.0 with 76 source files and unchanged
receipt inode/timestamp; the shared-parser core cohort also replays all 42 locked
dependencies. These prove agreement with approved frozen locks, not independent
publisher authentication, rights approval, compiler authenticity, generated-code
or runtime qualification. Producer receipt joins remain separate under the
[release input contract](../architecture/release-manifest.md#locked-gleam-dependency-source-bytes).

### Native candidate source-receipt join

**Observation:** 2026-10-05. The actual isolated Mac candidate captures 1,464
material files. Its independently pinned core/Gleam source receipts match 1,457
source/metadata paths, hashes and modes. The remaining seven are five generated
EarmarkParser/Erlex lexer/parser `.erl` files, FileSystem's native `mac_listener`
and the empty Gleam compiler-lock file. The first six are derived build inputs;
the source receipts deliberately do not qualify their derivation. The lock is
metadata, not authenticated source or operating-system lock ownership.

The selected receiver validates bounded canonical private receipts and frozen
lock/manifest identities, then compares every proved fact with the already
admitted candidate. Explicit generated exceptions retain their captured hashes
and reasons; any unexplained input refuses. Actual app versions, closure and
seals are checked separately. Final static receipt/candidate/bundle readback
follows all version/parser children, so a child-time change to another already
read input cannot pass completion. Source-receipt assertions are independently
pinned inputs, not remote execution or publisher authentication.

Git's current [global options](https://git-scm.com/docs/git#Documentation/git.txt---no-lazy-fetch)
include `--no-lazy-fetch` to prevent missing promisor objects being retrieved on
demand and `--literal-pathspecs` to prevent pattern interpretation. The admitted
dependency reader requires those options, ignores caller Git overrides and
replacement refs, and disables filesystem monitoring. An actual missing sparse
tree with an explicitly enabled controlled promisor helper refuses without
invoking the helper; an actual bracket-containing sparse directory admits by
literal identity. Unsupported Git installations refuse this source profile.

Six retained-assertion fixture groups use real Git/Mix source, CPU compiler
roles, version consumers and native seals. Successful CLI replay and in-flight
receipt conflict/refusal pass. The full 24-native-file arm64 host joins its actual
source-verifier receipts and preserves joined-record inode/timestamp on replay.
No build, signing, source normalization or candidate rewrite occurs. Independent
publisher/registry trust, licenses, compiler/generated-code authenticity,
native execution attestation, installed support and production distribution
remain separate under the
[owning join contract](../host/macos.md#candidate-dependency-source-join).

### Dependency source evidence transport

**Observation:** 2026-10-05. The strict Mac app archive carries only the native
candidate and app. Adding source receipts inside that root would change its
admitted namespace and invalidate the existing receiver contract. The selected
transport is a separate four-member `macos-material/` POSIX USTAR: its private
root plus the core, Gleam and dependency-input joined receipts. Its fixed
33 MiB archive, 16 MiB source-receipt, 64 KiB joined-receipt and four-member
ceilings are checked before descriptor extraction. The app and Ubuntu profiles
retain their existing roots and bounds.

The receiver compares independent transport/receipt/candidate digests, invokes
the existing source join against the admitted app, and requires its own joined
record to equal the received record byte for byte. A correct archive hash alone
cannot make conflicting source assertions pass. Final static archive, extracted
member, candidate/app and namespace checks follow all child consumers. Successful
replay retains the same receipt and handoff inode/timestamp; incomplete or changed
custody is preserved and refused.

The full retained native arm64 host and its actual 42-core/two-Gleam source
receipts pass a 255,488-byte BSD USTAR and unchanged replay, with 1,457 matched
facts and seven classified generated/lock inputs. The archive SHA-256 is
`489b6110a4ce770bec2a8556aa2ed149702cad998d6d137d8d38f00ad98b0aee`;
the receiver handoff SHA-256 is
`e3f8a09667d16779a8eaed5c7d1c405b777c1b2268f8c14e65142d8a1479d4df`.
This is local byte/consumer evidence under the
[receipt handoff contract](../host/macos.md#dependency-source-receipt-archive-handoff),
with publication authority `none`. It does not authenticate original producer
execution, a publisher, licenses, generated code or toolchains, and does not
establish hosted/native Intel, installed or production distribution acceptance.

### Gleam fetched metadata reproducibility

**Observation:** 2026-10-05. Pinned Gleam 1.18.1, revision
`4a83802ca33a8a96227a1b332768725f232f9779`, stores fetched package versions in a
`HashMap` and serializes it with `toml::to_string` in
[`LocalPackages::write_to_disc`](https://github.com/gleam-lang/gleam/blob/4a83802ca33a8a96227a1b332768725f232f9779/compiler-cli/src/dependencies.rs).
The dependency manager writes that metadata after resolving/downloading, even
when package identities did not change. The actual
[`command_build`](https://github.com/gleam-lang/gleam/blob/4a83802ca33a8a96227a1b332768725f232f9779/compiler-cli/src/lib.rs)
invokes dependency download before compilation. Its inspected `build --help`
has no option to bypass that operation.

Five independent dependency-download processes against a disposable copy of the
actual fetched decision-kernel packages produced both valid orders for
`gleam_stdlib` 1.0.5 and `gleeunit` 1.11.0. Their raw metadata SHA-256 values were
`11c186f4a7d943364df01fad48a36b1137b4909a48c36a4e8c05abd2d1ee801b`
and `589c29e213f48d2437d713877438724defeac577ec1817f0b3101b5fff92eaa4`.
Only row order changed. This is an actual upstream serialization observation;
it explains a possible false refusal in a before/after raw-material comparison.

The selected remedy admits the supported metadata syntax, exact locked versions,
empty Git state and safe ignored namespace, then atomically prepares only this
generated metadata in ASCII name order. It preserves mode and uses private
pending/exclusive-file custody, source/byte/namespace rechecks and a no-write
canonical replay. It does not normalize source, BEAM/native output or retained
candidate/receipt bytes. New candidates require prepared metadata before capture
and repeat preparation after the build; completed producer replay never prepares.
Receipt hashes are bound to the prepared input before building and must replay
afterward. Six preparation groups and seven actual native-role producer groups
pass, including five pinned Gleam processes converging to one prepared hash and
changed-version/partial/alias/mutation refusals. The
[preparation contract](../architecture/release-manifest.md#canonical-fetched-gleam-metadata-for-candidate-builds)
defines this build prerequisite. A fresh isolated full arm64 source/build cohort
uses canonical metadata SHA-256
`11c186f4a7d943364df01fad48a36b1137b4909a48c36a4e8c05abd2d1ee801b`,
replays both actual dependency receipts after building and joins 1,457 facts with
seven generated exceptions. Its candidate record SHA-256 is
`319109ace4997cc88c805e8a7f13bd353428ee382fdd4e0fa31d1674c07ba3b4`;
its joined record SHA-256 is
`bbbfc71337f69fc89effd64ca256978f28e8cefe2567dec8e15386f99b7b2958`.
Unchanged candidate/join replay and packaged IPC/import/restart/offline maintenance
checks pass. Publication authority remains `none`; compiler-lock,
source/publisher authenticity, generated derivation, rights and release acceptance
remain separate.

### Native workflow source evidence sequence

**Observation:** 2026-10-05. The manual Mac workflow now composes the existing
source gates and receivers: exact locked fetch, explicit generated metadata
preparation, both source receipts, native build/packaged checks, receipt replay,
captured-source join, and separate app/evidence TAR verification. The evidence
receiver operates against the received app and independent candidate/core/Gleam/
joined-record digests. Token-free execution and transport steps surround separate
read-only remote/source identity checks. Both archives have their own per-attempt
artifact identities and independently retained SHA-256 values; partial retention
does not establish a complete evidence pair or release authority.

Pinned Gleam's
[`global_package_cache_package_tarball`](https://github.com/gleam-lang/gleam/blob/4a83802ca33a8a96227a1b332768725f232f9779/compiler-core/src/paths.rs)
selects `dirs_next::cache_dir()/gleam/hex/hexpm/packages`. Its locked
`dirs-next` 2.0.0
[`mac.rs`](https://github.com/xdg-rs/dirs/blob/1e1aae3136f09ae78495a806d3126a95ea0707dd/src/mac.rs)
selects the existing user's `Library/Caches` directory. The workflow uses that
inspected macOS path; a missing or differing checksum cache refuses instead of
guessing another cache or bypassing admission.

The pinned `actions/upload-artifact` v7.0.1
[`README`](https://github.com/actions/upload-artifact/blob/043fb46d1a93c77aae656e7c1c64a875d1fc6a0a/README.md)
documents single-file non-ZIP upload, immutable attempt names, artifact IDs and
permission loss for ordinary directory uploads. Each workflow artifact is one
already verified TAR with `archive: false` and `overwrite: false`; receiver modes
and bytes come from the bounded archive profile. An artifact ID identifies a
retained attempt and does not replace the independent transport digest.

Nine remote/source/workflow fixtures and policy checks pass. The local fresh
arm64 library pipeline admits a 40,908,288-byte app TAR, SHA-256
`9bb4258a4c490793c2ed3cd876ba4128b5b15e3d51a6004cbe1ab4c3c7f8bd6c`,
and a 255,488-byte evidence TAR, SHA-256
`ccc6f5e07ce9b912158a6795782096a70b4c17e7be4c0d2d37406dd7943de766`.
The received evidence replays all 1,457 source facts/seven exceptions against
the received app with unchanged handoff inode/timestamp. This exercises local
macOS 27 library boundaries, not the workflow's macOS 26 hosted profile. No
workflow was pushed or dispatched. The
[workflow contract](../host/macos.md#native-mac-candidate-workflow) retains
independent hosted/native Intel, runner/publisher/toolchain, rights, generated
derivation, installed and production distribution gates.

### Ubuntu captured-source receipt comparison

**Observation:** 2026-10-05. Repository inspection of
`release/linux/prepare-context`, `record-inputs.mjs` and `candidate.mjs` shows the
Ubuntu build copies dependency source and selected private Git state into a
captured context. The original source receipts exclude private Git state. The
retained full arm64/amd64 contexts each contain 1,864 file facts, including 1,509
dependency-path facts: 1,464 ordinary inputs and 45 Git metadata files totalling
36,374,448 bytes. Supplier `priv` and Erlang files are source where the archive
proof identifies them; a blanket generated-file exclusion would discard evidence.

Pinned Elixir 1.20.4
[`Mix.SCM.Git.checkout/1` and its private checkout](https://github.com/elixir-lang/elixir/blob/v1.20.4/lib/mix/lib/mix/scm/git.ex)
initialize Git with hooks disabled, fetch the locked revision, configure sparse
selection and check it out. This explains why Git metadata can appear in captured
preparation, but does not authenticate a retained config or execution, or imply
those bytes belong in a customer archive. The selected comparison reuses existing
source admission, bounds a known Git metadata path profile only for Git-locked
core dependencies, and records its raw facts separately. Unknown metadata and
metadata presented as Git source proof refuse. No complete captured context is
retained here, so these assertions do not replay the compilation or prove that
every captured input was consumed.

Actual source gates admit 42 core packages and two Gleam packages, with source
receipt SHA-256 values
`76b9316033d78c06ea08e06258d80d07bd0c2dc13fbc70e2050b9dd6a9d6d7a7` and
`40277a06e012d6e84030e3221a708c6e072d66b0277d0d410e8ad9d874fe3154`.
Both joins compare 1,457 source/metadata facts and record seven generated inputs
plus 45 Git facts. Arm64 joined-record SHA-256 is
`c672e663892901732b9bdaead0b03dd78c3aa6ab932032e8c075f663688e795c`;
amd64 is `62048c923da13d4c55e3cce1414d2ceae9244cd76e3ca4dc030961a8c2d76c40`.
Both repeat without receipt inode/time changes. These are existing native-arm64
and emulated-amd64 Ubuntu container candidates. Receipt/refusal fixtures and the
[owning join contract](../architecture/release-manifest.md#ubuntu-captured-dependency-source-join)
retain separate compiler/generated derivation, independent publisher/rights,
hosted/systemd/native installed and release gates; publication authority is none.

### Ubuntu source-evidence transport

**Observation:** 2026-10-05. The fixed Mac source-evidence transport now also
serves Ubuntu through an explicit `ubuntu-material` profile. It transports only
the core/Gleam source receipts and exact joined record, beside a separately
received candidate. Independent digest, canonical semantic join and final static
full-candidate custody checks are separate assertions. The handler shares the
bounded descriptor USTAR reader and preserves the established Mac record schema;
platform adapters select the existing source-join and final byte consumer.

The pinned Ubuntu build image's GNU TAR emits 266,240-byte archives for both
retained full container candidates. Arm64 transport SHA-256 is
`a2561abce6e2053b8f2d7263a06664df517adb3722ab7b856232610030e4f074`;
amd64 is `e173b8274afa11c422790ad5d4c243b37559b6bd8641e551d1c226c8ff189abf`.
The corresponding handoff records are
`98e543a5ceb5c6b346facc485d7e1bdc357e7cff6ceed8cff322b20269b9044e` and
`25d978d999054ea010c70be9901b079a0a37d641c17f8f6718c4ef71878f5ebf`.
Each received candidate rejoins 1,457 proved source/metadata facts, seven generated
inputs and 45 separately retained Git metadata facts. Completed replay preserves
handoff and extracted source-receipt inode/time. BSD USTAR retained-assertion,
wrong/semantically conflicting identity, mode/member/resource, partial/changed
custody and child-time mutation fixtures complement the full GNU transport.
This does not authenticate a hosted workflow or compiler execution; the
[handoff contract](../host/linux.md#dependency-source-receipt-archive-handoff)
keeps rights/publisher, generated/toolchain, installed/systemd and production
release acceptance separate, with publication authority none.

### Ubuntu workflow source evidence sequence

**Observation:** 2026-10-05. The manual Ubuntu workflow now composes source
receipt admission, prepared fetched metadata, target/container acceptance,
receipt replay and captured-source joining before separate candidate/evidence
USTAR receivers. Independently retained hashes bind the received source evidence
to the received candidate. Separate remote checks surround token-free transport;
source gates and candidate acceptance receive no job token. The existing Ubuntu
build/preparation step still uses a read-only token for its public pinned Gleam
`gh release download`, so the build is not described as credential-free.

Pinned Gleam's inspected checksum-cache function uses `dirs_next::cache_dir()`.
Locked `dirs-next` 2.0.0
[`lin.rs`](https://github.com/xdg-rs/dirs/blob/1e1aae3136f09ae78495a806d3126a95ea0707dd/src/lin.rs)
uses an absolute `XDG_CACHE_HOME` or the user's `.cache` fallback. The workflow
selects a private absolute runner-temporary XDG root before fetching and admits
archives at `gleam/hex/hexpm/packages` below it; private Hex inputs have their own
runner-temporary root. Missing/differing fetched archives refuse. Both final
archives have separate unchanged-digest checks and single-file non-ZIP uploads,
with distinct run/attempt identities, `overwrite: false` and both IDs/hashes in
the summary, under the previously inspected pinned upload-artifact contract.

Nine remote/source/workflow fixtures and policy checks pass. Actual full GNU TAR
source-evidence joins/replays for both received target candidates are recorded
above; they exercise library/container boundaries, not an executed hosted matrix.
No workflow was pushed or dispatched. The
[workflow contract](../architecture/install-and-guide.md#ubuntu-candidate-workflow)
keeps hosted/native CPU/systemd/installed, publisher/rights, generated/compiler and
production release evidence independent, with publication authority none.

### Captured core lexer/parser derivation

**Observation:** 2026-10-05. Five generated Erlang files in the retained Mac and
Ubuntu input assertions have corresponding archive-admitted grammars: three
EarmarkParser 1.4.46 inputs and two Erlex 0.2.9 inputs. Pinned OTP 29.1
[`leex.file/2`](https://github.com/erlang/otp/blob/OTP-29.1/lib/parsetools/src/leex.erl)
and
[`yecc.file/2`](https://github.com/erlang/otp/blob/OTP-29.1/lib/parsetools/src/yecc.erl)
provide the actual source-generation boundary. Both read inherited
`ERL_COMPILER_OPTIONS`; default `leexinc.hrl`/`yeccpre.hrl` paths contribute to
raw `-file` attributes. Explicit reporting/return options leave this cohort's
output bytes unchanged. The helper clears inherited options and records four
generator modules and both templates, retaining paths only in private child
observations for static byte rechecks. It does not compile generated actions.

Reproduction uses private `package/src` copies, relative source names and
OTP 29.1/ERTS 17.1/parsetools 2.8. Exact captured SHA-256 values are:

| Captured output | Bytes | SHA-256 |
| --- | --- | --- |
| `earmark_parser_link_text_lexer.erl` | 26,960 | `b1ba2c6cbdafaf91220c4fb0ff12da97e46961da8e5fc862bfca45e57f0f1640` |
| `earmark_parser_link_text_parser.erl` | 37,780 | `061fa5dd201da6d6631f10a0d35d8917b64d36edc4dc3cd396bcabce306a224f` |
| `earmark_parser_string_lexer.erl` | 21,521 | `f6f3927ae0e0dd627154c50454f8b90840fbcfd60813d59555bc2328efac2fd4` |
| `erlex_lexer.erl` | 37,511 | `7985a9d71d689544cdca996344dd2305a389c330df8645a4aaf924804958da70` |
| `erlex_parser.erl` | 130,528 | `76bb7af3f0eb42d689f366863001c94fc6704a6c7fd3caa861b009ef97793724` |

The bounded verifier first replays the complete original core source receipt,
then compares actual regenerated bytes with the independently pinned dependency
join. It retains exact private proof files and finishes with source/tool/proof
byte and namespace checks after children. Seven archive/generator/refusal groups
pass, including inherited-option isolation and unchanged CLI replay that invokes
only observation operations. A local shell file-limit experiment stops a
5 MiB write at 4 MiB with a failing child status on this macOS shell; the separate
generated-file admission ceiling remains 2 MiB. Neither measurement establishes
compiler peak-memory limits or another shell's block size.

The [derivation contract](../architecture/release-manifest.md#captured-core-lexerparser-derivation)
qualifies only selected captured source inputs. Different installation-path/tool
cohorts must reproduce the same raw bytes or refuse; normalization is disallowed.
Native helper, empty compiler lock, retained Git metadata, target compilation,
independent tool/publisher authenticity, rights and installed/production release
acceptance remain separate. An empty selected subset proves no target-generation
claim. Publication authority remains none.

All three retained full captured cohorts derive the same five raw output hashes
and preserve record inode/time on no-generation replay. The Mac arm64 derivation
record SHA-256 is
`cccee4b9b40f0d2fea59ba5ee8402ae1edff1c42f127012ee42e1304788d0334`;
Ubuntu arm64 is
`6e4da354982d494034cd7ee3c436d6be4dae43644876b1ec7985b02ddad0e96a`;
Ubuntu amd64 is
`eb7e6797318fb349dc87ee53be288ee09e2b79048c762167d56d32a48c53cf93`.
The Ubuntu inputs are assertions captured for native-arm64 and emulated-amd64
container candidates; derivation runs on the observed local Mac generator cohort
and establishes source-input identity, not target generator/BEAM execution.
Each still records two unqualified generated inputs. The seven fixture groups,
formatter, Node syntax, policy and rendered Chrome documentation checks pass.

### Locked dependency notice-file collection

**Observation:** 2026-10-05. The source-admitted 42 core dependencies and two
Gleam dependencies provide a bounded technical starting point for notice
collection. Selection uses the
[owning filename profile](../architecture/release-manifest.md#locked-dependency-notice-file-collection),
not content interpretation. Nested sparse Git notices and `LICENSES`/`LICENCES`
members retain their original paths; each core Hex package's admitted raw
metadata has a separate role. Arbitrary suffixes can identify candidates that
are not license texts, so filename matching alone establishes no rights or
notice completeness. Raw contents are copied without decoding or execution.

The full cohort produces 83 files and 283,159 raw bytes: 44 conventional filename
candidates plus 39 package metadata files. Inventory SHA-256 is
`c10d3584c2bb0259e7826d923f422137419a942092e0ab17da89b89de783d52e`.
Completed source-gate/inventory replay preserves its inode and timestamp. Seven
core packages have no matching notice name in the admitted source scope:
benchee_markdown 0.3.4, db_connection 2.10.2, elixir_make 0.10.0,
file_system 1.1.1, nimble_parsec 1.4.2, stream_data 1.4.0 and yaml_elixir 2.12.2.
Their inventories explicitly retain an empty notice list and separate Hex
metadata; this absence is not a determination about their licensing.

Actual archive/Git/Gleam fixtures exercise non-UTF-8/NUL raw copies and correct
metadata roles, missing names and successful unchanged CLI replay. Source-admitted
inputs exceeding 1 MiB per file, 16 MiB aggregate and 512 selected files refuse
before collection. Independently wrong/forged/changed evidence, incomplete or
aliased/unsafe/changed/extra copies, and changes during the final source parsers
refuse while preserving prior/partial custody. Five refusal/resource groups and
two positive/filename groups pass in targeted runs. Current source identities and copied byte/namespace checks follow all
parser/version children.

This collection includes development/build dependencies and does not determine
which packages ship. It does not cover all inline/transitive notices or the
project, OTP/Elixir, Swift/toolchain, Rust/native, SDK/model and OS distribution
materials. It changes no retained app/DEB/candidate and is not an installed notice
bundle. Full closure and rights review remain required; publication authority is
none. Continue the separate input-source gates before attaching broader release
claims to notice inventories.

### Locked codec Cargo registry source bytes

**Observation:** 2026-10-05. Rust 1.97.1 pins Cargo source revision
`c980f4866141969fab6254a680546a277789d6f0`, matching the installed Cargo identity.
The [registry unpack implementation](https://github.com/rust-lang/cargo/blob/c980f4866141969fab6254a680546a277789d6f0/src/cargo/sources/registry/mod.rs#L623-L682)
reuses an unpacked directory when its `.cargo-ok` JSON marker has version one.
That branch does not recompare every source file with the locked archive. The
marker is therefore a generated cache observation, not independent source proof.
The [package producer](https://github.com/rust-lang/cargo/blob/c980f4866141969fab6254a680546a277789d6f0/src/cargo/ops/cargo_package/mod.rs#L895)
uses GNU TAR headers. The admitted profile must cover that actual layout;
accepting only USTAR would exclude the current producer's archives.

The 27 current locked crates contain 1,499 regular GNU members, totaling
3,148,593 compressed bytes, 17,129,472 expanded TAR bytes and 15,924,462 source
bytes. No extended or directory headers occur in this cohort; 1,498 files have
mode 0644 and one has mode 0755. Ordinary GNU extension fields are zero; ignored
UID/GID fields can be all NUL. Each existing source tree has the exact seven-byte
`{"v":1}` root marker and no `.cargo-checksum.json`. These are dated cache
observations, not a general promise about future Cargo layouts.

The [bounded source gate](../architecture/release-manifest.md#locked-codec-cargo-registry-source-bytes)
checks locked archive SHA-256 before parsing, uses a fixed private Node child,
and compares every delivered byte/mode without extracting or executing source.
The normalized manifest preamble identifies the locked name/version; it is not
a general TOML parser. The two local packages retain frozen project manifest
references rather than being represented as registry archives. Source and
marker custody, frozen Git/Mix identity and namespaces reverify after children.
Partial outputs remain retained; successful replay invokes no Cargo and leaves
the completed record inode/time unchanged.

The full cohort receipt SHA-256 is
`5e429ac652d760c089fba62bc3f2b04ffc462d0544160973457200fa14cea4bc`.
Seven fixture groups pass across targeted runs: actual Cargo-produced archives,
GNU/USTAR profile handling and inherited Node-option clearing, literal lock
refusal, checksum-before-parser, malformed headers/path/type/padding/identity,
bounded 128 MiB inflation, missing/extra/aliased/unsafe sources and markers,
partial or changed/aliased/unsafe completed custody and source/cache/frozen-lock/output mutation during parsing.
The complete cohort and unchanged replay pass separately from those fixtures.

This qualifies existing cache bytes against the approved lock. It does not prove
publisher/registry trust, target compilation consumption, native output identity,
compiler authenticity, notices, rights or installed-release acceptance. Continue
Rust/native notice collection and those independent build/evidence gates;
publication authority remains none.

### Locked codec notice-file collection

**Observation:** 2026-10-05. The admitted 27 Cargo registry packages and two
frozen local package scopes now have a separate private notice collector. It
replays the original Cargo source receipt before selection and after copying.
Selection uses the existing conventional filename profile and retains raw
normalized/original Cargo manifests as separate metadata. Local codec and vendor
sources retain their original tracked paths and Git modes; filename matching
does not infer license terms or patch derivation.

The full 29-package inventory contains 115 files and 402,640 raw bytes:
59 conventional notice candidates and 56 manifest metadata files. Its SHA-256 is
`c5efc0b8ef7d9d781622991568b8e0059e8425ec0d037ce498636f256ed43d2d`.
The local frameshift-codec 0.1.0 scope has no matching notice name; its empty
notice list is distinct from the retained manifest. This is not a licensing
determination or a project license selection. Successful full replay preserves
the record inode/time, invokes no Cargo and changes no original receipt/source.

Seven fixture groups pass using actual Cargo/Git/Mix and frozen local inputs.
They cover raw binary copies, metadata roles, explicit unmatched names, private
unchanged CLI replay, independently wrong/forged/missing source receipts,
source-admitted 1 MiB/16 MiB/512-entry excess, changed/aliased/unsafe/extra/partial
copy and inventory custody, and source/copy/receipt/frozen-source/output mutation
during the final archive parsers. The full cohort and replay pass separately.

The [collection contract](../architecture/release-manifest.md#locked-codec-notice-file-collection)
keeps raw binary copies, independent source-receipt identity, fixed local scope,
metadata roles and unmatched names explicit. Its limits and private custody do
not establish target build consumption, publisher rights, vendor archive/patch
qualification, complete inline/transitive/distributed closure or installed
release notices. Toolchain, SDK/model and OS materials remain independent gates.
Publication authority is none; rights review remains required.

### Booted Ubuntu manager, launcher and kernel admission

**Observation:** 2026-10-05. An isolated OrbStack 2.2.3 arm64 machine uses Ubuntu
24.04.5 userspace, systemd 255.4-1ubuntu8.17 and cgroup v2 on
`7.0.14-orbstack-00380-ga7e0a2dc9535`. Machine settings request 2 GiB RAM, two CPU
cores and a 4 GiB disk-usage limit; these settings are not measured whole-machine
resource enforcement. Host files and SSH-agent integration are disabled.
OrbStack's [isolation contract](https://docs.orbstack.dev/machines/isolated)
describes a shared Linux VM/kernel, so this is not an independent stock Ubuntu
kernel. The initial userspace has an unrelated failed kernel-debug mount.

The fresh private `v0.1.0` source is
`14a64975e39fb9f1adb20febf2d1623609c728b4`, based on committed main with only the
fixture's stable application version selected. The candidate record SHA-256 is
`5a732eba397cd6865d3c341dfe11993ac2b02b44560b4f0cdbd2dfe936cd686a`;
the DEB is `5f689c269bab94497ab8cbb6bd3421b81afe116414a83599b256dc7aa837d656`.
Pinned target tools build its OTP, SQLite/Exile NIF/helper, Rust codec and Zig
closure. Source/package/tag versions agree. After exact transfer readback, actual
APT/dpkg replacement installs that archive and its wrappers match the frozen
source byte-for-byte. No accepted source cohort or archive is rewritten.

The machine injects `/run/systemd/system/service.d/zzz-lxc-service.conf`, which
disables filesystem/home/private-tmp/device/kernel/control-group protection and
NoNewPrivileges. Those defaults cannot qualify the required service policy.
A fixture-only per-unit override restores the declared values; the actual host
starts with default JIT, nonzero matching UID fields, NoNewPrivs=1, zero effective
capabilities and active seccomp. Actual different-UID control/observer commands,
identity version, absolute PNG import from an unavailable caller directory,
literal relative PNG import from its usable private directory and observer/
outsider refusal pass. Both new imports resolve to the same item. Three POSIX
launcher groups also exercise readable, unreadable and unlinked directories.

The revised mixed-stop probes below use the explicit launcher/unit overlay
described under [managed VM shutdown](#managed-vm-shutdown-and-private-custody),
not the unchanged archive identified above.
`release/linux/check-systemd` compiles `systemd-canary.c` with Ubuntu's native C
compiler, outside shipped runtime material, and copies the independently pinned
installed service into four temporary fixture units. It checks their resolved
identity/confinement/limits against the host, restores only the provider-weakened
restrictions for those units, and leaves the host unit intact. Actual probes pass
managed-root writes, read-only system/kernel/cgroup views, home denial, isolated
temporary/device views, `/dev/null`, NoNewPrivileges, 4096 descriptor limits and
privilege/realtime/personality/address-family refusal. Kernel pseudo-file denial
is joined to read-only mount flags; EACCES alone is not read-only mount evidence.
A native fork probe admits 511 children plus its parent and refuses another with
EAGAIN, then reaps every child: the actual unit limit is 512 tasks.

The memory probe first observes positive `memory.events high` under the actual
805306368-byte high watermark. Only that disposable canary unit then relaxes its
high watermark to exercise the unchanged 1073741824-byte `MemoryMax`; the manager
reports `Result=oom-kill` and explicit `OOMPolicy=stop` terminates the unit.
Swap remains unlimited in the tested unit, so no total allocation or swap ceiling
is claimed. A separate native child ignores TERM; `KillMode=mixed` removes its
process identity and empties/removes its cgroup after main-process exit, within
the declared 40-second deadline. Current-invocation journal selection excludes
prior fixture messages.
The harness removes its reserved canary files/units and the host remains active.

The upstream v255 contracts support the distinction between declared settings and
execution: [memory/task control](https://github.com/systemd/systemd/blob/v255/man/systemd.resource-control.xml),
[execution confinement](https://github.com/systemd/systemd/blob/v255/man/systemd.exec.xml)
and [whole-group termination](https://github.com/systemd/systemd/blob/v255/man/systemd.kill.xml).
These sources were read with gh on 2026-10-05. The successful fixtures qualify the
specified manager/shared kernel and canary configuration; their high-watermark
relaxation is not operation with all host limits. Real codec-child stop, booted
numeric-version update/removal and administrative backup/restore remain separate
checks. Stock Ubuntu/native amd64, physical storage/power, rights/signing and
production release acceptance remain independent gates. Publication authority is
none; no model or physical frame is involved.

### Managed VM shutdown and private custody

**Observation:** 2026-10-05. A second isolated Ubuntu 24.04.5/systemd 255.4 arm64
machine exposes a real routine-restart defect: simultaneous control-group TERM
reaches the supervising flock process, OTP VM and native helper handshakes. The
manager times out and kills the remaining VM/helpers; import and codec fences
remain, correctly making new imports unavailable. Those uncertain bytes are
retained for explicit stopped-service inspection, never erased by startup.

The [util-linux 2.39.3 implementation](https://github.com/util-linux/util-linux/blob/v2.39.3/sys-utils/flock.c#L348-L381)
execs the requested command without a supervising fork when `--no-fork` is set;
its lock descriptor remains open across exec. The
[systemd v255 kill contract](https://github.com/systemd/systemd/blob/v255/man/systemd.kill.xml#L64-L103)
defines mixed termination: initial TERM reaches only the main process, then
remaining group members receive final termination after main exit or the stop
deadline. Both exact sources were read with gh on the observation date.

The managed launcher uses that exec path and the unit declares `KillMode=mixed`
and `OOMPolicy=stop`. In an explicit overlay fixture, systemd's main process is
`beam.smp` and a competing directory lease exits 69. Two actual managed stops
report success, release confirmed import/codec custody and the directory lock,
and permit new imports across restarts. The revised four kernel canaries also
pass with those exact unit properties, including the TERM-ignoring child and
hard-ceiling OOM stop. This is the same shared OrbStack kernel, with declared
hardening restored only for the fixture units. It is not unchanged-package,
stock-kernel, native-amd64, physical-power or production acceptance. A fresh
source-bound DEB and real codec-child/package lifecycle join remain required.

### Managed command readiness

**Observation:** 2026-10-05. A fresh installed arm64 package's exec-style start
returns while its initial native setup is still running. An immediate fixture
restart reaches the stop deadline, kills remaining processes and retains unknown
import/codec custody. Once the command boundary is ready, managed stop succeeds.
The retained bytes remain available for stopped-service inspection; this fixture
does not qualify clean install by clearing them.

The [systemd v255 service contract](https://github.com/systemd/systemd/blob/v255/man/systemd.service.xml#L182-L191)
considers an exec-style service started after executing its binary, independently
of application readiness. Its
[post-start contract](https://github.com/systemd/systemd/blob/v255/man/systemd.service.xml#L413-L450)
includes a failing post-start command in activation failure and ordering.
These exact sources were read with gh on the observation date.

The unit now runs the installed `check-ready` helper as its service UID before
completing start. It admits the existing public numeric policy, clears the child
environment and polls only `frameshiftctl state`, discarding response bytes.
The interval is 250 ms; a 35-second TERM deadline and one-second final-kill bound
fit inside the manager's 60-second deadline. Wrong identity refuses before
polling; absent command availability returns a finite readiness error. No private
identity, model, frame, import, fence deletion or replacement is authorized by
this read. Command availability can coexist with a fenced intake owner.

An explicit unit/helper overlay passes immediate ready restart and successful
managed stop. The wrong-role helper exits 69 before polling; with the real host
stopped, its missing-boundary check exits 69 after 35,038 ms with fixed error text.
The existing three-start/120-second budget also refuses excess rapid fixture
starts; resetting that budget is an explicit fixture operation, not a product
change. Previously unknown custody stays retained. This is actual installed
runtime/manager evidence on the observed shared arm64 kernel, with an overlay;
it does not qualify an unchanged archive, stock kernel or native amd64.

The native canary replaces the host executable and omits only this host-IPC
post-start command; otherwise its confinement, identity and resource fields
remain joined to the installed host. Startup readiness and application lifecycle
require their separate actual host fixture. Fresh source-bound packages must
qualify first install, immediate restart and the complete retained-data lifecycle.

### Linux final artifact export cache boundary

**Observation:** 2026-10-05. Docker 29.4.0 with the overlayfs store and Buildx
0.33.0 (`f7897eba028583e0071642db3c011e860444f8cf`) repeatedly exports an incomplete
runtime from the same frozen private arm64 source cohort. Later cached local
exports contain 1,070 files and omit the installed unit and build-input record;
three consecutive bounded inventories remain unchanged. A diagnostic TAR export
also omits those required files. These outputs refuse and remain retained without
a final candidate record. This does not establish delayed copying or a local-only
export fault.

Independent Node 26.9 runtime copies preserve the admitted file inventory and
bytes. Repeating both runtime and DEB builds with cache reuse disabled only for
the final `artifact` stage produces a complete candidate and passes the existing
source, runtime-copy, packaging, release-version and final-record checks. The
experiment changes only the Docker arguments; it does not substitute a prior
runtime, repair missing files, weaken admission or prune shared caches. This
implicates the cache/export boundary, but the precise upstream failure mechanism
remains unproven.

The exact [Buildx 0.33.0 build reference](https://github.com/docker/buildx/blob/v0.33.0/docs/reference/buildx_build.md#no-cache-filter),
read with gh on the observation date, defines `--no-cache-filter` for named
stages. All Linux builders now use `--no-cache-filter artifact` for runtime and
package exports, retaining the existing compilation/dependency cache policy.
Source/namespace/byte verification stays authoritative. The completed experiment
has publication authority `none`; fresh standard-command builds and installed
lifecycle qualification remain separate. If those exports remain incomplete,
retain the failure and investigate rather than accepting or patching its bytes.

### Source-bound booted lifecycle and actual codec stop

**Observation:** 2026-10-05. Fresh standard-command candidates rooted at the
artifact/readiness/mixed-stop implementation join these private source identities:

| Fixture version | Frozen source commit | Source-input SHA-256 | Candidate record SHA-256 | DEB SHA-256 |
| --- | --- | --- | --- | --- |
| 0.1.0 | `15eb563ee74a98735f8839aac33d73f5c46d046f` | `b82d85cb5a11dc1fa64f3488a93b925b49a645e60ab1ff9c6af2e1376cd0ca58` | `23b308b50f1e71776a5719e803af5dd5f7245528f6fb0a7098c0adc0458dc0c3` | `83f16c67ef13f304681a9e53ee48843ca6397f729cf1d56fce2f141f1dfd1d70` |
| 0.1.1 | `99f4f493444a79db176d0966bd214497f42257c7` | `1d5685278d61bb04dfea246f5562f7e72513789b812e2877dd9ed2e49f6ff5cb` | `391646cde91296a6e11bd10ae4c4ad87269d883b471cf0a5e605ac892f25791e` | `cd7da0eb63bdfb340e95575ed886f56c0df6464997ed4cd9791861e947ea0cab` |

The copied archives verify independently. Installed unit, `check-ready`,
`launch-service`, `frameshiftctl` and `policy.sh` match frozen source. Unit SHA-256
is `dc6290adb88bb9e0930f98c7393d60c9c7f6be1eba5bbcf3e491ec95c1b8591f`.
Actual APT install and immediate managed restart pass with default JIT on a fresh
Ubuntu 24.04.5 arm64/systemd 255.4 machine using the shared OrbStack kernel.
Provider-disabled hardening is restored before installation, only for the tested
unit, through a persistent `/etc/systemd/system/frameshift.service.d/` override.
Pre- and post-fixture readback confirms strict system protection, home denial,
private temporary/device views, NoNewPrivileges, mixed stop, OOM stop, a 1 GiB
memory ceiling and 512 tasks. This is an exact software configuration, not a
stock-kernel or physical-hardware qualification.

The complete corrected repository fixture passes uninterrupted from that fresh
installation. It joins exact original PNG/JPEG/group admission, created 0400
identity and service-UID resolution, offline backup/verify/restore, live
maintenance refusal, active-but-disabled 0.1.0-to-0.1.1 upgrade, downgrade before
unpack/error-unwind and retained comparison. Actual remove, purge, lower-version
reinstall refusal and higher-version reinstall preserve immutable bytes, owners,
modes, authoritative tables, retained audits, key, UID, backups and unknown
sentinel. A new original import succeeds. The validator runs from its separately
extracted protected runtime, independent of removed product files.

An exact C-locale `reset-failed` response for an unloaded unit permits normal
start; every other reset error refuses. The [systemd v255 reset source](https://github.com/systemd/systemd/blob/v255/src/core/dbus-manager.c#L870-L874),
read with gh, explains why resetting does not load an absent unit that cannot
retain failed state. The real three-start/120-second budget remains unchanged.
The complete run does not resume a partial fixture or reset its installed
custody, watermark or fences.

The final phase SIGSTOPs the actual codec worker after executable/cgroup/PID-start
matching. Managed stop succeeds within the declared deadline, that identity
disappears, the group empties and the interrupted CLI exits 75. Authoritative
tables remain unchanged: decoding had not reached Library receipt admission.
Restart keeps prior completed receipts readable; interrupted status and new
import refuse with 69 while uncertain intake custody stays retained. The final
fenced installation and fixture outputs remain available for inspection. This
qualifies actual worker ownership/refusal, not pre-decode durable claims or
automatic recovery.

Stock Ubuntu/native amd64, actual host OOM recovery, physical storage/power and
production acceptance remain open. These private candidates grant no release
authority.

### Timezone-independent protected identity custody

**Observation:** 2026-10-05. The booted arm64 identity command validates its PEM,
publishes the certificate-bound 0400 file and successfully synchronizes the
credential directory, but returns uncertain status because final resolution
compares unequal calendar timestamps. On this configuration, pathname mtime/ctime
are `2026-10-05 16:29:13`, while the opened raw descriptor reports `18:29:13`;
all other compared fields match and independent PEM proof succeeds. These are two
representations of the same unchanged inode, not observed byte mutation.

The resolver now requests `time: :posix` for both pathname reads and both opened
file-information reads. It retains all existing owner, mode, inode, size, mtime,
ctime, bounded-byte and final-name checks; atime remains excluded because reading
may change it. The exact [OTP 29.1 file contract](https://github.com/erlang/otp/blob/OTP-29.1/lib/kernel/src/file.erl#L679-L689)
defines explicit POSIX seconds independently of default local calendar conversion;
that source was read with gh on the observation date.

The existing Linux nonroot credential/TLS/installation fixture now runs in fresh
processes with `TZ=UTC0` and `TZ=Etc/GMT-2`. Before correction, the complete lane
reports 14/15 passing with actual uncertain publication in the credential group.
After correction, all 15 groups pass, including both timezone variants, actual
IPv4/IPv6 pinned TLS, no-replacement/changed/unsafe custody, concurrent identity
installation, stdin CLI, publication uncertainty, real full-disk refusal and the
other peer/actor contracts. This is source/runtime fixture evidence. Fresh fixed
DEB installed identity, booted backup/restore and numeric update/removal remain
required; no physical durability, encrypted-key recovery or production claim
follows. Previously uncertain identity bytes remain preserved for inspection.
