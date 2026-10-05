# Release Artifact Manifest

**Status:** normative local verification contract; no production signing key or
public artifact is qualified

## Purpose and trust

The installation guide, direct download, Cask, Sparkle feed, and Linux package
instructions must identify exact released bytes. A versioned manifest binds
the app version and each artifact's platform, architecture, format, HTTPS URL,
byte count, and SHA-256 digest. Its detached Ed25519 signature covers the exact
UTF-8 manifest bytes. A verifier must obtain the trusted public key from a
separately pinned release configuration, never from the manifest or its download
location. Sparkle's archive/appcast signatures and Apple Developer ID are
additional independent checks; the manifest does not replace them.

The manifest has `schemaVersion: 1`, `product: "io.frameshift.app"`, a SemVer
`version`, and 1–16 `artifacts`. The UTF-8 JSON is compact with one trailing
newline and at most 64 KiB; duplicate keys fail that encoding check. Versions
are stable three-component numeric SemVer. Each artifact has only `platform`,
`architecture`, `format`, `file`, `url`, `bytes`, and `sha256`. Accepted tuples
are macOS/universal/DMG, Ubuntu/amd64 or arm64/DEB, and Nerves Pi 5/arm64/FW.
Names are flat ASCII basenames; filenames and platform tuples are unique.
URLs are HTTPS with no credentials, query, fragment, or mutable `latest` path,
and carry the exact version tag and basename. Artifacts have a positive byte
count no larger than 8 GiB. The local verifier also checks
that each corresponding regular file has the recorded size and digest. It
rejects symlinks and never follows a path outside the supplied artifact
directory.

## Manifest creation

The release operator supplies a compact UTF-8 plan containing the same product
and stable version plus 1–16 artifact entries with only platform,
architecture, format, flat filename, and immutable HTTPS URL. The signer reads
each regular local archive without following a symlink, derives its byte count
and SHA-256, constructs the canonical manifest above, and signs those exact
bytes with an Ed25519 private key supplied as an owner-only regular file. It
derives the public key from that private key and refuses to sign unless its
SPKI SHA-256 equals the separately supplied owner-pinned fingerprint. It
never prints key bytes or accepts a private key from a command argument or
environment variable.

The signer writes a manifest, detached 64-byte signature, and derived public
key into a new private output directory. It does not overwrite existing
release material. It verifies its own output with the ordinary local verifier
before making that directory available to the next release step. Signing does
not publish or claim that a DMG, package, firmware image, or public URL passed
its independent acceptance gate. An owner may instead use an offline signing
system that emits the same exact manifest and detached signature contract.

There is no manifest of placeholder downloads. The guide keeps installation
links absent until a fully verified signed manifest and its exact artifact
files exist. A release-mode guide build takes explicit paths for the manifest,
detached signature, public key, pinned key fingerprint, and local artifact
directory; a partial set of inputs fails the build. It substitutes a bounded
version and platform-specific link list into the static install section only
after local verification. The publication pipeline must then fetch each public
URL with a finite redirect chain that remains HTTPS, requests identity
encoding, rejects partial or compressed responses, streams at most the
declared byte count, and compares the downloaded size and SHA-256 before
building the release guide. The dedicated publication build command takes all
five signed-release inputs, performs local and public verification first, and
leaves the prior guide output untouched on refusal. The ordinary development
build may use local signed fixtures without a public URL. GitHub Releases may
redirect to its asset CDN; a redirect
is never taken as evidence by itself. Publication
additionally requires owner-pinned trust root,
Developer ID/notarization, Sparkle and Cask acceptance, licenses/notices,
installed platform tests, and applicable frame evidence. Repository visibility
does not change to publish release artifacts.

## Frozen source inputs

Before a stable installer build, `scripts/record-release-inputs TAG COMMIT OUTPUT`
records a clean exact source checkout in a new private output directory. `TAG`
is the existing stable `vX.Y.Z`; `COMMIT` is its independently supplied 40-hex
commit. HEAD and the local tag must resolve to that same commit. The actual core
Mix project version must equal `X.Y.Z`, read through a fixed non-starting build
entrypoint, rather than inferred from an artifact filename. Development app
versions and absent/moved tags refuse. This command never creates/moves a tag,
pushes a ref or changes repository visibility. A release workflow must separately
bind its expected commit to the owner-authorized remote tag/event.

