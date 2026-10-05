# SQLite and Elixir boundary

**Status:** prototype-selected
**Updated:** 2026-10-05

## Decision

The current host implementation uses Exqlite directly behind one Frameshift-owned
OTP process. Ecto is not part of the initial persistence boundary. The choice
remains subject to macOS bundle, migration, crash-recovery, and license review
before a prototype release.
The broader engine comparison in [embedded persistence](embedded-persistence.md)
keeps SQLite as the authoritative store across all specified hosts.

## Question

Which SQLite boundary gives the Elixir core one durable metadata owner without
duplicating domain state or adding an external database process?

## Repository context

`docs/host/macos.md` assigns metadata ownership to the Elixir core and names
`metadata.sqlite` as the store. `docs/architecture/implementation-plan.md`
requires transactional migrations, restart durability, cache reuse, and
reference-safe removal. The repository forbids project-owned Python tooling
and keeps custom raster code outside the BEAM.

## Evaluation criteria

The boundary must:

- support transactions, foreign keys, prepared parameters, and a single
  serialized writer;
- run inside the per-user host process without a separate database service;
- keep SQL and migrations visible in the repository;
- build on current Apple Silicon without Python;
- have a license that can remain under review while the project license is
  unresolved.

Ecto is not disqualified, but its schema and migration abstractions are not
needed for the first store owner. A command-line `sqlite3` port would add an
external executable and a second framing/error boundary without removing the
need for ownership and migration code.

## Evidence

### Locked Exqlite 0.42.0

Exqlite exposes supervised connections, parameterized queries, and transaction
functions. Its documentation warns that prepared statements are mutable and
must not be manipulated concurrently, and that SQLite does not support
simultaneous writing through the driver. Those constraints fit one
Frameshift-owned store process. The package is MIT-licensed and includes a
precompiled macOS NIF path. This is upstream source and package evidence, not a
notarized Frameshift bundle result.

The current lock selects Exqlite 0.42.0, exact upstream tag commit
`991c71fe354c07b11e109dd5263bc8a4686911a3`. Nineteen published source files
(`Makefile`, `mix.exs`, license, `lib/` and `c_src/`) match the tag's Git blobs.
The [release notes](https://github.com/elixir-sqlite/exqlite/releases/tag/v0.42.0)
identify nonblocking statement cleanup for a busy connection; the
[C implementation](https://github.com/elixir-sqlite/exqlite/blob/991c71fe354c07b11e109dd5263bc8a4686911a3/c_src/sqlite3_nif.c)
and current single-writer rollback tests are the applicable boundary evidence.
Observation and source comparison: 2026-10-05.

The bundled amalgamation reports SQLite `3.53.4` with source ID
`2026-07-24 19:02:57 bf7c7f30031888f4e796e429ab3978879485813aaca6f641c7b33e4e09459bcc`.
`scripts/check-linux-codec-owner` copies only locked native source and portable
BEAM files into its private build context. The pinned Rust/Debian builder
compiles SQLite and Exile against the pinned Linux OTP 29.1.1 headers using
their upstream Makefiles; host Mac NIFs are excluded. The resulting nonroot
arm64 and emulated amd64 joins check SQLite version, FTS5, thread-safe mode and
integrity, actual actor-bound PNG registration and fourteen receipt tests for
rollback, restart, exact result replay and verified backup/restore. These are
Debian/Linux software joins, not installed Ubuntu, hardened Mac or filesystem
power-loss qualification. The amd64 emulator's documented single JIT mapping
does not establish native amd64 default-mapping behavior.

### SQLite transactions and WAL

SQLite documents rollback journals as its default atomic commit mechanism and
WAL as an alternative journal mode. Frameshift will enable foreign keys and WAL
on its connection, use explicit transactions for related metadata changes, and
keep immutable artwork bytes outside the database. These settings do not prove
recovery until the repository's interruption tests and macOS lifecycle tests
pass.

## Conflicts and uncertainty

Exqlite calls SQLite through dirty NIFs. A defect in that dependency does not
have the process isolation required of the project-owned Zig raster worker.
The dependency is selected because SQLite is the specified metadata engine and
the host needs an in-process driver, but it does not inherit the renderer's
crash-containment claim. Release qualification remains mandatory.

The project license is unresolved. MIT is permissive, but the complete release
license inventory still needs approval. Current source inspection also does not
prove hardened-runtime, signing, notarization, sleep/wake, or upgrade behavior.

## Analysis

One domain process serializes every metadata mutation and is the only module
given the database connection. Direct Exqlite keeps transaction boundaries
next to the invariants they protect and avoids a second application state model.
SQL migrations remain numbered files executed in one transaction. Read paths
also pass through the owner in the current implementation; this can be measured
before adding any read pool.

The content-addressed file store commits bytes with a temporary file, sync, and
rename before inserting metadata. Startup reconciliation may retain orphan
files for later inspection but must never delete a referenced, pinned, queued,
current, or previous-known-good object.

## Result

**State:** prototype-selected

Use the locked Exqlite 0.42.0 behind one supervised `Frameshift.Library` process. Enable
foreign keys, WAL, and full synchronous writes. Exercise transaction rollback,
process restart, database reopen, orphan reconciliation, and protected-object
collection in automated tests.

The choice is rejected for a prototype release if the macOS bundle cannot load
the NIF under the hardened runtime, crash testing corrupts committed metadata,
or the final project license review rejects a transitive component.

## Follow-up

- Run the packaging and lifecycle gates from `docs/host/macos.md` on a signed
  development build.
- Exercise power/interruption boundaries on copies of representative metadata.
- Reassess Ecto only if migrations or queries become difficult to audit, not as
  a speculative abstraction.
- Complete the repository license decision before distribution.

## References

- [Exqlite locked source](https://github.com/elixir-sqlite/exqlite/tree/991c71fe354c07b11e109dd5263bc8a4686911a3), inspected
  2026-10-05.
- [Exqlite README and caveats](https://exqlite.hexdocs.pm/readme.html),
  retrieved 2026-09-22.
- [Exqlite 0.42.0 package](https://hex.pm/packages/exqlite/0.42.0), source matched
  2026-10-05.
- [SQLite write-ahead logging](https://www.sqlite.org/wal.html), retrieved
  2026-09-22.
- [SQLite PRAGMA reference](https://www.sqlite.org/pragma.html), retrieved
  2026-09-22.
