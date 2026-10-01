# Final-Product Completion Plan

**Status:** required product work, ordered by dependency and evidence

This plan decomposes the complete product definition. Builders can start with
Paper, Photo, Pixel, the Mac app or a protocol implementation. The seams below
keep those choices interoperable. Track code/tests separately from external
permissions, signing and physical measurements. Those gates constrain relevant
activation and claims; they do not excuse unfinished implementable software.

## Composition and product dependency gates

Frameshift is a modular reference product and integration proof of concept for
Conjunct. The [platform contract](build-platform.md) defines BP-01–BP-11;
[CI-01–CI-08](conjunct-integration.md) defines the ownership, migration and
consumer evidence. A printable parts/shopping list is an output of a physical
composition. Transactional shop
work is on hold; no implementation resumes merely because its contract remains.

[PC-01–PC-09](producer-contracts.md) is the library-delivery contract. It names
what Conjunct and each other producer must supply, what Frameshift provides and
the joined refusal/recovery evidence. Specified but unfinished producer work
may proceed alongside its consumer; it is distinct from undecided requirements.

| Gate | Required outcome | Dependency/evidence |
| --- | --- | --- |
| A — Contract foundation | Product/producer ownership and current implementation boundaries | Exact source/API map, preserved v1 identity and evidence ledger |
| B — Host boundaries | Existing Phoenix/Ash/phoenix-assets/Svelte foundation, authorized commands and bounded diagnostics | Existing app moves retained; complete missing auth, logs/traces and qualified producer interfaces |
| C — Physical profile and extraction | Frameshift profile and complete Conjunct compiler/report with independent checks | Producer schemas/exports, old-byte replay, explicit successor migration, cross-runtime parity and formal outcome/replay gates |
| D — Composition and visual procedures | Source-bound geometry, steps, local save/export/print and list for each claimed frame profile; one exact fixture is the first slice | Corresponding C profile and required B surface; valid/invalid/unknown cases, accessible offline/low-graphics output, no account or payment dependency |
| E — Generality and adaptation | Upstream passive/sensor consumers, two operator profiles and bounded autonomous research | Actual producer conformance, no frame imports in generic core, source/rights admission, revocation/restart/budget tests |
| F — Optional external services, on hold | Later admitted supplier/service and Rivure financial integration plus complete care | Separate resumption; D/E complete and all applicable BC-01–BC-10 evidence |

Conjunct core owns generic validation, normalization, composition, comparison,
catalog/parts projection, predicates and CheckReport aggregation. Its
instruction profiles own procedure planning and portable presentation semantics.
Frameshift C supplies frame profiles, mandatory rules, exact fixtures, v1 replay
and a qualified consumer adapter; D supplies the product interface, content and
authorized local/server I/O. The retained BuildSpec planning preview is a
non-admitting migration aid, not a way to implement D ahead of Conjunct by
duplicating those producer roles. Refpath P1 is required for E's operator
generation, not for independent composition and instructions.

These are dependency and acceptance gates without time estimates. A missing
generic producer capability has an upstream owner and reproducing consumer test;
it cannot be filled by a second Frameshift runtime. Narrow deterministic paths
remain usable while broader profiles are unavailable.

Conjunct core/instructions work, Refpath P1 durable-generation work and ExMaude
P2 search-evidence work can progress together. Only the dependent operator or
formal claim waits for the real producer join. A per-profile C-to-D slice does
not wait for the remaining frame classes or optional CAD/service/device profile;
complete claimed Paper/Photo/Pixel coverage remains the overall C/D gate.

Host, protocol, receiver and simulator work below remains a separate product
lane. Conjunct proof-of-concept completion does not claim these installed-product
requirements have passed. The native product stays independent of the platform
and optional transactions. Update the [verification ledger](verification.md)
with evidence for each actual implementation slice.

## Shared contracts

These artifacts reduce rework across every track:

1. canonical master, recipe, artifact, frame-state, and playlist data models;
2. Frame Protocol v0.1 schemas and conformance fixtures;
3. a simulated frame with selectable capabilities and injected failures;
4. a versioned Frame Thing Model, Host Outbox Thing Model, namespaced
   vocabulary, binding profiles, and conformance claims;
5. golden source/preview/artifact fixtures for each display profile;
6. repository-wide build, format, test, and license checks; no project-owned
   Python code, with pinned upstream build tools isolated and recorded;
7. decision/evidence records for every dependency and exact hardware revision;
8. explicit product-bundle, physical-composition, application-generation and
   external-commitment identities with migration and consumer-conformance tests.

