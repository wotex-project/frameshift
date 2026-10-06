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

## Release tooling ownership and migration

Elixir owns portable release policy: canonical manifests and channel material,
Ed25519/key identities, frozen source inputs, source/receipt joins, archive
profiles and publication reconciliation. The planned tool-only Mix project
is `release/portable/`, with the `FrameshiftRelease` namespace and
`frameshift-release` executable; these are targets, not existing exports. Keep
it independent of host application processes and dependencies and declare its
workspace owner when introduced. Mac-native operations are
delegated to the [Swift tooling owner](../host/macos.md#mac-release-tooling-implementation)
through bounded explicit commands. Ubuntu consumers must not require Xcode or
Swift. Cask/appcast rendering is portable policy despite its current directory.
Browser rendering and documentation bundling retain their own JS boundaries;
their release verification must consume the same qualified portable owner.

A language replacement preserves every existing schema/profile, accepted
identity, byte limit, trust root, refusal exit and retention rule. Compare exact
manifest, channel body/footer, signature and digest bytes for identical inputs.
Preserve canonical field/array ordering, UTF-8 and escaping, integer bounds,
booleans distinct from numbers, duplicate-key refusal and one trailing LF.
Generic map or sorted-key encoders are not evidence of compatibility. Preserve
SPKI DER fingerprinting independently of Sparkle's raw public key, and plain
Ed25519 over the complete admitted message; never sign a substituted hash.

Portable input admission must first qualify the existing no-follow,
nonblocking descriptor, finite read/hash and pre/post custody semantics on
Mac and Ubuntu. OTP's ordinary file operations do not expose all required
flags. Resolve the minimal isolated adapter under
[D-003](../decisions/README.md#d-003--language-boundary) before using it; no
path-check/read sequence, application NIF or hidden Node subprocess may stand
in for this requirement. The selected adapter's operations, byte/time bounds,
process exit, secret handling and retained failure state require an explicit
contract and adversarial fixtures before portable callers cut over.

Producer implementation observations can legitimately change when ported.
Declare the new source/tool profile and independently pin its receipt; do not
forge former implementation hashes or rewrite a completed output. Within an
unchanged profile, complete replay must remain read-only. A changed profile at
an existing output refuses as a conflict. Retained-record consumers validate
their pinned historical producer assertions and bytes without claiming to have
executed that producer. Old/new comparison fixtures must distinguish stable
wire identities from intentionally changed producer observations.

Migration is incremental under the
[implementation plan](implementation-plan.md#release-tooling-migration).
Keep the former implementation as a test oracle only while necessary, migrate
its Mac/Ubuntu and guide/site consumers together, then remove obsolete
production imports and commands. The separate codec Cargo helper is outside
the initial Mac migration except where a shared dependency must be qualified;
do not turn this task into a repository-wide tooling rewrite. Missing signing
credentials or installed targets do not block specified local implementations
and refusal fixtures. No port is qualified by this specification update.

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

## Pinned Mac updater source material

`scripts/check-sparkle-source TAG COMMIT SOURCE_RECORD ARCHIVE FRAMEWORK OUTPUT`
creates a private input receipt without fetching, compiling application code,
thinning, signing or updating an app. First verify the exact frozen source and
use SwiftPM's bounded `dump-package` parser on its Mac manifest in a separate
private scratch directory. Workspace initialization can reset an unsupported
state file even for manifest dumping; evaluation must not open the compiler's
evidence workspace. Require the
single Sparkle binary target's exact approved URL and ZIP checksum and bind the
manifest file hash. Then apply the
[pinned updater material admission](../host/macos.md#pinned-updater-material-and-private-cpu-derivation)
to the independently supplied ZIP and actual cached framework. Preserve their
custody through source/manifest/cache rechecks before completing the receipt.

The canonical mode `0600` `sparkle-material.json` in an owned mode `0700` output
binds product/tag/version/commit/source-input hash, parsed binary identity,
manifest hash, verifier-source observation, exact archive and framework/native
facts, with publication authority `none`. Bound it to 64 KiB and all work to a
six-minute software budget, with each manifest child limited to one minute and
512 KiB output. Require the fixed 85 regular files, 57 directories, nine
aliases and five two-CPU native roles. A separately pinned receipt consumer
checks source/schema/manifest/archive/profile and canonical custody before any
candidate input join; it performs no SDK extraction or compiler invocation.
Receipt assertions do not independently authenticate producer execution or
upstream build derivation.

An identical rerun verifies retained bytes without rewriting the receipt.
Unknown, partial, changed, aliased, unsafe or conflicting output refuses and is
retained. Refuse overlap with source/cache/archive custody and refuse an output
inside tracked source. Acceptance uses actual frozen Git/Mix/SwiftPM producers,
the exact upstream ZIP/cache, independent receipt digests and unchanged replay,
plus source/manifest/cache/namespace changes, wrong profile/digest/schema and
partial or aliased output. The later native build/captured-input and transport
joins must consume this receipt before claiming a full updater candidate.

## Captured core lexer/parser derivation

`scripts/check-core-generated TAG COMMIT SOURCE_RECORD HEX_CACHE CORE_RECEIPT
CORE_SHA256 DEPENDENCY_JOIN JOIN_SHA256 OUTPUT` qualifies only the known captured
core lexer/parser inputs identified by `generated-lexer-parser` in an independently
pinned Mac/Ubuntu dependency join. Reuse complete core source-receipt replay from
its original single-receipt output against the fetched archive/Git cache; do not replace that verifier or infer source proof
from the joined record. Core receipt, join and frozen source identities
must agree. Retain the join's candidate reference without claiming a new candidate
admission. Unknown schemas/facts/paths, wrong expected hashes, missing admitted
grammars and unsafe/changed custody refuse. Other generated inputs and retained
Git metadata keep their separate scope. An empty selected subset is recorded as
zero qualified files; it does not qualify generation inside the target build.

The supported syntax profile is OTP 29.1/ERTS 17.1/parsetools 2.8, using `leex`
for the three retained lexer grammars and `yecc` for the two retained parser
grammars in earmark_parser/erlex. Invoke only those inspected public file exports
with relative `src/` names in private copies; clear inherited compiler options.
Record exact helper, four generator-module and two default-template observations.
Default templates embed their installation path in generated source. Require
exact raw output bytes/hash and captured 0644 mode: a different tool/path cohort
refuses; do not normalize generated source or change retained candidate bytes.
Source grammar inputs are at most 64 KiB each, generated files at most 2 MiB each,
with at most five pairs and 64 KiB joined/proof records. Each generator/observation
child has a 30-second deadline, 64 KiB output ceiling and shell file-size limit;
the operation has a three-minute software budget. This is bounded source/output
and child-lifetime policy, not a measured
compiler peak-memory guarantee.

A new private output contains synchronized 0600 grammar/generated proof files,
0700 directories, a pending marker and a bounded derivation record. Preserve
partial/conflicting custody for inspection; never implicitly regenerate there.
Completed replay checks retained proof bytes, source/receipt/join identity and
current generator observations without generating, fetching, building, loading
application code or rewriting. Final static input/proof/namespace checks follow
all source/parser/observation children. No generated Erlang actions are executed.

Acceptance joins real parser-generator outputs, actual Git/Mix and source-archive
receipts to exact captured hashes; altered source/output/template/module identity,
unsupported input, resource/alias/namespace conflicts, child-time mutation and
no-generation replay must refuse or preserve the declared custody. Separately
join the five full captured files for both Mac and Ubuntu retained cohorts. This
proves derivation of these captured source inputs by the observed tool cohort;
it does not prove compiler/publisher authenticity, target BEAM/native execution,
licenses, installed lifecycle or production distribution. Authority remains none.

## Locked dependency notice-file collection

`scripts/collect-dependency-notices TAG COMMIT SOURCE_RECORD CORE_CACHE
CORE_RECEIPT CORE_SHA256 GLEAM_CACHE GLEAM_RECEIPT GLEAM_SHA256 OUTPUT` collects
raw notice candidates only from the independently pinned core and decision-kernel
source receipts. Replay both existing source gates from their original
single-receipt directories against the same frozen source and supplied caches.
Missing, conflicting or incomplete source evidence refuses; collection never
creates replacement source receipts, fetches, builds or starts application code.

Select admitted files whose ASCII case-insensitive basename is `LICENSE`,
`LICENCE`, `LICENSES`, `LICENCES`, `COPYING`, `COPYRIGHT`, `NOTICE`, `NOTICES` or
`AUTHORS`, optionally followed by a dot, underscore or hyphen suffix. Also retain
files below an exactly named `LICENSES`/`LICENCES` directory and each core Hex
package's admitted `hex_metadata.config`. Keep original path/mode/byte/hash and
locked package identity; copy exact raw bytes into private component/package
paths. Do not decode, execute, render, normalize or infer SPDX expressions from
the content. Record every locked package, including an explicit empty notice
list where this filename profile finds nothing. Metadata is a separate role;
it cannot turn a missing notice file into a complete package review.

This is a technical collection scope, not a license decision or full distributed
closure. It does not establish that these packages ship, that inline notices or
third-party code have been covered, or that declared licenses grant the planned
rights. Project license selection, rights review and the separate OTP/Elixir,
Swift/toolchain, Rust/native, SDK/model and operating-system materials remain
required. The record must state rights review required and publication authority
none. Do not modify retained app/DEB/candidate bytes or pretend this private
collection is an installed release notice bundle.

Bound selection to 512 files, 1 MiB per file, 16 MiB aggregate raw bytes and a
1 MiB inventory, with existing source path/depth and package limits. Use the
source gates' finite parser/child limits and a six-minute software processing
budget. Synchronize 0600 files and 0700 directories beneath a private output;
retain a pending marker on failure. A complete replay verifies exact copied
bytes, package/role inventory, source/receipt identity and output namespace
without copying, rewriting or deleting. Unknown/aliased/special/unsafe files,
additional directories, changed source or child-time custody changes refuse
while retaining prior or partial evidence. Final static source, selected-file,
receipt and output checks must follow all parser/version children.

Acceptance joins actual Hex/Git/Gleam source producers and the existing source
verifiers, then checks exact copies, nested notice names, missing-file reporting,
independent identity, bounds, aliases, incomplete custody, mutation and unchanged
CLI replay. A full current dependency cohort exercises the same collector; this
evidence does not close release licensing or distribution acceptance.

## Locked codec Cargo registry source bytes

`scripts/check-cargo-material TAG COMMIT SOURCE_RECORD CRATE_CACHE REGISTRY_SOURCES
OUTPUT` admits already fetched codec registry sources against the frozen
`codec/Cargo.lock`. Support its bounded literal version-four generated lock form,
the exact crates.io registry source, unique name/version identities and unambiguous
locked dependency references. Refuse unsupported registries/Git/path packages,
duplicate or unconsumed syntax and checksum conflicts. The two existing local
packages retain explicit references to frozen project manifests; this registry
receipt does not replace project/vendor source review or qualify a target build.

Compare each existing `name-version.crate` descriptor's SHA-256 with the locked
checksum before parsing. A fixed private Node 26.9.0 child reads bounded stdin,
checks that digest again and inflates the admitted gzip into bounded memory.
Accept only checksum-correct POSIX USTAR or ordinary GNU TAR regular files and
directories within the exact locked root. GNU extension fields must be zero;
long-name, PAX and sparse extensions remain unsupported. Require safe unique
paths, ordinary readable non-writable-by-group/world
modes, zero padding and a complete zero terminator with no trailing material.
Refuse links, special/extended/sparse headers, reserved `.cargo-ok` members,
unsafe numbers, truncated payloads and conflicting file/directory names. Do not
extract to disk or execute manifests, Rust source or build scripts. The archive's
supported normalized `Cargo.toml` package preamble must name the locked package
and version; this bounded identity profile is not a general TOML interpreter.

Every archive-delivered file must match the fetched source's raw bytes and mode,
including publisher-generated manifests and VCS metadata. Parent/archive
directories must match the bounded expected namespace; undeclared files or empty
directories refuse. Cargo 1.97.1's root `.cargo-ok` marker is a distinct generated
cache fact: require its exact `{"v":1}` bytes, ordinary 0644 mode and unaliased
regular custody. It establishes no source authenticity. Do not accept cached
source merely because this marker exists. Source timestamps are not normalized.

Bound the lock to 64 KiB/128 packages, compressed archive input to 64 MiB,
expanded archive and individual source files to 128 MiB, aggregate registry
material to 512 MiB/8,192 entries and the private receipt to 16 MiB. Each parser
child has a 30-second deadline and 16 MiB output ceiling; the software operation
has a three-minute budget. Record helper/Node/zlib observations. Clear inherited
Node preload/path/coverage options. Byte/deadline/heap policy does not establish
whole-process RSS or compiler peak memory.

Synchronize a new 0700 output and 0600 pending marker/receipt. Complete replay
compares exact retained bytes without fetching, running Cargo, compiling,
starting the application or rewriting. Partial/conflicting output remains for
inspection. Final static frozen source, archive/source/marker bytes, helper and
namespace checks must follow parser/version children; aliases, changed custody
and resource excess refuse without replacing retained evidence.

Acceptance joins actual Cargo-produced GNU archives, supported USTAR fixtures and
frozen Git/Mix identity
to every delivered source fact, with checksum-before-parser, malformed header/
path/type/padding/identity, extra/missing/aliased/changed sources and markers,
resource/child-time refusal and unchanged successful CLI replay. Exercise all
current locked registry packages separately from publisher/registry rights and
trust, target compiler/runtime execution, complete notices, installed lifecycle
and production release acceptance. Publication authority remains none.

## Locked codec notice-file collection

`scripts/collect-codec-notices TAG COMMIT SOURCE_RECORD CRATE_CACHE
REGISTRY_SOURCES CARGO_RECEIPT CARGO_SHA256 OUTPUT` collects private technical
notice candidates from the separately pinned codec source receipt. Replay the
original completed Cargo source output before selection and after copying;
never create a missing receipt, fetch, run Cargo, compile or start the host.
The received source identity and expected digest must agree with frozen inputs.

Apply the existing conventional notice filename profile to every admitted
registry package. Retain raw `Cargo.toml` and optional `Cargo.toml.orig` as
separate package-metadata files. Neither metadata nor a filename match establishes
licensing or notice completeness. Every package inventory must explicitly list
its notice candidates, including an empty list when no name matches.

The two local packages remain distinct frozen-project scopes. Select their
tracked manifests and conventionally named files from `codec/` excluding its
`vendor/` subtree for frameshift-codec, and from `codec/vendor/jpeg-decoder/` for
the local decoder. Do not imply that these files qualify the upstream vendor
archive, patch derivation, project license choice or full distributed closure.
Keep source Git modes, locked local revisions and original paths in the inventory.

Retain exact raw copies under package/version-specific paths without decoding,
normalization, execution or rendering. Bound each selected file to 1 MiB,
aggregate bytes to 16 MiB, selected files to 512, inventory to 1 MiB and operation
to six minutes. The source gate's archive, entry and child limits still apply.
Private output directories use 0700 and copies/record/pending marker use 0600.
Synchronize completion; partial or conflicting output remains for inspection.
Completed replay verifies copies and exact retained inventory without rewriting.

After all parser/version children, recheck pinned source receipt, all frozen
source bytes, selected source files, copied bytes and input/output namespaces.
Refuse wrong/forged/changed identities, aliases, special files, unsafe modes,
resource excess and unknown directories/files without replacing retained proof.
Publication authority is `none` and rights review remains required. This fixed
codec scope does not modify the existing core/Gleam collector or candidate
transports, and creates no installed notices bundle.

Acceptance joins actual Cargo archives and frozen Git/Mix/local files, checks
binary candidates and metadata separation, missing-name reporting, independent
receipt refusal, file/aggregate/entry bounds, partial/changed/aliased/unsafe
copy/output refusal, late parser-time mutations and unchanged successful CLI
replay. Exercise the full current codec cohort separately from publisher rights,
target consumption, installed execution and production release acceptance.

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

Runtime and DEB builders explicitly bypass cache reuse for the final `artifact`
stage with `--no-cache-filter artifact`. Compilation and dependency stages keep
their existing cache policy. This narrow export policy does not replace source,
namespace, version, byte, mode or handoff verification; incomplete exports refuse
and remain retained. Do not prune shared caches as part of candidate production.

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

## Ubuntu captured dependency source join

`scripts/check-linux-material TAG COMMIT SOURCE_RECORD arm64|amd64 CANDIDATE
CANDIDATE_SHA256 CORE_RECEIPT CORE_SHA256 GLEAM_RECEIPT GLEAM_SHA256 OUTPUT`
compares a retained Ubuntu 24.04 candidate's captured build inputs with the same
independently supplied source receipts used by native Mac candidates. It neither
fetches, compiles, installs nor launches the packaged host. All three expected
record digests must come from a separate retained source; reading them from the
records being admitted is not an independent assertion.

Admit canonical private records, exact frozen tag/commit/version/architecture,
recorded native/emulated build policy and the complete retained package/runtime
bytes. Compare the embedded source record and selected project-owned context
inputs with frozen source. Consult the bounded runtime release descriptors with
the existing version consumer. Candidate files and captured assertions are
bounded to 8,192 entries, 32 path components, 512 path bytes, 128 MiB per file and
512 MiB aggregate. Candidate directories are owned, real, non-group/world-writable;
files are owned regular unaliased source-like modes with owner read. Reject
unknown namespaces, empty undeclared directories, links, special files, malformed
facts, duplicate paths and all size/hash/mode conflicts. Private receipt records
are at most 16 MiB. All source/parser/version children finish before final static
record, byte and namespace checks; use a finite 180-second processing budget.

Every admitted core/Gleam source file must match the captured input, including
supplier-delivered Erlang and native source. The exact fetched Gleam metadata
hash/mode must agree. Only the existing explicit generated lexer/parser, native
helper and empty compiler-lock profiles may remain outside source proof. Ubuntu
preparation additionally retains Git metadata for Git-locked dependencies. Admit
only the bounded known HEAD/FETCH_HEAD/config/description/index, sparse/exclude,
object pack/commit-graph and safe branch-reference paths; record their exact facts
separately as `retained-git-build-metadata`. They establish captured metadata
identity, not source authenticity, execution, sanitization or a need to distribute
Git metadata. Hooks, logs, unknown Git files and metadata beneath Hex/Gleam
packages refuse. A new receipt cannot relabel an unexplained input as proved.

Write a private 0700 output containing a synchronized 0600
`ubuntu-dependency-input-join` record, at most 64 KiB, with source/candidate/receipt
hashes, proved source count, explicit generated facts and separate retained Git
facts. Interrupted or conflicting output refuses and stays for inspection. A
complete identical rerun verifies all inputs and preserves receipt inode/time.
Publication authority remains `none`. Retained-assertion refusal fixtures and
actual archive/Git verifier receipts joined to both qualified container candidates
are the acceptance targets; they do not establish hosted provenance, licenses,
generated derivation, compiler authenticity, booted systemd or native installation.

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
