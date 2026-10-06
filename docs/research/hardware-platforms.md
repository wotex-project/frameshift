# Hardware Platform Research

**Research date:** 2026-10-06; controller source inspection supplements the candidate survey

**Hard constraints:** the reference object is a thin picture frame, not a
computer enclosure, and Raspberry Pi hardware is excluded. No visible
cable is a high-priority industrial-design goal, not a pass/fail requirement.

## Power feasibility

“No cable,” “no visible cable,” and “passive” are different requirements.

| Frame | Image with electronics off | Battery-only practicality | Continuous input power | Honest classification |
| --- | --- | --- | --- | --- |
| Paper / e-paper | Yes | Strong candidate | Only while waking and refreshing | Cable-free, passive between changes |
| Photo / IPS | No; backlight and timing controller stop | Poor for wall art | Required whenever visible | Thin emissive, concealed power |
| Pixel / HUB75 | No; LEDs stop immediately | Impractical at A2-like size | Required whenever visible | Thin emissive, high-current concealed power |

The Paper frame can be truly cable-free with a battery. Photo and Pixel can
have **no visible cable** only when the installation supplies hidden power—an
in-wall low-voltage feed, a powered mounting rail/contact plate, or a cable
concealed by the wall/frame. Wireless power does not make them passive; it adds
conversion loss, alignment constraints, and heat.

If cable-free passive operation were ever made mandatory for every Frameshift
product, Photo and Pixel would need to be removed or reinterpreted with
bistable reflective technology. It is not currently mandatory.

## Mechanical budget

Component thickness alone is not installed depth. Each prototype record must
include panel, controller, connector height, cable exit and bend radius,
battery, converter, backing, mounting clearance, airflow, and wood rebate.

Initial targets are measurement hypotheses, not guarantees:

| Frame | Display-plane target | Local electronics pocket | PSU location |
| --- | --- | --- | --- |
| Paper | panel + support under 4 mm | under 10 mm in a localized rear pocket | thin battery in rear pocket |
| Photo | raw panel under 15 mm | under 12 mm beyond panel, placed behind mat/rebate | external or wall-contact supply |
| Pixel | module depth to be measured | controller under 8 mm; airflow separate | remote 24 V-class supply plus local conversion candidate |

The final outside depth follows measurement. A reference fails if it meets the
electronics target only with unsafe cable bends, exposed boards, trapped heat,
or a bulky box attached to the center of the backing.

## Paper candidate

### Display

The strongest currently documented prototype is Waveshare's 13.3-inch E Ink
Spectra 6 HAT+ (E):

- 1600×1200, E6 full color;
- 270.40×202.80 mm active area;
- 284.70×208.80×0.85 mm panel outline;
- 65.00×30.50 mm development driver board;
- SPI mode 0, 3.3/5 V;
- vendor-quoted 19 s full refresh and under 0.5 W typical panel refresh;
- 0–40 °C operation.

