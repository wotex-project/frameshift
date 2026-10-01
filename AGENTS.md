# Frameshift agent instructions

This file is the repository contract for every coding agent. Read
[README.md](README.md), [docs/README.md](docs/README.md), and the documents that
own the affected behavior before changing it. Clients without native
instruction discovery must read this file explicitly.

## Product and implementation boundaries

- Frameshift is a modular reference product for Conjunct and an independent
  native application for thin digital art displays. The documents under
  `docs/` define the intended product; partial implementation does not reduce
  their scope.
- Preserve the separation between host, Frame Protocol, frame agent, display
  adapter, and physical panel. Select behavior from advertised capabilities;
  vendor/model branches require an evidenced quirk.
- The host owns expensive rendering and immutable source masters, recipes, and
  derivatives. Frames own persistence, capability reporting, atomic asset
  activation, and last-valid-artwork operation without host or network access.
  Keep transferred bytes distinct from physically displayed artwork.
- Frame artwork and its device protocol handle still images only. Do not add
  Membrane, video, motion, audio, or streaming infrastructure to that path.
  Assembly instruction animation is a separate Conjunct viewer capability.
- Use Elixir/OTP for host orchestration, Zig for the existing isolated raster
  worker, and a thin Swift/SwiftUI shell for macOS lifecycle and Apple APIs.
  Follow the existing Phoenix/Ash and Svelte companion-platform boundaries.
  Select MCU firmware language and tooling from exact hardware, security, and
  recovery evidence. Nerves is for a separately qualified external Pi
  appliance or bridge.
- Do not write Python in project-owned application code, firmware, scripts,
  examples, or tests. A pinned upstream firmware/system toolchain may require
  Python in an isolated reproducible build; record its version, inputs,
  license, and output, and never ship it as an application runtime.
- Frameshift reference frames contain no Raspberry Pi hardware. Separate Pi
  host targets and Raspberry Pi prior art do not authorize a rear-mounted Pi
  reference frame.
- Paper, Photo, and Pixel are independent builder choices. Prototype-first
  advice reduces risk within the chosen track; it is not a required sequence
  across frame classes. Zero visible cable is a priority, not a universal
  pass/fail rule. Describe the real power path; only bistable Paper can remain
  passive while its image stays visible.
- Follow [build-platform.md](docs/architecture/build-platform.md) and
  [conjunct-integration.md](docs/architecture/conjunct-integration.md).
  Conjunct owns generic composition, comparison, check aggregation, catalog
  projection, procedure planning, and portable instruction semantics.
  Frameshift owns frame profiles, product rules, procedures, and packs.
  Preserve the existing compiler, v1 identities, and tests until qualified
  producer exports replace each generic boundary; retained replay and
  regression support must not grow into a second generic workbench engine.
- Refpath owns generic adaptation/effects, Rivure financial operations, and
  DocShell explanatory artifacts. Transactional shop implementation is on hold.
  A printable parts/shopping list is a composition output. If optional service
  work resumes, apply its independent instructions/list and operational gates.

## Evidence and documentation

- Use the evidence vocabulary in [docs/README.md](docs/README.md). Keep research,
  candidates, references, prototypes, and exact validated configurations
  distinct. A source claim, calculation, code inspection, automated test,
  simulation, and physical measurement support different conclusions.
- Do not describe a frame or component as production-ready, proven, safe,
  compatible, or available without linked evidence at the claimed tier.
  Validation does not transfer to another revision or configuration. Missing
  external evidence does not excuse implementable refusal, simulation, or
  recovery behavior.
- Keep requirements separate from candidates. A product page, marketplace
  listing, or plausible architecture does not establish whole-system fit.
  Prices, stock, firmware support, and vendor specifications are dated
  observations; recheck them before a purchase or prototype decision.
- Physical constraints include active area, outline, total installed depth,
  connectors and cable clearance, voltage/current, thermal behavior, PSU,
  weight, mounting, service access, and passe-partout geometry.
- Write concrete technical prose. Preserve identifiers, units, measurements,
  citations, and uncertainty; remove marketing language, filler, and repeated
  conclusions. Check claims in context rather than treating word searches as
  evidence of correctness.

Put maintained content beside its owner and link new specifications from
[docs/README.md](docs/README.md). Do not create a parallel `docs/specs/` tree.

| Owner | Location |
| --- | --- |
| External evidence, experiments, and open questions | `docs/research/` |
| Cross-cutting architecture and protocol requirements | `docs/architecture/` |
| Reference-frame requirements and exact validated configurations | `docs/frames/` |
| Host behavior and platform integration | `docs/host/` |
| Shared physical constraints and candidate BOM policy | `docs/hardware/` |
| Decisions that materially constrain the product | `docs/decisions/README.md` |

## Working method and skills

- Inspect Git state first and preserve unrelated changes. Follow the requested
  deliverable: a review returns findings unless edits are authorized. Keep
  supporting notes and validation results in chat unless the task requires
  maintained repository content.
- Resolve relevant contract questions before implementing new or changed
  behavior. A narrow defect in already-defined behavior can use the existing
  contract. Keep owning specifications and verification claims aligned.
- Extend the existing owner rather than creating parallel documentation or
  generic engines. Do not add abstractions, services, plugins, caches, or
  configuration systems for hypothetical future use.
- Canonical skills live in `.agents/skills/`. Automatically select and apply
  matching skills from their descriptions as the task, changed mechanism, or
  delivery stage requires. Do not ask the user to invoke a skill or choose a
  slash command. Keep implicit invocation enabled.
- Clients without native skill discovery must inspect
  `.agents/skills/*/SKILL.md` metadata, select matching workflows, and read their
  instructions themselves. Load supporting references only when relevant.
- For Claude skill discovery, use individual ignored directory symlinks at
  `.claude/skills/<name>` targeting `../../.agents/skills/<name>`. Preserve local
  settings and unrelated entries; repair only repository-owned links. Do not
  track client settings or duplicate canonical skills.

## Validation

Run checks proportionate to the changed surface using the existing tools and
pinned toolchains in `.mise.toml`. Inspect the final diff and Markdown links.
For code, run the affected formatter, tests, static checks, and build. The
available lanes are implemented in [scripts/check](scripts/check), with
environment requirements in [README.md](README.md) and component READMEs.

`./scripts/check policy` checks repository policy, shell/CI syntax, and workspace
boundaries. `workspace.json` owns the component dependency graph, and
`./scripts/check-workspace` validates it. Use the affected application lane for
application changes; do not impose unrelated suites or install tooling merely
to validate guidance edits.

Report what actually ran and what its fixtures establish. Keep unavailable
hardware, credentialed, installed-release, or platform proof explicit; a
declaration or planned check is not a passing result.

## Git operations

- Commit only when requested. Push or rewrite remote refs only with separate
  express authorization. Never change repository visibility.
- When a user has authorized commits, use Conventional Commit subjects:
  `type(scope): imperative description`. Use a narrow scope such as `host`,
  `mac`, `renderer`, `protocol`, or `docs`.
- Accepted types are `build`, `chore`, `ci`, `docs`, `feat`, `fix`, `perf`,
  `refactor`, `revert`, `style`, and `test`. Use `!` for a breaking change.
- Check the staged diff and subject before committing. The subject must describe
  the actual change. Do not add AI attribution or co-author trailers.
- Enable the repository's commit-message hook with
  `git config core.hooksPath .githooks` in a fresh clone.
