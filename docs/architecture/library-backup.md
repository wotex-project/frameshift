# Library Backup and Restore

**Status:** required host storage contract; software evidence is separate from
power-loss and target-filesystem qualification.

## Format

A version-one backup is one directory containing `metadata.sqlite`, an
`objects/sha256` tree, a `trash` tree, and a canonical `manifest.json`. The
manifest identifies the format version, exact database SHA-256, and every
SQLite `objects` row by digest, byte count, and active/trash placement. The
manifest contains no Keychain secret or transient IPC token. Its digest checks
detect corruption, not a malicious replacement of the whole backup.

## Creation

The library's single writer serializes the entire export against imports,
collection, pairing, outbox changes, and other mutations. It creates a private
sibling staging directory, runs SQLite `VACUUM INTO` for a consistent database
snapshot, then copies each object named by the authoritative snapshot. Source
and copied bytes must match their digest and size. It writes and syncs the
manifest last, verifies the complete staging directory, and publishes it with
one rename. An existing destination is never overwritten. Failed or interrupted
staging remains non-activatable and can be removed without touching the library.
SQLite documents `VACUUM INTO` as a consistent live backup and notes that
interrupted output may be corrupt: [VACUUM INTO](https://www.sqlite.org/lang_vacuum.html#vacuuminto).

## Restore

Restore runs with the destination library stopped and installs into an absent
data directory. It stages the backup on the destination filesystem, checks
the manifest, database and every named object digest and size, then runs
`PRAGMA integrity_check` and `PRAGMA foreign_key_check`. Protected current,
previous-known-good, queued, and playlist references must resolve to verified
objects. It rebuilds the derived FTS5 index because vacuuming may change
unkeyed rowids. Only then does it rename the staged directory into place.
Failures leave the destination absent and the source backup untouched. Restore
does not assert that a frame displayed a queued image or transfer Keychain
private keys to another Mac; a moved installation requires re-pairing.

Linux protected PEM identity is also outside the artwork backup. Backup/restore
copies only the opaque certificate-bound reference in paired metadata; it never
copies the configured credential directory or key bytes. An administrator restores
the same verified identity separately from an encrypted key backup or physically
re-pairs the frames. Missing keys preserve pending intent and unavailable transport;
artwork restoration never generates replacement keys or resends a consumed secret.
See [Linux credential custody](../host/linux.md#protected-file-credential-resolver).

## Packaged maintenance command

The packaged macOS app exposes `Contents/Resources/bin/frameshift-maintenance` with
`backup DESTINATION`, `verify BACKUP`, and `restore BACKUP DESTINATION` commands.
`backup` reads the configured `FRAMESHIFT_DATA_DIR` (or the normal per-user
Frameshift data directory). The app and its core must be stopped before backup:
the command refuses a live core or a socket whose ownership cannot be proved.
An abandoned Unix socket with a refused connection is tolerated after an
unclean shutdown; a listening socket or a non-socket at that path is refused.
It also requires an existing `metadata.sqlite` so a typo cannot silently create
an empty library. The command starts the single-writer library solely for the
export, then stops it. That startup may apply pending schema migrations, so
maintenance should use a release compatible with the library.

`verify` reads only the named backup. `restore` installs into the explicit,
absent destination data directory and refuses a live core at that destination.
The command never replaces a running or existing library. Operators can first
restore to a separate location and test it using `FRAMESHIFT_DATA_DIR`; choosing
to replace an installation is a separate, deliberate filesystem operation.
Each command prints one result and exits nonzero on failure. User paths are
passed as data to a fixed release entrypoint, never interpolated into Elixir
source. Packaged-app tests exercise backup, verification, corrupted input,
active-core refusal, and restore through this public command.

APFS, supported Linux filesystems, Pi storage, full-disk behavior, and
power-interruption durability require target-specific qualification before a
release claim. This contract does not authorize repository visibility changes.
