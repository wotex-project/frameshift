# Static installation guide

This directory builds the illustrative Frameshift field guide and offline
browser lab. It is a development artifact, not a published installer or
physical frame validation. The requirements are in
[browser guide simulation](../../docs/architecture/guide-simulation.md) and
[implementation plan](../../docs/architecture/implementation-plan.md).

Run `./scripts/check guide` from the repository root to compile the pinned
Gleam JavaScript target, produce `apps/guide/dist`, and test the lab state model.
On a Mac with Chrome, run `./scripts/check guide-browser` to exercise the
page at a real mobile viewport, check accessible names and keyboard actions,
reject invalid files, load a local still, and verify delivery recovery after
the local HTTP server stops. Set `FRAMESHIFT_GUIDE_SCREENSHOT_DIR` to a
directory to save the desktop, mobile, and lab screenshots from that smoke
test.

`apps/guide/wrangler.jsonc` points Workers Static Assets at `apps/guide/dist`. Its
`workers_dev` setting is disabled. A domain owner must separately configure
the intended hostname and public release artifact channel before any
deployment. The guide contains no live download links until a checked release
manifest and signed artifacts exist. The source repository's visibility is
not part of this deployment path.

For a release-mode build, set all five `FRAMESHIFT_RELEASE_MANIFEST`,
`FRAMESHIFT_RELEASE_SIGNATURE`, `FRAMESHIFT_RELEASE_PUBLIC_KEY`,
`FRAMESHIFT_RELEASE_ARTIFACT_DIR`, and `FRAMESHIFT_RELEASE_TRUST_FILE` paths
before `./scripts/check guide`. A missing or invalid input refuses the build;
the trust file comes from the owner-approved release configuration. The site
publisher must separately fetch each public URL and verify its bytes before
deployment.

For the local combined documentation site, run `./scripts/check docs` or
`./scripts/check docs-browser` from the repository root. The first renders all
maintained Markdown and core API documentation, checks source/index/link
custody and builds `var/site-preview`; the second also exercises real Chrome
search, keyboard controls, narrow layout, API/version links, no-JavaScript
recovery text, HTTP 404s and the generated security policies. `./scripts/build-site`
requires clean `main`; `--preview` permits uncommitted inspection and records
that its output cannot be published. Neither command deploys or promotes a
release. See the [development documentation contract](../../docs/architecture/install-and-guide.md#development-documentation-build).

`./scripts/build-site --release-docs vX.Y.Z COMMIT` requires a clean checkout at
that exact stable tag and application version. It builds `var/site-vX.Y.Z` with
an immutable version directory, source/file inventory and a shared ExDoc menu.
The candidate keeps no-release global pages and cannot be deployed as a
qualified release. The docs checks also build an isolated test-only tagged
fixture and verify refusal/rerun custody; the browser lane tests actual version
changes with preserved API anchors. See the
[versioned documentation contract](../../docs/architecture/install-and-guide.md#versioned-documentation-builds).

The three compressed frame illustrations come from the maintainer's desktop
`Frameshift.html` visual draft. The Frameshift SVG is the existing macOS mark.
No externally loaded fonts, scripts, trackers, or image hosts are required.
