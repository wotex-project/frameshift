# Candidate Bill of Materials

**Research snapshot:** 2026-09-22; baseline sources rechecked 2026-09-24
**Status:** candidates for independent prototypes, not a purchase list

The default manufacturer baselines for software simulation are the Waveshare
13.3-inch E6 assembly, BOE MV270QHM-N40 preliminary P1 panel, and six Waveshare
P3 64×64 modules. See the [networked simulator contract](../architecture/container-frame-simulator.md).
They are concrete candidate fixtures; none is a validated product revision.
Versioned [physical profile data](../../data/physical/README.md) now preserves
source digests, nominal values, tolerances, conflicts and explicit missing facts.
The BOE mechanical section has an unresolved model-name discrepancy; the
Paper panel drawing uses native portrait axes and layer-specific thicknesses.

This research BOM is separate from the customer's generated shopping list.
The [physical build contract](../architecture/physical-build-contract.md)
turns sourced exact revisions into configuration inputs. The composition view
produces a printable parts/list projection with unknowns and procedures in D;
optional service implementation is deferred F and currently on hold. Candidate
status cannot silently become qualified compatibility or purchasing eligibility.

The [thin-composition inventory](../research/thin-composition-evidence.md) adds
research leads and geometry gaps. It does not replace these source-pinned
candidate profiles or qualify a complete controller/driver composition. There
is no arbitrary global diagonal limit; every claimed profile must fit its
evidenced physical bounds and declared software capabilities.

Recheck availability, exact revision, interface, dimensions, license, price,
and safety documentation immediately before purchase. Builders may choose any
frame path.

## Active milestone parts packet

The [M1 tracker](../architecture/implementation-plan.md#active-milestone--macos-to-a-physical-frame)
requires one complete exact build packet before hardware testing: panel,
controller/driver, memory, power/protection, connectors/cables, carrier, mat,
backing, mount and service access, with wiring/pin maps and reproducible
flashing/recovery instructions. Maintain it with the chosen frame owner and
its [build record](validation-plan.md#build-record-layout). This is a manually
reviewed assembly record for that exact configuration; it does not depend on
Conjunct's future generic composition/list generation. The candidate tables
below remain research inputs until their individual source and received-part
gates pass; this milestone does not select or qualify a controller.

## Shared lab items

- Current-limited bench supply and inline power/current logger.
- Thermocouples or contact probes plus an ambient sensor.
- Calipers, depth gauge, scale, and straightedge.
- Logic analyser for SPI/timed-I/O/HUB75 bring-up.
- Fused test leads and correctly rated connectors.
- Neutral test images, color/palette chart, grid, single-pixel pattern, and
  worst-case all-channel power pattern.
- Non-combustible open test fixture before any wood enclosure test.

## Paper prototype candidate

| Item | Candidate | Status / gate |
| --- | --- | --- |
| Display | Waveshare 13.3-inch e-Paper HAT+ (E), E6, 1600×1200 | Candidate; verify exact revision and inspect glass/FPC on arrival |
| Development driver | Driver HAT supplied for that exact panel | Bench-only; headers/connectors are not final thickness |
| Frame controller | MCU-class Wi-Fi controller with a qualified SDK and reproducible build | **Unselected**; must pass TLS, SPI, atomic flash, sleep-power gates |
| Storage | Onboard flash or low-profile serial flash with two asset slots | Size after exact packed E6 artifact is measured |
| Power | Current-limited lab supply first; protected thin battery only after energy profile | Battery chemistry/capacity and charging remain unselected |
| Mechanics | Rigid nonconductive carrier, FPC restraint, mat, removable backing | Must protect fragile 0.85 mm panel without point load |

Evidence: [Waveshare 13.3-inch E6 manual](https://www.waveshare.com/wiki/13.3inch_e-Paper_HAT%2B_%28E%29_Manual).

### Future large Paper path

A 28.5-inch/A2-like Spectra-class panel and its vendor-approved controller are
research-only. Do not buy a bare large panel without confirmed waveform,
controller, connector, minimum order, shipping protection, and replacement
path.

## Photo prototype candidate

| Item | Candidate | Status / gate |
| --- | --- | --- |
| Donor-display path | 27-inch matte QHD monitor with external certified supply, de-cased only after electrical/mechanical inspection | Select exact locally available revision; panel substitutions are common |
| Raw-panel path | BOE MV270QHM-N40-class 27-inch QHD matte panel | Geometry evidence only; exact LVDS/backlight controller pair unqualified |
| Frame controller | Thin MCU/SoC that can retain and output one still framebuffer to exact controller | **Unselected**; 2560×1440 interface is the main risk |
| Power | Original external supply for donor prototype; later concealed low-voltage/powered-mount research | Continuous while visible |
| Mechanics | Panel carrier, mat, ventilation path, removable controller pocket | Must measure depth/heat after de-casing |

Evidence: [mirrored BOE preliminary panel data sheet](https://www.panelook.com/upload/202311/MV270QHM-N40_Rev.P1_20190125_202311014949.pdf).

Do not order a generic “compatible” LCD controller based only on size and
resolution. Connector, channel mapping, voltage, backlight driver, EDID/timing,
and panel revision must all match.

## Pixel prototype candidate

### One-module electrical mule

| Item | Candidate | Status / gate |
| --- | --- | --- |
| Panel | One Waveshare P3 64×64 HUB75E, 1/32 scan | Candidate; inspect driver IC and revision |
| Controller | Non-Raspberry DMA-capable MCU with qualified firmware tooling | **Unselected**; an STM32H7-class part is a feasibility candidate, not a recommendation |
| Logic | Voltage translation appropriate to the selected MCU and panel timing | Select after signal-integrity measurement |
| Power | Current-limited 5 V supply rated for at least one module's documented 4 A ceiling | Fuse at source; do not power through controller board |
| Fixture | Open non-combustible carrier with guarded rear electronics | Required before wood enclosure |

### Six-module A2-like mule

- Six exact-matching P3 64×64 modules arranged 3×2.
- Three parallel data chains of two modules, if the controller spike proves it.
- Fused branch distribution; connector/wire sizing from measured current.
- Hardware brightness ceiling independent of host content.
- Candidate remote higher-voltage certified supply plus local conversion only
  after loss/heat measurements; otherwise a correctly rated external 5 V
  supply close to the frame.
- Structural carrier, light leakage control, rear guard, ventilation, and
  optional diffuser/mat experiment.

The six-module nameplate ceiling is 5 V/24 A (120 W) before controller/losses.
Actual indoor art power must be measured; lower typical use does not erase the
fault/worst-case design requirement. Evidence: [Waveshare P3 specification](https://www.waveshare.com/wiki/RGB-Matrix-P3-64x64).

## Explicit exclusions

- Raspberry Pi hardware in any Frameshift reference build.
- A Linux development board hidden inside a frame as its default controller.
- An internal open-frame mains PSU inside a wooden prototype.
- Unprotected pouch cells, improvised charging circuits, or charging during an
  unattended enclosure test.
- Components selected solely from marketplace titles without primary data.
- Unpinned or non-reproducible build/flashing tools; project-owned Python code.
