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
points. The publication assembler must later verify and retain release docs,
isolate development replacement, serialize writes and reconcile interrupted
deployment; this builder does not claim that publication work has passed.
Acceptance combines clean/dirty source fixtures, parsed link/image custody,
full corpus rendering and local link/anchor checks, real Chrome search/API/version
navigation, narrow-viewport keyboard access, essential text without JavaScript
and HTTP 404 behavior. Installed/public Cloudflare and release-version evidence
remain separate.

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
