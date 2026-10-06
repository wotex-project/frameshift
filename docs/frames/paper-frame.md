# Paper Frame — Reflective E-Paper Reference

**Status:** candidate prototype path; no controller selected

The Waveshare 13.3-inch E6 assembly is the default manufacturer candidate for
the [networked simulator](../architecture/container-frame-simulator.md) and
first Paper bench fixture. This selects a concrete test baseline, not a
validated controller, final enclosure, or purchase recommendation.

## Purpose

Paper is the reflective medium: ambient-light readability, a very thin display
surface, and retained artwork with the electronics fully asleep. It can be
battery-powered with no installed cable, but that is an option rather than a
universal Frameshift requirement.

## Candidate display profile

The dated prototype candidate is Waveshare's 13.3-inch E Ink Spectra 6 HAT+
(E): 1600×1200 pixels, 270.40×202.80 mm active area, 284.70×208.80×0.85 mm
panel outline, SPI, E6 full color, 19-second vendor-quoted refresh, and under
0.5 W typical panel-refresh power. Source: [vendor manual](https://www.waveshare.com/wiki/13.3inch_e-Paper_HAT%2B_%28E%29_Manual).

Those are vendor conditions, not measured Frameshift results. The glass and FPC
are fragile. The 65×30.5 mm development driver board is a bench tool; a final
thin frame needs a verified low-profile driver layout and connector strategy.

The vendor advises at least 180 seconds between refreshes, a refresh at least
every 24 hours while in use, and sleep or removal of panel power after each
refresh. The first cycling profile uses a provisional six-hour artwork dwell;
this is a product starting point, not a measured battery optimum. The frame
must wake locally for cached playlist changes while the Mac is offline.
See [display timing](../architecture/display-timing.md).

## Physical requirements

- Rigid, flat support with no point load or twisted glass.
- FPC bend and strain relief follow the panel specification.
- Display plane remains visually paper-like; no glossy protective layer unless
  testing proves the tradeoff acceptable.
- Electronics and battery sit in distributed or edge pockets, not a central
  computer-shaped bulge.
- Backing is removable without peeling or flexing the panel.
- Temperature range is enforced; the candidate is specified for 0–40 °C use.

## Electronics

The reference direction is a sleeping MCU-class controller with a qualified
firmware toolchain, Wi-Fi, mutual TLS, secure identity, flash for two assets and
recoverable firmware, SPI, a real-time wake source, and switchable display rail.
No exact part is selected until the toolchain and whole-device power gates pass.

The driver owns panel initialization, busy timing, waveform/update sequence,
power sequencing, and recovery after interrupted refresh. Vendor sample sources
are protocol evidence only; they do not determine the project language stack.

## Wake/update cycle

1. Wake on RTC or physical button.
2. Read battery/temperature and abort safely if outside limits.
3. Associate to Wi-Fi and authenticate the paired host/outbox.
4. Compare desired digest with locally verified current/desired state.
5. Download into an inactive slot only when different.
6. Verify length, profile, dimensions, palette revision, and SHA-256.
7. Refresh the panel and wait for its busy/complete condition.
8. Atomically mark current only after success.
9. Acknowledge outcome and return radio, panel rail, and MCU to deep sleep.

If any stage fails, the panel keeps its existing physical image and the frame
backs off before a later wake. Reboot alone does not force a refresh.

## Artifact profile

The Mac sends an exact indexed/panel-packed still profile negotiated by
capability. The inspected 13.3-inch E6 driver uses **1200×1600 native portrait**;
1600×1200 landscape requires an explicit orientation transform and a separately
qualified profile. Palette entries, hardware wire codes, bit packing, row order,
split-controller layout and conversion-profile revision are mandatory. A PNG
preview is not necessarily the panel wire artifact.

The [pinned controller-source inspection](../research/hardware-platforms.md#integrated-esp32-s3-controller-exact-source-findings)
defines a source-based 960,000-byte, high-nibble-first row-major candidate layout.
Each controller consumes its 300-byte slice from every 600-byte row. It also
identifies unbounded BUSY waits, swallowed transfer errors and missing OTA slots
in the sample. The physical adapter must propagate transfer failure, bound
completion and power sequencing, and refuse a displayed/current acknowledgement
until exact hardware completion is established. The host's
[closed indexed4 software profile](../architecture/content-pipeline.md#closed-indexed4-software-profile)
can be tested independently; it does not qualify pigments or received hardware.

Host rendering performs crop, color conversion, palette mapping, and dithering.
The frame validates and transfers bytes; it does not reinterpret the artwork.

## Power qualification

Measure the complete frame, not the MCU data sheet:

- regulator/battery-monitor quiescent current;
- deep sleep with radio and panel rail off;
- cold boot and Wi-Fi association;
- no-change outbox check;
- full asset transfer;
- complete panel refresh at low/room/high allowed temperature;
- retry and unreachable-host behavior;
- battery self-discharge and storage.

Only then calculate expected update count and calendar life for a named battery.

## Required prototype evidence

- exact color/palette test chart photographed under controlled light;
- full refresh time and energy at three temperatures;
- visible flash behavior and acceptable default dwell;
- 100 interrupted-power trials across download/refresh/metadata boundaries;
- sleep current over at least 24 hours;
- assembled depth map, mass, FPC stress inspection, and drop/handling notes;
- retained image after complete battery removal;
- one successful and one rolled-back signed firmware update.

## Future A2-like path

28.5-inch Spectra-class displays remain a separate sourcing exercise. The
software profile can scale, but the large panel is blocked on exact controller,
waveform, price, shipping, minimum order, replacement, and mechanical evidence.
