# Release manifest verification

`manifest.mjs` verifies one detached Ed25519 signature against a separately
pinned SHA-256 fingerprint of the public key's DER SPKI bytes, then reads and
hashes every exact local archive. The verifier accepts no placeholder artifact.
The signer takes a compact plan with version, target, filename, and URL for
each archive. It hashes the local bytes and writes a new directory containing
`manifest.json`, `manifest.sig`, and `release.pub.pem`. Its owner-only Ed25519
private-key file must match the separately pinned fingerprint.

```sh
./scripts/check release
mise exec -- node release/sign.mjs PLAN.json ARTIFACT_DIR OWNER_PRIVATE_KEY.pem TRUSTED_KEY_SHA256_FILE NEW_OUTPUT_DIR
mise exec -- node release/verify.mjs MANIFEST.json MANIFEST.sig RELEASE.pub.pem ARTIFACT_DIR TRUSTED_KEY_SHA256_FILE
mise exec -- node release/verify.mjs MANIFEST.json MANIFEST.sig RELEASE.pub.pem ARTIFACT_DIR TRUSTED_KEY_SHA256_FILE --public
./scripts/build-release-guide MANIFEST.json MANIFEST.sig RELEASE.pub.pem ARTIFACT_DIR TRUSTED_KEY_SHA256_FILE
```

The trust file must come from the owner-approved publication configuration, not
from the release download. No production key or release files are in this
repository yet. The [release contract](../docs/architecture/release-manifest.md)
lists the additional signing and installed acceptance gates. The `--public`
form streams and hashes every public URL after local verification and is a
required publication check for a real release.
The last command verifies both local archives and their public URLs before
building a guide with download links. A failed check leaves the previous
`apps/guide/dist` untouched. It prepares static files; deployment and release
acceptance remain separate actions.

