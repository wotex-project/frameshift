# Software Verification Map

**Status:** implementation evidence ledger against the complete product

This map connects bounded requirements to executable checks. A passing row
demonstrates only the named behavior and evidence profile. It does not create a
smaller product tier or satisfy a broader end-to-end requirement. Simulator
results do not validate live transport, physical panels, controller
electronics, packaging, security review, or certification.

## Companion build platform

The [canonical platform plan](build-platform.md) and
[Conjunct integration contract](conjunct-integration.md) define the current
composition/instruction direction. Existing boundary, host and partial compiler
evidence is retained below. D produces visual procedures and independent parts
lists from the same composition; E qualifies generic and adaptive producer
integration. Optional transactional F is on hold and does not gate the engine
integration proof of concept. Native product acceptance remains separate.
Hardware tests, agreements and release administration are distinct evidence
gates. Specification and retained v1 tests do not establish Conjunct runtime
conformance.

[PC-01–PC-09](producer-contracts.md) define required library deliveries, with
implementation and joined tests tracked below. An unfinished specified producer
is implementation work; only undecided behavior is a contract gap. Simulators
can support development without qualifying the real producer boundary.

| Requirement / milestone | Owner | Required software evidence | Current state |
| --- | --- | --- | --- |
| BP-01–BP-03, BP-11, CI-01–CI-04 / A | Product/specifications | Canonical plan, ownership/extraction map, coherent dependency gates and aligned linked docs | Current Conjunct source/API cohort and specification delivery S1–S7 are mapped in the consolidated research and implementation plan. Pure upstream kernel/registry tests were rerun; no Frameshift integration completion implied |
| BP-06–BP-09 / B | Web/domain boundaries | `scripts/check-workspace`, `scripts/workspace_test.exs`, `scripts/check platform`, `FrameshiftPlatform.CatalogTest`, `FrameshiftPlatformWeb.HTTPTest`, `FrameshiftPlatform.OrchestrationTest`, `FrameshiftPlatform.DependencyBoundaryTest`; generated-contract and migration drift checks | Nineteen workspace fixtures include frontend alias, relative import, dynamic literal, opaque/glob refusal and cross-application checks. Twenty platform tests cover source/audit rollback, actor policies, public projection, shared runtime pool/PubSub, separate schemas, raw analytics queries and repeated upserts. Svelte contracts and a live Chrome source page work. Exact Refpath/AshPostgres pins and pgvector migrations are recorded; remote CI needs its private-runtime read credential. Gleam moved with 256 parity cases, guide and core-release checks. Core, macOS and guide moves passed their full affected gates. Bounded diagnostics and authenticated write boundaries remain open |
| BP-07 / public catalog view | Frameshift web UI | Svelte type/lint/build, bounded HTTP profile/source read tests and local Chrome rendering; pagination fault and responsive browser acceptance still required | The page lists three candidate profiles with exact downloads and five source records in the seeded local catalog. Candidate limits are explicit. Manual pagination retains loaded records, deduplicates shifting pages and stops at the server's offset ceiling. This view does not implement composition or build admission |
| PB-01–PB-06, PB-09 / C | Catalog + pure packages | Three-class sourced fixtures, bounded schemas, canonical hash/parity, valid/invalid/unknown combinations, fact/protocol mapping and export round trips | Thirteen retained v1 checks now run together in a verified-input planning preview with cross-target parity; partial compiler and immutable catalog evidence are recorded [below](#physical-compiler-evidence). This preview is replay/migration evidence, not a successor workbench engine. Qualified Conjunct composition/report and product consumers remain open |
| PB-07–PB-09, PC-04 / C | Conjunct verification + Frameshift profile + ExMaude P2 | Typed completion/termination, session/worker leases, bounded/exhausted/inconclusive results, mutation detection, compiler replay and invalidation | ExMaude SearchRun and the producer-reported two-predicate formal join exist. Typed cancellation/state limits, full frame coverage and this consumer join remain open; deterministic compiler/viewer work proceeds independently |
| CI-02–CI-04, PC-02 / C | Conjunct core + product adapter | All five v1 domains replay unchanged; wire/rational/unit/occurrence successor mapping, purpose-bound CheckReport, both-runtime parity, loss refusal and mandatory frame checks | S1 staged data/transport consumers pass at the frozen cohort below. Thirteen-stage frame mapping, complete operations and consumer migration/parity remain open. Existing v1 evidence is retained |
| CI-05–CI-07, BP-04–BP-05, PC-02/PC-05 / C–D | Conjunct evidence/geometry/procedures + DocShell | Source/feature/step binding, offline freshness and retention, exact transforms/loss, evidence-bearing procedure transitions and equivalent accessible outputs | Producer geometry/procedure/guide exports and DocShell collection APIs exist; frame content and joined consumer tests remain open. Synthetic/manual geometry supports the first profile. The selected planar AP214 STEP adapter is narrower than general CAD support and activation remains unqualified; federation qualifies separately |
| BP-04–BP-05, CI-07 / D | Visual composition and instructions | Conjunct selection/comparison/CheckReport and procedure/output semantics through the Frameshift UI; local save/reload I/O without accounts/checkout; missing facts/prices, private artwork, keyboard, screen reader, reduced motion, low graphics and reconnect checks | Missing; existing static installation lab and v1 planning preview are not this workbench |
| CI-04, CI-08 / E | Conjunct producer + product consumer | Passive enclosure/fastener/packaging and connected-sensor fixtures use the same core without frame imports; exact frame profile retains required checks | Producer draft vectors include passive/sensor cases; expectations await independent review. Frameshift consumer replay and stable semantic conformance remain open; transport parity is not independent-engine agreement |
| BO-01–BO-03, BO-07–BO-08, CI-08, PC-03 / E | Frameshift packs + Conjunct adapter + Refpath P1 | Durable scoped head, CAS/fences, verified VM cold-start, idempotent admission, old-work dispositions, two operators, schedule/DST, source admission and receipt recovery | Installed Refpath durable admission exports exist; atomic current review-through-commit and two-operator joined qualification remain open. Conjunct selects a different producer cohort. Existing embedded host tests qualify their recorded scope only |
| BO-04–BO-06 / E | Decision evaluation | Held-out project labels/rubrics, rules baseline, candidate qualification, false acceptance/coverage, latency/memory/total cost and outage/budget gates | Research only; no model selected by Frameshift benchmark |
| BP-10, BO-08 / B–E, extended F | Diagnostics | Metrics/trace/audit definitions, bounded labels, Beamlens production dependency/single supervisor, authorized read-only/redacted observations, budgets/outage/overhead | Server catalog v3 has fixed histogram buckets, bounded source/profile/HTTP labels, database timing, VM gauges and reset/sample timestamps. Thirty-two platform tests include 100,000 concurrent observations without scraping, invalid measurement refusal and collector outage/restart; Prometheus config and alert fixtures pass. Structured logs/traces remain open. Beamlens is an explicit production dependency but its bounded supervisor/provider integration remains open. Native host evidence below remains distinct |
| CI-08 / operated host | Host + shared telemetry receiver | Exact GreptimeDB/collector/auth/retention join, bounded logs/traces, loss/redaction/outage and restore | Planned; current Prometheus exporter/alert evidence does not establish this destination |
| PC-06–PC-08 / applicable host profile | Web/device/diagnostic owners | Trusted scoped actors, expected-revision commands, generated type parity, separate exact-unit device authority, bounded read-only diagnostics and consistent recovery closure | Requirements assigned; existing native/catalog/metrics evidence remains bounded. New host/device/restore joins require their own tests |
| BC-01–BC-04 / optional F | Policy / Quotes & Mandates / Rivure integration | Role/route readiness, exact quote/mandate snapshots, producer fee/rounding/reversal fixtures, actor isolation and stale/revoked-authority refusal | On hold; no financial implementation. Actual operation scope and producer APIs need qualification if resumed |
| BC-05–BC-06, BC-09 / optional F | Purchasing + Refpath/provider contracts | Placement/cancellation/refund/notification/reconcile capabilities, duplicate/out-of-order/unknown/partial-order faults and selected-provider sandbox checks | On hold; generic producer capability gaps remain explicit |
| BC-07–BC-10 / optional F | Fulfillment & Care / Access & Policy | Tracking, cases, returns/refunds/disputes/recalls, data rights/reporting, financial reconciliation, restore and accessible customer/operator paths | On hold; simulator evidence must remain distinct from external activation |

### Producer source checks, 2026-10-04

The [consolidated research](../research/conjunct-adoption.md#evidence-actually-established)
records a rerun on Conjunct `f6609c5e4c2188626f5e1f345446fec04e78d6c9`
with Rust 1.97.1: 174 kernel and 8 distribution tests passed. This checks the
exercised pure upstream paths, not a Frameshift adapter, complete producer gate,
transport/browser package join, independent semantic conformance or hardware.
Other upstream join results are attributed source observations. The draft
50-case suite still awaits independent expectation review. S1–S7 in the
[implementation plan](implementation-plan.md#composition-specification-delivery)
assign the next consumer evidence without promoting these source checks.

### Staged Conjunct consumers, 2026-10-04

`scripts/check conjunct` builds the exact pinned source archive and verifies
the [S1 consumer contract](conjunct-integration.md#s1-consumer-bundle-and-acceptance).
On macOS arm64, Rust 1.97.1, Node 26.9.0, TypeScript 6.0.3 and
Elixir 1.20.4/OTP 29.1 built and consumed the native port, raw WASM,
Elixir kernel/wire/data and JavaScript kernel/data/guide artifacts.
Fresh consumers outside the repository resolved runtime dependencies offline;
the distributed declarations compiled without suppressing declaration checks.
Three Elixir cases and the Node/browser exercises passed. Chrome
154.0.8037.95 consumed the local Worker artifacts with networking disabled
after loading them. Canonical scope identity and nine original protocol
responses matched through the Elixir port, raw WASM and Node/browser Workers.
Unsupported profiles/contracts, escaped duplicate keys, rational overflow,
oversized documents, stale contexts, canceled dispatched work, bounded queue
overflow and incorrect executable digest have explicit refusal checks.
Eight policy tests cover artifact/manifest tamper, symlinks, permissions,
undeclared files, discovery mismatch and hostile archive entries.

Each run retains the exact bundle manifest digest, target/browser, fixture
bytes and transport response reports under ignored `var/conjunct/bundles/`.
This is package/data/transport integration evidence for the recorded target,
not complete semantic conformance, frame-rule coverage, v1 migration, a joined
guide procedure, another browser/OS or physical/operated qualification.
No catalog identity or existing compiler authority changes.

### Frame successor profile refusal, 2026-10-04

The [thirteen-stage S2 mapping](physical-build-contract.md#s2-successor-obligation-mapping)
records candidate predicates and missing producer derivations separately.
`FrameshiftPlatform.CompositionTest` checks every class retains all obligations,
reports unavailable and refuses caller-supplied readiness/admission flags;
invalid classes and HTTP mutation routes refuse. The complete platform check
passes 35 tests against a fresh isolated PostgreSQL database, with formatter,
warnings-as-errors compilation and strict Credo.
`scripts/check conjunct` loads one synthetic source and a supported `present`
RuleSet control, then reproduces the unsupported `directed_flow` predicate's
located schema refusal through the real Elixir port and raw/Worker/browser WASM.
Exact original responses agree and are retained with the checker/input digests.
This establishes the current-contract refusal and product availability gate.
It does not complete S2's positive/violated/unknown corpus, S3 migration or S4;
generic producer flow/route/group/support/raster assessments remain required.

### Physical compiler evidence

Run `scripts/check build-spec` for the shared package. The current gate passes
183 Gleam tests per target, 26 Elixir and 38 browser/data tests, all listed
parity/oracle fixtures and an isolated OTP release without test modules. These
are bounded software claims under declared inputs. Full BuildSpec admission,
qualified contracts and physical evidence remain required.

| Stage | Implemented and verified scope |
| --- | --- |
| Arithmetic | Exact units, tolerances, grids/stacks/loads/apertures, voltage and unknown/refusal behavior on both targets; 256 generated parity records |
| Profile identity | Nine shared codec tests, 2,048 corruption cases, four tests per identity adapter and 256 canonical-byte/SHA-256 parity fixtures; packaged JSON runtime |
| Sourced catalog | Three candidate profiles resolve five source revisions; five data regressions preserve conflicts/unknowns and reject tampering/orphans. Ash immutable profiles retain source bindings and atomic audit attribution. Twelve profile/domain/HTTP tests cover policies, spoofing, rollback, partial import, file/size refusal and conditional downloads |
| Assembly identity | Eight shared tests, three Elixir/four browser adapter tests, 2,048 structural corruptions and 256 byte/hash parity records preserve exact pins, per-unit placements, dependencies and intent |
| Exact resolution | Four shared tests and four per-adapter tests cover byte/count ceilings, missing/extra/duplicate bodies, changed revisions and unavailable cryptography |
| Graph constraints | Eight tests cover class/revision, roles, required ports, endpoint/direction errors and exact cycle members. All 512 directed three-node graphs agree with independent closure |
| Scoped facts | Five shared reader tests retain units and citations and refuse unusable values; two BEAM/three browser checks exercise actual candidate data without nominal or conditional substitution |
| Enclosure geometry | Nine tests cover six faces, rotated clearances, exact contact, unknowns, external instances and maximum bounds. Another 2,048 placements match independent corner transforms |
| Viewing | Four rectangle, four projection and ten viewing tests cover union gaps, interval offsets/rotation, nested mats, tiled seams, plane order and obstructions, including 3,906 obstacle pairs. All 512 small rectangle subsets match a cell oracle; 256 projections match 64 extreme-choice combinations each |
| DC interfaces and loads | Eight interface tests cover voltage/polarity/declarations and 1,792 obligations in a 256-edge fixture. All 441 finite voltage interval pairs match point enumeration. Nine budget tests cover repeated/shared rails, rounding, unknown loads, ambiguous feeds and full converter input demand; 256 target ports retain exact 7,680,000,000 mW derived power |
| Connected declarations | Three connectivity and six contract tests catch pairwise/global disagreement, passive rails, unknowns and converter domains. All 512 edge subsets match undirected closure; the 576-node/512-edge boundary passes |
| Passive DC flow | Nine tests cover cumulative drops, branch demand, input ratings, optional-feed bypass and cycles, including 690 findings in a 64-instance chain. Another 256 generated budgets match independent endpoint enumeration. One evidence test preserves distinct observations sharing a lookup key |
| Thermal | Eight tests cover complete local ambient/rise, repeated heat, external parts, missing/conflicting facts, scope agreement and enclosure ambiguity, including 64,000,000 mW and 600,000 m°C intermediates. Another 256 fixtures match independent extreme-choice enumeration |
| Mounting | Eleven tests cover support modes/paths, complete child plus adapter mass, port/shared ratings, installation kind, unknowns, cycles, internal-anchor bypass and connected joint declarations. A 64-instance chain carries 6,300,000 g. Another 256 trees agree with independent descendant-set mass accounting |
| Signal declarations | Seven tests cover full voltage containment, unknown/conflicting facts, unsupported polarity, driver/reference agreement, invalid endpoints and global alternatives, including all 519 findings in a 256-edge group |
| Runtime intent | Nine tests cover controller/display roles, selected artifact/firmware/protocol, conservative dwell limits, advisory separation and storage ownership, including shared/multiple-device refusal, repeated instances and exact 2^40-byte/seven-day boundaries |
| Mandatory obligations | Eight tests cover omitted/optional requirements, power and signal roles, source-role disguise, exact rasters, controller ownership, exterior/cavity dimensions, missing profiles and unexpanded composites, including a 64-instance fixture |
| Directed display routes | Eleven tests cover ordinary edges, explicit internal mappings, ownership, missing/ambiguous feeds, cycles, stale scope and repeated profiles. A 64-instance chain and 511-edge port path pass; 512 directed topologies and their evidence references agree across runtimes and with independent matrix closure. Mapping admission remains separate |
| Mapping identity | Six shared codec tests include 2,048 corruptions, bounded ports/sources and exact round trips. Three Elixir/four browser tests cover immutable scope, source changes, input refusal and cryptography loss; 256 generated canonical-byte/hash records agree across runtimes |
| Compilation context | Seven shared, five Elixir and six browser context tests verify combined identity, complete sources, exact mapping/layout scope, missing/duplicate inputs and one 4 MiB budget. Context fixtures agree across runtimes and independent standard hashing. Browser regressions protect all four input snapshots during async hashing |
| Artifact layout identity | Five shared codec tests include 2,048 corruptions, exact round trips and resource bounds. Three Elixir/five browser tests cover mixed bindings, stale assignments, cryptography loss and input mutation. Another 256 generated layouts have identical canonical bytes and SHA-256 identities on BEAM and JavaScript |
| Artifact footprint | Ten tests cover canvas assignment, every rotation, gaps/overlap, owner/kind errors, missing/ambiguous rasters, encoding limits and individual/retained payloads. Maximum cases include 63 displays, 1,953 tile pairs and 3,221,225,472,000,000 exact bytes. Another 256 layouts match independent pixel/byte enumeration on both targets. Runtime qualification remains required |
| Planning preview | Four shared, two Elixir and two browser tests cover all 13 ordered stages, unknown versus known-incompatible results, exact input references, changed identity, malformed-layout refusal and a 64-instance chain. Three complete stage/check/reference fixtures agree byte for byte across BEAM and JavaScript. This retained v1 path supports replay, frame-rule regression and migration only. It does not implement Conjunct authoring, comparison, catalog/parts projection, CheckReport or instructions and never grants admission; current evidence, qualified mappings/runtime and physical validation remain open |

## Installed product and guide

| Requirement | Owner | Automated evidence | Current state |
| --- | --- | --- | --- |
| SQLite and content-addressed objects preserve protected references through backup, restore, full disk, and power interruption on each supported host filesystem | Core/platform | `Frameshift.LibraryTest`, `Frameshift.Library.MaintenanceTest`, and `scripts/check-packaged-app` exercise consistent snapshot, manifest, integrity and digest checks, active-core refusal, and offline restore; target storage fault tests required | Packaged offline backup, verification, and restore pass in software; power-loss and cross-platform physical storage evidence remain open |
| One pure Gleam decision kernel agrees on BEAM and JavaScript for bounded capability admission, profile choice, and simulated delivery transitions | Core/guide | `scripts/check kernel` runs shared dwell, RGB24 profile, and display-decision tests on Erlang and JavaScript; host `Frameshift.DisplayTimingTest`, `Frameshift.RenderProfileTest`, `Frameshift.Delivery.TransitionTest`, and outbox tests exercise the packaged BEAM dependency; `scripts/check-kernel-parity` compares 256 generated cases byte for byte; browser matrix and accessibility acceptance remain required | Dwell, currently supported RGB24 profile choice, and confirmation rules use the shared module in the host and build for both targets; the local guide and Chrome smoke pass; wider capability admission, cross-browser and accessibility acceptance remain open |
| Public static installation guide accurately links qualified artifacts and labels simulated versus physical evidence | Guide/release | `scripts/check guide` builds and tests the static lab against the JavaScript kernel and verifies conditional link markup; a local signed fixture build exercises link insertion and partial-input refusal; `scripts/check guide-browser` exercises a 390 px Chrome viewport, accessible names, keyboard controls, invalid file refusal, local still, profile refusal, interrupted transfer, offline interaction, and recovery; a local desktop Safari inspection showed the rendered guide and lab controls; `GuideHandoffTests` and the packaged URL registration check cover bounded native hints; a local ad-hoc packaged app received, dismissed, and received a Paper URL again through Launch Services; manual accessibility, browser interaction matrix, public manifest links and digests, and signed-install handoff acceptance remain required | Local guide, signed fixture build, Chrome smoke, desktop Safari rendering, bounded native handoff tests, and a live ad-hoc handoff pass; no deployed release guide or qualified public downloads |
| Release links identify signed exact archive bytes before publication | Release | `scripts/check release` exercises deterministic manifest creation from exact regular-file bytes, owner-only key admission, pinned-key signing, CLI round trip, detached Ed25519 verification, strict schema, HTTPS/versioned URL, size/digest, tamper, bounded HTTPS redirect, partial/compressed response refusal, and public byte verification; `scripts/build-release-guide` runs local and public checks before altering guide output; signed real artifacts and publication acceptance required | Local signer, verifier, and synthetic public-response checks pass; owner-pinned production key, signed artifacts, real public URL readback, and distribution remain open |
| One notarized Mac DMG installs by direct download and Homebrew Cask and updates through Sparkle without identity or data loss | Mac/release | Clean Mac install/update/rollback, Gatekeeper, nested-signature, appcast-signature, background-registration tests required | Ad-hoc development bundle only; no public artifact |
| Ubuntu amd64/arm64 and Pi 5 Ubuntu Server arm64 run the same authoritative core and protocol with safe service, credential, log, import, and upgrade behavior | Linux/release | `scripts/check linux-ipc` exercises pinned OTP and actual `SO_PEERCRED` PID, UID, and primary GID for root and UID/GID 65534 in a read-only, network-disabled Linux container and runs on native amd64 CI; cross-platform contract suite, clean `.deb`, peer-authenticated command/diagnostic sockets, bounded streamed import, systemd/journald, full-disk, idle and migration tests required | Linux peer-credential contract passes locally on arm64; native amd64 CI result, group admission, platform port, and packages remain open |
| Dedicated Nerves Pi 5 bridge validates signed firmware, reverts failed boot, keeps persistent state, and exposes bounded diagnostics | Pi appliance | Exact image boot/update/failure, `/data`, identity provisioning, circular-log and resource tests required | Separate appliance design specified; no image built |
| Portable domain boundaries preserve delivery, content-reference, replay, and audit atomicity under one writer | Core | `Frameshift.Delivery.TransitionTest`, `Frameshift.Diagnostics.StoreTest`, library and diagnostic audit tests, existing outbox/direct-delivery crash and replay tests; Mac/Linux contract tests required | Pure Delivery decisions and the Diagnostics audit policy are extracted; persisted audit details are allowlisted; remaining context extraction and cross-platform qualification remain open |
| A failed update is traceable by command and attempt ID across durable audit, native logs, metrics, and authoritative display state | Core/shell | Direct timeout and reconciliation tests, diagnostic IPC and formatter tests; packaged command-to-display failure injection, redaction, restart, and correlation tests required | Direct push and reconciliation record distinct durable attempt facts, preserve a pending intent and count repeated timed-out pushes as `unknown`, correlate display confirmation, emit bounded attempt metrics, and allowlist IDs in native logs. Pull attempt tracing and independent-frame evidence remain open |
| Console.app and `/usr/bin/log` read core and shell operational logs without a Frameshift UI; health, metrics, and audit have a bounded read-only CLI | Core/shell | `Frameshift.LocalIPC.DiagnosticsServerTest` covers a stalled client, collector outage, and symlinked socket directory; `Frameshift.LocalIPC.ServerTest` covers symlink refusal and a second listener against a live socket; `Frameshift.Diagnostics.FallbackLogTest` covers fallback directory and target admission; `CoreLogBridgeTests` checks public field validation and bounded queue saturation; `scripts/check-packaged-app` exercises all three installed CLI reads; bridge-failure and Linux tests required | A packaged Mac app showed native shell and core command logs; the bundled CLI read health, metrics, and audit over peer-authenticated IPC. Both listeners and the fallback log now inspect their final paths before opening or changing permissions. Core log emission has a 512-record queue with counted loss; production signing, bridge-failure behavior, and long-running resource behavior remain open |
| Local metric catalog preserves units, bounded dimensions, restart coverage, and disk/resource ceilings | Core | `Frameshift.Diagnostics.CatalogTest`, `Frameshift.Diagnostics.MetricsTest`, `Frameshift.Diagnostics.StoreTest`, and `Frameshift.LocalIPC.DiagnosticsServerTest` cover concurrent atomic queue admission, bounded labels including the outbox listener lifecycle, invalid rollups, catalog meaning, the 20,000-row cap, SQLite page-budget pruning and rollback, unavailable page measurement, idle restart maintenance, reset and loss status, collector and SQLite owner outages, and restart readback; long-running load and idle measurements on Mac and Linux required | Local reporter, rollups, bounded labels, versioned definitions, atomic 10,000-event queue limit, restart readback, collector status, and a 32 MiB active metric page budget are implemented; historical coverage, shared WAL/free-page footprint, and physical disk/resource ceilings remain unqualified |
| Immutable content-addressed masters, recipe identity, recoverable removal, protected references, and verified readback | Elixir core | `Frameshift.Library.IdentityTest`, `Frameshift.LibraryTest`, `Frameshift.LocalAPITest`, `Frameshift.Library.MetadataTest` | Pure master admission and ordered canonical recipe identity are separated from the single writer; the local durable library implements the named storage behaviors. Native Recently Removed now exposes paginated verified restoration and current retention reasons. App Sandbox bookmarks, storage quotas and automatic retention policy remain open |
| Bounded control JSON, duplicate-key rejection, embedded schemas, and version skew rejection | Frame Protocol/core | `Frameshift.Protocol.JSONTest`, `Frameshift.Protocol.SchemaTest`, protocol fixtures | Implemented for v0.1 fixtures |
| Bounded W3C TD/TM admission, unknown-extension preservation, required-profile rejection, and deterministic advertised Form selection | Frame Protocol/core | `Frameshift.Protocol.ThingTest`, embedded Thing Models, Frame and Host Outbox TD fixtures | Implemented for the semantic admission/selection boundary; live bindings remain open |
| A selected finite JSON Property/Action Form executes through the pinned Wotex HTTP binding with exact credential audience, local-address admission, mutual TLS, no pooling/redirect/retry path, absolute deadline, and bounded response collection | Frame Protocol/core | `Frameshift.Transport.HTTPClientTest` with generated independent server/client certificate chains and a live loopback TLS socket; `Frameshift.Transport.KeychainBrokerTest` for callback framing; `scripts/check keychain-pairing` for an issued Keychain identity and live pairing/TD transport | Finite client binding and broker signing work together over live mutual TLS with an isolated Keychain identity. Installed app routing, SSE lifecycle, and production-device interoperability remain unverified |
| An awake push-capable frame receives an exact rendered artifact and desired-state request through its advertised binary/JSON Forms, strong ETag preconditions, bounded typed problems, explicit idempotent retry rules, and a final authoritative state read | Frame Protocol/core | `Frameshift.DirectSyncTest` across two route-independent TD variants; `Frameshift.Transport.HTTPClientTest` over live mutually authenticated, SPKI-pinned loopback TLS; `Frameshift.RenderPipelineTest` through the push-only queue command | Implemented through rendering and direct orchestration; the installed Keychain broker has not yet been exercised with an issued identity and independent live device |
| A paired frame record binds one admitted universal TD and capability instance to a pinned server SPKI fingerprint and opaque Keychain credential reference, survives restart, rejects conflicting re-admission and duplicate SPKI custody, and supplies UI targets without vendor branching | Frame Protocol/core | `Frameshift.FrameRegistryTest`, `Frameshift.LibraryTest`, `Frameshift.Outbox.EndpointTest`, `Frameshift.LocalAPITest`, `FrameDiscoveryTests`, `FrameServiceResolverTests`, and `HostCertificateTests`; installed browse and pairing acceptance required | Idempotent post-pairing admission and unique pin custody are implemented; database uniqueness rejects duplicate pins rather than silently reassigning custody. Mac Settings browses bounded introductions and resolves a selected local service; the shell creates and reuses a Keychain P-256 host identity. A local Bonjour resolution and Keychain persistence test pass. Installed end-to-end discovery/pairing, rotation, and explicit TD refresh remain open |
| A physical bootstrap record contains only a device ID, frame SPKI pin, and at least 16 secret bytes; the host checks the presented peer certificate before sending the secret and later matches the authenticated TD device ID | Pairing/core | `Frameshift.Pairing.BootstrapTest`, `Frameshift.Pairing.RequestTest`, `Frameshift.Pairing.WindowTest`, `Frameshift.Pairing.EndpointTest`, `Frameshift.Pairing.ClientTest`, `Frameshift.Pairing.AdmissionTest`, `Frameshift.Pairing.AdmissionLiveTest`, `Frameshift.Pairing.StoreTest`, `Frameshift.Pairing.HTTP1Test`, `Frameshift.Pairing.TLSServerTest`, `Frameshift.LocalIPC.ServerTest`, `Frameshift.SimulatorTest`, `PairingQRReaderTests`, `scripts/check keychain-pairing`, pairing schema fixtures | Bounded QR/request parsing, physical-window state, QR image capture and confirmation, pinned host client, fail-closed simulator custody, a live mutual-TLS pair-to-authenticated-TD exchange, and transient authenticated local pairing admission pass in software. Explicit recovery reads the authenticated TD without replaying the one-time secret on the frame network. A live probe pairs and recovers using a short lived Keychain P-256 identity through the actual broker, then removes it. Installed Mac-to-independent-frame acceptance remains open |
| Desired/current separation, verified storage, idempotence, still-only playlists, and power-loss recovery | Simulator | `Frameshift.SimulatorTest` | Implemented in software simulation |
| Profile suggestions are source qualified and never shorter than the hard dwell minimum; a frame-owned clock cycles cached stills through restart, long offline gaps, and refresh failure | Protocol/simulator | `Frameshift.DisplayTimingTest`, `Frameshift.SimulatorTest`, `Frameshift.ContainerReceiverTest`, `Frameshift.RenderPipelineTest`, and Swift shell tests across Paper, Photo, and Pixel fixtures | Capability admission, separate-process timing, authenticated outbox playlist-body delivery, and the menu's pinned-artwork command with pending/active custody are implemented in software; hardware RTC, optical preview comparison and whole-frame energy evidence remain open |
| Ordered active masters render in exact submitted order; resume requeues the saved canonical revision after pin changes/restart, refusing stale intent, newer delivery and changed capabilities; interval preferences roll back with failed queue writes | Core/renderer/outbox | `Frameshift.LocalAPITest`, `Frameshift.RenderPipelineTest`, `Frameshift.Outbox.EndpointTest`, `Frameshift.Playlist.PlanTest`, core `mix check` | The full core gate passes 269 tests/properties with 14 environment-gated exclusions. Joined Zig rendering and durable outbox fixtures cover millisecond precision, clamping, exact saved-body resume without a renderer, changed pins, removed protected masters, restart and injected rollback. Pin previews are bounded independently of search. Installed accessibility and physical clock/display acceptance retain separate evidence |
| Native ordered-set review retains per-frame drafts, exposes add/remove/order and precise interval controls, and resumes the saved revision independently of current pins | Swift shell/core IPC | `PlaylistEditingTests`, `ModelsTests`, `scripts/check macos`, `frameshift-ipc-probe` | Fifty-five Swift tests in twelve suites, shell checks, release packaging and the packaged IPC probe pass. Fixtures cover per-frame draft recovery, immutable in-flight copies, overflow/minimum/capacity refusal, saved defaults and stale/pending/profile refusal. The real packaged Swift/core exchange checks pin projections and the new command payloads. Optical preview comparison, installed visual/accessibility acceptance and physical timing remain open |
| Bounded local native previews verify immutable master bytes, selected frame/profile/capability identity, exact RGB digest and worker build; stale selection cannot replace current pixels and preview never queues artwork | Core/renderer/native IPC | `Frameshift.RenderPipelineTest`, `Frameshift.LocalIPC.ServerTest`, `ArtworkPreviewTests`, core `mix check`, `scripts/check macos`, `frameshift-ipc-probe` | The full core gate passes 272 tests/properties with 14 environment-gated exclusions; 59 Swift tests in thirteen suites and the packaged Swift/core preview probe pass. Real Zig fixtures cover crop, alpha, output bounds, unsupported/stale/missing refusal and unchanged recipe/artifact/outbox state. Native fixtures cover malformed byte/digest/scope refusal and selection races. Optical color, hardware profiles and installed visual/accessibility acceptance remain open |
| Title/user-label edits require the exact observed metadata revision and preserve immutable bytes, machine provenance and frame references; paginated removal recovery verifies retained bytes and atomically restores search/audit state | Library/native IPC | `Frameshift.Library.MetadataTest`, `Frameshift.LocalIPC.ServerTest`, `LibraryMetadataTests`, `mix coveralls`, `scripts/check macos`, `frameshift-ipc-probe` | 280 core tests/properties pass with 14 environment-gated exclusions; 65 Swift tests in fourteen suites, shell/package checks and the packaged metadata/search/removal/restore probe pass. Fixtures cover Unicode/count limits, stale observation refusal, transaction/audit/FTS rollback, protected removal, pagination, corrupt/missing bytes, interrupted moves/restart and native draft/read/save races. Static checks pass; a complete core gate attempt failed locked-dependency registry retrieval during Hex timeouts, recorded separately from test evidence. Installed visual/VoiceOver, automatic Vision/similarity adapters and retention policy remain open |
| Sleeping contact keeps only the newest manifest and converges after missed/failed contact | Core/simulator | `Frameshift.OutboxTest` | Implemented in software simulation |
| An independent Paper, Photo, or Pixel candidate receiver contacts the real host outbox over mutual TLS, checks exact artifact bytes, persists current across process restart, and leaves custody pending after transport, storage, display, or acknowledgement faults | Container receiver/core | `scripts/check container`, `Frameshift.ContainerReceiverTest` with three manufacturer-sized RGB24 proxies, wrong host pin, profile mismatch, wrong byte count, missed contact, corrupt transfer, storage full, display failure, Paper temperature refusal, interrupted process, stale ack, restart, and class-specific visible state with power off/on | Container software acceptance passes locally; panel packing, real controller, optical state, power, and physical persistence remain unvalidated |
| A push-only command records its desired artifact before network I/O, exposes an unknown outcome in the menu, blocks a new intent while confirmation is pending, and advances current/previous-known-good only after authoritative display confirmation | Core/library/shell | `Frameshift.DirectDeliveryTest`, `Frameshift.DirectSyncTest`, `Frameshift.RenderPipelineTest`, `ShellModelTests` | A read-only “Check frame” command uses the advertised state Form and confirms matching display without replay; the broker is wired but pairing and independent-frame acceptance remain open |
| A pull request with a verified peer DER certificate resolves exactly one paired SPKI pin, parses one bounded HTTP/1.1 exchange, reads only that frame's current manifest and exact artifact, and clears the outbox only with a strict current-revision acknowledgement | Core/outbox | `Frameshift.Outbox.HTTP1Test`, `Frameshift.Outbox.EndpointTest`, `Frameshift.Outbox.TLSServerTest`, `Frameshift.Outbox.ServiceTest`, `Frameshift.Pairing.AdmissionLiveTest`, `scripts/check keychain-pairing`, and packaged IPC probe | Framing, identity, HTTP semantics, automatic listener custody for paired pull frames, a real mutual-TLS exchange, and Keychain broker signing in the host server role pass in software. The Mac advertises the active listener port through Bonjour; installed advertisement and an independent physical frame remain unverified |
| Fixed-point crop, nearest/bilinear resize, alpha composition, caller-supplied palette, and deterministic dither | Zig renderer | Zig golden, boundary, malformed-input, and parser-fuzz tests | Implemented for generic RGB24 and indexed still profiles |
| Advertised capability structure—not vendor/model naming—selects a supported artifact profile and compiles a deterministic centered composition | Core/renderer | `Frameshift.RenderProfileTest`, `Frameshift.RenderPipelineTest` | Implemented for tightly packed uncompressed sRGB RGB24; exact indexed wire-code packing and measured Paper/Photo/Pixel profiles remain open |
| Each accepted render and delivery intent pins an asset-specific work digest and a reusable admitted renderer/profile/transfer qualification through restart, switching, and rollback | Core/renderer/delivery | `Frameshift.Qualification.IdentityTest`, `Frameshift.Qualification.ProfileTest`, `Frameshift.Qualification.StoreTest`, `Frameshift.RenderPipelineTest`, `Frameshift.DirectDeliveryTest`, and `Frameshift.RendererTest` cover canonical identity, profile changes, durable admission, accepted work/result, pull and push intent custody, restart, active switch, atomic cohort promotion, preservation of accepted work across that promotion, legacy outbox restart, duplicate pull acknowledgement, last-good retention, exact build refusal, qualified render/cache replay, alternate profile selection, and a qualified push on a dual-mode frame. Repeated legacy and qualified timed-out pushes keep one intent and report distinct unknown attempts; producer fixtures remain required | The product queue uses the active admitted profile and transfer mode when present and retains qualified custody through confirmation. New unqualified delivery is refused after activation; existing legacy pull and exact pending push can finish or replay; the renderer owner now launches a private copy whose digest and cleanup are verified by `Frameshift.RendererTest`. Mandatory new-work qualification, production admission evidence, and physical qualification remain open |
| The packaged macOS menu-bar agent keeps its dropdown available after dismissal, offers an accessible Quit control, scrolls artwork, accepts multiline instructions and preserves one selected-frame/artwork/draft/focus/delivery envelope across compact, focused and Settings modes | Swift shell/package | `scripts/check macos` verifies agent bundle metadata, app launch, a newline-bearing packaged IPC round trip, and Swift shell model tests; required native fixtures must cover 360- and 420-point popovers, admitted minimum and expanded windows, mode transitions, VoiceOver, Full Keyboard Access, increased text size, Increase Contrast and Reduce Transparency | The redundant Dock window was removed, the agent and bundled core remain running, and the menu icon appears without a Dock entry. Native multiline editing and saved-newline readback passed in the earlier window build; live dropdown reopen passed locally on 2026-09-24. Cross-mode state/focus, full native layout matrix, multiline AX acceptance and signed distribution remain open |
| Native Settings uses full-width grouped sections, wraps explanatory text, keeps frame actions below their identity, and shares flat action buttons with the dropdown | Swift shell | `scripts/check macos`; native preview compiled from the exact Settings view and shared button source, with live Bonjour discovery; window resizing and scrolling inspected on 2026-09-24 | The macOS gate passed 39 tests, shell checks, packaging, and the IPC probe. Native preview inspection at 580-point and 520-point widths showed readable sections, matching Pair/Recover buttons, wrapped help, and Startup reachable by scrolling. The UI automation could not attach to the closed menu-only app after relaunch, so this visual evidence is from the temporary preview; complete installed Settings and VoiceOver acceptance remain open |
| Native failure cannot terminate the BEAM; timeout or malformed response restarts a clean worker owner | Core/renderer | `Frameshift.RendererTest` | Implemented with an external Zig port |
| A native focused Library shares exact-master selection, search and unsaved instruction with the popover; filtering retains selection, confirmed removal clears it, and a save acknowledgement cannot discard newer edits | Swift shell | `ShellModelTests`, `scripts/check macos` | Forty-four Swift tests, shell checks, release packaging and the packaged IPC probe pass. The Library scene, Command-L and native actions compile against the pinned SDK. UI automation could not attach to the packaged agent; visual layout, focus return, VoiceOver and installed macOS 14 acceptance remain open |
| One supported still image is bounded, orientation-normalized, converted to sRGB straight-alpha RGBA8 with Apple Image I/O, handed off in a user-only file, digest-verified, and persisted with its exact original bytes | Swift shell/core | `frameshift-shell-checks`, `frameshift-ipc-probe`, `Frameshift.LocalAPITest`, `Frameshift.MasterPackageTest`, `scripts/check-packaged-app` | Implemented for the installed import path; file bookmarks/sandbox distribution and a larger format/orientation/color fixture corpus remain open |
| A durable normalized master is read back with object and package verification, rendered for a paired capability/profile, cached, queued to the sleeping outbox or dispatched to a push-only frame, and converges in-process | Core/renderer/simulator | `Frameshift.LibraryTest`, `Frameshift.RenderProfileTest`, `Frameshift.RenderPipelineTest`, `Frameshift.DirectDeliveryTest` | Implemented through the product queue command for compatible RGB24 targets; pairing and an installed Keychain-to-frame TLS acceptance test remain open |
| One explicitly selected generation provider preflights, times out, caches exact repeats, and persists no provider context | Core generation | `Frameshift.GenerationTest` | Implemented with fixture providers only |
| Production core configuration is relocatable, boots with an explicit renderer path, and serves the versioned local protocol | Elixir core/Swift shell | `scripts/check-core-release`, `frameshift-ipc-probe` | Implemented with a real Swift-to-release round trip |
| A fresh 256-bit challenge crosses a one-use user-only bootstrap file, authenticates every bounded local request with constant-time comparison, and binds each mutation ID to a durable canonical command hash and terminal outcome | Swift shell/core | `Frameshift.LocalIPC.TokenTest`, `Frameshift.LocalIPC.ServerTest`, `Frameshift.LibraryTest`, `frameshift-shell-checks`, `frameshift-ipc-probe`, `scripts/check-core-release`, `scripts/check-packaged-app` | Implemented for the protected-bootstrap and durable at-most-once replay profile; an interrupted claim returns an explicit unknown outcome and the shell refreshes authoritative state instead of repeating the mutation |
| Menu extra remains a snapshot/command client, launches the bundled OTP core and Zig worker, uses authoritative durable library/target state, and works with no generation provider | Swift shell/core | `Frameshift.LocalIPC.ServerTest`, `Frameshift.LocalAPITest`, `Frameshift.RenderPipelineTest`, `Frameshift.Transport.KeychainBrokerTest`, `frameshift-shell-checks`, `frameshift-ipc-probe`, `scripts/check-packaged-app` | The broker is launched with the bundled core and Settings has a physical-QR pairing flow; complete installed Keychain-to-frame TLS verification, service registration, and signed distribution remain open |
| Frameshift-owned application, firmware, scripts, tests, and examples contain no Python; required upstream build tools are pinned and isolated | Repository policy | `scripts/check policy`, CI workflow, plus firmware/system toolchain provenance gate when selected | Current source-file ban is enforced; no upstream exception is in use or qualified |
| Elixir modules and test modules follow the required module documentation layout; public API docs and types build | Core/tooling | `scripts/check-elixir-docs`, Doctor, ExDoc warnings-as-errors, Dialyzer | Enforced with 100% module and type coverage in the current Doctor report; function docs cover 79.2% of the inspected surface |
| Generated protocol and renderer framing cases, Swift package behavior, and safety-optimized Zig code are checked | Core/shell/renderer | StreamData property tests, `swift test`, Zig Debug and ReleaseSafe tests | Added to the implemented software gate; real transport tests require permitted local sockets |

## Open evidence gates

The following remain open and must not be inferred from the automated rows:

- exact Paper, Photo, or Pixel hardware selection and measured render profiles;
- physical refresh completion, interrupted electrical update, power, thermal,
  depth, mounting, and optical measurements;
- pairing, mutual TLS, certificate rotation, authorization, and independent
  security review;
- sandbox-safe file bookmarks and UI acceptance of imported security-scoped
  references across app restarts;
- commissioned Keychain identities and live reference HTTPS TLS, SSE lifecycle, ExposedThing
  routing, and live interoperability with independent devices;
- real AI provider preflight, provenance, cost/privacy disclosure, cancellation,
  and local-only network isolation;
- VoiceOver/manual accessibility acceptance, Service Management background
  lifecycle, Developer ID signing, hardened runtime, and notarization;
- public guide deployment, broader shared-kernel capability coverage,
  cross-browser acceptance, release manifests, direct/Cask/
  Sparkle paths, Ubuntu packages, and Nerves Pi 5 appliance evidence;
- power-loss and physical storage-fault measurements on each supported host;
- project license selection and third-party release notices.

## End-to-end acceptance path

The installed product is complete only when the same shipped app can execute
this entire path without simulator-only substitutes or manually seeded pairing
records:

1. Discover a frame, verify its bounded Wotex Thing Description and advertised
   Forms, commission it in physical pair mode, and persist its identity and
   credential in Keychain. Bounded discovery, QR confirmation, Keychain host
   identity creation, transient pairing, authenticated TD retrieval, and
   durable record admission are coded. Their combined installed-device
   acceptance path is not yet evidenced.
2. Import or generate an image, retain exact source bytes and a canonical
   master, select an advertised artifact profile, render it, and verify the
   content address. Import, storage, RGB24 rendering, and cache verification
   are implemented; real generation providers and indexed-profile wire output
   are not.
3. For an awake push-capable frame, resolve its Keychain credential at the
   transport boundary and run direct synchronization using its selected Forms.
   The queue command now renders and dispatches push-only targets through the
   reference synchronizer when a credential resolver is configured, recording
   a durable intent before network I/O. The menu process now provides a
   Keychain-backed signing socket and the core configures its resolver at
   launch. No commissioned identity or live installed TLS exchange has been
   verified, so shipped delivery to a physical push-only frame is unproven.
   An uncertain outcome remains visible as pending and blocks a new intent.
   “Check frame” reads its advertised state Form and commits only a matching
   displayed asset; installed credentials are still required to run it.
4. For a sleeping pull-capable frame, expose the latest per-frame outbox over
   an authenticated Host Outbox Thing, serve exact rendered bytes, accept the
   frame's verified acknowledgement, and update authoritative current state.
   Durable convergence and frame-scoped HTTP semantics are tested in-process.
   The supervised mutual-TLS listener now follows paired pull custody, and a
   real-socket test uses the Mac Keychain broker for host signing. The installed
   app publishes its active port through Bonjour. An installed independent
   receiver discovery/contact run remains unevidenced.
5. Survive restarts, credential rotation, network loss, interrupted refresh,
   and app upgrades without losing the previous known-good display. Software
   persistence and simulator fault cases cover part of this; physical fault
   injection, service lifecycle, signed distribution, and independent security
   review are still required.

These steps are acceptance gates for one final product, not optional product
tiers. Passing the tooling gate below does not close them.

Run the default software gate from the repository root:

```sh
make check
```

The Docker-backed receiver and Linux peer-credential lanes run separately in
CI. Locally, run `./scripts/check container` and `./scripts/check linux-ipc`
with a Docker-compatible daemon. Neither lane substitutes for physical frame
or installed Linux service evidence.

## Formal verification target

The strongest candidate for model checking is the frame delivery transition
system: a command can be claimed, bytes installed, desired state committed,
display interrupted, an acknowledgement delayed, and contact retried in
different orders. A model should assert that `currentAsset` advances only after
display confirmation, protected known-good bytes are never collected, outbox
revisions do not retreat, and replay cannot apply a mutation twice. These are
state and concurrency properties shared by the Elixir host and future Zig
frame agent; the verification language should describe the protocol rather
than mirror either implementation language.

[ExMaude](https://github.com/futhr/ex_maude) is a plausible Elixir-facing
Maude interface for state-space search. It requires a separate Maude binary
and a maintained second specification. The current StreamData properties and
simulator fault cases exercise concrete code, but they do not exhaustively
explore interleavings. A Maude model becomes valuable when both sides of the
delivery and acknowledgement state machine exist and can be checked against
the same transition traces. It is not a substitute for physical panel,
power-loss, or cryptographic interoperability evidence.
