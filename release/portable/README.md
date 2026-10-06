# Portable release tooling

This independent Mix project owns portable release policy. Its first boundary
is `FrameshiftRelease.Input`, backed by the release-only Zig POSIX worker.
Existing Node manifest/receipt/channel consumers remain until their byte and
refusal compatibility fixtures pass. No host application dependency, NIF,
background service or publication authority is added.

`FrameshiftRelease.Manifest`, `FrameshiftRelease.Trust` and
`FrameshiftRelease.Verifier` now join exact compact manifests, independently
pinned public SPKI, whole-message signatures and streamed local archive facts.
The escript CLI exposes distinct local and signature-only observations:

```sh
release/portable/frameshift-release verify MANIFEST SIGNATURE PUBLIC_KEY ARTIFACT_DIR TRUST_FILE
release/portable/frameshift-release verify-signature MANIFEST SIGNATURE PUBLIC_KEY TRUST_FILE
```

Build with `./scripts/check release-portable` first. The default worker is built
in that checkout; `--worker ABSOLUTE_TOOL` explicitly selects another qualified
native worker for the execution OS. The standalone escript needs pinned OTP;
an installed app's reduced runtime is not a complete developer toolchain.
Neither command performs public URL readback. Usage/refusal exits are 64/1 with
fixed diagnostics, and no input, receipt or archive is changed.

```sh
./scripts/check release-portable
cd release/portable
mise exec -- mix run -e 'case FrameshiftRelease.Input.read("mix.exs", maximum: 65536) do {:ok, bytes} -> IO.puts(byte_size(bytes)); {:error, _} -> System.halt(1) end'
```

The check builds the worker with pinned Zig, checks formatting, compiles Elixir
with warnings as errors and exercises actual input/mutation/process fixtures.
The API requires an explicit read maximum; `hash/2` streams up to 8 GiB by
default. `with_input/3` holds descriptor custody through the supplied consumer
and returns a result only after closing checks and actual worker exit zero.
Private and trust predicates use independent options. See the
[owning custody contract](../../docs/architecture/release-manifest.md#portable-descriptor-custody),
[migration sequence](../../docs/architecture/implementation-plan.md#release-tooling-migration)
and [verification map](../../docs/architecture/verification.md#installed-product-and-guide).

## Worker exchange

Every frame starts with a big-endian unsigned 32-bit body length. Integers are
unsigned big-endian; reserved bytes must be zero. The executable takes no
arguments. Paths and file bytes appear only on stdin/stdout. Stderr is unused.

| Body | Exact fields |
| --- | --- |
| Initial request | Version `1` (u8), operation `1` read / `2` hash (u8), flags bit 0 private / bit 1 trust (u8), reserved (u8), minimum (u64), maximum (u64), whole-session milliseconds (u32), path byte length (u16), UTF-8 path bytes |
| Provisional read | Version `1`, status `0`, operation `1`, reserved (all u8), actual length (u64), exactly that many bytes |
| Provisional hash | Version `1`, status `0`, operation `2`, reserved (all u8), actual length (u64), 32 raw SHA-256 bytes |
| Closing request | Exactly one byte: `1` finish / `0` abort |
| Terminal success | Exactly four bytes: `1,0,3,0`, followed by actual exit `0` |
| Terminal refusal | Exactly four bytes: `1,1,0,0`, followed by actual exit `65` |

Initial bodies are at most 4,122 bytes; paths are nonempty, at most 4,096 bytes
and contain no NUL. Read maximum is 16 MiB, hash maximum 8 GiB and session budget
1–900,000 ms. A read/hash success is provisional until closing custody and exit.
Malformed/extra/duplicate messages, unsafe or changed files, EOF and deadline
refuse. The worker polls nonblocking pipes and checks its monotonic budget
between regular-file syscalls. A stalled syscall has no hard termination claim.

The monitored Elixir owner parses bounded streaming frames before accumulating
their bodies. On terminal refusal it writes nothing further and waits for actual
exit. Consumer failure/caller death/deadline request abort once, discard late
output and retain the port until exit. Lost port custody returns explicit
`:worker_custody_unknown`, never accepted data. No file cleanup, replay, key
selection, release signing or remote effects belong to this worker.
