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