Source: [Waveshare manual](https://www.waveshare.com/wiki/13.3inch_e-Paper_HAT%2B_%28E%29_Manual).

The 0.85 mm panel supports a thin object, but the HAT is development hardware,
not a final mechanical answer. Its stacking headers, connectors, and cable
orientation must be replaced by a low-profile driver PCB only after the vendor
schematic and panel protocol are verified.

### Controller and energy strategy

The controller must be MCU-class and power-gated:

1. RTC/button wakes the controller.
2. Radio associates and authenticates.
3. The frame asks the paired host/outbox for its desired digest.
4. If unchanged, it records health and returns to deep sleep.
5. If changed, it downloads to an inactive flash slot, verifies digest and
   format, refreshes the panel, marks current, and sleeps.

An ESP32-S3-class chip demonstrates the relevant scale: Espressif documents
single-digit-microamp chip deep sleep with RTC memory configurations, although
module PSRAM, regulators, flash, battery monitor, and development-board LEDs can
raise whole-board sleep current dramatically. Source: [ESP32-S3 datasheet](https://documentation.espressif.com/esp32_s3_datasheet_en.pdf).

That is evidence for the power class, not a selected controller. Selection is
blocked on a pinned reproducible firmware build plus Wi-Fi, mTLS,
secure identity, SPI throughput, and measured whole-board sleep current.

The panel-only refresh claim corresponds to less than 0.003 Wh at 0.5 W for
19 seconds, but it excludes controller, driver losses, radio association,
battery conversion, retries, and temperature effects. Battery life must be
calculated from measurements of the entire frame over a real wake/update/sleep
cycle. No months-of-life claim is allowed before that test.

### Integrated ESP32-S3 controller: exact source findings

The integrated **ESP32-S3-ePaper-13.3E6, SKU 34349** is a separate controller
candidate from the 65×30.5 mm HAT driver. Its [manufacturer page](https://docs.waveshare.com/ESP32-S3-ePaper-13.3E6)
contradicts itself: the introduction specifies WROOM-2-N32R16V, 32 MB flash and
16 MB PSRAM; the onboard-resources list specifies WROOM-1-N16R8, 16 MB flash and
8 MB PSRAM. The [schematic](https://files.waveshare.com/wiki/ESP32-S3-ePaper-13.3E6/ESP32-S3-ePaper-Driver-Board.pdf),
page 1, labels U2 WROOM-2-N32R16V. That supports the first description for the
drawn design, but does not identify a received board. Photograph its markings,
record board revision, probe flash/PSRAM, and measure the complete connector,
cable, power and backing envelope before admitting a configuration.

The following findings come from the vendor repository at commit
[`f8e9456bd1ca520f638786142fc17a74154f4e05`](https://github.com/waveshareteam/ESP32-S3-ePaper-13.3E6/tree/f8e9456bd1ca520f638786142fc17a74154f4e05),
retrieved with `gh` on 2026-10-06. They are code inspection, not measured
interoperability. The reviewed ESP-IDF example is `04_E-Paper_Example` under
`example/ESP-IDF-5.5.1`.

| Boundary | Inspected behavior | Frameshift consequence |
| --- | --- | --- |
| Native raster | [Header](https://github.com/waveshareteam/ESP32-S3-ePaper-13.3E6/blob/f8e9456bd1ca520f638786142fc17a74154f4e05/example/ESP-IDF-5.5.1/04_E-Paper_Example/components/epaper_port/epaper_port.h) declares 1200×1600 and pigment codes black 0, white 1, yellow 2, red 3, blue 5, green 6 | Landscape 1600×1200 is an orientation of the panel, not this native memory layout. Palette position is not the hardware code: code 4 is absent. Preview RGB values need their own measured conversion revision. |
| Pixel packing | [GUI writer](https://github.com/waveshareteam/ESP32-S3-ePaper-13.3E6/blob/f8e9456bd1ca520f638786142fc17a74154f4e05/example/ESP-IDF-5.5.1/04_E-Paper_Example/components/epaper_src/GUI_Paint.c), `Paint_SetPixel`, writes even X in the high nibble, odd X in the low nibble | One native row is 1200/2 = 600 bytes; 1600 rows occupy 960,000 bytes. No header or compressed image enters the panel stream. |
| Controller routing | [Display driver](https://github.com/waveshareteam/ESP32-S3-ePaper-13.3E6/blob/f8e9456bd1ca520f638786142fc17a74154f4e05/example/ESP-IDF-5.5.1/04_E-Paper_Example/components/epaper_port/epaper_port.c), `EPD_Display`, sends the first 300 bytes of each row to M and the next 300 to S | Each controller receives 480,000 bytes. Splitting the artifact into two contiguous halves would produce different bytes. Confirm physical axes/controller placement with a labelled chart and logic trace. The sample's resolution-register values alone do not resolve that mapping. |
| Electrical interface | Driver defines SPI3, mode 0, 10 MHz, CLK 9, MOSI 46, CS M 10, CS S 3, DC 11, reset 2, BUSY 12, power 1 | Freeze this pin map only for the inspected design. GPIO3 and GPIO46 are strapping pins; verify ROM recovery with the connected panel. GPIO46 is output-capable on ESP32-S3, as documented by its [GPIO reference](https://docs.espressif.com/projects/esp-idf/en/v5.5.5/esp32s3/api-reference/peripherals/gpio.html). |
| Completion and failure | `EPD_ReadBusyH` waits indefinitely for HIGH. `EPD_SendData_Buffer` logs a SPI error and returns `void`; its caller can continue to refresh. The power-off BUSY wait is commented out | Do not adopt these routines unchanged. Every transfer must propagate failure; bounded BUSY and power sequencing must return an explicit result. A log message cannot advance physically displayed/current state. |
| Firmware recovery | [Partition table](https://github.com/waveshareteam/ESP32-S3-ePaper-13.3E6/blob/f8e9456bd1ca520f638786142fc17a74154f4e05/example/ESP-IDF-5.5.1/04_E-Paper_Example/partitions.csv) has one 15 MB factory app and SPIFFS, with no OTA data or two OTA app slots | It does not implement firmware rollback or two protected artwork slots. Freeze a different partition budget after actual module capacity and linked firmware size are known. |

The inspected driver blob is `84db910f4c46c9da1169683af2b1d289c8e19aa3`, SHA-256
`0e9b9fe9ab7f45e3a4dba6b32cf1f5343c90781807b96967738bf2e9e13614ba`;
the GUI blob is `a0f9ffa70e2dcc7069d89aa54274b73561fec76b`, SHA-256
`a19a9a31d9e500af9a776eec98610d02e8fb19df91329448492c68648c590eb2`.
The repository root is Apache-2.0; these copied driver/GUI files include separate
permission notices. Preserve and review file-level licenses before adoption.
No vendor firmware has been incorporated or qualified by this inspection.

**Build direction:** C with ESP-IDF is the evidenced candidate for this board,
because the manufacturer supplies an actual S3 SPI/PSRAM implementation and
[requires IDF 5.5.0 or newer](https://docs.waveshare.com/ESP32-S3-ePaper-13.3E6/ESP-IDF).
Investigate the maintained 5.5 patch line before changing SDK families.
[v5.5.5](https://github.com/espressif/esp-idf/releases/tag/v5.5.5), published
2026-07-17, resolves a JPEG decoder vulnerability and changes PSRAM allocation
options; its tag resolves to commit `b774170ff46c393eeb5e495ea37936038d3f4f4f`.
Ordinary source archives omit submodules. A firmware build must pin recursive
inputs, upstream tool/Python versions and licenses, SDK configuration and
outputs in an isolated environment. This is a proposed build cohort, not a
successful build, target-specific changelog qualification or received-device test.
The receiver should accept host-produced packed stills without a JPEG decoder
or the board's unrelated audio stack.

[IDF 5.5.5 OTA requirements](https://docs.espressif.com/projects/esp-idf/en/v5.5.5/esp32s3/api-reference/system/ota.html)
support two OTA apps and redundant OTA metadata, but rollback requires explicit
configuration and first-boot health confirmation. Signed OTA without hardware
secure boot is a distinct security tier. Burning secure-boot/anti-rollback
eFuses can change recovery permanently; retain ROM/service access and qualify
the exact key, partition and recovery policy before that action. The
[SPI DMA contract](https://docs.espressif.com/projects/esp-idf/en/v5.5.5/esp32s3/api-reference/peripherals/spi_master.html)
requires appropriate buffer capability and alignment; available PSRAM alone
does not establish DMA behavior or bounded memory during TLS and refresh.

#### TLS commissioning: pinned source and native handshake findings

The proposed IDF cohort needs an explicit commissioning TLS profile. A secure
HTTPS server is insufficient evidence that a client certificate is requested,
retained or authorized. The following files were retrieved with `gh` on
2026-10-06 at IDF commit `b774170ff46c393eeb5e495ea37936038d3f4f4f`:

| Source boundary | Exact inspected behavior | Consequence |
| --- | --- | --- |
| [`esp_https_server.h`](https://github.com/espressif/esp-idf/blob/b774170ff46c393eeb5e495ea37936038d3f4f4f/components/esp_https_server/include/esp_https_server.h), `HTTPD_SSL_CONFIG_DEFAULT` | Client CA is null, optional client auth is false, session tickets are false, four sockets and a 10,240-byte task stack are defaults. `tls_handshake_timeout_ms: 0` selects the underlying ten-second default | Pin explicit resource and handshake budgets. Defaults do not qualify memory consumption during simultaneous TLS, flash writes and refresh. |
| [`https_server.c`](https://github.com/espressif/esp-idf/blob/b774170ff46c393eeb5e495ea37936038d3f4f4f/components/esp_https_server/src/https_server.c), `create_secure_context` and `httpd_ssl_open` | Copies CA and server identity into ESP-TLS; after handshake invokes `open_fn` without using its return value, then the `void` user callback | Neither callback is an authorization result. Extract a bounded peer identity through supported APIs and require it at the request owner; never replace HTTPS-owned transport context or send/receive overrides. |
| [`esp_tls_mbedtls.c`](https://github.com/espressif/esp-idf/blob/b774170ff46c393eeb5e495ea37936038d3f4f4f/components/esp-tls/esp_tls_mbedtls.c), `set_server_config` | `set_ca_cert` sets required verification. The optional-auth override is inside the non-null CA branch and compiled only with `CONFIG_ESP_TLS_SERVER_MIN_AUTH_MODE_OPTIONAL` | Setting the optional boolean while leaving CA null does not request the intended bootstrap authentication. Freeze and test the bootstrap trust/configuration path rather than borrowing the post-pair CA path. |
| [`mbedtls/Kconfig`](https://github.com/espressif/esp-idf/blob/b774170ff46c393eeb5e495ea37936038d3f4f4f/components/mbedtls/Kconfig) | TLS 1.3 defaults off and depends on retained peer certificates. `MBEDTLS_SSL_KEEP_PEER_CERTIFICATE` defaults on; disabling it makes `mbedtls_ssl_get_peer_cert` return null in the pinned library | Build and test explicit TLS 1.3, certificate-based exchange and retained-peer settings. A smaller build that removes the certificate cannot satisfy the pairing boundary. |

The server source blob is `7f4e083ac308f91bb00248cb3ab2fbcc054cb75b`, SHA-256
`80cf8b2a90d38535a6f9c819b008927fed00a9b1c7c6bc45160c94a3d2243067`;
the header blob is `dd18e1701d90b3b5d0eeca266af802c45e67565e`, SHA-256
`69d83b88248964501ca20c6c388314ea39a7880fa44c785b6bff77bcf5a1eeb9`.
The ESP-TLS implementation blob is `9507f056464bc929945f9249e2e25b35f979255a`,
SHA-256 `d8403ebfbfcd59f2b8a064514c6fce2799fbf370ddb95deeff29eee6e59839aa`;
the Mbed TLS Kconfig blob is `899ad410a9d1c42ad972d2a3174d5c13a26e4d98`,
SHA-256 `c84df6aa9a4435fa38c7e387ca7276d848cee33721fe516b7fd0f34bcebb0fe8`.
The public [ESP-TLS header](https://github.com/espressif/esp-idf/blob/b774170ff46c393eeb5e495ea37936038d3f4f4f/components/esp-tls/esp_tls.h)
exports `esp_tls_get_conn_sockfd` and `esp_tls_get_ssl_context`. These establish
candidate extraction boundaries, not a completed request-to-peer implementation.
The [HTTPS event configuration](https://github.com/espressif/esp-idf/blob/b774170ff46c393eeb5e495ea37936038d3f4f4f/components/esp_https_server/Kconfig)
defaults to a 2,000 ms posting timeout; `-1` selects an indefinite wait. Keep
this finite and include event/HTTP handling in the overall operation budget.

IDF's exact Mbed TLS submodule is
[`9d669eadb1955d348986b9280156710aaaadf79f`](https://github.com/espressif/mbedtls/tree/9d669eadb1955d348986b9280156710aaaadf79f),
which reports Mbed TLS 3.6.6. Its
[`ssl.h`](https://github.com/espressif/mbedtls/blob/9d669eadb1955d348986b9280156710aaaadf79f/include/mbedtls/ssl.h),
`mbedtls_ssl_conf_authmode`, documents server default `VERIFY_NONE`; optional
verification continues after certificate-chain failure. The
[`ssl_tls.c`](https://github.com/espressif/mbedtls/blob/9d669eadb1955d348986b9280156710aaaadf79f/library/ssl_tls.c)
peer getter returns null when certificate retention is disabled. Those facts
were checked against actual native loopback handshakes, not inferred from an
HTTPS feature list.

**Native experiment:** built the pinned submodule's `ssl_server2` and
`ssl_client2` in an isolated temporary directory on macOS 27.0.1 arm64, using
CMake 4.4.4, Apple Clang 21.0.0 (`clang-2100.3.34.2`) and GNU Make 3.81.
CMake used upstream Python 3.14.8 for configuration checks; no project Python
code or shipped runtime was added. Python uses the PSF license; Mbed TLS offers
Apache-2.0 or GPL-2.0-or-later, CMake uses BSD-3-Clause, and GNU Make uses GPL.
The build used upstream configuration with `ENABLE_PROGRAMS=ON`,
`ENABLE_TESTING=OFF`, `GEN_FILES=OFF`; its configuration-header SHA-256 is
`6a1ca93154a35e9b4e3b5a05d4ca6373096e1d28823a81b17d16a4e5de35b87c`.
This enables TLS 1.3 and certificate retention, unlike IDF's unmodified TLS 1.3
default. The observed downloaded archive SHA-256 is
`9beefd652664a896167011515bdd1fd65cb0e3463b4e9a3a93052bd61a95f66a`;
the immutable submodule commit owns source identity, not GitHub archive encoding.
Observed server/client executable SHA-256 values are respectively
`cc7ac042195f62685f013d596d35f145578111b121337e34c6db89e2df238741`
and `5738cbd3b88b88bcb4ee09eb731278f3250928e5bcb3f6e6c42974b88d015a7a`.
These identify the experiment outputs, not a portable firmware build.

Each server bound only loopback, disabled tickets and forced TLS 1.3. The client
required server verification, used `server_name=localhost`, forced TLS 1.3 and
bounded reads to 3,000 ms. Trusted identities/CA came from the upstream test
programs; the untrusted client was a newly generated one-day P-256 self-signed
fixture made with OpenSSL 4.0.3, not a product credential. Anonymous clients
used `crt_file=none key_file=none`. Every client had a seven-second fixture
deadline; every server was terminated and reaped after its case.

| Server auth mode | Client certificate | Actual handshake | Retained peer certificate |
| --- | --- | --- | --- |
| None | Trusted fixture supplied | TLS 1.3 succeeds | Absent: the server did not request it |
| Optional | Trusted fixture | TLS 1.3 succeeds | Present |
| Optional | Untrusted self-signed fixture | TLS 1.3 succeeds; untrusted-chain flag remains | Present |
| Optional | Absent | TLS 1.3 succeeds | Absent |
| Required | Trusted fixture | TLS 1.3 succeeds | Present |
| Required | Untrusted fixture | Refused | No completed session |
| Required | Absent | Refused | No completed session |

All seven cases passed on 2026-10-06. This establishes the pinned library's
certificate-presence and verification behavior. It does not compile IDF,
exercise its HTTPS callback/session ownership, prove malformed-signature refusal,
test the Mac Keychain identity or qualify the physical board. Optional chain
verification must never authorize an anonymous caller. Before pairing, require
the actual TLS peer certificate and private-key proof plus the physical window,
one-time secret and request identity. After pairing, independently require the
exact durable admitted fingerprint for every protected request, even if another
certificate passes a CA check. A certificate in JSON or an HTTP header remains
unauthenticated data.

**Implementation sequence:** retain the completed capability-selected indexed4
host/preview and receiver custody/integrity fixtures. Next freeze the isolated
IDF build inputs and configuration, then join its actual TLS peer export to
physical commissioning and durable authority. Test absent/untrusted/wrong peer,
lost response, replay and authority restart through the supported request API
before exposing any normal protocol operation. Bound memory and task lifetimes
alongside inactive asset verification, signed OTA and a failure-propagating panel
adapter. Actual module capacity, flash faults, interrupted refresh, rollback,
whole-board power and installed geometry retain the separate M1 gates under
[H-001–H-009 and P-001–P-004](../hardware/validation-plan.md).

### Large-format future

E Ink positions Spectra 6 for full-color retail/signage displays. A 28.5-inch
2160×3060 Sharp/Spectra-class panel is A2-like, but public controller,
procurement, waveform, temperature, and price evidence is insufficient for a
reference BOM. It stays a future sourcing track, not a prototype dependency.
Source: [E Ink Spectra 6](https://www.eink.com/brand/detail/Spectra6).

## Photo candidate

A raw 27-inch matte QHD panel gives A2-like wall presence but is not passive.
The BOE MV270QHM-N40 is useful geometry evidence: 2560×1440, 596.736×335.664 mm
active area, roughly 608.8×353.3×14.9 mm outline, anti-glare surface, WLED
backlight, and a multi-channel LVDS interface. The preliminary data sheet shows
separate panel and backlight/control requirements. Source: [mirrored MV270QHM-N40 preliminary data sheet](https://www.panelook.com/upload/202311/MV270QHM-N40_Rev.P1_20190125_202311014949.pdf).

It is not yet the purchase recommendation. Raw LCD part revisions and generic
controller boards are easy to mismatch. One lower-risk mechanical prototype
option is a documented, externally powered 27-inch matte QHD donor monitor
whose exact panel and controller are verified before de-casing. A builder can
instead start from a raw panel/controller pair when thinness and interface
bring-up are the questions they want to test. A Philips reference data sheet
reports about 23 W typical on-power for one QHD IPS model, which illustrates
why battery-only operation is not credible. Source:
[Philips 27-inch QHD product leaflet](https://www.documents.philips.com/assets/20230529/f326da3d6a284d2ba65eb01100f58d8a.pdf).

The long-term controller candidate is an ultra-thin embedded board capable of
holding a still framebuffer and driving the exact LVDS/eDP interface. It does
not need desktop compute. ESP32-P4 demonstrates that MCU-class parts now expose
MIPI DSI and can drive high-resolution panels, but current documented paths do
not prove compatibility with a 2560×1440 LVDS/eDP panel. Source:
[ESP32-P4 display interface data](https://documentation.espressif.com/esp32-p4_datasheet_en.html).

Until an exact panel/controller pair passes bring-up, the Photo frame is not
implementation-ready.

## Pixel candidate

Six Waveshare P3 64×64 HUB75E modules in a 3×2 physical grid produce a
576×384 mm active area and 192×128 logical pixels. Each module is specified as
192×192 mm, 1/32 scan, 5 V/4 A, and at most 20 W. The combined nameplate ceiling
is therefore 5 V/24 A or 120 W before controller and conversion losses. Source:
[Waveshare P3 64×64 specification](https://www.waveshare.com/wiki/RGB-Matrix-P3-64x64).

Art brightness should consume much less than all-white nameplate power, but PSU,
wiring, fusing, and thermal design must use measured worst cases plus margin.
Brightness is a safety/power setting with a hardware-enforced ceiling.

### Controller direction

The controller is deliberately unselected. The working direction is a
non-Raspberry MCU that can feed several synchronized parallel outputs from DMA
and timers while application code handles only infrequent still-image swaps.
An STM32H7-class part is a feasibility candidate because the family exposes
high-resolution timers, substantial DMA/display facilities, external-memory
interfaces, and cryptographic acceleration. Those capabilities do **not** prove
an exact HUB75 design, qualified firmware support, Wi-Fi/TLS integration, or
acceptable board depth. Sources: [STM32H7 family](https://www.st.com/en/microcontrollers-microprocessors/stm32h7-series.html)
and [STM32H7 example catalogue](https://www.st.com/content/ccc/resource/technical/document/application_note/group0/6b/36/9b/ef/1d/91/4e/6b/DM00393275/files/DM00393275.pdf/jcr%3Acontent/translations/en.DM00393275.pdf).

An STM32 community driver demonstrates that two chained 64×64 HUB75E modules
can be driven from that MCU ecosystem, but it is C++/HAL, GPL-3.0, and not
Frameshift code. MicroZig demonstrates an active Zig embedded toolbox with some
STM32 support, while explicitly warning that its API is still in development.
Neither source establishes support for the exact H7 part or peripheral set
Frameshift needs. They are feasibility evidence and test-oracle material only.
Sources: [STM32 HUB75 driver](https://github.com/kostaman/HUB75) and
[MicroZig](https://github.com/ZigEmbeddedGroup/microzig).

A factory-programmed radio/network coprocessor is acceptable if its bounded
protocol, credential handling, firmware provenance, and recovery lifecycle are
documented. Whether the Pixel frame uses one integrated network MCU or a
display MCU plus such a coprocessor remains an open measurement-driven choice.
Three parallel chains of two modules are a candidate topology, not a frozen
requirement. This is the highest-risk hardware spike.

### Power placement

Do not route 24 A over a long 5 V wall cable. Candidate installation architecture
is a certified external higher-voltage DC supply, concealed low-voltage wiring,
and fused local conversion close to the panels. This reduces cable current but
moves converter heat into the frame, so it remains a hypothesis. An electrician
and local code review are required for concealed wiring; Frameshift will not
specify user-installed mains wiring.

## Controller selection gate

No MCU or module becomes reference hardware until it passes all of these:

- maximum assembled PCB height and connector/bend envelope;
- clean build from a pinned toolchain; any upstream Python tools run only in an
  isolated reproducible environment and never in shipped firmware;
- Wi-Fi association, reconnect, and local discovery behavior;
- TLS 1.3 or appropriate current TLS, mutual authentication, and key storage;
- two recoverable firmware slots or equivalent;
- two atomic asset slots plus current/previous metadata;
- measured idle, radio-on, transfer, refresh, and fault power;
- brownout and abrupt battery removal during every write phase;
- thermal test inside the actual wood/mat/backing stack;
- regulatory path for radio module, battery, charger, and external PSU.

## Prototype paths

Builders may choose any frame class; no universal build order is specified. A
recommended risk-reduction tactic is to use the smallest prototype that can
disprove the selected class's risky assumptions before buying premium hardware
or finishing an enclosure. It is not a participation requirement:

- **Paper:** a development mule that measures wake, transfer, refresh, sleep,
  and the complete battery/control-board depth.
- **Photo:** a donor-monitor or exact panel/controller mule that measures depth,
  heat, idle power, glare, and cable/mount options.
- **Pixel:** a one-module electrical mule that validates timed-parallel/DMA,
  mapping, brightness, and power before a six-module power/mechanical build.

A software frame simulator and golden artifact set benefit every path but do
not block a builder from starting with the hardware they care about.
