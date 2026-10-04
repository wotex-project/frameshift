# Build Research and Orchestration

**Status:** normative integration and evaluation contract; implementation open
**Owner:** Frameshift domain commands and `packs/frameshift/`; external Refpath runtime
**Milestone:** E for research and adaptive-host qualification; optional F is on hold

## Runtime ownership and admission

**BO-01 — One runtime.** Embed Refpath at an exact qualified revision in the
Phoenix build-platform host. Reuse its schedules, task/attempt identities,
authority enforcement, effect journal, budgets, pause/recovery and verification
contracts. Do not implement a second scheduler, generic effect ledger, agent
engine or adaptive composition runtime. Refpath status labels are not consumer
conformance evidence; verify the actual host API and migrations at that revision.

Conjunct owns generic physical composition and procedure semantics. Frameshift
supplies the product profile, evidence and typed commands. Refpath owns generic
adaptive application binding, UI graphs and generation admission. The
[CI-01–CI-08 integration contract](conjunct-integration.md) defines these
boundaries; the available upstream exports are not installed by this spec.

[PC-03](producer-contracts.md) defines the required Refpath delivery, including
Conjunct P1/CJ6-07–CJ6-08 durable scoped admission. The installed Refpath has
durable application-admission exports; map and qualify them rather than adding
another generation pointer. Atomic current review-through-commit and the
two-operator Conjunct join remain open at this consumer cohort. Required
extensions belong in Refpath; core and portable instructions do not require a
live operator host. The [source research](../research/conjunct-adoption.md#adaptive-admission-and-formal-evidence)
distinguishes the installed pin, selected upstream join and prospective API.

The initial embedded host uses the public `Refpath.BootConfig.Contract`,
`Refpath.Migrations` and readiness probe. The host owns one PostgreSQL pool and
PubSub service. Runtime tables use the `refpath` schema; Frameshift tables and
its migration ledger use `public`. Injected connections must resolve Refpath's
raw SQL through `public, refpath` while Frameshift's Repo qualifies its own
Ecto operations with `public`. Keeping `public` first also protects Ecto's
unqualified migration-ledger operations. Domain table names must not collide
across these schemas. Test both routes. A runtime
readiness label alone does not establish schema ownership or working queries.
The host disables Refpath's Beamlens instance, public API, MCP, file watchers,
plugin runtime and optional model-serving processes. Later research admission
enables only the required pack/capability surface. Do not copy the dependency's
development configuration, provider defaults or secrets into the host.

**BO-02 — Frameshift-owned packs.** Research and, if F resumes, procurement/care packs,
task bindings, schemas, methods, rubrics and evaluations are versioned and tested
in `packs/frameshift/` in this repository. Refpath loads an admitted exact pack
revision. The host owns product catalog/composition truth and exposes authorized typed actions;
packs cannot write domain tables, change policies, or grant purchasing authority.
Reusable runtime, provider and capability-contract improvements belong upstream.

Keep product/evidence bundles distinct from executable workflow packs. Join
exact product, composition, procedure and assessment identities to Refpath's
generation and execution identities. Recheck current revocation at admission
and resume without rewriting accepted input snapshots. Reuse the producer's
generation pointer and activation authority; no parallel host registry or
shadow active-generation state is allowed. Later service adapters join order
projections and Rivure financial records by their authoritative receipt IDs.

Pin each execution's task contract, pack/rule/model/source revisions, permitted
capabilities, actor and resource scope, cost/time limits, and authority expiry.
New generations affect new admissions only. Resume checks must reject revoked,
expired or incompatible authority while retaining accepted identities and
reconciling outstanding effects. A deployment or pack rollback cannot erase an
unknown external outcome. Research/adaptive-composition descriptions are not
evidence that these boundaries are already implemented upstream.

| Existing seam | Required integration evidence or known gap |
| --- | --- |
| SY.33 / DF.35–DF.36 / RT.35 / RT.61–RT.62 | Map actual public exports for product/operator solution bindings, registered UI components and generation compilation/admission; specification numbers alone are not callable APIs |
| Refpath P1 / CJ6-07–CJ6-08 consumer contract | Durable operator/project head, compare-and-swap predecessor, monotonic fence, idempotent receipt, verified cold-start closure and explicit old-work dispositions; existing attempts/effects retain identity |
| RT.03 / RT.64 schedules | Exact task binding, duplicate/DST occurrence behavior, report/assisted/unattended operation, budget, pause, maker/checker and recovery |
| RT.68 task/attempt contract | Consumer tests for identity and terminal/unknown outcomes; inspected implementation/spec remains partial |
| RT.77 / SY.33 effect and capability contracts | Admitted operation, durable effect intent, normalized receipt, explicit unknown outcome and reconciliation; inspected status labels and narrative do not consistently establish completion |
| Research engine | Reuse source manifests and extraction/evidence methods; host adapters acquire sources and Frameshift commands commit catalog changes |
| RT.59 / R.153 composition | Prove durable flow, restart admission, generation changes and revocation at the pinned revision; no copied host runtime |
| Commerce/post-purchase contracts | In F only: implement missing placement/cancellation and actual notification/refund effects; current methods/drafts are not executed external actions |

## Autonomous nontransactional research

**BO-03 — Research loop.** A versioned schedule contains permitted source scope,
budget, cutoff, freshness targets and required evidence. The loop must:

1. Acquire permitted manufacturer documents and supported supplier feeds,
   retaining exact revisions, content digests, retrieval dates, provenance and
   permitted retention/redistribution rights for documents and geometry assets.
2. Extract candidate facts with field-level source references. Preserve missing
   values and conflicting observations; distinguish source facts from inference.
3. Independently check schema, physical constraints, required formal results,
   existing evidence, supported integration capability and applicable policy.
4. Publish a revision automatically only when every preapproved applicable gate
   passes. Otherwise retain a candidate or quarantine and record a recoverable
   exception with the missing evidence and responsible owner.
5. Detect changed sources, end-of-life, safety notices, stale evidence and
   affected compositions, geometry feature maps and procedure steps. Recompute
   or quarantine affected projections
   without rewriting accepted specs or paired-device state.

Treat acquired text as untrusted data. It cannot modify permissions, supplier
bank details, payment destinations, executable code, Maude modules, model tools,
or admission policy. Require reviewed capability admission for a new protocol
or source connector. New facts that fit an existing schema may be admitted as
data; unsupported retailer operations remain unavailable for automation.

Retain source material only within permission and retention constraints. Fetches
must have URL/redirect, network destination, size, timeout, rate and parser bounds.
Use source-change detection and caching to limit unnecessary acquisition. An
inaccessible source leaves evidence stale/unknown; it does not fabricate facts.

## Decision model selection

**BO-04 — Roles.** Explicit controls and versioned Gleam/Elixir rules are the
default for customer actions and business policy. Optional free text proposes
an intent or clarification; it cannot authorize spending or prove compatibility.
Use separate tasks and acceptance gates for intent routing, source-evidence
triage and preference ranking. Apply hard eligibility constraints before ranking.

| Candidate | Permitted role and adoption condition |
| --- | --- |
| Rules/explicit UI | Baseline and outage fallback; closed actions and transparent policy |
| Local Ollama Qwen3.5 2B/4B | Initial language-routing candidates through Refpath's existing provider; short bounded context/output, closed intent enum and `unknown`/abstain |
| Compact classifier/SetFit approach | Evaluate after obtaining Frameshift labels; adopt only with a repository-compliant serving/export path and demonstrated advantage |
| Jev | Optional challenger for structured evidence questions, revision conflicts, entity matches or soft preference decisions; no required dependency without task-specific value |
| FunctionGemma/Laya or another small model | Research candidates with the same held-out gates; published task-specific results do not qualify Frameshift use |
| Z3/SMT | Consider only if a measured combinatorial optimization requirement exceeds ordinary constraint code; no default extra solver service |

Reuse Refpath's Ollama transport, structured output, accounting and provider
controls. Qualify exact model digest, quantization, context, output schema,
thinking controls and serving configuration. JSON-schema output constrains shape;
Frameshift still validates meaning and authority. A model-supplied confidence
number is not calibrated probability. Do not silently fall back to cloud or a
different model. Cloud research uses public component evidence by default and
must not transmit customer information or credentials.

The repository's no-project-owned-Python rule applies to classifiers, scripts,
tests and examples as well as the app. SetFit/Laya research is not authorization
to add a Python application service. A compliant exported model/serving path or
a separately agreed external training tool boundary must be established before
adoption. Do not introduce every candidate or a dedicated GPU merely to avoid
small per-call API charges.

**BO-05 — Qualification.** Keep cases, labels, rubrics and versioned outcomes in
`packs/frameshift/evals/`; reuse Refpath's generic evaluation machinery. Compare
the same cases, allowed labels and response contract against explicit rules.
Hold out manufacturers, revisions and paraphrase families to prevent leakage.
Include ambiguity, unsupported requests, unknowns, numerical contradictions,
hostile source text and Swedish/English if those languages are claimed.

Record dataset provenance/license, labeling and adjudication, splits, model
identity, serving parameters, hardware, warm/cold conditions, failures and all
billable work. Report macro-F1, per-class false acceptance/error rates,
abstention coverage, calibration where meaningful, uncertainty intervals,
p50/p95 latency, cold start, memory and full cost per correctly resolved case.
Include retries, timeouts, abstentions and escalation in comparisons. Freeze
task-specific thresholds before selecting the cheapest qualifying candidate;
do not retroactively weaken a threshold to admit a favored model. Requalify
model/provider/rubric changes. No Frameshift benchmark has yet selected a winner.

**BO-06 — Cost limits.** Use changed-source research, relevant excerpts, batching
of questions sharing source context, and caches keyed by source/question/model/
policy revision. Apply request, token, time, concurrency and spend limits,
bounded retries and circuit breakers through Refpath. Reconcile provider usage
and estimated reservations so parallel work cannot exceed the admitted budget.
Local inference has compute, memory, energy and maintenance costs. Select by
total task cost and error handling, not provider token price alone. Treat
probabilities for separate questions as dependent unless justified; do not
multiply them into unsupported certainty. Pricing/benchmarks are dated research
in [the decision record](../research/build-platform-decisions.md), not fixed
production assumptions.

## Failure, safety and completion

**BO-07 — Effect discipline.** Even before commerce, source fetches, notifications
and catalog commands need exact task/attempt identity, scoped actor authority,
durable receipts, and declared retry behavior. Domain actions are idempotent
by command identity and canonical payload; changed payloads conflict. Use
Refpath's effect boundary rather than a second host effect journal. Do not keep
database transactions open over provider I/O. Persist reconciliation links and
test interruption between runtime receipt and domain commit in either direction.

Research provider outages leave work pending and preserve the last admitted
catalog. Users can still inspect supported deterministic compositions,
instructions and parts-list exports. Routine admitted work proceeds unattended. Exceptions require
the specific missing fact, authority or external action; a human cannot approve
away an unknown physical fact or convert an unknown payment into failure.

**BO-08 — E acceptance.** Demonstrate exact-revision runtime/pack conformance,
schedule duplication and DST handling, independent admission checks, source
injection refusal, budgets, provider outage, restart, generation revocation,
quarantine propagation and safe resumption. Required model use must have passed
the evaluation gate; deterministic paths remain complete without inference.
Measure source freshness, eligible automatic completions, manual interventions,
false admissions, queue age, unknown outcomes, inference spend and diagnostic
resource limits under the [diagnostics contract](diagnostics.md).

Prove two differently scoped operator applications use the same reviewed code
and product data. Exercise stale UI actions, cross-operator authority, successor
and rollback, concurrent generation admission, VM restart and pending effects.
Conjunct producer conformance separately includes passive enclosure/packaging
and connected-sensor fixtures without frame imports. An unavailable adaptive
profile must leave supported deterministic composition and native paths usable.

Prove Beamlens redaction, authorized read-only queries, single supervision,
provider/budget failure and runtime overhead separately from intent-model
qualification. E must not place an order, charge, cancel, refund or alter a
supplier commitment. Those adapters, packs and failure proofs belong to
[optional F](build-commerce.md), currently on hold and requiring a separate
resumption decision after independent instructions/list and operational gates.
They do not gate completion of the engine integration proof of concept.
