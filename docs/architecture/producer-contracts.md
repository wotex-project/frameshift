# Required library contracts

**Status:** normative consumer expectations, source mapping updated 2026-10-04; implementation and
joined conformance are tracked separately in the [verification map](verification.md).
**Owner:** Frameshift integration. Generic implementation belongs to the named
producer. This contract complements [CI-01–CI-08](conjunct-integration.md).

Conjunct and the other owned libraries are being developed alongside their
consumers. A required export may be specified before it is implemented. The
requirement must identify its inputs, outputs, authority, refusal/recovery and
consumer evidence. A missing implementation does not invalidate that design or
stop independent work. It prevents a claim that the affected integration passed.

## Delivery and readiness rules

**PC-01 — One contract owner.** Use these states separately for each boundary:

| State | Meaning | Required next artifact |
| --- | --- | --- |
| Contract gap | Observable behavior or ownership is undecided | Producer requirement and agreed consumer fixture |
| Implementation gap | Required behavior is specified but not supplied | Producer implementation and public export |
| Integration gap | Export exists but the consumer mapping is absent | Adapter, explicit errors and exact input/output mapping |
| Qualification gap | Implementation/mapping exists without sufficient evidence | Producer and joined consumer results at exact revisions |

Do not report an unimplemented specified operation as an architectural blocker.
Do not label an operation implemented from a specification or simulator. Before
switching an existing boundary, record the producer commit/package, contract and
profile revision, public export, lock/toolchain, schemas/diagnostics, consumer
fixture revision, and actual results. Unknown export status is unassessed until
source inspection; it is not proof that the producer lacks the capability.

Logical operations below are requirements, not new module/function names or a
universal RPC envelope. Resolve them to the owning library's public API. Extend
that owner when necessary; do not create a parallel registry, encoder, scheduler,
documentation model, effect dispatcher or financial ledger in Frameshift.

