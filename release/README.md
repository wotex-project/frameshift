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
installers. DEB lifecycle, protected administrative backup/provisioning, native
amd64/systemd, licenses/notices, signing and public readback remain required.
The [Linux owner](../docs/host/linux.md#initial-deb-runtime-and-service-contract)
defines private state, runtime traversal, group policy and conservative recovery.
