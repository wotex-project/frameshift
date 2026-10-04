# Conjunct integration and Frameshift product profile

**Status:** adopted direction; producer source mapping updated 2026-10-04,
Frameshift integration and joined conformance open.
**Owner:** Frameshift product integration; generic producer semantics belong in
Conjunct. The [adoption record](../research/conjunct-adoption.md) maps inspected
revisions and existing implementation.

## Product and engine boundary

**CI-01 — Product consumer.** Frameshift is the first modular reference product
and integration proof of concept for Conjunct. Its bundle supplies Paper, Photo
and Pixel profiles, rules, procedures, artwork behavior, presentation and product
evidence. The native application, Frame Protocol, renderer and firmware remain
Frameshift software. The proof of concept demonstrates these boundaries with
executable evidence; it does not imply a completed engine, released application
or physically qualified frame.

Conjunct owns generic physical composition, evidence, geometry, procedure and
packaging semantics. Refpath owns generic capability, application-generation,
UI-graph, work, effect and recovery contracts. Rivure owns financial operations;
DocShell owns versioned explanatory artifacts; Wotex owns device-interaction
contracts. Frameshift must not introduce another owner for those responsibilities.
The inspected Conjunct cohort supplies a Rust kernel and public Elixir
port/browser WASM/data/guide source exports. They are unreleased and not
installed or qualified here. Map the actual discovery/protocol/ABI before
adoption. A missing generic export needs a producer requirement and reproducing
fixture; it cannot be replaced by a second local generic engine.

Conjunct's core contract owns product/profile validation and normalization,
explicit-selection composition, canonical physical identity, comparison,
catalog/parts projection, generic predicates and purpose-bound check aggregation.
Its instruction profiles own generic geometry/procedure planning, semantic
scene binding and portable text/print/offline output. Frameshift supplies exact
frame profiles, mandatory frame rules, approved steps and observations, source
references and presentation content. The Frameshift host and browser own their
UI, authorized storage and file I/O; they consume Conjunct results rather than
recompute physical or procedure meaning. Refpath is needed for an admitted
operator/application generation, not for independent composition or instructions.

The [required library contracts](producer-contracts.md) define each producer's
delivery, Frameshift inputs, failure behavior and joined tests. Specified but
unfinished library work is an implementation obligation. Contract readiness and
integration readiness are separate; producer and consumer development may
proceed together using explicit fixtures and simulators.

The independent composition view and instructions must work without an account,
inference, transactions or a central manufacturer catalog. A printable parts
and shopping list is a projection of the same composition. Optional service
execution is retained in [BC-01–BC-10](build-commerce.md) and currently on hold.
It does not gate the engine-consumer proof or native application work.

## Product artifacts and identities

**CI-02 — Distinct immutable inputs.** Keep these objects separate:

| Object | Owner and identity meaning |
| --- | --- |
| Product bundle | Frameshift profile vocabulary, exact rules, procedures, evidence references and permitted presentation assets |
| Physical composition | Exact chosen part revisions, quantities, connections, placements, requirements and physical semantics |
| Geometry artifacts | Source geometry, analysis representation and delivery mesh, each with source and conversion identity |
| Procedure and packaging plans | Exact composition, approved operations, parameters, protection and inspection requirements |
| Application generation | Refpath identity binding admitted product, operator, capabilities, UI and execution profile |
| Assessment and admission | Purpose, authority, scope, evidence, effective period and current revocation, external to physical identity |
| Execution and as-built records | Actual serial/lot, operations, observations, deviations and acceptance evidence linked to a plan |
| Offer and commitment | Optional externally accepted terms, counterparty, amounts and authority; no mutation of a composition |

A UI change cannot rewrite physical identity. A new source assessment may block
future use without deleting history. A changed part or physical rule creates a
successor and invalidates affected derived plans. Accepted work, previous
generation references and unresolved effects remain addressable across upgrades.

Product bundles contain no credentials, customer artwork, private operator data,
bank destinations or live market state. Signed publisher bytes, source truth,
physical compatibility and permission to execute are distinct evidence.

## Existing format and migration

