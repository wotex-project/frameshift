# Composition Workbench and Product Integration

**Status:** adopted direction, source mapping updated 2026-10-04; existing host/compiler
slices retained, Conjunct integration open, transactional shop implementation on hold.
**Scope:** Frameshift product bundle, physical composition, instructions,
research and optional later service capabilities.

The [Conjunct source and readiness record](../research/conjunct-adoption.md)
identifies the producer contracts and implemented exports. [CI-01–CI-08](conjunct-integration.md)
defines identity migration and producer ownership. Existing site presentations
are implementation evidence only where the verification map names a test.

## Product and output contract

Frameshift is the first modular reference product and integration proof of
concept for Conjunct's generic physical composition and instruction engine.
Frameshift supplies frame profiles, product rules, procedures, evidence and
presentation. Its native app, renderer, device protocol and firmware remain
independent product software. Conjunct's inspected cohort implements a Rust
kernel, Elixir port, browser WASM bindings and portable guide. No qualified
Conjunct package is installed here. Integration claims require the exact
producer distribution and joined consumer tests.

**BP-01 — Independent composition.** Provide visual Paper, Photo and Pixel
configuration, explained constraints and exact printable output. Users can
inspect parts, save/reload/import/export and obtain instructions and a parts or
shopping list without an account, model, payment provider or supplier API. The
list is a projection of the physical composition. Unsupported stores and missing
prices do not exclude parts from planning. A first exact frame fixture proves
one slice; it cannot close acceptance for all claimed profiles.

**BP-02 — Optional services.** Transactional shop implementation is on hold.
Retain [BC-01–BC-10](build-commerce.md) as a deferred contract for later admitted
quotes, component handoff, purchasing, production, packaging and care. They use
explicit capabilities, counterparties, policy and authority. No fixed seller,
assembler, fee rate or company business model defines the composition engine.
An enabled service must meet its full applicable contract; speculative service
work must not displace usable composition and instructions.

**BP-03 — Local independence.** Library, artwork, generation choices, rendering,
pairing, playlists and frame delivery remain usable without the web host,
Conjunct server, inference or a service account. A composition URL or product
bundle grants no device-control authority. The web host never reads the local
SQLite database. Native device and render-generation admission remain separate.

## Visual configuration and instructions

**BP-04 — Interaction.** Show proportions and artwork preview, frame, mat,
finish, display, controller, power, mounting and assembly choices. Explain
changes to dimensions, appearance, refresh, power, required assembly operations
and available indicative prices. Support comparison, fit inspection, custom
parts and explicit unknowns. Use 2D/3D where it improves inspection. A presentation
mesh cannot establish tolerances or actual optical output.

Conjunct owns generic geometry/procedure/viewer semantics; Frameshift binds
exact parts, source features and procedure steps. Source CAD/drawings, analysis
geometry and delivery meshes remain separate. The assembly viewer is distinct
from the Zig artwork renderer. Complete installed depth includes electronics,
connectors, cable bends, backing, mounting and service access. No arbitrary
product diagonal limit replaces these constraints; versioned software limits
remain explicit and enforced.

Users can save locally, reload, duplicate and compare without signing in.
Conjunct defines the canonical composition, comparison, CheckReport, parts
projection and procedure/output semantics used in those flows. The Frameshift
browser supplies frame-specific controls, renders qualified Conjunct results and
performs local file/storage I/O; local persistence does not authorize a second
physical compiler or procedure planner. The retained v1 BuildSpec preview may
inspect historical inputs during migration but is not the workbench's successor
engine or an accepted-build result.
Server saving/sharing is a separate explicit operation with access and retention
rules. Artwork stays in the browser until the user requests an upload. Public
share URLs, metrics and generated metadata contain no private artwork or
customer/operator data.

**BP-05 — Reproducible output.** Print and portable export contain exact
composition identity/version, parts/profile revisions, quantities, permitted
manufacturer/source links, dimensions, check results, unknowns and evidence
scope. Bind procedure, geometry/scene and explanatory-document revisions.
Include required tools, skills, steps, stop conditions, observations and native
installation handoff. A missing physical parameter prevents acceptance of the
affected operation; instructions cannot fill it with plausible prose.

Output must work without colour, clipped tables, network-only assets or a 3D
canvas. Keyboard, screen reader, reduced motion, low graphics capability,
narrow-screen/high-zoom, loading, invalid, offline/reconnect and missing-source
paths are required. Selection, save, reload, import and export use the same
compiler semantics. DocShell supplies explanations through a qualified contract;
procedure meaning and physical evidence have their own owners.