The current mapping uses the exact source cohort in the
[consolidated research](../research/conjunct-adoption.md#exact-producer-source-cohort),
including CJ.09, domain/geometry annexes and the trusted discovery registry.
The Rust kernel, Elixir port, browser WASM/data bindings and guide have public
source exports; none is installed or qualified by this consumer yet.
Unreleased semantic descriptor, package and executable identities are distinct.
P1/P2 contracts now require qualification of existing producer APIs and their
remaining extensions, rather than implementation from scratch.

## Required deliveries

**PC-02 — Conjunct core, evidence and instructions.** Conjunct supplies the
generic contracts in CJ1-12, CJ2-01–CJ2-11, CJ3-07–CJ3-09 and CJ4-01–CJ4-10.
The core producer, not the Frameshift workbench, implements generic profile
validation, normalization, composition, comparison, canonical identity,
catalog/parts projection, predicates and purpose-bound CheckReports. Conjunct's
instruction profiles implement generic geometry/procedure planning and
portable viewer, text, print and offline semantics. Frameshift supplies its
profile constraints, approved procedures, evidence and UI/storage adapters.
Local save/reload is a host I/O choice, not a separate semantic implementation.

| Boundary | Frameshift supplies | Producer must return or enforce | Consumer acceptance |
| --- | --- | --- | --- |
| Pack/profile validation and normalization | Exact frame profile, permitted source claims, explicit requirements and pinned limits | Supported-profile result, bounded canonical values and typed structural refusal; no live lookup | Invalid keys/units/closure/overflow refuse identically on BEAM and JS; local files cannot raise limits |
| Composition and comparison | Exact occurrences, interfaces, placements, hard rules and preferences | Immutable composition, purpose-bound CheckReport, stable diagnostics and semantic successor diff | Reordered inputs preserve canonical identity; changed physical semantics change identity; changed purpose cannot reuse an unrelated report |
| Evidence and current-use admission | Source/claim records, product assessments, actor/action/scope, status checkpoint and explicit time | Forward/reverse evidence closure and separate eligibility result under CJ3-08 | Unknown required evidence cannot pass; withdrawal reaches affected plans; pure historical replay never claims live permission |
| Geometry and procedure planning | Frame features, approved operations, parameters, tools/skills, sourced or clearly synthetic geometry | Bound geometry/scene/procedure artifacts, feature/loss map, DAG and typed unavailable/unknown results | Stale feature maps, missing required parameters and impossible order refuse; parts/steps/warnings agree in viewer, text, print and offline output |
| Procedure observations | Exact plan/step/instance, actor authority, expected revision and required observation | Separate observed state, deduped events and explicit conflict/rework disposition | Duplicate completion, shared-tool concurrency and stale/offline observations cannot erase or invent work |

The core delivers `cj/wire/1` and `cj/core/0.2` semantics: closed versioned
schemas, exact string rationals, canonical units/kinds, occurrence graphs,
nine mandatory non-geometric predicates, bounded arithmetic and deterministic
diagnostics. A CheckReport binds requirements, composition, rules/compiler and
claim/assessment closure; admission binds that report and current authority.
Translated explanations do not change canonical check identity. Frameshift
retains all mandatory display/power/signal/raster/storage obligations.

Frameshift's five v1 identity domains remain readable and replayable under
CI-03. Conjunct's artifact domain, rational SI values and occurrence vocabulary
require an explicit successor mapping. Convert existing integer units exactly;
refuse unrepresentable/lost required semantics. A migration records both IDs,
semantic differences and readable/writable/executable version support. No
historical catalog row is silently rehashed or promoted to current eligibility.

The first instruction profile may use synthetic/manual geometry. The broader
`cj/cad-step/0.2` requirement is not an advertised implemented capability.
The inspected adapter selects `cj/step-planar-assembly/0.1`: Linux/arm64,
OCCT 7.9.3 and single-file ASCII AP214 planar B-rep. It excludes AP242,
curves, PMI, external documents, manufacturer geometry and engineering accuracy;
activation/distribution remain unqualified. Record the exact
[cohort and exclusions](../research/conjunct-adoption.md#procedures-geometry-and-accessible-output).
Any claimed STEP conversion to glTF 2.0/GLB needs exact tool/subset, units,
transforms, loss and feature evidence.
Conjunct's right-handed metre/+Y-up/+Z-forward transform convention is an
explicit conversion from the existing frame-coordinate profile. Other CAD
formats remain unavailable until their own adapter qualifies. Manufacturer CAD
permission is not a prerequisite for synthetic compiler/viewer fixtures.

**PC-03 — Refpath generation, work and effects.** Conjunct owns the generic
physical-domain adapter; Frameshift supplies its product bundle, typed commands,
registered components and operator bindings. Refpath retains generation identity,
capability/UI admission, attempts, effects and recovery authority.

Required public operations are candidate compile/verify, scoped admit, read
current admission, resolve historical admission, declare successor/rollback
disposition, reconcile interrupted admission, and execute/reconcile admitted
capabilities. Existing DF.35/DF.36/SY.33/RT.35/RT.61–RT.62/RT.68/RT.77 owners
are reused. The audited export map is in the Conjunct source record; exact
consumer binding is frozen with each implementation slice.

P1/CJ6-07–CJ6-08 requires a durable admission head per operator/project scope,
compare-and-swap predecessor, monotonic fence and idempotent receipt. VM restart
restores the head and verified artifact closure before commands resume. Missing
state makes that scope unavailable. All workers and UI commands use the same
authority. Rollback admits retained bytes under a new fence. It does not lower
the fence, mint new IDs for pending effects or rewrite accepted compositions.

Test two operators from the same source, concurrent successors, stale clients,
lost acknowledgment, complete VM restart, missing assets and an unknown effect
across upgrade/rollback. Simulators support development; the joined gate uses
the producer's real durable store. The installed Refpath already exports
`ApplicationAdmissions.admit/2`, `current/2`, `restoration/2`, `pin/2` and
`source/3`, with scoped HotReload wrappers. Map these existing interfaces;
do not create another admission head. Atomic current review-through-commit
remains a producer qualification gap: the prospective
`Artifacts.with_review_projections/3` snapshot is not the selected cohort and
is absent from the installed pin. Require withdrawal/commit race fixtures
against a qualified producer transaction before enabling that profile.

**PC-04 — ExMaude solver evidence.** ExMaude supplies P2/CJ8-04 through its
existing search/pool/backend owner. Inputs are reviewed model/query identities,
bounded encoded data and explicit resource/search limits. Outputs bind parser,
executable/backend, session/worker generation, observed counts, raw output and
termination reason to that exact search.

Distinguish exhausted finite search, completed declared bound, solution/depth
cutoff, timeout, truncation, cancellation, worker loss and parser/protocol error.
Loading, searching and trace retrieval use one leased session or a qualified
replay contract. Reset/replacement invalidates old trace handles. A list of zero
solutions cannot prove completion. Preserve the existing API or version its
replacement with migration tests.

Conjunct supplies generic physical encodings/predicates and compiler witness
replay. Frameshift supplies frame assumptions and product regression cases.
Tests cover two concurrent searches, stale trace access, each terminal outcome
and a deliberately broken rule whose witness reproduces in the real compiler.
P2 gates formal-evidence claims; it does not prevent deterministic compiler or
viewer development. Required formal predicates still gate the profile that
claims their evidence.

The inspected producer supplies `ExMaude.Verification.SearchRun.run/3` with
typed termination and bound session/output/trace evidence. Conjunct's selected
formal join covers screw reach and sensor capacity, not the full frame profile.
Typed cancellation receipts, state-count limits and complete predicate/trace
coverage remain required work. Qualify the exact selected cohort and distinguish
producer-reported tests from Frameshift reruns; do not describe the search API
as wholly missing or an empty bounded result as a proof.

**PC-05 — DocShell explanations.** The generic bridge consumes an exact
documentation collection through DocShell's collection/projection boundary.
Inputs bind composition, procedure, scene, collection and localization revisions,
plus the host-authorized projection. Output is portable explanatory content
whose part/step/parameter/warning references match the procedure. It cannot
change required quantities, steps or acceptance evidence.

Test interactive, text and print outputs against the same semantic IDs;
exclude restricted fields from public metadata/search/export. Missing reviewed
essential text gives an explicit reviewed-language fallback or makes execution
unavailable. A portable guide consumes already generated permitted artifacts
without a live DocShell server or Refpath operator host. Frameshift does not
implement a second documentation store to hide an integration gap.

**PC-06 — Phoenix, Ash and phoenix-assets/Svelte.** The host authenticates
sessions, establishes actor/operator membership and passes trusted scope into
every command. Ash actions enforce the same resource policy for browser,
worker, pack and administrator entry points. Conjunct never treats a product
hash or browser-provided role as authority. Existing public catalog reads remain
distinct from authenticated writes and private composition sharing.

phoenix-assets owns generated host/frontend types and asset manifests; Svelte 5
renders registered viewer/inspector/procedure components. It does not own a
parallel domain schema. A mutating command binds a stable scoped command ID,
payload digest, expected target revision and producer admission/fence when
applicable. Same-ID/same-payload replays; changed payload or stale revision
conflicts. The server derives identity/account context and rechecks authority.

The host slice must freeze its session mechanism and action/resource permission
matrix before exposing writes. Test forged roles, cross-operator IDs, CSRF,
stale generated actions, concurrent updates, private asset/cache/search leakage
and schema-generation drift. This is host implementation work; authentication
is not a missing responsibility of the pure Conjunct core.

**PC-07 — Wotex and native device custody.** Wotex supplies public Thing/TD/TM,
capability and interaction contracts. Frameshift supplies exact frame/profile
mapping and retains its authenticated native pairing, credentials and delivery
state. Physical composition and sensor modeling require no device control.

For an enabled Conjunct device profile, CJ6-09 binds actual unit/lot, interface,
firmware and security identity to separately commissioned interactions. A
replacement cannot inherit authority from an identical composition. Test wrong
unit, changed firmware/key, retired binding, revoked control and acknowledgment
without physical postcondition. Web device effects require their own admitted
Refpath/Wotex path; this does not move the existing native delivery journal into
Refpath or make the native app depend on its server.

**PC-08 — Metrics, logs and Beamlens.** Conjunct and Refpath expose bounded
semantic measurements through their invoking host; pure compilation performs
no telemetry I/O. Frameshift assigns one collector/supervisor per integration
and preserves the current catalog, units, cardinality and reset/coverage rules.
The [diagnostics contract](diagnostics.md) owns event definitions and export.

Beamlens receives only authorized redacted observations and a configured BAML
provider with enforced frequency, concurrency, context, duration and spend
limits. It has no mutation tools. GreptimeDB receives qualified
Prometheus/OpenTelemetry ingestion; it owns no domain receipts. Test cardinality,
secret/log injection, token exhaustion, collector/provider outage and continued
ordinary commands. Server logs use bounded structured output and standard
collectors; native logs remain readable through Console.app and `log`.

CJ7-08–CJ7-09 requires measured worker limits and a recovery manifest joining
database positions, producer admissions/effects and content-addressed assets.
Restoration verifies that closure before mutations resume. Missing receipts,
assets or a current fence cannot be replaced by fresh command IDs. Resource
profiles, actionable alerts and recovery objectives are fixed before their
operational acceptance run; no unmeasured latency or zero-loss guarantee follows
from these requirements.

**PC-09 — Rivure, deferred F.** Rivure supplies financial commitments,
account-scoped provider operations, amount/fee/reversal calculations and financial
receipts. Frameshift supplies exact domain/commitment references and approved
terms. Existing external-commitment and Connect surfaces are qualified rather
than proposed as missing wholesale. This work remains on hold for Frameshift.

If resumed, Refpath delivers the financial command; Rivure owns financial
execution and PSP retries. Stable domain and financial IDs join the owners.
Neither layer independently repeats the other's provider mutation. Test lost
acknowledgments, account/environment mismatch, partial reversals, eventual lookup
and idempotency expiry. An unknown outcome cannot be resent after key expiry
without authoritative reconciliation. No finance provider is needed by the
core, independent instructions or native product.

## Development and acceptance order

1. Freeze the selected contract/profile, schema/diagnostics and consumer fixtures
   with its owner. Generate implementation artifacts from those decisions.
2. Implement the producer and consumer adapter in their owning repositories;
   declared simulators may exercise the consumer while producer work continues.
3. Pass the producer's tests and the consumer's joined positive/refusal/recovery
   tests at exact revisions before switching authority or claiming conformance.
4. Record each profile independently. One complete C-to-D frame slice may proceed
   before all three classes pass; full claimed Paper/Photo/Pixel coverage remains
   required. Generality needs passive/sensor fixtures; the operator profile needs
   P1 and two scopes; formal claims need P2. Optional F stays parked.

Missing optional live hosts must leave permitted deterministic/native paths
usable. Offline output reports exact revisions and last known status; observations
remain unadmitted until reconciliation. Current-use operations require the
CJ3-08 freshness/authority contract. An offline guide cannot dispatch purchasing,
device changes or new qualified claims, nor silently queue them for reconnect.
