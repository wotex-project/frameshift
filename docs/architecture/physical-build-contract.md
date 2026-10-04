# Physical Build Contract

**Status:** normative Frameshift v1 contract; partial implementation recorded in
the verification ledger; Conjunct profile migration open
**Owner:** Frameshift Composition & Instructions; current pure contracts in
`packages/build-spec/`
**Milestone:** C, consumed by composition/instructions and printable output in D

This is the existing product-specific semantic and wire contract. It remains
authoritative for v1 replay while [CI-01–CI-08](conjunct-integration.md) governs
extraction into Conjunct. Generic algorithms and frame obligations have different
owners; extraction cannot disable required frame checks. Conjunct CJ.02's
selected UTF-8/RFC 8785 wire profile is not the current ASCII/field-order/LF format. Preserve
old hashes and define explicit successor identity and loss/refusal semantics.
Optional service use is separately admitted and its implementation is on hold.

## Profiles and evidence

**PB-01 — Exact facts.** Version component profiles for Paper, Photo, and Pixel:
display, controller, driver, frame, mat, carrier, mounting, power, connectors,
cables, storage, and required assembly items. Each fact has its unit, exact
manufacturer/part/revision scope, source reference and content digest, retrieval
date, evidence class, and applicable uncertainty/tolerance. Keep conflicting
facts and missing values explicit. Marketplace titles do not establish a part
revision or electrical specification.

Seed the current [candidate BOM](../hardware/bom.md) and manufacturer-based
[simulator](container-frame-simulator.md) facts: Waveshare 13.3-inch E6,
BOE MV270QHM-N40 preliminary P1, and Waveshare P3 64×64 modules. These are
simulation/prototype baselines. They do not qualify a combined assembly,
controller choice, supply chain, or purchasable route.

Separate immutable source facts from versioned evidence assessment and current
eligibility. Record evidence expiry, contradiction, quarantine, safety notices,
seller/integration capability and market/destination scope. A newer favorable
source cannot silently erase an earlier contradiction. Revocation can block a
route without rewriting a historical BuildSpec or order.

### Baseline data admission

Store reviewed canonical profiles under `data/physical/profiles/`; a versioned
manifest pins each file identity and records its public label, candidate state
and unresolved gates separately. Source entries map exact content digests to
HTTPS URLs, document revisions, retrieval dates, media type and byte size.
Every citation must resolve to one matching source revision. Reject missing,
duplicate, orphaned or mismatched profile files/references in the offline data
gate. Never fetch a mutable live page as part of deterministic compilation.

Use each drawing's native axes. The Paper baseline is portrait; landscape
rotation is a later explicit layout choice. Keep `.nominal`, `.typical`,
`.nameplate` and conditional measurements distinct from complete admitted
bounds. Missing tolerance, assembled connection/cable depth, controller,
mounting, thermal or revision evidence remains missing; contradictory scopes
retain both locators. In particular, a thin active-area layer does not establish
total depth. A generic HUB75 family name cannot stand for a qualified pinout.
These seeds contain no prices, selected controller, purchasing route or safety
qualification. Compiler facts require a reviewed property registry before use.

### Catalog profile revision actions

The Ash Catalog domain records public candidate profiles through an internal
`record_profile` action requiring the existing typed catalog editor or research
worker actor. Actor construction is not authentication; authenticated HTTP
writes remain a separate boundary. Accept only a public label and canonical
profile bytes without trimming or normalizing them. Derive profile key, revision, class/kind and SHA-256 identity
through the shared codec. Callers cannot set the identity, attribution, evidence
state or resolved source bindings. All new records are candidates; subsequent
qualification/revocation is a separate versioned assessment.

Resolve every cited digest/revision against immutable SourceDocument records
before writing the profile, including matching manufacturer/measurement/custom
evidence kinds. Standard and supplier documents remain valid general catalog
sources but cannot be mislabeled as those fact evidence classes. Source records have unique URI/revision and
content-digest/revision identities. Preserve a deterministic derived binding
for each fact/port locator to its source document UUID; source deletion and
replacement have no domain action. Missing sources refuse profile admission.
Commit profile and actor-bound audit event in one transaction. Emit only bounded
profile-action outcome telemetry after its transaction; rollback cannot leave
an audit fact or a visible profile. Profile key/revision and content identity
are unique and immutable; no update/destroy action can rewrite them.

Anonymous reads expose bounded metadata pages (50 records, offset at most
10,000). A separate digest-addressed GET returns the exact canonical bytes,
with a strong ETag and immutable public caching. Invalid digests return 400,
missing records 404, storage failure 503; no caller input enters an error body.
The index excludes canonical bodies, source-binding storage and actor IDs.
A downloadable historical profile is evidence data, never current eligibility.
HTTP mutation remains unavailable in this slice.

A local administrative seed command takes an explicit actor UUID and data
folder. It records source leaves and profiles independently, allowing a safe
retry after partial progress. An existing revision must have identical identity
inputs; collisions fail and never overwrite. It performs no source fetch,
provider call, supplier action or implicit application-start write. A shell
operator's explicit import is distinct from authenticating a browser user.
Read at most 262,144 bytes per manifest/profile; refuse direct file symlinks and
profile path traversal. The selected local directory is administrator-controlled,
not an uploaded archive or an untrusted filesystem sandbox. Retain the source's
recorded download-completion timestamp as its observation time.

**PB-02 — Timing and power.** Source manufacturer-recommended refresh intervals,
minimum safe update spacing, waveform/full-refresh requirements, sleep behavior,
temperature range and power limits by exact profile. Preserve recommended and
mandatory limits as distinct fields. Use those recommendations for sensible
defaults under the [display-timing contract](display-timing.md); keep supported
customer overrides explicit. Unknown recommendations remain unknown. Longer
dwell is not evidence of meaningful energy savings for continuously powered
Photo or Pixel displays. Simulated behavior never becomes measured power data.

## Immutable BuildSpec

### S2 successor obligation mapping

At Conjunct `f6609c5e4c2188626f5e1f345446fec04e78d6c9`, each
retained stage below remains mandatory. A candidate predicate mapping has not
passed its full product corpus. A producer gap means that the closed current
wire contract lacks the needed derivation or assessment; a consumer cannot
implement that generic algorithm and label its output a kernel result.
No whole frame class is available under the successor contract yet.

| Retained stage | Producer mapping candidate and unresolved requirement |
| --- | --- |
| `graph` | Explicit Selection/occurrence closure and `present`/`equal`/`occurrence-count` cover some representation/role checks. Occurrence-forest and rule-dependency DAG validation do not establish acyclicity of the separate power/dependency networks; require an exact directed-network assessment. |
| `completeness` | ProductDefinition rules require each named property/interface/role through `present`, `equal`, counts and implications. Freeze display/controller/energy-source obligations independently of optional part declarations; absent/missing/conflicted cases remain required. |
| `geometry` | `contains`/`clearance_ge` with exact adopted geometry, transforms, qualified error bounds and explicit AssessmentSet. Complete installed, connector and service envelopes remain distinct; no unqualified mesh supplies them. |
| `viewing` | Qualified geometry can cover containment and plane constraints. Complete projected active/aperture rectangle-union coverage, tiled overlap/gaps and occlusion still need a producer assessment contract; simple pairwise containment is insufficient. |
| `power_interfaces` | Exact scoped `interface_match` covers complementary roles, voltage containment and declared pinout/reference/polarity/protection fields. Product rules must preserve each whole operating interval and missing/conflicting source state. |
| `power_loads` | `sum_le` evaluates explicitly listed terms. Require producer derivation of directed passive/converter flow: downstream demand, repeated loads, cumulative voltage drops, per-port/shared ratings, ambiguity, missing feeds and cycle handling. Caller-computed totals or a boolean claim are not this derivation. |
| `power_contracts` | Pairwise `interface_match`/`subset` cannot establish one common alternative over an entire connected rail with passive ties. Require exact connected-group intersection and its source-bound witness/refusal. |
| `thermal` | Exact `range`/`sum_le` can represent component ambient and heat budgets, with absolute temperature and temperature-difference kinds kept distinct. Product mappings must include internal rise, enclosure scope and common assembly declaration; sums alone are not measured thermal qualification. |
| `mounting` | `sum_le` and scoped mechanical interfaces can compare a known support load. Require producer support-path/subtree derivation with repeated mass, shared ratings, ambiguous support, self-anchoring and cycles; geometry fit alone supplies none of these. |
| `signals` | Scoped `interface_match` covers endpoint voltages and declared fields. Connected-group common driver alternatives require the same group reasoning as power contracts; thresholds/timing and executable mappings retain separate qualification. |
| `signal_routes` | Require a producer route assessment over exact controller ownership, endpoint mappings and expanded paths, retaining wrong root, cycles, missing/ambiguous feeds and versioned internal mappings. A relation label or connected endpoint is insufficient. |
| `operation` | Scoped `in_set`, `range`, counts and `sum_le` can compare declared firmware/protocol/encoding, hard dwell and storage values. Integrated/dedicated/shared storage ownership and artifact closure need a faithful mapping. Recommendations remain advisory; producer comparison does not qualify a runtime. |
| `artifacts` | Physical quantities do not establish pixel-coordinate assignments, complete canvas union coverage, encoding-derived bytes or retained-copy storage ownership. Require an exact raster/layout assessment with integer units, rotations, overlap/gap witnesses, size bounds and source/runtime binding. |

