# Physical build contracts

Pure shared profile and assembly types, validation and canonical bytes for BEAM and
JavaScript. Physical arithmetic comes from `../decision-kernel`; there is no
application, database, network, model, clock or purchasing dependency.

The [physical contract](../../docs/architecture/physical-build-contract.md)
owns the format, limits and remaining composite compiler requirements. The
current codec accepts immutable component profiles with sourced numeric bounds,
capability terms, ports, required roles and explicit missing/conflicting facts.
Manufacturer part revision and catalog profile revision are separate fields.
A valid profile is not an accepted assembly or an eligible purchasing route.

This package is the retained Frameshift implementation during
[Conjunct integration](../../docs/architecture/conjunct-integration.md).
Generic composition, comparison, check aggregation, catalog projection and
instruction semantics belong to Conjunct. This package keeps v1 replay and
regression plus frame-specific obligations and fixtures until each qualified
producer export and consumer migration pass. It is not a successor workbench
engine. Frame artifact layouts and product-specific qualification remain here.
The existing ASCII v1 bytes/hashes remain replayable. Conjunct's selected
UTF-8/rational wire profile needs an explicit versioned adapter and migration,
not an in-place codec rename.
No Conjunct package or conformance result is currently supplied by this package.

[PC-02](../../docs/architecture/producer-contracts.md) defines the required
producer delivery and product fixtures while both sides are developed.

## APIs

- Gleam `frameshift_build.encode` validates typed input and sorts set-like
  collections. `decode` accepts only canonical exported bytes. Refusals contain
  bounded codes; they never echo untrusted input.
- `FrameshiftBuild.profile_identity/1` validates bytes then hashes the versioned
  payload with OTP SHA-256.
