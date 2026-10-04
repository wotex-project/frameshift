# Portable Host Core

**Status:** normative architecture; implementation and platform qualification are separate
**Scope:** host software on macOS, Linux, and Raspberry Pi-class Linux computers

## Decision

Frameshift has one portable Elixir/OTP host core and platform-specific shells and
adapters. The macOS menu-bar app is the first shell, not the definition of the
core. A Raspberry Pi may run the host or a separately qualified powered frame
or bridge; those roles must not be conflated. MCU-class reference frames remain
independent of the host operating system.

The core is not a web application. Do not add Phoenix, a general-purpose HTTP
UI/control server, Ash, or an external database merely to organize the host.
Keep the local authenticated IPC boundary. A future platform may provide a
different local transport behind the same versioned command and diagnostics
contract. Remote control is a separate security decision, not an accidental
consequence of a framework dependency.

## Domain boundaries

The core exposes product operations, not SQL tables or framework resources:

| Boundary | Owns |
| --- | --- |
| Library | Immutable masters, recipes, artifacts, labels, search, pins, recoverable removal, and content reference rules |
| Frames | Paired identity, admitted Thing Descriptions, capability state, and a read projection of display state |
| Delivery | The authoritative desired, confirmed displayed, and previous-known-good transition; durable push intent, sleeping pull outbox, revisions, acknowledgement, reconciliation, and safe retries |
| Rendering | Deterministic jobs, profiles, artifact identity, deadlines, and supervised worker lifecycle |
| Generation | Provider contract, preflight, provenance, recipe caching, cancellation, and explicit cloud consent |
| Diagnostics | Redacted audit history, bounded operational logs, metrics, health, and correlation identifiers |

The [qualification contract](qualified-generations.md) joins an admitted
renderer build, frame profile, and transfer binding for new work. A work digest
then pins that binding to one source and recipe. Qualification decisions are
pure; the existing single writer persists admission, selection, work, and
delivery intent without splitting cross-context transactions.

The [domain map](domain-map.md) defines the vocabulary, transition ownership,
and atomic invariants. These are boundaries inside one host process, not a
mandate for separate GenServers or databases. Each boundary has documented
public commands and queries, typed outcomes, and tests for its invariants.
Domain decisions and state transitions do not depend
on Ecto schemas, IPC JSON, Swift types, or operating-system APIs. Persistence
modules map between domain values and stored rows. Cross-boundary workflows
have an explicit owner; splitting a module must not split an atomic invariant.
Avoid generic repository interfaces where there is only one implementation:
introduce a port when it isolates a real platform or external-system boundary.

## Persistence decision

The [library backup and restore contract](library-backup.md) defines verified
offline activation and recovery alongside this storage boundary.

SQLite remains the embedded metadata store; content-addressed files remain
the byte store. The accepted [D-010](../decisions/README.md#d-010--host-metadata-boundary)
keeps direct Exqlite and numbered SQL migrations. The
[embedded persistence review](../research/embedded-persistence.md) rejects a
second authoritative database for this ledger. Neither Ecto schemas nor an
Ash resource layer define the domain model. Change the driver only for a
measured defect while retaining SQLite's database-enforced invariants.

One writer owns mutations. Keep a single write connection, immediate
transactions, a finite busy timeout, foreign keys, WAL, and
`synchronous: :full` to retain the existing crash contract. Read
concurrency may be added only after measuring a need and proving snapshot
semantics. The store must preserve digest checks, uniqueness, referential
integrity, replay receipts, monotonic delivery revisions, and audit records.
SQLite-specific `STRICT` tables and checks remain explicit migration SQL;
the data access layer must not weaken database-enforced invariants. File writes
and database commits are not one atomic transaction: retain the stage, flush,
rename, commit ordering and startup reconciliation described in
[software stack research](../research/software-stack.md#host-persistence).
Backup takes a consistent SQLite snapshot plus a manifest of referenced
objects, protecting those objects from collection until the copy completes;
restore verifies database constraints and object digests before
activation. Text search begins with SQLite FTS5 after target-build support is
verified. Search indexes are rebuildable projections, never display or custody
truth.

Because no product release has shipped, edit original table definitions,
indexes, and constraints directly rather than add alteration migrations or
maintain a public upgrade path. Development data is still user data: verify
fresh schema creation and restart behavior, and document any deliberate reset;
never silently discard a working library. Schema changes must keep observable
product behavior and crash-safety tests intact.

## Platform ports

The portable core may use OTP, SQLite, local filesystem primitives, and the
versioned frame protocol. It may not call Keychain, Apple Vision, Core Image,
MediaGenerationKit, Service Management, or macOS-specific path conventions
directly. Place these behind narrow adapters:

- credential identity and signing, with opaque references in core state;
- import/decode, classification, preview, and optional local AI capabilities;
- user-data location, secure directory creation, process lifecycle, and local
  IPC endpoint;
- discovery and OS notifications;
- platform-built Zig renderer executable and any hardware-specific acceleration.

The Mac shell supplies Apple adapters. A Linux/Pi host supplies Linux adapters
and a shell appropriate to that platform; unavailable optional capabilities
are reported explicitly and cannot silently switch to a cloud provider.
Platform selection occurs at the composition root, not throughout the domain.
The renderer wire contract and WoT semantics are shared across hosts.
The small pure capability/transition decision kernel is shared with the public
browser guide through Gleam's Erlang and JavaScript targets. It owns no I/O or
authoritative display state; see the
[installation guide contract](install-and-guide.md).

## Diagnostics contract

The [diagnostics contract](diagnostics.md) defines three separate signals:
durable audit entries for state changes, operational logs for causal detail,
and bounded metrics for rates, latency, backlog, and health. The core emits
named telemetry events and retains bounded local aggregates so closing the UI
does not erase measurements. On macOS the shell writes native logs and drains
structured core records through a supervised pipe bridge to Apple unified
logging, readable through Console.app and `/usr/bin/log` without a Frameshift
log UI. A versioned read-only diagnostic IPC client reads
health, metrics, and paginated audit through the core; it does not open SQLite.
Every command and delivery attempt carries a correlation ID across audit,
logs, and displayed state. Credentials, artwork bytes, and full prompts are
excluded by default. Export is explicit, redacted, and local. No general HTTP
metrics endpoint or automatic remote telemetry is part of this architecture.

## Qualification

Before calling the portable core complete, prove the following on macOS and a
supported Linux/Pi host configuration:

1. The same domain and protocol suites pass without platform conditionals in
   domain modules; platform contract tests cover each adapter.
2. A clean release starts with user-only data and IPC paths, imports and renders
   a master, restarts, and retains committed data.
3. Interrupted file placement, database transactions, delivery, and renderer
   processes recover without false display acknowledgements or lost protected
   artwork.
4. Concurrent commands preserve single-writer and idempotency guarantees;
   SQLite lock behavior and bounded waits are tested.
5. Diagnostics can reconstruct a failed update from command through physical
   display state without exposing secrets or needing the UI to remain open.
6. Native dependencies and the Zig worker build for each supported CPU/OS
   target; optional Apple capabilities fail closed on Linux.

Relevant upstream behavior: [SQLite WAL](https://www.sqlite.org/wal.html),
[SQLite backup API](https://www.sqlite.org/backup.html), and
[Gleam targets](https://gleam.run/documentation/command-line-reference/).
