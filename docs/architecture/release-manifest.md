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

### Local file admission

All local manifest, signature, public key, signing plan, private key, trust
fingerprint and archive inputs MUST be regular files. Refuse a nonregular final
name before opening; use no-follow/nonblocking descriptor admission and compare
the named file with its descriptor before and after reading. A replaced name,
changed byte count/mode/timestamp or growing file refuses. Fixed-position reads
cannot allocate beyond the admitted metadata size; archives stream in bounded
chunks and cannot consume more than their admitted initial size. These checks
do not promise to interrupt a filesystem syscall or defeat same-user debugger
access. Public verification never needs or reads a private signing key.

Admit at most 64 KiB for manifest/plan, exactly 64 signature bytes, at most
16 KiB for either PEM key and 64 lowercase hexadecimal fingerprint bytes with
one optional trailing LF. The private signing key must belong to the operator
and have mode 0400 or 0600.
The fingerprint file must belong to the operator or root and refuse group/world
writes. Parse failures and release CLI refusal must emit fixed
non-secret diagnostics without file paths, contents or crypto exception terms.
Use finite processing budgets, preserving the manifest's existing 8 GiB archive
limit and the separate publication-channel limit. Hashing compares the actual
read count and named/descriptor identity; a digest alone cannot prove custody.

Acceptance covers real regular inputs and signed verification, each metadata
limit, symlink/FIFO/device/directory refusal, final-name replacement and growth
during reads, strict fingerprint grammar, private-key modes and sanitized CLI
failure. Test FIFOs in bounded child processes so a regression cannot hang the
verification lane. Public readback and native installed/signing evidence remain
independent.

## Frozen source inputs

