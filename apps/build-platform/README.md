# Frameshift build platform

Phoenix hosts Ash/AshPostgres domains and a Svelte 5/SvelteKit application built
through phoenix-assets. This application has its own PostgreSQL database and
does not read or control the computer application's SQLite state.

The current slice provides immutable catalog source and component profile revisions,
atomic actor attribution, public metadata reads, exact profile downloads, protected Prometheus metrics and an embedded
Refpath host. The planned workbench consumes Conjunct's generic composition and
procedure exports with Frameshift profiles, evidence and commands. Conjunct owns
canonical selection, comparison, CheckReports, parts projection and instruction
semantics; this host owns UI, authorized product state and file/network I/O.
The retained BuildSpec v1 preview supports replay and migration, not a second
workbench engine. No Conjunct package is installed yet. Visual instructions and
printable parts lists share the accepted composition; transactional shop work is
on hold. Remaining work is
tracked in the [verification ledger](../../docs/architecture/verification.md)
and [integration contract](../../docs/architecture/conjunct-integration.md).

## Local development

From this directory:

```sh
docker compose -p frameshift-platform up -d --wait
mise exec -- mix deps.get --check-locked
mise exec -- mix ecto.setup
mise exec -- mix phoenix_assets.gen
cd assets
mise exec -- npm ci
mise exec -- npm run build
cd ..
mise exec -- mix phx.server
```

Open `http://localhost:4080`. The database fixture binds only to loopback port
54329 and uses a separate Compose volume. Its credentials are local fixtures.
Stop it with `docker compose -p frameshift-platform down`; that retains data.

Run `./scripts/check platform` from the repository root with the fixture running.
The lane checks Svelte types/lint/build, dependency advisories, Elixir format/compile/tests/Credo,
generated-contract drift, phoenix-assets production checks and migration drift.
Tests use a separate database and sandbox transactions. CI provisions the same
pinned PostgreSQL image. No provider credentials or frame hardware are needed.

Before the first release, edit original migrations instead of adding alteration
migrations. Use `<timestamp>_install_<integration>.exs` for dependency installers
and `<timestamp>_create_<table>.exs` for tables; keep each table's indexes and
constraints with its creation. Existing development databases may need an
explicit reset after schema edits; setup does not rewrite already-applied
migrations. Preserve needed data before resetting a fixture.

`./scripts/check policy` also resolves frontend ESM imports and declared aliases
through the workspace component graph. Dynamic imports need literal paths;
glob imports refuse at this boundary.

## Boundaries

- `GET /api/sources` reads public metadata, with pages of 50 and a bounded offset.
  Source actor identifiers are excluded from HTTP and generated TypeScript.
- `GET /api/profiles` lists candidate metadata. `GET /api/profiles/:digest`
  downloads exact canonical bytes with a strong ETag and immutable caching.
  Source bindings and actor identifiers remain private. Admission recomputes
  identity and resolves every citation's digest, revision and evidence kind.
- The public page lists candidate profiles and source records with explicit
  qualification limits, manual bounded pagination and exact profile downloads.
  This is catalog inspection, not the composition workbench or build admission.
- Catalog writes are internal Ash actions requiring a typed editor or research
  worker actor. Constructing an actor is not authentication. There is no HTTP
  write route; an authenticated command boundary must precede browser writes.
- URI/revision identities cannot be replaced. Source and audit records commit
  together. An HTTPS locator and digest do not qualify the source's claims or
  authorize fetching it; source acquisition has a separate admission boundary.
- `GET /api/health` returns process reachability without internal details.
- `GET /ops/metrics` requires a bearer token matching
  `FRAMESHIFT_METRICS_TOKEN` (at least 32 bytes). Missing configuration denies
  access. Only bounded labels are exported; the response is not cacheable.
  Fixed histogram buckets do not retain samples between scrapes. Reset and
  sampling timestamps expose collection gaps. See the [operating setup](ops/README.md).
- Refpath is pinned to the researched Git revision and owns its `refpath`
  PostgreSQL schema. It reuses the host's pool and PubSub. API/MCP/watchers,
  plugin runtime, optional model serving and automatic Beamlens are disabled.
  Its public migration installer runs through a host-owned migration.
- Beamlens is an explicit dependency. No diagnostic agent is started or provider
  inferred by this slice; the bounded integration remains a separate B/E gate.

## Reviewed seed data

An administrator can explicitly import `../../data/physical` through
`mix frameshift.seed_catalog --actor UUID --directory ../../data/physical`.
Supply the UUID for the accountable local operator. This command does not
authenticate browser users. It fetches no remote source, and it never runs at
application startup. Each immutable source/profile and its audit event commit
together; a partial import can be retried without replacement or duplicate audit
events. Conflicting revisions fail. Imported baseline profiles remain candidates
with unresolved assembly constraints.

## Deployment inputs

Production requires `DATABASE_URL`, `PHX_HOST`, `SECRET_KEY_BASE` and `CLOAK_KEY`
(base64 encoding exactly 32 random bytes); optional
`PORT` and `POOL_SIZE` default to 4080 and 10. Serve behind the deployment's HTTPS
termination. Database migrations and the frontend build are explicit deployment
steps. Production never falls back to the local database or development secret.
Public HTTP has no mutation actions or session credentials in this slice.

The runtime repository is private. CI needs a `REFPATH_READ_TOKEN` secret with
read-only repository contents access. That external credential is not stored
here or required for customer configuration. Repository visibility stays under
the maintainer's control. Native runtime dependencies use the pinned Rust toolchain.

AshPostgres uses Refpath's published, pinned dynamic-repository fork. This is
required for upserts through the shared host pool; ordinary reads alone do not
qualify the integration. The test suite covers repeated upserts and migrations.
See the [dependency qualification record](../../docs/research/build-platform-decisions.md#embedded-runtime-dependency-qualification-2026-09-24)
for compatible native/numerical pins and the three scoped advisory exceptions.

The pinned frontend `cookie` override upgrades SvelteKit's transitive legacy
parser to 0.7.2 for its published security fix. Keep the override until the
upstream constraint admits a patched compatible version. `npm audit` currently
reports no advisories; this is dependency evidence, not an application audit.
