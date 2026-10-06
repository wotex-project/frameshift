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

GitHub Actions builds architecture-specific, self-contained `.deb` packages
from the exact release tag/commit with the pinned toolchains and locked
dependencies. Customers install the packaged runtime and `frameshiftctl`
without an Elixir/Erlang/Zig development environment. The initial Linux
interface is the headless service and local CLI. Publish only exact qualified
Ubuntu versions and architectures at `frameshift.wotex.io/download/`, with
matching retained release docs and signed-manifest-verified GitHub Release
downloads. A signed APT repository follows direct-package install/update and
recovery acceptance. Pi 5 Ubuntu Server uses the qualified arm64 package;
other distributions and graphical shells require separate qualification.
The [installation and workflow contract](../architecture/install-and-guide.md)
defines version identity and failed-publication recovery. Development DEB
assembly and container lifecycle checks are implemented;
stable-tag build and publication workflows remain required.

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

### Initial DEB runtime and service contract

The first packaging qualification target is **Ubuntu 24.04 LTS**, independently
for amd64 and arm64. Other Ubuntu versions remain candidates until the same
closure and installed lifecycle pass there. The package is `frameshift`; it
installs the self-contained core at `/usr/lib/frameshift/core`, with the exact
codec and raster worker in `/usr/lib/frameshift/bin`. Language compilers and Mix
are build tools, not installed dependencies. System libraries remain explicit
DEB dependencies, checked from every shipped ELF executable/shared object in a
clean target image; bundling OTP does not eliminate its OS ABI requirements.
Locked upstream source is compiled against target OTP headers. A host-built NIF,
helper or BEAM containing a build-time native path cannot establish this closure.

The fixed service account is `frameshift`, with no login and a distinct primary
group. `frameshift-control` grants local mutations and `frameshift-observer`
grants diagnostics. The service belongs to both; installation adds no human
account automatically. Numeric IDs are resolved from the installed account/group
database and validated before launch, never copied from a build machine or a
socket response. Accounts/groups are retained on removal to prevent numeric UID
reuse from granting custody over retained data. Root remains the administrator.

A root-owned provisioning helper runs as a service pre-start maintenance action.
It validates managed ancestors and creates only absent final directories:
`/var/lib/frameshift` (0700), `tmp` and `credentials` beneath it (0700),
`/run/frameshift` (0711, traversal only), and distinct `control`/`observer`
children (0710 with their respective groups). Existing symlinks, wrong owners,
groups or modes refuse without chmod, recursive chown, deletion or target
access. Initial directory publication may fail partway; a retry admits only
already-correct directories. It never creates a credential or resets SQLite.
The listeners still own stale/live socket admission and 0660 socket modes.
Private import/codec custody lives in persistent `tmp`, outside the registered
object quota. Abrupt-owner fences survive service restart and reboot; recovery
requires a stopped service, receipt inspection and explicit administrator action.
No startup or package removal recursively clears these files.

The service launcher runs with the dedicated nonroot identity and a clean,
non-distributed OTP environment. It sets fixed data/socket/credential/native
paths, private TMPDIR, finite redacted logging and disabled crash dumps. The
installed CLI supplies only public numeric policy and socket paths in a clean
bundled VM; it never inherits service cookies, private keys or runtime service
configuration. The separate identity launcher requires the service UID and reads
its bounded PEM from stdin under the existing protected-file contract.

Installed clean-VM launchers must not inherit an unreadable or unlinked working
directory into OTP startup. Preserve a readable/searchable caller directory with
a resolvable physical path, so ordinary relative imports and maintenance paths
retain their meaning. Otherwise launch from `/`; any supplied relative import,
backup or restore file path refuses with the finite custody error before starting
the VM. Absolute paths and path-free commands retain their existing admission.
The stdin-only identity launcher may use that fallback without reinterpreting a
file argument. Working-directory recovery grants no actor or credential access.