The [public release observer](install-and-guide.md#public-release-reconciliation)
separately joins exact signed local files to a configured public GitHub channel,
its retained asset inventory and anonymous archive/metadata readback. A partial
or missing published set cannot promote; the observation grants no release
authority and never changes remote bytes or proves the product source commit.

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

## Locked core dependency source bytes

`scripts/check-core-material TAG COMMIT SOURCE_RECORD HEX_CACHE OUTPUT` verifies
the core's already-fetched dependency source against the exact frozen
`apps/core/mix.lock`. It performs no fetch, dependency update, compilation,
application start or publication. Admit only bounded literal supported Hex/Git
lock entries, exact package names/versions/checksums and pinned Git commits.
The dependency directory must contain exactly those admitted packages.

For each Hex package, read the existing archive through a bounded stable regular
descriptor and compare its SHA-256 with the frozen outer checksum before parsing.
Use inspected Hex 2.5.1's memory-only parser with explicit compressed and
uncompressed ceilings; check package identity and inner checksum too. Compare
every archive source file with the actual dependency's bounded byte hash and
validate the generated Hex manifest and metadata. Refuse changed, missing,
duplicate, unsafe or additional source members. For Git dependencies, compare
actual regular files/modes with literal committed blobs at the lock's exact
commit and sparse subtree, ignoring replacement refs and caller Git overrides.
Dependency queries require Git's `--no-lazy-fetch` support and disable the
filesystem-monitor hook; absent objects refuse instead of automatic network
retrieval. Older Git installations without that option refuse this profile.

Build directories, private Git metadata and explicitly generated compiler/native
outputs are outside this source-byte claim; they still require their own producer
closure/custody checks. Expected archive/blob members always take precedence over
exclusions. Current exclusions are `_build`, `.elixir_ls`, `.DS_Store`, Git's
private root metadata, generated `.o`/`.beam`/`.d` files, Exile's `priv/exile.so`
and `priv/spawner`, Exqlite's `priv/sqlite3_nif.so`/`.a`, FileSystem's
`priv/mac_listener`, and the five exact EarmarkParser/Erlex `.erl` outputs only
when their corresponding locked `.xrl`/`.yrl` inputs exist. Do not exclude
arbitrary Erlang source. Compare admitted file permissions exactly, including
published `0664` files; special bits and world-writable files refuse.
Recheck the frozen source, cache namespace and all source
material before syncing a bounded private receipt in a new owner-only output.
Complete replay verifies the same receipt without modifying inputs or output;
partial/conflicting custody refuses and remains retained. The receipt binds the
source-input digest, dependency/lock identities, parser observations and admitted
source facts, with publication authority `none`.

Bound the lock to 64 KiB/128 packages, archive input to 64 MiB per package,
memory-only expansion to 128 MiB per package, source files to 128 MiB each and
512 MiB total, 8,192 material entries and the receipt to 16 MiB. Use finite
parser output/child deadlines and a three-minute software processing budget.
These do not interrupt every filesystem syscall or prove total process-tree
termination. Acceptance includes actual locked Hex archives and Git blobs,
source/manifest/archive/lock/namespace/alias mutation, resource refusal and
unchanged receipt replay against an isolated full source cohort.

This is byte identity relative to caller-approved frozen locks, not independent
publisher/registry authentication, rights approval, toolchain authenticity,
generated-code qualification or complete runtime dependency admission. Gleam,
Swift/OTP/toolchain and non-core components retain their own input gates.

## Locked Gleam dependency source bytes

`scripts/check-gleam-material TAG COMMIT SOURCE_RECORD HEX_CACHE OUTPUT` admits
the existing `packages/decision-kernel/build/packages` sources against that
component's frozen `manifest.toml`. The selected profile accepts Gleam 1.18.1's
inspected generated literal Hex manifest form, with `gleam` build tools,
bounded unique names/versions, optional same-name OTP app, declared package
requirements and outer checksums. Unsupported Git/local sources, ambiguous or
duplicate fields, escapes and unconsumed syntax refuse; this is not a general
TOML interpreter. The fetched `packages.toml` must declare exactly the locked
name/version pairs with empty Git state. The existing regular `gleam.lock` is
empty and outside the source-byte identity; this check does not claim to hold
the compiler's operating-system lock.

Archives are named by their uppercase outer checksum in the existing Gleam Hex
cache. Compare their SHA-256 before using the same bounded pinned Hex memory
parser, then validate package identity, internal checksum and every fetched
file's exact bytes/mode. Fetched package directories contain exactly the admitted
source files and their parent/archive directories; no generated-output exclusions
apply inside them. Reserved metadata, extra/missing/aliased/special members and
world-writable or special file modes refuse. Root fetched metadata is bounded
and rechecked with source, cache and package namespaces before completion.

Use the core source gate's 64 KiB lock/metadata, 128 package, 64 MiB archive,
128 MiB expansion/file, 512 MiB aggregate, 8,192 material-entry, 16 MiB receipt
and three-minute processing ceilings, including finite parser output/deadlines.
Sync a new 0700 output and 0600 pending marker/receipt; partial or conflicting
output is retained and refused. Complete replay verifies unchanged custody
without fetch, dependency update, compilation, core application start or output
rewrite. Bind the frozen source/manifest digests, parser observations, package
identities and admitted source facts with publication authority `none`.

Acceptance includes both real locked Gleam archives and fetched source trees,
literal/metadata/hash/source/namespace/alias/resource refusal, changes during
inspection and unchanged private receipt replay. This establishes agreement with
approved locks; it does not authenticate publishers, approve licenses or prove
compiler/generated-code/runtime/other-component qualification. Join these
receipts to producer inputs separately.

## Canonical fetched Gleam metadata for candidate builds

Gleam 1.18.1 rewrites generated `build/packages/packages.toml` with package-map
iteration order. Identical fetched versions can therefore produce different raw
bytes, independently of source or compilation changes. Before freezing a new
candidate's material and source receipts, use `scripts/prepare-gleam-metadata TAG
COMMIT SOURCE_RECORD` to admit the supported bounded literal metadata against
the exact frozen decision-kernel manifest and write ASCII name order. The
canonical representation is `[packages]`, one literal name/version pair per
line, one empty line, `[git]`, and a final newline. Empty Git state and the exact
locked Hex package namespace are required. Do not normalize dependency source,
compiler output, BEAMs, native code, manifests, candidate records or receipts.

This is an explicit preparation of generated metadata in the ignored package
cache of an exclusively operated build checkout. It fetches, compiles and
publishes nothing and does not claim operating-system compiler-lock ownership
or source authenticity. Admit a regular unaliased file of at most 64 KiB with
owned safe path components, no special/group/world-write permissions and owner
read access. Preserve its admitted mode. Require the empty regular compiler-lock
file and exact package names; aliases, unsupported syntax, different versions/Git
state, changed frozen source and unsafe namespaces refuse before replacement.

Write a private pending marker and exclusive prepared file, sync them, and
recheck source, old bytes/identity, directory custody and namespaces before atomic
replacement. Final readback and directory sync precede removing the marker.
Interrupted or conflicting preparation remains retained and refused; it must
never silently resume or overwrite partial work. Already canonical metadata
verifies source/custody without changing its inode or timestamp. Bound processing
to one minute with the existing finite source-child limits; a stalled filesystem
syscall is not guaranteed to be interrupted.

New native Mac producers require canonical metadata before material capture.
After the package child returns, canonicalize only admitted equivalent generated
metadata before the full source/material/tool recheck. A changed version, source,
mode or any other input still refuses. Completed candidate replay performs no
metadata preparation or build effect. Source receipts must be produced from the
canonical bytes and replay after building; their original hashes remain binding.

Acceptance requires real temporary tagged source, supported reordered metadata
with unchanged semantics, exact byte/mode identity and no-write replay, malformed/
changed/aliased/unsafe/oversized/partial inputs and mutation refusals. Repeat the
pinned Gleam dependency command against a disposable fetched package copy to
observe the upstream ordering variance, then prepare each result and require
one canonical hash. Join that hash to actual source admission and captured
candidate facts separately; this preparation grants publication authority `none`.

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
