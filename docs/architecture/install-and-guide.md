# Installation and Interactive Guide

**Status:** normative delivery architecture; distribution and browser behavior
remain unqualified until their release gates pass

## Public entry point

Use `frameshift.wotex.io` as the first public home and installation guide.
Buying `frameshift.se` is optional; the guide and installed app cannot depend
on a new domain. The maintainer's `Frameshift.html` desktop draft is visual
draft material, not a published installer or compatibility claim. Rebuild its
Paper, Photo, and Pixel paths as a responsive, accessible guide with real
requirements, parts/evidence status, setup steps, failure recovery, and a
clearly identified simulation. Windows is outside supported host scope.

The installation guide and offline lab retain a static export that works
without an application server or account. Deploy those static assets on
Cloudflare Workers Static Assets under the Wotex subdomain.
Cloudflare's documented static-asset limit is 25 MiB per file as checked on
2026-09-24; installation
archives belong in the public release artifact channel, not the site bundle.
The user or domain owner must configure DNS and any public release repository;
the private source repository's visibility is never changed by automation.

## Development documentation build

`./scripts/build-site` builds a local staged site from a clean `main` commit.
`./scripts/build-site --preview` allows worktree inspection and records the
uncommitted input state; preview output is never eligible for publication.
The outputs are `var/site` and `var/site-preview`. The builder performs no
deployment, repository visibility change, release upload or channel promotion.
Release environment inputs refuse this development-only operation.

Render every maintained `docs/` Markdown page and component README with the
locked ExDoc toolchain alongside core API pages at `/docs/dev/`. Repository-path
page identities keep same-named READMEs distinct. Resolve links from the original
file, preserve repository heading anchors, and bind code/source links to the
selected commit. Embedded repository images are copied locally; missing files,
symlinks, outside-root references, rendering warnings, missing output assets and
broken local anchors refuse. Source bytes and Git identity are checked again
before the staged site replaces its previous development output.
Existing output must match its complete recorded file inventory; unowned or
changed output refuses replacement. A failed staged rename restores the prior
development output. Generated section-link icons have static accessible names.

`docs/dev/build.json` records the source commit, dirty/eligibility flags, exact
source-input digests, page inventory and pinned toolchain configuration.
`site-manifest.json` inventories final static files, sizes/digests and link-check
counts; these are build evidence, not release signing or public readback.
Static assets have a 25 MiB/file and 20,000-file build ceiling. The local
no-release site serves the guide/lab at `/`, explicit unavailable installer
content at `/download/`, the no-release entry at `/docs/`, and a real 404 page.
No executable customer install command or artifact URL is invented.