**CI-03 — Preserve v1 replay.** The normative
[physical contract](physical-build-contract.md) and
[artifact contract](build-artifacts.md) retain the current Frameshift v1 bytes,
integer bounds, identifiers, validation and hash domains during extraction:

| Existing document | SHA-256 payload domain |
| --- | --- |
| Component profile | `frameshift.profile.v1` followed by LF |
| Assembly | `frameshift.build.v1` followed by LF |
| Signal mapping | `frameshift.signal-mapping.v1` followed by LF |
| Artifact layout | `frameshift.artifact-layout.v1` followed by LF |
| Compilation context | `frameshift.compilation.v1` followed by LF |

These formats use bounded ASCII JSON, a specified field order and a final LF.
They do not claim RFC 8785 conformance. The Conjunct 0.2 specification selects
`cj/wire/1`, bounded UTF-8/RFC 8785, a separate artifact hash domain and exact
rational SI quantities. Its producer owns the schema/encoder implementation.
The two formats cannot share a version or identity merely because their JSON
looks similar. PC-02 defines the required migration and conformance boundary.

Before adopting a Conjunct encoder, record the exact producer schema, required
profile, compiler semantics, numeric/Unicode rules, byte/depth/collection limits
and hash domain. Recompute imported identities through standard cryptography.
An explicit migration produces a successor identity and a mapping to the
retained original. Record unsupported semantics or information loss; do not
drop fields or manufacture a favorable interpretation to make conversion pass.

The current assembly `Instance` is a selected occurrence with placement, not a
received serial/lot. A future as-built instance must retain that distinction.
Current fact `Missing`, `Conflicting` and numeric zero cannot be converted into
Conjunct's not-applicable state without a profile rule and evidence. Annotation
extensions cannot disable required checks. Mutable assessment, live price,
stock, clock, issuer signature and current eligibility stay outside physical
identity. Hash first, then attach detached evidence and admission.

Before switch-over, old exported bytes must still replay and new outputs must
have deterministic BEAM/JavaScript parity. Storage migration, rollback and
supported-reader lifetimes must be specified against the actual persisted
records. No automatic reinterpretation of existing catalog rows is allowed.

The current Conjunct contract fixes quantity kinds, rational arithmetic limits,
occurrence semantics and purpose-bound CheckReports under CJ2-08–CJ2-11.
Frame micrometres/millivolts and coordinate conventions need exact conversion;
its broader limits do not silently raise the existing Frameshift v1 ceilings.
The producer's readable/writable/executable profile matrix accompanies the
consumer migration. Required unknowns cannot become not-applicable or accepted.

## Extraction ownership

**CI-04 — Extract only demonstrated shared semantics.** `packages/build-spec/`
remains the working implementation boundary until the producer replacement is
qualified. The following is an extraction map, not a claim of installed packages:

This retention permits exact v1 replay, regression and migration, including the
bounded non-admitting planning preview. It does not establish a second primary
authoring, comparison, CheckReport, parts-list or instruction implementation in
Frameshift. A new consumer of those generic operations uses a qualified
Conjunct export; until one exists, its claimed profile remains unavailable.
Frame-specific rules and fixtures may continue here without changing the owner
of generic composition or presentation semantics.

| Existing material | Intended treatment |
| --- | --- |
| Exact physical arithmetic in `frameshift_physical`, graphs, interval/rectangle algorithms and bounded evidence references | Candidates for Conjunct core with product-independent inputs and retained independent oracles |
| Profile/assembly codecs, fact registry, context and source-resolution types | Split generic contracts from the current frame vocabulary; preserve v1 compatibility through an explicit adapter |
| Power, thermal and mounting calculations | Reusable constraint profiles only where their assumptions and mandatory obligations are explicit; unsupported physics stays unknown |
| Frame enclosure/aperture rules, display ownership, routed signal/driver scope, raster layouts, dwell and retained-artifact storage | Frameshift profile rules and fixtures; generic traversal/geometry may be extracted underneath |
| Native capability/profile selection and delivery decisions in `frameshift_decisions` | Frameshift product decisions; independent of a Conjunct host |
| Source/profile Ash persistence, audit, HTTP and metrics in `apps/build-platform` | Retain the working host; adapt through qualified producer commands without private-table access or an immediate application move |
| Manufacturer facts and source rights in `data/physical` | Frameshift-owned evidence and imports; generic test corpora use synthetic or explicitly permitted data |
| Maude models | Generic predicates upstream; frame assumptions and physical qualification here; ExMaude completion/session APIs remain producer-owned |

