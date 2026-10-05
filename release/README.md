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
storage/power tests, protected administrative recovery, complete license notices,
signing and public publication/readback remain required.
