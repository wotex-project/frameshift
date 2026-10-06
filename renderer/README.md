# Frameshift raster worker

`frameshift-raster` is the isolated deterministic raster process. It accepts
bounded, length-framed binary jobs on standard input and emits one framed
terminal response per complete job on standard output. It receives canonical
RGBA8 pixels, explicit composition parameters, and either an uncompressed
RGB24 profile or a caller-supplied indexed palette. It receives no credentials,
URLs, provider configuration, or frame identity.

The current generic-profile renderer uses integer arithmetic for crop,
nearest/bilinear resize, alpha composition, palette selection, ordered dither,
and Floyd–Steinberg error diffusion. RGB operations are byte-space transforms;
they do not claim measured colorimetric accuracy. Measured color transforms,
transfer functions and sharpening remain gated on an exact qualified display
profile. The closed indexed4 software path maps explicit hardware codes and
packs native rows; it does not establish measured pigment color or physical
controller qualification.

## Wire request v0.1

Each request starts with a four-byte big-endian body length. The 52-byte body
header is followed by `paletteCount × 3` RGB bytes and exact
`sourceWidth × sourceHeight × 4` RGBA8 bytes.

| Offset | Type | Field |
| ---: | --- | --- |
| 0 | 4 bytes | `FSR1` |
| 4 | `u8` | protocol major (`0`) |
| 5 | `u8` | protocol minor (`1`) |
| 6 | `u8` | command (`1`, render) |
| 7 | `u8` | output (`1` RGB24, `2` indexed8) |
| 8 | `u8` | resize (`1` nearest, `2` bilinear) |
| 9 | `u8` | dither (`0` none, `1` ordered 2×2, `2` Floyd–Steinberg) |
| 10 | `u16` | reserved, zero |
| 12 | `u32` | source width |
| 16 | `u32` | source height |
| 20 | `u32` | crop x |
| 24 | `u32` | crop y |
| 28 | `u32` | crop width |
| 32 | `u32` | crop height |
| 36 | `u32` | target width |
| 40 | `u32` | target height |
| 44 | 4 bytes | background RGB followed by a reserved zero byte |
| 48 | `u16` | palette entry count |
| 50 | `u16` | reserved, zero |

Lengths are capped at 64 MiB, dimensions at 32,768, and raster arithmetic at
16,777,216 pixels. Because the complete request contains a 52-byte header and
up to 768 palette bytes in addition to four bytes per source pixel, the host
import boundary admits at most 16,777,011 source pixels. Target output remains
bounded independently. All integers are big-endian.

## Wire request v0.2: indexed4

Output code **3** is `indexed4_msb` and requires protocol **0.2**. The header
remains 52 bytes, but each palette entry is **four bytes: R, G, B, wire code**.
There must be 2–16 entries with unique codes in 0–15, and the target width must
be even. The existing geometry, crop, alpha, resize and dither contracts apply.
Palette distance ties select the first entry. Each adjacent pixel pair becomes
`(code[left] << 4) | code[right]`; rows have no padding and output is exactly
`width × height / 2` bytes. The worker owns both quantization and final packing.
0.2 accepts only code 3; substituting a format/version, duplicate or oversized
code, malformed palette/length, or odd target width returns a typed refusal.
0.1 RGB24/indexed8 byte layouts are unchanged.

The [host contract](../docs/architecture/content-pipeline.md#closed-indexed4-software-profile)
requires explicit advertised packing and palette/color revisions. Vendor names
do not select this output. The 1200×1600 fixture enumerates every native byte
against the source-based Paper controller row slicing; it is a software oracle,
not optical, electrical or physical completion evidence.

## Wire response

The response also starts with a four-byte big-endian body length. Its 20-byte
body header contains `FSO1`, protocol version, a stable status byte, output format,
width, height, and payload length, followed by the payload only on success.
The version is 0.1 for RGB24/indexed8, 0.2 for indexed4. A 0.2 error retains
that version with zero output/dimensions/payload. Unrecognized versions refuse;
error responses for short or unsupported requests use 0.1.

| Status | Meaning |
| ---: | --- |
| 0 | success |
| 1 | malformed frame |
| 2 | unsupported protocol version |
| 3 | length, dimension, or pixel bound exceeded |
| 4 | invalid crop |
| 5 | invalid output, filter, dither, or palette profile |
| 6 | allocation failed |

Run the complete worker build and tests with:

```sh
mise exec -- zig build test
mise exec -- zig build -Doptimize=ReleaseSafe
```
