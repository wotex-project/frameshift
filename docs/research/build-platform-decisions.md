# Build Platform Technical Decision Research

**Updated:** 2026-10-05; earlier source observations retain their recorded dates.
**Evidence:** repository/source inspection and attributed published measurements.
**Not performed:** Frameshift model benchmarks, paid inference, Maude proof runs, live provider qualification or physical hardware validation.

The technical design is in the [build-platform specification](../architecture/build-platform.md) and its linked contracts. The [Conjunct source record](conjunct-adoption.md) tracks producer contracts and integration readiness. [Thin composition evidence](thin-composition-evidence.md) retains hardware and geometry sources.

This record contains technical decisions only. Company strategy, monetization,
partner agreements, legal interpretations and monetary scenarios are outside
the product contract. They do not define the product's business model.

## Producer source provenance

| Source | Inspected revision or document | Technical consequence |
| --- | --- | --- |
| Frameshift | Current native, guide, platform and v1 BuildSpec source | Keep product behavior, v1 replay and exact fixtures while extracting genuinely generic semantics |
| Refpath | Current host cohort `ee60f58cb885f8fe6875ce9468b0c6ffdb5496c0`; [dependency refresh](#dependency-refresh-2026-10-04) | Reuse runtime owners, qualify actual exports and joined consumer behavior; unreleased/private source is not a public distribution path |
| phoenix-assets | `c76b626104e938d1c6601b73ed8c4d9d7aa4feb3` | Existing Phoenix/SvelteKit asset tooling, generated contracts and Ash metadata; no second schema generator |
| ExMaude | Current inspected source `d7669346e6983258bbe43dbcf982c558c7300283`; [source/API map](conjunct-adoption.md#adaptive-admission-and-formal-evidence) | Typed SearchRun boundary exists; complete formal profile and Frameshift join remain unqualified |
| Conjunct | `f6609c5e4c2188626f5e1f345446fec04e78d6c9`; [source record](conjunct-adoption.md#exact-producer-source-cohort) | Rust kernel, Elixir port/browser WASM/data bindings and guide exist; distribution and Frameshift consumer qualification remain open |

These are research snapshots, not automatically admitted dependency pins. Repeat owner/API discovery against the selected implementation cohort. All public requirements must be understandable without private memos or a maintainer's local Downloads file.

The direction is composition and visual instructions with an independent parts/list projection; transactional service implementation is on hold. Frameshift retains its profiles, models, procedures, native app and evaluation fixtures. Generic application-generation/effect machinery belongs in Refpath; generic physical composition belongs in Conjunct.

## Ash, assets and diagnostics

Ash domains group resources behind defined actions and policies. AshPostgres supplies server persistence without changing the local core's SQLite writer. Sources: [Ash domains](https://ash.hexdocs.pm/domains.html), [policies](https://ash.hexdocs.pm/policies.html), [AshPostgres](https://ash-postgres.hexdocs.pm/readme.html).

The selected frontend is Svelte 5/SvelteKit through [phoenix-assets](https://github.com/futhr/phoenix-assets). Pin actual exposed metadata and manifest behavior. Do not infer complete server rendering from a working asset build. Electric/Phoenix.Sync remains optional pending a real synchronization requirement.

[Beamlens](https://beamlens.hexdocs.pm/readme.html) describes a read-only diagnostic runtime. Qualify the exact dependency, native components, authorized observations, redaction and resource ceilings. Its [provider setup](https://beamlens.hexdocs.pm/providers.html) uses a BAML client registry; it is not automatically the same provider path as ordinary Refpath inference.

The earlier Refpath inspection found Beamlens optional for development/test and an observability owner capable of starting it when available. A production host must declare the dependency, select one supervisor and avoid a duplicate instance. Bound investigation frequency, concurrency, context and execution. Diagnostic failure cannot remove ordinary logs, metrics or alerts, and diagnostic models cannot mutate product/commitment state.

The planned shared operated deployment uses GreptimeDB-oriented metrics and bounded structured logs/traces without ELK. GreptimeDB ingestion and any log/trace features require exact-version qualification; the existing exporter remains. This is host configuration, not a dependency of pure product decisions. Heavy CAD/model processing must not starve authoritative application/reconciliation work.

## Private account and token boundary, 2026-10-05

The requirement is an optional server account for the companion workbench,
independent of local composition and native artwork custody. The existing Ash
Access domain owns credentials and token persistence. The bounded first-party
password direction avoids introducing a second authorization engine. OIDC is a
possible replacement only after an actual provider, identity-linking policy and
joined consumer are selected; no provider is configured or contacted here.

The admitted stable dependency is
[Ash Authentication 4.15.0](https://github.com/team-alembic/ash_authentication/tree/d6b2be35cf8f0b8ab84e7a934cfb0d91de0a3c17),
the peeled `v4.15.0` source commit checked with `gh`. Its
[changelog](https://github.com/team-alembic/ash_authentication/blob/d6b2be35cf8f0b8ab84e7a934cfb0d91de0a3c17/CHANGELOG.md)
adds session renewal and strengthens revocation/current-token handling.
Use its existing password preparation, token issuance, session consumer and
expiry supervisor. Store every token and require its presence; ordinary resource
policies refuse access outside the authentication interaction. OAuth, reset,
remember-me and short-lived sign-in-token flows are not enabled. The Phoenix
LiveView authentication package is unnecessary for the existing Svelte consumer.

The source contract for
[token revocation](https://github.com/team-alembic/ash_authentication/blob/d6b2be35cf8f0b8ab84e7a934cfb0d91de0a3c17/lib/ash_authentication/token_resource/revoke_token_change.ex)
explicitly leaves signature verification to the caller. The host verifies with
`AshAuthentication.Jwt.verify/4` before `AshAuthentication.TokenResource.Actions.revoke/3`;
decoding a claim alone cannot revoke another session. The
[session helper](https://github.com/team-alembic/ash_authentication/blob/d6b2be35cf8f0b8ab84e7a934cfb0d91de0a3c17/lib/ash_authentication/plug/helpers.ex)
verifies the token, requires a `user`-purpose row and resolves the current account.
Its finite refusal also covers failed storage reads; it does not distinguish
every storage outage from incorrect credentials. No refusal grants authority.

The selected password implementation is
[argon2_elixir 4.1.3](https://hex.pm/packages/argon2_elixir/4.1.3), through the
upstream `AshAuthentication.Argon2Provider`. The admitted package's
`lib/argon2/base.ex` defaults to Argon2id, time cost 3, 64 MiB and parallelism 4;
this is per hash, before concurrent-work limits. The published source changelog
retrieved for the 4.1.3 cohort describes releases only through 4.1.1, so it does
not establish a complete 4.1.3 change account. Exact package source and actual
hash verification are the integration evidence. The new dependency closure adds
seven packages without changing existing lock entries. Bcrypt and Assent remain
upstream transitive dependencies; no product strategy selects them.

[NIST SP 800-63B-4](https://pages.nist.gov/800-63-4/sp800-63b.html) supports a
15-character minimum for single-factor passwords and acceptance of long
passwords. The host accepts exactly 15–128 Unicode code points without trimming
or silent truncation. This bounded choice and native hashing do not establish
NIST conformance, mailbox ownership, account recovery or production identity
assurance. Password/token SQL parameters are excluded from query logs; bounded
database timing telemetry remains enabled.

Original CREATE migrations own both private tables and their indexes; a separate
INSTALL migration owns citext. Ash snapshots are checked against those schemas.
The pre-existing test database retains an older migration ledger and is preserved;
qualification uses a new isolated PostgreSQL fixture through the test-only database
selector. The [account/session specification](../architecture/build-platform.md#account-and-browser-session-boundary)
and S5 plan require database/native hashing refusal tests first, then HTTP cookie,
CSRF, origin, revocation and work-budget tests, and finally the Svelte consumer.
Authentication never supplies a catalog/operator role or opens composition writes.

Qualification passes thirteen focused database/native-hash cases, including
code-point counting and combining-character byte preservation, with warning-free
compilation, formatter and strict Credo. The full suite with HTTP/task cases below
passes 61 tests.
The three new migrations roll back and reapply on the isolated fixture.
Dependency audits retain only the existing scoped advisory exceptions; the
new credential/token closure reports no additional advisory. HTTP and browser
acceptance require their own joined consumer evidence.

### Session HTTP and native work custody

The HTTP consumer uses the pinned
[Plug 1.20.3 session cookie](https://github.com/elixir-plug/plug/blob/9fa11c8ebedbe68531eba25d8f81b9282e0514da/lib/plug/session/cookie.ex)
and [CSRF protection](https://github.com/elixir-plug/plug/blob/9fa11c8ebedbe68531eba25d8f81b9282e0514da/lib/plug/csrf_protection.ex).
The upstream recommendation to delete CSRF state after login is applied together
with Ash Authentication's session renewal. Only configured exact origins admit
writes; no forwarded header establishes an IP or origin. Credential JSON input
and cookie lengths are bounded before authentication. The three session routes
project no account, role, scope or authentication token.

[OTP 29.1's dirty-NIF contract](https://github.com/erlang/otp/blob/OTP-29.1/erts/doc/references/erl_nif.md#dirty_nifs)
states that termination can trigger monitors while native execution continues.
Consequently, caller exit never cancels admitted work or releases its slot.
Normal task completion releases capacity; abnormal worker exit, limiter restart
or task-supervisor identity loss fences new work for this VM. Each admission also
checks the current supervisor PID, closing the replacement race. Two task slots,
six per-IP and sixty global attempts per real monotonic minute bound this single
VM. Fixed transport-IP counters contain no credentials. Native hard cancellation
and multiple-instance shared admission are not qualified by this implementation.

The HTTP fixtures explicitly disable Phoenix.ConnTest's default CSRF bypass.
Joined cases exercise renewal/fixation, missing/duplicate/foreign origins, forged
and oversized cookies, exact JSON/query/role refusal, rate headers, storage outage
and revoke-before-clear. The work fixture holds actual Ash sign-in tasks at their
database-read boundary, disconnects a caller, waits through the real 60-second
window, then runs native Argon2/token issuance and observes actual task exit.
Limiter restart, task-supervisor replacement and abnormal admitted task exit have
finite refusal controls. This is software account/session evidence, not forced
dirty-NIF cancellation, production HTTPS or provider identity assurance.

## Gleam and ExMaude

Existing Frameshift Gleam code shares selected host/guide decisions. The
retained v1 physical package also uses Gleam for replay and frame-rule tests;
Conjunct owns successor generic composition and instruction decisions. Keep
pure decisions free of database access, clocks, inference and provider I/O.
Extraction must preserve historical canonical output parity and leave
frame-specific rules here without creating a second workbench engine.

The earlier [ExMaude search implementation](https://github.com/futhr/ex_maude/blob/73acecf087934e593d6bae231b0e1a4d2ddf60b4/lib/ex_maude/maude.ex) returned bounded search solutions. The current [SearchRun boundary](conjunct-adoption.md#adaptive-admission-and-formal-evidence) supplies typed termination and bound session/output/trace evidence. An empty result or partial statistics still do not establish global exhaustion. The [Maude manual](https://maude.lcc.uma.es/maude-manual/maude-manual.html) describes search within selected semantics. Qualify distinct counterexample, bounded-no-counterexample, exhausted-finite-model and inconclusive outcomes, with same-session witnesses and replay.

Use bounded separate OS processes through the qualified Port backend. Review formal predicates independently, mutate rules deliberately and replay counterexamples against production decisions. Formal evidence covers its model and bounds, not physical supplier truth. [Dependency notices](https://github.com/futhr/ex_maude/blob/main/THIRD_PARTY_NOTICES.md) distinguish library and executable licensing; retain exact tool/version notices in release artifacts without making a new licensing strategy here.

## Small-model qualification

No evidence makes Jev mandatory or establishes that it is the only suitable decision model. Begin with explicit actions and rules. Evaluate optional free-text intent using existing Refpath/Ollama support and exact Qwen3.5 2B/4B candidates. Compare trained compact classifiers when project labels exist; Jev can be an optional challenger for appropriate typed questions.

[Ollama structured outputs](https://docs.ollama.com/capabilities/structured-outputs) constrain response shape for supported profiles, not correctness or authority. Qualify the exact local/hosted implementation rather than assuming equivalent features. Pin artifacts from the [Qwen library](https://ollama.com/library/qwen3.5). The [2B model card](https://huggingface.co/Qwen/Qwen3.5-2B) reports instruction-following benchmarks; these are not Frameshift intent or engineering-fact accuracy.

The independent author's [Banking77 report](https://github.com/dhruvmehra/jevbench/blob/main/docs/results/2026-09-22-n500-summary.md) reported the following on 500 held-out examples on 2026-09-22:

| Model | Reported accuracy | Macro-F1 | Median latency |
| --- | --- | --- | --- |
| Fine-tuned DistilBERT | 88.0% | 86.4% | 8 ms |
| Jev 1.13 | 76.4% | 75.3% | 389 ms |
| Laya base | 38.2% | 32.1% | 130 ms |

These are inherited published results, not rerun measurements. DistilBERT was trained for the dataset; other models used label descriptions. Local Apple Silicon timing and a hosted OpenRouter hop are not directly comparable deployment conditions. The [method](https://github.com/dhruvmehra/jevbench) helps design a controlled comparison; it does not select a universal winner.

[SetFit](https://huggingface.co/docs/setfit/conceptual_guides/setfit), [Laya's report](https://github.com/NandhaKishorM/laya#benchmarks) and [FunctionGemma](https://ai.google.dev/gemma/docs/functiongemma/model_card) are specialist/classifier research leads. Training or evaluating a model does not automatically justify adding a Python runtime to Frameshift. Distinguish base checkpoint, fine-tuned artifact, inference host and evaluation method.

[Jev typed primitives](https://docs.typesafe.ai/introduction) and [documented jaggedness](https://docs.typesafe.ai/model-jaggedness/jev-1.13) make the previously ambiguous name explicit. Its numerical/date reasoning, indirection and adversarial-context limitations reinforce the need for deterministic arithmetic, compatibility and authorization. The [vendor methodology](https://typesafe.ai/blog/introducing-system-one-models-and-jev) is not independent engineering ground truth.

No model is admitted by this research. Build held-out examples covering exact part/revision identity, unit extraction, contradictory documents, missing geometry, ambiguous intent, abstention, source references, prompt injection, outage and bounded fallback. Measure quality, uncertainty and latency on the actual deployment. CPU/GPU memory depends on model/quantization/context/concurrency, not parameter count alone.

[Z3 optimization](https://microsoft.github.io/z3guide/docs/optimization/intro/) is a separate candidate only when configuration search demonstrates a need that existing deterministic rules do not satisfy. Optimization cannot turn a violated hard constraint into an eligible build.

## Runtime portability

Browser/offline validation, Popcorn/AtomVM experiments and network-edge execution are separate profiles. A browser success does not prove a Cloudflare Worker can run Phoenix/Ash, persistent Refpath workflows, native CAD conversion or local model serving. Qualify exact runtime libraries, host drivers, memory, persistence, sockets and restart semantics before claiming support.

A missing adaptive capability leaves the narrower deterministic guide useful. It does not authorize a copied local runtime or silently weakened authority. Keep provider/client code at its existing owner and record actual conformance gaps.

## Required implementation consequences

D covers independent composition, instructions and printable output; E covers nontransactional research and adaptive producer qualification. Optional purchasing/service/care remains deferred F and is not an engine-consumer completion gate. Preserve Ash/Svelte/phoenix-assets, bounded diagnostics, product-owned packs and procedures, deterministic physical decisions and targeted formal checks.

Models may propose or explain. They cannot admit a physical composition with required unknowns, grant new capabilities, change financial parameters, certify safety or authorize spending. External policy references and generic financial execution are handled through the [technical service contract](../architecture/build-commerce.md), not business assumptions in this file.

Record missing evidence in the [verification ledger](../architecture/verification.md). Specifications, source inspection, simulation, measured hardware and live producer qualification remain distinct.

## Implemented Frameshift work and remaining joins

The [Conjunct source record](conjunct-adoption.md) and
[CI-01–CI-08](../architecture/conjunct-integration.md) define producer
ownership and migration. Conjunct's GreptimeDB
deployment direction uses qualified Prometheus-compatible ingestion; it does
not replace the implemented metric catalog by changing a document.

The records below are dated implementation/readiness evidence from 2026-09-24.
Their B/C labels identify host-boundary and physical-contract work. Their test
results, source pins and known gaps remain scoped evidence; current ownership
and scheduling follow the integration/platform contracts above. None establishes
Conjunct conformance.

The current Conjunct code, descriptor/schema ownership, existing P1/P2 producer
APIs and remaining qualification gaps are recorded in the
[consolidated research](conjunct-adoption.md).
[PC-01–PC-09](../architecture/producer-contracts.md) states required library
deliveries and consumer tests. These requirements guide concurrent producer and
consumer implementation; they do not demand that an owned library already be
complete before its contract can be specified.

## B boundary-slice readiness, 2026-09-24

Specification readiness: `docs/architecture/build-platform.md`, BP-06–BP-09.

| Check | Result and evidence |
| --- | --- |
| Ownership | PASS — BP-07–BP-09 assign app/package/runtime owners |
| Evidence state | PASS — target paths and missing companion implementation are explicit |
| Repository truth | PASS — current roots and module namespaces inspected in Mix projects and scripts; `workspace.json` records them |
| Boundaries | PASS — separate server/local state, shared pure decisions, no shared database |
| Requirements | PASS — prohibited app imports and independently buildable components are observable |
| Capability model | PASS — this slice changes workspace organization, not frame selection or protocol semantics |
| Lifecycle | PASS — verified moves must include scripts, packaging and CI; no persisted-state migration in this slice |
| Failure/offline | PASS — existing core and guide tests remain applicable; no new server dependency in the app |
| Security/privacy | PASS — source parsing does not evaluate project files; runtime authorization remains a separate server gate |
| Physical completeness | PASS — no physical facts or hardware claims change |
| Dependencies/non-goals | PASS — boundaries precede moves; commerce remains F |
| Acceptance | PASS — forbidden-edge fixtures and current-tree checks; affected builds/parity tests required for moves |
| Sources | PASS — repository source and prior pinned dependency research support this slice |
| Completion claims | PASS — static inspection is explicitly distinct from runtime/sandbox enforcement |

Verdict: **READY** for workspace enforcement and verified package moves. This
does not qualify the unimplemented server, physical compiler, or commerce flow.

The core now lives in `apps/core`. Its move preserved relative protocol,
renderer and shared-package inputs. The core gate passes 263 cases (five
properties and 258 tests; 14 opt-in cases excluded), 81.8% coverage, strict
Credo, Dialyzer, dependency audits, generated documentation and the release's
Swift-to-Elixir IPC probe. The documentation build also includes the companion
specifications linked by the shared architecture. Excluded network/container
cases and platform hardware evidence are not implied by this result.

The Swift shell now lives in `apps/macos`. Its 39 tests and shell checks pass;
the macOS gate rebuilt and verified the app bundle, exercised its actual core
IPC and diagnostic CLI, and checked offline backup/restore and shutdown. The
move preserves the approved artwork and bundle identity. Local Swift tooling
reports missing optional CommandLineTools search directories; the linker and
packaging checks succeed. This is local ad-hoc packaging, not signed release
qualification.

The guide now lives in `apps/guide`. Its static build, eight Node tests and
signed-release fixture build/refusal checks pass from the new path. Source
assets and the guide's runtime behavior are unchanged. The workspace check
covers all four application roots after these moves.

## B server-foundation slice, 2026-09-24

The 2026-09-24 dependency lock selected Phoenix 1.8.14, Ash 3.33.10,
AshPostgres 2.13.1, phoenix-assets 1.1.1 and Beamlens 0.3.1. Frontend versions
are exact in `apps/build-platform/assets/package.json`. PostgreSQL 18.6 uses
the same image digest in local Compose and CI. These versions compiled locally
on the repository's pinned Erlang/Elixir toolchain; CI execution is a separate
observation.

On 2026-09-28, Ash was raised to 3.33.11 after
[EEF-CVE-2026-93477](https://osv.dev/vulnerability/EEF-CVE-2026-93477)
identified a bulk action argument vulnerability in earlier versions. The
dependency floor and lock now select that patched release. Mint was raised to
1.11.0 in the core and platform locks after
[EEF-CVE-2026-91043](https://osv.dev/vulnerability/EEF-CVE-2026-91043),
[EEF-CVE-2026-92103](https://osv.dev/vulnerability/EEF-CVE-2026-92103), and
[EEF-CVE-2026-94194](https://osv.dev/vulnerability/EEF-CVE-2026-94194)
reported HTTP response handling vulnerabilities in earlier releases.

Compilation exposed two required dependencies: Ash consumes StreamData at
runtime, and Beamlens' Puck backend references Req even though its upstream
dependency is optional. Both are declared explicitly. Ash authorization also
needs a SAT implementation; the initial role policies use `simple_sat`.
The frontend overrides transitive `cookie` to 0.7.2 to fix GHSA-pxg6-pf52-xh8x;
the resulting npm audit reports zero advisories. This does not qualify every
dependency behavior or diagnostic model.

Specification readiness for BP-06/BP-07 and the first BP-10 measurement slice:

| Check | Result and evidence |
| --- | --- |
| Ownership | PASS — Ash owns catalog/audit; Phoenix owns public projection; Svelte owns presentation |
| Evidence state | PASS — source documents remain distinct from component qualification |
| Repository truth | PASS — actual application, lockfiles, generated contracts and PostgreSQL migrations inspected |
| Boundaries | PASS — independent server database; no local-core imports or frame authority |
| Requirements | PASS — immutable source revision, bounded public read, typed actor policy and atomic audit specified |
| Capability model | PASS — no vendor selection or protocol behavior introduced |
| Lifecycle | PASS — schema migration and transactional rollback covered; no remote effect in this slice |
| Failure/offline | PASS — invalid input, duplicate evidence, transaction failure and source-unavailable UI covered |
| Security/privacy | PASS — no HTTP write route; actor attribution excluded from public/generated types; metrics deny absent credentials |
| Physical completeness | PASS — no physical compatibility assertion follows from a source record |
| Dependencies/non-goals | PASS — generated Ash metadata uses phoenix-assets; Refpath/Beamlens integration remains separately tracked |
| Acceptance | PASS — platform gate checks 11 database/HTTP tests, types, lint, build and contract/migration drift |
| Sources | PASS — inspected upstream dependency code and locked packages; fixture credentials only on loopback |
| Completion claims | PASS — bounded foundation evidence does not close full B, D or any commerce requirement |

Verdict: **READY** for this foundation slice. The passing checks are recorded in
the verification ledger; later B integration and C–F implementation remain open.

## Embedded runtime dependency qualification, 2026-09-24

The host pins Refpath `4a8e128628cac28706b0479bd2eabd3b9d240236` through Git,
not a sibling worktree or copied runtime. Refpath owns its migration baseline;
the host calls its public installer. Its required vector extension changes the
fixture to pgvector 0.8.6 / PostgreSQL 18, image digest
`2ba9ca5f2e7daa0f0e7723cba1ee9167bab54efd3640516a44ac1a928dd67e7a`.
The prior local PostgreSQL volume is retained, not reused across image families.

Consumer resolution selected newer Axon/Scholar releases requiring Nx 1, outside
the pinned Refpath constraint. The host therefore constrains Axon 0.8.1,
Scholar 0.4.1 and Nx 0.12.1 to the inspected upstream lock's compatible ABI.
It explicitly selects Rustler 0.38.0 for Refpath native builds over BAML's
optional 0.36 constraint. BAML ships a precompiled NIF; a native-parser smoke
checks loading, while actual diagnostic inference remains a separate gate.
Optional forecast, ML serving and native embedding are disabled in the host.

The live post-boot seed exposed the published AshPostgres 2.13.1 upsert planner
looking up an unstarted `Refpath.Repo`, despite successful reads through the
injected pool. Refpath's README requires the published fork revision
`528177429ab9bd72ab6ee7bfdf278f94c9fd8252`; the host now pins that override.
`OrchestrationTest` exercises initial insert and conflicting upsert through the
real Refpath resource, in addition to raw analytics reads and schema ownership.
A boot/readiness-only check would have missed this failure.
After the override, a live Phoenix run completed definition seeding without
warning/error records and served health and public-source requests. The full
platform gate passed 16 tests, strict Credo, frontend checks/build, generated
contracts, migration drift and phoenix-assets production checks.

The host's injected pool preserves `public, refpath` in its connection search
path and explicitly defaults its own Ecto operations to `public`. Refpath's raw
SQL can resolve its tables; Ecto's unqualified migration ledger stays in
`public`. Keeping `refpath` first created a second migration ledger during the
local test; the fixture was repaired and repeated migration runs now form part
of qualification. The schemas must not contain conflicting domain table names.

Refpath is private; the public AshPostgres fork is separately fetchable. The CI
lane expects the maintainer-managed `REFPATH_READ_TOKEN` with read-only contents
access to Refpath. No token or repository visibility change is part of this
implementation. This remains external CI setup, not evidence of a remote CI run.

Readiness review extends the B foundation's fourteen checks: ownership and
boundaries use the public boot/migration/readiness APIs; lifecycle includes
pool reuse and immutable dependency revisions; failure checks include absent
supervision and duplicate startup; acceptance adds schema reads, upsert conflict
and native dependency loading. No frame, physical, capability or commerce
meaning changes. Evidence remains limited to this embedded-host slice; E must
still qualify task/effect/pack/restart and authority behavior.

### Scoped advisory assessment

The locked graph reports cowlib 2.20.0 advisories EEF-CVE-2026-43966 and
EEF-CVE-2026-43969, plus a duplicate GHSA-w4f7-4cxr-rv3c match on Gun 2.6.0.
The upstream [header-injection advisory](https://github.com/advisories/GHSA-w4f7-4cxr-rv3c)
identifies raw structured-header serialization; its Gun version fields are
inconsistent with its stated affected range. The
[cookie advisory](https://github.com/advisories/GHSA-g2wm-735q-3f56) concerns
unvalidated cookie serialization. These are not claims that cowlib is patched.

Inspection of this host and the exact Refpath library/package sources found no
direct call to those encoders, no `invalid_request_headers: :ignore`, and no
custom Gun cookie store. The public server uses Bandit; this slice has no public
source-fetch action. Locked Gun validates outgoing CR/LF before dispatch; its cookie parser
rejects injected Set-Cookie input. `DependencyBoundaryTest` exercises those
guards. The three advisory IDs are narrowly excluded from the automated audit
for these inspected paths. Reassess when the graph, transport, cookie handling,
or source/provider adapters change; newly reported advisories still fail.

## Ash security patch, 2026-10-05

A fresh Hex audit reported CVE-2026-94201 on the previous Ash 3.34.0 pin.
The [Ash 3.34.4 changelog](https://github.com/ash-project/ash/blob/5800aa41f03a34f8be4aaaaf596456b2527576ce/CHANGELOG.md)
records the 3.34.3 correction; the exact
[filter fix](https://github.com/ash-project/ash/commit/5282f3f513053628cdd1bf2236ea22d975d934d4)
keeps caller strings as strings during atom-filter coercion and native dumping,
instead of interning them through unsafe attribute input casting. Upgrade the
platform requirement and lock to Ash 3.34.4. Its required Spark 2.7.6 is the only
other changed lock entry. Both peeled tag commits were checked with `gh`.

The reviewed changes also correct aggregate/calculation nullability and retain
false defaults in manifests/keyset handling. Spark's
[2.7.6 changelog](https://github.com/ash-project/spark/blob/7e0e4f3d16cdf17f17b1c55d4255e3871a18e287/CHANGELOG.md)
records smaller compile dependencies/module output. Apply Ash's recommended
[`infer_generic_action_reactors?: false`](https://github.com/ash-project/ash/blob/5800aa41f03a34f8be4aaaaf596456b2527576ce/documentation/topics/development/backwards-compatibility-config.md#infer_generic_action_reactors)
after inspecting the actual installed resource actions: 378 resources across
the host, Refpath and Ash Authentication contain no bare Reactor implementation.
Generic Reactor actions would need the explicit upstream `reactor/2` wrapper;
this application introduces none. No measured compilation-speed claim is made.

A test-only private ETS resource reproduces the corrected unsafe-atom filter
boundary. One hundred distinct nonmatching caller strings remain uninterned,
while a string matching an existing stored atom still selects its row. The
production resources retain their existing constrained roles/evidence kinds;
no unsafe atom attribute or generic filter endpoint is introduced. Joined account,
HTTP, resource-policy, generated-schema and migration checks qualify this patch
with the existing scoped Gun/cowlib exceptions and no additional audit exclusion.

## Dependency refresh, 2026-10-04

GitHub source and changelog inspection used `gh`; Hex/npm resolution produced
the checked locks. This refresh supersedes the dependency selections in the
dated records above, without extending their product-readiness claims.

| Surface | Selected update | Relevant upstream change and consumer action |
| --- | --- | --- |
| SQLite host | Exqlite 0.42.0 | [Statement cleanup fixes](https://github.com/elixir-sqlite/exqlite/blob/v0.42.0/CHANGELOG.md) avoid busy-handler waits and defer finalization while a connection is locked; existing persistence/restart tests exercise the consumer. |
| Protocol validation | JSV 0.25.0 | [Changelog](https://hex.pm/packages/jsv/0.25.0/files/CHANGELOG.md) fixes IPv6 URI/IRI validation and property-name error locations. The embedded, offline schema resolver remains the owner. |
| Core checks/docs | ex_check 0.17.0; Makeup 1.2.3 | [ex_check](https://hex.pm/packages/ex_check/0.17.0/files/CHANGELOG.md) adds `halt_on_failure`; enable it with retries disabled. [Makeup](https://hex.pm/packages/makeup/1.2.3/files/CHANGELOG.md) fixes deterministic compilation and escaping. |
| Platform | Phoenix 1.8.15; Ash 3.34.0; AshSQL 0.8.0; AshOban 0.9.0; AshTypescript 0.19.0 | [Phoenix](https://hexdocs.pm/phoenix/changelog.html) fixes transport replacement/close behavior. [Ash](https://hexdocs.pm/ash/changelog.html) fixes filter/atomic-update and notification handling; temporal resources are optional. [AshSQL](https://hexdocs.pm/ash_sql/changelog.html), [AshOban](https://hexdocs.pm/ash_oban/changelog.html), and [AshTypescript](https://hexdocs.pm/ash_typescript/changelog.html) cover aggregate joins, current Oban plugin configuration, pagination and generated types. Automation remains disabled; generated-contract and migration drift checks pass. |
| Platform transitive packages | Finch 0.24.0; RustlerPrecompiled 0.10.0; pgvector 0.4.2 | [Finch](https://hex.pm/packages/finch/0.24.0/files/CHANGELOG.md) fixes failed/stale HTTP connection handling; [RustlerPrecompiled](https://hex.pm/packages/rustler_precompiled/0.10.0/files/CHANGELOG.md) avoids unlinking loaded native libraries; [pgvector](https://hex.pm/packages/pgvector/0.4.2/files/CHANGELOG.md) improves sparse-vector conversion. Existing native-loading and shared-pool upsert tests pass. |
| Other platform transitive packages | CLI_mate 0.11.0; LLMdb 2026.9.8; Peri 0.11.3; Xema 0.17.10; Zoi 0.18.11 | [CLI_mate](https://hex.pm/packages/cli_mate/0.11.0/files/CHANGELOG.md), [LLMdb](https://hex.pm/packages/llm_db/2026.9.8/files/CHANGELOG.md), [Peri](https://hex.pm/packages/peri/0.11.3/files/CHANGELOG.md), and [Zoi](https://hex.pm/packages/zoi/0.18.11/files/CHANGELOG.md) document option inheritance, provider metadata, generator/schema, and coercion/default changes. Consumer compilation and tests pass; model inference remains unqualified. [Xema's source changelog](https://github.com/hrzndhrn/xema/blob/04bb684a3e0d01d87faceb7266b06dbb68c0ff8f/CHANGELOG.md) changes string lengths to code points and labels 0.17.10 with a future date; the selected version is the available Hex artifact, not evidence of that date. |
| Frontend | Biome 2.5.15; Vite 8.3.2; Node types 26.6.4 | [Biome release](https://github.com/biomejs/biome/releases/tag/%40biomejs%2Fbiome%402.5.15) and [Vite changelog](https://github.com/vitejs/vite/blob/v8.3.2/packages/vite/CHANGELOG.md) contain lint/type, watcher, preload and build fixes; type checks, layout tests, lint and static build pass. |

The [Refpath source comparison](https://github.com/refpath/refpath/compare/4a8e128628cac28706b0479bd2eabd3b9d240236...ee60f58cb885f8fe6875ce9468b0c6ffdb5496c0)
advances the immutable pin to `ee60f58cb885f8fe6875ce9468b0c6ffdb5496c0`.
Its boot contract separates process deployment from infrastructure ownership.
The host explicitly selects `hosting_mode: :self_hosted`; the boundary test
asserts the exported settings retain `deployment_mode: :embedded` and that
hosting mode. Refpath still owns its unreleased v1 migration baseline, invoked
through the existing `InstallRefpath` migration. No alter migration is added.
New upstream work-product/reconciliation exports require their own joined
consumer qualification before replacing retained Conjunct boundaries.

All three Wotex packages advance together to
`c8c727a7c8c18fec82d80cc5ba88d246af3c67fc`. The
[source comparison](https://github.com/wotex-project/wotex/compare/e6aa01a69ea35447afa989d5dea061618d20b3cf...c8c727a7c8c18fec82d80cc5ba88d246af3c67fc)
changes guidance/test scaffolding for the consumed packages, with no runtime
API migration required.

Retained constraints are deliberate:

- AshPostgres stays at `528177429ab9bd72ab6ee7bfdf278f94c9fd8252`.
  Inspection of published 2.14.0 and the fork's current branch found neither
  preserves the dynamic-repo upsert fix required by the shared pool.
- Nx 0.12.1, Axon 0.8.1, Scholar 0.4.1 and Rustler 0.38.0 retain Refpath's
  numerical/native ABI. Newer numerical majors conflict with its Nx constraint.
- SvelteKit 2.70.3/static adapter 3.0.10 remain: the
  [Kit 3 migration](https://svelte.dev/docs/kit/migrating-to-sveltekit-3) removes
  `svelte.config.js`, still required by phoenix-assets 1.1.1's doctor and
  generated type-check setup. TypeScript 6.0.3 remains within svelte-check
  4.7.6's declared peer range; TypeScript 7 is outside it. The Kit 2 cookie
  override stays at 0.7.2; npm audit reports zero advisories.
- Gleam packages already resolve to the current compatible releases. Swift and
  Zig have no external package dependencies to refresh.

Verification: the core lane passed 262 tests/properties (14 environment-gated
tests excluded), Dialyzer, documentation, format/static checks, both dependency
audits, dual-target kernel checks and the Swift-to-Elixir release IPC probe.
The isolated PostgreSQL fixture passed fresh
install, full rollback, reinstall, 32 platform tests, strict Credo, generated
contracts, production asset checks and migration drift. Platform `mix hex.audit`
passes with the existing three narrowly scoped Gun/cowlib exceptions; source
inspection of the new Refpath cohort still found no direct vulnerable encoder
call or configured header-validation bypass, and `DependencyBoundaryTest`
passes. Those packages remain unpatched; this does not widen the exceptions or
qualify unused provider/source adapters.

## B server telemetry hardening, 2026-09-24

The initial `telemetry_metrics_prometheus_core` 1.2.1 histogram stores individual
samples until aggregation at scrape time (`Core.Distribution` and `Aggregator`
in the inspected lock). A stopped scraper therefore leaves memory proportional
to traffic. Replace the host reporter with `prometheus.erl` 6.1.3, whose
[histogram](https://prometheus.hexdocs.pm/prometheus_histogram.html) aggregates
fixed buckets on arrival. Retain portable Telemetry definitions, an isolated
host registry and bounded labels. Upstream Refpath dependencies remain pinned;
this changes only Frameshift's reporter. The local SQLite reporter is unaffected.
The graph also contains Peep 4.4.0, which has bounded histograms; its generic
handler defaults a missing atom-keyed measurement to one and does not catch
measurement callback errors. The selected narrow reporter explicitly refuses
invalid measurements and contains handler/storage failure, with restart tests.

Specification readiness: `docs/architecture/diagnostics.md`, server catalog v2.

| Check | Result and evidence |
| --- | --- |
| Ownership | PASS — named domain, HTTP, Repo and collector triggers |
| Evidence state | PASS — operating targets require a baseline; no physical evidence claimed |
| Repository truth | PASS — inspected installed histogram storage and upstream fixed-bucket API |
| Boundaries | PASS — separate server registry; native Console/audit ownership unchanged |
| Requirements | PASS — units, buckets, labels, reset, retention and resource rules are explicit |
| Capability model | PASS — no frame capability behavior changes |
| Lifecycle | PASS — initialization, restart markers, missing collector and detached handlers covered |
| Failure/offline | PASS — scraper outage must not increase retained sample count |
| Security/privacy | PASS — unknown dimensions normalize; query text and raw event metadata excluded |
| Physical completeness | PASS — no panel, energy, power or assembly calculation changes |
| Dependencies/non-goals | PASS — fixed dependency; inference qualification and traces remain separate slices |
| Acceptance | PASS — concurrent load without scrapes, exact buckets, malformed metadata and restart checks |
| Sources | PASS — pinned implementation and primary histogram documentation inspected |
| Completion claims | PASS — measured workload evidence will be recorded after execution |

Verdict: **READY** for bounded server metric collection. This does not close
Beamlens inference, provider budgets or the later metric families.

The implemented reporter passed 100,000 synthetic concurrent endpoint events
without scraping: one observed run took 51,324 microseconds and added 35,200
bytes across the histogram/counter ETS tables. Counts and bucket sums matched;
the table row/memory limits in the test bound scheduler shards rather than
traffic. This measures the telemetry path, not HTTP throughput or a deployed
capacity target. Twenty platform tests, strict Credo, frontend/build and
generated-contract checks pass. Counter names now use the Prometheus `_total`
convention; v2 supersedes the short-lived foundation metric names.

Prometheus tooling is pinned to the image digest of
[v3.14.0](https://github.com/prometheus/prometheus/releases/tag/v3.14.0),
`5ce7540c3c00ef4ab0c9d2c995c6a5b9c421f44b4a115d97a2c7af3b1c21cbb0`.
Its offline lane checks configuration syntax and four collection-health rules,
including missing samples and stale-versus-current sample fixtures. Retention,
disk allocation and alert delivery are explicit deployment inputs, not live
services claimed by this check.
The live Phoenix endpoint's authenticated exposition also passed `promtool
check metrics`; native startup completed its background seeds without warning
or error records. The exporter includes current sample and reset timestamps.

## C bounded arithmetic readiness, 2026-09-24

The candidate fixtures contain sourced dimensions and explicit controller,
mounting and thermal gaps. Implement the physical contract's bounded arithmetic
before a wire consumer can silently round dimensions or treat missing facts as
zero. This slice adds no vendor selection and grants no assembly admission.

Specification readiness: `physical-build-contract.md`, PB-04/PB-06 primitives.

| Check | Result and evidence |
| --- | --- |
| Ownership | PASS — pure Gleam decisions; BuildSpec owner supplies provenance and complete constraints |
| Evidence state | PASS — candidate facts do not become validated assemblies |
| Repository truth | PASS — existing Gleam Erlang/JS package and parity harness inspected |
| Boundaries | PASS — no app, database, provider, clock or I/O dependency |
| Requirements | PASS — units, precision, ranges, tolerances, counts and decisions defined |
| Capability model | PASS — inputs describe capabilities; no vendor branching |
| Lifecycle | PASS — deterministic calls; no persisted state or protocol change |
| Failure/offline | PASS — missing/conflicting/invalid input cannot become compatibility |
| Security/privacy | PASS — bounded parsing and arithmetic; no artwork or credentials |
| Physical completeness | PASS — primitive scope includes supplied clearances/stack; full composite completeness remains the compiler gate |
| Dependencies/non-goals | PASS — shared source targets and packaged modules; canonical schema/graph/formal work remain open |
| Acceptance | PASS — exact decimal, tolerance boundaries, grid/stack/load/voltage refusals and generated target parity |
| Sources | PASS — existing candidate BOM/simulator evidence supplies examples, not new hardware claims |
| Completion claims | PASS — named arithmetic tests cannot close all of C or physical qualification |

Verdict: **READY** for these arithmetic primitives.

The shared module passes ten new physical tests plus the six existing decision
tests on both Erlang and JavaScript. The 256-case parity corpus now includes
physical outcomes, reasons and worst-case intervals. Core checks still pass
263 cases, Dialyzer and generated docs; the actual OTP release resolves the
new physical module and excludes its test module, and its Swift IPC probe passes.
The guide's eight tests and signed-fixture build also pass. Full profile/wire
compilation and physical qualification remain separate uncompleted gates.

## C canonical profile boundary, 2026-09-24

**Decision:** prototype-select a shared Gleam profile codec in `packages/build-spec`
with strict canonical imports. Keep bounded arithmetic in `decision-kernel`.
The codec pins `gleam_json` 3.1.0 (published 2025-11-08); upstream
[API](https://gleam-json.hexdocs.pm/gleam/json.html) and
[FFI source](https://github.com/gleam-lang/json/tree/v3.1.0/src), inspected
2026-09-24, use OTP JSON and JavaScript JSON parsing. These parsers do not expose
duplicate object fields through the typed decoder. Consequently ordinary
successful decoding is insufficient evidence of an unambiguous identity.

Decode only size/depth-bounded ASCII input, validate the typed document, then
require byte equality with the deterministic encoder. Duplicate/unknown fields,
reordered fields, exponent/rounded numbers and alternate escapes cannot survive
that comparison. Generated exports use those canonical bytes. Import errors
explain the canonical-format requirement; a future human-oriented editor must
use the typed encoder rather than silently rewriting imported accepted files.
This is a versioned application format, not a claim of general RFC 8785 support.
Human labels, URLs, retrieval dates, prices and changing eligibility remain
separate projections. Source digests, source revisions and fact locators remain
inside physical identity. No source text or artwork enters this codec.

The decoder needs a small lexical resource check before native parsing, not a
second JSON parser. Test both targets with duplicates, unsafe numbers, excessive
nesting, invalid escapes and round trips. Any byte/hash disagreement falsifies
this selection. The compiler must still require all relevant physical facts;
a valid profile document alone cannot qualify a build or transaction.

Specification readiness: `physical-build-contract.md`, canonical profile v1.

| Check | Result and evidence |
| --- | --- |
| Ownership | PASS — pure build-spec package, arithmetic remains in decision-kernel |
| Evidence state | PASS — source claim classes never imply assembly qualification |
| Repository truth | PASS — new package is explicitly proposed until implemented |
| Boundaries | PASS — no DB, HTTP, clock, inference or authorization inside codec |
| Requirements | PASS — exact fields, ordering, limits, units and refusal behavior defined |
| Capability model | PASS — generic roles/ports; manufacturer IDs do not choose behavior |
| Lifecycle | PASS — immutable revision, canonical import/export, unsupported version refusal |
| Failure/offline | PASS — pure local round trip; malformed input never yields partial admission |
| Security/privacy | PASS — size/depth/ASCII bounds, strict re-encoding, no secrets/artwork |
| Physical completeness | PASS — preserves explicit missing/conflicting facts; full composite checks remain open |
| Dependencies/non-goals | PASS — pinned JSON and shared arithmetic; hashing uses runtime SHA-256 adapters |
| Acceptance | PASS — target parity, schema refusals, adversarial decoding and digest fixtures |
| Source quality | PASS — exact upstream version and both native implementations inspected |
| Completion claims | PASS — codec tests cannot close compiler, formal verification or hardware gates |

Verdict: **READY** for the profile codec and identity adapters.

Implementation evidence: the profile codec passes nine Gleam tests on each
target, including 2,048 generated corruptions; all accepted mutations retain
exact canonical bytes. Three Elixir and four JavaScript adapter tests cover
identity, revisions, boundary types and mutable-field refusal. The 256 generated
profiles have equal bytes and hashes across targets. An isolated OTP release
loads the copied JSON codec, retains upstream licenses and excludes test
modules. These fixtures are synthetic; sourced catalog profiles and the full
BuildSpec compiler remain open.

## C sourced baseline profile admission, 2026-09-24

**Result: candidate.** Encode the existing three manufacturer baselines as
reviewed, immutable data. This does not select a controller or qualify an
assembly. Sources were downloaded and SHA-256 hashed; PDF drawings and table
footnotes were rendered and inspected. The baseline remains falsifiable by an
exact delivered revision, a contradictory source or a physical measurement.

- [Waveshare E6 manual v1.0, 2024-11-15](https://files.waveshare.com/wiki/13.3inch%20e-Paper%20HAT%2B/13.3inch_e-Paper_%28E%29_user_manual.pdf),
  printed pp. 3–4: native portrait axes are 1200×1600 and
  202.8×270.4 mm. The drawing has active-area ±0.1 mm and general ±0.3 mm
  tolerances. Layer-specific 0.85/0.91 mm thicknesses cannot stand for the
  entire panel/FPC/driver envelope. Retain the feature/absolute-temperature
  conflict (pp. 2, 8) and unknown final connection clearance.
- [Waveshare E6 guide, revision 110104](https://www.waveshare.com/w/index.php?title=13.3inch_e-Paper_HAT%2B_(E)_Manual&oldid=110104):
  the quoted 19-second refresh varies in practice. The guide **recommends**
  180 seconds minimum spacing and a refresh within 24 hours during use;
  these are distinct from the receiver's provisional enforced policy and from
  a measured energy optimum. The six-hour Frameshift suggestion is not a
  manufacturer claim.
- [BOE MV270QHM-N40 preliminary P1](https://www.panelook.com/upload/202311/MV270QHM-N40_Rev.P1_20190125_202311014949.pdf),
  revision history dated 2019-01-25: pp. 5 and 21 give nominal dimensions;
  p. 21 unexpectedly names MV270**F**HM-N40 when referring to the drawing.
  Preserve that scope conflict instead of admitting mechanical tolerances.
  The p. 7 electrical values have explicit ambient, frame-rate and test-pattern
  conditions; panel logic and the p. 8 four-channel backlight are separate
  loads. Neither quoted typical total power nor LED power excluding driver
  losses establishes whole-frame supply or thermal capacity. The mirror's
  document revision does not establish a delivered hardware revision.
- [Waveshare P3 legacy revision 110782](https://www.waveshare.com/w/index.php?title=RGB-Matrix-P3-64x64&oldid=110782)
  redirects readers to the [current multi-variant documentation](https://docs.waveshare.com/RGB-Matrix-Px-64x64).
  The P3 SKU 22100 row preserves 192 mm square, 64×64, 1/32 scan and
  5 V/4 A/20 W values. The old label is HUB75E; the newer family page says
  HUB75. That does not establish an exact connector pinout or driver IC.
  Unspecified geometry/voltage tolerances, depth and mounting remain unknown.

The source manifest records exact body digests, URLs, document revisions and
retrieval dates. It contains extracted facts and locators, not copies of the
manufacturer PDFs. A live page changing bytes does not rewrite a pinned record.
Refreshing source observations, adjudicating contradictions and finding missing
components are later catalog/orchestration work.

Specification readiness: physical profile seed slice, PB-01/PB-02/PB-09.

| Check | Result and evidence |
| --- | --- |
| Ownership | PASS — reviewed `data/physical`, validated by build-spec codec |
| Evidence state | PASS — all candidate; no purchased/qualified controller or assembly |
| Repository truth | PASS — paths are the next data addition; codec and hash gate exist |
| Boundaries | PASS — baseline facts do not authorize devices or suppliers |
| Requirements | PASS — separate identity, source manifest, labels and unknown gates |
| Capability model | PASS — native geometry/ports/facts; no vendor-specific decision branch |
| Lifecycle | PASS — immutable revision/digest; changed source creates a new reviewed record |
| Failure/offline | PASS — checked-in data validates without fetching mutable pages |
| Security/privacy | PASS — no source HTML, script execution, artwork or secret inputs |
| Physical completeness | PASS — missing full-envelope, controller, mounting and thermal evidence is explicit |
| Dependencies/non-goals | PASS — current codec; full compiler and supplier qualification remain open |
| Acceptance | PASS — hash/source-reference checks and regression assertions for conflicts/unknowns on both targets |
| Sources | PASS — downloaded source bodies; PDF figures/table conditions reviewed |
| Completion claims | PASS — no inference from document validity to assembly safety or eligibility |

Verdict: **READY** for sourced candidate data and offline integrity checks.

The three candidate files now pass canonical identity checks on BEAM and
JavaScript. Their references resolve to five pinned source records. Five data
regressions preserve native axes, conditional facts, scope/temperature conflicts
and missing assembly constraints, and refuse tampered hashes, absent sources,
duplicate revisions, traversal paths, unsupported evidence promotion and orphan
files. This establishes data integrity, not source authenticity or assembly
qualification.

## C catalog profile persistence readiness, 2026-09-24

Reuse the inspected SourceDocument policy/audit/transaction path and the shared
canonical codec. Store immutable source bindings as a derived profile attribute;
there is no independently writable citation action. This keeps a citation from
being attached to a profile whose canonical body never contained it. Immutable
source actions have no delete/replace path. Current eligibility stays separate
from downloadable historical facts. Source/hash identity is checked again at
this boundary rather than trusting a browser-supplied digest.

Specification readiness: physical contract, Catalog profile revision actions.

| Check | Result and evidence |
| --- | --- |
| Ownership | PASS — Ash Catalog; shared codec only normalizes/identifies bytes |
| Evidence state | PASS — candidate default; no qualification flag accepted |
| Repository truth | PASS — existing SourceDocument, actor, audit and generated-types seams inspected |
| Boundaries | PASS — app owns DB/source lookup; no application dependency in shared package |
| Requirements | PASS — accepted/derived fields, unique identities and public projections specified |
| Capability model | PASS — class/kind/facts come from validated profile, not vendor branches |
| Lifecycle | PASS — immutable create/read; explicit retryable administrative import |
| Failure/offline | PASS — unresolved source and collision refusal; transaction rollback and storage errors |
| Security/privacy | PASS — actor policies; attribution/bindings excluded from HTTP; no mutation route |
| Physical completeness | PASS — persistence cannot convert missing/conflicting facts to a passing assembly |
| Dependencies/non-goals | PASS — existing Ash stack and build-spec dependency; compiler/eligibility remain open |
| Acceptance | PASS — derived-field spoof, source resolution, rollback, revision collision and HTTP cache tests |
| Sources | PASS — same pinned Ash implementation and reviewed baseline records |
| Completion claims | PASS — database/HTTP evidence does not claim a complete builder or physical qualification |

Verdict: **READY** for immutable profile storage and public reads.

Implementation evidence: the platform's 32 tests pass. Twelve profile tests
cover exact bytes, typed policies, derived-field spoofing, source evidence-kind
matching, revision collisions, atomic audit rollback, post-transaction outcome
events, retry after partial import, bounded files and conditional HTTP downloads.
Ash's default string trimming initially removed the canonical trailing LF;
`trim?: false` and mutation regressions now protect byte identity. The explicit
seed task disables its own HTTP listener, allowing import beside a running
server. A local import and retry recorded five sources and three candidates;
live HTTP returned all three exact files and matching 304 responses, refused
mutation routes and exposed only bounded profile route labels in protected
metrics. This local database is development evidence, not a deployed catalog.

Both Gleam targets, four Elixir adapter tests, canonical/hash parity and the
isolated codec release pass. The frontend build/type/lint checks, generated
contracts, migration drift, strict Credo, workspace policy and Prometheus rules
also pass. Existing scoped dependency advisory exceptions remain as documented;
these checks do not qualify full assembly compatibility or purchasing.

## C assembly identity readiness, 2026-09-24

Choose explicit component instances with profile-content pins, directed port
connections, required-role bindings and integer placement. Quantities derive
from instances, preserving each module's load and connections. A separate intent
record pins operating requirements. This extends the existing profile codec
without moving source lookup, mutable eligibility or device authority into the
pure package. Physical profiles and the current protocol contracts were
inspected; a registry identifier still needs an admitted mapping to those
contracts. No manufacturer fact is inferred by this schema decision.

The codec preserves incomplete plans, including cycles, for compiler explanations.
It rejects structurally dangling references and ambiguous bytes. Full physical
constraints remain the next compiler boundary; a valid document cannot be
mistaken for an accepted assembly. Exact profile pins allow later compiler
resolution and portable export without silently following latest catalog data.

Specification readiness: physical contract, Canonical assembly document v1.

| Check | Result and evidence |
| --- | --- |
| Ownership | PASS — shared build-spec package; Ash resolves catalog pins |
| Evidence state | PASS — structural validity only; no assembly admission |
| Repository truth | PASS — existing codec/bounds/hash adapters inspected; assembly module proposed |
| Boundaries | PASS — no DB, browser UI, inference, source fetch or device control in codec |
| Requirements | PASS — required fields, bounds, canonical order, versions and digest defined |
| Capability model | PASS — generic instances/ports/requirements; no vendor branch |
| Lifecycle | PASS — immutable pins; explicit semantic identity; no automatic migration/substitution |
| Failure/offline | PASS — bounded refusal and offline round-trip; incomplete plans retained |
| Security/privacy | PASS — strict schema excludes artwork/customer data and executable expressions |
| Physical completeness | PASS — position/quantity/requirements retained; unmodeled constraints cannot acquire acceptance from codec |
| Dependencies/non-goals | PASS — existing pure libraries; full compiler/source admission remain required |
| Acceptance | PASS — malformed/oversized/version/dangling tests and both-target byte/hash permutations specified |
| Sources | PASS — existing physical/profile/protocol contracts; no new hardware facts |
| Completion claims | PASS — identity evidence distinct from compatibility, formal verification and purchasing |

Verdict: **READY** for immutable assembly structure and identity adapters.

Implementation evidence: eight assembly tests pass on both Gleam targets,
including 2,048 deterministic corruptions, inclusive maxima, dangling references,
duplicate edges, incomplete/cyclic plans and reordered sets. Three Elixir and
four browser adapter tests cover golden identities, changed physical inputs,
exact unique pins, unknown boundary types and unavailable cryptography. All 256
generated assemblies have equal canonical bytes and SHA-256 identities on BEAM
and JavaScript. The isolated OTP release exercises both codecs and excludes
assembly test modules. All 32 platform regressions still pass. These results
qualify structural identity; physical resolution and complete constraints remain
open.

## C exact resolution readiness, 2026-09-24

Resolve immutable profile content through the existing standard crypto adapters;
keep catalog/network access outside the shared package. Internal Gleam pairs
are computed by those adapters, never accepted as caller attestations. Missing
pins remain data for unknown constraint results. A 4 MiB total budget and 64
profile limit bound offline imports before hashing/decoding. This uses the
already qualified profile codec and makes no new manufacturer or protocol claim.

Specification readiness: physical contract, Exact profile resolution.

| Check | Result and evidence |
| --- | --- |
| Ownership | PASS — build-spec adapters and pure resolver; catalog supplies bytes |
| Evidence state | PASS — resolved content only; no authenticity/physical admission |
| Repository truth | PASS — assembly/profile codecs and standard crypto present; resolver proposed |
| Boundaries | PASS — no network or source lookup; caller identity never trusted |
| Requirements | PASS — types, count/byte ceilings, missing/extra/duplicate behavior specified |
| Capability model | PASS — exact content pins, independent of vendors |
| Lifecycle | PASS — immutable revisions retained; changed bytes need changed pin |
| Failure/offline | PASS — missing list and crypto/malformed refusal; offline operation |
| Security/privacy | PASS — preflight total budget; private artwork outside documents |
| Physical completeness | PASS — resolution cannot bypass compiler or turn absence into fit |
| Dependencies/non-goals | PASS — existing codecs; complete constraints remain required |
| Acceptance | PASS — tampering, ordering, revisions, missing/extra, limits and outage tests |
| Sources | PASS — inspected current codecs/crypto adapters; no external claim introduced |
| Completion claims | PASS — content integrity distinct from compatibility and eligibility |

Verdict: **READY** for exact profile resolution.

Implementation evidence: four shared resolution tests pass on BEAM and JavaScript;
four tests in each standard-crypto adapter cover real profile hashes, reordered
bodies, unresolved pins, changed/tampered revisions, duplicate/extra bodies,
invalid types, sparse/improper lists, UTF-8 byte budgets and crypto loss. The full
codec lane passes 21 Gleam tests per target, 11 Elixir tests and 17 browser/data
tests, both 256-record parity sets and a real OTP release resolution call. This
establishes exact content binding and resource refusal. Physical compatibility
and source assessment remain separate required work.

## C graph constraint readiness, 2026-09-24

Use bounded per-node reachability for dependency and power-cycle membership.
Exact cycle nodes provide useful explanations without enumerating every path.
A separate transitive-closure test oracle checks every three-vertex directed
graph, including self-loops. Class, declared role and port-shape checks preserve
unknown profiles/revisions. These are compiler obligations, not a replacement
for physical fact, load, geometry, protocol or eligibility checks.

Specification readiness: physical contract, Dependency and port structure checks.

| Check | Result and evidence |
| --- | --- |
| Ownership | PASS — pure build-spec compiler stage |
| Evidence state | PASS — individual modeled constraints only |
| Repository truth | PASS — resolved profiles/instances/ports inspected; graph modules proposed |
| Boundaries | PASS — no database, provider, device or authority operation |
| Requirements | PASS — graph direction, required roles/ports, unknown/incompatible semantics and limits stated |
| Capability model | PASS — classes/kinds/ports; no vendor cases |
| Lifecycle | PASS — exact pins and field references; no mutation of accepted inputs |
| Failure/offline | PASS — unresolved profiles retained; bounded traversal works offline |
| Security/privacy | PASS — validated IDs/pins only; no executable predicates from profiles |
| Physical completeness | PASS — declared structure cannot bypass later mandatory physical constraints |
| Dependencies/non-goals | PASS — existing resolution; full compiler/formal admission remain required |
| Acceptance | PASS — 512-graph independent oracle plus boundary and actual stage fixtures |
| Sources | PASS — current canonical schema/resolver and bounded arithmetic ownership |
| Completion claims | PASS — passing graph checks is not full compatibility or formal proof |

Verdict: **READY** for bounded graph constraints.

Implementation evidence: three graph and five actual-stage tests pass on both
Gleam targets. All 512 directed three-vertex graphs produce identical cycle
members across targets and match a separately implemented transitive-closure
oracle. A 64-node chain/ring, parallel edges, tails and bounds are covered.
Stage tests retain unknown profiles/revisions/requirements and identify wrong
roles/classes, absent/reversed/mismatched/self ports and dependency/power cycles.
Checks retain content-pinned field references. The complete codec lane passes
29 tests per Gleam target, existing adapter/data tests, both hash parity sets,
workspace policy and an isolated OTP graph call. Numeric/interface constraints
and whole-assembly acceptance remain open; the graph stage exposes no aggregate
compatibility or purchasing verdict.

## C compiler fact lookup readiness, 2026-09-24

Introduce an exact property registry before geometry and electrical consumers.
The existing baselines deliberately retain nominal/conditional values alongside
missing worst-case fields, and Paper retains a thermal contradiction. A reader
must preserve those distinctions and each citation instead of guessing from
nearby keys. Registry scope and required units follow the existing canonical
profile model; no new numerical hardware claim or automatic admission is made.

Specification readiness: physical contract, Compiler fact registry.

| Check | Result and evidence |
| --- | --- |
| Ownership | PASS — build-spec compiler; source assessment remains Catalog |
| Evidence state | PASS — usable reading only; no authenticity or qualification claim |
| Repository truth | PASS — actual baseline keys/units/states inspected; reader proposed |
| Boundaries | PASS — pure lookup; no I/O, mutable eligibility or device authority |
| Requirements | PASS — exact keys/scopes/units/shape/positive bounds and closed statuses |
| Capability model | PASS — property semantics independent of manufacturer name |
| Lifecycle | PASS — exact pinned profile and citations preserved |
| Failure/offline | PASS — missing/conflicting/unsupported states remain explicit offline |
| Security/privacy | PASS — validated profile input; no arbitrary executable rule expressions |
| Physical completeness | PASS — nominal/conditional values cannot supply worst-case constraints |
| Dependencies/non-goals | PASS — existing resolution; downstream completeness/comparison rules required |
| Acceptance | PASS — scope, bounds, unknowns, citation and non-substitution fixtures on both targets |
| Sources | PASS — current profile schema and three reviewed baseline records |
| Completion claims | PASS — reading is not a physical compatibility verdict |

Verdict: **READY** for the compiler's exact fact reader.

Implementation evidence: five shared fact-reader tests pass on both targets,
covering exact scope, pin/citation retention, conflicting and absent data, wrong
units, positive dimensions, and refused numeric/term selection. Two BEAM and
three browser tests resolve actual checked-in candidates before reading them:
Paper retains its depth gap and two-source thermal conflict; Photo/Pixel retain
missing required bounds despite adjacent nominal/conditional/nameplate claims.
The full package lane passes 34 tests per Gleam target, 13 Elixir and 20 browser/
data tests, both identity parity sets, the 512-graph oracle and isolated release.
No fact reading promotes the candidates or replaces the remaining compiler rules.

## C enclosure placement readiness, 2026-09-24

The next compiler stage applies the existing integer/tolerance contract to
explicit instance placement. No manufacturer value is added. Directional
clearance is required because a scalar cable allowance does not identify the
occupied face. Bounding-box overlap is insufficient evidence of a material
collision; keep it unknown until a mating/cavity model can explain it. This
conservative limit preserves missing evidence while still proving separation.

Specification readiness: physical contract, Enclosure placement and service envelopes.

| Check | Result and evidence |
| --- | --- |
| Ownership | PASS — pure build-spec geometry stage |
| Evidence state | PASS — modeled fit only; no hardware qualification |
| Repository truth | PASS — canonical placement and exact fact registry inspected |
| Boundaries | PASS — exact resolution in; explained findings out; no I/O |
| Requirements | PASS — explicit topology, coordinates, rotations, six faces and pairs |
| Capability model | PASS — source facts and component kinds; no vendor branching |
| Lifecycle | PASS — pinned inputs; stable order and semantics |
| Failure/offline | PASS — partial geometry stays unknown; known failures retained |
| Security/privacy | PASS — bounded 64-instance arithmetic; no executable geometry |
| Physical completeness | PASS — whole depth and six service clearances required for internal fit |
| Dependencies/non-goals | PASS — aperture, mating, thermal, mounting and electrical remain separate |
| Acceptance | PASS — asymmetric rotation, boundary, missing/conflict and independent oracle fixtures |
| Sources | PASS — existing physical coordinate/tolerance schema; no new external factual premise |
| Completion claims | PASS — stage findings cannot be presented as a complete build verdict |

Verdict: **READY** for enclosure fit and service-envelope separation.

Implementation evidence: nine geometry tests pass on both Gleam targets.
They retain exact profile/field/citation references and numeric operand intervals,
exercise all rotations, contact/overrun, missing/conflicting/wrong-unit values,
unsupported enclosures, maximum 64-instance pair count and the 15,000,000 µm
intermediate limit. All 2,048 generated placements agree across targets and with
an independent corner-transform oracle. The package gate passes 43 shared tests
per target, 13 Elixir and 20 browser/data tests plus identity/graph/release gates.
The pure-import declaration now admits the standard library's option type and
pure combinators, already admitted by the decision package. Aperture and the
remaining physical constraints still need their own compiler stages.

## C rectangular coverage readiness, 2026-09-24

A module array's outer dimensions do not describe its gaps. The aperture path
therefore needs exact union coverage. An edge-partition sweep over bounded
integer rectangles avoids both floating-point area error and raster sampling
that could miss a narrow seam. Independent cell enumeration qualifies the
algorithm; no new manufacturer geometry or inferred tolerance is introduced.

Specification readiness: physical contract, Rectangular viewing coverage.

| Check | Result and evidence |
| --- | --- |
| Ownership | PASS — pure build-spec geometry primitive |
| Evidence state | PASS — rectangle coverage only; no display or assembly qualification |
| Repository truth | PASS — existing integer placements and rectangular profile facts |
| Boundaries | PASS — bounded rectangles in, coverage/refusal out; no I/O |
| Requirements | PASS — signed integer edges, strict bounds, union rather than outer box |
| Capability model | PASS — geometry independent of component vendor or class |
| Lifecycle | PASS — deterministic order-independent result on both runtimes |
| Failure/offline | PASS — malformed rectangles refused; empty covering set cannot cover |
| Security/privacy | PASS — 64 rectangles, 130 edges, 129 slabs; no mesh or expression input |
| Physical completeness | PASS — gaps preserved; provenance/masks/planes remain consumer obligations |
| Dependencies/non-goals | PASS — exact fact reader supplies future consumer; no implied aperture result |
| Acceptance | PASS — all 512 subsets of nine rectangles against independent cell coverage |
| Sources | PASS — repository coordinate and tolerance contract; algorithmic decision only |
| Completion claims | PASS — this primitive cannot authorize a physical build |

Verdict: **READY** for bounded rectangle-union coverage.

Implementation evidence: four shared rectangle tests pass on both targets,
including a one-micrometre gap, interior hole, overlaps/contact, negative origins,
64-item and ±15,000,000 µm limits and malformed-rectangle refusal. All 512 subsets
agree across targets and with the independent unit-cell oracle. The full package
gate passes 47 shared tests per target, 13 Elixir and 20 browser/data tests and
all identity, graph, geometry and release checks. The pure import list admits
integer comparison/min/max; the existing random-call guard remains enforced.
Profile-derived aperture/mask/plane consumers remain required.

## C sourced viewing readiness, 2026-09-24

Connect the verified union primitive to exact sourced geometry. A guaranteed
active region is the intersection implied by its independent tolerance bounds;
a possible aperture is their outer envelope. Explicit nested masks support
multiple mats, and depth order plus conservative obstruction findings prevent
2D coverage from being mistaken for an unobstructed assembly. No new hardware
fact, optical simulation or correlation between dimensions is assumed.

Specification readiness: physical contract, Sourced viewing geometry and mask order.

| Check | Result and evidence |
| --- | --- |
| Ownership | PASS — build-spec viewing stage and shared enclosure selector |
| Evidence state | PASS — modeled straight-on projection only |
| Repository truth | PASS — source registry, envelope and coverage primitive inspected |
| Boundaries | PASS — pure resolution to explained findings; no vendor or I/O hooks |
| Requirements | PASS — interval edges, region containment, mask order, coverage and obstruction |
| Capability model | PASS — exact component facts and geometry; no model-name shortcut |
| Lifecycle | PASS — pinned sources, placement and deterministic instance/mask ordering |
| Failure/offline | PASS — unknown geometry/kind/obstruction stays visible offline |
| Security/privacy | PASS — schema limits bound all regions and ordered component pairs |
| Physical completeness | PASS — aperture/outline/plane distinctions and multiple masks explicit |
| Dependencies/non-goals | PASS — optical qualification and other physical stages remain separate |
| Acceptance | PASS — mask/tile/rotation/tolerance/failure fixtures on both targets |
| Sources | PASS — existing registry and coordinate semantics; no external hardware claim |
| Completion claims | PASS — viewing findings cannot authorize a whole assembly |

Verdict: **READY** for profile-derived viewing geometry.

Implementation evidence: four projection and ten viewing tests pass on both
Gleam targets. They cover sourced offsets, all rotations, independent tolerances,
empty guaranteed regions, frame-only and nested masks, plane ordering, seams,
missing/conflicting sources, unresolved kinds, unknown/disjoint/behind obstacles,
canonical ordering and every 3,906 ordered obstacle pair with 64 total instances.
Findings retain source readings and possible/guaranteed region operands. Another
256 projections agree across runtimes and with independent corner enumeration
over all 64 endpoint combinations of their six source intervals. Enclosure
selection is shared with the existing fit stage. Other physical stages and the
whole-build report remain separate work.
The complete package lane passes 61 shared tests on each target, 13 Elixir and
20 browser/data tests, all four independent oracle/parity lanes, exact identity
checks and the isolated release. Workspace's 14 policy fixtures and ExDoc's
warnings-as-errors check pass.

## C DC interface declaration readiness, 2026-09-24

Start electrical composition with the explicit DC source/sink scope already
represented by the profile schema. Full voltage containment and separate
polarity/reference findings avoid accepting overlapping but different rails.
Exact declared contracts remain distinct from executable registry qualification.
Bidirectional power is unknown until switching/reverse-load semantics are
modeled; one directed edge cannot supply those missing facts.

Specification readiness: physical contract, DC power interface declarations.

| Check | Result and evidence |
| --- | --- |
| Ownership | PASS — build-spec DC interface stage; shared endpoint resolver |
| Evidence state | PASS — declared agreement only; no supplier or safety qualification |
| Repository truth | PASS — exact power properties and graph checks inspected |
| Boundaries | PASS — immutable resolution to findings; no I/O or implicit adapters |
| Requirements | PASS — full containment, polarity and five exact contract alternatives |
| Capability model | PASS — port properties, not vendor or model identity |
| Lifecycle | PASS — stable canonical connection/key order and exact pins |
| Failure/offline | PASS — missing/conflicting/unsupported scope remains unknown |
| Security/privacy | PASS — at most 256 connections and bounded term lists |
| Physical completeness | PASS — source/sink facts and negative-rail polarity explicit |
| Dependencies/non-goals | PASS — loading, conversion and qualified registry mappings separate |
| Acceptance | PASS — declared matching, endpoint errors and independent interval oracle |
| Sources | PASS — repository power magnitude/port contract; no new component claim |
| Completion claims | PASS — partial electrical findings cannot admit a build |

Verdict: **READY** for DC paired-interface declarations.

Implementation evidence: eight DC tests pass on both targets. They retain
exact port/pin/source references and full voltage operands, refuse partial
voltage overlap and opposite polarity, preserve missing/conflicting facts and
exercise declaration alternatives, endpoint errors and bidirectional scope.
A canonical 256-connection fixture produces all 1,792 pair obligations. All 441
interval pairs in the finite integer domain agree across targets and with an
independent point-containment oracle. Structural and DC stages now share exact
endpoint lookup. The full package gate passes 69 shared tests per target,
13 Elixir and 20 browser/data tests plus all identity/oracle/release checks.
Current/load/conversion and qualified interface admission remain separate work.

## C direct DC budget readiness, 2026-09-24

A voltage match does not account for current, shared supply limits or fan-out.
The direct budget stage groups exact source ports and retains every target,
including unresolved targets. Scope is explicit: a cable's capacity or zero
static consumption cannot stand in for downstream demand. Pass-through flow
will need propagation; direct converter input is its sourced full worst-case
envelope, not an inferred lossless ratio or idle current.

Specification readiness: physical contract, Direct DC load budgets.

| Check | Result and evidence |
| --- | --- |
| Ownership | PASS — pure build-spec direct load stage |
| Evidence state | PASS — declared worst-case budget; no source truth or conversion qualification |
| Repository truth | PASS — port limits and existing current.maximum semantics inspected |
| Boundaries | PASS — exact resolution and integer findings; no I/O |
| Requirements | PASS — fan-out, per-rail current/power and component shared power |
| Capability model | PASS — explicit mode/topology and facts; no vendor branching |
| Lifecycle | PASS — each instance/port counted; exact pins and scope retained |
| Failure/offline | PASS — unresolved loads/modes cannot become zero; multi-feed remains unknown |
| Security/privacy | PASS — 256 edges; all products below JavaScript safe integer ceiling |
| Physical completeness | PASS — full input transients and shared output cap distinguished |
| Dependencies/non-goals | PASS — complete feeds, pass-through flow and qualified conversion separate |
| Acceptance | PASS — repeated loads, multi-rail overload, rounding, unknowns and maximum bounds |
| Sources | PASS — existing current/voltage contract; added budget semantics are explicit |
| Completion claims | PASS — direct budgets alone cannot admit a build |

Verdict: **READY** for direct DC budgeting.

Implementation evidence: nine direct-load tests pass on both Gleam targets.
They count repeat-instance loads, reject shared multi-rail overload despite legal
individual rails, ceil fractional milliwatts after summing current, preserve
missing targets/draw/modes, refuse static zero-draw pass-through and multiple
feeds, and retain the converter's full declared input envelope when downstream
draw changes. A canonical 256-unique-target fixture retains exact 25,600,000 mA
and 7,680,000,000 mW operands without wrapping. Consumption power cannot replace
shared output capacity. The full package gate passes 78 shared tests per target,
13 Elixir and 20 browser/data tests plus identity/oracle/release gates. Pass-through
voltage/load propagation and qualified conversion remain required.

## C connected contract readiness, 2026-09-24

The declaration model uses alternatives, so local intersections cannot establish
a consistent shared choice. The minimal counterexample is {A}, {A,B}, {B} on a
connected path. Require a common intersection for physical port groups, and for
whole reference/polarity rails tied through declared passive components.
Converters keep separate domains. This closes a concrete composition gap before
power propagation and supplies a useful invariant for the later formal models.

Specification readiness: physical contract, Connected power contract consistency.

| Check | Result and evidence |
| --- | --- |
| Ownership | PASS — pure port connectivity and power contract stages |
| Evidence state | PASS — consistent declarations only, not registered support |
| Repository truth | PASS — canonical endpoints and alternative-term semantics inspected |
| Boundaries | PASS — structured keys, immutable sources, no inferred conversion or I/O |
| Requirements | PASS — physical groups versus reference rails; common alternatives |
| Capability model | PASS — mode/topology and contract data, no vendor names |
| Lifecycle | PASS — deterministic groups, exact pins and common terms retained |
| Failure/offline | PASS — missing cannot repair conflict or create agreement |
| Security/privacy | PASS — 576 nodes/512 edges and bounded traversal |
| Physical completeness | PASS — shared reference and polarity include passive adapter paths |
| Dependencies/non-goals | PASS — flow and qualified mappings remain separate |
| Acceptance | PASS — minimal composition counterexample, unknowns, bounds and independent oracle |
| Sources | PASS — declared set semantics and finite graph reasoning, no new hardware fact |
| Completion claims | PASS — no whole-build or supplier-truth claim |

Verdict: **READY** for connected power contract consistency.

Implementation evidence: three port-graph and six connected-contract tests pass
on both targets. They preserve structured keys and canonical ordering, refuse
malformed/dangling/duplicate/oversized graphs, and traverse the maximal 576-node,
512-edge fixture. The contract tests exhibit adjacent agreement with no global
choice, passive reference/polarity conflicts, known conflict with missing members,
unknown polarity and separate converter domains. Findings retain assumptions,
source readings and sorted common alternatives. All 512 three-node edge subsets
agree across targets and with independent undirected closure. The full package
gate passes 87 shared tests per target, 13 Elixir and 20 browser/data tests plus
all identity/oracle/release checks. Flow and qualified contract admission remain
separate required work.

## C passive DC flow readiness, 2026-09-24

A passive part cannot supply an independent regulated output or consume only its
idle current while carrying a downstream load. Use its declared passive topology
to propagate effective voltage forward and demand backward. Require explicit
worst-case drop and ratings, retain upstream uncertainty, and stop on ambiguous
feeds or cycles. Qualified source truth and connected-contract consistency stay
separate obligations; the calculation does not infer efficiency or wiring.

Specification readiness: physical contract, Passive DC flow and rating checks.

| Check | Result and evidence |
| --- | --- |
| Ownership | PASS — shared power-flow context consumed by interface and budget stages |
| Evidence state | PASS — declared passive model; no measured wiring/thermal claim |
| Repository truth | PASS — modes, exact readers, contract components and direct budgets inspected |
| Boundaries | PASS — pure traces and findings; no I/O or executable profile rules |
| Requirements | PASS — cumulative drop, branch demand, rated envelopes, feeds and input limits |
| Capability model | PASS — ordinary source/consumer/converter/pass-through roles, no vendor branches |
| Lifecycle | PASS — pinned facts and complete derivation references; no upstream reset |
| Failure/offline | PASS — missing, cycles and ambiguous feeds remain unknown offline |
| Security/privacy | PASS — 64-instance/256-edge traversal, visited set and bounded integer products |
| Physical completeness | PASS — input/output/combined ratings plus required mode feeds |
| Dependencies/non-goals | PASS — registered qualification, thermal and full assembly remain separate |
| Acceptance | PASS — chains/branches, bounds, concealment, cycles and arithmetic parity/replay |
| Sources | PASS — existing port/voltage/current contract and explicit passive-model assumptions |
| Completion claims | PASS — flow is one electrical stage, not physical admission |

Verdict: **READY** for passive DC propagation and ratings.

Implementation evidence: nine flow tests and one exact-evidence test pass on
both targets. They cover cumulative voltage drops, input/output range failure,
missing/wrong-unit drop, optional-feed bypass attempts, repeated/intermediate
branches, passive input ratings, cycles and a 64-instance chain with all 690
local diagnostics/budgets. Another 256 generated chains/branch budgets agree
byte for byte across targets and with independently enumerated extreme choices
for voltage, current and milliwatts. The full package gate passes 97 shared
tests per target, 13 Elixir and 20 browser/data tests, all prior oracles and the
isolated release. Workspace policy passes its 14 fixtures. Qualified contracts,
thermal/mounting and whole-build admission remain separate required work.

## C operating-temperature and thermal-budget readiness, 2026-09-24

The existing ambient intent, heat/capacity fields and thermal-scope declarations
support bounded conditional checks. Installation ambient alone cannot establish
internal ambient. Add an explicit sourced local ambient-rise envelope and keep
its assembly-scope qualification separate. Electrical input/output ratings do
not substitute for heat dissipation. These are declared modeling rules, with no
new manufacturer fact or measured-performance claim.

Specification readiness: physical contract, Operating temperature and enclosure thermal budget.

| Check | Result and evidence |
| --- | --- |
| Ownership | PASS — pure physical compiler thermal stage |
| Evidence state | PASS — conditional calculations; assembly qualification remains required |
| Repository truth | PASS — exact readers, enclosure selector, intent range and existing thermal properties inspected |
| Boundaries | PASS — local ambient versus junction/case temperature; no solver or source fetch |
| Requirements | PASS — sourced rise, full-range containment, complete heat sum and shared scope |
| Capability model | PASS — locations and declared facts, no vendor branches |
| Lifecycle | PASS — immutable inputs, source references and deterministic findings |
| Failure/offline | PASS — missing rise/heat/scope stays unknown; disjoint known scope fails |
| Security/privacy | PASS — 64 instances, bounded integers and exact registry properties |
| Physical completeness | PASS — internal temperature and enclosure capacity remain separate obligations |
| Dependencies/non-goals | PASS — geometry, load scope and qualified thermal evidence remain mandatory |
| Acceptance | PASS — extrema, unknowns, repeated/external parts, scope conflicts and independent oracle |
| Sources | PASS — existing repository contract and explicit model semantics; no hardware assertion |
| Completion claims | PASS — no certification or whole-build admission |

Verdict: **READY** for operating-temperature and enclosure thermal-budget checks.

Implementation evidence: eight thermal tests pass on both targets, including
negative ambient and exact boundaries, incomplete/conflicting/incorrect-unit
rise, electrical-power non-substitution, repeated/external parts, scope conflict
with missing profiles, enclosure ambiguity and the 64-instance/64,000,000 mW
boundary. The connected-power and thermal stages share exact alternative-set
agreement. Another 256 thermal fixtures agree across targets and with independent
extreme-choice enumeration. The full package gate passes 105 shared tests per
target, 13 Elixir and 20 browser/data tests, prior independent oracles and the
isolated release. These results do not qualify a physical thermal configuration.

## C mounting-path readiness, 2026-09-24

The physical contract requires mounting load and pattern checks. Model complete
support interfaces and single-parent mass trees; qualified joint contracts own
fastener distribution, orientation, substrate and load conditions. This keeps a
bounded declared calculation separate from unmodeled statics. Optional ports,
internal self-anchoring and circular support cannot remove required evidence.

Specification readiness: physical contract, Declared mounting paths and supported mass.

| Check | Result and evidence |
| --- | --- |
| Ownership | PASS — pure mounting stages, with independent qualification admissions |
| Evidence state | PASS — conditional supported-mass calculation; no tested joint claim |
| Repository truth | PASS — mechanical ports, mass/capacity registry, graph and common-declaration checks inspected |
| Boundaries | PASS — complete grouped joints; no inferred per-fastener load distribution |
| Requirements | PASS — anchor/supported modes, single feeds, root kind, full subtree and shared ratings |
| Capability model | PASS — sourced modes/contracts and installation intent; no manufacturer branches |
| Lifecycle | PASS — pinned per-unit mass and exact path evidence; no kit double counting |
| Failure/offline | PASS — missing mass/support stays unknown; cycles and invalid topology fail |
| Security/privacy | PASS — 64 instances/256 edges, visited traversal and bounded integer mass |
| Physical completeness | PASS — self/child mass, every internal root and anchor/joint evidence covered |
| Dependencies/non-goals | PASS — qualified substrate/joints, geometry and strain relief remain distinct |
| Acceptance | PASS — branches, bypass attempts, cycle/unknown cases, max chain and independent descendant oracle |
| Sources | PASS — explicit declared mounting model and existing repository requirements |
| Completion claims | PASS — no hardware safety or whole-build admission |

Verdict: **READY** for declared mounting paths and supported-mass checks.

Implementation evidence: eleven mounting tests pass on both targets. They cover
repeated parts, adapter self-mass, shared/port/fan-out limits, missing/ambiguous
optional supports, cycles without anchors, internal-anchor bypass, installation
kind and anchor evidence, unknown mass/profiles, common joint declarations and
invalid endpoints. A 64-instance chain preserves 6,300,000 g of supported mass.
Another 256 trees agree across targets and with an independent transitive-closure
descendant-set oracle. Power and mounting share the same ordinary endpoint
validation. The full package gate passes 116 shared tests per target, 13 Elixir
and 20 browser/data tests, all prior oracles and the isolated release. Workspace
policy passes 14 fixtures. Joint, substrate and whole-assembly qualification
remain required.

## C signal-declaration readiness, 2026-09-24

Signal ports already have an exact voltage property and interface-contract
fields. Their local operating-envelope checks and connected declarations must
preserve unknowns and global alternatives. They cannot infer logic thresholds,
protocol timing or an adapter's internal route. Complete qualified path admission
remains a required compiler predecessor to any whole-build result.

Specification readiness: physical contract, Signal interface declarations.

| Check | Result and evidence |
| --- | --- |
| Ownership | PASS — pure signal-interface stage |
| Evidence state | PASS — necessary declarations/envelopes only |
| Repository truth | PASS — existing signal properties, endpoint validation and connected groups inspected |
| Boundaries | PASS — qualified thresholds/timing/routes remain separate |
| Requirements | PASS — ordinary direction, full voltage containment, positive polarity and common contracts |
| Capability model | PASS — exact port evidence; no logic-family or vendor branch |
| Lifecycle | PASS — pinned facts and deterministic source-retaining results |
| Failure/offline | PASS — unresolved/conflicting/unsupported cases stay unknown |
| Security/privacy | PASS — existing 64-instance/256-edge bounds; no I/O or expressions |
| Physical completeness | PASS — driver, reference, pinout, connector, protection and strain-relief declarations |
| Dependencies/non-goals | PASS — adapter mapping and controller/display completeness remain mandatory |
| Acceptance | PASS — polarity/envelope/mapping errors, global conflict, unknowns and maximal edges |
| Sources | PASS — explicit repository property semantics; no new hardware claim |
| Completion claims | PASS — local checks cannot establish executable or whole-build compatibility |

Verdict: **READY** for signal interface declarations.

Implementation evidence: seven signal tests pass on both targets. They cover
complete voltage envelopes, missing/conflicting/wrong-unit facts, unsupported
polarity, absent drivers, global alternatives with unknown members, invalid
endpoints and 519 findings in the maximum 256-edge fixture. The stage reuses
the ordinary endpoint, bounded connectivity, exact set-agreement and interval
primitives. The full package gate passes 123 shared tests per target, 13 Elixir
and 20 browser/data tests, all earlier oracles and the isolated release.
Whole-route, executable driver and physical interface qualification remain open.

## C runtime-intent readiness, 2026-09-24

The canonical intent and exact property registry already carry the selected
artifact/firmware/protocol, dwell and storage request. Apply conservative hard
bounds and explicit per-controller storage ownership. Recommendations remain
advisory, and neither equal identifiers nor a capacity comparison establishes
executable mapping, artifact footprint or a complete hardware route.

Specification readiness: physical contract, Runtime intent, dwell and storage allocation.

| Check | Result and evidence |
| --- | --- |
| Ownership | PASS — pure operation stage; runtime admission remains with the host/protocol |
| Evidence state | PASS — declared support and budget checks, no executable qualification |
| Repository truth | PASS — canonical intent, component kinds, role dependencies and exact properties inspected |
| Boundaries | PASS — selected shared contracts; no latest-version or provider fallback |
| Requirements | PASS — role presence, identifier membership, conservative dwell and single-store allocation |
| Capability model | PASS — kind/contract data; recommendations separate from hard limits |
| Lifecycle | PASS — selected firmware/storage scope, immutable inputs and receiver re-admission |
| Failure/offline | PASS — missing selected storage cannot fall back; shared/ambiguous ownership is unknown |
| Security/privacy | PASS — existing bounded integers/graphs; no artwork, clocks or I/O |
| Physical completeness | PASS — configured budgets remain distinct from actual artifact and atomic-retention requirements |
| Dependencies/non-goals | PASS — qualified routes/storage/firmware remain mandatory |
| Acceptance | PASS — known/unknown selections, dwell extrema, storage ownership and numeric ceilings |
| Sources | PASS — canonical plan and display-timing contract; no new manufacturer assumption |
| Completion claims | PASS — operation checks cannot admit a complete build alone |

Verdict: **READY** for runtime intent, dwell and storage allocation.

Implementation evidence: nine operation tests pass on both targets. They cover
required roles, missing/excluded runtime identifiers, conservative dwell bounds,
recommendation separation, integrated/selected storage, capacity failure,
unknown/wrong-kind providers, shared/multiple devices, repeated physical stores
and the 2^40-byte/seven-day boundaries. The full package gate passes 132 shared
tests per target, 13 Elixir and 20 browser/data tests, all earlier independent
oracles and the isolated release. Actual artifact footprint, qualified mappings
and complete whole-build admission remain required.

## C mandatory-obligation readiness, 2026-09-24

The graph stage deliberately trusts neither profile completeness nor optional
port flags as proof of a complete build. Enumerate physical dimensions, powered
and signal roles, explicit energy sources, exact display rasters and controller
ownership in code. Existing specialized stages keep their detailed obligations;
profile data cannot turn them off.

Specification readiness: physical contract, Mandatory physical obligations.

| Check | Result and evidence |
| --- | --- |
| Ownership | PASS — shared compiler completeness stage |
| Evidence state | PASS — modeled data/role checks, separate from source qualification |
| Repository truth | PASS — every existing stage and remaining data-controlled omission inspected |
| Boundaries | PASS — typed kinds and explicit constituents; no opaque composite bypass |
| Requirements | PASS — outer/cavity/raster, powered/signal roles, energy source and runtime owner |
| Capability model | PASS — role semantics and connected ports, not vendor/model identifiers |
| Lifecycle | PASS — exact pins and source references; changed constituents require new identity |
| Failure/offline | PASS — omitted optional obligations stay unknown; known contradictions fail |
| Security/privacy | PASS — fixed stage inventory and existing bounded schema |
| Physical completeness | PASS — external/enclosing outlines and separate power constituents included |
| Dependencies/non-goals | PASS — owner declaration is not a qualified signal route or artifact mapping |
| Acceptance | PASS — bypass attempts, roles/owners, dimensional contradictions and maximum counts |
| Sources | PASS — existing complete physical contract and explicit separate-component model |
| Completion claims | PASS — no whole-build result or source admission from presence alone |

Verdict: **READY** for mandatory physical obligations.

Implementation evidence: eight completeness tests pass on both targets. They
cover all-optional ports and empty requirements, missing connections, source
disguise, exterior/cavity dimensions, ambiguous rasters, missing/multiple/wrong
owners, unresolved profiles and unexpanded composites. A 64-instance fixture
retains each display's dimensions and owner. The full package gate passes 140
shared tests per target, 13 Elixir and 20 browser/data tests, existing independent
oracles and the isolated release. Presence and declarations do not establish
qualified routes or a complete build verdict.

## C directed-route readiness, 2026-09-24

Existing connected-port checks establish declarations on physical edges. They
cannot establish continuity through a controller, adapter or chained display.
Use explicit pinned internal mappings and trace every display input to its
declared controller. This follows the existing capability boundary; no vendor
lookup, inferred wire connection or hardware claim is added.

Specification readiness: physical contract, Directed display routes and explicit
internal mappings.

| Check | Result and evidence |
| --- | --- |
| Ownership | PASS — shared compiler route stage; registry admission remains external |
| Evidence state | PASS — conditional reachability, separate from qualified hardware scope |
| Repository truth | PASS — ordinary endpoint rules and explicit controller ownership inspected |
| Boundaries | PASS — typed bounded mappings with separate input references |
| Requirements | PASS — every required/connected display sink reaches its owner |
| Capability model | PASS — exact pins, runtime contract IDs and port pairs |
| Lifecycle | PASS — changed profile/runtime requires a matching mapping selection |
| Failure/offline | PASS — missing/ambiguous routes unknown; wrong roots/cycles incompatible |
| Security/privacy | PASS — byte/digest admission external; no caller digest authenticates itself |
| Physical completeness | PASS — adapter output labels cannot hide missing upstream wiring |
| Dependencies/non-goals | PASS — source truth, signal timing and registry authority remain separate |
| Acceptance | PASS — direct/adapted paths, malformed maps, ambiguity, cycles and maximal chains |
| Sources | PASS — existing mandatory ownership, signal scope and exact-resolution contract |
| Completion claims | PASS — reachability does not grant whole-build or purchase admission |

Verdict: **READY** for directed display routes under explicit mappings.

Implementation evidence: eleven route tests pass on both targets, including
wrong roots, missing/ambiguous feeds, cycles, stale runtime/profile scope,
malformed maps, every required/connected display sink, a 64-instance chain and
a 511-edge path that revisits components through distinct ports. All 512 small
directed topologies match independent matrix closure; both targets also agree
on full ordered evidence references. The package gate passes 151 shared tests
per target, 13 Elixir and 20 browser/data tests, all prior oracles and an isolated
release. Canonical mapping identities, registry admission and whole-build
qualification remain required.

## C mapping-codec readiness, 2026-09-24

Directed routes now have an explicit internal mapping type. Give that data a
portable sourced identity before exposing it to browser/server compilation.
Reuse the established canonical document and standard-crypto boundaries; keep
mapping selection and catalog approval separate from the bytes.

Specification readiness: physical contract, Canonical signal-mapping revisions.

| Check | Result and evidence |
| --- | --- |
| Ownership | PASS — shared codec; standard hashing adapters and external catalog |
| Evidence state | PASS — sourced declaration, no implicit mapping admission |
| Repository truth | PASS — route types, profile source codec and identity adapters inspected |
| Boundaries | PASS — separate immutable document and mutable assessment |
| Requirements | PASS — exact profile/runtime scope, local pairs and source references |
| Capability model | PASS — profile and runtime contracts, no manufacturer branching |
| Lifecycle | PASS — source/mapping changes alter identity and require new assessment |
| Failure/offline | PASS — exact offline round trip; unavailable crypto refuses identity |
| Security/privacy | PASS — bounded ASCII document; no credentials or caller-trusted digest |
| Physical completeness | PASS — typed route checks still require actual ports and full build scope |
| Dependencies/non-goals | PASS — independent admission and complete context pins remain required |
| Acceptance | PASS — parity, mutations, ordering, boundaries and adapter failure cases |
| Sources | PASS — existing source/identity format and directed-route contract |
| Completion claims | PASS — identity cannot substitute for compatibility or purchasing eligibility |

Verdict: **READY** for canonical signal-mapping revisions.

Implementation evidence: six shared codec tests pass, including 2,048 fixed
corruptions, exact ordering, port/source uniqueness and resource ceilings.
Three Elixir/four browser tests cover immutable scope/source changes, inspection,
type/refusal boundaries and missing cryptography. All 256 generated documents
have identical canonical bytes and hashes on both runtimes. The full gate passes
157 shared tests per target, 16 Elixir and 24 browser/data tests, earlier oracles
and the isolated release. Verified compilation context and catalog admission
remain separate work.

## C compilation-context readiness, 2026-09-24

Bind the existing assembly/profile resolver to canonical signal mappings before
whole-build consumers can use them. One computed context identity records exact
contract choices; one input budget applies across both document collections.

Specification readiness: physical contract, Verified compilation context.

| Check | Result and evidence |
| --- | --- |
| Ownership | PASS — shared resolver and standard BEAM/browser crypto adapters |
| Evidence state | PASS — verified bytes and scope, independent of source admission |
| Repository truth | PASS — profile resolver, mapping codec and route selector inspected |
| Boundaries | PASS — context pins immutable choices; mutable assessment remains external |
| Requirements | PASS — exact profiles/runtime/ports, complete citations and identity |
| Capability model | PASS — versioned contract kinds, no vendor lookup |
| Lifecycle | PASS — changed binding changes context; no latest-revision substitution |
| Failure/offline | PASS — unresolved plans remain representable; stale supplied mappings refuse |
| Security/privacy | PASS — combined preflight budget and adapter-computed hashes |
| Physical completeness | PASS — resolution cannot supply missing paths or waive constraints |
| Dependencies/non-goals | PASS — whole-build report, source admission and purchases remain separate |
| Acceptance | PASS — actual crypto, mutations, ordering, stale scope and mixed-document limits |
| Sources | PASS — existing exact-resolution, canonical mapping and directed-route contracts |
| Completion claims | PASS — context identity does not grant acceptance or qualification |

Verdict: **READY** for verified compilation context.

Implementation evidence: four shared context tests, five Elixir/six browser
adapter tests and one additional profile-adapter regression pass. They cover
actual recomputed pins, canonical identity, source changes, input permutations,
stale/ambiguous scope, missing bodies, mixed-document budgets and caller-array
mutation during hashing. Generated fixtures agree on both runtimes and with
independent standard-crypto pins. The full gate passes 161 shared tests per
target, 21 Elixir and 31 browser/data tests, all prior oracles and the isolated
release. Whole-build execution, artifact footprint and evidence admission remain
required.

## C artifact-footprint readiness, 2026-09-24

The installed renderer and shared raster selector currently admit exact packed
RGB24/sRGB with 32,768-axis and 16,777,216-pixel ceilings. The frame protocol
protects current and previous-known-good assets during upload/recovery. Reuse
those executable definitions, explicit controller ownership and the existing
rectangle-union primitive. Add a declared complete retention bound instead of
guessing queue behavior or silently counting only the incoming file.

Specification readiness: [build artifact contract](../architecture/build-artifacts.md).

| Check | Result and evidence |
| --- | --- |
| Ownership | PASS — pure shared layout and footprint stages; actual device admission stays in the host |
| Evidence state | PASS — conditional geometry/storage calculation, qualified runtime scope separate |
| Repository truth | PASS — RenderProfile, shared RGB selector and protocol storage/recovery inspected |
| Boundaries | PASS — logical pixels, physical geometry and storage allocations remain explicit |
| Requirements | PASS — complete assignments, coverage, wire size, per-artifact and retention budgets |
| Capability model | PASS — encoder/runtime contracts, not model or manufacturer branches |
| Lifecycle | PASS — layout/context identity must change with pixel assignments or selected scope |
| Failure/offline | PASS — missing layout/raster/encoding/retention remains unknown |
| Security/privacy | PASS — bounded integer math; no artwork, decoder, network or inference |
| Physical completeness | PASS — current/previous/incoming and full runtime retention scope required |
| Dependencies/non-goals | PASS — typed stage first; canonical layout resolution and runtime qualification mandatory |
| Acceptance | PASS — rotations, gaps/overlap, assignments, byte/count extremes and independent enumeration |
| Sources | PASS — executable RGB packing/limits and Frame Protocol sections 14–15 |
| Completion claims | PASS — logical coverage cannot qualify wiring, firmware or storage behavior |

Verdict: **READY** for explicit artifact layout and footprint calculations.

Implementation evidence: ten shared artifact tests pass on both targets. They
cover assignments, all rotations, gaps/overlap, owner/kind errors, strict layout
boundaries, missing/ambiguous rasters, unsupported encodings and conservative
individual/retained storage. A 63-display fixture checks 1,953 tile pairs; the
maximum intermediate remains exactly 3,221,225,472,000,000 bytes. Another 256
generated layouts agree with independent pixel and retained-byte enumeration.
The gate passes 171 shared tests per target, 21 Elixir and 31 browser/data tests,
all prior oracles and the isolated release. Public layout byte admission,
context integration and qualified runtime evidence remain required.

## C portable-layout readiness, 2026-09-24

The layout stage already has bounded explicit inputs. Give those inputs a strict
offline codec, standard-crypto identity and a typed compilation-context binding.
Preserve existing context hashes when no layouts are selected. The combined
budget and preflight snapshots apply across every input collection.

Specification readiness: artifact contract, Identity and evidence.

| Check | Result and evidence |
| --- | --- |
| Ownership | PASS — shared layout codec and existing context adapters |
| Evidence state | PASS — user-selected logical assignments, no hardware qualification |
| Repository truth | PASS — artifact types, validation and context canonicalization inspected |
| Boundaries | PASS — layout bytes carry intended assignment; profiles carry source facts |
| Requirements | PASS — exact fields/order, bounds, hash domain and context binding kind |
| Capability model | PASS — unknown encodings stay explicit without guessed footprint |
| Lifecycle | PASS — changed layout changes context; omitted collection preserves earlier identity |
| Failure/offline | PASS — bounded refusal and exact offline round trip |
| Security/privacy | PASS — shared 4 MiB budget, digest recomputation and array snapshots |
| Physical completeness | PASS — byte validity does not suppress mandatory layout checks |
| Dependencies/non-goals | PASS — whole-build execution and qualified runtime scope still required |
| Acceptance | PASS — byte/hash parity, mutations, mixed bindings, limits and cryptography failure |
| Sources | PASS — existing layout model, codec rules and verified compilation-context format |
| Completion claims | PASS — imported layout cannot admit evidence or authorize a purchase |

Verdict: **READY** for portable layouts and context integration.

Implementation evidence: five shared layout-codec tests include 2,048 fixed
corruptions. Three Elixir and five browser adapter tests cover canonical pins,
mixed context bindings, stale assignments, input mutation and cryptography
loss. Three shared context tests add layout selection, duplicate/global
assignment refusal and one combined 4 MiB input budget. The gate passes 179
shared tests per target, 24 Elixir and 36 browser/data tests, 256 generated
layout byte/hash parity records, the prior independent oracles and an isolated
OTP release without test modules. With no selected layout, the earlier context
golden identity stays unchanged. Whole-build execution and runtime/source
qualification remain open.