The generic core cannot import Frame/Paper/Photo/Pixel, artwork rendering or
device-control behavior. Conversely, extraction must not make frame obligations
optional: a passive mechanical profile may omit electrical obligations, while a
Frameshift profile still requires every applicable power, signal, storage and
display check. Empty caller-supplied requirements cannot bypass that profile.

Each extraction slice needs one producer export, a consumer adapter, equivalent
outputs for supported old cases, and refusal for unsupported mappings. Remove
duplicate authority when switching; do not maintain two independently evolving
implementations. No empty package or directory is required to resemble a target
tree. Update `workspace.json`, package locks, scripts and release tests with the
slice that actually changes dependencies.

## Evidence, geometry and procedures

**CI-05 — Evidence closure.** Adopt CJ.03's distinction between source revision,
extracted proposal, normalized claim, derived fact, measured observation,
assessment, admission and revocation. Preserve Frameshift's existing source,
received-part, test and lot evidence scales. Geometry grades G0–G5 describe
obtained geometry only and cannot promote product qualification.

Every imported claim retains exact source/part revision, locator, original
units, conversion, uncertainty and review method. Record permitted use and
redistribution independently from technical availability. Signed federated packs
use trusted issuer roots, bounded dependency closure, archive/path admission,
rollback defenses and current revocation. Restricted assets remain restricted
even when their digest or public product page is known. Generic pack-security
and ingestion mechanisms belong to their producers; Frameshift supplies scoped
source adapters and product evidence.

CJ3-07–CJ3-09 separates historical replay from current-use admission. Offline
guides show exact revisions and last status check; progress remains unadmitted
until reconciliation. Missing freshness/expiry or unreliable time cannot grant
current permission. A known stop notice stays visible. Rights-required deletion
leaves a permitted tombstone/replay-unavailable result rather than a promise to
retain restricted bytes forever. Reconnection never automatically dispatches
queued commitments or device changes.

**CI-06 — Complete geometry.** Installed thickness includes the panel, board,
power, connector protrusion, FPC/cable bend, backing, mounting and tool/service
access. No universal diagonal limit is product policy. The current renderer,
codec and algorithm ceilings remain declared versioned software capabilities;
larger unsupported inputs must refuse or remain visibly limited.

Keep source drawing/CAD, collision and clearance representations, and a browser
mesh separate. Assets retain units, coordinates, handedness, tolerances,
conversion tool/options, loss and stable part/feature identifiers. Select input
formats from actual permitted samples and qualify one adapter at a time. Neither
the list of formats in CJ.04 nor a GLB preview is engineering support evidence.

CJ4-08 now selects right-handed metre/+Y-up/+Z-forward transforms and a separate
STEP/OCCT qualification package. Synthetic/manual geometry supports the first
instruction slice; real CAD support needs the exact tool/subset/loss fixtures.

**CI-07 — Procedure meaning.** Frame assembly, commissioning, inspection,
packaging, disassembly and repair are structured plans with exact composition
and procedure identities. Steps identify prerequisites, parts, tools, skill,
required access, sourced parameters, stop conditions and observations. Missing
torque, bend radius, power isolation or other required facts prevent the affected
step's acceptance. Reversing an animation does not qualify disassembly.

Engineering, manufacturing, service and packaging BOM projections retain
transformation lineage and explicit consumables/process aids. A plan is distinct
from actual work; completion requires its named observation, test or confirmation.
Frameshift supplies product procedures, Conjunct their generic semantics, and
DocShell explanatory content. No duplicate prose-only procedure authority.

