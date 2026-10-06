# Shared Decision Kernel

**Status:** required cross-target host, guide and physical-composition contract;
implementation evidence is recorded separately.

The package now lives at `packages/decision-kernel/`. The host Mix dependency,
guide generator, repository checks and parity runner use that path. The move
preserves its compiled application/module identity and existing behavior.

## Companion physical composition extension

The [physical build contract](physical-build-contract.md) extends bounded pure
decisions through the separate `packages/build-spec` package. It requires
canonical units, explicit unknowns, safe integers and cross-target fixtures.
The [Conjunct integration map](conjunct-integration.md#extraction-ownership)
identifies reusable physical algorithms for extraction; native capability,
profile-selection and delivery decisions remain Frameshift-owned.

`frameshift_physical` now implements exact decimal conversion, tolerance
normalization, bounded grid/stack/load/aperture comparisons and voltage-range
containment. Its unknown and refusal results are distinct. The caller must
provide the complete constraint set and attach source/part references; these
primitives are not a BuildSpec compiler or assembly qualification.

The separate `packages/build-spec` package supplies canonical profiles,
assemblies, signal mappings, artifact layouts and exact contexts, plus the
implemented stages in the [verification map](verification.md). Its codecs
consume this arithmetic package; the complete compiler/report and qualification
remain open. This retained v1 implementation supports replay and migration,
not a new generic workbench. Conjunct owns successor composition, comparison,
CheckReport, parts projection and instruction semantics; the Frameshift kernel
continues to own native frame capability, render-profile and delivery decisions.
Current identities and both-target fixtures survive extraction.
No Ash/database, provider authority or I/O enters the pure kernel. Generic
formal predicates belong in Conjunct; frame assumptions and counterexample
replay remain Frameshift consumer evidence. The
[orchestration contract](build-orchestration.md) keeps optional classifiers out
of deterministic compatibility and authority decisions.

## Toolchain and boundary

Pin Gleam 1.18.1 with the repository's Erlang/OTP 29 and Elixir 1.20.4
toolchain. Gleam's documented compatibility includes OTP 29 from 1.18 and
JavaScript runtimes implementing ECMAScript 2022. The same `.gleam` source
must compile to both targets. The package is a pure library with no externals,
filesystem, network, clock, randomness, secrets, or hardware access. The
Elixir host calls the Erlang build for selected production decisions; the
static guide calls the JavaScript build only to explain those decisions. The
guide's examples, event model, and evidence labels are defined in the
[browser guide simulation](guide-simulation.md).

## First extraction

Move the rules for bounded artwork dwell selection and confirmation of direct
and pull display state into the kernel. The host remains responsible for
schema admission, persistence, synchronization, and authoritative frame
reads. The guide feeds only fixed examples or user-provided non-secret values
through the same functions. Inputs crossing from JSON must be integers within
the JavaScript safe range and the profile's practical dwell bound; invalid
input returns a typed refusal, never an implicit default. A queued transfer
cannot become displayed without a matching revision, request or manifest
identity, exact asset digest, and an authoritative displayed outcome.
Pull acknowledgements admit only the schema's `verified`, `unchanged`, and
`failed` storage values and `displayed`, `failed`, and `not-requested` refresh
values. A failed or skipped refresh remains pending; verified cached bytes may
be reported as `unchanged` without weakening the digest check.

Every decision has canonical fixtures covering valid, invalid, boundary, and
uncertain cases. Run those fixtures on both targets and compare results. The
test harness additionally emits 256 deterministic generated cases from a
documented bounded integer sequence. It serializes each dwell, RGB24 and indexed4 profile,
direct-confirmation, pull-confirmation and physical-grid result (including
worst-case intervals) into one stable text record.
The check compares the complete Erlang and JavaScript records byte for byte
and rejects a missing, duplicate, or reordered case. The generator and record
encoder live only in test code; production decisions remain pure. A browser
lab release must include this parity check in CI. The host adapter must include
a parity test against its former decision behavior
before deleting that behavior. Package the BEAM output with the OTP release;
do not rely on a developer's Gleam installation at runtime. The JS output is
versioned with the guide and cannot be treated as physical display evidence.
The Mix wrapper copies every module originating in the production `src/` tree
and its standard library, excludes test modules, and removes stale BEAM outputs.

The kernel selects uncompressed tightly packed RGB24 in continuous sRGB, or the
[closed indexed4 layout](content-pipeline.md#closed-indexed4-software-profile)
with explicit restricted-palette codes and revisions. Indexed4 requires even
rows, 2–16 unique four-bit hardware codes, bounded preview RGB and exact declared
packing/color revision. Host compilation additionally checks supported native
geometry. The kernel rejects dimensions above
16,777,216 pixels, inconsistent byte capacity, incompatible packing/color,
and unsupported explicit IDs. With no requested ID, it chooses the compatible
profile with the smallest ASCII profile ID, independent of advertisement order.
Duplicate profile IDs are refused so the returned identity cannot refer to
different advertised byte contracts.
The protocol schema bounds profile IDs to ASCII and at most 128 characters and
the list to 64 profiles. The host still verifies the complete Thing Description
and compiles the actual raster job; the kernel receives only the bounded
capability projection. The guide labels this choice as a software simulation.
Future color and packing modes require new qualified rules and fixtures.
Exact render bytes, credentials, and delivery effects stay outside the kernel.

Sources: [Gleam compatibility](https://gleam.run/documentation/compatibility-reference/),
[Gleam build targets](https://gleam.run/documentation/command-line-reference/),
and [Elixir/OTP compatibility](https://elixir.hexdocs.pm/main/compatibility-and-deprecations.html).