Use non-overlapping CSP rules: the guide remains restricted to its existing
local assets; development docs permit same-origin search fetches, exact hashes
of generated inline scripts and ExDoc's inline style behavior. Shared framing,
content-type and privacy headers remain in force. Cloudflare joins duplicate
matching header values rather than replacing them, so the guide CSP must not
also match docs. Check this behavior against the
[static header contract](https://developers.cloudflare.com/workers/static-assets/headers/)
and exercise the actual generated policies in a browser. Development/status
routes require cache revalidation.

The development builder refuses to replace an output containing retained
`docs/vX.Y.Z/` directories. Its failure preserves those bytes and stable entry
points. The local assembler below verifies and retains release docs, isolates
development replacement and serializes recoverable local swaps. External
deployment reconciliation remains separate; this builder performs no publication.
Acceptance combines clean/dirty source fixtures, parsed link/image custody,
full corpus rendering and local link/anchor checks, real Chrome search/API/version
navigation, narrow-viewport keyboard access, essential text without JavaScript
and HTTP 404 behavior. Installed/public Cloudflare and release-version evidence
remain separate.

### Versioned documentation builds

`./scripts/build-site --release-docs vX.Y.Z COMMIT` builds a local documentation
candidate from a clean checkout at that exact stable tag and 40-hex commit. The
tag must resolve to the current commit, the application version must equal
`X.Y.Z`, and both source bytes and tag identity must remain unchanged through
publication of the local output. Dirty, moved, mismatched, prerelease or missing
tags refuse. No remote ref, release asset or deployment is changed.

Use the same renderer and source inventory as development docs, placing the
version's Markdown, API/search assets and source images under `/docs/vX.Y.Z/`.
Each page names its documentation version and exact source commit. Its
`build.json` records tag/version/commit, toolchains, input digests, page inventory
and the final version-directory file digests excluding that record itself.
Retained bytes are immutable: an identical rerun may verify them, while any
conflicting content or changed/unowned output refuses without replacing it.

The complete local candidate at `var/site-vX.Y.Z` includes same-source labelled
development docs so global links can be checked. It keeps the no-release
download and stable docs pages; a documentation tag is not an accepted installer
or publication claim. Its manifest explicitly records that it is a release
documentation candidate and is not eligible for deployment. The later qualified
assembler consumes the verified version subtree, not that candidate's
development/global pages.

Use one revalidated `/docs/docs_config.js` for the ExDoc version menu, referenced
from generated HTML before the version directory's inventory is frozen. It
lists retained versions and labelled development docs. Adding a version updates
that shared file rather than rewriting old documentation directories. Keep
per-version CSP hashes scoped to their own routes; immutable version assets
must not inherit the development cache policy. The locked ExDoc 0.40.4
[`versionNodes` contract](https://github.com/elixir-lang/ex_doc/blob/80270f3a4c4fe0d85c4b86029128e50995fcc21a/lib/ex_doc.ex#L483)
and [generated head](https://github.com/elixir-lang/ex_doc/blob/80270f3a4c4fe0d85c4b86029128e50995fcc21a/lib/ex_doc/formatter/html/templates/head_template.eex#L24)
were checked locally and through `gh` on 2026-10-04.

Before freezing inventories, serialize ExDoc's search/sidebar metadata with
sorted JSON object keys, preserving array order and exact string values. Update
its content-derived filenames, HTML references and generated file list together.
The pinned [`ExDoc.Utils.to_json/1`](https://github.com/elixir-lang/ex_doc/blob/80270f3a4c4fe0d85c4b86029128e50995fcc21a/lib/ex_doc/utils.ex#L102)
uses map iteration order (source blob `44571a0a4ce370c38a01af4d59c524c71b3be15f`,
checked locally and through `gh` on 2026-10-05). Separate local VMs produced
semantically identical search items with different property order; raw file
digests therefore differed. Object-key normalization closes that reproducibility
gap without changing search meaning or accepting conflicting retained content.

Acceptance covers exact tag/application/source matching, tag movement during
build, rendered version/source/links/search, shared menu loading, independent
CSP/cache rules and byte-preserving identical/conflicting reruns. Stable
promotion still requires the separately pinned signed manifest, exact local
artifacts, public readback and source/build provenance; this candidate grants
none of those qualifications.

### Site assembly and local recovery

`./scripts/assemble-site development DEV_SITE OUTPUT [TRUST_FILE]` assembles a
clean-main eligible development build, preserving every retained release and
the current guide, download page and stable docs entry. The first assembly may
use the development build's no-release global pages. Preview, changed/unowned
inventories and non-private output custody refuse. Updating development docs
replaces only their subtree and regenerates the shared version menu, scoped
headers and assembly inventory.

`./scripts/assemble-site release DEV_SITE RELEASE_DOCS OUTPUT MANIFEST SIGNATURE
PUBLIC_KEY ARTIFACT_DIR TRUST_FILE SOURCE_COMMIT` additionally admits one exact
versioned candidate. Its tag/version/commit must match the manifest version and
the release workflow's explicit source commit. Verify the separately pinned
Ed25519 trust root, signature, exact local archive bytes and bounded public
readback before adding that version or generating customer links. Record the
accepted manifest/signature/public key and source/documentation digest beside
the assembled output; private keys and installer archives are never site assets.
Source provenance remains separate from manifest v1's artifact-byte claims.

Every retained version must match its complete documentation inventory and
recorded source identity, and its retained release signature must verify against
the separately supplied trust file. Development updates to a site containing
releases therefore require that trust file. Same-version changed source, docs
or signed archive manifest refuses. The regular trust file is builder/root-owned
with group/world write permissions clear. An identical replay retains the version
bytes. Stable docs/download/guide promotion selects the greatest admitted stable
SemVer using exact numeric components; adding an older version cannot rewind it.
The local assembly admits at most 32 retained versions within the static asset
budget. Reaching a ceiling refuses an additional version; no automatic pruning
or replacement is permitted.
Shared menu URLs omit a trailing slash because the pinned ExDoc consumer adds
the current page/anchor itself. Versioned asset cache and CSP rules stay scoped.

Serialize local writes with an exclusive private `OUTPUT.lock` directory under
an existing owned parent. Stage a complete validated assembly, sync its files and
directories, and record an owned bounded recovery journal before swapping local
directories. Recheck inputs and prior output before the swap. Refuse an existing
lock or unreconciled `OUTPUT.previous`; do not guess that another process ended.
Failures before swapping leave the prior output intact. Failures after swapping
begins retain the journal, stage/prior/current bytes and report uncertainty.

`./scripts/assemble-site recover OUTPUT [TRUST_FILE]` performs no network or
release effect. Inspect the journal's exact old/new manifest digests and actual
inventory/signature custody. Complete a verified new output or restore the
verified prior output; remove only this journal's owned stage/prior/lock after
reconciliation. Unknown, changed, symlinked or conflicting states refuse with
bytes preserved. This is local build recovery, not atomic GitHub/Cask/Sparkle/
Cloudflare publication or proof of filesystem power-loss persistence.

Acceptance joins real source/rendered bundles to signed fixture archives and
synthetic public responses, proving retention, independent development updates,
older-version and changed-version refusal, wrong trust/public bytes, lock
contention, input changes and actual process death at each directory-swap
boundary. Browser checks exercise multiple retained versions, stable/no-release
routes, download links, search/anchors, per-route CSP/cache and essential text
without JavaScript. Real production trust, installer/installed evidence, source
provenance and public deployment/readback remain their separate gates.

## Composition and independent instructions

The [build platform](build-platform.md) extends the public experience with
Phoenix/Ash/AshPostgres and phoenix-assets/Svelte 5/SvelteKit. The static-guide
decision applies to documentation and the offline lab, not to all companion
application routes. Route/deployment integration must preserve real release
links, offline behavior and the non-secret native handoff described here.

Milestone D delivers visual composition, exact procedures and printable parts
and shopping-list projections. Include exact revisions/quantities, source links,
evidence/unknowns, required tools/steps and app handoff without an account or
supplier API. Conjunct geometry/procedure references and DocShell explanations
bind to the same exact composition under [CI-05–CI-07](conjunct-integration.md).
Essential content remains usable without WebGL, colour or network access.
Indicative prices are dated and partial sums labelled. Optional transactions,
purchasing and care remain deferred F, currently on hold; they do not gate the
guide, engine-consumer proof or native installation.

## One Mac release artifact

Publish one Developer ID signed, hardened-runtime, notarized, stapled Mac DMG
for direct download, Homebrew Cask, and Sparkle updates. Its version, digest,
bundle identity, and minimum macOS version are fixed in a release manifest.
The [release artifact manifest](release-manifest.md) is detached-signed and
checked against each local archive before any guide link is published.
The first Cask can live in a project tap; upstream Homebrew acceptance is a
separate gate. The Cask pins the artifact digest and marks in-app updates
accurately. Sparkle
uses an independently signed EdDSA archive/appcast and verifies the app's
Developer ID identity; the updater must not downgrade or replace library data.
Test fresh installation, update, rollback recovery, removal, and Gatekeeper on
clean supported Macs. The current ad-hoc development bundle is not this
artifact.

Host binary downloads use a separate public release channel created public
from the outset; a GitHub Releases repository is the initial choice. The guide
links to its immutable versioned assets and verifies checksums. Publishing
requires a license, notices, signing credentials, owner-controlled public
channel, a repeatable release process, and the applicable installed/physical
product gates. No existing repository visibility change is part of this plan.

Mac-native release commands are being migrated to Swift; portable release
verification, source/receipt policy and channel rendering/signing belong to
Elixir, with thin POSIX shell entry points. The
[tooling contract](../host/macos.md#mac-release-tooling-implementation) and
[portable migration rules](release-manifest.md#release-tooling-ownership-and-migration)
require qualification before each command switches. The documented Node
commands remain the current implementation until that cutover; this language
decision does not qualify signed artifacts or an installed updater.

### Local Mac channel material

`scripts/derive-macos-channels MANIFEST SIGNATURE PUBLIC_KEY ARTIFACT_DIR RELEASE_TRUST MINIMUM_OS SPARKLE_SIGNATURE SPARKLE_TRUST OUTPUT`
prepares a private Cask/appcast candidate from the signed manifest's unique
macOS/universal/DMG tuple. It performs no upload, tap change, network request or
application update. The output has publication authority `none`; local byte and
signature checks cannot attest the installed app, minimum OS or publisher rights.

Channel URLs are bounded to 2,048 UTF-8 bytes and each generated file to 16 KiB.
The minimum OS is an explicit canonical `major.minor.patch` declaration from the
qualified final Mac build, at least macOS 14.0.0. Production qualification must
bind that declaration to every nested Mach-O slice and the final app. Use the
stable release version as both `CFBundleVersion` and the displayed version;
Sparkle's numeric comparison must not depend on the development build counter.
The production publisher must independently join the final app's version,
`SUPublicEDKey`, embedded updater and minimum OS to this material before setting
customer links or the Cask's in-app-update claim. This local renderer does not
perform that join.

Read the release-key fingerprint through the existing protected trust-file
contract. The separately configured Sparkle trust file is an owner/root-owned,
non-writable-by-others regular file containing exactly 32 public-key bytes as
canonical base64 with an optional LF. It must not come from the signed manifest
or update response. Admit a separate canonical base64 64-byte Sparkle signature,
as emitted by Sparkle's `sign_update -p`. Verify ordinary Ed25519 over the exact
DMG bytes, independently of the release-manifest signature, and require the
manifest's exact size and SHA-256. Keep the existing 1 GiB Mac disk-image bound;
the current verifier buffers that bounded message for Node's Ed25519 API. The
replacement must preserve the whole-message signature profile and bound. The
bound is not a measured whole-job RSS ceiling. Unsafe/nonregular inputs, malformed
encoding, missing Mac tuple, changed bytes, untrusted keys and signature failure
refuse before output creation.

Derive the Cask's stable version, SHA-256 and immutable URL from that tuple. Its
fixed application is `Frameshift.app`, homepage is the canonical site, and it
declares the supplied minimum OS and in-app updates for the intended Sparkle
release. Do not add uninstall hooks, destructive `zap`, artifact-host guessing
or a second archive. Render one full-update RSS item with top-level Sparkle
version/short-version/minimum-system-version fields, the same URL and length,
and verified EdDSA enclosure signature. There are no deltas, external release
notes, dates inferred from local time or invented compatibility claims. Archive
signing is required; the signed mode below also signs the feed. Runtime
signed-feed integration remains a separate product gate.

Use an absent output under an owned, protected real parent. Create mode 0700,
write mode 0600 files, synchronize bytes and retain a pending marker until the
complete `frameshift.rb`, `appcast.xml`, `sparkle.sig` and deterministic
`channels.json` record have been verified. The record distinguishes the declared OS from qualified
platform evidence and records local-only authority. A complete identical replay
verifies all inputs and retained bytes without rewriting files; unknown members,
partial output, changed inputs or same-output conflicts refuse without deletion.
No refusal may print input paths, key bytes or cryptographic exception details.

Acceptance uses distinct ephemeral release/Sparkle keys, exact local archives,
real Ruby syntax and XML parsing, signature/tamper/grammar/custody refusals and
unchanged replay. Compare the signature profile with the exact upstream Sparkle
tool in an isolated fixture. These software checks do not qualify a DMG, a real
tap, installed updater, signed feed, Developer ID, public archive readback or
production release.

### Signed Mac channel material

`scripts/sign-macos-channels MANIFEST SIGNATURE PUBLIC_KEY ARTIFACT_DIR RELEASE_TRUST MINIMUM_OS SPARKLE_SEED SPARKLE_TRUST OUTPUT`
uses the same verified manifest, declared OS, bounded archive and output-custody
contract. Its separately supplied Sparkle seed is canonical base64 of exactly
32 bytes, with an optional LF, in an operator-owned regular mode 0400/0600 file.
Derive the Ed25519 public key and require it to equal the independently pinned
Sparkle trust file before signing. Never read Keychain keys, accept seed bytes
in argv/environment, log key material or generate production keys automatically.

Sign the admitted exact archive and then the renderer's exact UTF-8 appcast body
with that key. Append Sparkle 2.10's canonical signature comment containing the
feed's base64 Ed25519 signature and exact body byte length. The signature covers
every byte before that comment; it is not a signature over a hash. Suppress no
verification on malformed bytes, altered length or unknown suffix. Keep the
complete generated feed within the existing 16 KiB metadata bound. This format
matches upstream `sign_update --disable-signing-warning`; no external release
notes or their separate signature are introduced.

Both renderer modes retain the canonical public archive signature as
`sparkle.sig`. The signed mode's record declares verified feed signing and hashes
all three public output files; it still has publication authority `none`. Replays
and interrupted outputs follow the existing no-replacement contract. A signer
rerun requires its protected seed; later consumers never need that private key.

`scripts/verify-macos-channels MANIFEST SIGNATURE PUBLIC_KEY ARTIFACT_DIR RELEASE_TRUST MINIMUM_OS SPARKLE_TRUST OUTPUT`
is read-only. It revalidates the independently signed manifest, exact local DMG
and retained archive signature; verifies the feed's signature using only the
pinned public key; and requires the unsigned body to equal the canonical body
regenerated from those inputs. It compares the complete Cask, signed feed,
public signature and record, including output names, private modes and unchanged
directory custody. Wrong key, digest, version, URL, OS declaration, signing
length, record, namespace or bytes refuses without rewriting anything. A changed
minimum-OS declaration cannot be laundered through a valid signature over a
noncanonical feed. CLI diagnostics remain fixed and secret-free.

Acceptance adds wrong-seed/private-mode and feed-body/footer tamper refusals,
public-only verification with the seed absent, immutable signed replay and
actual upstream signing/verification of the canonical feed. These checks qualify
local signed metadata, not the runtime client's signed-feed settings, installed
update, production keys, Developer ID/notarization, public delivery or promotion.

## Linux and Pi delivery

Ubuntu amd64 and arm64 receive architecture-specific OTP releases and native
renderer binaries inside versioned `.deb` packages. Direct downloads are
verified against a signed release manifest; `dpkg` alone does not authenticate
a downloaded package. A signed APT repository may
offer updates after the direct package path passes installation and recovery
tests. Raspberry Pi 5 running supported Ubuntu Server arm64 uses that arm64
package and the same core/protocol contract. A separately qualified Nerves Pi 5
image serves a dedicated bridge/appliance role; it is not the Ubuntu package,
and its firmware update, credential, persistent-data, and log paths are
qualified separately. See [Linux host](../host/linux.md).

## Public release reconciliation

`scripts/inspect-release-channel OWNER/REPO MANIFEST SIGNATURE PUBLIC_KEY
ARTIFACT_DIR TRUST_FILE` observes an independently configured public GitHub
Releases channel using `gh` GET requests. First verify the owner-pinned local
signature and exact archives. Every archive URL must name that repository's
exact `/releases/download/vX.Y.Z/FILENAME`; refuse another channel or any archive
at or above the channel's 2 GiB limit before network work. The channel is separate
from the source repository. Its `target_commitish` cannot prove the product
source commit; exact-source/candidate acceptance remains its upstream boundary.

Require the repository's observed visibility to be public. Query only computed
repository/tag/asset endpoints with bounded responses and request/processing
budgets; never follow an API-provided URL or pagination link. A tag endpoint 404
means `not-published`, not that no draft/ref exists or a new release may be created.
An inaccessible/malformed response, wrong tag/release ID, private channel or
prerelease refuses. A draft cannot pass anonymous public acceptance.

The current asset profile contains the manifest's archives plus `manifest.json`,
`manifest.sig` and `release.pub.pem`. Refuse duplicates, extra/unrecognized assets,
wrong names/URLs, changed byte counts/digests and unsupported states. Missing
assets or an interrupted `starter` upload return `incomplete`, retaining all
remote bytes; they never authorize deletion, replacement or blind retry. Compare
an API-provided SHA-256 when available, but its absence cannot replace anonymous
readback and its presence cannot establish the served bytes.

For a complete published set, anonymously stream every archive and all three
metadata files with the existing HTTPS redirect, deadline, identity-encoding,
size and SHA-256 rules. Recheck local signed files/archives and the same remote
repository/release/asset inventory afterward. Any in-flight change refuses.
An unchanged observation can report `public-bytes-verified`, with publication
authority `none`; it does not grant source, license/notices, installed, signing
identity or channel-promotion acceptance. A rerun observes the retained bytes,
without building, writing a remote ref, uploading, deleting or promoting.
The CLI emits its bounded JSON observation and exits 0 only for
`public-bytes-verified`, 2 for incomplete/not-published, 1 for fixed-diagnostic
refusal and 64 for usage. A passing byte observation still has no release authority.

Acceptance covers signed local joins, zero-request malformed/size/channel refusal,
published/draft/missing/partial/conflicting states, metadata-digest absence,
wrong actual public bytes and changed local/remote custody. Fixture APIs and
responses do not establish a real Frameshift release. A live upstream read may
check the selected GET transport without changing an external repository.

## Ubuntu candidate workflow

`.github/workflows/ubuntu-candidate.yml` is a manually dispatched build/check
workflow. The operator supplies an existing stable tag and its independently
known exact commit. The source job uses `gh` against the current repository to
resolve the remote tag, peeling a bounded annotated-tag chain, and refuses a
different commit, unavailable reference or unsupported object. It then checks
out that commit and freezes its actual source/app-version record. Remote tag
identity is checked again around source verification and target transport.

The Ubuntu 24.04 amd64/arm64 matrix depends on that source job. Each target
recomputes the same deterministic source-record digest, admits the physical/native
runner and Docker architecture, and fetches exact locked dependencies with pinned
Hex. Use private runner-temporary Hex and absolute XDG Gleam checksum-cache roots.
Prepare only admitted generated Gleam metadata, then emit core/Gleam source
receipts before copying/building. The target builder uses pinned native images;
exact candidate/container acceptance must pass. Reverify both source receipts
without rewriting afterward and join captured dependency facts against the exact
candidate record. Generated and retained Git metadata stay outside source proof.

Recheck remote/source identity in a separate read-only step before transport.
Create and verify one candidate USTAR, then a separate fixed-profile source-evidence
USTAR. The evidence receiver must join against the **received** candidate using
independently retained candidate/core/Gleam/join hashes. Recheck remote identity
after both receivers; compare both final archive digests before upload. Wrong CPU,
source/receipt identity, moved tag, failed acceptance or changed artifact prevents
uploads. A partial artifact pair is incomplete evidence. Target source tools take
data arguments rather than interpolated workflow expressions in shell commands.

The workflow has contents-read permission, no signing/deployment secret or
protected publication job. Checkout credentials are not persisted and mise's
GitHub token stays inside its action. Read-only job tokens are scoped to remote
`gh` checks and the Ubuntu preparation/build step's public pinned Gleam release
download; source gates, candidate acceptance/replay and TAR/evidence receivers
receive no job token. That build/preparation credential is not a publisher or
execution attestation. Successful outputs are two separate single-file non-ZIP
TAR artifacts per CPU, preserving internal private/executable modes, with distinct
run/attempt identities and `overwrite: false`. Retain both artifact IDs and
source/candidate/core/Gleam/join/archive SHA-256 values in the job summary. A fresh
runner rebuild is another candidate; it does not establish identical released
bytes. A later release consumes accepted exact bytes and revalidates their
handoffs before signing/promotion.

Acceptance includes remote-ref/annotated-tag/error/moved-tag and exact source-digest
fixtures; workflow syntax, step-order, permissions and credential-scope checks;
and both candidate/source-evidence receivers joined to full retained target
artifacts. Authoring/static/local container evidence is separate from a hosted
GitHub run, native amd64/default JIT, booted systemd and installed qualification.
No workflow push or dispatch follows from implementing this sequence. Publisher/
rights, generated/toolchain, signing, public readback and channel/site promotion
remain separate release gates, with publication authority none.

### Candidate archive handoff

The Ubuntu candidate producer emits an uncompressed POSIX USTAR archive rooted
at `ubuntu-candidate/`, with hard-linked files represented as independent regular
files. Verify the producer's TAR with the same receiving command before upload.
Record its SHA-256 after candidate verification and retain that digest, exact
source digest, target, run/attempt and artifact ID in the job output/summary.
A receiver must obtain the expected digest through its trusted job handoff;
the local command does not authenticate a workflow run. An Actions artifact ID or the downloaded file's
self-computed digest cannot supply the independent expected identity.

`scripts/stage-linux-candidate TAG COMMIT SOURCE_RECORD arm64|amd64 ARCHIVE SHA256
OUTPUT` receives that exact archive beside the qualified source checkout. It
MUST verify the independently supplied transport hash, exact frozen source and
the existing complete candidate record without rebuilding. Admit only regular
files/directories under that one root; reject traversal, duplicate or conflicting
names, links/devices/FIFOs, extensions/compression, malformed checksums/numbers,
nonzero padding/trailing material and unsafe modes. Do not run an unrestricted
archive extractor, restore archived ownership or overwrite an existing name.

This profile admits at most 1 GiB of archive/payload, 512 MiB per file and 65,536
entries. Check available destination space for the payload plus a 128 MiB reserve
before writing. Use bounded descriptor reads and compare archive identity before
and after extraction. Extract into a new owner-only directory, preserve admitted
file modes, then compare every regular member's bounded descriptor bytes with
its admitted archive payload, including same-size substitutions. Verify exact
directory names/modes and source/candidate inventories, synchronize files and
verify again before
publishing a private `handoff.json`. The record binds the transport, candidate and
source digests with publication authority `none`; it is separate from manifest v1.

An identical complete replay verifies without rewriting or extracting. Changed,
unsafe or interrupted output refuses and retains previous/partial bytes for
inspection. A staged candidate still needs installed acceptance, license/notices,
signing and public readback before release promotion. Acceptance joins real
USTAR producers to exact-source/candidate fixtures and refusal cases, plus a
retained full-product candidate; it does not dispatch a hosted workflow or publish.

## Browser installation lab

The public page gives a useful simulation before purchase or installation:
select a frame class and capability profile, supply a still sample, inspect
the planned crop/profile and transfer states, inject loss/restart, and see why
the previous image remains current. Example profiles are marked simulated.
Browser image/crop rendering is explicitly illustrative; exact preview and
wire bytes require the installed renderer and a qualified frame profile.
The page does not claim exact panel color, firmware behavior, physical display
success, or real pairing from the browser.

Extract a **small pure decision kernel** from host logic into Gleam and build
the same source for Erlang and JavaScript. Its scope is capability admission,
bounded profile selection, state labels, and simulated delivery transitions.
It performs no filesystem, credential, network, crypto, or hardware I/O. The
production Elixir core remains the only authority for actual delivery; the
Zig renderer remains the authority for exact artifact bytes. The browser's
preview is illustrative until a separately qualified exact-render path can
prove parity. Pin Gleam and OTP/JS targets, stay within JavaScript safe integer
range, use fixed-point rules where arithmetic crosses runtimes, and run the
same fixtures and generated cases on both targets. Any semantic divergence
blocks publishing the lab.
The release target is Erlang/OTP 29 with Elixir 1.20.4 and Gleam 1.18.1, a
combination supported by the official compatibility tables. Build and package the Erlang output
with the host release; test the JavaScript output in the guide's browser matrix.

After installation, the guide may hand off a selected class and non-secret
profile to the native app through a registered deep link. The app presents the
selection and performs pairing through its authenticated local flow and
physical pair mode. The link carries no token, credential, local path, command
authorization, or hidden mutation. Direct browser-to-loopback/frame control
is not part of the release: origin authorization, browser local-network
permissions, and cross-browser behavior would require a separate security and
compatibility decision.

For advanced experimentation, provide a **locally run Livebook** that drives
the simulator with named fixtures. It is not a public code-execution service
or a commissioning dependency. The public guide remains usable without it.

## Release acceptance

1. The public guide's commands, supported OS/CPU versions, artifact digests,
   Cask, update feed, and package links match a released manifest.
2. Static deployment serves correct caching/security headers, accessible
   keyboard flows, and a bounded simulation that needs no network after its
   assets have loaded on supported browsers.
3. BEAM and JavaScript kernel fixtures agree, including invalid capabilities,
   version skew, interrupted transfer, and unknown display outcome.
4. Deep-link input is bounded, non-secret, and requires visible native action;
   pairing never becomes a website-originated mutation.
5. Mac direct/Cask/Sparkle paths install or update the same signed product;
   Ubuntu/Pi packages preserve data across upgrade and removal.
6. Every support claim links to exact installed or physical evidence. The page
   never calls a simulated frame physically validated.

Upstream evidence: [Gleam targets](https://gleam.run/documentation/command-line-reference/),
[Gleam JavaScript integer range](https://gleam.run/news/context-aware-compilation/),
[Gleam/OTP compatibility](https://gleam.run/documentation/compatibility-reference/),
[Elixir/OTP compatibility](https://hexdocs.pm/elixir/compatibility-and-deprecations.html),
[Cloudflare static asset limits](https://developers.cloudflare.com/workers/platform/limits/),
[Cloudflare static asset billing](https://developers.cloudflare.com/workers/static-assets/billing-and-limitations/),
[Homebrew Cask format](https://docs.brew.sh/Cask-Cookbook),
[APT repository authentication](https://manpages.debian.org/testing/apt/apt-secure.8.en.html),
[Sparkle distribution](https://sparkle-project.org/documentation/), and
[Chrome local network access](https://developer.chrome.com/blog/local-network-access).
