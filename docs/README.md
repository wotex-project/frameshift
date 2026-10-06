# Frameshift Documentation

Frameshift uses specification-driven development. Requirements describe the
complete product independently of implementation maturity. Decisions, research,
implementation status and physical validation remain separate.

This corpus contains code/architecture, product structure, technical research
and evidence. Company strategy, monetization, prospective commercial terms and
legal interpretation belong outside the product repository. Technical service
contracts consume approved external policy and financial interfaces; they do
not select a business model.

Requirements remain in force until an explicit decision changes them. Vendors
and revisions are concrete capability instances, never hard-coded protocol
branches. Complete installed thinness matters; there is no arbitrary global
display-size limit.

## Ownership and build sequence

Conjunct owns the generic physical kernel and instruction semantics:
validation, canonical composition, comparison, purpose-bound reports, parts
projection, procedure planning and portable text/print/offline output.
Frameshift supplies frame profiles, mandatory rules, approved steps, content,
the product UI/storage adapters and its independent native artwork/device path.
Refpath owns optional operator generations and effects. The retained v1
BuildSpec compiler is for replay, regression and migration until qualified
Conjunct exports and consumer tests replace each generic boundary.

The [implementation plan](architecture/implementation-plan.md) orders the
contract foundation, host boundaries, Conjunct frame profile and workbench,
generality/operator integration and deferred optional services. The
[verification map](architecture/verification.md) records what has actually
passed. Missing producer exports leave the dependent profile unavailable;
they do not stop independent native, host or frame-profile work.

## Decisions

- [Decision ledger](decisions/README.md)

## Architecture and protocol

- [Product definition and completion contract](product-definition.md)
- [System architecture](architecture/system.md)
- [Composition workbench, Conjunct boundaries and dependency gates](architecture/build-platform.md)
- [Conjunct integration, identity migration and product ownership](architecture/conjunct-integration.md)
- [Required library deliveries and producer/consumer tests](architecture/producer-contracts.md)
- [Physical BuildSpec, compatibility and formal verification](architecture/physical-build-contract.md)
- [Build artifact layouts and storage footprint](architecture/build-artifacts.md)
- [Frameshift packs, research orchestration and model qualification](architecture/build-orchestration.md)
- [Optional service, purchasing and care integration — on hold](architecture/build-commerce.md)
- [Portable host core](architecture/host-core.md)
- [Library backup, verification and offline restore](architecture/library-backup.md)
- [Host domain map](architecture/domain-map.md)
- [Host diagnostics contract](architecture/diagnostics.md)
- [Frame Protocol](architecture/frame-protocol.md)
- [Networked frame simulator and manufacturer baselines](architecture/container-frame-simulator.md)
- [Capability model](architecture/capabilities.md)
- [Display timing and pinned artwork loops](architecture/display-timing.md)
- [Content pipeline](architecture/content-pipeline.md)
- [Qualified render and transfer generations](architecture/qualified-generations.md)
- [Installation and interactive guide](architecture/install-and-guide.md)
- [Release artifact manifest](architecture/release-manifest.md)
- [Browser guide simulation](architecture/guide-simulation.md)
- [Shared Gleam decision kernel](architecture/shared-decision-kernel.md)
- [Implementation plan](architecture/implementation-plan.md)
- [Software verification map](architecture/verification.md)

## Host

- [macOS controller](host/macos.md)
- [Browser guide handoff](host/guide-handoff.md)
- [Linux and Raspberry Pi hosts](host/linux.md)
- [Menu-bar interface](host/menu-bar-interface.md)

## Reference frames

- [Paper Frame — reflective e-paper](frames/paper-frame.md)
- [Photo Frame — matte IPS](frames/photo-frame.md)
- [Pixel Frame — HUB75 RGB matrix](frames/pixel-frame.md)

## Hardware

- [Hardware principles](hardware/principles.md)
- [Candidate BOM](hardware/bom.md)
- [Validation plan](hardware/validation-plan.md)
- [Thin composition families, source drawings and geometry gaps](research/thin-composition-evidence.md)

## Research

- [Consolidated composition research, current producer exports and specification plan](research/conjunct-adoption.md)
- [Hardware platforms and power feasibility](research/hardware-platforms.md)
- [Software stack](research/software-stack.md)
- [Release tooling language research](research/software-stack.md#release-tooling-language-boundary)
  and [migration sequence](architecture/implementation-plan.md#release-tooling-migration)
- [Technical build decisions, producer seams and model qualification](research/build-platform-decisions.md)
- [SQLite and Elixir boundary](research/sqlite-elixir-boundary.md)
- [Embedded persistence review](research/embedded-persistence.md)
- [Host diagnostics research](research/host-diagnostics.md)
- [AI image generation](research/ai-image-generation.md)
- [Protocol foundations](research/protocol-foundations.md)
- [Prior art and libraries](research/prior-art-and-libraries.md)
- [Display technologies](research/display-technologies.md)
- [Open questions](research/open-questions.md)

## Evidence vocabulary

- **Specified:** required by the product contract, not automatically implemented.
- **Research:** evidence for a direction is being investigated.
- **Candidate:** evidence suggests a fit, but a required check is missing.
- **Validated:** an exact revision passed a named recorded test.
- **Reference:** an interoperable implementation target, not a fixed product SKU.
- **Prototype:** a build intended to invalidate assumptions.

Geometry documentation levels and product/received-hardware evidence are
separate. A linked drawing is not a received part; a mesh is not fit proof; a
passed software test is not a safety certificate.

Software completion and external activation/release evidence are separate.
Missing external evidence cannot justify omitting implementable refusal,
simulation or recovery paths. A document or v1 preview does not demonstrate
producer integration.