The simulator can be an Elixir application on macOS and need not imply Nerves
or Linux hardware inside a frame. No global diagonal limit follows from the
particular reference candidates selected for a test.

## Host track

### H1 — Library core

- OTP application and supervision tree;
- portable domain boundaries and platform adapter contracts from
  [Portable Host Core](host-core.md);
- content-addressed store and direct Exqlite/SQLite metadata migrations under
  D-010, with consistent backup, object manifest, restore checks, and FTS5
  search as specified in the [persistence review](../research/embedded-persistence.md);
- import, pin, recoverable remove, labels, and search;
- immutable recipe/variant relationships;
- single-writer transactions, replay receipts, atomic audit writes, and
  read-only paginated diagnostics through authenticated local IPC;
- named telemetry events, bounded persistent metric rollups, native macOS
  unified logging and Linux logging adapters, and a diagnostic CLI;
- test-only CLI or local harness.

**Exit:** crash and restart preserve committed masters; identical recipes reuse
cache; removal cannot collect referenced/pinned content; Mac and Linux/Pi host
contract tests preserve the same domain and protocol behavior. A failed update
is reconstructable from command through display confirmation or pending state
without opening the UI or exposing secrets. Metric and log storage bounds are
measured on both host platforms. Backup/restore reproduces protected references
and rejects corrupt or missing objects before activation.

### H1a — Shared decision kernel and guide

- extract only pure capability admission, profile selection, state labels,
  and simulation transitions into Gleam;
- compile the same source to Erlang for the host and JavaScript for the public
  guide on the pinned OTP 29/Elixir 1.20.4/Gleam 1.18.1 toolchain, with cross-target
  fixtures, integer bounds, and generated cases;
- turn the desktop HTML draft into the static interactive installation guide
  at `frameshift.wotex.io`; present simulated profiles and failures honestly;
- hand non-secret setup choices to the native app after installation, with
  pairing and delivery still performed by the installed host.

**Exit:** BEAM/JavaScript decisions agree for valid and adversarial inputs;
the guide works without an account or hosted code execution; no browser
simulation is described as physical display evidence. See
[installation and guide](install-and-guide.md). Generic physical extraction
must preserve this parity and retain product-owned decisions where appropriate.

### H2 — Deterministic renderer

- supervised Zig executable and framed protocol;
- crop/scale/color foundation;
- Paper palette/dither, Photo raster, and Pixel static-raster profiles as each
  selected hardware track supplies evidence;
- golden fixtures and target previews.

**Exit:** deterministic byte-for-byte results, bounded malformed inputs, clean
worker crash/timeout recovery, and no in-process native crash surface. The
Conjunct assembly viewer is separate from this artwork renderer.

### H3 — Native shell

- SwiftUI `MenuBarExtra` window;
- menu-bar agent with no launch window or Dock entry, using the selected
  perspective-frame mark on a transparent Finder icon field, monochrome
  menu-bar icon, and compact branded dropdown header with an accessible Quit
  control;
- native translucent dropdown backdrop and a bounded scrolling artwork list;
- task-first compact, focused and Settings presentation modes that preserve one
  selected-frame, still-artwork, draft, focus and delivery-state envelope
  without browser breakpoint logic;
- target selection, instruction/import, library search, result cards;
- regenerate, pin, remove, queue/send, and concise status;
- Keychain, Vision labels/feature prints, notifications, accessibility;
- Settings and `SMAppService` opt-in background lifecycle.

**Exit:** menu-bar acceptance scenarios pass at the specified native popover and
window fixtures with keyboard/VoiceOver and macOS accessibility preferences,
with no AI provider configured and no change to the selected still or delivery
meaning across presentation modes.

### H4 — AI adapters

- provider contract and preflight;
- local MediaGenerationKit candidate;
- experimental Ollama adapter that proves a real generation before enabling;
- Draw Things+ cloud and optional Gemini API behind explicit cost/privacy
  disclosure and current authorization;
- recipe/cache/provenance and cancellation.

**Exit:** local-only mode emits no provider traffic; no automatic cloud switch;
cached repeat avoids provider call; secrets remain in Keychain.

### H5 — Qualified render and transfer generations

- define versioned renderer and connector operation descriptors, a reusable
  qualification manifest, an asset-specific work manifest, and an immutable
  result binding exact wire bytes;
- attest the renderer build and canonical selected frame profile, then qualify
  candidate combinations against software fixtures and measured frame cohorts;
- persist candidate, evidence, admission, and active cohort selection under
  the single writer; preserve legacy pending work without retroactive claims;
- pin accepted render work and push/pull intents to exact work and qualification
  digests across restart, candidate activation, rollback, and reconciliation;