Indicative prices retain currency, observation date, inclusions and stale/missing
status. Label partial sums; missing stock or price cannot block an exact parts
list. Binding amounts, tax calculations and reservations belong to an enabled
service profile and its financial/policy owner.

## Server and frontend architecture

**BP-06 — Selected host.** Retain Phoenix, Ash/AshPostgres and
phoenix-assets/Svelte 5/SvelteKit in `apps/build-platform`. Refpath is an exact
external dependency. Conjunct will supply qualified composition/host capabilities;
Frameshift supplies the product specialization. Package boundaries do not imply
one service per package or one application fork per operator.

- Ash actions enforce validation, actor/operator scope, policy and server writes
  across browser, worker, administrative and product-pack entry points.
- Phoenix owns sessions, HTTP boundary checks and authenticated subscriptions.
  Frontend visibility or a product hash cannot authorize a command.
- SvelteKit consumes phoenix-assets' Vite/manifest and generated `$phoenix/*`
  contracts. Expose metadata deliberately; retain one schema-generation owner.
- Pure physical decisions depend on neither hosts, databases, models nor I/O.
  The retained Gleam/JavaScript v1 preview supplies bounded historical planning
  feedback. The workbench uses a qualified Conjunct browser binding for new
  generic decisions; server acceptance recomputes the same semantics from exact
  inputs and checks current admission, including revocation on a cache hit.
- Use commands, queries and scoped PubSub. Synchronization and server-rendering
  claims require demonstrated requirements and consumer evidence.
- Refpath owns approved UI-graph and generation authority. Registered viewer,
  inspector, procedure and explanation components resolve to authorized commands;
  a model may propose data or an approved configuration, never executable code.

### Account and browser-session boundary

The first-party account/session implementation uses Ash Authentication's public
password/token boundary in the existing Access domain, with Argon2id hashing.
A private account UUID identifies the credential holder; a login email is not
proof of mailbox ownership, an operator role or permission to use another user's
composition. Account provisioning, confirmation/recovery and browser presentation
are explicit host operations. Local composition, public catalog reads and the
native artwork app require no account.

Passwords are opaque, untrimmed strings of 15–128 Unicode code points; confirmation
must match exactly. Persist only the salted hash. Store all issued 12-hour tokens
in the private token resource and require both cryptographic verification and
stored-token presence for authentication. Expired, revoked, changed or missing
tokens and unavailable storage refuse. Per-request account resolution uses the
current stored account rather than browser claims. Hashing and token handling
stay with the admitted upstream implementation; no product authentication engine
or alternate provider fallback is introduced.

The browser session uses an encrypted, signed, HttpOnly cookie, Secure in
production, SameSite Strict and Path `/`, with a fresh session on successful
sign-in. Authentication tokens never enter JSON, URLs, frontend storage, public projections or
logs. State-changing session requests require the matching CSRF token and the
configured same origin. Sign-out revokes the stored token before clearing the
session; failed revocation cannot report completed sign-out. Use finite errors
and `no-store` responses. Rate limits and concurrent-password-work bounds must
pass before an externally accessible password route is enabled.

| Entry point | Trusted authority | Allowed behavior |
| --- | --- | --- |
| Public catalog/health/guide | None | Existing deliberate public projections |
| Account/token actions | Ash Authentication interaction or explicit trusted provisioning | Credential authentication and private token lifecycle |
| Authenticated session | Verified current account | Its own finite session state; no caller-supplied actor/role/scope |
| Catalog write | Existing typed editor/research-worker policy | Internal actions; a login alone grants no catalog role |
| Composition save/share/assets | Current server membership plus S4/S5 command/resource qualification | Unavailable until its profile, identity, receipt/revision and private-asset gates pass |
| Operator action | Current operator membership and producer admission/fence | Remains independently gated; no role inferred from email or token claims |

Deliver account/token resources first, then bounded HTTP session/CSRF/revocation
and the Svelte consumer. Keep browser writes closed while those consumers and
composition gates are unqualified. Acceptance uses actual PostgreSQL and Argon2,
unique private identities, incorrect credentials, password/confirmation bounds,
plaintext exclusion, cryptographic tamper/expiry, stored-token removal/revocation,
current-role refusal and storage failure. Joined HTTP/browser fixtures add forged
cookie/role/scope, login CSRF, fixation, origin, logout failure and budget/capacity
refusal. Fixture accounts and tokens grant no live identity-provider or release
authority. Recovery/delivery and production HTTPS configuration require their
own actual consumer evidence.

