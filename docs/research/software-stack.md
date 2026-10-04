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

The accepted first profile is static PNG. Complete JPEG admission remains
independent work: exact end-of-image/multiple-image handling, Exif, ICC and
CMYK/YCCK interpretation must be qualified before enabling it. The direct PNG
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
