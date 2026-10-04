# Thin compositions and geometry evidence

**Updated:** 2026-10-04. **Status:** technical research inventory, not validated hardware or live supply qualification.

This inventory was reviewed against the current sourced profiles. Good Display
GDEP133C02, E Ink EL253EW1 and Waveshare's 64×64 family pages were rechecked;
the [dated findings and conflicts](conjunct-adoption.md#hardware-source-checks-and-remaining-experiments)
record the exact scope. The other rows retain their earlier source evidence.
No new CAD or hardware was acquired; denied wiki requests and gated downloads
are not successful refreshes or obtained assets.
Use [CI-05–CI-07](../architecture/conjunct-integration.md) for consumer evidence
and geometry/procedure requirements. The existing candidate data remains at its
recorded evidence tier.

## Selection contract

There is no arbitrary target diagonal, aspect ratio or universal size limit. The complete installed object must remain thin: panel, controller/driver, storage, power conversion or battery, connectors, cable/FPC bend envelopes, backing, mounting, ventilation and service access. A thin display with a Raspberry Pi, mini-PC or bulky monitor controller attached to the back does not satisfy the concept.

Research whole compositions rather than standalone displays. Keep exact panel, driver/controller, waveform/scan mode, firmware and renderer profile together when qualifying a revision. Marketplace similarity, identical outline dimensions or a hobby library does not establish interchangeability.

The candidates below preserve the manufacturer sources and previous search results. No new part was received, measured or tested in this task. Links are discovery locators, not retained licensed CAD assets. Previously reported dimensions are not a completed source-to-claim import. Before adding an authoritative profile, retain exact document revision, page/feature locator, content digest, rights and assessment through the physical contract.

## Evidence dimensions

Retain the existing product evidence vocabulary: E0 discovery/community/listing, E1 primary technical source, E2 exact received revision, E3 Frameshift tests and E4 repeated-unit/lot evidence. These candidates have no new E2–E4 evidence from this task. A mirrored manufacturer datasheet must retain both original issuer and mirror provenance and be authenticated before relying on its claimed revision.

Geometry evidence is separate:

| Grade | Meaning |
| --- | --- |
| G0 | Marketing dimensions only |
| G1 | Outline plus relevant active/functional area |
| G2 | Dimensioned mechanical drawing |
| G3 | Relevant connector/FPC/mount/keep-out geometry also covered |
| G4 | Obtained manufacturer 2D CAD of the applicable revision |
| G5 | Obtained manufacturer 3D CAD of the applicable revision |

Do not assign G4/G5 because a page says CAD exists. Physical measurement is another record, not automatically supplied by CAD. Even G3 can be incomplete for a particular installation if connector protrusions or cable/tool access are missing.

## Paper panel families

| Candidate | Previously sourced technical facts | Source and geometry follow-up |
| --- | --- | --- |
| Waveshare 13.3-inch Spectra 6 panel/HAT reference | 1600×1200; raw panel reported 284.70×208.80×0.85 mm; active area 270.40×202.80 mm | [Manufacturer manual](https://www.waveshare.com/wiki/13.3inch_e-Paper_HAT%2B_%28E%29_Manual). Dimensioned panel/FPC/stiffener/protrusion drawing is the important source; development HAT thickness is not a final low-profile design. Retain the exact drawing before G2/G3 admission. |
| Good Display GDEP133C02 | 13.3-inch Spectra 6, 1600×1200, 60-pin/QSPI; outline 208.8×284.7×0.85 mm and active area 202.8×270.4 mm reported in opposite orientation | [Manufacturer page](https://www.good-display.com/product/559.html). Obtain applicable panel and driver-board specifications/schematics. Similar geometry to Waveshare does not establish matching waveform, controller, pinout or revision. |
| E Ink EL073TF1U5 | 7.3-inch Spectra 6, 800×480; reported outline 170.2×111.2×0.9 mm, active 160×96 mm | [Manufacturer page](https://www.eink.com/product/detail/EL073TF1U5). G1-type data is available as a lead; connector, flex and complete drive/power design still required. |
| E Ink EL253EW1 | 25.3-inch Spectra 6, 3200×1800; active 560×315 mm; outline 576.5×333×0.85 mm; glass/anti-glare and reported mass 385±15 g | [Manufacturer page](https://www.eink.com/product/detail/EL253EW1). Exact mechanical file, waveform/controller path, fragility/mounting and power envelope are open. The 0.85 mm figure is raw panel, not installed depth. |

These are examples across sizes, not the allowed size catalogue. Extend the family with actual documented reflective colour panels from E Ink, Good Display, Waveshare and qualified integrators. Investigate current full-colour technologies without silently treating monochrome, three-colour and full-colour panels as equivalent artwork products.

### Paper composition concepts

**P-01 — Small externally powered reflective frame.** Exact small colour panel + manufacturer-qualified drive/controller/waveform path + custom low-profile networking/storage controller + protected low-voltage input. Render on the host; transmit a qualified artifact; retain a durable last accepted asset and safe refresh/recovery state. Driver board, FPC fold and power conversion usually determine electronics depth; measure them.

**P-02 — Small battery/sleep variant.** P-01 plus an exact thin battery, protection, charging and power-gating design. Battery thickness, swelling/clearance, safe charging and the refresh energy budget are part of the composition. No battery lifetime or zero-consumption claim is accepted from an e-paper marketing statement alone. Networking wake/sleep and brownout during refresh need tests.

**P-03 — 13.3-inch raw-panel family.** Waveshare/Good Display candidate + exact approved panel-driving design + custom flat PCB placed in a perimeter/backing pocket instead of a stacked HAT. Match panel/controller/power/raster layout as one qualified revision. Do not claim that a generic SPI MCU can directly replace the required controller/PMIC/waveform implementation.

**P-04 — Large reflective frame.** EL253EW1 or another sourced large panel + its actual qualified controller and power design + mechanically supported glass panel. A shared networking/storage architecture may be reusable, but panel drive, refresh buffering, FPC and mounting may differ. Larger area does not justify an invented maximum diagonal or an assumed identical small-panel PCB.

For all four, obtain driver schematics, waveform access/usage permission, controller firmware/programming details, temperature behavior, required update interval, refresh peak current and interrupted-refresh recovery evidence. Paper may sleep between updates; exact measured whole-system energy remains a separate result.

## Photo panel families

The following are retained discovery leads. Some data came from mirrored manufacturer documents or secondary catalogues; they are not current manufacturer supply or complete-controller validation.

| Candidate | Retained facts | Source/uncertainty |
| --- | --- | --- |
| BOE MV270QHM-N40, preliminary P1-class reference | 27-inch QHD 2560×1440; active 596.736×335.664 mm; reported LCM outline approximately 608.8×355.3×9.3 mm | [Mirrored datasheet](https://285624.selcdn.ru/syms1/iblock/a5c/a5c33ffd75b646e208b55ce7cbae3c90/52a42f9344cc9b70dc535175a80e7d11.pdf). Confirm issuer/revision, interface and power/backlight requirements with an authorized source. |
| LG Display LM270WQA-SSA2 | 27-inch QHD family; active 596.736×335.664 mm; drawing reported approximately 608.8×355.1 mm outline | [Mirrored manufacturer specification](https://www.panelook.com/upload/202107/LM270WQA-SSA2_Ver1.0_20200513_202107296844.pdf). A reference to manufacturer 3D data does not mean the STEP was obtained. Thickness map, interface and exact revision remain to qualify. |
| Innolux M270KCJ-K7B Rev.B1 family | Similar reported 608.8×355.13 mm outline and active 596.736×335.664 mm | [Secondary catalogue](https://www.panelook.com/M270KCJ-K7B%20Rev.B1_Innolux_27.0_LCM_parameter_59831.html). Variant/interface, including V-by-One possibilities, prevents treating it as a generic eDP/LVDS substitute. |

Search BOE, LG Display, Innolux, AUO and documented industrial/display-module channels across small, medium, large and unusual aspect ratios. The desired family is a thin high-quality matte/anti-glare LCM with exact mechanical and electrical evidence, not simply anything marketed as IPS or 27-inch QHD. OLED or other technologies need their own still-image, lifetime, optical and power assessment rather than automatic inclusion.

### Photo composition concepts

**F-01 — Native MCU/SoC display-interface path.** A small documented panel whose actual MIPI-DSI/RGB interface and throughput match an appropriate thin controller, framebuffer memory and display timing implementation. Select silicon from exact interface/bandwidth requirements; do not begin with a preferred development board. External low-voltage supply and flat PCB routing are part of the mechanical model.

**F-02 — Low-profile bridge/TCON path.** Exact eDP/LVDS panel + compatible bridge/TCON/scanout source + sufficient framebuffer and bandwidth + minimal network/storage controller. A bridge only translates a supported signal; it does not automatically create a framebuffer or the required panel timing. Backlight power/dimming and startup/shutdown sequences need separate evidence.

**F-03 — FPGA/ASIC scanout path.** Exact larger/high-resolution panel + framebuffer/scanout FPGA or other suitable dedicated source + qualified interface bridge where needed + network/storage MCU. High-frequency memory routing, pinout, PCB layers, EMI, power and thermal behavior must fit the thin envelope. This is an engineering candidate, not a validated no-Linux implementation.

**F-04 — Existing documented flat controller integration.** Use a genuinely documented controller design that meets the interface, boot, storage, protocol and complete-depth requirements. A random HDMI board or monitor chassis is not eligible merely because it lights the panel. Native connectors and cable routing often dominate installed depth.

Photo continuously scans the image and generally powers the backlight. Still-image application semantics do not eliminate pixel-clock, memory-bandwidth or thermal requirements. Calculate storage from exact resolution and artifact format, include double-buffer/atomic activation requirements, and measure concurrent network/refresh behavior. No theoretical MCU maximum becomes a qualified whole-system result.

## Pixel module families

| Candidate | Retained manufacturer facts | Source and mechanical gap |
| --- | --- | --- |
| Waveshare RGB-Matrix-P3-64x64 | 192×192 mm, 64×64, 3 mm pitch, HUB75E, 1/32 scan, 5 V/4 A maximum and ≤20 W in the vendor description | [Documentation and 2D drawing resource](https://www.waveshare.com/wiki/RGB-Matrix-P3-64x64). Rear components, connector insertion and power distribution remain part of installed depth. |
| Waveshare RGB-Matrix-P2-64x64 | 128×128 mm, 64×64, 2 mm pitch, 1/32 scan; reported 5 V/3 A/15 W maximum | [Product page](https://www.waveshare.com/product/rgb-matrix-p2-64x64.htm). Distinguish ordinary and GOB/B variant; do not transfer coating/mechanical claims across SKUs. |
| Waveshare P2.5 64×64 family | 160×160 mm from 2.5 mm pitch; reported 5 V/4 A/20 W family limits | [64×64 family documentation](https://docs.waveshare.com/RGB-Matrix-Px-64x64). Obtain exact SKU scan/driver/mechanical data before use. |
| Waveshare GOB and flexible variants | Coating/flexible construction may change protection, optics, mounting and repair behavior | [Family documentation](https://docs.waveshare.com/RGB-Matrix-Px-64x64). A protective coating is not blanket evidence of thermal suitability, reparability or identical controller behavior. |
| Other 64×32 and fine-pitch modules | Candidate alternate geometries and scan architectures | [64×32 documentation](https://docs.waveshare.com/RGB-Matrix-Px-64x32). Exact module/driver/revision must be identified; no generic family thickness assumed. |

Search beyond Waveshare among documented indoor LED/GOB/COB module manufacturers. Preserve HUB75 versus proprietary receiver/scan interfaces as different capability classes. No concrete additional manufacturer's module was qualified in this research.

### Pixel composition concepts

**X-01 — Small direct MCU/DMA scan.** Exact HUB75 module + compatible deterministic scan implementation, level shifting, framebuffer memory, protected low-voltage distribution and minimal networking/storage. ESP32-S3/P4 or STM32H7-class candidates require exact scan/driver/library and simultaneous networking tests. Their presence in hobby examples is insufficient evidence.

**X-02 — Larger array with dedicated scan helper.** Multiple exact modules + FPGA/CPLD or dedicated receiver/scan hardware + separate network/storage controller. Split deterministic scan from network load where required. Preserve panel count, scan multiplexing, PWM bit depth, brightness/refresh limits and power-injection topology as composition constraints.

**X-03 — Low-profile coated/flexible assembly.** A qualified GOB/COB or flexible module + its actual controller and support method. Curvature and adhesive/backing, repair access and thermal requirements are additional facts, not automatic advantages. A flexible module does not justify forcing an unqualified radius.

RP2350 silicon can be investigated separately from Raspberry Pi SBCs, but adoption requires explicit interpretation of the project's no-Pi policy and technical qualification. It is not selected by this document. No controller family is blessed without memory, timing, security, firmware/recovery and geometry evidence.

Pixel requires continuous refresh and power. Calculate worst-case rail current, branch protection, wire/connector loading, copper losses and thermal dissipation for the actual array. Large configurations remain possible only within evidenced limits; do not hide an unsafe or unmodeled power system behind a configurable tile count.

## Shared controller and power requirements

Custom low-profile PCB/component-level designs are preferred over stacked development boards for final thinness. Identify the exact MCU/SoC/module, flash/memory, secure boot/storage requirements, antenna keep-out, clocking, power conversion, FPC/board connectors and firmware ownership. Preserve signed/authenticated network admission, durable asset storage, atomic activation, recovery and capability reporting. Do not add unnecessary frame-side rendering or a cloud dependency.

Power options include an external appropriately qualified mains supply with low-voltage ingress, a documented internal converter where safe/necessary, and optional protected battery designs for suitable Paper profiles. An external supply may reduce in-frame heat and depth; it does not qualify the whole system automatically. Connector orientation and strain relief must be represented in geometry.

Supplier/manufacturer names for investigation include Espressif and ST for controllers, Texas Instruments and other actual device vendors for interface/power/reference designs, plus documented connector and memory vendors. Exact MPNs and complete schematics remain open where not listed above. Do not fill the missing BOM with imagined parts.

## Geometry asset and instruction pipeline

For each proposed composition collect outline, active area, thickness/protrusion map, mounting/fastener details, connector position/mating direction, FPC shape/stiffener/bend radius, cable length/route, antenna and thermal keep-outs, tool/service access, PCB/battery dimensions and backing/mounting clearances.

Retain the source CAD/drawing when permitted, semantic feature IDs, canonical coordinates/units/tolerances, converter version/options and loss report. Produce a collision/clearance model separately from a simplified browser GLB. Source-to-feature traceability is required before dimensionally authoritative output.

The visual procedure binds the exact CompositionSpec/BuildSpec, part revisions, approved operations, tool/skill conditions, safety instructions and verification steps. Exploded views, connector highlighting and camera paths cannot invent hidden geometry or substitute for required physical measurement. DocShell supplies explanatory artifacts, while Conjunct owns generic procedure/scene semantics and Frameshift owns its specific content.

## Qualification packet and next technical work

For every candidate record composition ID, exact manufacturer/MPN/revision, class, active area/resolution/pitch, source dimensions, interface, driver/controller revision, network/storage, power modes, actual installed depth and its limiting feature, geometry grade, product evidence state and unresolved facts. Unknown total depth remains unknown rather than panel thickness plus a guessed constant.

Obtain datasheets, applicable mechanical drawing, source CAD and permitted derivative rights, interface/pinout, FPC/connector drawings, reference schematic, waveform/driver requirements, firmware and programming procedure, electrical/thermal limits, approved substitutions, lifecycle/PCN/EOL and test methods. Commercial terms and partner financing are outside this technical corpus.

Then import one exact Paper, Photo and Pixel path into the same physical contract; include unknown and deliberately incompatible combinations. Receive the selected revisions, measure full stack-up, run electrical/optical/thermal/mounting and interrupted-update tests, and retain actual results. Only then advance the relevant evidence state. A simulator, primary datasheet or attractive wireframe alone does not make a composition validated.
