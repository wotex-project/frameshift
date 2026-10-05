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
Directory opens use OTP's explicit `directory` mode, and synchronization must
succeed before acknowledging publication. Refused/unsupported directory sync is
an error, never an inferred pass. The API is checked against [OTP 29.1 `file`](https://github.com/erlang/otp/blob/OTP-29.1/lib/kernel/src/file.erl)
(`open/2`, source blob `bac83444cf5974b3f9a14057f5b4f4ec8c792001`, retrieved
2026-10-04). Local macOS and pinned Linux/OTP directory-open/sync joins establish
syscall acceptance; they do not qualify physical power-loss durability.
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
Failures before publication leave the destination absent and the source backup
untouched. Failed parent sync after rename returns `{:commit_uncertain, reason}`
and preserves the published destination for deliberate offline verification;
it never deletes or overwrites it or reports committed success. Restore
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

## Ubuntu administrative entrypoint

The DEB exposes `/usr/bin/frameshift-maintenance` with the same `backup
DESTINATION`, `verify BACKUP` and `restore BACKUP DESTINATION` operations. Only
the dedicated nonroot service UID may invoke it. An administrator first stops
the complete service (`systemctl stop frameshift.service`) and uses `runuser -u
frameshift -- ...`; control/observer membership alone grants no offline database
or credential access. The command never stops the service automatically.
When a systemd manager is present, backup/restore first require an `inactive`
unit from a bounded two-second, clean-environment status query; unknown, active,
activating, deactivating or failed state refuses. Verification skips this check.

The managed service and offline backup/restore take an exclusive nonblocking
Linux flock on the real, admitted `/var/lib/frameshift` directory. The managed
service execs through `flock --no-fork`, so the actual systemd main VM inherits the
lock descriptor. Offline backup/restore retain their supervising flock process.
Inherited custody may prolong refusal until those processes exit. Contention
exits 69 before the child starts. The managed unit initially signals only its main
VM, then kills any remaining control-group processes after its exit or deadline;
helpers must survive long enough for OTP's confirmed native shutdown.
Use the directory inode rather than a writable/removable lock filename. Its
service UID, primary GID and exact 0700 mode are checked before locking. Existing
live/default command-socket checks remain required. This serializes managed
entrypoints; it does not authorize direct competing database VMs or substitute
for stopping the whole systemd control group. Never delete/replace the data
directory to clear an active lock.

`verify` reads only its named backup and may run while the host is active; it
needs no service-writer lock. All maintenance operations run a clean, bundled,
non-distributed VM with fixed data/socket/TMPDIR and disabled crash dumps. Caller
runtime/environment values cannot redirect service custody. Paths are argv data,
never shell or evaluated source. Each path is bounded to 8192 bytes. Usage exits
64, wrong role/custody or lock contention exits 69, and the existing Library
maintenance result exits 0/1 without printing arbitrary errors or key bytes.

Package configuration calls the root-owned `provision-runtime --maintenance`
helper. It creates only absent `/var/backups/frameshift` (0700, service primary
UID/GID) under a real root-owned 0755 `/var/backups`; unsafe existing type, mode,
owner or group refuses without normalization. It does not create a backup.
The service's normal pre-start helper does not grant writes outside its existing
systemd roots. An operator can place explicit absent exports/restored candidates
under this private backup root; other destinations require deliberate filesystem
access granted to the service UID. Removal/purge retain the backup root and all
its contents. These copies are outside the registered-object quota and need
operator-managed capacity; there is no automatic export or deletion policy.

A restore candidate cannot replace `/var/lib/frameshift` or merge into an existing
store. The candidate contains only Library data, with no credential directory,
package watermark, release configuration or import/native unknown-custody fences.
Adopting it as an installation remains a stopped administrator operation that
preserves the exact package-version and identity-recovery evidence; no command
implicitly resets custody or downgrades data. Qualified filesystem/power evidence
and encrypted private-key backup remain separate from container backup checks.

Acceptance joins the actual DEB commands to a nonroot service, checks concurrent
managed start/maintenance refusal before socket creation as well as live-core
refusal, exports and verifies exact original/pixel/receipt content, rejects corrupt
or existing restore destinations, and reads the restored Library in a fresh VM.
The packaged identity command installs/replays a real certificate/key PEM under
its protected-file contract, resolves it as the service UID and refuses other
roles. Backup/restore and remove/purge preserve private identity bytes without
including them in an artwork export. Booted systemd, physical storage and
administrator encrypted-key restore remain separate acceptance tiers.

The source-bound booted arm64 fixture separately joins actual manager ownership,
service-UID backup/verification/restore, exact PNG/JPEG/receipt readback and
created-key resolution to the numeric-version package lifecycle. Byte/mode/owner,
authoritative-table and retained-audit comparisons pass across the exercised
update/remove/purge/reinstall phases. The qualification is split by a VM disk-pressure
interruption; an uninterrupted fresh fixture remains required. Restored artwork
continues to exclude private keys, watermark and temporary custody. This evidence
covers the observed shared kernel and filesystem; it does not qualify encrypted
identity restore, physical power loss or another Ubuntu configuration.

APFS, supported Linux filesystems, Pi storage, full-disk behavior, and
power-interruption durability require target-specific qualification before a
release claim. This contract does not authorize repository visibility changes.