- add bounded diagnostic coverage and adversarial tests for incompatibility,
  exact replay, uncertain effects, duplicate transfer, and last-good retention.

**Exit:** a new job cannot use an incompatible or unadmitted combination;
accepted work and last-good bytes survive a cohort switch and restart; physical
display success still requires authoritative frame evidence. See
[qualified generations](qualified-generations.md).

## Protocol track

### P1 — Schemas and simulator

- Frame and Host Outbox Thing Models plus vendor-independent TD examples;
- extension-preserving bounded W3C TD/TM admission and deterministic Form
  selection;
- state, desired, playlist, outbox manifest/ack, and problem schemas;
- digest-addressed fake storage;
- a separate Docker-managed frame receiver for the default Paper, Photo, and
  Pixel manufacturer candidates, contacting the host over real mutual TLS;
- fault injection for slow refresh, sleeping contact, bad digest, full storage,
  power-loss checkpoints, and version skew.

### P2 — Security prototype

- physical pair-mode abstraction and QR/bootstrap flow;
- pinned server identity and mutual TLS;
- host Keychain/client identity;
- authorization, reset, redacted diagnostics;
- independent review before production claims.

### P3 — Conformance suite

- semantic, runtime, binding, live-transport, firmware, and hardware evidence
  profiles whose claims cannot substitute for one another;
- direct push and sleeping pull across advertised Forms rather than assumed
  vendor endpoints;
- idempotence/preconditions;
- parser and allocation bounds;
- atomic storage/state recovery;
- still-only negative cases.

**Exit:** protocol compliance tests pass against the simulator and at least
one real selected hardware track for the corresponding claimed profile.

## Hardware tracks

### Paper track

Qualify an exact colour e-paper/driver assembly, build its low-profile
controller path, implement exact packing/refresh and measure the complete
energy/depth cycle. Small and large paths can proceed independently. A battery
variant needs its own protection, charging and interrupted-refresh evidence.

### Photo track

A donor or raw-panel prototype can identify interface risks. Verify exact
panel/controller and retained-still boot behavior, then measure optics, power,
heat, complete depth and mounting/cable options. A controller that merely
lights a panel is not a final qualified design. Still artwork does not remove
continuous scanout/framebuffer requirements.

### Pixel track

Prove exact module/driver revision, scan mapping, refresh and power limits.
Scaling is a recommended risk-reduction method, not a mandated start point.
Full-array current, power distribution, timing and thermals are independent
qualification obligations.

No track must precede another or be implemented by every contributor. The
[thin composition matrix](../research/thin-composition-evidence.md) preserves
technical candidate sources and unresolved geometry/controller evidence.

## Evidence and release gates

Development snapshots may contain only some components, but they are never a
different product scope. The verification ledger names each bounded claim and
its evidence profile.

A releasable software build requires the installed end-to-end flow, compatible
bindings, authenticated lifecycle, migration/recovery, accessibility, signing,
hardened runtime, notarization, dependency/license inventory and required
security review. Product and upstream conformance are checked separately.

## Distribution and platform gates

Mac distribution uses one signed, notarized DMG for direct download, Homebrew
Cask and Sparkle. Ubuntu amd64/arm64 and Pi 5 Ubuntu Server arm64 use target
packages authenticated by a signed release manifest or APT repository and the
same host contracts. Nerves Pi 5 is a separately qualified external appliance.
The guide links only to real verified artifacts. See
[installation and guide](install-and-guide.md) and [Linux host](../host/linux.md).

1. Freeze release manifest, OS/CPU matrix, signing identities, package names
   and external artifact channel without changing source visibility.
2. Qualify object/SQLite backup and restore, native logging limits and the Mac
   signed/notarized lifecycle.
3. Prove Gleam on the pinned OTP and JavaScript targets; build and accessibility
   test the guide against exact fixtures.
4. Publish only after direct Mac/Cask/Sparkle artifact identity and update
   tests pass and the actual claimed product/hardware evidence exists.
5. Port the same core to Ubuntu amd64/arm64; qualify Pi-host storage, power and
   service behavior; publish each package only after its own gates.
6. Build/test the separately signed Nerves appliance's validation/revert,
   credentials, persistent state and logging.

A guide simulation or host package does not certify a frame assembly. A released
hardware profile also requires an exact reproducible assembly, signed
rollback-capable firmware, protocol conformance, interrupted-update recovery
and measured electrical, power, thermal, optical, installed-depth, mounting
and service evidence. Required independent safety/conformity evidence is
tracked for the actual claim; naming a profile reference cannot replace it.
