# Isolated still-image codec

`frameshift-codec` is the Linux original-byte normalization adapter. Elixir
owns orchestration and library writes; the existing Zig worker owns crop,
resize and target packing. macOS keeps its Apple ImageIO adapter. This process
has no paths, network, credentials, library handles or frame authority.

Build with the repository's pinned Rust toolchain:

```sh
./scripts/check codec
./scripts/check linux-codec
cd codec
mise exec -- cargo build --locked --release
./target/release/frameshift-codec --version
```

The admitted profiles are **static PNG** and bounded **8-bit Huffman JPEG**. Indexed and grayscale depths
expand before color conversion; 16-bit color retains its precision through
conversion and rounds to RGBA8. Primary Exif orientation 1–8 applies exactly
once, including legal metadata after IDAT. Canonical pixels are top-left,
straight-alpha sRGB; zero-alpha RGB is zero. Original bytes are never rewritten.
See the [owning contract](../docs/architecture/content-pipeline.md#linux-native-normalization).
JPEG admits baseline/progressive grayscale and RGB/YCbCr with explicit common
sampling and complete coefficient scans. CMYK/YCCK, HDR/gain-map, MPF/MPO,
XMP/unknown application extensions, incomplete scans and other formats refuse.
The strict entropy patch prevents an early marker from fabricating pixels;
complete Exif and split ICC admission precede orientation/color conversion.

## Input and output

One invocation accepts one unsigned big-endian u32 source length followed by
exactly that many bytes and EOF. No command-line source path is accepted.
`--version` prints the exact producer cohort; other arguments exit 64.
Sources are 1 byte–128 MiB, dimensions 1–32,768 and at most 16,777,011 pixels.
The source must have one exact PNG signature, complete CRC-checked chunks,
consecutive IDAT and an exact IEND with no trailing bytes. Any APNG marker
refuses, including a one-frame animation. Metadata limits and color admission
are in the owning contract. PNG's compressed-data checksum is explicitly enabled;
ICC inflation is separately bounded because the upstream PNG parser discards
ICC decoding errors.
An independent stream pass uses 32 KiB scratch space and requires exactly one
complete checksummed zlib stream with the declared filtered scanline count;
missing checksums, extra output and concatenated/trailing stream data refuse.

Output is a fixed 64-byte `FSN1` header followed by the declared RGBA bytes:

| Offset | Field |
| --- | --- |
| 0 | Four bytes `FSN1` |
| 4 | u16 version, 1 |
| 6 | u8 status, 0 success; 1 malformed, 2 unsupported, 3 bounds, 4 color, 5 metadata, 6 allocation, 7 internal |
| 7 | u8 color interpretation: 1 assumed sRGB, 2 PNG sRGB, 3 cICP sRGB, 4 cICP Display P3, 5 matrix ICC, 6 gAMA with sRGB primaries, 7 JPEG Exif sRGB |
| 8, 12 | u32 normalized width, height |
| 16, 17 | u8 original orientation, source media (1 PNG, 2 JPEG) |
| 18 | Six reserved zero bytes |
| 24 | u64 RGBA byte length, exactly width × height × 4 |
| 32 | 32-byte source-color digest; zero for assumed/declared sRGB, SHA-256 of cICP or inflated ICC, domain-bound gamma digest for code 6 |

PNG admits interpretation codes 1–6; JPEG admits 1, 5 and 7. JPEG alpha is
always 255. Codes 1, 2 and 7 require a zero digest; other admitted codes require
the exact nonzero source-color digest. Media/interpretation mismatches refuse.

All multibyte values use big-endian order. Failure has only magic, version and
status set, with no payload or source metadata. Producer errors are finite;
panic is caught without printing source material. OOM or process loss remains a
worker failure for the host. The host must bound output, enforce one decode at
a time and a 30-second absolute deadline, reap a stopped worker and never replay
an uncertain library mutation. The executable digest belongs in master
provenance. Target-specific CPU/runtime closure and installed Linux memory
limits remain release requirements; compiling this executable does not satisfy
them.

## Dependencies and qualification

`Cargo.lock` fixes the entire source cohort. Direct dependencies are PNG 0.18.1,
moxcms 0.9.1 without SIMD/LUT features, kamadak-exif 0.6.1, flate2 1.1.10 with
its Rust backend, crc32fast 1.5.2, SHA-2 0.11.0 and the scalar
[vended jpeg-decoder 0.3.2-fs.1](vendor/jpeg-decoder/README.md). No system codec C library or
in-process NIF is introduced. moxcms uses BSD-3-Clause OR Apache-2.0, Exif uses
BSD-2-Clause, and the other direct dependencies use MIT OR Apache-2.0.
The [source review](../docs/research/software-stack.md#linux-codec-source-cohort)
records exact revisions, tradeoffs and limits; distribution license notices and
target-specific binary closure still need release verification.

`tests/normalization.rs` exercises complete native process framing, all eight
orientations, alpha, low-bit/palette expansion, 16-bit quantization, actual ICC
and cICP color conversion, gamma, malformed metadata and resource refusals.
`tests/jpeg.rs` adds eighteen tests for baseline/progressive gray/RGB/YCbCr,
common sampling/restarts, all orientations, actual split RGB/gray ICC, explicit
Exif color, every-scan entropy deletion/forged EOI, padding/EOB boundaries,
complete metadata, extensions, resource limits and mutation/process refusal.
The source-check script reverses the patch and verifies every preserved upstream
source/license hash before compilation. Fixture-only jpeg-encoder 0.7.1 uses
`(MIT OR Apache-2.0) AND IJG` and is absent from the shipped executable.
Tests establish software normalization, not a measured display profile or an
installed Ubuntu package. The pinned Rust 1.97.1 / Debian trixie multiarch
fixture runs the same release corpus on Linux arm64 and amd64, then runs it
again as UID 65534 with read-only root and no network. macOS arm64 and both
Linux fixture architectures agree on forty normalized header/pixel vectors:
SHA-256 `12c3f441f4caf87542a9c75404510ffad3f585a772952f8b37e45c09610b6ade`.
The same targets agree on 98 JPEG vectors: SHA-256
`8b65e9848b51bc0b213f59f9d7482fe1e6962235c766a8b3397763465d4ef593`.
The fixed JPEG source/pixel pair also joins actual native ownership, authenticated
upload, fresh CLI import and full host-VM restart/status recovery on both Linux
fixtures. Cargo-audit 0.22.1 checked all 29 locked dependencies against RustSec
`ef6173cbc5c50ec8166f9a5b28f07834144373ee` on 2026-10-05 with no reported
vulnerability or warning; this is a dated advisory check, not a security proof.
The amd64 local execution uses Docker emulation; this is a fixture-corpus
byte-identity claim, not installed Ubuntu or universal colorimetric proof.