The Conjunct viewer binds stable semantic part/feature/step IDs to scene assets.
It must offer usable keyboard/text, reduced-motion, low-graphics, print and
offline output. A stale feature map refuses the affected projection. The native
Zig artwork renderer remains a separate system. A scene click or composition URL
cannot authorize a device action or provider mutation.

CJ4-09–CJ4-10 defines evidence-bearing procedure transitions, separate rework,
concurrent/offline observation conflicts and equivalent semantic content across
accessible/localized presentations. Conjunct supplies these generic contracts;
Frameshift supplies approved frame operations and required observations.

## Adaptive host and producer admission

**CI-08 — Explicit producer cohort.** Before using a producer capability, record
its exact source/release, supported exports, lock/toolchain, schema ownership,
supervisor owner, consumer fixture and result. A specification identifier is not
an API. Private/unreleased packages remain explicit distribution gaps; a local
sibling checkout is inspection evidence, not an installed dependency.

PC-03 and PC-04 identify Refpath P1 durable scoped admission and ExMaude P2
typed completion/session evidence. Both producers now have relevant public
exports; atomic review-through-commit, full formal coverage and this consumer's
joined qualification remain open. Missing required evidence gates the dependent
operator/formal claim, without preventing deterministic core/instruction work.

Refpath owns generic product/operator solution binding, approved UI graphs,
generation compilation/admission, attempts and effects. Frameshift binds typed
product commands and registered viewer/inspector/procedure components. Unknown
action IDs, stale generations and out-of-scope actor/operator bindings refuse.
No model may introduce executable code, waive a rule or enlarge authority.

Two differently scoped operator applications must use the same reviewed code
and product data without a fork. Successor/rollback tests cover accepted
compositions, pending work, current revocation, concurrent admission and VM
restart. Disabled new external work must preserve authorized reconciliation and
care. Wotex device admission remains separately authenticated. Rivure is only
required by an enabled financial profile; DocShell and viewer availability are
qualified for the exact instruction profile. No unavailable adaptive or external
profile may disable the supported deterministic/native paths.

## Acceptance and dependency gates

| Gate | Pass condition and owner |
| --- | --- |
| v1 preservation | Existing v1 documents, identities and recorded tests replay unchanged; successor requirements and implementation evidence remain distinct |
| Encoder/profile transition | Conjunct producer schema/export exists; both runtimes agree; old bytes replay; migration changes identity where semantics change and refuses loss |
| First frame composition | One exact frame fixture compiles with explained valid/invalid/unknown cases and produces a bound procedure plus print/offline output; synthetic complete fixtures and sourced candidates with unknowns retain distinct evidence labels |
| Generic vocabulary | Conjunct's passive enclosure/fastener/packaging fixture and connected sensor fixture use the same core without frame imports or mandatory networking |
| Viewer and evidence | Source-to-feature-to-step trace survives conversion, revoked/stale mappings refuse, required text remains available without WebGL |
| Adaptive host | Actual Refpath exports pass two-operator, scope, restart, successor and unknown-effect tests; missing capabilities are explicit unavailable results |
| Operations | Existing bounded metrics remain reproducible; exact GreptimeDB ingestion and structured log/trace paths pass loss, redaction and outage checks before operated-host claims |
| Optional external services | Parked; BC-01–BC-10 and producer conformance become required for any later enabled service profile, after independent instructions/list and operational gates |

No completed gate implies an untested one. Frame hardware measurements, licensed
assets, release permissions and production credentials retain their own evidence
owners. Engine conformance does not establish supplier truth or physical safety.

## Source cohort

The current source mapping uses Conjunct at
`f6609c5e4c2188626f5e1f345446fec04e78d6c9`, inspected on 2026-10-04.
The [source record](../research/conjunct-adoption.md#exact-producer-source-cohort)
identifies the relevant exports, trusted registry and remaining qualification
limits. Exact discovery ContractRef/schema digests and staged artifacts are
frozen by [S1](implementation-plan.md#composition-specification-delivery).
Source exports and pure tests do not constitute an installed package or stable
semantic conformance.
Generic schema/adapter work belongs upstream; Frameshift defines its profile,
migration and consumer proof here.