The [Ubuntu candidate workflow](install-and-guide.md#ubuntu-candidate-workflow)
implements the remote-source/frozen-digest gate and independent build/check
matrix with publication authority none. Actions outputs are temporary staging;
they cannot satisfy accepted released-byte reuse, signing or public readback.

`source-inputs.json` is a deterministic version-one `release-source-inputs`
record of at most 8 MiB, separate from manifest v1. It identifies product,
tag/version/commit, Git tree, every tracked path with Git blob identity, SHA-256,
byte count and
executable mode, and the source paths of dependency locks and `.mise.toml`.
It contains no file contents, private key, environment dump or local tool-cache
path. Its `publicationAuthority` is `none`: source capture alone does not prove
resolved dependency bytes, native build outputs, licensing/notices, signing,
installed acceptance or a public channel. Target builders extend their own
records with actual tools, OS/image/CPU, resolved material and final artifacts.

All source entries must be stage-zero regular files with admitted Git file modes;
symlinks, submodules, conflict stages, unsafe paths or missing files refuse.
Read descriptors without following final symlinks, compare inode/size/timestamps
across hashing and compare actual bytes with their Git blob. This catches hidden
changes even when Git's status optimization or configuration suppresses them.
Use literal committed objects, ignoring Git replacement refs and caller Git
directory/index/work-tree overrides. Refuse nonregular names before opening and
use nonblocking descriptor admission so a raced FIFO cannot wait for a writer;
a source growing beyond its initial size refuses during hashing.
Retain exact bytes/modes; no checkout filter or newline transformation counts as
identical source. Nonignored untracked changes refuse; ignored caches are outside
the source inventory and cannot themselves qualify build material.

The collector checks tag/HEAD, tracked inventory, all hashes/modes and application
version again before publication. A builder uses `scripts/verify-release-inputs
TAG COMMIT RECORD` after its work to repeat that comparison; it cannot claim a
frozen source using only a clean-looking status. Git and Mix queries have finite
deadlines and fixed arguments, with no source/eval interpolation from supplied
paths or tags. The output parent must be an existing directory owned by the
operator; the output directory is 0700 and record 0600. Existing identical owned
output verifies without rewriting; unsafe output, extra files or same-path
changed version/source refuses. Interrupted output is retained for inspection,
never silently overwritten or treated as committed.

Acceptance uses real temporary Git/Mix projects: exact stable source and identical
rerun, development/version mismatch, dirty/untracked source, changed tag/HEAD,
hidden content/mode change, symlink and conflicting output refusal, and post-build
verification that preserves the previous record. Those fixtures do not create a
Frameshift release or qualify a signing key, runner, installer or remote tag.

## Ubuntu tagged build candidates

`scripts/package-linux-candidate TAG COMMIT SOURCE_RECORD arm64|amd64 OUTPUT`
consumes the frozen source record above and builds one Ubuntu 24.04 runtime and
DEB candidate in an absent private output. App, tag, release descriptor and DEB
versions must be the same stable `X.Y.Z`; development fixture revisions cannot
be relabelled. The builder uses the same target preparation, pinned images and
package lifecycle policy as development builds. It neither signs nor publishes.

Before compiling, compare every selected project-owned context input with its
frozen source hash/mode and inventory the actual copied dependency/tool/native
material. Check the source again after preparation and after building; compare
the private context again before accepting outputs. Record upstream material
as captured bytes, not as proof of its provenance or license. Target compilation
and ELF closure still run inside the selected Ubuntu image. Emulated build JIT
settings are recorded and never added to shipped launchers.

Consult the generated core `.app`, release `.rel` and `start_erl.data` before
runtime export and again before DEB assembly. Refuse a mismatched version,
architecture or source-record digest. Hash the runtime before copying it into
packaging and compare the copy; a changed handoff refuses. Retain source/runtime/
packaging records, actual package versions, ELF closure and final archive digest.

A final private `ubuntu-release-candidate` record covers all retained files and
the one DEB's size/hash. It is written only after source, context and handoff
checks pass and files are synchronized. Its publication authority is `none`:
installed acceptance, license/notices, trusted signing and public readback are
still required. No file contents, environment dump or private key enters it.
An identical complete rerun verifies retained bytes without rebuilding or
rewriting; changed, unsafe or interrupted output refuses and stays available
for inspection. An existing stable version is never rebuilt over its bytes.

Acceptance joins real Git/Mix source fixtures to version-descriptor and build/
packaging handoff checks, and separately builds a test-only tagged full product
in the pinned target image. `scripts/check-linux-candidate` takes the same five
arguments, verifies the retained candidate without rebuilding, compares copied
archive bytes with its recorded digest, then installs the actual DEB in a clean
image. The externally supplied expected version must agree with dpkg metadata,
retained watermark and bundled command/identity versions. Existing private
PNG/JPEG, peer/group, restart/crash-custody and administrative recovery fixtures
run with that version; original source/artifacts verify again afterward. This
is container acceptance, independent of booted systemd/native installed proof.
The [candidate archive handoff](install-and-guide.md#candidate-archive-handoff)
receives retained USTAR bytes beside this same frozen source without rebuilding.
It verifies transport, candidate and directory custody before emitting a private
record with publication authority none; hosted provenance remains separate.
Such a tag is confined to the disposable fixture;
it does not create a product release or authorize remote publication.

## Failure and recovery

Reject an unknown schema or platform tuple, malformed signature, changed
manifest byte, duplicate or missing artifact, path traversal, symlink,
size/digest mismatch, non-HTTPS or mutable URL, and a key other than the
configured trust root. Refuse a group/world-readable private key, a changed
artifact during hashing, an unsafe output parent, or an existing output
directory. A partial release is never presented as complete for a
claimed platform. A failed verification cannot overwrite the last published
manifest or guide. Key rotation needs a separately reviewed transition signed
by the previous trusted key and installed-client update compatibility tests.

Local fixture tests may generate ephemeral Ed25519 keys; they establish parser
and digest behavior only. A public release needs a protected owner-controlled
private key and a pinned public-key fingerprint in the publication pipeline.

Primary evidence: [Node Ed25519 sign and verify](https://nodejs.org/api/crypto.html),
[Sparkle distribution and independent signatures](https://sparkle-project.org/documentation/),
and [Homebrew Cask digest policy](https://docs.brew.sh/Cask-Cookbook).