- `FrameshiftBuild.ConjunctAdapter.quantity/5`, `transform/4` and `local_id/2`
  convert resolved v1 values, rotated-outline origins and native IDs under the
  [exact product mapping](../../docs/architecture/conjunct-integration.md#exact-v1-adapter-requirements).
  Browser equivalents are `quantity`, `transform` and `localId` in
  `js/conjunct-adapter.mjs`. Results contain exact canonical rational values or
  bounded refusals. These primitives do not emit a Conjunct artifact/report,
  validate whole profiles, promote evidence or replace a planning stage.
- `FrameshiftBuild.ConjunctAdapter.v1_inputs/5` and browser `v1Inputs` retain
  all five original v1 identity domains through the existing codecs. The
  [input contract](../../docs/architecture/conjunct-v1-inputs.md) requires a
  complete pinned closure and exact compilation-context replay. Results keep
  full original bytes and IDs; they do not create Conjunct successors.
- `FrameshiftBuild.ConjunctAdapter.v1_inventory/5` and browser `v1Inventory`
  independently enumerate every original JSON node in that verified closure.
  The [source inventory contract](../../docs/architecture/conjunct-v1-inventory.md)
  retains exact values, container structure, source locators and required
  migration references under a 10000-node ceiling. Complete coverage concerns
  syntax custody; physical equivalence and successor execution remain separate.
- `FrameshiftBuild.inspect_profile/1` derives the same identity, public metadata
  and each fact/port's source citations. Applications resolve these citations;
  the shared library performs no source lookup or evidence promotion.
- Gleam `frameshift_build/assembly.encode` and `decode` preserve exact component
  pins, per-unit placement, directed connections, role dependencies and explicit
  installation requirements. They permit incomplete plans but refuse malformed
  structure and dangling instance references. Compatibility is a separate step.
- `FrameshiftBuild.build_identity/1` and `js/build.mjs`'s `buildIdentity` hash the
  assembly domain payload. `profile_pins/1` and `profilePins` return unique exact
  pins for external resolution; they never select the latest catalog revision.
- `FrameshiftBuild.resolve_build/2` and `resolveBuild` validate a canonical plan
  with up to 64 profile bodies within a shared 4 MiB budget. They recompute every
  digest, refuse duplicates/unreferenced bodies and return exact resolved
  profiles plus an explicit missing-pin list. No catalog or network is consulted.
- Internal `compiler/graph_checks` evaluates class/revision, declared roles,
  required ports, connection structure and dependency/power cycles on a
  validated resolution. Each check retains exact input references. It exposes
  no whole-assembly verdict; physical and interface constraints remain required.
- Internal `compiler/facts` reads exact registered component/port properties and
  retains values, units, source citations and unusable reasons. Its numeric/term
  selectors refuse missing, conflicting, unsupported or malformed readings.
  Nominal and conditional neighboring values never replace required bounds.
- Internal `compiler/geometry` checks the enclosing frame, six fit faces and
  unordered service-envelope pairs. Findings retain operands and source readings;
  missing geometry and overlapping envelopes remain unknown. Aperture and other
  assembly obligations are separate stages.
- Internal `compiler/rectangles` proves complete rectangle-union coverage with
  a bounded integer edge sweep. It preserves gaps and refuses malformed geometry;
  it is used by the profile-derived viewing stage.
- Internal `compiler/viewing` checks sourced active/opening offsets, containment,
  rotated tolerance envelopes, nested mats, plane order, tiled active coverage
  and possible obstructions. Findings retain possible/guaranteed rectangles,
  numeric plane operands and pinned citations. This is straight-on geometry,
  without optical or whole-build qualification.
- Internal `compiler/power_interfaces` checks directed DC voltage containment,
  polarity and exact declared reference/pinout/connector/protection/strain-relief
  agreement. Bidirectional or AC power remains unsupported unknown scope.
  Declarations do not establish registered/executable support or load capacity.
- Internal `compiler/power_loads` accounts for repeated direct loads, fan-out,
  per-port current/power and shared component output capacity. It uses declared
  source/consumer/converter/pass-through scope. Passive flow carries cumulative
  worst-case voltage drops forward and branch demand backward, with required
  feeds and input/output ratings. Missing loads, ambiguous feeds, unsupported
  scope and cycles remain unknown. This is a budget under declared facts.
- Internal `compiler/power_contracts` checks common contract alternatives across
  connected ports and reference/polarity rails, including declared passive ties.
  It catches chains whose adjacent agreements cannot share one choice and retains
  exact source assumptions and common terms. Qualification remains separate.
- Internal `compiler/thermal` checks each component's complete local ambient
  range, explicit internal ambient rise, enclosure ambient scope, the sum of all
  enclosed heat contributions and their common thermal declaration. It retains
  unknowns and exact operands; qualified assembly thermal evidence is separate.
- Internal `compiler/mounting` checks declared support paths, installation kind,
  mechanical contract groups and complete subtree loads against input, output
  and shared ratings. Missing or ambiguous supports remain unknown; internal
  self-anchoring and known cycles fail. Joint and substrate qualification is
  separate from these supported-mass calculations.
- Internal `compiler/signals` checks ordinary directed endpoints, complete
  unipolar operating-voltage containment and common signal/driver declarations
  across connected port groups. Adapter routes, thresholds, timing and executable
  mappings remain required qualification work.
- Internal `compiler/operation` checks controller/display presence, selected
  artifact/firmware/protocol declarations, hard dwell bounds and per-controller
  storage. Integrated storage and one explicit dedicated device are distinct;
  shared or multiple stores remain unknown. Recommendations are advisory.
- Internal `compiler/completeness` imposes dimensions, exact rasters, power and
  signal connections, explicit energy sources and one controller per display.
  Empty requirements, optional ports and assembly placeholders cannot remove
  these obligations. Declared owners still need qualified physical routes.
- Internal `compiler/signal_routes` follows each required/connected display
  input back to its declared controller using explicit pinned internal mappings.
  Missing or ambiguous feeds remain unknown; wrong roots and port cycles fail.
  The stage validates mapping structure/scope, not its digest or admission.
- Gleam `frameshift_build/mapping` imports/exports canonical sourced mapping
  revisions. `FrameshiftBuild.mapping_identity/1` and `mappingIdentity` hash the
  same versioned bytes; `inspect_mapping/1` exposes exact scope and citations for
  catalog binding. Mutable approval/eligibility fields cannot enter this identity.
- `FrameshiftBuild.resolve_context/4` and `resolveContext` recompute assembly,
  profile, mapping and artifact-layout pins under one 4 MiB input budget.
  Their three-argument forms select no layouts and retain the earlier context
  identity. They validate exact mapping/layout scope and return canonical
  context bytes/identity plus complete source records. Browser arrays are
  snapshotted before asynchronous hashing. This resolves selected inputs;
  constraint execution and evidence admission follow.
- Gleam `frameshift_build/artifact` imports/exports canonical artifact-layout
  revisions. `FrameshiftBuild.layout_identity/1` and `layoutIdentity` hash the
  same versioned bytes. An unknown encoding stays a valid planning choice with
  unknown execution and footprint findings.
- Internal `compiler/artifacts` checks explicit controller canvases and every
  display assignment, exact rotated rasters, complete pixel coverage/separation,
  RGB24 renderer limits, individual artifact size and retained-copy budgets.
  Region evidence carries explicit pixel/physical units. Runtime qualification
  remains a separate boundary.
- `FrameshiftBuild.planning_preview/3,4` and browser `planningPreview` verify
  the exact assembly, profile, mapping and layout bytes through the existing
  context resolver, then run all 13 retained frame-check stages. They return
  context/assembly identities, an ordered stage result with exact findings and
  `incompatible` for a known violation or `unknown` otherwise. The preview
  never grants build, source, runtime, safety or purchase admission. The pure
  Gleam stage runner is `compiler/preview`; typed structural refusals propagate.
  It is for historical inspection and migration fixtures, not a new generic
  authoring, comparison, parts-list or procedure API for the workbench.
- `js/profile.mjs` provides the equivalent `profileIdentity` through standard
  Web Crypto. Build JavaScript first; the browser must bundle the generated
  dependency graph with the adapter. It needs no HTTP service for validation.

Human labels, artwork, source retrieval records and current market eligibility
belong outside physical identity. Canonical files contain compact ASCII JSON
and one final newline. Whitespace editing, extra fields, duplicate keys and
alternate number representations are refused rather than silently normalized.
Use the typed encoder when creating a new profile revision.

## Checks and packaging

Run `scripts/check build-spec` from the repository root. It checks formatting,
strict compilation, both Gleam targets, malformed-input mutations, Elixir/JS
adapters, 256 profile and 256 assembly canonical-byte/hash parity fixtures and an actual isolated OTP
release. The [sourced baseline data](../../data/physical/README.md) additionally
passes source-reference integrity and both-target hash checks. Synthetic test
fixtures are never manufacturer evidence.

`scripts/check-conjunct-adapter` retains complete selected source/BEAM/compiled-JavaScript
bytes, inputs, expected/actual results and commands under ignored
`var/conjunct-adapter/`. The 2026-10-06 primitive qualification passes 44 authored
hands and 900 independent corner transforms on each runtime, two executed source
faults with actual reduced counterexamples per runtime, and ten correctness
smoke samples per runtime under null latency/memory budgets. The complete
package gate includes this campaign. Whole-profile migration, installed producer
resolution and all mandatory frame checks remain separate qualification work.
Graph traversal additionally agrees across targets on all 512 directed graphs
on three vertices and with an independent transitive-closure oracle.
Geometry agrees on 2,048 placements across all four rotations with an independent
corner-transform oracle; maximum coordinates and component counts are tested.
All 512 subsets of the nine rectangles on a 2×2 domain additionally agree with
an independent cell-coverage oracle. Another 256 interval projections agree
with independent corner enumeration over all 64 input-bound combinations each.
All 441 finite voltage interval pairs agree with independent point enumeration.
All 512 three-node port-graph edge subsets also agree with independent undirected
closure; maximal 576-node/512-edge connectivity and malformed limits are tested.
Another 256 passive chain/branch budgets agree across targets and with independent
endpoint enumeration for voltage, current and rounded power. Tests include a
64-instance chain, intermediate branches, missing feeds, passive input ratings,
cyclic flow and upstream evidence retention. Stable evidence deduplication
retains different observations even when they share the same lookup key.
Another 256 thermal cases agree with independent extreme-choice enumeration.
Boundary tests cover negative temperatures, excessive internal rise, unknown
heat/scope, external parts, ambiguous enclosures and 64 heat contributions.
Another 256 mounting trees agree with independent descendant-set mass accounting.
Tests cover repeated parts, adapter weight, shared capacities, invalid support
paths, global pattern agreement and a 64-instance chain carrying 6,300,000 g.
Signal tests include unknown/conflicting facts, invalid directions/polarity,
common driver/reference alternatives and all 519 findings in a 256-edge group.
Operation tests cover selected contracts, hard versus advisory dwell, dedicated
storage ownership, no implicit fallback/pooling and exact 2^40-byte limits.
Completeness tests cover omitted obligations, source-role disguise, missing and
ambiguous owners, invalid cavity bounds, unknown profiles and 64 instances.
Eleven route tests cover adapters, missing and ambiguous feeds, wrong roots,
cycles, scope changes and repeated profiles. Boundary cases include a 64-instance
chain and a 511-edge path through 255 local mappings. All 512 small directed
topologies agree with an independent matrix-closure oracle and both runtimes;
parity includes the complete ordered input references.
Six mapping-codec tests include 2,048 deterministic corruptions and complete
port/source boundaries. Three Elixir/four browser adapter tests and 256 generated
canonical-byte/hash fixtures cover immutable scope, source changes, untrusted
inputs and unavailable cryptography.
Four shared context tests, five Elixir/six browser tests and one profile-adapter
regression cover actual verified pins, canonical identity, stale/ambiguous
mappings, mixed-document limits and array mutation during hashing. Generated
fixtures match both runtimes and independently computed standard-crypto pins.
Five layout-codec tests include 2,048 deterministic corruptions, ordering and
resource bounds. Three Elixir/five browser adapter tests and 256 generated
canonical-byte/hash fixtures cover mixed context bindings, source changes,
untrusted inputs and unavailable cryptography. Three additional shared context
tests cover missing profiles, duplicate assignments and the combined budget.
Ten artifact tests cover every rotation, gaps/overlap, ownership/role errors,
unknown encodings/rasters, malformed layout inputs and conservative retention.
They include 63 displays, 1,953 tile pairs and an exact 3,221,225,472,000,000-byte
intermediate. Another 256 layouts match independent pixel and retained-byte
enumeration on both targets.
Three planning-preview fixtures compare complete ordered stage, check,
outcome, reason and input-reference projections byte for byte on both targets.
Adapter tests cover verified identities, permutation stability, changed source
bytes and malformed documents. Shared tests preserve known physical conflicts
and typed stage refusal. No preview is an accepted build.

The Mix compiler copies production Gleam modules and the pinned JSON codec,
including its native pure JSON FFI; it excludes test runners. The decision
package supplies the standard library and physical arithmetic. Gleam and Node
are build tools, not requirements for a running OTP release. `priv/licenses/`
contains the JSON dependency's upstream license; the decision package retains
the standard-library license. The check compares these files with the locked
packages and checks their presence in the assembled release.
