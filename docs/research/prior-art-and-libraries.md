# Prior Art and Library Survey

**Research date:** 2026-09-22

**Policy:** borrow architecture lessons, not source, until license and fit are
recorded. Projects with a forbidden runtime may still be evidence about
hardware behavior but cannot enter the Frameshift stack.

## Relevant projects

| Project | Useful lesson | Boundary |
| --- | --- | --- |
| [Openframe](https://docs.openframe.io/) | Separate an artwork/control service from a Raspberry Pi display controller; commodity HDMI displays are a practical prototype. | Old architecture and dependencies; inspiration only. |
| [Tidbyt Pixlet](https://github.com/tidbyt/pixlet) | Render on the capable host and push a constrained display artifact. | Its Starlark runtime and animation focus are not adopted. |
| [TRMNL firmware/BYOD](https://docs.trmnl.com/go/diy/byod-s) | A thin e-paper client can fetch a prepared image, retain it, and work with a self-hosted server. | Its firmware and image toolchain are not Frameshift dependencies. |
| [HUB75 Pixel Art Display](https://github.com/mzashh/HUB75-Pixel-Art-Display) | Local flash, a simple upload UI, brightness control, and panel-specific configuration are proven ESP32 patterns. | Arduino/ESP32 application is not reused; project is MIT, but provenance is still required for any copied code. |
| [`rpi-rgb-led-matrix`](https://github.com/hzeller/rpi-rgb-led-matrix) | Panel mappings, scan modes, color-depth/refresh tradeoffs, and parallel chains document mature HUB75 constraints. | Research oracle only. Raspberry Pi hardware and the C++ driver are not the Frameshift architecture. |
| [ESP32 HUB75 DMA](https://github.com/mrcodetastic/ESP32-HUB75-MatrixPanel-DMA) | DMA buffer size, driver-chip variance, PSRAM bandwidth, and Wi-Fi interference are real validation risks. | C++/Arduino implementation is research evidence, not a stack choice. |
| [STM32 HUB75 driver](https://github.com/kostaman/HUB75) | Two chained 64×64 HUB75E panels on an STM32 are useful timing and mapping feasibility evidence. | GPL-3.0 C++/HAL research oracle only; not approved for copying or adoption. |
| [MicroZig](https://github.com/ZigEmbeddedGroup/microzig) | Active Zig embedded toolbox with some STM32 support. | Its API is explicitly in development; exact chip, DMA, network, TLS, flashing, and recovery support must be proven. |
| [MediaGenerationKit](https://github.com/drawthingsai/media-generation-kit) | Native local/cloud still-image generation behind one Swift API. | LGPL-3.0 obligations and model licenses must be reviewed. |
| [CodexBar](https://github.com/steipete/CodexBar/tree/6a26b2e9b1b60471970deb6fe663f9e5f284e2ce) | Idempotent native cleanup, explicit task ownership and a small updater UI boundary. | MIT; source/test inspection on 2026-10-06, not copied or qualified here. Official Swift/Apple/Sparkle guidance owns requirements; custom window/Dock behavior is not adopted. |
| [agent-scripts Mac release helper](https://github.com/steipete/agent-scripts/tree/79150cfac4a6ba4df13cf30176bf2db85170ae6c/skills/release-mac-app) | Thin entry point with an explicit function-library owner, scoped credential commands and retained partial-publication state. | MIT; shared personal Bash automation with credential, runtime, keychain and Git assumptions. Research only; not a Frameshift dependency. |

The [2026-10-06 native lifecycle and wrapper review](software-stack.md#native-shell-lifecycle-practices)
records exact source revisions, official guidance, implementation gaps and the
bounded H3 follow-through. The earlier hardware survey's date is unchanged.

## Patterns adopted

1. **Prepared assets, not live rendering.** The host creates exactly what the
   panel needs; the device validates, stores, and swaps it.
2. **Last valid image is sacred.** Network, host, provider, update, and decoder
   failures leave the current artwork intact.
3. **Panel revision is data.** HUB75 scan mode, e-paper waveform/controller, and
   LCD controller pairing are recorded per hardware revision, never guessed
   from marketing size.
4. **Brightness is a power control.** Pixel-frame brightness limits are part of
   the electrical envelope and capability profile, not merely a visual slider.
5. **A constrained artifact is testable.** Golden images can verify crop,
   palette, dithering, orientation, and exact output bytes without hardware.
6. **Self-hosting is an architectural property.** A device remains usable when
   the vendor or project server is absent.

## Patterns rejected

- Browser-hosted configuration as the primary product UI.
- Provider-specific or model-specific fields leaking into frame firmware.
- Continuous image streams for a still-art product.
- Pulling untrusted arbitrary URLs from the frame.
- Shipping Wi-Fi credentials in source or firmware images.
- Treating community-reported panel compatibility as proof for a purchased
  revision.
- Adding a language runtime because a useful upstream demo happens to use it.

## License intake checklist

Before code or assets are copied, record:

- upstream URL, immutable commit/tag, and retrieval date;
- license file and copyright notices at that revision;
- exact files or concepts used;
- modifications and generated artifacts;
- source-distribution, relinking, attribution, and patent obligations;
- whether the dependency is linked, executed as a separate process, or used
  only as a development oracle.

No repository surveyed here has yet been approved for source copying.
