# Browser Guide Simulation

**Status:** normative guide behavior; browser and release evidence belongs in
the [verification ledger](verification.md).

The static installation guide uses the desktop `Frameshift.html` as visual
reference. Its field-guide layout, typography, and three independent media
paths inform the implementation. The guide must remain a small, responsive
document with an accessible keyboard path; the embedded desktop draft is not
shipped wholesale.

## Example capability profiles

The lab offers three explicitly **simulated** examples. The Paper example uses
the candidate Waveshare 13.3-inch E6 geometry (1600×1200) and the documented
180-second minimum refresh spacing. A provisional six-hour cycling suggestion
is shown with its basis. Its panel-packed artifact profile is not supported by
the current RGB24 renderer or shared profile selector. The guide must refuse
to call that example ready for transfer.

The Photo example uses the candidate BOE 2560×1440 geometry and a simulated,
tightly packed sRGB RGB24 capability. The Pixel example uses the candidate
six-module Waveshare 192×128 geometry with the same simulated RGB24 packing.
Their panel/controller selections and physical behavior remain unqualified.
For Photo and Pixel, user-selected artwork dwell is an aesthetic rotation
choice; a longer dwell has no claimed display-energy benefit.

The browser invokes the compiled JavaScript build of the same Gleam function
used by the host for RGB24 profile choice and bounded dwell. It shows a
refusal for unsupported packing, invalid capacity, or an unknown profile. It
never invents a compatible replacement profile for Paper.

## Local lab contract

- A user may choose one class, optionally load one local still image, and
  inspect the illustrative center crop. Decode only common image formats and
  cap the file at 8 MiB, decoded dimensions at 8192 pixels per side, and
  decoded area at 16,777,216 pixels. Keep
  the image in browser memory; never upload or persist it.
- The lab shows current and desired as separate concepts. Queuing a simulated
  revision changes desired only. A valid display confirmation changes current.
  An interrupted transfer, restart, version mismatch, digest mismatch, or
  unknown outcome leaves current unchanged and desired pending. Recovery can
  confirm the still-pending revision.
- Simulated digests and request IDs are local opaque labels. They are never
  passed to a physical frame. Generated preview pixels are not Zig renderer
  bytes or panel color evidence.
- The lab uses no account, storage, service worker, analytics, browser-to-host
  request, or remote code. Its imported decision module and all assets are
  local. Once loaded, it must remain usable without a network connection.
  A reload after connectivity is lost is outside this contract because the
  browser may need to fetch the document and modules again.
- Every event reports a short textual outcome in an `aria-live` region. All
  controls are native buttons, selects, and file inputs with visible focus.
  No color alone conveys state.
  The browser smoke checks accessible names for interactive controls and
  activates core choices by keyboard. It also checks invalid file rejection;
  manual VoiceOver and cross-browser inspection remain release gates.

On 2026-09-24, the built guide was served locally and inspected in desktop
Safari on macOS 26.6.2 arm64. The page rendered and Safari's accessibility tree
included the live unsupported Paper result and named delivery controls. A
Desktop screenshot records that layout. This observation does not cover Safari
keyboard operation, file import, mobile Safari, VoiceOver, or other browsers.

## Delivery and acceptance

Build the guide from checked-in source and the pinned Gleam JavaScript output.
Copy only the generated module's transitive runtime dependencies, not tests or
the build tree. Verify every copied path stays inside the generated-output
root. The build is deterministic, keeps every asset below the static hosting
limit, and produces a read-only directory suitable for Cloudflare Workers
Static Assets. Serve JavaScript as modules, set restrictive security headers,
and avoid framing/inline script. Versioned release download links appear only
when a checked release manifest and signed artifact channel exist; until then
the guide states that installation artifacts are unavailable.

Publish the lab at the canonical `frameshift.wotex.io` site with `/download/`
and generated documentation under the
[installation/publication contract](install-and-guide.md). Retain static
`/docs/vX.Y.Z/` output and clearly label `/docs/dev/`; the latest docs entry point
cannot present development content as a released install. GitHub Actions builds
and checks these assets before Cloudflare deployment. Integrating the workbench
must preserve documentation/download routes and the lab's offline behavior.
The local site builder joins the guide, Markdown and API documentation and
checks retained versions. Public hostname configuration and deployment remain
open; Wrangler assets configuration alone does not establish publication.

Acceptance covers the two compiled Gleam targets, a local HTTP offline lab
exercise, keyboard and small-screen inspection, safety refusals, and build
reproducibility. Physical and installed claims need their separate gates. See
the [implementation plan](implementation-plan.md) and
[shared decision kernel](shared-decision-kernel.md).
