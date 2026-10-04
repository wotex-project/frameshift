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

## Zig boundary

The existing project-owned host raster executable is Zig. It accepts a
length-framed binary protocol on stdin/stdout and never receives credentials.
MCU firmware uses the exact controller's qualified SDK/language after a
reproducible build, signed update, TLS, and power/refresh spike. Keeping Zig
there is allowed only if it passes those gates.

The raster protocol carries a versioned job header plus paths or file
descriptors to canonical decoded buffers. It emits progress and one terminal
result. The Elixir owner enforces maximum dimensions, output size, wall-clock
deadline, and process memory limits where the OS permits. A crash fails one job
and restarts the port.

Zig is not a reason to rewrite high-quality system facilities. SQLite, image
codecs supplied by Apple, and vendor kernel drivers can remain upstream native
dependencies when their license and attack surface are reviewed. Keep the
existing Zig renderer while it passes its isolated-worker gates.

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