The current predicate/operand lists are closed in the producer's
[`domain.schema.json`](https://github.com/futhr/conjunct/blob/f6609c5e4c2188626f5e1f345446fec04e78d6c9/schemas/domain/0.1/domain.schema.json),
with execution defined by
[`domain-operations.md`](https://github.com/futhr/conjunct/blob/f6609c5e4c2188626f5e1f345446fec04e78d6c9/docs/specs/cj02/domain-operations.md).
The consumer fixture `scripts/conjunct/test/fixtures/directed-flow-rule.json`
changes only the supported control predicate to the proposed, unsupported
`directed_flow` name. A real staged kernel loads its source and `present` control
but refuses that rule at `/body/rules/0` with `schema_violation`. This is a
reproducing current-contract refusal, not a proposed API specification or proof
that every possible producer extension must use that name.

The upstream requirement is an independently specified, bounded network/route
assessment over immutable expanded occurrences and exact scoped claims,
including complete positive, violated, missing/conflicting, repeated-use,
cycle/ambiguity and overflow fixtures. Its canonical witness/report must be
available through the public port and browser operations under a newly selected
ContractRef. An assessment cannot merely import the retained v1 verdict.
The thirteen-stage positive synthetic Paper composition remains unqualified
until all mappings and their acceptance corpus are complete. Photo and Pixel
remain independent choices with the same mandatory coverage gate.

`GET /api/composition/:class` returns the product-owned availability projection
for exact `paper`, `photo` or `pixel`: `status: unavailable`,
`reason: producer_profile_incomplete`, `admission: false`, producer revision,
the complete mandatory stage list and the identified producer gaps. Unknown or
structured class values refuse with `400 unsupported_class`; extra readiness
parameters cannot change the result. It starts no producer worker or effect,
exposes no private inputs and uses `Cache-Control: no-store`. POST and other
mutation routes remain absent. This projection reports the integration gate;
it does not classify a physical candidate as incompatible.

**PB-03 — Identity.** A BuildSpec pins its schema/compiler semantics, exact part
and profile revisions, quantities, canonical geometry/tolerances, mounting,
controller/electrical requirements, assembly intent, and compatibility inputs.
Define required fields, maximum sizes, permitted enums, schema migration, and
unsupported-version rejection before implementing consumers.

Use canonical units, bounded integers/fixed-point arithmetic, deterministic
ordering and serialization, and a versioned cryptographic digest. Set explicit
limits within JavaScript's safe integer range; refuse overflow and ambiguous
conversion. Equal pinned inputs must yield identical canonical bytes and hash
on both targets. Record compiler/rule identity with outputs so a semantic
change cannot reuse an old acceptance result accidentally.

Do not include mutable prices, availability, retrieval timestamps, current
market eligibility, or order state in physical identity. Preserve these as
separate versioned projections/records. Changes to selected parts, revisions,
geometry, or compatibility semantics produce a new specification. Recompiling
old pinned inputs cannot silently follow the latest profile revision.

### Canonical assembly document v1

The shared package owns the `frameshift_build/assembly` codec. Its
structural validity permits an incomplete or incompatible plan to be saved;
only the complete constraint compiler can produce a compatibility result. The
codec never emits acceptance, safety or purchasing eligibility.

Emit these required root fields in order:

| Field | Value and bound |
| --- | --- |
| `class` | `paper/photo/pixel` |
| `connections` | Zero to 256 directed port connections, sorted by canonical bytes |
| `dependencies` | Zero to 256 explicit consumer/provider role bindings, sorted by canonical bytes |
| `instances` | One to 64 component instances, sorted by unique ID |
| `intent` | Explicit installation requirements described below |
| `schema` | Integer `1`; no automatic migration |
| `semantics` | Exact `frameshift-physical-1` rule identity; unsupported identities refused |

An instance has `id`, `location`, `placement`, `profile` in order.
Profile is an exact `sha256:<64 lowercase hex>` canonical profile identity.
Location is `enclosure/internal/external`. Placement contains `rotation`
(0, 90, 180 or 270 degrees about its depth axis), `x_um`, `y_um`, `z_um`
in order; coordinates are integers from zero through 5,000,000 micrometres.
They describe intended placement in a common enclosure coordinate system,
not measured fit. The enclosure origin, occupied/service envelopes, multiple
enclosures and unsupported geometric cases require explicit compiler results.
No arbitrary mesh or executable expression enters this format.

Every unit receives its own instance ID. Repeated exact profile pins produce
shopping-list quantities by counting instances. Electrical, mounting and
placement checks retain per-instance identity; six modules cannot accidentally
be evaluated as one load. A kit may have a separately reviewed assembly profile;
its contents and dependencies still need the compiler's completeness checks.

A connection contains `from` and `to`; each endpoint contains `instance`
and `port`. A dependency contains `consumer`, `provider`, `role`;
role is one of the component-kind values in the profile schema. Referenced
instance IDs must exist. Endpoint port existence, direction, capability/pinout,
required-role completeness, self-connections and dependency cycles belong to
semantic checks. Duplicate edges are refused structurally. Cycles and missing
connections must remain representable for explained incompatible/unknown output.
Cable and adapter components have their own instances and ports; an edge does
not implicitly supply a missing cable or adapter.

Intent fields, in order, are `ambient_mc`, `artifact`, `dwell_ms`,
`firmware`, `mounting`, `protocol`, `storage_bytes`. Ambient temperature
contains inclusive integer `max`, `min` within −100,000 to 300,000 millicelsius.
Dwell is 1–604,800,000 milliseconds; storage is 1–1,099,511,627,776 bytes.
Mounting is `wall/stand`. Artifact, firmware and protocol are exact registry
identifiers using the profile identifier syntax. They are desired capabilities;
an unknown registry mapping or absent device evidence cannot pass by name.
All other identifiers use the same syntax and case sensitivity. Intent has no
hidden compiler defaults and contains no price, supplier account, customer,
artwork, source retrieval time or current eligibility fields.

Use the same 262,144-byte, 16-level resource preflight, ASCII JSON, strict integer
rules, exact field ordering and one final LF as the profile codec. Typed export
sorts sets and refuses duplicate IDs/edges. Import compares exact re-encoding,
refusing additional/duplicate fields, ambiguous numbers and noncanonical bytes.
Hash `frameshift.build.v1\n` followed by the canonical bytes with SHA-256.
Changing class, pins, quantities, geometry, connections, requirements or rule
identity changes physical identity. Array input order and external labels do
not. Standard BEAM/Web Crypto adapters produce the same identity and fail closed
when cryptography is unavailable.

A parsed document is not a resolved assembly. Resolution must fetch or import
each exact pinned profile, recompute its identity and preserve that pin. It
cannot substitute a newer revision. Missing profiles remain unresolved. The
server repeats resolution and compilation independently of browser output.
Portable output carries the referenced profile bytes separately; local artwork
and mutable market observations remain separate optional records. The codec
must round-trip offline, including incomplete plans, with equal bytes/hash on
both targets. Structural mutation tests and generated pin/placement/edge
permutations qualify this boundary before compiler consumers are attached.

### Exact profile resolution

The standard BEAM/browser `resolve_build` / `resolveBuild` adapters
accept canonical assembly bytes and a list of zero to 64 canonical profile byte
strings. Limit the combined UTF-8 byte size to 4,194,304 before decoding or
hashing; each document retains its own 262,144-byte ceiling. Refuse non-string
entries, malformed/noncanonical profiles, duplicate computed identities and
unreferenced extra profiles. Compute every profile identity from its validated
bytes with the standard cryptographic adapter. Never accept a caller's digest
as proof of those bytes. A digest-service failure is a refusal.

The shared resolver receives only the adapter-computed identity/byte pairs,
revalidates document structure and binds the exact pins. Return the validated
assembly, profiles sorted by computed identity and the sorted unique missing
pin list. Missing profiles are explicit unresolved input for compatibility;
they must not become a substituted revision, empty valid part or successful
assembly. Input order does not affect resolution. Repeated component instances
share one pinned profile body without losing individual instance identity.
Resolution performs no HTTP, catalog lookup, source authentication or evidence
promotion. Direct use of internal Gleam identity/byte pairs is not an authority
boundary; all external consumers must enter through the hashing adapters.

Use this same boundary for offline portable input and server-supplied catalog
bodies. A later compiler consumes the resolution object; a database read alone
cannot bypass the digest check. Tests must cover tampered bytes, unchanged
caller pins, missing/extra/duplicate records, mixed revisions, per-document and
combined resource ceilings, order independence and standard-crypto outages.

### Canonical component profile v1

The pure `packages/build-spec` package owns a shared Gleam typed profile codec
for BEAM and JavaScript. A profile is immutable content, independent of current
eligibility. Its required JSON fields, emitted in this exact order, are:

| Field | Value and bound |
| --- | --- |
| `classes` | One to three unique sorted values: `paper`, `photo`, `pixel` |
| `facts` | One to 128 facts, sorted by unique fact key |
| `id` | Stable component profile identifier |
| `kind` | `display/controller/driver/frame/mat/carrier/mount/power/connector/cable/storage/assembly` |
| `manufacturer`, `part` | Exact normalized identifiers; display names live separately |
| `part_revision` | Exact manufacturer part revision, or `unverified` |
| `ports` | Zero to 32 ports sorted by unique ID |
| `requires` | Zero to 12 unique sorted required component kinds |
| `revision` | Exact immutable catalog profile revision |
| `schema` | Integer `1`; other versions refused without automatic migration |

Identifiers and fact keys contain one to 96 ASCII letters/digits, dot,
underscore, plus or hyphen, starting with a letter/digit. They are case-sensitive;
no normalization occurs during import. Ports contain `direction`
(`source/sink/bidirectional`), `facts` (one to 64), `id`, `kind`
(`power/signal/mechanical`) and `required` (boolean), in that order.
A required role or port is an input to the composite compiler, not proof that
an appropriate component or connection exists.

Each fact contains `key`, `sources`, `unit`, `value`, in that order.
Numeric units are `um/mv/ma/mw/g/mc/byte/ms/count`. Their nonnegative ceilings
are the arithmetic contract's limits for the first five; temperature permits
−100,000 to 300,000 millicelsius; bytes permit up to 1,099,511,627,776; time up to
604,800,000 milliseconds; count up to 1,000,000. A known numeric value contains
`max`, `min`, `state: "known"`. Bounds are inclusive integers; lower cannot
exceed upper. A quoted nominal value without tolerance does not establish a
worst-case mechanical/electrical bound: store a distinct nominal fact and leave
the required tolerance fact missing. The compiler's fact registry defines each
property's unit, significance and completeness requirement.

The `token` unit instead uses `state: "known"`, `terms` (one to 32 unique
sorted identifiers). It represents documented alternatives or capabilities;
its meaning and matching rule belong to the compiler's property registry.
Missing/conflicting values contain only `state: "missing"` or
`state: "conflicting"`, with no guessed value. Every known fact needs one to
eight source references; missing facts have none; conflicts retain two to eight
distinct references. A reference contains `digest` (64 lowercase SHA-256 hex),
`evidence` (`manufacturer/measurement/custom`), `locator` and `revision`
(identifier syntax), in that order. Sort references by their canonical bytes
and reject duplicates. Source retrieval dates/URLs and raw documents are stored
separately under the content digest. A citation is a claim requiring catalog
assessment; syntactic validity never establishes the source's authenticity.

Canonical bytes are compact ASCII JSON with the above object field order,
sorted set-like arrays, decimal integers, no alternate escapes, and one final
LF. Import accepts at most 262,144 bytes and 16 container levels. Check these
limits before native JSON decoding, then validate and compare with re-encoded
bytes. Refuse duplicate or unknown fields, noncanonical ordering/numbers,
unsupported units/enums, invalid bounds, oversized lists and malformed input.
Return bounded error codes, never the raw untrusted payload. Typed encoding
sorts collections but refuses duplicate identifiers. Hash the exact bytes with
SHA-256 after the ASCII domain prefix `frameshift.profile.v1\n`; express identity
as `sha256:<lowercase hex>`. BEAM and browser adapters use their standard crypto
implementations; an unavailable browser digest API returns `crypto_unavailable`
without a fallback identity. All structural decisions and canonical bytes share Gleam code.

Profile import/export must work offline. Exported bytes are directly importable;
accepted bytes and digest cannot change when labels, prices or eligibility do.
Profile identity does not yet constitute a BuildSpec. Composite schema,
constraint completeness, graph validation and formal admission remain required.

**PB-04 — Constraint result.** Return `compatible`, `incompatible`, or `unknown`
with machine-readable constraint IDs, implicated part/revision IDs, source
references, relevant values/units, and clear explanations. Check:

- dimensions, tolerances, enclosure depth, clearances, stack-up and mat opening;
- connector pinout, electrical levels, controller/driver/panel interface;
- supply capacity, current limits, protection and documented power envelope;
- thermal evidence, mounting/load and strain relief;
- storage, firmware, artifact formats, protocol bindings and update behavior;
- quantities, required adapters, dependency cycles and missing assembly items.

Compatibility is conditional on modeled facts and scope. Missing required
facts, contradictions, and unqualified interfaces cannot pass through defaults.
Custom parts may appear in planning output with unknown results. Automated
purchasing requires the applicable compatibility, evidence and route gates;
an affirmative calculation alone does not certify physical safety.

### Dependency and port structure checks

The compiler's graph stage consumes a validated exact resolution. It
returns individual constraints, with stable code/outcome/reason, implicated
instance IDs and references to the exact build/profile/port fields used. These
references retain the profile content pin; the complete report resolves profile
revision and fact citations from the same resolution. A stage result cannot
stand for complete assembly compatibility or purchasing admission.

Evaluate these obligations without vendor/model branches:

- Every instance's profile resolves, its class includes the selected class, and
  its manufacturer part revision differs from the explicit `unverified` marker.
  Missing profiles or unverified revisions yield unknown; a documented different
  class yields incompatible. Content resolution alone does not authenticate a
  manufacturer's claimed revision.
- The directed consumer-to-provider dependency graph is acyclic, including
  self-dependencies. Each declared binding's provider kind matches its role.
  Every role in a resolved profile's `requires` list has a matching binding;
  absence is unknown. A binding to an unresolved provider cannot satisfy it.
  The full compiler also applies mandatory component/physical obligations;
  this declared-role stage cannot let a profile opt out of those obligations.
- Every required profile port is incident to a connection. Both endpoints of
  every connection exist, belong to distinct component instances, have equal
  power/signal/mechanical kinds, and permit the stated direction. From permits
  `source/bidirectional`; to permits `sink/bidirectional`. A known absent
  endpoint or wrong kind/direction is incompatible; an unresolved endpoint's
  profile yields unknown. A merely connected port still needs every electrical,
  pinout, mounting or signal-contract constraint in subsequent stages.
- The directed power-connection graph between instances is acyclic. Use edges
  whose endpoints are resolved power ports; missing or mismatched endpoints
  already retain their separate unknown/incompatible constraint. Source fan-out
  and adapter conversion still require complete load/capacity accounting.

Cycle analysis returns exactly the sorted nodes that participate in a cycle,
excluding tails merely leading into or out of one. Bound it to 64 unique nodes
and 256 directed edges. Parallel semantic edges may share an endpoint pair;
deduplicate them for reachability. Refuse dangling nodes or excessive input.
Use visited-node traversal, never unbounded recursive path enumeration. Preserve
self-loops. Check the implementation against an independent transitive-closure
oracle over all 512 directed graphs on three vertices, plus long-chain and
large-cycle limits on both runtimes. Test unresolved profiles, wrong roles,
missing ports, reversed connections and adapter cycles against actual checks.

### Compiler fact registry

The compiler fact reader uses an explicit property registry. A property
has component/port scope, required unit and numeric-or-term shape. Read exact
keys only. Never strip `.nominal`, `.typical`, `.nameplate` or condition
suffixes, borrow an absolute rating for an operating limit, aggregate unrelated
ports, or search a different profile revision. A generic interface family cannot
substitute for a pinout, driver, protection or executable contract.

Initial registry properties are:

| Scope | Exact properties | Unit and lower bound |
| --- | --- | --- |
| Component | `outline.width/height/depth`, `active.width/height`, `inner.width/height/depth`, `opening.width/height` | `um`, positive |
| Component | `active.offset.x/y`, `opening.x/y`, `clearance.left/right/top/bottom/front/back`, `connector.clearance`, `cable.clearance` | `um`, nonnegative |
| Component | `mass`, `mount.capacity` | `g`, nonnegative |
| Component | `power.maximum`, `power.output_capacity`, `heat.maximum`, `thermal.capacity` | `mw`, nonnegative |
| Component | `temperature.operating`, `thermal.ambient` | `mc`, −100,000 minimum |
| Component | `temperature.ambient_rise` | `mc`, nonnegative |
| Component | `storage.capacity`, `artifact.maximum` | `byte`, nonnegative |
| Component | `storage.retained_artifacts` | `count`, positive |
| Component | `refresh.minimum/maximum`, `refresh.recommended_minimum/recommended_maximum`, `refresh.energy_recommended` | `ms`, nonnegative |
| Component | `raster.width/height` | `count`, positive |
| Component | `artifact.contract`, `firmware.contract`, `protocol.contract`, `assembly.thermal`, `mount.pattern`, `mount.kind`, `mount.mode`, `mount.contract`, `power.mode` | `token`, documented terms |
| Power port | `input.voltage`, `output.voltage`, `voltage.drop` | `mv`, nonnegative magnitude |
| Power port | `current.maximum`, `current.capacity` | `ma`, nonnegative |
| Power port | `power.maximum`, `power.capacity` | `mw`, nonnegative |
| Power port | `fanout.maximum` | `count`, nonnegative |
| Signal port | `logic.voltage` | `mv`, nonnegative magnitude |
| Mechanical port | `mount.capacity` | `g`, nonnegative |
| Mechanical port | `fanout.maximum` | `count`, nonnegative |
| Power or signal port | `polarity`, `reference.contract`, `pinout.contract`, `connector.contract`, `protection.contract`, `driver.contract`, `interface.family`, `strain_relief.contract` | `token`, documented terms |
| Mechanical port | `mount.pattern`, `mount.contract`, `strain_relief.contract` | `token`, documented terms |

Slash-separated suffixes in the table denote separate complete keys. Upper
bounds and term/count limits remain those of the canonical profile schema.
Registry membership alone does not make a property mandatory or sufficient:
each subsequent constraint specifies which properties it requires and how it
compares them. Recommendations remain advisory; a term's existence does not
qualify its named contract. Voltage comparisons must retain polarity/reference
scope. Whole-envelope geometry cannot silently substitute a layer thickness;
thermal capacity needs its operating scope and mounting needs its stated load
and pattern. `current.maximum` means the required worst-case input envelope,
including applicable start/update transients; a condition-specific quote cannot
supply it without evidence covering that entire scope.

Each reading retains instance ID, exact profile pin, separate port/key, actual
and expected unit, the original value and complete source references. Return a
closed status: `usable`, `missing_profile`, `missing_port`, `missing_fact`,
`conflicting_fact`, `unsupported_property`, `unit_mismatch` or
`invalid_value`. Unknown/conflicting or unusable values must never enter
numeric comparisons as zero or a compatible term. Absent and explicitly missing
facts have the same missing status; conflict citations remain intact. Lookup
performs no interpretation, evidence promotion, DB access or source fetch.
Comparisons use the reader's numeric/term selectors, which refuse every unusable
status and wrong value shape; the preserved observed value is for explanation.

Tests must cover exact scope/unit/positive bounds, preserved citations, missing
profiles/ports/facts, conflicting sources, condition/nominal non-substitution and
unsupported fields on both runtimes. The three sourced baseline profiles remain
incomplete even where a nominal, typical or absolute value exists nearby.

### Enclosure placement and service envelopes

The geometry stage consumes validated exact profile resolution. It evaluates a
single enclosing frame in a common right-handed planning space: X increases
rightward, Y downward and Z from the viewing side toward the back. Coordinates
refer to the top-left-front of the rotated bare outline. The enclosure cavity
starts at zero. Require exactly one instance with location `enclosure`, kind
`frame`, zero position and zero rotation. No enclosure or multiple enclosures
produce an unknown topology result; a resolved wrong kind or nonzero enclosure
transform is incompatible with this coordinate contract. Unresolved enclosing
profiles remain unknown. Do not silently select the first frame.

For every `internal` instance read exact `outline.width/height/depth` and
`clearance.left/right/top/bottom/front/back`. A clearance is the maximum
required free envelope for connectors, cable bend and service on that face;
zero requires an explicit sourced value. The individual connector/cable scalar
facts do not replace these directional bounds. Use the full component depth.
External instances do not consume the cavity; they still require their own
mounting, electrical and installation checks.

Rotation is clockwise as viewed from the front. Depth and front/back clearance
do not rotate. In-plane mappings are:

| Rotation | Width, height | Left, right, top, bottom clearance |
| --- | --- | --- |
| 0 | W, H | L, R, T, B |
| 90 | H, W | B, T, L, R |
| 180 | W, H | R, L, B, T |
| 270 | H, W | T, B, R, L |

For each axis emit two separate constraints: negative-face clearance maximum
must not exceed the placement coordinate; coordinate plus maximum outline plus
positive-face clearance maximum must not exceed the frame's minimum inner
extent. Retain every exact input path, profile pin, reading, unit and citation,
and both operand intervals when known. A missing/conflicting/wrong-unit reading
cannot become zero. Known fit failure remains a failure even when another axis
is unknown. Inclusive contact at a bound passes that modeled constraint.

Also compare every unordered pair of internal service envelopes. A known
separating axis (including contact) suffices even if another axis is unknown.
If all three axes are known and overlap, report unknown
`overlapping_service_envelopes`: overlapping bounding boxes alone do not prove
material collision for hollow or interlocking parts. Otherwise report the
unusable-reading reason. These checks cannot authorize intersecting assemblies;
a separately modeled mating/cavity relation would need its own contract.

Use the canonical instance order, X/Y/Z axis order, negative then positive face,
and sorted unordered pairs. With at most 64 instances there are at most 2,016
pairs and 385 topology/face checks; each coordinate calculation is bounded by
15,000,000 micrometres, exactly representable on both targets. No meshes,
unbounded search, I/O or inferred geometry enters this stage. Missing or
unsupported enclosure topology still emits each internal instance's face
obligations with unknown cavity availability, preserving known negative-face
failures and pair checks. An invalid enclosure transform cannot supply cavity
bounds. A usable per-axis envelope is computed independently of other axes.

This stage emits findings, not a whole-build verdict. Aperture coverage,
obstruction, complete mounting/thermal/electrical/protocol checks and source
qualification remain separate obligations. Tests must cover four asymmetric
rotations, every face, tolerance extremes, exact contact, missing/conflicting
bounds, external placement, enclosure topology, repeated instances, maximum
counts, deterministic ordering and an independent geometric oracle on both
runtimes. The existing candidate profiles remain incomplete.

### Rectangular viewing coverage

The viewing stage uses straight-on rectangular projections in the enclosure's
coordinate system. It must never treat the bounding rectangle of a tiled array
as entirely active. Coverage is the union of actual guaranteed active rectangles;
a gap, even one micrometre wide, remains uncovered. This model makes no viewing
angle, optical color, glass-reflection or physical qualification claim.

Use a bounded pure rectangle-union primitive: one positive-area target rectangle,
zero to 64 positive-area covering rectangles, integer edges within
−15,000,000 through 15,000,000 µm. Reject inverted/empty rectangles and out-of-bound
edges. Empty coverage is false. Clip coverings to the target, partition at all
unique X edges, then prove continuous Y coverage in each positive-width slab.
Inclusive touching edges introduce no gap; overlapping coverage does not double
count area. Do not use floating-point area sums, raster sampling or a containing
bounding box as proof. At most 130 unique X edges and 129 slabs are inspected.
An independent unit-cell oracle must enumerate every subset of the nine
rectangles on a 2×2 cell domain; additional tests cover bounds, order, overlaps,
negative origins, exact contact and narrow gaps on both runtimes.

A viewing consumer must derive the largest possible aperture rectangle and each
display's guaranteed active rectangle from exact sourced offsets, dimensions,
outline and placement/rotation. These are distinct from nominal outlines. Every
required bound must be usable, and active area must fit inside the outline.
Missing/contradictory geometry cannot be repaired by assuming a centered panel.
Frame and mat openings, nested masks, plane ordering and possible obstructions
must be explained separately. The union primitive alone cannot emit a whole
viewing or assembly verdict.

### Sourced viewing geometry and mask order

The viewing stage shares the enclosure selector and the canonical instance
order with enclosure fit. Unresolved profiles emit unknown classification
findings, including external components. Resolved displays and mats must be
internal to participate in this viewing model; another location is an unknown
unsupported placement. At least one internal display is required. The selected
frame's aperture plane is the cavity-front plane Z=0.

For a display read `active.offset.x/y`, `active.width/height` and
`outline.width/height`. For a mat read `opening.x/y/width/height` and
`outline.width/height`. For the frame read the same opening keys with
`inner.width/height`; opening offsets are relative to the cavity origin.
Emit X/Y constraints requiring offset plus size maximum to fit within the
containing dimension minimum. Do not use a region whose containment checks
have missing inputs or fail. Readings and their exact source references remain
attached to each finding.

Represent each projected edge as an inclusive interval. Unrotated edges are
X, Y, X+width, Y+height. A quarter-turn maps left/right to H−bottom/H−top and
top/bottom to left/right; a half-turn maps both axes to their opposite edges;
a three-quarter turn maps left/right to top/bottom and top/bottom to
W−right/W−left. Interval subtraction uses lower minus upper and upper minus
lower. Add the rotated bare-outline placement coordinates afterward. The bare
outline itself stays anchored at the placement origin, with swapped dimensions
for quarter turns. Never round or average tolerances.

The possible rectangle uses each left/top lower bound and right/bottom upper
bound. The guaranteed rectangle uses left/top upper and right/bottom lower
bounds. If uncertainty leaves no positive guaranteed rectangle, retain unknown
`no_guaranteed_region`. This is conservative over all independent admitted
bounds; it does not infer correlations between dimensions.

Sort internal mats by increasing Z and then ID. Each mat's guaranteed outer
rectangle must cover the previous mask's possible opening; the mat's possible
opening must fit within the previous mask's guaranteed opening. Its front plane
must be at or behind the previous mat's maximum back plane. The frame plane
starts this chain at zero. Every mat retains its own aperture-containment and
full-depth obligation. Multiple mats are supported; missing or overlapping
plane order remains unknown or incompatible as appropriate. The innermost mat
opening, or frame opening when there are no mats, is the final visible target.

Every display front must be at or behind the final mask's maximum back plane.
Only usable active regions with admitted plane order may contribute guaranteed
coverage. Prove the final possible aperture is covered by the union of these
rectangles. If complete known geometry leaves a gap, emit incompatible
`aperture_not_covered`. If a needed region/plane is unresolved, an uncovered
result stays unknown; an already complete known union can establish this one
coverage constraint while the separate unknown obligations remain visible.

For each display inspect every other internal non-mat component whose front is
strictly in front of it. A possible bare-outline intersection with the portion
of that display visible through the final aperture emits unknown
`possible_obstruction`. Unknown projection emits unknown; a proven disjoint
projection or an obstacle at/behind the display plane passes this modeled check.
Bounding-box intersection cannot prove opacity of hollow parts. Masks are
handled by their opening/plane chain. No inferred transparent material or
unmodeled cutout may silently bypass obstruction checks.

Limits inherit the 64-instance schema: at most 64 aperture regions, 64 coverage
rectangles and 4,032 ordered obstruction pairs. Derived signed edges remain
within the rectangle primitive's ±15,000,000 µm bound. Findings remain ordered
by instance, mask Z/ID and obstacle instance; all source readings, placement
paths and operand intervals are preserved. Containment, coverage and obstruction
findings include each participating instance’s possible/guaranteed rectangle and
role (target, covering, active or obstacle), retaining absent regions explicitly.
Tests must cover frame-only and
nested masks, rotations/offsets/tolerances, tiled seams, missing/conflicting
facts, plane order, unknown kinds and possible/disjoint/behind obstruction on
both runtimes. These findings make no optical or complete assembly claim.

### DC power interface declarations

A DC interface stage consumes exact resolved connections and reuses the graph
stage's endpoint lookup. It emits findings only for connections where either
resolved endpoint is a power port; unresolved endpoints remain explicit, and a
known power/non-power mismatch is incompatible. Both ports must exist on
different instances and permit the directed connection. An absent port or
reversed direction is incompatible. A bidirectional power port yields unknown
`unsupported_bidirectional_power`: the single directed edge does not declare
its switching, charging, backfeed or reverse-load behavior. Do not infer a
pass-through converter or treat its input as a second independent source.

For an ordinary source-to-sink power connection require these independent
constraints:

- The source's exact `output.voltage` magnitude interval is wholly contained
  in the sink's exact `input.voltage` interval. Mere overlap is insufficient.
  Preserve required/available intervals in millivolts; missing, conflicting or
  wrong-unit values remain unknown.
- Each endpoint's `polarity` must be exactly one term, `positive` or
  `negative`, and agree. Opposite known polarities are incompatible. Missing
  polarity is unknown; AC, mixed or unrecognized polarity terms are unknown
  unsupported scope. Negative rails compare magnitudes only after preserving
  this separate polarity finding. No signed or AC waveform is inferred.
- Each of `reference.contract`, `pinout.contract`, `connector.contract`,
  `protection.contract` and `strain_relief.contract` must have at least one
  exact common term between endpoints. A term denotes one complete declared
  interface contract, including complementary mating roles where relevant;
  lists are alternatives, not independently optional safety features. Disjoint
  known alternatives are incompatible; unusable readings remain unknown.

These are declared-interface agreements. Matching opaque terms do not establish
that a contract is registered, a supplier claim is true, a driver is executable,
or physical safety/qualification passed. The complete compiler must separately
require exact supported/qualified contract mappings; `interface.family` or
model names cannot satisfy that requirement. Current/load accounting, conversion,
protection coordination and complete source-to-load topology remain separate
obligations even when every paired declaration agrees.

Preserve connection endpoints, port IDs/directions/kinds, profile content pins,
all source readings and numeric operands. Iterate canonical connections, with
voltage, polarity then contract keys in the order above. At most 256 connections
produce 1,792 ordinary pair findings. Tests cover full interval containment,
negative polarity, exact/multiple/disjoint contract alternatives, missing or
conflicting data, nominal non-substitution, unresolved/absent/mismatched ports,
reverse/self connections and bidirectional refusal on both targets. Add an
independent exhaustive integer interval-containment oracle.

### Direct DC load budgets

Group canonical connections by each resolved ordinary power source port. Count
all outgoing connections, including unresolved targets; never omit an unknown
load from a known partial total. Each target's exact `current.maximum` means
its full worst-case input demand, including applicable startup/update transients.
No nominal current or conductor capacity may replace that demand. Retain every
sink instance and port separately, including repeated physical instances of the
same profile. A connected sink may have only one incoming connection in this
scope; multiple feeds remain unknown switching/OR-ing behavior and cannot
contribute a known direct demand.

The component's explicit `power.mode` declares this budget scope. An ordinary
`source` has one or more source power ports and no sink power port; a
`consumer` has sink power ports and no source power port; a `converter` has
exactly one sink and one or more source power ports. The converter's declared
input demand must cover its entire admitted output envelope and conversion
losses. Bidirectional ports remain unknown. `passthrough` cables/splitters require the
passive flow model below; a static demand cannot stand in for that model. Missing/ambiguous
modes remain unknown; a known ordinary mode contradicting its port topology is
incompatible. A mode does not establish measured source truth or qualified
conversion behavior. Complete role/feed/flow obligations remain mandatory.

For each source port emit:

1. Connection count ≤ its explicit `fanout.maximum` minimum. A connector does
   not implicitly permit an arbitrary splitter; a single mating position should
   declare one. Missing fan-out data stays unknown.
2. Sum of all supported sink-current upper bounds ≤ source
   `current.capacity` minimum. Each direct sink must be a resolved consumer or
   converter in the declared scope. A cable marked with zero static draw cannot
   hide the load beyond it; unsupported modes make the sum unknown.
3. Conservative output-power demand ≤ source `power.capacity` minimum. Derive
   required milliwatts from this port's output-voltage envelope times total
   current envelope. Floor the lower product and ceil the upper product after
   dividing by 1,000. Do not multiply already rounded per-load powers, combine
   unrelated rail currents, or substitute typical power.

Also sum these output power envelopes across each source/converter component's
connected output ports and compare with its exact `power.output_capacity`
minimum. This separate shared limit prevents independently legal rails from
exceeding a common supply rating. Do not substitute the component's consumption
`power.maximum` or add unrelated per-port ratings as the shared capacity.

Keep individual mode/feed findings alongside budget findings, source readings,
exact port/connection references and known operand intervals. Current or voltage
scope that is unsupported cannot generate a known budget by silently using zero.
A known fan-out limit can still fail while its load total is unknown. No connected
output ports means no direct budget finding, not a whole-build acceptance.

At most 256 edges contribute: current sum ≤25,600,000 mA, the largest pre-division
voltage/current product ≤7,680,000,000,000, and total derived power ≤7,680,000,000
mW. These are intermediate software bounds, not acceptable electrical ratings.
All fit within JavaScript's safe integer range. Tests must cover repeat-instance
loads, shared multi-rail capacity, fractional-milliwatt ceiling, exact limits,
missing targets/demand/modes, false zero-draw pass-through, multiple feeds,
fan-out and maximum edge counts on both targets. Direct budgets do not replace
pass-through voltage/drop/load propagation or qualified converter evidence.

### Connected power contract consistency

Pairwise declared agreement is necessary but insufficient for a shared port or
rail. For example, A connected through alternatives {A,B} to B can pass adjacent
intersections while lacking one common selection. The compiler must check the
intersection across the relevant connected set before presenting a complete
power result. Do not pick a different reference independently at each hop.

Build an undirected port graph from power connections. Known non-power pairs
are outside this stage; unresolved endpoints remain included as potential power
endpoints so missing evidence cannot disappear. Port keys remain structured
instance/port pairs. On this physical-connection graph, check common
`pinout.contract`, `connector.contract`, `protection.contract` and
`strain_relief.contract` alternatives across each connected component.
This also handles a source port with several attached targets.

For `reference.contract` and `polarity`, additionally tie the input port to
each connected output of a component explicitly declaring `power.mode`
`passthrough`, exactly one ordinary sink and at least one ordinary source,
without bidirectional power ports. The declaration means one common DC rail;
internal pinout/connector conversion remains permitted and separately qualified.
Inactive output ports do not constrain the selected path. Active converters do
not get an implicit same-reference tie. Missing/unsupported mode or topology
retains its separate power-mode finding; graph connectivity cannot qualify it.

Every rail's polarity must be a single positive or negative term at each port.
Other/multiple polarity terms stay unknown scope. For each contract component,
intersect all usable term sets. Disjoint known sets are incompatible even when
another member is missing; an unknown member cannot repair a known conflict.
Otherwise any unusable member prevents agreement. Complete nonempty agreement
retains the sorted common alternatives in the finding. Keep every participating
port's exact pin/path/source readings and the build connections used to derive
the component; a matching term still does not establish registered support.

The shared port-connectivity primitive accepts at most 576 structured nodes and
512 edges: 512 physical endpoints plus at most one added pass-through input per
instance, and 256 physical edges plus at most 256 connected-output ties. Validate
node identifiers/uniqueness and reject dangling edges or exceeded bounds. Treat
edges as undirected, deduplicate parallel/reversed edges, and preserve isolated
nodes in the generic primitive. Sort components and their members by instance
then port, independent of input order. Bounded visited traversal must terminate
on loops. Verify all 512 three-vertex directed edge subsets against an independent
undirected closure oracle, plus maximal chains and malformed limits.

Stage tests must include pairwise-compatible/global-inconsistent alternatives,
source fan-out, multi-hop pass-through reference conflicts, unknown intermediate
facts, known conflicts with missing members, polarity mismatch, deterministic
order and ordinary converters separating their two reference domains. These
checks precede pass-through voltage/current propagation and qualified contract
admission; they do not replace either obligation.

### Passive DC flow and rating checks

Extend the declared mode model with `passthrough`: exactly one ordinary power
sink, one or more ordinary power sources, no bidirectional power port, and no
active current consumption or voltage conversion. A contradictory known port
topology is incompatible. This is a declared passive model, not measured truth.
The connected reference/polarity checks above and qualified wiring contracts
remain mandatory; a mode cannot bypass either requirement.

A passive output's `voltage.drop` is a sourced nonnegative millivolt interval
covering its entire admitted input/current/temperature envelope, including its
internal wiring path. Its `output.voltage` is the permitted output envelope
over that scope, not an independently regulated source. Both are required.
Input voltage uses the sink's existing `input.voltage`. Do not infer zero
resistance/drop, subtract a typical value, or narrow an unsupported result to
make a receiving device fit.

For a connected passive output, require exactly one incoming connection at its
input. Follow that connection toward an ordinary source or active converter.
The ordinary source/converter supplies its sourced output envelope. At each
passive hop, compare the arriving envelope with the input's permitted interval;
require the greatest drop not to exceed the least arriving magnitude; subtract
the drop interval (input lower minus drop upper, input upper minus drop lower);
then require the result to fit the passive output's permitted envelope. Emit
separate input-range, drop-headroom and output-range findings with numeric
operands and all upstream source/mode/path evidence. If any required value,
feed or scope is missing/unsupported, or a local bound fails, the effective
output remains unknown. Do not clamp a negative result to zero or silently
intersect it with the declared output range. Paired voltage checks consume this
effective output, so an adapter's static label cannot reset upstream uncertainty
or a cumulative voltage drop.

For input demand, a consumer or active converter uses its sourced full-envelope
`current.maximum`. A passive component sums the demands on all connected
outputs recursively. Its own static `current.maximum` is not a substitute for
those downstream loads. A passive output with no connection contributes zero
only because the declared mode has no active consumption. A missing load,
unsupported endpoint, multiple input feeds or a cycle keeps the aggregate
unknown. The single input prevents merging paths from counting one downstream
branch repeatedly; malformed multiple feeds are refused from known demand.

Feed checks require exactly one incoming connection for converters and passive
components, even if their sink's profile flag is optional. A consumer requires
at least one connected sink, and every required sink must have a single feed.
Optional unconnected alternative inputs remain unused; connected alternatives
still receive independent interface/feed checks. These rules supplement the
profile's required-port declarations so active conversion cannot run on an
unconnected optional input.

Compare each passive input's derived current against its exact
`current.capacity`; compare arriving voltage times derived current against
its `power.capacity`, using the same floor/ceiling milliwatt conversion as
output budgets. Output/fan-out/shared-component budgets use derived current and
effective output voltage. Current and power ratings, shared output limits,
operating-temperature/thermal constraints and complete source/load obligations
remain distinct. A converter's input continues to use its declared full worst
case; do not infer efficiency or lower its budget from a lighter selected load.

Carry exact profile/port/connection references and source readings through each
flow trace. Traversal follows at most 64 instances with an explicit visited set;
loops, multiple feeds, absent/unsupported modes and unresolved endpoints end in
an explained unknown trace. The structural power-cycle check still supplies its
incompatible finding. Single-feed passive branches bound each traversal by the
256-edge graph; cache mode lookups per resolution. Derived current, voltage and
power retain the integer bounds in the direct-budget contract. No I/O, iterative
unbounded circuit solver or arbitrary rule expression enters the calculation.
Deduplicate repeated evidence with bounded immutable membership state while
preserving first-occurrence order. Never derive report order from hash-map
iteration or discard distinct observations that happen to name the same fact.

Tests must cover multi-hop cumulative drops, source uncertainty, insufficient
headroom, out-of-range input/output envelopes, missing/wrong-unit drops, static
output labels that cannot replace derived voltage, branching current, repeated
loads, zero-draw concealment, input ampacity/power limits, missing/optional feeds,
cycles and maximum chains on both targets. Include parity for generated passive
chains and branch budgets and independent arithmetic replay. No flow finding
is a complete electrical or assembly admission.

### Operating temperature and enclosure thermal budget

The thermal stage consumes the same exact resolution and enclosure selector as
geometry. It produces conditional numeric findings and a declared thermal-scope
agreement. Source qualification and actual assembly thermal evidence remain
mandatory separate admissions. A thermal watt budget alone cannot establish
component temperature or unattended-use safety.

`temperature.operating` means the complete permitted **local ambient** range
at that component in millicelsius, including applicable operating conditions.
Junction, case, storage, absolute-limit or condition-specific temperatures must
use different properties and cannot replace it. For each external instance and
the enclosing frame, compare the installation's entire `intent.ambient_mc`
range with this operating range. This tests the installation environment only.

For each internal instance, require sourced `temperature.ambient_rise`: a
nonnegative millicelsius interval for local ambient rise above installation
ambient in the declared assembly thermal scope. Its admitted input range is
0–300,000 m°C. Derive local ambient as installation lower plus rise lower and
installation upper plus rise upper, then require that entire interval inside
`temperature.operating`. A missing rise never becomes zero. Do not substitute
self-heating junction rise or an unrelated open-air measurement. Active cooling
below installation ambient is outside this nonnegative-rise model and needs
separate reviewed semantics. Derived bounds are −100,000–600,000 m°C and remain
exact integers; a derived upper bound above the sourced operating range fails.

Read `heat.maximum` from the enclosing frame and every internal instance.
This is a sourced complete heat-dissipation envelope in milliwatts over the
admitted configuration, including the conditions relevant to the thermal
assessment. Passive frame/mat/wiring parts need an explicit sourced zero or
their applicable contribution; missing heat cannot disappear from the sum.
Repeated instances contribute separately. Do not replace heat with electrical
input/output power or infer converter loss. External instances do not consume
the enclosure's dissipation budget; their local operating-range checks remain.

Require the sum's upper bound not to exceed the enclosing frame's least
`thermal.capacity`, and require the entire installation ambient interval within
the frame's `thermal.ambient`. Capacity is the documented dissipation envelope
for the exact declared thermal scope and admitted ambient conditions. It is
not a generic material constant or permission to combine unrelated measurements.
The thermal sum has at most 64 contributions and a 64,000,000 mW upper bound.

Every contributing instance, including the enclosing frame, supplies sourced
`assembly.thermal` contract alternatives. Require a common intersection across
all contributors. Known disjoint alternatives are incompatible even when another
contributor is unknown; otherwise a missing/conflicting/unusable reading keeps
the agreement unknown. Retain sorted common alternatives only for a fully known
agreement. Reuse this exact set-agreement rule for other declaration stages.
The later qualification registry must bind a selected thermal contract to exact
parts, placements, enclosure/ventilation, loads, operating conditions and test
evidence. A matching arbitrary string cannot satisfy that registry obligation.

Emit separate enclosure, per-instance operating-temperature, ambient-scope,
heat-capacity and declared-contract findings. Include installation intent and
instance/location/placement references, exact profiles, source readings, and
required/available intervals. Unknown/conflicting values remain explicit.
The absence or ambiguity of an enclosing frame prevents a known capacity;
preserve the selector's reason rather than choosing another part's rating.
No thermal solver, network request or inference runs in this pure stage.

Acceptance includes negative installation temperatures, exact boundaries,
internal rise, missing/incorrect-unit/condition-only facts, known excessive
heat, repeated loads, external exclusion, incomplete profiles, ambiguous
enclosures, global scope conflict with unknown members and the 64-instance
limit. Generated thermal fixtures must agree across BEAM and JavaScript and
with independent extreme-choice enumeration of temperatures and heat sums.

### Declared mounting paths and supported mass

Mechanical connections point from a support provider's ordinary source port
to the supported component's ordinary sink port. This represents a complete
qualified joint, which may include several fasteners. It does not divide a load
between individual screws, infer force/torque distribution or prove adhesive,
substrate, seismic or impact performance. Those conditions belong to the exact
qualified mounting contract. Bidirectional joints remain unsupported unknown.

Every physical instance supplies a sourced `mass` interval in grams and exactly
one `mount.mode` term. Mass covers that physical instance, excluding separately
modeled children; a kit's gross mass cannot be substituted and counted again
with its children. The supported modes are:

- `supported`: exactly one mechanical sink, zero or more mechanical sources.
  The sink must have exactly one incoming feed even when its optional flag is
  false. Multiple supports need a qualified grouped interface; do not split,
  average or duplicate demand between separate incoming connections.
- `anchor`: no mechanical sink, zero or more mechanical sources. The instance
  is outside the frame or is the enclosing frame with a documented integrated
  anchoring arrangement. An internal part cannot declare itself independently
  anchored. Each anchor requires sourced `mount.contract` alternatives for its
  installation boundary; the qualification registry still must admit them.

Missing, ambiguous or unsupported modes are unknown. A known mode with an
inconsistent port topology or an internal anchor is incompatible. Every
internal instance and the enclosing frame must reach an anchor by following
its support path backward. Require that anchor's sourced `mount.kind`
alternatives contain the intended `wall` or `stand` installation. External
equipment may have an independent anchoring arrangement; it still requires
mass, mode, applicable feed and anchor-contract evidence, but its separate root
does not override the frame's installation intent. Unresolved endpoints,
unsupported direction/scope, missing or multiple support feeds and cycles
produce explained unknown paths. A separate mechanical-cycle check reports
known directed cycles as incompatible, including cycles with no anchor.

The mass at a supported component's input is its own mass plus all masses
carried by its connected mechanical outputs, recursively. Unknown contributors
make the complete demand unknown. A leaf has its own mass; a missing mass never
becomes zero. The single-input rule prevents counting a shared child repeatedly.
Compare this complete subtree mass with the supported sink's `mount.capacity`.
For each connected provider output, compare the sum of its supported subtrees
with that source port's `mount.capacity` and the connection count with its
`fanout.maximum`. Compare the sum across a provider's used outputs with its
component `mount.capacity`. These output/shared capacities rate supported
payload; the provider's own mass enters the demand on its parent. An anchor's
own structure and mounting to its substrate remain within its qualified
installation contract. No numeric rating substitutes for that evidence.

Require common `mount.pattern` and `mount.contract` alternatives across each
connected group of mechanical ports. Check the entire fan-out group, not just
adjacent pairs. Input and output ports on an adapter may legitimately have
different patterns/contracts; its own mode, mass, ratings and qualified
component mapping must cover that conversion. Matching arbitrary declarations
does not qualify a joint or anchor. Required mechanical ports still receive
the graph stage's required-port checks; optional flags cannot remove mode feed
obligations. Electrical strain-relief obligations remain separate.

Emit exact source evidence, input references and numeric demand/capacity
operands for mass presence, modes, feeds, paths, installation kind, anchors,
interfaces, cycles and per-port/shared ratings. Follow at most 64 instances and
256 connections with visited traversal; a valid tree has at most 64 unique
mass contributions and at most 6,400,000 g derived demand. Invalid merging
feeds are unknown before any subtree summation. Preserve exact integer results
on both targets without a general statics solver or rule evaluation language.

Acceptance covers frame/part/adapter mass, repeated profiles, branching and
shared limits, optional/multiple/missing feeds, no-anchor cycles, internal anchor
bypass, incompatible installation kind, absent profiles/ports, global pattern
conflict, unknown mass and maximum chains. Generated trees must match across
targets and an independent descendant-set mass oracle. Assembly and joint
qualification remain separate from these conditional load calculations.

### Signal interface declarations

For every connection involving a signal port, check distinct instances,
ordinary source-to-sink direction and signal kind at both ends. Preserve
unresolved profiles as unknown; absent named ports, known kind/direction errors
and self-connections are incompatible. A bidirectional port is unknown under
this ordinary directed model. Connections known to involve only other port
kinds are outside this stage.

The existing signal-port `logic.voltage` property is a sourced complete
nonnegative pin-voltage operating envelope relative to the declared reference.
At a source it bounds the voltages produced over the admitted conditions; at a
sink it bounds the accepted operating envelope. Require the source interval
wholly inside the sink interval. A nominal logic-family label, supply rating or
an absolute-maximum limit cannot replace this property. Only singleton positive
polarity is supported by this unipolar envelope model; negative, AC and ambiguous
polarity remain unknown. Signed/differential signaling requires a qualified
mapping that explicitly covers its conditions and appropriate modeled bounds.

Build undirected groups of the actual connected signal ports and require a
common declaration across each complete group for `polarity`,
`reference.contract`, `pinout.contract`, `connector.contract`,
`protection.contract`, `driver.contract` and `strain_relief.contract`. Use the
same known-conflict-before-unknown rule as power/mounting. Retain common terms
only for fully known agreement. Do not infer an internal connection between an
adapter's ports from similar names, a family label or the existence of both.

These are necessary interface declarations and voltage-envelope checks.
Logic thresholds, loading, termination, timing, protocol sequencing, internal
adapter mappings and executable driver/firmware support require the later exact
qualified contract admission. In particular, an adapter's static output label
does not establish a valid upstream route. The whole compiler must enforce
complete controller/driver/display routes through admitted mappings; these
local results alone cannot establish them or produce whole-build acceptance.

Emit per-connection structure and voltage findings and per-group declaration
findings with exact port/profile/connection evidence and numeric operands.
Preserve source uncertainty and conflicting facts without borrowing neighboring
nominal/conditional fields. Work within the canonical 64-instance/256-edge
limits and the existing bounded port-group primitive. Tests must cover voltage
containment, unknown/conflicting/incorrect-unit facts, polarity, driver and
reference mismatch, invalid endpoints, bidirectional scope, global alternatives,
known conflict with unknown members and the maximum connection count on both
targets. No network, source fetch or inference enters these decisions.

### Directed display routes and explicit internal mappings

The signal-route stage proves directed reachability under an explicitly supplied
mapping set. It is a necessary structural check; external assessment must still
admit every mapping, endpoint driver, electrical interface and operating scope.
No profile label or successful path can supply that authority. Public compilation
must resolve mapping bytes and admission separately before using this stage.

An internal mapping names its content identity, exact profile pin and selected
artifact, firmware and protocol contract IDs. It lists local input/output port
pairs. Every pair joins an ordinary signal sink to an ordinary signal source on
that same profile. Each output has exactly one mapped input; one input may feed
several outputs. Combining input streams, bidirectional routing and implicit
cross-connections are unsupported. A display with a data output may have an
explicit mapping for a daisy chain; belonging to one component never implies
that its ports are internally connected.

The internal typed boundary accepts zero to 64 mappings and at most 256 local
pairs in total, including after expansion over repeated physical instances.
Identities use the existing SHA-256 pin syntax; contract and port
IDs use the existing bounded identifier syntax. Duplicate mapping identities,
duplicate profile/runtime selections, duplicate pairs or outputs, wrong runtime
scope, unreferenced/missing profiles and nonexistent/wrong-direction ports are
refusals. The external resolver must recompute the mapping identity from its
canonical bytes; the typed stage cannot authenticate a caller-provided digest.
Use one selected mapping revision per profile and runtime scope. Every repeated
physical instance applies that same mapping to its own ports.

For each display, check every required signal sink and every connected ordinary
signal sink, including ports marked optional. At least one sink must be checked.
Obtain its unique declared controller through the mandatory owner rule. Trace
each sink backwards through exactly one ordinary physical connection, then
through an explicit internal mapping, until reaching a controller's ordinary
signal source. Every sink on the route needs exactly one incoming connection;
multiple feeds are unknown without a supported combining contract. Missing
wiring, endpoint profiles, mappings or owners remain unknown. A resolved root
controller different from the declared owner is incompatible. A known invalid
physical edge is incompatible under the shared endpoint rules; bidirectional
scope remains unknown. A route cannot stop at a non-controller's output label.

Track visited structured port endpoints. A repeated endpoint is an incompatible
route cycle, even when that cycle also has an unrelated valid output elsewhere.
The assembly's 256 connections plus at most 256 internal pairs bound traversal
to 512 edges; at most 1,024 distinct endpoints can occur. No recursive search
enumerates alternative paths: ambiguous incoming feeds stop with unknown.

Findings retain the display and declared/resolved controller, every traversed
physical connection and profile port, ownership dependencies, selected runtime
intent, and exact mapping identity/local pair. Mapping inputs have their own
reference type; they cannot masquerade as profile facts. Source/evidence tables
in the complete report resolve those references from the admitted registry.
Acceptance covers direct and adapted routes, wrong roots, optional/missing
feeds, ambiguous feeds, loops, repeated profiles, changed runtime/profile scope,
malformed maps and maximal chains on both runtimes. Whole-build qualification
and canonical mapping resolution remain required work.

### Canonical signal-mapping revisions

A portable signal-mapping revision is an immutable sourced document, distinct
from its catalog approval and from the physical assembly. Its schema-1 root
contains exactly `artifact`, `firmware`, `pairs`, `profile`, `protocol`, `schema`,
`sources` in that order. Runtime IDs and port IDs use the profile identifier
syntax; `profile` is one exact profile content pin. `pairs` contains one to 256
objects with `input`, `output` fields. Outputs are unique, each pair's two ports
must differ, and the array sorts by its canonical object bytes. More than one
output may share an input. Port existence, direction, kind, selected runtime and
the 256 expanded-pair budget are checked against the resolved build separately.

`sources` contains one to eight distinct source references with the same
digest/evidence/locator/revision fields, validation and canonical ordering used
by profiles. These citations describe the complete mapping and selected runtime
scope. A syntactically valid citation neither authenticates a document nor
admits a driver. Do not encode approval, expiry, revocation, mutable labels,
credentials, market data or inferred hardware claims in the mapping document.

Reuse the profile document's ASCII, 262,144-byte, depth-16, decimal-integer and
exact-reencoding requirements. Canonical output ends with one LF. Refuse missing,
duplicate or unknown fields, noncanonical order/escapes, malformed or duplicate
ports/sources, unsupported versions and resource-limit violations. Typed export
sorts set-like collections. Import/export works without a catalog or network.

The identity is SHA-256 after the domain prefix
`frameshift.signal-mapping.v1\n`, using the same `sha256:<lowercase hex>` form.
Standard OTP/Web Crypto adapters validate canonical bytes before hashing and
never accept a caller-supplied identity as authentication. Browser cryptography
failure returns `crypto_unavailable`. Inspection exposes the exact profile pin,
runtime selections and source references for catalog binding. Physical assembly
identity remains unchanged; the complete compilation/accepted BuildSpec must
pin these additional mapping identities and invalidate assessments when any
selection changes. A mapping identity alone is not registry admission.

Acceptance includes both-target byte/hash parity, source/runtime/profile changes,
ordering, port/source uniqueness, malformed bytes and boundary mutations,
untrusted adapter types, absent cryptography and release packaging. Exact mapping
selection and independent admission remain obligations of compilation context.

### Verified compilation context

The `resolve_context` / `resolveContext` adapters accept canonical assembly bytes,
zero to 64 profile bodies, zero to 64 signal-mapping bodies and an optional zero
to 64 [artifact-layout bodies](build-artifacts.md). Enforce one shared
4,194,304-byte UTF-8 budget over all input documents, with the existing
262,144-byte limit per document, before decoding or cryptography. Reject
non-string entries and oversized collections. Compute every assembly, profile
and mapping digest from validated bytes through the standard adapters.
Browser adapters snapshot the bounded string collections before asynchronous
hashing; caller mutation cannot change the inputs that passed preflight.

Apply exact profile resolution, then decode mapping revisions and validate their
profile/runtime/port selection through the directed-route boundary. Refuse
duplicate identities, competing mappings for one profile/runtime scope,
unreferenced or unresolved mapping profiles, stale runtime selections and
invalid ports or expanded-pair counts. Return mappings sorted by identity with
their complete source references. Missing profile pins remain explicit when no
mapping claims to resolve them. An empty mapping collection is valid planning
input; it cannot supply an absent internal route.

The adapter returns both assembly identity and compilation-context identity.
Context canonical bytes contain `assembly` (computed assembly pin), `bindings`
(sorted canonical objects with `identity`, `kind`), `compiler` (the assembly's
semantics identifier) and `schema` (`1`), in that order, followed by LF. The
supported binding kinds are `signal-mapping` and `artifact-layout`; later supported contract
types require their own reviewed codec and compiler integration. Hash after
`frameshift.compilation.v1\n`. This context records exact contract choices;
changing mapping content, sources or selection changes context identity without
rewriting the physical assembly document. Document-list input order has no
effect. Missing profile bodies do not change the selected assembly's identity;
the complete result must still record unresolved pins and remain unknown.

The internal pure resolver receives adapter-computed identity/byte pairs, never
performs I/O and never authenticates caller-provided digests. Context resolution
does not admit cited evidence, qualify a driver, run constraints, or grant
purchasing eligibility. Browser results are reproducible planning output; the
server must resolve its own exact inputs and current assessments. Complete
reports and accepted records pin context identity and record compiler semantics.

Acceptance covers actual adapter-computed pins, mapping/source mutation,
permuted input collections, stale profile/runtime/port choices, empty and
unresolved plans, duplicate mappings, mixed-document resource limits, unavailable
cryptography and equality of canonical context bytes/hash across runtimes.

### Runtime intent, dwell and storage allocation

Exact canvas assignment, wire size and retained payload budgets follow
[Build artifact layouts and storage footprint](build-artifacts.md). They are
mandatory alongside the configured-budget checks in this section.

The operation stage applies installation intent to known controller and display
instances. Require at least one resolved controller and one resolved display;
an absent role is an incomplete/unknown build, and an unresolved instance gets
an explicit classification-unknown finding. Exact profile kind is required;
labels and declared dependencies cannot impersonate it. These role counts do
not prove the required controller-to-display route or satisfy its later exact
qualified mapping.

Every resolved controller must declare support for the selected
`intent.artifact`, `intent.firmware` and `intent.protocol` registry identifiers
through its exact component `artifact.contract`, `firmware.contract` and
`protocol.contract` alternatives. A known set excluding the selected identifier
is incompatible; a missing/conflicting/unusable set is unknown. These identifiers
name shared assembly contracts, which may map to different exact binaries or
drivers per component. Equality alone does not admit a firmware image, artifact
decoder or protocol implementation. No family-name or latest-version fallback
may satisfy the selection.

Both controllers and displays require sourced hard `refresh.minimum` and
`refresh.maximum` bounds for admitted completed still-update spacing. Compare
the largest required minimum with `intent.dwell_ms`, and the requested dwell
with the least permitted maximum. Uncertain bounds apply in the conservative
direction. Zero is a numeric bound, never an unlimited sentinel. A missing
maximum cannot silently become unlimited. `refresh.recommended_minimum`,
`refresh.recommended_maximum` and `refresh.energy_recommended` remain separate
advisory facts; their absence or an operator's departure from them cannot cause
a hard compatibility failure. A recommendation does not establish measured
energy benefit. Preserve the [display-timing contract](display-timing.md) for
native receiver policy and re-admission; a planning result does not override it.

Each controller needs an explicit usable storage budget at least as large as
`intent.storage_bytes`. If it has no `storage` dependency, read its own component
`storage.capacity` as integrated storage. If it has exactly one such dependency,
the selected provider must resolve to kind `storage`; read that instance's
capacity instead. Do not fall back to integrated storage if the selected device
is missing or too small. More than one selected provider is unknown under this
single-store model. A provider referenced by more than one distinct consumer
through storage dependencies is unknown without an explicit partition model;
do not give every consumer its whole capacity or invent a split. Separate
physical instances of one profile remain separate devices.

`storage.capacity` means guaranteed usable bytes dedicated to the still-artifact
store under the selected firmware/storage contract, after reserved space and
overheads. Nameplate/raw-chip capacity, current free space and optional labels
cannot replace it. A wrong known provider kind is incompatible; a missing
provider/profile/fact is unknown. Required connections, mounting, qualified
storage/firmware mapping, exact artifact size and atomic retention space remain
mandatory independent obligations. The configured request does not by itself
prove that every selected artifact or rollback copy will fit. Actual receiver
capacity is admitted again through the installed protocol.

Findings retain the selected intent field, instance/profile kind and storage
dependency references, exact capacity/contract/refresh facts and numeric
operands. Keep within the existing 64-instance/256-dependency, seven-day planning
dwell and 2^40-byte bounds; no storage pool, clock, provider call or inference
enters this stage. Acceptance covers missing roles/profiles, excluded or unknown
contract identifiers, exact and uncertain dwell limits, advisory non-substitution,
integrated versus selected storage, insufficient/unknown/wrong-kind devices,
multiple/shared storage, repeated device profiles and maximum byte/dwell bounds
on both targets.

### Mandatory physical obligations

The complete compiler must enumerate these obligations independently of a
profile's optional ports or `requires` list. Declaring an empty list cannot
remove a physical or runtime requirement. Missing evidence is unknown;
known contradictory roles or bounds are incompatible. This stage supplements
the graph and physical stages rather than replacing their detailed checks.

- Every selected instance, including the enclosure and external equipment,
  requires sourced positive `outline.width`, `outline.height` and
  `outline.depth`. The existing mounting stage requires each instance's mass.
  Internal service clearances remain the geometry stage's six directional
  envelopes; do not require redundant scalar clearances as substitutes.
- Every resolved kind `frame` requires its cavity's greatest
  `inner.width/height/depth` not to exceed the corresponding least outer
  `outline.width/height/depth`. This is necessary dimensional consistency and
  does not infer cavity offset, wall strength or measured material behavior.
- Every display requires positive exact `raster.width` and `raster.height`
  counts. An interval containing more than one count is unknown for an exact
  artifact/protocol mapping; do not silently choose its nominal or upper count.
- Display, controller, driver and separate storage components require an
  ordinary connected power sink and declared `consumer` or `converter` power
  mode. Missing ports/connections or unknown scope is incomplete. A known
  `source` or `passthrough` declaration on one of these powered roles is
  incompatible with this separate-component model. An integrated battery or
  supply must be represented by its physical power-source constituent and
  honest component mass/geometry, not an unpowered controller label.
- A declared ordinary power `source` must be kind `power`. Require at least one
  resolved source with a connected source port. This gives the selected frame's
  update path an explicit energy source; it does not assert energy duration or
  prevent Paper retaining an image after power removal. Batteries, external
  supplies and an existing host's power output remain explicit sourced parts.
  Converter/pass-through feed and cycle checks still apply to every path.
- Displays, drivers and separate storage require at least one connected
  ordinary signal sink; controllers and drivers require at least one connected
  ordinary signal source. Missing wiring is unknown. Direction, voltage and
  contract checks remain separate and cannot be replaced by a port count.
- Every display declares exactly one `controller` role dependency for its
  runtime owner, even if its profile omits that required role. The provider
  must resolve to kind `controller`. Missing or multiple owners are unknown;
  a known wrong kind or self-owner is incompatible. All displays may share one
  controller, or have separate controllers. The later qualified signal-route
  stage must prove that actual connected paths reach the declared owner;
  a dependency alone cannot establish the physical path.

Kinds `assembly` and other composite purchases do not waive constituent
requirements. Their physical constituents and responsibilities must be modeled
explicitly without duplicate mass/BOM accounting. An `assembly` placeholder
stays unknown until expanded into its physical constituents before compilation;
commercial kit grouping belongs outside the physical-node inventory.
Kind `power` also requires a valid declared power mode and its matching port
topology even when no port or dependency was supplied. An unresolved profile emits
unknown classification and required-size readings; it is never dropped from
the obligation set. Fields required by thermal, mounting, operation and interface
stages remain required as well, even when a profile leaves them absent.

Retain exact instance/profile/kind, intent, port, connection and dependency
references with each finding. Presence checks describe required modeled data,
not qualification of the source. No data-controlled list selects which compiler
stages run. Acceptance includes empty `requires`, all-optional ports, missing
physical roles, orphan/multiple/wrong controller owners, source-role disguise,
missing exterior dimensions, impossible cavity bounds, ambiguous raster counts,
unresolved profiles and maximum instance counts on both targets. Complete
qualified mappings, artifact footprint, assessment authority and canonical
whole-build reports remain separate required compiler work.

The retained v1 compiler may expose a pure **planning preview** over one
resolved compilation context. It runs every implemented frame constraint stage
in a fixed order, retains each stage's findings and input references, and
propagates a typed structural refusal instead of dropping a failed stage. A
known incompatibility makes the preview `incompatible`; otherwise its status is
`unknown`, including when all implemented findings are compatible. Missing
source/current-use assessment, qualified runtime and mechanical/thermal
evidence, formal evidence where claimed, and Conjunct's purpose-bound
CheckReport prevent this preview from granting build or purchase admission.
The caller must still verify source bytes and identity pairs through the
standard crypto adapters before presenting a public preview. A preview does
not mint a new identity or modify historical v1 identities.
This retained path supports old-byte replay, frame-rule regression and explicit
migration. It is not a new workbench authoring/comparison engine or a substitute
for Conjunct's canonical composition, parts projection and purpose-bound
CheckReport. New generic workbench decisions and instruction output consume
qualified Conjunct producer operations; missing exports remain unavailable.

### Bounded physical arithmetic v1

The first shared physical module exposes typed arithmetic primitives; the
BuildSpec compiler must attach part/revision/source references to their results.
These primitives alone cannot produce assembly or purchasing admission. Wire
schema, profile admission, graph constraints and canonical hashing remain
separate requirements.

Use integer micrometres for geometry, millivolts for voltage, milliamperes for
current, milliwatts for power and grams for mass. Accept decimal millimetres
only as ASCII strings with at most three fractional digits, no exponent,
separator, sign or whitespace. Convert exactly to integer micrometres; reject
more precision rather than rounding. No float enters a physical calculation.

A fact is explicitly known with nonnegative integer lower/upper bounds, missing,
or conflicting. A nominal value and symmetric tolerance normalize to those
bounds; tolerance must not exceed the value.
Values and their upper tolerance bound must fit the relevant domain ceiling:
geometry 5,000,000 µm; voltage 300,000 mV; current 100,000 mA; power 1,000,000 mW;
mass 100,000 g.
These are software input ceilings, not permitted operating ratings. Every sum
or product must remain within 9,007,199,254,740,991 on both runtimes.

The bounded primitives must cover:

- A uniform grid of one to eight rows/columns, including every module outline,
  inter-module gap and two-sided service clearance. Use greatest required
  extent against least available frame opening. Mixed modules require an
  explicit future layout or return unknown; never average their outlines.
- A stack of one to 64 depth contributions (panel, carrier, board, backing,
  connector/cable and service envelope supplied by the compiler). Compare
  greatest stack depth against least available depth.
- Aperture width/height against least available active area.
- One-to-64 load contributions against least rated capacity, in one consistent
  unit. The compiler must construct distinct electrical rails and mounting
  loads; the primitive cannot combine unrelated capacities or voltages.
- Supply voltage interval wholly contained in the consumer's admitted input
  interval. Mere overlap is insufficient.

Each primitive returns a compatible/incompatible/unknown decision with a stable
reason and, when known, required/available worst-case values. Missing and
conflicting facts remain distinct unknown reasons. Invalid counts, malformed
ranges, unsupported precision or overflow are input refusals, not compatible
results. A failed known constraint dominates unknowns when aggregating a set;
otherwise any unknown prevents compatibility. An empty constraint set cannot
be called compatible. Provenance and completeness of the constraint set remain
the compiler's responsibility.

**PB-05 — Existing product contracts.** Reuse protocol/profile identifiers and
existing bounded decisions without conflating physical configuration with
paired-device admission or exact render/transfer qualification. A shopping
list may provide non-secret installation hints. The installed host re-admits
the actual device and capabilities through its authenticated flow. New parts
using existing qualified contracts may be data additions; a new protocol,
electrical driver, artifact format, or executable capability needs code and
conformance evidence. A profile alone cannot make arbitrary hardware work.

## Deterministic implementation and formal verification

**PB-06 — Retained v1 Gleam boundary.** Maintain the existing pure Gleam
implementation for v1 replay, frame-specific obligations, regression and
migration on BEAM and JavaScript. Normalize data at explicit boundaries. It
owns no database queries, source extraction, policy authority, I/O, clocks,
randomness or inference. Its browser preview is non-admitting; it must not grow
into a parallel generic composition, comparison or instruction kernel. The
Conjunct producer owns those successor operations and their qualified browser
and server bindings. The server recomputes accepted compositions from pinned
facts and current admission. Cross-runtime fixtures preserve v1 unit conversion,
limits, ordering, refusals and canonical output through the migration.

**PB-07 — Targeted ExMaude verification.** Use ExMaude for CI and asynchronous
catalog/rule admission, off the ordinary browser preview path. Frameshift owns
frame predicates and fixtures under the current `packages/build-spec/verification/`
boundary when implemented. Generic physical predicates belong in Conjunct;
consumer replay still verifies the actual Frameshift profile. No formal module
or producer integration is claimed by this target path.
Check finite bounded composition properties, including:

1. Required interfaces/power/mounting constraints cannot be bypassed by an
   adapter chain or a circular dependency.
2. Missing, contradictory or quarantined required facts cannot yield admitted
   purchasing eligibility.
3. Part substitutions and changed constraints invalidate affected prior proof
   and quote eligibility rather than modifying accepted commitments.
4. Accepted part/revision identities remain immutable across new catalog or
   workflow generations.

Generate normalized facts and fixtures from shared schemas, but review formal
predicates independently from production decision code. Replay counterexamples
against the actual compiler and use deliberately broken-rule mutations to show
the verifier detects relevant faults. A duplicated implementation with the same
bug is not independent evidence. Formal results cover the model, assumptions,
and explored bounds; they do not prove supplier truth, unmodeled physics, or
certification.

Use the default Port backend and separate Maude OS processes in a small bounded
pool. Set CPU, memory, time, output and concurrency limits and prove termination
on overrun. Only reviewed modules and validated encoded data enter Maude.
Research documents/profile strings cannot supply executable source. Retrieve
witnesses/traces from the same worker session as the search that produced them.

**PB-08 — Result and invalidation contract.** The inspected ExMaude list-returning
search API does not establish exhaustion. Extend the generic upstream API with
typed completion evidence before admitting results:

| Outcome | Meaning and admission consequence |
| --- | --- |
| `counterexample` | A violation with replayable witness; reject the affected admission |
| `no_counterexample_within_bound` | No violation within recorded limits; cannot claim exhaustive verification; admit only where the invariant's reviewed policy explicitly accepts that bound |
| `exhausted_finite_model` | Search completed over the declared finite model; satisfies only the named modeled invariant |
| `inconclusive` | Timeout, truncation, malformed response, worker loss, unsupported semantics or missing completion evidence; cannot satisfy a required check |

Store fact/spec, model, invariant, tool/executable and rule versions/digests,
finite assumptions, bounds, search outcome, trace and replay result. Cache keys
include all semantic inputs and invalidate when any relevant input changes.
Current revocations are checked separately even on a proof-cache hit. Do not
treat an empty solution list as proof or collapse bounded/inconclusive outcomes.
ExMaude's generic result/session support belongs upstream under
[PC-04](producer-contracts.md). Conjunct owns generic physical predicates;
Frameshift retains frame assumptions, product regression fixtures and admission
policies. Track the separate Maude executable's
license/distribution obligations for the exact deployed version.

## Required software evidence

**PB-09 — Acceptance.** Full C completion requires reproducible fixtures for
all three classes.

A single claimed profile may pass its applicable C gate and feed its D
instruction slice first. Synthetic complete assemblies and sourced candidates
with explicit unknowns are separate fixtures. Full C completion still requires
all three classes. ExMaude P2 is required for formal-evidence claims; it does not
block deterministic compiler/viewer development while the producer is built.

Required checks for each claimed profile are:

- schema size/unit/overflow/version refusals and source-revision round trips;
- identical canonical bytes/hash across BEAM/JavaScript and reload/export;
- generated valid/invalid/unknown combinations and minimal typed explanations;
- independent formal predicates, mutation detection, trace replay, finite-bound
  and exhaustion distinction, timeout/truncation/worker-loss handling;
- proof invalidation after fact, rule, tool or quarantine changes;
- no silent accepted-spec mutation after candidate admission or substitution;
- browser/server disagreement refusal and profile-to-protocol mapping checks.

Physical measurements and external compliance evidence remain accurately
unqualified until recorded. They do not prevent implementing unknown/refusal
paths, complete simulators, or independent planning and instructions.