Offline backup/restore uses the same admitted data-directory lock as the managed
service launch, through the service-UID-only `frameshift-maintenance` command.
Package configuration additionally provisions a private `/var/backups/frameshift`
root without admitting or resetting existing mismatched custody. Artwork exports
exclude credentials, package watermark and abandoned import/native files; restore
publishes only an absent candidate. Removal/purge retain those explicit backups.
See [administrative backup and restore](../architecture/library-backup.md#ubuntu-administrative-entrypoint)
for commands, limits, concurrency and deliberate adoption/identity recovery.

The managed launcher uses `flock --no-fork` so the exec chain replaces the lock
launcher with the actual bundled VM. That VM retains the admitted directory lock
and is systemd's main process. `KillMode=mixed` sends initial TERM only to that
main process, allowing OTP to stop upload/codec/renderer owners and their native
handshakes before helper processes are killed. On main-process exit or the finite
stop deadline, systemd kills every remaining control-group process. Ordinary
managed restart must release confirmed private worker/intake custody and permit
new imports; forced termination or unknown native exit still retains its fences.
Never clear those fences at startup. Explicit `OOMPolicy=stop` stops the unit on a
kernel OOM notification; bounded on-failure restart retains uncertain custody.

The exec-style unit completes start only after its service-UID `ExecStartPost`
helper receives a successful read-only `frameshiftctl state` response. A clean
environment, 250 ms retry interval and 35-second TERM/one-second final-kill bound
keep this inside the declared 60-second manager start deadline. Refusal emits a
finite readiness error and fails activation; it never repairs fences or attempts
an import. This attests availability of the command/Library boundary, not frame,
credential, codec or model readiness. In particular, a fenced import owner may
coexist with available catalog/diagnostics. An exec alone is not application
readiness; package start must not return during initial native setup.

The systemd unit confines writes to the managed state/runtime roots, denies home
access and privilege escalation, bounds file descriptors, process count and
memory, and applies finite stop/restart limits. Stop kills the entire service
control group, including native workers. Declared memory limits are containment
policy, not measured idle or maximum working-set evidence. JIT and native
helpers must pass with the actual unit restrictions; blanket executable-memory
or syscall restrictions cannot be asserted without that join. Journald consumes
the existing redacted console format; durable audit remains SQLite.

Booted-manager acceptance must distinguish resolved unit properties from kernel
execution. A fixture service copied from the installed unit runs a bounded native
canary under the same confinement, identity, file-descriptor and cgroup limits.
It checks writable managed roots, read-only system paths, denied home access,
private temporary/device views, privilege/address-family refusal, actual process
and memory ceilings, and whole-control-group stop including a child that ignores
TERM. After observing the declared memory-high throttle, only the disposable
canary unit relaxes that throttle to exercise the unchanged hard ceiling; record
this phase separately from operation with all declared limits. `MemoryMax` bounds
cgroup memory, not total allocation when swap is available; record swap policy.
Fixture overrides that restore provider-disabled restrictions are explicit;
missing kernel support refuses rather than becoming a passing skip. This proves
the tested manager/kernel/configuration, not another Ubuntu kernel or CPU.
Run `release/linux/check-systemd CANARY_SOURCE INSTALLED_UNIT_SHA256` as root only
in a disposable booted Ubuntu 24.04 machine with the exact package installed and
its service active. The canary source is a root-owned 0600 regular file; pin the
installed unit digest independently from the accepted package. Compiler tooling
belongs to the fixture and is not a customer dependency. The harness creates and
removes only its reserved temporary units and canary paths, preserves the host's
unit, and refuses conflicting custody or provider-weakened host properties.
The installed host must separately start with default JIT, import through its
actual native codec, survive managed restarts and preserve state through actual
package update/removal. No fixture can replace physical power/storage evidence.

DEB maintainer scripts must be idempotent, refuse unsupported OS/architecture and
version downgrade before unpack, and preserve data/credentials on update,
removal and purge. Removal stops/disables the unit and removes packaged files;
intentional data destruction is a separate administrator operation. No upgrade
claims transactional rollback across package bytes, SQLite and external delivery.
The unreleased schema remains original CREATE/INSTALL definitions.

A root-owned 0600 `.installed-version` watermark beneath the private state root
records the highest admitted Debian package version. Pre-install compares both
that bounded single-line version and dpkg's prior version before unpacking.
Removal/purge retain the watermark, so a lower reinstall cannot adopt newer data.
Missing/unsafe watermark beside an existing metadata database refuses implicit
adoption; restoring or admitting an unversioned development library is an
explicit administrator recovery operation with its matching version evidence.
Configuration synchronizes an exclusive temporary record and atomically replaces
the admitted watermark before host startup, then synchronizes its filesystem.
The watermark remains after a startup failure because migration effects may be
uncertain. A sync/publication failure refuses configuration; no physical
power-loss guarantee follows.

Pre-install also validates every existing directory in the archive footprint as
a real root-owned directory with the expected mode, because dpkg can follow an
existing directory symlink when unpacking. It never follows a redirected package
prefix or normalizes its target. State directories have their separately admitted
nonroot owner. A live upgrade stops the unit before replacing runtime bytes;
stop failure or a still-active unit refuses. Package error-unwind restores a
previously active service when its retained runtime remains usable, preserving
administrator masks/disablement. Installer service actions respect policy-rc.d;
policy refusal is not treated as a successful stop of a live host.

Package configuration creates only missing system accounts/groups, requires the
fixed nonlogin account/home/primary-group contract, adds only the service to the
control/observer groups, provisions exact directory custody and retains existing
user grants. It enables the unit on first install while preserving later admin
mask/disablement. Removal stops/disables packaged activation; purge removes
package-manager activation state while retaining account IDs, Library, credentials,
watermark and unknown custody. Journald records remain under system policy.
Avahi/D-Bus clients/services are explicit OS dependencies for local discovery;
unavailable discovery still returns its finite refusal without restarting daemons.

Development DEBs identify the existing `0.1.0-dev` application with a bounded
`0.1.0~dev+fixtureN` packaging revision. They cannot enter a stable manifest or
customer download page. Stable app/package/tag/version agreement, licensing,
signing, native installed lifecycle and public readback remain independent gates.

The tagged candidate builder instead consumes a private frozen source record,
compiles the exact stable app version in the target image and binds its runtime
and packaging handoff to final hashes. Its clean-container acceptance checks
dpkg/watermark/command versions and the existing import, restart and administrative
joins against the actual archive. Complete reruns verify retained bytes without
rebuilding. These candidates retain publication authority none under the
[release input contract](../architecture/release-manifest.md#ubuntu-tagged-build-candidates);
they do not close native installed, licensing, signing or publication gates.

Acceptance first joins fresh target builds and actual nonroot launch, peer/group
CLI, PNG/JPEG import, persistence/restart, unsafe-directory refusal and native
ELF closure in pinned Ubuntu containers. The `linux-deb` lane additionally runs
actual dpkg install/update/remove/purge/reinstall, retained-version downgrade
refusal and configuration retry against the packaged bytes. Controlled systemctl
responses exercise package-script stop/start/error-unwind and policy refusal
through Ubuntu's actual helper, without claiming a running service manager.
Those tests do not establish a booted
systemd manager, native amd64 JIT, installed clean-VM update/removal, cgroup/OOM
behavior, power loss, signing/notices or Pi hardware. Installed systemd and native
CPU acceptance remain mandatory before a customer package is advertised.

### Booted package and native-stop fixture

`release/linux/booted-check.exs LOWER_DEB UPPER_DEB LOWER_SHA256 UPPER_SHA256`
qualifies private 0.1.0/0.1.1 arm64 candidates in a disposable booted Ubuntu
24.04 machine. Run its root validator from a separately extracted lower runtime,
so package removal cannot remove lazily loaded validator modules. Independently
pin both source-bound candidate archives; require root-owned unaliased regular
0600 inputs. Prepare explicit control/observer/denied actors, public exact JPEG
fixtures and the two readback/stop helpers as described in the
[fixture instructions](../../release/README.md#booted-ubuntu-qualification).
The real package must already be installed, ready and confined by its declared
unit. Restore any provider-disabled hardening only for the tested unit.

The fixture joins literal/absolute original imports, a separately retained 0400
identity, offline exact backup/restore and live refusal to actual active-but-disabled
upgrade, downgrade/error-unwind, remove/purge and higher-version reinstall.
Compare immutable bytes, ownership/modes, authoritative SQLite tables, prior
audit rows and account IDs. Mutable diagnostics/metrics, SQLite physical layout
and the increasing installation watermark are checked under their own contracts.
Reset the unit's failure/start-rate state only between independent acceptance
phases. An exact C-locale `reset-failed` response that the unit is not loaded
permits the subsequent start to load it; every other reset error refuses. The
unit's real three-start/120-second policy and filesystem fences stay unchanged.

Finally suspend the actual codec worker after matching its executable, cgroup
and start identity, then stop the whole managed host. Require successful manager
stop within 40 seconds, disappearance of that PID identity, an empty group and
CLI unknown-outcome exit 75. Before decoding has completed, no Library receipt
may be fabricated. Restart preserves prior completed receipts while unknown
intake custody refuses status/new import with exit 69. Retain this fenced final
state and all fixture outputs; this is not automatic recovery or a customer
installation procedure. A partial run never resets or deletes its retained data.
The complete fixture passes uninterrupted from a fresh Ubuntu 24.04.5 arm64 /
systemd 255.4 installation with default JIT on the shared OrbStack kernel. A
persistent per-unit override restores provider-disabled hardening before APT
installation; actual properties are checked before and after the lifecycle.
Stock Ubuntu/native amd64, actual host OOM recovery, physical storage/power and
production acceptance remain separate from that exact software configuration.

### Captured dependency source receipts

The retained Ubuntu candidate's build-input assertions now have a separate
source-receipt join. `scripts/check-linux-material` takes the exact frozen source,
architecture, candidate and independently pinned core/Gleam receipts; it rechecks
all retained package/runtime bytes, embedded source/project facts and runtime
version descriptors without Docker, install or host launch. Unknown input,
wrong identity, unsafe custody, receipt/candidate mutation and partial or
conflicting output refuse. A complete replay preserves receipt inode/time.

Supplier source and fetched metadata must agree byte-for-byte and mode-for-mode.
Generated parser/native/lock inputs retain explicit reasons. Captured Git metadata
has its own bounded known-path profile and separate facts; it is not source proof
or an execution/sanitization claim. See the
[Ubuntu source join contract](../architecture/release-manifest.md#ubuntu-captured-dependency-source-join)
for identity, limits, recovery and evidence tiers. The same core/Gleam comparison
serves Mac and Ubuntu without adding another dependency verifier. Actual archive/
Git receipts join both retained container candidates; installed/systemd, hosted
provenance, generated derivation, licenses and trusted distribution remain open.

### Dependency source receipt archive handoff

`scripts/stage-linux-material TAG COMMIT SOURCE_RECORD arm64|amd64 CANDIDATE
CANDIDATE_SHA256 ARCHIVE ARCHIVE_SHA256 CORE_SHA256 GLEAM_SHA256 JOIN_SHA256 OUTPUT`
receives a separate source-evidence POSIX USTAR beside the already received
Ubuntu candidate. Independently pin archive, candidate and all three receipt
digests. Admit exactly `ubuntu-material/` at 0700 and the three 0600 regular
members `core-material.json`, `gleam-material.json` and `dependency-inputs.json`.
The fixed four-member profile is at most 33 MiB, with 16 MiB source receipts and
a 64 KiB joined record; extra names, links, extensions, bad modes and bounds
refuse before extraction. Share descriptor-level USTAR validation with existing
Mac and candidate receivers; compare every extracted member with its payload.

Create only absent private output under safe custody, with a synchronized pending
marker. Rejoin received receipts to the separately admitted Ubuntu candidate;
the locally produced joined bytes must equal the received joined bytes exactly.
Keep a separate private verification record and a bounded 4 KiB handoff record
binding source, architecture, transport/candidate/receipt hashes and the source,
generated and Git metadata counts. Final source/parser/version children precede
static archive/extracted-receipt/full-candidate and namespace checks. An interrupted
or conflicting output stays incomplete for inspection. Identical complete replay
verifies existing bytes without extraction, build, install or rewriting.

Publication authority remains `none`. BSD/GNU USTAR retained-assertion fixtures,
independent and semantically conflicting digests, wrong profile/member/mode/bounds,
partial/aliased/changed custody, child-time mutation and exact unchanged replay
are acceptance targets. Both full Ubuntu container candidates must receive these
actual source receipts through the bounded receiver. This does not authenticate
a hosted run or source publisher, sanitize Git metadata, approve licenses or
qualify booted systemd/native installed lifecycle or production distribution.

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
Standalone pair/recover use the actor-bound physical-command contract below;
missing command identity or unsupported reference policy refuses before claims.
Missing protected keys on first execution yield a retained preflight refusal.
Streamed import, credential provisioning, the full CLI and installed
packages remain required work;
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
Every mutation requires an explicit `--id COMMAND_ID` of 1–64 UTF-8 bytes
(the pairing contract below restricts that ID to its commissioning alphabet); the
CLI neither invents an ID after failure nor automatically retries an exchange.
Arguments map to existing product commands and cannot supply an actor UID.
`storage-set REVISION BYTES --id COMMAND_ID` changes the registered-object budget
against its observed revision; BYTES is a whole decimal from 1048576 through
1099511627776. It never deletes objects to reach the new limit.
`metadata-edit ITEM REVISION TITLE` requires either one or more `--label LABEL`
options (the complete replacement user-label set), or explicit
`--clear-user-labels`. Up to 32 user labels and 64 `--dismiss PROVENANCE LABEL`
options are allowed; each dismissal names an exact currently observed machine
label/provenance pair (`filename`, `metadata`, or `vision`) under the metadata
revision. Title/labels follow the existing trimmed NFC/control/byte bounds.
Label omission alone refuses so a title-only-looking command cannot implicitly
clear the existing user-label set. Immutable artwork and machine provenance remain
owned by the existing metadata command.

`loop TARGET INTERVAL ITEM...` preserves 1–64 distinct digest IDs in caller order;
`loop-pinned TARGET INTERVAL` snapshots the existing bounded pin set. INTERVAL is
an explicit whole millisecond value from 1 through 31536000000, or `profile` to
request the qualified source-backed recommendation. The existing core still
clamps an override to the advertised minimum and refuses a missing recommendation,
unsupported target/profile, inactive item or rendering failure. Both forms and
metadata edits retain the required trailing `--id COMMAND_ID`. Resume keeps its
exact suspended playlist revision contract.

The argument admission ceiling is 270 arguments, 64 KiB total raw UTF-8 bytes,
and 8 KiB per argument, before constructing JSON. Catalog edits, replay and stale
revision acceptance use the actual SQLite owner; ordered-loop argument fixtures
join the retained core rendering/playlist tests. These are software checks, not
Linux NIF, installed package, qualified target or physical display evidence.
Streamed original import uses the dedicated custody/codec/receipt contract below.

The [native normalization profile](../architecture/content-pipeline.md#linux-native-normalization)
uses an isolated codec executable. Its admitted static-PNG and bounded JPEG profiles own
complete container/stillness, primary orientation, alpha and SDR-to-sRGB
conversion. Original-byte upload must precede this service-owned codec; no
client-decoded pixels or caller path can replace it. A decoder fixture is
distinct from authenticated upload/receipt, installed Ubuntu and target binary
closure evidence. The exact JPEG cohort passes complete-container, primary
Exif, split ICC, complete entropy/scan and golden-byte fixtures. CMYK/YCCK,
HDR/gain-map/multiple-image and unknown metadata extensions refuse explicitly.

The host's `Frameshift.NativeCodec` owner requires existing nonroot private
`0700` temporary custody selected before startup, including Exile's descriptor
handshake. It snapshots a protected executable, requires its exact digest and
producer revision, closes bounded stdin and awaits native exit. Original bytes
do not enter argv, environment, stderr or marked upstream crash logs. Unknown
custody or abrupt owner death retains an exclusive replacement fence. Installed
recovery must stop the complete service and verify native termination before
removing an abandoned `frameshift-codec-custody` directory. This is separate
from replaying an import receipt or modifying the immutable Library.

Physical pair/recovery and stdin intake follow the dedicated contracts below.

### Streamed original import

The group endpoint admits `importBegin`, `importChunk`, `importFinish`,
`importCancel` and read-only `importStatus`. Each request independently verifies
final socket custody, kernel credentials and `auth: "peer"` before decoding or
looking up an upload. The private Mac path-import operation remains separate;
group callers cannot submit decoded pixels, dimensions, source paths or actor
identities. Upload and command admission use the existing command socket and
limits, not a general HTTP listener or a second Library writer.

`importBegin` carries an `intent` with exactly these fields:

| Field | Requirement |
| --- | --- |
| `kind` | Exact `importOriginal` |
| `id` | Caller-retained command ID, 1–64 UTF-8 bytes |
| `title` | Nonblank NFC UTF-8, at most 256 bytes, no control characters |
| `originalFilename` | One nonempty NFC UTF-8 filename, at most 255 bytes, no `/`, NUL or control characters; metadata only |
| `sourceByteCount` | Integer 1–134217728 |
| `sourceDigest` | Exact lowercase `sha256:` identity of those original bytes |

Hash the RFC 8785 canonical intent, including its kind and ID. The selected
codec digest/revision is service-derived and frozen in the upload; it is not a
caller field or part of the source-intent hash. A later codec version must not
change the identity of an earlier completed request. Check the durable receipt
before allocating a stage: changed payload/actor conflicts, completed import
returns its exact prior master ID, and pending remains unknown. Same-actor,
same-intent active upload returns its existing token/offset rather than creating
another stage. An ID used by an ordinary command cannot become an import.

The upload owner admits at most two leases and 128 MiB per lease. Its real
service-owned `0700` staging directory and exclusive `0600` files have generated
names unrelated to caller filenames. A 256-bit random hexadecimal token binds
the exact intent, authenticated UID and frozen codec context. Tokens and stages
are transient; tokens, file paths and bytes never enter receipts, audit or logs.
Uploading has a thirty-second idle and ten-minute absolute deadline. These
limits apply to byte intake; a finishing job retains its reservation until its
actual task/effect custody is resolved. Expiration cannot grant a second decode
worker or conceal an uncertain Library mutation.

`importChunk` carries exactly `uploadToken`, an integer `offset` and `bytes` as
canonical padded base64 for 1–6144 decoded bytes, within the existing 8192-byte
JSON string limit. The offset must equal acknowledged bytes; gaps, duplicate
offsets, wrong actor/token, overflow or changed custody refuse before append.
Advance the offset only after a complete write. An IO failure leaves that lease
unavailable for further appends. No partial write or lost acknowledgement is
automatically retried. An explicit repeated begin can observe the acknowledged
offset; a failed lease requires explicit cancellation. Chunk acknowledgements
are intake observations, not crash-durable import receipts.

`importFinish` carries only `uploadToken`. Seal and synchronize the owned stage,
verify exact byte count and source digest through stable descriptor custody,
then pass original bytes to the frozen native codec. Canonical pixels come from
that codec alone. A decode/busy/refusal before Library admission creates no
command claim; an explicit caller retry is possible without silently retrying
work. The sole codec owner still enforces its actual worker reservation and
exit/deadline contract. A source mismatch or unsafe stage cannot reach it.

The Library performs the final command claim and immutable import through one
writer call. It refuses an existing pending claim, replays an exact terminal
result and never reexecutes an uncertain import. Successful master registration,
its import audit, exact result master ID, terminal receipt and completion audit
commit in one SQLite transaction after verified content placement. The original
unreleased CREATE definition adds a nullable checked `imported_master_digest`
to `command_receipts`, permitted only for successful imports. Ordinary command
receipts retain their existing shape. File placement and the SQLite commit
remain separate; an interrupted write can leave an orphan or pending claim,
not permission to repeat effects. A receipt records a past result and does not
pin artwork or restore a subsequently removed master.

The immutable MasterPackage retains exact original and canonical pixels.
Provenance records original filename/media/orientation, source-color
interpretation/digest, codec revision and executed binary digest. Source-intent
hash and authenticated actor bind the receipt; caller fields cannot override
decoder facts. Registered package bytes use the existing Library byte budget;
bounded transient stages are a separate working-resource allowance.
Exact package duplicates use the existing master and retain its current title,
labels and provenance; a new import intent does not become a metadata edit.
A new explicit import may restore removed bytes under the existing Library
contract, while replaying an earlier completed ID never restores them.

`importCancel` carries only `uploadToken`. The matching actor may discard a
known intake/failed stage before effects. Cancellation cannot roll back a
finishing or terminal Library mutation. `importStatus` carries only `commandId`
and returns the authenticated actor's pending/terminal receipt with an optional
exact imported master ID and finite error code; another actor's ID refuses.
A completed ordinary command without an imported result refuses with
`command_id_conflict` rather than masquerading as a successful import.
It requires no source file and performs no decode, restoration or retry.
Successful envelopes use the bounded `import` object; pending stays an explicit
unknown outcome. No response exposes filesystem paths or source bytes.

`frameshiftctl import FILE [--title TITLE] --id COMMAND_ID` opens a regular
source accessible to the caller through a bounded descriptor, checks its identity/length,
hashes exact bytes, rewinds and streams chunks. Empty, oversized, symlink and
nonregular sources refuse before staging. Without `--title`, use the filename
without its extension; normalize the filename as NFC metadata without changing
the opened path. Rehash the complete original under unchanged descriptor/path
custody before finish, including a resumed prefix. The service never follows
FILE. Only explicit begin/offset
observation can resume intake; no CLI loop automatically retries a lost chunk
or finish. `frameshiftctl import-status COMMAND_ID` reads recovery without
opening FILE. Existing statuses apply: 2 domain refusal, 64 usage/policy, 69
unavailable intake/read and 75 unknown after a possible finish/effect. Exit 75
retains the original ID; terminal status recovery returns the same master ID
after restart or codec change.

Normal owner shutdown removes only known owned intake stages after its active
tasks exit. Abrupt owner death or unknown active custody preserves an exclusive
staging fence; a replacement reports import unavailable without adopting or
deleting unknown bytes. Library and diagnostics remain available. Recovery of
that fence requires complete service/native termination before removal; durable
receipt recovery remains separate and cannot erase immutable Library objects.

Acceptance joins actual Unix authorization, native normalization, the single
SQLite writer and CLI. It covers different UIDs, actor/payload/token conflicts,
chunk limits/order/custody, incomplete/mismatched originals, idle/absolute
expiration, blocked IO, full disk, stop/crash fences, concurrent finishes,
transaction rollback, lost finish replies, fresh-VM status/replay, codec change,
removal without replay restoration and unchanged original/canonical hashes.
Linux joins freshly compile SQLite and Exile native dependencies for both
architectures; Mac NIF reuse is not accepted. Installed Ubuntu/systemd resource,
package/upgrade and filesystem power-loss evidence remains R3 acceptance.

The implementation uses `Frameshift.Import.Intent`, `Stage` and `Upload` for
this boundary. Explicit Linux group mode starts the upload owner; configure
`FRAMESHIFT_CODEC_PATH` to the protected native executable and select an existing
real service-owned `0700` temporary directory before startup. The upload owner
links the codec lifetime. Missing configuration or abandoned custody reports
import unavailable while the Library and diagnostics continue; status reads
the durable writer directly. `Frameshift.Import.Source` and `Import.CLI` join
regular caller descriptors and explicit chunk/finish operations; fresh VMs read
the same terminal receipt after host restart without an original file.

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
Validated unknown or incomplete outcomes use exit 75 as specified below.

Acceptance runs pure argument/refusal fixtures, real socket wrong-peer/framing
checks, the actual nonroot Linux application/CLI join and a clean production
release invocation with no development tools in PATH. That clean CLI invocation
must work without service credentials or a renderer variable and must not create
application state. Target-specific Linux OTP/NIF/renderer closure and install
permissions remain independent package qualification gates.

### Protected file credential resolver

Linux may configure `FRAMESHIFT_CREDENTIAL_DIRECTORY` as an operator-provisioned
absolute UTF-8 path of at most 4096 bytes. It selects protected-file custody only
with the explicit Linux control/observer policy; mixing it with the Mac token or
broker policy refuses before bootstrap consumption. Absence leaves transport
credentials unavailable without stopping catalog/diagnostic operation. The
service checks its actual nonroot real/effective/saved/filesystem UID and the
final directory inode before opening listeners. The directory must be owned by
that UID with exact `0700` permissions. It is neither created nor chmodded by the
resolver. Root/service-owner ancestor replacement remains an installation trust
boundary, not a descriptor-relative race-protection claim.

`linux-pem-v1:HEX` is the only admitted reference, where HEX is the lowercase
SHA-256 of the complete DER host certificate. It selects exactly `HEX.pem` under
the configured directory; no caller path, arbitrary filename or environment key
material selects a credential. Each file is an owned regular file with exact
`0400` or `0600` permissions and 1–131072 bytes. Resolution checks the final
path with `lstat`, the opened descriptor and readback inode/size/mtime/ctime/custody,
reads at most the bound plus one byte, closes the descriptor and returns a finite
error on replacement, missing/unsafe bytes or decode failure. The final directory
is rechecked. No failure prints an exception, path, PEM or key.

Pathname and opened-descriptor custody comparisons use explicit POSIX-second
timestamps for both reads. Local timezone conversion must not reject the same
unchanged inode; size, inode, owner, mode, mtime and ctime checks remain required.

The PEM contains exactly one certificate then one unencrypted RSA or EC private
key, including supported PKCS#8 wrapping, with no extra blocks or non-whitespace
text. Certificate DER is at most 65536 bytes and must match the reference. Only
two-prime RSA of 2048–8192 bits with a bounded odd public exponent, and
named-curve P-256/P-384/P-521 ECDSA keys are admitted. A SHA-256 proof signs
fixed domain-separated certificate identity and verifies with that certificate's
public key before returning transient OTP TLS material. It establishes key/cert
agreement, not current certificate validity, pairing or a frame pin. Those remain
the existing TLS/protocol checks. Direct delivery and the pull listener resolve
through the same existing port; missing custody preserves pending artwork.

Private PEM is exportable key custody. Provisioning and encrypted administrator
backup live outside the artwork backup and metadata database; the resolver never
writes key material. Restoring artwork alone does not restore identity. Missing
identity requires deliberate re-provisioning of the same verified certificate/key
or physical re-pairing; there is no automatic replacement key or replay of a
consumed pairing secret. Pair/recover uses the actor/receipt contract below.

This protected-file policy does not assume systemd credentials have service-owned
private modes. Upstream uses root ownership plus ACLs when supported and ownership
fallback in qualified cases. `LoadCredential=`/`LoadCredentialEncrypted=` support
therefore needs a separate ACL/mount/installed consumer fixture; merely setting
`CREDENTIALS_DIRECTORY` is not this adapter. Never put plaintext private keys in
unit environment variables or `SetCredential=`. TPM/encrypted provisioning needs
exact installation evidence. The current research checks [systemd credentials](https://systemd.io/CREDENTIALS/)
and [credential creation](https://github.com/systemd/systemd/blob/cfd2f7c73e21d6890b3a5b26203a9ba69e690c26/src/core/exec-credential.c)
on 2026-10-04. PEM/PKCS#8 support is checked against [OTP 29.1 `public_key`](https://github.com/erlang/otp/blob/OTP-29.1/lib/public_key/src/public_key.erl)
(source blob `29cf404b9e585f3d0198a44e5ef49e06c48f8b11`). Acceptance requires real
nonroot Linux file custody and a PEM-resolved pinned mutual-TLS exchange, alongside
malformed/mismatched/encrypted/oversized/symlink/owner/mode refusal. Installed
systemd, TPM, amd64 closure and physical identity recovery remain open.

The credential transport normalizes DNS/IPv4/IPv6 HTTPS origins once, keeps
an unbracketed resolver host and exact port, and reconstructs bracketed IPv6
URI authorities, omitting only default port 443. Appended TD paths and HTTP
Host headers retain that authority. This follows [RFC 3986 section 3.2.2](https://www.rfc-editor.org/rfc/rfc3986.html#section-3.2.2),
checked on 2026-10-04. Live pinned mutual TLS on IPv4 and IPv6 loopback using
loaded protected PEM is software acceptance; it does not qualify scoped
link-local addresses, routed discovery or a received frame.

### Offline protected identity import

The bundled `frameshift-identity import` maintenance command installs an
administrator-supplied PEM while running as the configured nonroot service
UID. It starts no application, database or listener. It requires canonical
`FRAMESHIFT_SERVICE_UID` and the existing `FRAMESHIFT_CREDENTIAL_DIRECTORY`;
actual real/effective/saved/filesystem UIDs must match, and final directory
custody must already be service-owned `0700`. It never creates a directory,
changes an existing file's permissions, generates a key or selects a systemd
ACL/encrypted credential policy. Missing/unsafe custody refuses before input.

Pipe one certificate/private-key PEM into stdin and close it. The shared CLI
intake reads at most 131073 bytes under one five-second deadline and admits
1–131072 bytes. PEM never goes into argv, environment, output or a database.
Certificate/key grammar, bounds and possession proof are the resolver's exact
rules. Derive the opaque reference from the admitted certificate DER; that
content identity provides idempotence for this offline installation. It is
separate from actor-bound artwork/pairing command receipts and has no hidden
service mutation or physical pairing effect.

Write only a fresh exclusive random staging file under the admitted private
directory, restrict it to `0400` before any PEM bytes, sync and close it, and
install `HEX.pem` using a hard link that cannot replace an existing name.
Recheck custody and resolve the final reference before acknowledging new
publication, requiring a real directory sync. If an existing reference resolves
to the same verified certificate/key identity, return it without rewriting its
bytes, permissions or name.
Malformed, unsafe, wrong-owner, symlink or directory conflicts remain untouched;
no force/replace/rotation option is provided. Concurrent identical imports
converge on one final name; a loser validates retained custody or refuses until
it can be inspected. An interrupted private stage is not resolvable by
a credential reference. Owned staging cleanup is attempted, with no automatic
deletion of other credentials or abandoned stages.

Successful canonical JSON contains only version, opaque credential reference
and status `created`/`existing`. Invalid input or a conflict exits 2, invalid
arguments/configuration/input framing exits 64, custody or pre-publication I/O
unavailable exits 69. A failure after new-name publication exits 75 with that
reference and status `unknown`, preserves installed bytes and requires explicit
inspection; it cannot acknowledge persistence or silently replace identity.
Lost output can be reconciled by deliberately submitting the same PEM, since
installation never replaces a final name. Help/version need no custody/input.

Administrator key issuance and encrypted backup remain external setup actions;
artwork backup retains only the opaque reference. This import qualifies no CA,
TLS-validity, TPM, signing/notarization, physical pairing or installed Ubuntu
release. Acceptance requires pure shared input/PEM refusal, real nonroot Linux
exclusive/file/directory custody, concurrent/import-replay/conflict/crash-stage
fixtures, fresh stdin CLI output and resolved-key pinned TLS. An isolated full
tmpfs exercises actual pre-publication ENOSPC; a post-link custody fault must
retain the file and return exit 75 without key/path output. Neither establishes
exact installed-filesystem disk-failure or power-loss qualification.

### Actor-bound physical pairing commands

Linux `pair` and `recoverPair` use the existing standalone IPC operations and
require a caller-retained `commandId` matching `[A-Za-z0-9._~-]{1,64}` in addition
to the transport `requestId`. The command ID is also the frame commissioning
request ID for `pair`; changing a connection's request ID never changes that
physical idempotency key. Linux accepts only the protected-file reference
namespace and the service-configured resolver. Mac token pairing retains its
existing transient contract and refuses this Linux-only command field.

Before claiming, parse the bounded physical record, require its discovered ID to
match, admit a HTTPS origin without userinfo/query/fragment/application path, and
validate the protected-file reference and actual kernel actor UID. The receipt
hash is SHA-256 of RFC8785 encoding of `{domain: "frameshift-linux-pairing-v1",
request: {operation, bootstrap, discoveredId, origin, credentialRef}}`; bootstrap
is the exact supplied string. Receipt storage contains that hash, command ID,
actor UID and terminal code only. It never stores the physical secret, request
body or private key. Bootstrap secrets need the existing entropy/encoding policy;
a digest is not a substitute for protecting transient input or logs.

Claim/completion use the existing global actor-bound command receipts. Changed
payload/operation or actor conflicts. A pending claim refuses with
`command_outcome_unknown` without resolving a key or sending the secret again.
Completed failure replays its code. Completed success reads the retained paired
record and returns its bounded frame ID only if device, credential reference,
server pin and TD origin still match. Missing or changed custody refuses with
`pairing_receipt_unavailable`; replay never creates a new physical exchange.
Pairing admission and receipt completion are separate transactions. Interruption
between them remains pending/unknown; no receipt asserts a lost external outcome.

First execution calls the existing pinned pairing/TD admission using the command
ID, then completes the receipt under the same actor. Unknown exchange/incomplete
admission remains explicit. Recovery with its own deliberate command ID reads
only the authenticated TD and never posts the secret. It cannot silently rotate
an identity or reuse a pair ID as a recovery command. The CLI supplies bounded
bootstrap intake and discovery under the dedicated contracts below.
Acceptance joins actual SQLite success/failure/pending/conflict/restart and
secret-exclusion checks to nonroot kernel attribution and dispatcher tests; live
protected-PEM TLS is separate from physical-window and exact-frame qualification.

### Pairing CLI intake

`frameshiftctl pair DISCOVERED_ID ORIGIN CREDENTIAL_REF --id COMMAND_ID` and
`recover-pair` with the same arguments use the actor-bound operations above.
The CLI accepts the protected-file reference and ASCII commissioning ID only.
Its origin is a bounded HTTPS authority without userinfo, query, fragment or an
application path. Discovery values are candidate inputs, not frame authority;
manual selection does not replace the pin and authenticated matching TD.

Pipe one physical bootstrap JSON record into stdin and close the stream. The
CLI reads at most 2049 bytes with one five-second deadline and admits at most
2048 bytes through the existing strict bootstrap parser. Device ID must equal
the selected discovery value before opening the service socket. Bootstrap text
never goes into argv, shell history, stderr or stdout; it stays transient in the
CLI/request and is not written to a staging file. Invalid, oversized, empty,
partial or withheld input refuses before a send. The clean CLI VM owns and
terminates its input task; a timed-out reader cannot extend the process lifetime.

The existing client verifies service/socket identity before sending that record.
Pair/recovery success requires exactly a matching `frameId` in the response, in
addition to the envelope identity. Sent pair/recovery with no validated response
is an unknown mutation, never an unavailable read. A validated
`command_outcome_unknown`, `pairing_outcome_unknown` or `pairing_incomplete`
response also exits 75 and preserves its JSON envelope on stdout; other domain
refusals exit 2. There is no automatic retry, new ID, pair-to-recover switch or
secret repost. Recovery is a deliberate command with its own retained ID.
Acceptance covers bounded real input, refusal before dispatch, matching/mismatched
frame envelopes, unknown exits and the actual Linux actor/receipt join. Installed
discovery/UI/credentials and exact physical commissioning remain separate gates.

### Bounded DNS-SD discovery CLI

`frameshiftctl discover` performs one local introduction snapshot without
starting the core, reading its database or obtaining a credential. It invokes
the installed root-owned `/usr/bin/avahi-browse` through `/usr/bin/timeout`
with fixed arguments: parsable resolved output, explicit `local` domain,
original service type and termination after the current browse. No shell,
executable path from argv/PATH, daemon auto-start or automatic retry is used.
The package must declare and qualify Avahi/coreutils runtime dependencies and
the system D-Bus/Avahi service. Missing binaries/daemon or a nonzero exit is
unavailable, preserving all host/frame state.

GNU timeout sends KILL to the owned process group after five seconds; the
collector has a six-second absolute deadline. It retains at most 65536 output
bytes, 512 events and 64 active service identities, and rejects partial final
lines and malformed machine output. Oversized output is discarded while the
finite subprocess deadline remains in force. Output collected before helper
failure/timeout never becomes a successful partial snapshot. Child cleanup
and output limits need real Linux process tests; these bounds are not measured
RSS or a complete installed service qualification.

Decode Avahi's DNS-label escapes and quoted TXT decimal/quote/backslash escapes
without losing duplicate keys. Admit only `_frameshift._tcp` in `local`, an
opaque ASCII instance of at most 63 bytes and the reference introduction:
exact version `0`, HTTPS scheme, `/.well-known/wot`, ASCII device ID of
16–128 bytes and optional pair `0`/`1`, with at most 512 length-prefixed TXT
bytes. Reject extra private metadata, duplicate fields and malformed escapes.
Added/unresolved and removed services never appear as resolved candidates.
An introduction or route that cannot be admitted is counted and omitted;
structural/output/service-count failures refuse the whole snapshot.

Require a bounded ASCII `.local` SRV hostname and canonical numeric port.
Return a literal local IPv4 or ULA IPv6 HTTPS origin from the resolved address,
avoiding an unqualified NSS/mDNS hostname dependency. Loopback, multicast,
public addresses, mapped IPv6 and scope-dependent IPv6 link-local results are
omitted. Multiple family/interface results for the same instance, hostname,
port and introduction coalesce, preferring IPv4 then the lexical origin;
conflicting instance/host/port/introduction under one device ID omit that
device as ambiguous. The result is sorted by device ID and contains only
device ID, origin, TD path and physical pair-mode hint. `omittedCount` counts
invalid introduction/route events plus candidates suppressed for ID ambiguity;
it is not a count of currently present devices. It contains no service instance,
interface, friendly metadata or TD.

Successful JSON explicitly identifies `authority: "introduction"`. Select a
candidate's device ID and origin for the existing pair/recover command; no
first candidate is paired automatically. A closed pair hint does not remove
the frame from discovery or authorize/forbid physical recovery. TLS pin,
physical bootstrap, local-address admission and authenticated TD ID remain
mandatory. Advertising the same ID is not proof of custody or compatibility.
No introduction persists beyond this invocation.

Research and exact upstream locators are in
[protocol foundations](../research/protocol-foundations.md#linux-discovery-adapter).
Acceptance requires hostile/duplicate/private TXT and lifecycle fixtures,
dual-family/ambiguity and local-address refusal, actual bounded Linux helpers
and CLI output, and an Avahi browse/resolve producer join. Supported Ubuntu
installed discovery, scoped link-local support and independent
physical-frame interoperability remain separately unqualified.

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