Local metadata and archives use bounded regular-file descriptor admission.
Manifest/plan inputs are at most 64 KiB, signatures exactly 64 bytes and PEM keys
at most 16 KiB. The fingerprint file is exactly 64 lowercase hex bytes with one
optional LF, owned by the operator or root and protected from group/world writes.
Private signing keys use mode 0400 or 0600. Symlink/FIFO/device/directory inputs,
changed named custody and oversized metadata refuse before acceptance; release
CLI failures do not print private paths, contents or crypto exception terms.
The guide and site assembler use the same admission rather than rereading signed
metadata through unrestricted file APIs. See
[local file admission](../docs/architecture/release-manifest.md#local-file-admission).

Inspect an existing public GitHub channel with
`./scripts/inspect-release-channel OWNER/REPO MANIFEST SIGNATURE PUBLIC_KEY ARTIFACT_DIR TRUST_FILE`.
It verifies the signed local files before bounded `gh` GET requests, checks exact
repository/release/asset identity, anonymously hashes archives and all three
detached metadata files, and rechecks custody. URLs must name that configured
channel's stable tag; archives at or above 2 GiB refuse. Missing published releases
and partial/starter uploads emit an observation with exit 2. Complete public
bytes emit exit 0 with publication authority none; conflicts/refusal emit exit 1.
The command never creates a release/tag, uploads, deletes, replaces or promotes.
It cannot infer product source provenance from the separate channel repository.
See [public reconciliation](../docs/architecture/install-and-guide.md#public-release-reconciliation).

The local [site assembler](../docs/architecture/install-and-guide.md#site-assembly-and-local-recovery)
uses the same verifier before promoting versioned documentation and download
links. Retained records use `verifyManifestSignature` to recheck the pinned key
and exact manifest without needing installer archives on the docs build worker;
that narrower call makes no fresh local/public archive claim. Development updates
preserve accepted versions and stable pages, and local journal recovery repeats
no release or network effect. These tools create no external publication.

The plan is compact JSON with one trailing newline, such as:

```json
{"schemaVersion":1,"product":"io.frameshift.app","version":"1.2.3","artifacts":[{"platform":"macos","architecture":"universal","format":"dmg","file":"Frameshift-1.2.3.dmg","url":"https://example.com/releases/v1.2.3/Frameshift-1.2.3.dmg"}]}
```

The example URL is a fixture. The signer refuses symlinked archives, weak key
permissions, mismatched trust fingerprints, unsafe output parents, and an
existing output directory. A release operator must separately qualify and
publish real archives, then run the public readback verifier.

## Ubuntu development closure

`./scripts/package-linux --development arm64` or `amd64` builds a new
`var/linux-<architecture>-development/` runtime tree; an existing destination
refuses. It snapshots source/locked dependency material without user/Hex config,
records file hashes and the exact commit/dirty state, verifies pinned Gleam
archives through `gh`, cross-builds the pinned Zig target, and freshly compiles
OTP-header-dependent NIFs/helpers and the scalar codec in pinned Ubuntu images.
`build-inputs.json`, `build-packages.txt` and `elf-closure.txt` accompany the tree.
The latter inspects all 24 shipped ELF executables/shared objects and rejects
wrong architecture or missing linked libraries. CA roots and dynamically loaded
SCTP are explicit OS dependencies even though `ldd` alone does not expose them.

Run `./scripts/check linux-release` after building both trees. The clean Ubuntu
fixtures contain no globally installed Elixir/Erlang/compiler tools, and exercise
packaged nonroot service and CLI, group separation, unsafe existing directories,
caller-private PNG/JPEG uploads, exact SQLite/pixel/provenance readback, full VM
restart and abandoned import-custody refusal. The service template is checked by
Ubuntu's systemd parser, while Docker supplies read-only root, no network,
1 GiB memory and 512-process containment. A fixture-only single-JIT mapping is
used under amd64 emulation; shipped launchers retain native default mapping.
No fixture proves a booted systemd manager or OOM/physical filesystem behavior.

These are explicitly development trees, not stable tagged DEBs or published
installers. Booted DEB lifecycle, protected administrative backup/provisioning, native
amd64/systemd, licenses/notices, signing and public readback remain required.
The [Linux owner](../docs/host/linux.md#initial-deb-runtime-and-service-contract)
defines private state, runtime traversal, group policy and conservative recovery.

## Ubuntu development DEBs

Build the runtime trees above, then use
`./scripts/package-linux-deb --development arm64 1` (or `amd64`). Revisions are
bounded to 1–9999 and identify `0.1.0~dev+fixtureN`; they do not change the
`0.1.0-dev` application version or qualify for a stable manifest. Each new
`var/linux-<architecture>-deb-fixtureN/` output contains the archive, its SHA-256,
packaging-input hashes/commit/dirty state, symbol-derived dependencies and actual
package-build environment versions. The archive retains both runtime and
packaging records. Wrong runtime identity/architecture, ELF machine, linked
library or redirected input refuses assembly; existing output refuses overwrite.

Build revisions **1 and 2 for both architectures**, then run
`./scripts/check linux-deb`. Apt first resolves the actual declared dependencies
on a clean pinned Ubuntu 24.04 image without globally installed language tools.
The network-disabled disposable container uses dpkg for installation, upgrade,
downgrade refusal, removal, purge and reinstall. It verifies dedicated accounts,
group admission, exact PNG/JPEG/SQLite results, clean CLI after replacement,
retained file bytes/owners/modes, private credential sentinel and unknown custody.
It also refuses unsafe/missing/version-regressing watermarks and redirected
package directories before unpack. The service account is retained; human
control/observer membership is never granted by installation.

Package-script tests use Ubuntu `init-system-helpers` with controlled systemctl
responses for active-but-disabled upgrade, failed pre-install error-unwind,
policy-denied stop, actual stop failure, failed start and configuration recovery.
These are simulated manager responses, not booted systemd acceptance. Native
arm64 uses default JIT; emulated amd64 uses a fixture-only single mapping after
replacement, leaving archive bytes unchanged. The writable container root is
needed for dpkg; Docker supplies no network and 1 GiB/512-process limits.
The fixture explicitly resets its own empty installation between image build
and execution to avoid Docker overlay lower-directory rename restrictions.
Removal/purge in the product scripts retain all private state.

Stable tag/version inputs, booted systemd, native amd64, installed failure and
storage/power and encrypted-key recovery, complete license notices,
signing and public publication/readback remain required.

## Offline Ubuntu maintenance

Stop the complete service with `sudo systemctl stop frameshift.service`, then
use `sudo runuser -u frameshift -- /usr/bin/frameshift-maintenance backup
/var/backups/frameshift/EXPORT` (one shell command). `verify BACKUP` reads only
the named backup; `restore BACKUP DESTINATION` publishes an absent candidate,
for example under that same private backup root. The operator chooses each
path explicitly; existing stores/exports are never overwritten. Stop/status,
role and directory-lock admission are owned by the
[Library maintenance contract](../docs/architecture/library-backup.md#ubuntu-administrative-entrypoint).
Control/observer membership does not grant offline data or credential access.

The clean nonroot command uses the installed Library backup format and target
SQLite. Verification can run alongside the host; backup/restore refuse early or
live concurrent managed ownership. The private backup root is provisioned by
package configuration and retained by removal/purge. It is outside the registered
object quota, so the administrator manages its capacity. Artwork exports omit
credentials, package version and unknown temporary custody. Adopting a restored
candidate or restoring a separately encrypted identity is a deliberate stopped
administrator operation; maintenance never resets those installation records.

`linux-deb` checks exact PNG/JPEG/pixel/actor-receipt backup and fresh-VM restore,
corrupt/existing destination refusal, literal paths, caller-environment isolation,
private-root refusal and lock release after actual VM exit. A real certificate/key
PEM passes installed stdin import/replay and protected service-UID resolution;
package lifecycle preserves its bytes while artwork exports exclude it.
Controlled manager states, query failure and deadline complement these checks.
Booted systemd, native amd64/default JIT, physical storage/power and separately
encrypted key recovery remain unqualified.

## Stable source input capture

`./scripts/record-release-inputs vX.Y.Z COMMIT OUTPUT` records a clean existing
stable tag at its independently supplied exact commit. It reads the actual
production Mix project version without starting the host or compiling dependencies,
and checks every committed source byte and executable mode against Git, including
changes hidden from status. The owned output parent must already exist; a private
`source-inputs.json` is created in OUTPUT. An identical rerun checks without
rewriting, while changed/unsafe/incomplete output is retained and refused.

Use `./scripts/verify-release-inputs vX.Y.Z COMMIT OUTPUT/source-inputs.json`
after build work to repeat source/version/tag verification. The source record
contains hashes and paths, not file contents or environment/key material. It
covers committed source, dependency-lock paths and the toolchain configuration;
resolved dependencies, actual native build material, target/runner qualification,
licenses/notices and final artifacts still need their target build records.
Its publication authority is explicitly `none`; it is not manifest v1 or release
acceptance. The tools never create/move tags, push, sign or publish. Current
`0.1.0-dev` source cannot produce a stable record. Real temporary Git/Mix fixtures
exercise source, version, hidden-change, post-build and output refusal paths in
`./scripts/check release`. The
[frozen input contract](../docs/architecture/release-manifest.md#frozen-source-inputs)
owns the format and lifecycle.

## Tagged Ubuntu candidates

For an existing clean stable tag whose core version agrees, first capture its
source as above, then run
`./scripts/package-linux-candidate TAG COMMIT SOURCE_RECORD arm64|amd64 OUTPUT`.
The private output contains a freshly compiled Ubuntu runtime, one matching
`frameshift_X.Y.Z_ARCH.deb`, runtime/packaging/source input records, actual build
package versions, ELF closure and `candidate.json`. It does not reuse or relabel
the existing development runtime. The source and copied project bytes must match;
actual dependency/tool material is hashed as captured, without claiming upstream
provenance or licensing. Generated `.app`, `.rel`, start metadata and DEB versions
agree. The copied runtime and post-build material are checked again before the
final record is synchronized. Current `0.1.0-dev` main refuses this command.

A complete identical rerun verifies the original files without recompilation or
rewriting. Changed, unsafe or interrupted output is retained and refused. Use
`./scripts/check-linux-candidate TAG COMMIT SOURCE_RECORD ARCH OUTPUT` for actual
clean-container installation, exact archive-handoff verification, matching
dpkg/watermark/CLI identity, private PNG/JPEG, peer/group, restart/crash-custody,
backup/restore and protected identity joins. Emulated builds/checks record or use
the fixture JIT setting; shipped launchers retain native policy.

These records have publication authority **none**. Complete notices/licensing,
installed native/systemd and failure qualification, trusted signing, public
archive readback and channel/site promotion remain required. The
[tagged candidate contract](../docs/architecture/release-manifest.md#ubuntu-tagged-build-candidates)
owns acceptance and refusal; neither command creates a tag, pushes or publishes.

## GitHub candidate staging

The manual [Ubuntu candidate workflow](../.github/workflows/ubuntu-candidate.yml)
takes an existing stable tag and independently known exact commit. A `gh`
remote-ref gate precedes source capture; each native Ubuntu 24.04 CPU job must
match its source-record digest and pass candidate build/container acceptance.
Remote tag and retained output checks repeat before upload. Each run/attempt
retains a distinct short-lived TAR, preserving private record/executable modes.
Actions records are staging outputs with publication authority none.

`release/workflow-cli.mjs` exposes the fixed remote, record and verify entrypoints
used by that graph; `./scripts/check release` exercises exact remote objects,
bounded annotation chains, moved/malformed source and source-digest handoffs.
`./scripts/check policy` validates both workflows. Actions are pinned to exact
source; checkout and mise token persistence are disabled. Explicit step-scoped
contents-read tokens support `gh`; signing/deployment credentials and promotion
are absent from this graph. No workflow was pushed or dispatched by local tests.
The [workflow contract](../docs/architecture/install-and-guide.md#ubuntu-candidate-workflow)
keeps actual hosted-runner, installed and production publication gates separate.

Receive the retained single-file POSIX USTAR using
`./scripts/stage-linux-candidate TAG COMMIT SOURCE_RECORD ARCH ARCHIVE SHA256 OUTPUT`.
Supply the expected archive SHA-256 from the trusted job handoff beside the exact
clean source checkout; computing a digest from the downloaded file alone cannot
establish its expected identity. The workflow checks this archive before upload
and records its target/source/digest/run/attempt/artifact identity in job metadata.
The receiver checks bounded regular-file/directory entries, exact source and
candidate inventories, and admitted modes before synchronizing a new private
output. Its `handoff.json` binds the source, transport and candidate digests with
publication authority none. An identical replay verifies without extraction or
rewriting; malformed, changed or interrupted output stays retained and refuses.
See the [archive contract](../docs/architecture/install-and-guide.md#candidate-archive-handoff)
for resource limits and independent acceptance gates.

Mac development bundles use
`./scripts/check-macos-closure APP arm64|x86_64|universal` before replacing the
prior app. Its static observation has publication authority none and includes
the final file hashes/modes and each native CPU/deployment/loader record.
`scripts/package-macos` rebuilds the local renderer/NIF cohort with explicit
macOS 14 targets, normalizes its private stage and signs inside out. The actual
OTP minimum remains visible in `LSMinimumSystemVersion`; the current runtime
requires 15.0.0. This mechanism does not sign a production release or establish
older-OS/Intel runtime compatibility. The
[owning contract](../docs/host/macos.md#native-closure-admission) records the
bounded static profile and installed acceptance still required.

`./scripts/package-macos-dmg APP arm64|x86_64|universal OUTPUT` creates a private
development DMG from an admitted ad-hoc app. It binds the final image and app
inventory in `dmg.json` and `bundle.json`, after actual read-only mounted-byte
and native-signature readback and detach. Reruns verify the existing archive;
source/metadata/archive conflicts and incomplete output refuse without a
rebuild. A refused detach retains the working mount rather than deleting its
directory. Its authority remains none and it supplies no stable release input,
production signature or notarization. See
[development image custody](../docs/host/macos.md#development-disk-image-custody).

`./scripts/package-macos-universal ARM_APP INTEL_APP OUTPUT` joins two admitted,
single-CPU ad-hoc apps into one private universal development bundle. Matching
directory paths/modes, common file bytes, parsed product identity and native
file roles/types are required. Every native item, including OTP helpers and
NIFs, is merged and signed in the new stage. Its private `universal.json` binds
both complete input observations to the final bundle; replay verifies without
changing source, output or signatures. Source conflict, mutation, failed merge
and interrupted output retain custody and refuse. Closure observation schema v2
includes directory identities by relative path and mode, so empty-directory
drift also changes retained identity. See
[the universal join contract](../docs/host/macos.md#universal-development-bundle-join)
for independent exact-source, native producer and installed acceptance gates.

A tagged native Mac candidate builds separately with:

```sh
./scripts/package-macos-candidate vX.Y.Z EXACT_COMMIT SOURCE_RECORD arm64 OUTPUT
```

Use `x86_64` only on physical Intel hardware. The exact clean tag, frozen source
record, declared app/core versions and captured dependency/tool observations
must remain unchanged. The producer retains the admitted ad-hoc app and a private
candidate record; identical reruns verify without rebuilding. The isolated full
arm64 producer and packaged IPC/import/restart/offline maintenance pass locally.
Captured cache bytes are not upstream provenance or license approval. This
candidate has publication authority `none`; the
[Mac producer contract](../docs/host/macos.md#tagged-native-mac-build-candidate)
keeps universal assembly and installed/signing gates separate.

`scripts/package-macos-cohort TAG COMMIT SOURCE_RECORD ARM_CANDIDATE ARM_SHA256
INTEL_CANDIDATE INTEL_SHA256 OUTPUT` binds two private native candidates to the
same frozen source before universal assembly. Independently supply the record
digests; captured material and compiler versions must agree. Actual app/core
versions, complete closures and seals are rechecked. A private parent record
binds those candidates to the retained universal child; replay has no build,
merge or signing effect. The [cohort contract](../docs/host/macos.md#source-bound-universal-candidate)
keeps retained assertions, native producer evidence and public release authority
separate. Full arm64 receiver admission passes; full native Intel remains open.

`scripts/stage-macos-candidate TAG COMMIT SOURCE_RECORD arm64|x86_64 ARCHIVE
ARCHIVE_SHA256 OUTPUT` receives a separately pinned POSIX USTAR containing only
`macos-candidate/`. The shared bounded reader compares each extracted regular
member with its archive payload and preserves exact modes/names. Native app/core
versions, candidate records, closures, seals and source identity reverify before
completion; unchanged replay never extracts or rebuilds. Actual BSD TAR CPU
fixtures and the full arm64 host pass, alongside retained Ubuntu GNU TAR replay.
See the [Mac handoff contract](../docs/host/macos.md#native-candidate-archive-handoff).
