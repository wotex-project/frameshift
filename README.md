# Frameshift

![Product scope: Complete specification](https://img.shields.io/badge/product%20scope-complete%20specification-blue)
![Implementation: In progress](https://img.shields.io/badge/implementation-in%20progress-orange)
![Release evidence: Incomplete](https://img.shields.io/badge/release%20evidence-incomplete-red)

> [!WARNING]
> **Frameshift is not yet a finished or certified product.** The specifications
> define the complete intended product; implementation and evidence ledgers
> state what is currently proven. Unfinished implementation must never be used
> to silently reduce the product specification.

Frameshift is a system for thin digital art frames that behave as much like
framed artwork as their display technology permits. A native macOS menu-bar app
imports or generates a still image, renders exact artifacts for a frame, and
then gets out of the way.

Frameshift is the first modular reference product and integration proof of
concept for Conjunct's physical composition and instruction engine. Its product
bundle supplies frame profiles, procedures and evidence; its native app,
renderer and device behavior remain product software. The companion workbench
uses Conjunct's composition and instruction semantics to explain configurations
and produce visual instructions and a printable parts and shopping list from
the same physical composition. Frameshift supplies the frame-specific rules,
content and interface; its retained v1 BuildSpec preview is a replay and
migration bridge, not a second workbench engine.

The [platform specification](docs/architecture/build-platform.md) and
[Conjunct integration contract](docs/architecture/conjunct-integration.md) define
the ownership and migration. Transactional shop work is on hold. Optional
service capabilities remain a separate deferred extension with their own
authority and producer conformance requirements.

This repository contains technical requirements, product code and evidence.
Company pricing, partnerships and legal interpretation are external decisions;
any enabled operation must still enforce its explicit approved scope.

## Reference media

| Target | Display | Power truth |
| --- | --- | --- |
| **Paper Frame** | reflective full-color e-paper | Can be cable-free and passive between updates where the complete design supports it |
| **Photo Frame** | matte IPS/LVDS/eDP and other explicitly qualified panel interfaces | Needs continuous power while visible |
| **Pixel Frame** | low-resolution HUB75 RGB matrix | Needs continuous, potentially high-current power |

These are interoperable reference classes, not a closed list of product SKUs
or allowed diagonals. Any vendor or custom frame can participate when it
truthfully describes its capabilities and implements a qualified protocol
binding. The complete installed composition must be thin; the panel alone is
not the measurement. There is no arbitrary global size limit.

Zero visible cable is a priority during hardware and mounting research, not a
hard requirement. For emissive frames it requires a powered mount, concealed
supply or carefully routed cable; it does not mean the display uses no power.

## Architecture

```text
                   Frameshift for macOS
          SwiftUI shell + Elixir core + Zig renderer
                              |
                still-image Frame Protocol
                  _________|_________
                 /         |         \
             Paper       Photo      Pixel
           sleeping MCU  qualified  timed scan
                         scanout    controller
```

The Mac retains source masters, AI recipes and rendered derivatives. Frames
retain verified still assets and their last known-good image. A sleeping frame
can wake and pull pending work; powered frames can also receive pushes.

There is no video, animation, motion, audio or streaming path in the frame
artwork protocol. A slideshow is a timed sequence of cached still images.
Visual assembly instructions in the companion guide are a separate renderer.

## Repository and build order

| Area | Owner and role |
| --- | --- |
| `apps/core`, `apps/macos`, `renderer`, `protocol`, `firmware` | Frameshift's independent still-artwork host and frame product |
| `data/physical`, `packages/build-spec` | Frame profiles, required frame checks and retained v1 identity/replay; the v1 preview cannot admit a build |
| Conjunct | Generic composition, comparison, CheckReports, parts projection and instruction semantics; no qualified package is installed here yet |
| `apps/build-platform` | Frameshift product UI, catalog/evidence storage and authorized Conjunct consumer |
| Refpath | Later adaptive/operator generations and effects; not required for independent composition or native artwork |

Qualify Conjunct's existing Rust kernel, Elixir port/browser WASM bindings and
guide with exact Frameshift profile/consumer fixtures. Preserve v1 identities
through an explicit migration, then connect the workbench to qualified producer
exports. The host authorization and native
artwork lanes can progress independently. Transactional services remain on
hold. The [implementation plan](docs/architecture/implementation-plan.md) and
[verification map](docs/architecture/verification.md) separate required work
from completed evidence.

## Stack direction

- Elixir/OTP for the macOS orchestration core.
- Phoenix + Ash/AshPostgres and phoenix-assets + Svelte 5/SvelteKit for the
  companion web platform; qualified Refpath loads product-owned packs.
- Conjunct for generic physical-composition and instruction contracts; exact
  producer exports and consumer tests must pass before adoption.
- Shared pure Gleam decisions for native/guide behavior and retained v1 replay,
  targeted ExMaude verification and bounded read-only Beamlens diagnostics.
  Models are optional and qualified per task; they do not decide compatibility
  or grant external-action authority.
- Rivure for optional financial integration and DocShell for portable
  explanatory artifacts; no duplicate provider engine or documentation model.
- Swift/SwiftUI for the native menu-bar shell and Apple frameworks.
- Zig for the isolated raster worker. Select MCU/scanout firmware tooling from
  exact interface, update, power, memory and protocol evidence.
- Ubuntu amd64/arm64 hosts and a Raspberry Pi 5 Ubuntu host reuse the core;
  a dedicated Nerves Pi 5 appliance is a separate host release target.
- Local-first image generation with explicit provider and cloud disclosure.
- No project-owned Python application or firmware code. Pinned upstream
  toolchains may use Python inside isolated reproducible builds.
- No Raspberry Pi hardware inside Frameshift reference frame builds. The
  separate host targets above do not authorize a rear-mounted Pi workaround.

## Installation direction

The first public guide is planned for `frameshift.wotex.io`. It will lead from
frame choice through a browser simulation that runs locally after loading to a
signed Mac download or Homebrew Cask, with separate Ubuntu and Pi-host
instructions. The browser simulation cannot pair a physical frame; installed
native software performs pairing and delivery. See the
[installation and guide contract](docs/architecture/install-and-guide.md) and
[Linux host specification](docs/host/linux.md). No public download is available
until signing, packaging, licensing and installed-release gates pass.

## Principles

- Prototype risky assumptions where useful; the complete intended product is
  not reduced to the currently easiest prototype.
- Panel, controller, power, cable bends, battery, backing, thermals and mounting
  all count toward installed depth and physical qualification.
- Local frame operation and the independent list require no vendor cloud
  account or subscription. Optional external operations have separate scoped
  authorization and producer contracts.
- Still-image-only, capability-driven device protocol.
- Source masters and generated results are immutable and cached.
- Interrupted transfers never replace valid artwork.
- Cloud AI never happens as a silent fallback.
- Unknown facts remain visible; simulation and attractive geometry are not
  proof of measured compatibility or certification.

See [docs/README.md](docs/README.md) for specifications, evidence and open gates.

## Development

The current partial implementation includes an Elixir library/simulator core,
an isolated Zig raster worker, a SwiftUI shell, and the separate
[Phoenix/Ash platform foundation](apps/build-platform/README.md). This is implementation
status, not the product scope or a release tier. Run the default format,
static-analysis, test, fuzz, and release-build gate with:

```sh
make check
```

`workspace.json` records component roots and allowed dependencies.
`./scripts/check-workspace` checks the graph and static Elixir imports before
component moves; it also runs as part of the repository policy gate.

The [isolated Linux codec](codec/README.md) has a bounded static-PNG profile.
`./scripts/check codec` runs its native format/static/debug/release gate;
`./scripts/check linux-codec` builds the pinned Linux arm64/amd64 fixtures and
runs the same corpus as a nonroot process with read-only root and no network.
It also joins authenticated private upload and exact Library results to freshly
built Linux SQLite/Exile NIF/helper artifacts against pinned OTP headers.
Fresh CLI original imports and receipt recovery pass; installed DEBs remain separate work.

The Docker-backed live receiver and Linux peer-credential checks are separate
lanes in CI. Run them locally with `./scripts/check container` and
`./scripts/check linux-ipc` when a Docker-compatible daemon is available.
The companion server has its own PostgreSQL-backed `./scripts/check platform`
lane; its README documents fixture setup and generated frontend checks.

The core's `mix check` configuration covers compilation, formatting, strict
Credo, Doctor, ExDoc, coverage, Dialyzer, and dependency audits. Swift Package
tests and the Zig Debug and ReleaseSafe test builds are part of the repository
gate. Run `make index` for the local Dexter code index, and run `mix bench` from
`apps/core/` to regenerate Markdown performance reports.

On macOS, build the current ad-hoc-signed development bundle with its embedded
Elixir core and Zig renderer with:

```sh
./scripts/package-macos
```

The generated `.app` is for local inspection and automated installed-flow
checks. It is not Developer ID signed or notarized, and background service
registration through Launch at Login has not passed installed lifecycle
acceptance.

See the [software verification map](docs/architecture/verification.md) for the
requirement-to-test links and the evidence that remains open.

## License

License selection remains an open release gate. Until a license file is added,
the repository does not grant reuse rights beyond those provided by law.
