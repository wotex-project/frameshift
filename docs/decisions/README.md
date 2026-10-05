# Decision Ledger

This ledger records decisions that materially constrain Frameshift. It is not
a substitute for the detailed specifications linked from each entry. A
decision can change when measurements or upstream changes invalidate its
evidence, but it must change explicitly. Company strategy and monetization
are outside this technical ledger; historical revisions remain in Git.

## D-001 — Product name

- **State:** accepted
- **Decision:** The product and project name is **Frameshift**.
- **Consequence:** All other capitalizations and word breaks are incorrect in
  product copy, source identifiers, and protocol names.

## D-002 — Still images only

- **State:** accepted
- **Decision:** Frameshift displays still images. It does not render video,
  animation, live streams, motion graphics, or animated transitions.
- **Consequence:** A slideshow is a sequence of independently cached still
  assets with discrete swaps and dwell times. Membrane and media-streaming
  infrastructure are outside the artwork architecture. Companion assembly
  instruction animation is a separate visualization system.
- **Rationale:** This matches the product intent and removes continuous
  decoding, frame-rate, streaming, and audio concerns from device artwork.

## D-003 — Language boundary

- **State:** accepted
- **Decision:** Elixir/OTP is the host orchestration language;
  Swift/SwiftUI is the smallest practical macOS shell and Apple API bridge;
  the existing isolated host renderer uses Zig. Nerves is the selected base
  for a separately qualified dedicated Pi 5 bridge/appliance. Select MCU
  firmware language and toolchain from exact board, display, security, and
  recovery evidence.
- **Consequence:** Frameshift-owned application, firmware, scripts, tests, and
  examples contain no Python. A pinned upstream toolchain may run Python in
  an isolated reproducible build; its provenance and output are release
  evidence. It is never a shipped application runtime.
- **Detail:** [Software stack research](../research/software-stack.md)

