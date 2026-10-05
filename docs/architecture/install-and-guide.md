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

## Ubuntu candidate workflow

`.github/workflows/ubuntu-candidate.yml` is a manually dispatched build/check
workflow. The operator supplies an existing stable tag and its independently
known exact commit. The source job uses `gh` against the current repository to
resolve the remote tag, peeling a bounded annotated-tag chain, and refuses a
different commit, unavailable reference or unsupported object. It then checks
out that commit and freezes its actual source/app-version record. Remote tag
identity is checked again around source verification and after target work.

The Ubuntu 24.04 amd64/arm64 matrix depends on that source job. Each target
recomputes the same deterministic source-record digest before building, uses
the pinned native target images and runs exact candidate/container acceptance.
Wrong target CPU, source digest, moved tag, failed build/check or changed artifact
prevents an artifact upload. Source and final archives remain bound to their
records; the target source tools are invoked with data arguments rather than
interpolated expressions in workflow shell commands.

The workflow has contents-read permission, no signing/deployment secret or
protected publication job. Checkout credentials are not persisted and mise's
GitHub token stays inside its action. An explicit read-only job token is scoped
to steps that use `gh`. Successful outputs are short-lived candidate TARs,
preserving private record and executable modes, with distinct run/attempt names.
No rerun overwrites an earlier candidate artifact; a fresh runner's rebuild is
another candidate, not proof of identical released bytes. Actions artifact IDs
and hashes are staging metadata. A later release consumes accepted exact bytes,
verifies handoffs and retains them before signing/promotion.

Acceptance includes remote-ref/annotated-tag/error/moved-tag fixtures, exact
source-digest checks, workflow syntax and permission checks, plus the existing
candidate builders and container joins. A local passing fixture does not count
as an executed GitHub runner or installed native/systemd qualification. License/
notices, stable accepted-byte rerun, Mac signing/DMG/Cask/Sparkle, public-channel
readback and site promotion remain the release pipeline's separate work.

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
