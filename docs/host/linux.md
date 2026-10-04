# Linux and Raspberry Pi Hosts

**Status:** normative platform-port requirements; no Linux/Pi release is yet qualified

## Roles

Ubuntu on amd64 or arm64 is the general Linux host. Raspberry Pi 5 with
supported Ubuntu Server arm64 is a headless host using the same application
release contract. A Pi 5 Nerves image is a separately packaged dedicated
bridge/appliance. These are external hosts or bridges; no Raspberry Pi is part
of a Frameshift reference-frame bill of materials.

All roles consume the same domain commands, frame protocol, immutable library,
qualification identities, and authoritative Delivery state. Optional Apple
Vision, MediaGenerationKit, Keychain, and UI facilities report unavailable
through explicit adapters. Local import and rendering remain usable without
an AI provider. A Linux graphical shell is a separate UI qualification; the
headless service and local command/diagnostic CLI are the initial Linux
interface.

## Ubuntu host

- Package target-specific OTP and Exqlite releases plus the native Zig raster
  worker; verify all NIF/shared-library dependencies on clean supported images.
- Run as an unprivileged dedicated service identity through systemd, with
  private state and runtime directories, bounded resources, restart policy,
  and an explicit stop/disable/remove path. The service must not run as root.
- Use separate command and read-only diagnostic Unix sockets with peer
  credentials and private permissions. An administrator grants command access
  to an explicit local control group and diagnostic access to a distinct
  observer group; commands retain durable replay receipts and user attribution.
  Before changing permissions or binding either socket, the service checks the
  directory itself with `lstat` and rejects a symlink or non-directory without
  touching its target. It refuses to replace a live socket. Group ownership
  and admission need installed Linux tests; the current Mac private-user socket
  policy does not establish that access model.
  Each accepted Linux connection reads the kernel PID, UID, and primary GID
  from `SO_PEERCRED` on the connected Unix stream socket. If the named OTP
  socket option is unavailable, the adapter uses the Linux native option and
  validates the exact 12-byte structure before accepting those fields. A read
  error or malformed credential fails closed. The primary GID does not prove
  supplementary group membership; filesystem permissions on the group-owned
  socket enforce that access, while the peer UID supplies attribution.
  A container contract test must exercise the actual Linux kernel and the
  pinned OTP release; a same-UID result alone does not qualify group admission.
  The Linux CLI must cover import, target discovery/pairing, send, state, and
  recovery as well as diagnostics. No general LAN control endpoint is exposed.
- For import, the CLI opens the caller's file and streams bounded bytes into a
  service-owned staging area over authenticated local IPC. The service does
  not follow caller-provided filesystem paths or require access to the caller's
  home directory.
- Use journald for redacted operational logs and `journalctl` for reading them;
  keep SQLite audit and bounded metrics separate. Ship `frameshiftctl` for
  read-only health, metrics, and audit queries alongside its authenticated
  local command surface.
- Provide a credential adapter with protected file or systemd credential
  loading. TPM-backed encrypted credentials are used only where the selected
  installation supports them; no private key goes into a unit environment
  variable or the metadata database. Define backup and identity-recovery paths.
- Store artwork and SQLite metadata on a qualified local filesystem. Install,
  upgrade, downgrade rejection, database migration, full-disk, power-loss, and
  backup/restore tests run on amd64 and arm64.

### Group-owned diagnostic endpoint

The initial group boundary is read-only diagnostics. Configure an explicit numeric
observer GID (canonical decimal, 1–4294967294) with `FRAMESHIFT_DIAGNOSTICS_GID`
and a diagnostic socket directory separate from the command directory. Omitted configuration retains the private
same-UID endpoint. An invalid GID, unsupported OS, root/changed service identity,
wrong directory owner or unsafe final target refuses before endpoint admission;
there is no automatic switch from group access to private access.

The Linux service verifies its real/effective/saved/filesystem UID fields from
a bounded `/proc/self/status` read, requiring one nonzero identity. It owns the
final directory, changes only its group to the configured GID and admits exact
mode `0710`; a bound pathname socket must have that owner/GID and mode `0660`.
Final symlinks and non-socket placeholders are refused before permission changes.
The service remains unprivileged and must already have permission to assign the
configured group. Provisioning the user/group is a package/operator action,
not an IPC request or a runtime call to `useradd`.

Linux pathname connect permission enforces primary or supplementary membership
in the observer group. The server also requires valid kernel `SO_PEERCRED`
PID/UID/primary-GID data and never treats primary GID as the supplementary-group
list. A connected descriptor retains its connection-time identity; this finite,
one-request endpoint cannot promise to revoke a connection after group changes.
Root remains an OS administrator able to bypass filesystem discretionary access;
this boundary does not claim isolation from root or a compromised service owner.
Caller JSON cannot select its UID, GID, group policy or mutation authority.