The session API has three operations: `GET /api/session` returns only the current
authenticated boolean and a CSRF token; `POST /api/session` accepts exactly email
and password; `DELETE /api/session` accepts an empty body and revokes the current
session. It exposes no account registration, password recovery or role-assignment
route. JSON query parameters cannot supply credentials. An existing token that
cannot be resolved returns a finite refusal while preserving its cookie; it does
not claim that remote sign-out completed. Missing cookies can obtain an anonymous
CSRF session without an account. Successful sign-in renews the cookie and CSRF
state; successful sign-out clears both after revocation.

Both state-changing operations require exactly one configured Origin and a valid
session-bound CSRF token. Session cookie input is bounded to 4096 bytes. Responses
are JSON with `no-store`, `nosniff` and no authentication token or account fields.
Only production HTTPS uses Secure cookies; loopback development/test fixtures
explicitly disable that flag. Origin checks use configured origins, never forwarded
headers or caller-supplied authority.

Password work admits at most two supervised workers, six attempts per transport
IP and sixty total attempts in a 60-second monotonic window, retaining at most
1000 IP counters. Capacity/rate refusal is 429 with a bounded Retry-After; it never
queues a hash or retries credentials. A disconnected caller does not release a
worker before its normal completion. Limiter or worker-supervisor restart or
replacement and abnormal worker exit fence new password work until a complete
VM restart, because lost rate/work state cannot
be treated as an empty budget. There is no hard native-hash cancellation claim.
Unknown/unavailable work returns 503, malformed input 400, invalid credentials or
session 401, and origin/CSRF refusal 403. These are one-VM admission limits; a
deployment with multiple instances requires an independently qualified shared
admission boundary before enabling password traffic across those instances.

The Svelte account consumer uses the generated public session-view type and route
helpers. It projects current session status, explicit sign-in/sign-out and a
manual retry for unavailable state. Credentials remain in the form only for the
explicit attempt; clear the password after every attempt and never retain it,
authentication tokens or CSRF state in browser storage. Do not retry a credential
or logout request automatically. A failed logout preserves its visible current
state and explains that completion could not be confirmed. Failed session lookup
must not fabricate signed-out status. Public catalog browsing remains usable.
Keyboard operation, named fields, live status, narrow/high-zoom/reduced-motion
layout, real HTTP login/renewal/logout, refresh and outage checks qualify this
consumer; frontend compilation alone does not establish that join.

### Current catalog membership boundary

S5's independent permission groundwork covers the existing global catalog only.
Private membership grants bind one account UUID to `catalog_editor`,
`research_worker` or the existing `operator` audit-reader role. The latter grants
only catalog-audit reads; it grants no Refpath operator/project or composition
authority. Roles, account IDs and membership references never enter public
catalog/session projections. A login has no membership by default.

An explicit trusted local administrator actor with `access_admin` may provision
or revoke grants. This bootstrap authority is supplied by trusted server code,
never a password account, email, JWT claim or browser input. It has no HTTP route
and cannot itself be assigned through membership provisioning. Preserve the
existing explicitly trusted administrative/worker actor path; an authenticated
lookup must never fall back to constructing such an actor after refusal.

A caller-chosen stable grant UUID binds exactly one account, role and granting
administrator. Creation is version 1 and retains its timestamp and attribution.
Same-ID/same-input retry returns retained state without another grant; conflicting
input refuses. At most one unrevoked grant exists per account/role. Revocation
requires expected version 1, records its administrator/time and transitions once
to version 2. Same-input retry preserves that result; another revoker or revision
conflicts. A revoked grant never reactivates. Regrant needs a new UUID, invalidating
all old permission references. Keep grant/revocation attribution; account removal
with retained grants refuses until a separate retention/deletion contract exists.

Permission lookup takes a cryptographically verified current session and one
server-selected catalog role. It derives the account UUID, reads current stored
membership and returns an actor carrying the exact grant/version reference.
Existing Ash role policies recheck that reference on each action; revocation or
replacement refuses held actors. Missing membership is unauthorized; failed
storage is unavailable and grants no permission. No role or membership cache is
used. This lookup is permission groundwork, not an atomic command admission lease:
browser writes still require command identity, payload/revision, transaction and
private-resource qualification before exposure.

Acceptance uses actual PostgreSQL constraints/transactions and native session
verification. Exercise absent/forged/account-mismatched memberships, role/ID/input
bounds, unchanged grant/revoke replay, changed-input conflict, duplicate active
roles, concurrent grant/revoke, regrant invalidation, token/current-account loss,
ordinary Ash-policy refusal, private-schema exclusion and storage failure.
Current catalog policy joins must reject revoked references while preserving
anonymous reads and the existing trusted local seed/worker path.