The Linux canonical codec is a separate bounded Rust executable consuming
pinned memory-safe upstream PNG/JPEG, color and metadata libraries. It does not
replace Elixir orchestration, the Zig raster worker or Apple's native adapter.
Its admitted static-PNG/bounded-JPEG profiles and exact source cohort are owned by
[the content pipeline](../architecture/content-pipeline.md#linux-native-normalization)
and [source review](../research/software-stack.md#linux-codec-source-cohort).
Other formats and installed target closure require separate qualification.

## D-004 — Host-rendered immutable artifacts

- **State:** accepted
- **Decision:** The Mac retains source masters and renders immutable,
  display-specific artifacts. Frames store and display validated artifacts.
- **Consequence:** The frame never needs an AI model or a general image editor.
  A renderer upgrade can reproduce target artifacts from the source and recipe.
- **Detail:** [Content pipeline](../architecture/content-pipeline.md)

## D-005 — Local-first AI with explicit fallback

- **State:** accepted with provider qualification gates
- **Decision:** Local generation is preferred. Draw Things/
  MediaGenerationKit is the current dependable Apple Silicon candidate;
  Ollama remains an experimental adapter subject to runtime preflight. Draw
  Things+ is the preferred subscription-backed cloud candidate. Gemini image
  models are optional metered API providers or manual-import sources.
- **Consequence:** Consumer web subscriptions are never automated or presented
  as API entitlement. Cloud use requires an explicit destination and cost
  disclosure before generation.
- **Detail:** [AI image generation research](../research/ai-image-generation.md)

## D-006 — W3C WoT capability envelope

- **State:** accepted for protocol v0.1
- **Decision:** Frames and host outboxes use W3C Web of Things Thing Description
  1.1 and reusable Thing Models. Frameshift adds a small namespaced still-display
  vocabulary. Properties, Actions, Events, and Forms separate semantic
  interactions from HTTPS, CoAP, MQTT, BLE, Matter, or gateway bindings.
- **Consequence:** Implementations preserve unknown extensions, bound parsing,
  do not fetch remote JSON-LD contexts at runtime, select advertised Forms
  deterministically, and never derive compatibility or endpoints from a vendor
  name. Exact hardware revisions remain first-class artifact/display-adapter
  profile data.
- **Detail:** [Frame Protocol](../architecture/frame-protocol.md) and
  [protocol foundations](../research/protocol-foundations.md)

## D-007 — Content addressing and atomic activation

- **State:** accepted for protocol v0.1
- **Decision:** Asset bytes are addressed by SHA-256. Upload and activation are
  separate. A complete, verified asset becomes desired state through an atomic
  pointer change; current state changes only after the adapter succeeds.
- **Consequence:** Interrupted transfers cannot replace displayed artwork.
  Frames retain current and previous-known-good assets through garbage
  collection.

## D-008 — Thin electronics and honest power classes

- **State:** accepted constraint; controllers remain candidates
- **Decision:** No Raspberry Pi hardware belongs inside a Frameshift reference
  frame. Complete installed thinness, not an arbitrary diagonal limit, governs
  the design. Paper supports sleeping/battery profiles where evidenced; Photo
  and Pixel require qualified thin scanout/controllers and continuous power.
- **Consequence:** Cable-free passive operation is a particular evidenced
  capability, not a universal label. Concealed low-voltage wiring does not mean
  no power connection. Boards, connectors, bend radii, batteries, converters,
  backing, mounting and thermal clearances all count toward depth.
- **Detail:** [Hardware platforms](../research/hardware-platforms.md) and
  [thin compositions](../research/thin-composition-evidence.md)

## D-009 — No mandatory cloud

- **State:** accepted
- **Decision:** Local import, deterministic rendering, discovery, transfer,
  caching, playlists, and display operation work without a Frameshift cloud.
- **Consequence:** AI providers, remote access, and managed firmware services
  are optional adapters, never prerequisites for showing existing artwork.

## D-010 — Host metadata boundary

- **State:** accepted; release qualification gates remain
- **Decision:** One Frameshift-owned OTP process serializes metadata access
  through Exqlite. The implementation uses direct SQL and numbered
  migrations rather than Ecto. Immutable artwork bytes remain in the
  content-addressed file store.
- **Consequence:** Transaction and reference-protection invariants stay in one
  owner. No other module receives the database connection. The Exqlite NIF is a
  packaging and crash-recovery validation dependency and does not inherit the
  Zig worker's process-isolation claim. NodeDB Lite, CubDB, and analytic
  engines do not replace the authoritative ledger; search projections remain
  rebuildable.
- **Detail:** [SQLite and Elixir boundary](../research/sqlite-elixir-boundary.md)
  and [embedded persistence review](../research/embedded-persistence.md)

## D-011 — Universal WoT interaction boundary

- **State:** accepted; implementation and interoperability gates remain
- **Decision:** Frameshift semantics are defined as W3C WoT Thing Models,
  Thing Descriptions, affordances, DataSchemas, and Forms. The reference HTTPS
  binding is one transport mapping, not the protocol identity. Additional
  bindings may coexist when they preserve the same state and effect contract.
- **Consequence:** Hosts consume advertised Forms and preserve unknown optional
  extensions. Required unknown profiles fail explicitly. Specific vendors,
  panels, controllers, and packers are represented by exact capability and
  artifact-profile data, not conditional endpoint logic.
- **Implementation reference:** Wotex supplies patterns for bounded admission,
  deterministic selection, explicit credential/transport ports, supervised
  subscriptions and evidence-scoped conformance. Consume qualified packages at
  one pinned full commit. Frameshift retains binary transfer, transport
  security policy, canonical state and physical display-effect evidence.
- **Detail:** [Protocol foundations](../research/protocol-foundations.md) and
  [Universal Frame Protocol](../architecture/frame-protocol.md)

## D-012 — Portable domain boundaries

- **State:** accepted as a software design; platform qualification remains
- **Decision:** Organize the host as a modular monolith with Library, Frames,
  Delivery, Rendering, and Generation domain boundaries. Diagnostics supports
  them all. Delivery owns desired, confirmed displayed, and previous-known-good
  transitions; Frames exposes their read projection. One SQLite writer retains
  the cross-boundary atomic invariants.
- **Consequence:** A context is not a separate process, database, or generic
  repository interface. Domain decisions are independent of storage and IPC
  representations. D-010 remains in force; adding Ecto is not a domain
  architecture requirement.
- **Detail:** [Host domain map](../architecture/domain-map.md)

## D-013 — Local diagnostic signals and OS log readers

- **State:** accepted as a software design; installed/platform evidence remains
- **Decision:** Store audit facts with domain mutations, aggregate bounded
  local metrics from named telemetry events, and send operational logs to
  native OS logging. Console.app and `/usr/bin/log` are the macOS log readers;
  a read-only authenticated CLI exposes health, metric rollups, and audit.
- **Consequence:** Logs and metrics are not authoritative display state. The
  Mac's privileged local log-store API is not an application diagnostic
  dependency. No diagnostic UI or remote telemetry service is required.
- **Detail:** [Diagnostics contract](../architecture/diagnostics.md) and
  [host diagnostics research](../research/host-diagnostics.md)

## D-014 — Qualified render and transfer generations

- **State:** accepted as a software design; qualification implementation and
  physical evidence remain open
- **Decision:** Admit a reusable renderer/profile/transfer qualification for
  each exact frame capability instance. Pin each accepted render and transfer
  workflow to an immutable work digest combining that qualification with its
  source and recipe. The work identity exists before rendering; the exact
  wire-byte digest is attached as a result. Accepted work retains its binding
  across activation, rollback, and restart.
- **Consequence:** The artifact digest remains SHA-256 of the exact wire bytes.
  A successful transfer cannot stand in for display confirmation. Qualification
  and activation are durable local host decisions; cloud tenancy and a remote
  composition service are not prerequisites.
- **Detail:** [Qualified generations](../architecture/qualified-generations.md)

## D-015 — Public guide and native installation

- **State:** accepted delivery design; public release evidence remains open
- **Decision:** Publish an accessible static installation guide first at
  `frameshift.wotex.io`. Mac direct download, Homebrew Cask, and Sparkle consume
  one signed and notarized release artifact. Ubuntu uses architecture-specific
  packages authenticated by a signed release manifest or APT repository.
  Source visibility and public artifact distribution are separate decisions;
  this work does not change repository visibility.
- **Consequence:** `frameshift.se` is optional. No public release claim or
  install command precedes signing, licensing, notices, clean-install tests,
  and manifest/digest verification.
- **Detail:** [Installation and interactive guide](../architecture/install-and-guide.md)

## D-016 — Shared browser decision kernel

- **State:** accepted design; existing generated cross-target parity evidence
  is bounded, while browser and installed release acceptance remain open
- **Decision:** Use the same bounded pure Gleam source for Erlang and browser
  JavaScript decisions. The browser runs locally and holds no pairing
  credentials or delivery authority. Exact raster bytes remain the Zig
  renderer's responsibility.
- **Consequence:** The guide can demonstrate capability and failure behavior
  without hosted Elixir execution. Cross-target parity and safe integer bounds
  are release gates. Deep links carry non-secret choices only.
- **Detail:** [Installation and interactive guide](../architecture/install-and-guide.md)

## D-017 — Linux host and Pi appliance roles

- **State:** accepted platform design; installed qualification remains open
- **Decision:** Ubuntu amd64/arm64 and Ubuntu Server arm64 on Pi 5 reuse the
  portable host core. A Nerves Pi 5 image is a separate dedicated external
  bridge/appliance with its own signed firmware lifecycle. No Pi enters a
  reference frame.
- **Consequence:** Linux service identity, credentials, journald, package
  updates, and native dependencies need platform tests. Nerves uses persistent
  `/data`, firmware validation/revert, and a bounded OTP log sink instead of
  systemd facilities. Neither role needs a vendor cloud to show artwork.
- **Detail:** [Linux host](../host/linux.md)

## D-018 — Companion platform and repository ownership

- **State:** selected design, revised 2026-09-25; implementation evidence open
- **Decision:** Use Phoenix, Ash/AshPostgres and phoenix-assets/Svelte 5/SvelteKit
  with one qualified Refpath runtime. Frameshift-specific profiles, packs,
  models and evaluations stay here. Generic Conjunct extraction follows D-022.
- **Consequence:** Server domains do not replace the single-writer local core.
  The static/offline guide remains available. Establish dependency checks
  before verified path moves and keep generic producer changes upstream.
- **Detail:** [Build platform](../architecture/build-platform.md)

## D-019 — Composition and instructions first; service work on hold

- **State:** revised 2026-09-25; transactional shop implementation on hold
- **Decision:** D demonstrates composition, visual procedures and exact printable
  output; E qualifies research and adaptive producer integration. The parts and
  shopping list is a composition projection. Optional provider/financial work,
  purchasing and care remain deferred F after D/E; they do not gate the engine
  integration proof or independent native product.
- **Consequence:** The guide does not depend on an account or live provider.
  Operator capability, role and financial-policy choices enter through explicit
  approved contracts rather than a selected business model in product code.
  External permissions and measurements gate relevant activation but do not
  excuse missing implementable simulations, refusal and recovery behavior.
- **Detail:** [Service integration](../architecture/build-commerce.md) and
  [implementation order](../architecture/implementation-plan.md)

## D-020 — Deterministic composition, formal checks and evaluated models

- **State:** required boundaries; physical/formal implementation and actual
  Frameshift model benchmarks remain open
- **Decision:** Use pure Gleam for shared decisions and ExMaude for targeted
  independent predicates, explicit search outcomes and counterexample replay.
  Evaluate optional local/hosted models per task. Models cannot grant physical
  compatibility or external-action authority.
- **Consequence:** Generic completion/trace support belongs upstream. Empty
  bounded search is not proof. Product-specific models remain here; no model
  candidate creates an exception to D-003.
- **Detail:** [Physical contract](../architecture/physical-build-contract.md),
  [orchestration](../architecture/build-orchestration.md) and
  [technical research](../research/build-platform-decisions.md)

## D-021 — Read-only investigation and independent telemetry

- **State:** selected design; production qualification open
- **Decision:** Use one authorized, bounded Beamlens supervisor. Configure its
  BAML provider at the actual diagnostic boundary; ordinary Refpath inference
  and diagnostics do not automatically share a registry. Retain the current
  Prometheus exporter; qualify GreptimeDB ingestion as the selected shared-host
  metric destination and a bounded log/trace path without ELK.
- **Consequence:** Exact dependency/skill qualification and resource ceilings
  are required. Diagnostic/provider failure cannot disable ordinary telemetry,
  alerts or commands. D-013 native OS/CLI diagnostics remain independent.
- **Detail:** [Diagnostics](../architecture/diagnostics.md)

## D-022 — Conjunct product-engine consumer and technical-only corpus

- **State:** integration direction, source mapping revised 2026-10-04; consumer qualification open
- **Decision:** Frameshift is the first modular reference product and integration
  proof of concept for Conjunct. Its physical BuildSpec becomes a versioned
  product profile of qualified Conjunct composition
  semantics. Frame-specific code/procedures/evidence remain here; generic
  product compilation belongs in Conjunct, adaptive execution in Refpath,
  financial primitives in Rivure and documentation data in DocShell.
- **Implementation direction:** Consume Conjunct's existing Rust semantic
  kernel through its public Elixir port and browser WASM bindings, with its
  portable guide. This does not replace the Zig artwork renderer or require
  a new Frameshift-owned Rust/Gleam composition engine. Freeze exact producer
  discovery and distribution, frame-rule coverage and loss-refusing v1 migration
  before switching semantic authority.
- **Consequence:** No competing encoders, UI graph, effect journal or copied
  manufacturer applications. Preserve native/device independence and exact
  accepted identities through migration. Preserve the existing app moves,
  compiler and recorded tests for v1 replay and frame-rule regression through an
  explicit migration; they do not authorize a parallel successor workbench.
  Private corporate strategy, monetization and legal analysis remain outside
  this repository.
- **Detail:** [Conjunct integration](../architecture/conjunct-integration.md),
  [adoption evidence](../research/conjunct-adoption.md),
  [thin composition evidence](../research/thin-composition-evidence.md)