Acceptance runs as a nonroot service in the pinned Linux/OTP container. It checks
exact inode modes/ownership, supplementary-group access with a different primary
GID, denied group access, unavailable peer credentials, live socket custody and
root/wrong-owner/symlink refusal without changing target permissions. Native Mac
checks retain the private endpoint. The joined dispatcher uses a finite fixture
store without loading host-built SQLite NIFs: this establishes socket admission
and read-only dispatch, not Linux database/release qualification. The credential
adapter shares malformed/truncated/sentinel byte fixtures with the command
transport; they establish decoder refusal rather than altered kernel credentials.
Installed systemd/group provisioning, the complete Linux command surface, full
CLI, streamed import, credentials and DEBs remain
separate software and installation work.

Source checks on 2026-10-04: [Linux pathname socket permissions and peer credentials](https://man7.org/linux/man-pages/man7/unix.7.html)
and [proc status identity fields](https://man7.org/linux/man-pages/man5/proc_pid_status.5.html).
These define the OS boundary; the joined kernel fixtures establish its consumer
behavior rather than inferred compatibility with a supported Ubuntu release.

### Group-owned command endpoint and receipts

`FRAMESHIFT_CONTROL_GID` explicitly selects the Linux command policy. It requires
an admitted observer GID with a different numeric value and a separate socket
directory. Both groups follow the same nonroot service ownership, final inode,
`0710` directory and `0660` socket checks. An omitted control GID retains the
Mac/private launch-token policy; group access never shares that token. Invalid
or mixed policy refuses before consuming bootstrap input or opening listeners.
The group request identifies the policy with the exact public `auth: "peer"`
marker. It supplies no secret and cannot select an actor identity.

For the existing packet-framed command transport, the service reads Linux
`SO_PEERCRED` through the public OTP `inet:getopts/2` raw option and requires the
exact twelve-byte native PID/UID/GID structure. The request is dispatched only
after final directory/socket custody and kernel credential checks. PID and
primary GID are connection-time context; the UID is the persisted local actor.
Linux UID attribution identifies an OS account, not a person or stable identity
after administrator reassignment of that numeric UID. Root remains an OS
administrator and may connect; the service itself must remain nonroot.

The global bounded command ID, canonical payload digest and actor UID jointly
identify a receipt. The original unreleased CREATE definition adds nullable
`actor_uid`; null is the existing launch-token authority and is distinct from
any Linux UID, including zero. Another actor reusing an ID refuses with
`command_id_conflict` before execution or completion. Same-actor completed
receipts replay their terminal outcome; pending claims remain unknown and never
execute again automatically. Claim/completion and their audit facts remain
single-writer transactions. UID is retained in the private receipt; diagnostic
audit exposes a bounded hash of the policy/UID as `actorId`, with no username,
PID, group list or raw UID. This is correlated attribution, not anonymization.

Ordinary bounded product commands (settings, pin/removal/restore, metadata,
playlists, queue/reconciliation) and existing finite reads use this endpoint.
Group-mode `importFile` and `recordVision` refuse before a claim: caller paths
must not reach the service, and Apple observations require their native adapter.
The standalone pair/recover operations also refuse until their Linux credential
and actor/receipt join is defined. Streamed import, pairing, protected signing
credentials, discovery, the CLI and installed packages remain required work;
this admission slice does not qualify a complete Linux application.

Acceptance combines real nonroot Linux sockets and supplementary control-group
clients with fresh-schema SQLite tests for actor conflicts, pending/failed/success
replay, identity-checked completion, restart/backup retention and atomic audit.
Malformed native credential bytes, unsupported OS and closed descriptors refuse.
Mac token authentication and packaged IPC keep their existing contract.
The public raw option was checked in [OTP 29.1 `inet:getopts/2`](https://github.com/erlang/otp/blob/OTP-29.1/lib/kernel/src/inet.erl)
on 2026-10-04 (source blob `97d826a2d240b42ab8c7dedffb35607a1cb50e04`).

### Bundled local CLI

The Linux CLI runs `Frameshift.CLI` in the packaged OTP runtime with a clean,
non-distributed boot. It does not start the application, load runtime service
configuration, read the service release cookie, open SQLite or require a customer
Elixir installation. A release overlay places `bin/frameshiftctl` beside the
service launcher; package install supplies the public policy values and runtime
socket paths. Development/source checks are not installed-DEB qualification.

The CLI defaults to `/run/frameshift/control/c.sock` and
`/run/frameshift/observer/d.sock`; `FRAMESHIFT_SOCKET_PATH` and
`FRAMESHIFT_DIAGNOSTICS_SOCKET_PATH` override those paths. Installation configures
the service to match those separate endpoints.

Each socket exchange requires explicit canonical numeric `FRAMESHIFT_SERVICE_UID`
and the selected `FRAMESHIFT_CONTROL_GID` or `FRAMESHIFT_DIAGNOSTICS_GID`. The
client checks final directory/socket owner, GID and exact `0710`/`0660` modes,
connects through Linux pathname permissions, then checks the kernel server UID
against the configured service identity before sending any request. A path,
server response or CLI JSON cannot supply the trusted UID. Managed ancestors and
installed root-owned policy provisioning remain installation acceptance work.
A replaced/wrong-owner endpoint, unavailable peer credentials or mismatched
server identity refuses; there is no token, TCP or database fallback.

`diagnostics health|metrics|audit` uses the observer socket with optional bounded
cursor/limit on paginated queries. `state`, `metadata ID`, `recovery [--after ID]`
and `storage` use finite existing command reads. Initial mutations are
`instruction TEXT`, `select TARGET`, `send ITEM TARGET`, `reconcile TARGET`,
`pin ID`, `unpin ID`, `remove ID`, `restore ID`, and `resume TARGET REVISION`.
Every mutation requires an explicit `--id COMMAND_ID` of 1–64 UTF-8 bytes; the
CLI neither invents an ID after failure nor automatically retries an exchange.
Arguments map to existing product commands and cannot supply an actor UID.
Import, discovery/pairing, metadata editing, storage editing and playlist creation
remain required CLI work until their dedicated argument/adapter contracts land.

Requests retain 64 KiB/8 KiB framing bounds and responses 1 MiB/256 KiB bounds.
The connection and send use finite deadlines; the response has one absolute
30-second deadline, including all partial reads, and bounded duplicate-key-aware
JSON admission. The response must match protocol version and request ID and
contain a valid success/error envelope. Output is canonical JSON plus a newline;
no private socket path, input artwork, raw exception or credential is printed.

Exit codes are 0 for a validated success/help/version, 2 for a validated domain
refusal, 64 for usage/policy errors, 69 for unavailable/invalid read exchanges or
pre-send admission failure, and 75 when a mutation may have been sent but its
validated outcome is unavailable. Exit 75 explicitly reports
`command_outcome_unknown`; callers reconcile with the same command ID. A closed,
truncated, oversized, mismatched or hostile response never becomes success.
Receipt conflict and pending outcomes remain the server's authoritative results.

Acceptance runs pure argument/refusal fixtures, real socket wrong-peer/framing
checks, the actual nonroot Linux application/CLI join and a clean production
release invocation with no development tools in PATH. That clean CLI invocation
must work without service credentials or a renderer variable and must not create
application state. Target-specific Linux OTP/NIF/renderer closure and install
permissions remain independent package qualification gates.

## Nerves Pi 5 bridge

Use the official `nerves_system_rpi5` as the base when a dedicated appliance
provides value beyond Ubuntu. Its firmware and root filesystem are updated as
a Nerves image, with persistent application data on `/data`. The bridge must
validate newly booted firmware or revert; signing and anti-rollback policy are
release gates. If it hosts the full library, SQLite and objects reside on
`/data` and pass the same storage tests; a simple relay bridge need not hold a
second authoritative library.

Nerves has no systemd journal. Send sanitized OTP operational records to a
bounded circular `logger_disk_log_h` sink on persistent storage and expose the
same diagnostic CLI contract. A hardware-backed device identity such as
NervesKey is a candidate only after physical provisioning and replacement
tests; otherwise the image must disclose and qualify its chosen custody
method. A NervesHub service is optional, not required for local artwork.

## Qualification

Record exact OS/image, CPU architecture, OTP, NIF, renderer, filesystem, and
storage medium. Run portable contract suites, clean install/update/removal,
network partition, denied credentials, power interruption, and independent
frame interoperability. Measure idle CPU, memory, wakeups, storage wear, and
the metrics/log disk ceiling. A Pi appliance claim additionally needs signed
firmware recovery, physical service access, and secure identity provisioning.

Upstream evidence: [Linux Unix sockets and `SO_PEERCRED`](https://man7.org/linux/man-pages/man7/unix.7.html),
[OTP socket options](https://www.erlang.org/doc/apps/kernel/socket.html),
[Nerves Pi 5 system](https://github.com/nerves-project/nerves_system_rpi5),
[NervesHub firmware signing](https://docs.nerves-hub.org/nerves-hub/setup/firmware-signing-keys),
[systemd credentials](https://systemd.io/CREDENTIALS/), and
[OTP circular logger](https://www.erlang.org/docs/26/man/logger_disk_log_h.html).