**BP-07 — Domain ownership.** Keep explicit consistency/API boundaries:

| Domain | Responsibility | State/dependency |
| --- | --- | --- |
| Product Catalog & Evidence | Frame sources, claims, profiles and current assessments; consume Conjunct generic semantics | Immutable sources/profiles implemented; assessment and federation open |
| Composition & Instructions | Frame rules and content, Conjunct consumer adapter, authorized product storage and installation handoff | Retained v1 checks exist; Conjunct selection, reports, projection and instruction consumers open |
| Access & Policy | Actor/operator authorization, external decision references, retention and audit access | Private account/session and current global catalog memberships implemented; browser domain writes and operator/project scope open |
| Product Research | Frameshift source/task mappings, rubrics and evaluations through Refpath | Packs and joined runtime conformance open |
| Service Commitments & Care | Optional exact accepted provider plans, production/packaging/fulfillment observations and cases | Deferred F |
| Financial Integration | Product-event and commitment references through Rivure public commands/results | Deferred F; no Frameshift ledger or provider engine |

The existing source boundary retains immutable UUID, public title/HTTPS URI,
publisher revision, content digest, source kind, observation time and recording
actor. URI/revision conflicts refuse; successful inserts and audit attribution
commit atomically. Exact profile bytes derive identity and bind every source
citation. These records do not grant assessment or physical acceptance. Preserve
these guarantees when adapting to Conjunct's richer evidence vocabulary.

Packs cannot write domain tables. Refpath owns attempts/effects, Rivure owns
financial state, and the host owns product state. Use immutable joins and public
commands; do not create a second effect journal or update producer tables.

## Monorepo boundaries and migration

**BP-08 — Actual paths and staged extraction.** The current tree already has:

```text
apps/{macos,core,build-platform,guide}/
packages/decision-kernel/
packages/build-spec/
data/physical/
protocol/ renderer/ firmware/ simulator/ release/ docs/ scripts/
```

`workspace.json` enforces the component graph and pure import allowlists. The
four app moves are implemented and have recorded build/package evidence.
`packages/build-spec` remains the current frame contract/compiler owner through
the explicit CI-03/CI-04 transition for v1 replay and frame-specific checks.
It does not become a parallel successor for Conjunct composition, comparison,
report aggregation or instructions. A directory rename cannot establish a
Conjunct dependency or a generic vocabulary.

Introduce `product/bundle`, profiles, procedures, packaging and presentation
only with real artifacts and conformance. `packages/frameshift-domain` is a
possible future product boundary, not a required empty scaffold.
`packs/frameshift` will hold product workflows/rubrics/evaluations. Generic
compiler, viewer and integration code belongs upstream; the retained v1 code
is removed from the successor path only after its producer export, consumer
adapter and identity migration qualify. Retain one authoritative implementation.

Keep the local Exqlite/SQLite writer and server AshPostgres records separate.
Pure shared packages cannot import application internals or provider I/O. The
workspace gate rejects undeclared Elixir module/path references, native externals
and unreviewed Gleam library operations, including randomness. It also resolves
declared frontend aliases and relative ESM imports through the component graph;
literal dynamic imports obey the same graph, while opaque and glob imports
refuse. New aliases and virtual imports must be declared in `workspace.json`.
These source checks do not sandbox running code.

Each extraction includes dependency locks, canonical migration, affected scripts,
CI, assets, package paths and independent builds. Preserve test fixtures and
accepted historical identities; no wholesale replacement of current code by a
specification-only producer.

**BP-09 — Producer contracts.** Pin Conjunct, Refpath, Wotex, Rivure, DocShell,
ExMaude and phoenix-assets only where the selected execution profile uses them.
Record actual exports and joined consumer conformance. A sibling checkout is
research evidence, not a distributable dependency. Generic fixes belong with the
producer and require a consumer reproduction. Product-specific rules, evidence
and tests stay here. Do not copy private producer code or publish it to resolve
a distribution gap.

[PC-01–PC-09](producer-contracts.md) states the required deliveries from Conjunct,
Refpath, ExMaude, DocShell, the web libraries, Wotex, diagnostics and optional
Rivure. Missing specified implementation is producer work; undecided behavior
is a contract gap. Implement producers and consumer fixtures together without
claiming the joined profile works before its real boundary passes.

Product bundle, physical composition, procedure, application generation,
assessment and external commitment have distinct identities and authority.
Current operator data and secrets never enter portable bundles. Company strategy
and legal interpretation live outside product semantics; applications still
validate and enforce the supplied policy's issuer, subject, scope and revocation.

## Operational architecture

**BP-10 — First-class diagnostics.** Keep the implemented bounded metric catalog,
Prometheus exposition and alert fixtures. Conjunct CJ.07 proposes GreptimeDB as
the shared operated-host destination through qualified Prometheus/OpenTelemetry
interfaces. This is a deployment direction; no GreptimeDB integration or runtime
result is claimed. Exact ingestion, retention, authentication and outage tests
must precede adoption. Structured logs and bounded traces remain required.

CJ.07's reference operated-host direction is the shared Hetzner estate with
Terraform/Ansible, PostgreSQL and independently supervised applications. Map
actual deployment conventions and backup/restore ownership before selecting
systemd or containers. This contract adds no infrastructure and does not mandate
Kubernetes, Kafka or a separate service for each package. Browser/AtomVM or
network-edge execution remains a separately qualified optional profile.

Use Console.app and `log` on macOS, standard collectors on the server, and
immutable audit for domain evidence. Keep geometry/converter and model workers
bounded and isolated from authoritative commands and recovery. Do not introduce
ELK or a second custom log UI. See the [diagnostics contract](diagnostics.md).

Beamlens has one authorized read-only supervision owner and an explicitly
configured BAML provider. Bound frequency, concurrency, context, time and
centrally accounted usage at the actual inference boundary. Redact observations;
model or collector failure cannot disable normal product actions or telemetry.
No diagnostic process may mutate product, authority, device or financial state.

## Milestones and evidence

**BP-11 — Dependency order.** The primary plan is composition and instructions.
D's parts/shopping list remains available independently. Optional transactions
stay on hold and, if resumed, follow D and applicable E qualification. They do
not define completion of the engine-consumer proof or native product.

| Gate | Scope and dependency | Required evidence |
| --- | --- | --- |
| A — Contract foundation | Frameshift product scope, current tree and Conjunct contracts | Owner/API map, preserved v1 identities, explicit migration and aligned specs |
| B — Product host | Existing foundation plus missing auth/diagnostics and producer interfaces | Independent builds, generated contracts, isolation and one supervisor per owner |
| C — Physical profile | Conjunct core compiler/report plus Frameshift profile rules, adaptation and consumer evidence per claimed profile | Existing v1 replay, successor migration, deterministic checks, source/assessment scope; required formal evidence through P2 |
| D — Visual composition and procedures | Corresponding C profile plus relevant B surface | Exact part/feature/step binding, local save/import/export, accessible print/offline output and explicit unknowns; all three classes for complete Frameshift coverage |
| E — Generality and adaptation | B/C; preparation may overlap D | Upstream passive/sensor fixtures, two operator profiles, safe research, restart/revocation/budget and producer-outage evidence |
| F — Optional services, on hold | Separate resumption after D/E | Applicable BC-01–BC-10, producer/provider simulations and available sandbox evidence; no duplicate uncertain effect |

A complete C-to-D frame slice can proceed before the other classes pass. P1
durable-generation and P2 solver-evidence work can run alongside core/viewer
development; they gate their dependent claims. The independent instruction
profile needs no live Refpath/DocShell host, finance or device-control profile.
Synthetic geometry permits instruction development before CAD qualification.
None of these dependency choices waives full claimed frame coverage.

The independent native-product lane is tracked in the
[implementation plan](implementation-plan.md). Codeable refusal, simulation and
recovery work remains required even where credentials, physical samples, source
permissions or release administration are absent. No document or producer status
can substitute for the missing evidence.

## Requirement map

| Area | Canonical contract | Evidence owner |
| --- | --- | --- |
| Product workbench and host | BP-01–BP-11 here | Frameshift host/browser |
| Conjunct boundary and migration | [CI-01–CI-08](conjunct-integration.md) | Producer plus Frameshift consumer |
| Required library deliveries | [PC-01–PC-09](producer-contracts.md) | Named producer, product adapter and joined tests |
| Current frame physical/profile semantics | [PB-01–PB-09](physical-build-contract.md), [artifact layouts](build-artifacts.md) | Shared package/product fixtures |
| Adaptive research/runtime integration | [BO-01–BO-08](build-orchestration.md) | Frameshift packs and producer consumer suites |
| Deferred service scope | [BC-01–BC-10](build-commerce.md) | Enabled service/financial/runtime owners |
| Diagnostics | [Diagnostics](diagnostics.md) | Local and server evidence kept separate |
| Technical research | [Adoption](../research/conjunct-adoption.md), [decisions](../research/build-platform-decisions.md), [thin compositions](../research/thin-composition-evidence.md) | Dated source/inspection records |
| Completion status | [Verification](verification.md) | Named tests and retained results |
