# Content Pipeline

**Status:** draft implementation specification

**Invariant:** every output is a still image

## Pipeline

```text
imported source ─┐
                 ├─> immutable master ─> composition recipe
AI generation ───┘                         |
                                           v
                              canonical decode + orientation
                                           |
                                  crop / mat-safe framing
                                           |
                    +----------------------+----------------------+
                    |                      |                      |
                  Photo                  Paper                  Pixel
             color/scale/sharpen    measured palette/dither  simplify/downsample
                    |                      |                      |
                    +----------> immutable target artifact <-----+
                                           |
                              transfer / verify / activate
```

AI never replaces the deterministic portion. It may create or edit a master;
the target renderer then produces exact bytes for the advertised frame profile.

## Library objects

### Master

An immutable imported or generated image. Store original bytes, normalized
orientation, cryptographic digest, decoded dimensions, color profile,
provenance, rights/source notes supplied by the user, and local labels.

### Generation recipe

Records source digests, base/user instructions, provider, exact model, seed and
parameters, provider response identity, parent variant, and disclosure state.
See [AI image generation](../research/ai-image-generation.md).

### Generated-result normalization

Provider output enters the same canonical master representation as import.
The request and recipe name the exact model revision and platform decoder
identity/revision, in addition to the provider/adapter identity. Preflight MUST
match those identities and the selected local/cloud destination. A model alias
or adapter name alone cannot substitute for the recorded revision. Cache keys
include model and decoder revisions; a changed decoder does not reuse an older
normalization result under the same recipe.

The trusted selected provider adapter returns the exact original still bytes,
canonical sRGB top-left straight-alpha RGBA8, decoded width/height, decoder
identity/revision and result identity. Normalization belongs to the narrow
platform codec adapter; the provider must not label raw service bytes as decoded
pixels or replace codec work with declared dimensions. The core checks binary
length, source-byte/pixel ceilings, exact decoder identity and the canonical
representation before packaging with `MasterPackage`. Generated masters store
orientation 1 and sRGB; original output media type and decoder/model revisions
remain in provenance. A missing or malformed canonical result refuses with no
generated master. Provider execution and canonical-result validation share the
finite worker deadline, with no retry or alternate provider.

Cache reuse re-verifies object bytes and the complete master package, including
stored dimensions. Corrupt, missing or legacy raw-image results refuse; a failed
cache verification does not call a provider or silently overwrite the old master.
An exact valid cached result remains usable while its provider is unavailable.
An edit derives its parent original and canonical pixels from an active verified
master package under the Library owner. Caller-supplied source pixels or paths
are not accepted; derived source bytes are transient provider input, excluded
from the recipe, logs and credential context. Removed or invalid parents refuse
before provider work. Fixtures exercise byte/identity refusal, revision changes,
source derivation, timeout and joined generated-master-to-Zig rendering. Native
codec and live model conformance remain separate evidence requirements; fixture
canonical pixels do not prove a production decoder or model.

### Generation callback privacy and refusal

Before invoking a provider's preflight or generation callback, the coordinator
MUST admit the existing exact private-process primary Logger filter and mark
the callback task. Records from that task, including raw provider messages and
OTP exception/throw/exit reports, are dropped before any handler. Other host
records retain their logging policy. A conflicting filter returns
`provider_privacy_unavailable` without invoking a callback or replacing that
configuration. A valid cached master remains readable without this admission.
The static provider identifier callback receives no private request or context.

Adapters return only finite error atoms: `not_available`,
`authentication_failed`, `quota_exhausted`, `refused`, `unsupported_model`,
`unsupported_request`, `download_required`, `cancelled` or `failed`.
The coordinator returns these as `{:error, {:provider, code}}`; any other error
term maps to `failed`, without retaining or exposing raw provider text. A
malformed callback reply returns `{:error, {:provider, :invalid_response}}`.
Coordinator-generated preflight mismatch details retain their existing finite
codes and missing-field names. Task admission failure returns
`provider_unavailable`; a fault returns `provider_crashed`; deadline expiry
returns `provider_timeout`. None triggers retry or a destination change, creates
a generated master, or changes a verified parent/cache object.

This protects the owned callback process. Adapters must independently protect
any child/native process or external service they use. BEAM task exit proves
neither native-worker exit nor cloud cancellation; those acknowledgements and
uncertain-effect recovery require the exact SDK/model cohort's qualification.
Acceptance uses a raw Logger handler, actual raised/thrown/exited callbacks with
private context and verified edit bytes, malformed and private error replies,
conflicting-filter/cache replay and real task-supervisor saturation/recovery.
These are core software fixtures, not live-model or Keychain acceptance.

### Local model preflight and activation

Preflight MUST perform only offline inspection. It cannot call a weight-readiness
or ensure helper whose offline flag protects only catalog lookup. A local
inference backend does not itself attest absence of catalog/download traffic.
Before enabling a selected adapter/model, qualify its explicit network-refusal
boundary and independently verify every selected weight/dependency's full bytes
against its admitted identity; filename, SDK `isDownloaded` or a cached expected
digest alone cannot establish the exact model revision recorded in a recipe.

Required SDK resources must come from the admitted revision and remain available
inside the installed worker without a source checkout. Qualify process-wide
model/cache state, private native outputs and actual cancellation/deadline
completion before admitting concurrent or replacement work. Missing resources,
bytes, disclosure, offline behavior or lifecycle evidence leaves generation
unavailable without downloading, altering a model or switching destinations.
The [exact SDK inspection](../research/ai-image-generation.md#exact-sdk-consumer-boundary-2026-10-05)
records source-based candidates and failed-build evidence; it does not establish
any of these runtime gates as passed.

### Composition recipe

Records target frame/profile, crop rectangle, focal point, rotation, mat-safe
inset, background treatment, renderer revision, palette/profile revision, and
all medium-specific controls. It is canonicalized before hashing.

### Artifact

The immutable output sent to a frame. Its identity is the SHA-256 of the exact
wire bytes. A database row links it to its master and recipes, but the digest
does not depend on database IDs.

## Deterministic stages

1. Decode through a bounded, memory-safe platform codec path.
2. Apply embedded orientation; reject contradictory or malformed metadata.
3. Convert to a canonical working color representation.
4. Apply the saved crop and mat-safe composition.
5. Resize with a renderer-versioned kernel.
6. Apply the exact target color/palette transform.
7. Pack the advertised artifact profile.
8. Hash exact final wire bytes. Bind render metadata to that digest in a
   separate immutable result record.

The same inputs and renderer version MUST produce identical artifact bytes on
supported machines. Golden fixtures cover edges, transparency, profiles,
orientation, extreme aspect ratios, and palette boundaries.

A [qualified binding](qualified-generations.md) pins the admitted frame
profile, exact renderer build, and transfer contract. One work digest combines
that reusable binding with the source and recipe before rendering; a result
binds it to the final wire-byte digest. A renderer revision label alone is not
proof that the same binary produced the bytes.
The renderer owner reads a bounded executable once into a private temporary
copy, hashes the copied bytes, and launches that copy. It retains the copy until
the worker exits, then removes it. A change to the configured executable path
after that snapshot cannot change the active worker's build identity; a worker
restart reads and qualifies a new snapshot before accepting work.

### Linux native normalization

Linux original-byte import uses a separate `frameshift-codec` executable,
consumed by the Elixir host through bounded stdin/stdout. It is a narrow codec
adapter, not a renderer, provider, library writer or new orchestration runtime.
The existing Zig raster worker and macOS ImageIO adapter keep their owners.
The [source cohort review](../research/software-stack.md#linux-codec-source-cohort)
records why the Linux adapter uses pinned memory-safe Rust libraries.

The first qualified software profile accepts **static PNG**, including indexed,
grayscale, alpha, low bit depths, 16-bit samples and Adam7 interlace. Unsupported
formats return a finite refusal; enabling JPEG or another format requires its
own complete-container, stillness, metadata and golden-byte corpus. A media
signature alone never establishes stillness or decoder validity. Any APNG marker
refuses, even with only one advertised frame.

Admission requires 1 byte–128 MiB of original bytes, dimensions 1–32,768 and at most
16,777,011 source pixels. Before pixel decoding, the adapter validates the
complete chunk envelope, every CRC, required/consecutive image data, metadata
placement/duplicates, exact IEND and absence of trailing bytes.
Image data must contain exactly one complete checksummed zlib stream with no
trailing compressed bytes and the exact filtered scanline count for the
declared bit depth/interlace. Check it with a bounded scratch buffer before
pixel decoding; permissive decoder completion cannot substitute for admission.
It allows at most 65,536 chunks, 1 MiB per ancillary chunk, 4 MiB total ancillary data, 64 KiB
Exif and 1 MiB inflated ICC. The PNG decoder has a separate 192 MiB internal
allocation budget; its caller-owned pixel buffer is capped at eight bytes per
source pixel. These are distinct bounds, not a total RSS measurement. CRC and
compressed-data checksums are required; errors must not become untagged color.

The admitted JPEG profile is 8-bit Huffman SOF0/SOF2 with one grayscale
component or three RGB/YCbCr components. It uses the pinned, scalar
jpeg-decoder 0.3.2 source with the maintained strict-entropy patch; the
[source review](../research/software-stack.md#jpeg-admission-source-review)
records the rejected permissive alternatives and exact patch boundary. JPEG
admission MUST precede decoder allocation and require:

- Exactly one initial SOI, one frame header, bounded complete marker segments
  and one final EOI, with no trailing bytes or second primary image. Reject
  unsupported coding modes, 12-bit/lossless/arithmetic images, CMYK/YCCK,
  DNL, hierarchical frames and unknown application extensions.
- At most 65,536 markers, 64 scans, 4 MiB total non-entropy segment payload bytes,
  64 KiB raw Exif and 1 MiB assembled ICC. Grayscale uses 1×1 sampling;
  RGB uses 1×1 sampling; YCbCr admits 4:4:4, 4:2:2, 4:4:0 and 4:2:0 with
  both chroma components 1×1. The common source/dimension/pixel bounds apply.
- Every declared component/coefficient must be supplied through approximation
  bit zero before EOI. Initial coefficient ranges cannot overlap; refinements
  follow their preceding approximation. Incomplete progressive previews are
  unsupported imports. Decode every expected block using actual entropy bits;
  fabricated bits after an early marker cannot complete a block. Require at
  most seven remaining all-one padding bits, exact restart order/intervals and
  no EOB run beyond a restart/scan boundary. Excess entropy data refuses.
- Only structurally checked JFIF, Exif APP1, ICC APP2 and Adobe APP14 application
  segments are admitted. Comments are retained only in the original bytes.
  XMP, MPF/MPO, SPIFF, JPEG XT/gain-map and other extensions refuse, including
  metadata between scans or after the last scan. JFIF thumbnails do not select
  primary artwork; non-square JFIF density refuses without resampling.
- Assemble every ICC chunk exactly once from a consistent nonzero count and
  sequence, including chunks after entropy data; missing, duplicate, conflicting
  or malformed chunks refuse. Use the existing bounded RGB matrix/gray-TRC
  SDR transform. A gray profile requires grayscale source, and an RGB profile
  requires three-component source.
- Parse complete Exif with primary orientation rules below. Exif ColorSpace is
  either one SHORT sRGB (1) or uncalibrated (65,535); unsupported/reserved values,
  duplicates and conflicting primary color fields refuse. Explicit sRGB plus
  ICC refuses; uncalibrated color requires an admitted ICC. Exif 3.x and
  alternate gamma/chromaticity/transfer declarations await their own profile.
  With neither ICC nor explicit Exif color, record assumed sRGB. JFIF/Adobe
  and component IDs must agree on RGB versus YCbCr; they do not themselves
  establish an ICC profile or measured color.

JPEG output is opaque RGBA8 with alpha 255, normalized orientation and source
media `image/jpeg`. Caller-owned decoded samples are capped at three bytes per
source pixel. Padded coefficient and row geometry are bounded before decoding;
the upstream output-buffer limit is not an internal allocation/RSS quota.
Installed OS memory limits remain a separate target requirement. JPEG acceptance
requires native process framing, positive baseline/progressive/color/orientation
fixtures, entropy deletion and forged-EOI refusal, metadata/scan/resource
refusals, unchanged PNG goldens, identical common corpus bytes on Linux
arm64/amd64 and an authenticated original-upload/CLI/Library readback join.
These checks pass for the recorded software cohort; installed Ubuntu/resource
limits and physical display/storage claims remain separate evidence.

Read primary Exif orientation from the complete container, including legal
trailing metadata. Missing orientation means 1; a present value must be one
SHORT in 1–8. Duplicate primary orientation fields, malformed Exif or an invalid
type/count refuse. Thumbnail fields do not override primary artwork. Apply
orientation exactly once, swapping axes for 5–8. Do not resample during this
operation. The canonical master stores orientation 1 and retains the original
orientation in provenance.

The SDR color profile is deliberately bounded:

- Untagged PNG uses **assumed sRGB**, recorded separately from an explicit PNG
  sRGB declaration. Alpha bypasses every color transform.
- Honor PNG color precedence: admitted cICP, then ICC, then sRGB, then gAMA/cHRM.
  cICP accepts full-range identity-matrix sRGB `(1,13,0,1)` and Display P3
  `(12,13,0,1)` only. Other transfer/primary/matrix/range combinations refuse.
  Unsupported HDR metadata refuses until a tone-mapping contract exists.
- ICC admits bounded v2/v4 RGB matrix-shaper or gray-TRC display/input profiles
  with XYZ PCS, aligned bounded unique tags and required white point/curves.
  LUT, device-link, alternate PCS, CICP-bearing ICC and incomplete profiles
  refuse. Curve tables are capped at 4,096 entries; admitted transfer curves
  must be finite, nondecreasing and within the SDR range. Duplicate/conflicting
  primary color descriptions refuse; ICC plus sRGB is not admitted.
- An sRGB declaration requires matching supplied fallback gAMA/cHRM. Without
  a higher-priority declaration, only sRGB chromaticities are currently admitted;
  gAMA in 0.1–10 converts its power-law encoding using sRGB primaries. Absent
  primaries are explicitly interpreted as sRGB primaries, not measured facts.

Color conversion uses scalar moxcms, relative colorimetric intent, fixed-point
preference and no CICP substitution inside ICC conversion. Preserve 16-bit
precision through conversion, then quantize a u16 sample with
`floor((sample + 128) / 257)`. Expand indexed/low-bit inputs before conversion.
Canonical output is top-left straight-alpha RGBA8 sRGB; zero-alpha RGB is zero.
Record original media/interpretation, source-color digest, original orientation,
exact codec cohort and the executed binary digest. Reusing an older normalized
master never silently renormalizes it under a new codec.

One worker invocation accepts an unsigned big-endian u32 length, exactly that
many source bytes and EOF. It returns the fixed 64-byte `FSN1` v1 header defined
in [the codec component](../../codec/README.md#input-and-output), followed by
exactly width × height × 4 bytes; errors contain no pixels or source metadata.
The host MUST validate all header fields, reserve one actual worker at a time,
bound accumulated output and apply a 30-second absolute worker deadline.
Cancellation/timeout must reap that worker before freeing its slot. Never
automatically retry library effects after an uncertain receipt. Original paths,
credentials, provider context and frame identities are excluded from this
worker protocol. Service-owned upload custody is specified by
[the Linux host](../host/linux.md); this executable alone does not authorize
caller paths or complete streamed import.

#### Host process custody

`Frameshift.NativeCodec` owns the normalized result before Library admission.
Its configured executable MUST be a regular executable, owned by root or the
actual nonroot service identity, without group/other write permission and at
most 64 MiB. Read a bounded descriptor, compare path/descriptor identity before
and after using one timestamp representation, then copy exact bytes into an
exclusive private custody directory and verify readback. Execute that snapshot;
later replacement of the configured pathname cannot alter its build digest.

The host selects an existing real service-owned `0700` temporary directory
before startup. This directory protects Exile's transient Unix descriptor
handshake as well as the `frameshift-codec-custody` lease. A preexisting lease
refuses startup without overwriting, adopting or removing any inode. Check
private temporary custody again before each invocation. The fixed root-owned
`/usr/bin/env` executable runs the staged worker with `-i`, an empty environment
and disabled stderr; source bytes enter stdin only. There are no caller paths,
credentials or provider arguments. Admit the exact primary Logger filter and
mark Exile processes before original-byte writes: upstream crash reports can
otherwise contain a queued input chunk. A conflicting filter refuses rather
than replacing unrelated logging policy.

Each admitted job verifies the exact `--version` result and its successful
native exit, then performs one decode. Both invocations share one thirty-second
absolute deadline and reservation. Writes and reads use at most 64 KiB chunks;
stdin closes after exact input. Validate the complete FSN1 header before reading
bounded pixels, then require exact payload, EOF and exit status zero. A valid
output followed by a nonzero exit is a refusal. Error output must have no
metadata, pixels or extra bytes.

An independent watchdog observes owner death and the deadline even while the
decode task is blocked on IO. The public deadline can return before native
termination, but the reservation remains occupied until the task acknowledges
actual exit. Unknown task/native custody makes the owner unavailable and
retains the lease. Normal shutdown removes custody only after confirmed exit;
abrupt owner death preserves it so a replacement cannot overlap old work.
Abandoned custody is an explicit service-recovery operation: stop the complete
installed service and establish native termination before removing that lease.
Do not infer VM-exit cleanup from `Port.close`, an elapsed timer or a PID signal
alone. Installed service/cgroup shutdown, NIF/helper closure, OS resource limits
and storage power-loss behavior require their own release evidence.

Acceptance requires native debug/release normalization and process-framing
fixtures, all orientations, actual ICC/cICP/gamma transforms, alpha, bit depth,
interlace, checksums, corruption and bounds. Host joins must additionally exercise
worker death/deadline, executable custody, authenticated upload, no duplicate
library write and recovery after lost replies. Identical fixtures on both Linux
architectures and installed resource limits are separate release evidence;
native macOS tests do not establish those claims or measured panel color.

## Photo renderer

- Preserve source detail without inventing motion or temporal effects.
- Composite alpha against the saved background before output.
- Fit the exact pixel geometry and safe inset.
- Convert to the advertised color space/profile.
- Use conservative output sharpening after resize, versioned in the recipe.
- Produce only a still artifact accepted by the controller.

The preview simulates the passe-partout crop and approximate matte/brightness,
but does not claim colorimetric accuracy without a measured panel profile.

## Paper renderer

- Use the exact ordered pigment palette and measured conversion profile.
- Offer renderer-versioned error-diffusion and ordered-dither modes.
- Keep neutral and near-white handling explicit; paper white is not an emitted
  RGB white.
- Pack indices exactly as the advertised driver profile requires.
- Reject a stale artifact when the frame's palette/profile revision changes.

Preview shows palette and dither at 1:1 pixels plus the expected full-refresh
flash warning. It is an approximation until compared with a photographed test
chart under controlled light.

## Pixel renderer

Low resolution is the medium. The recipe may apply composition-aware crop,
edge/shape emphasis, cluster cleanup, palette reduction, and controlled
pixelation before the final exact 192×128-class grid.

The renderer does not send an animation or a sequence of temporal frames. It
packs one static RGB artifact. Brightness/current limiting is applied again in
hardware, independently of source pixels, so corrupt metadata cannot defeat the
electrical ceiling.

Preview uses nearest-neighbour enlargement with visible grid/module boundaries
and the configured brightness/gamma profile.

## Slideshow semantics

A slideshow is a playlist of artifact digests and dwell rules. Each item is a
complete independently verifiable still. At the boundary, the frame swaps from
one cached still to another; it does not interpolate, crossfade, scroll, or
decode motion.

The host clamps dwell to the frame's `minimumDwellMs` and may prefill a new
cycle from its qualified or explicitly provisional `recommendedDwellMs`.
The frame, not the host, advances cached artwork at a confirmed-display-based
deadline. [Display timing](display-timing.md) defines the pinned-artwork loop,
energy evidence, and failure behavior.

The implemented host command snapshots pinned masters, renders exact artifacts,
checks capacity, and writes a complete pull playlist with protected references.
The receiver fetches the body and all missing assets before the first display
acknowledgement activates the revision. Physical persistence and RTC behavior
still require validation on exact frame hardware.

## Bounded native preview contract

The authenticated local `preview` read accepts an active `itemID` and either no
target (source preview) or the selected `targetID`, `profileID` and exact
`capabilityDigest`. The core reads and verifies the registered master package;
it accepts no caller pixels, paths or replacement capability documents. Target
preview uses the same admitted RGB24 profile selection, centered crop, alpha
background and resize job as Send, including the active binding's profile when
present. Unsupported palette/packing/color profiles refuse explicitly.

The Zig worker renders a transient RGB24 preview with each dimension at most
256 pixels and a five-second render deadline. The longest edge is reduced to
256 without enlarging smaller rasters; integer rounding is explicit, and the
result retains the original source/target aspect dimensions for native layout.
The response includes master, target, profile and capability identities, the
worker build digest, exact RGB byte digest and `approximation: true`. Raw pixels
are at most 196,608 bytes; the base64 response remains below the existing 1 MiB
IPC ceiling. No master, recipe, artifact, pin, delivery or frame state changes.
Preview cannot authorize transfer or claim panel color, palette, brightness,
physical mounting geometry or confirmed display. Mat-safe/profile controls not
yet implemented remain explicit requirements of the final rendering contract.

The focused Library and selected compact card share one bounded preview state.
The shell checks response identity, format, dimensions, byte length and digest
before constructing a native sRGB image. Selecting another master/frame clears
the old image immediately; late responses cannot replace the new selection.
Closing a surface preserves the shared selected preview. Busy, timeout, missing
master, changed capability/profile and malformed responses show an actionable
unavailable state with explicit retry; they never become automatic mutation
replay. Artwork remains local and has no browser/network upload in this path.

Acceptance joins verified package readback, real Zig crop/alpha bytes, source and
target identity, unsupported/stale/missing refusal and unchanged library/outbox
state. Native fixtures test bounded digest validation and late-response races;
the packaged Swift/core probe reads and validates real preview bytes. Optical
comparison and native installed visual/accessibility evidence remain separate.

## Cache behavior

- Identical work digests reuse existing artifacts after exact byte verification.
- Regenerate creates a new master variant; it never overwrites.
- Re-render after a renderer/profile update creates a new artifact.
- Pin protects a master, generation, and referenced artifacts from automatic
  collection.
- Remove unlinks from the active library and moves unreferenced host content to
  recoverable trash.
- Current, previous-known-good, queued, playlist-referenced, or pinned frame
  assets are never collected.

## Local storage budget

The Library writer owns a durable `storage.objectByteLimit` setting. Its initial
budget is 20 GiB; an explicit change accepts whole byte counts from 1 MiB to
1 TiB. This is a budget for unique registered object bytes, including masters,
artifacts and recoverable trash. It is not a filesystem quota or free-space
measurement: SQLite, work files, logs, provider/model downloads and unregistered
orphans are outside this accounting and need their own bounded lifecycle.

The authenticated `libraryStorage` read reports the configured limit, a revision
over that configuration, active/trash byte counts, total registered bytes,
object count, remaining allowance and over-budget state. It returns no private
paths. `updateStorage` accepts only the expected configuration revision and the
new byte limit. Setting and redacted audit commit together; a stale revision or
invalid stored configuration refuses without resetting it. Lowering a limit
below retained usage is allowed and visibly reports over-budget state.

Before placing a new master or artifact, the serialized writer checks its exact
byte size against the remaining allowance. Duplicate registered bytes consume
no additional allowance; digest-addressed placement still verifies bytes before
reuse. Over-budget imports, generated results and new render artifacts refuse with
`library_storage_full` before placement or new object/master/artifact rows and
their placement audit commit. Recipe registration or provider execution may
already have occurred before this final admission; refusal does not roll back
those earlier operations. Existing artwork remains readable, pinnable and
deliverable using retained artifacts; restore and
metadata edits remain usable. Removal and collection into recoverable trash
do not free registered bytes and never trigger automatic permanent deletion.

Native Settings shows accounted usage and trash bytes, accepts an explicit
whole-MiB draft and saves against its observed revision. Refresh and window
closure preserve unsaved drafts; a concurrent settings change requires explicit
reload/review. Edits typed during save survive its acknowledgement. Uncertain
command outcomes use the existing receipt/reconciliation contract. A budget
error distinguishes host library capacity from a frame's storage capacity and
offers review of Storage settings. No write is retried automatically.

Acceptance covers exact-boundary admission, duplicate reuse, removed/trash
accounting, over-budget read/restore, generated/artifact refusal, writer
serialization, stale configuration, audit rollback, invalid persisted settings
and restart. Native fixtures cover draft/save races and finite input; a packaged
Swift/core probe joins the read/update path. Full-disk, physical power loss and
installed native accessibility remain separate evidence gates.

## Auto-labeling

User labels win. Filename/metadata terms and Apple Vision classifications are
stored with provenance and confidence. Vision feature prints support local
similarity search. Labeling does not upload an image by default and has no role
in artifact correctness.

### Native Vision adapter

The native adapter accepts only a validated full-source preview, never a target
crop. Its input is the existing source-preview v1 envelope: top-left sRGB RGB24,
white-composited alpha, bilinear reduction without enlargement, maximum edge
256 pixels. Record the master digest, exact preview-pixel digest and renderer
build digest. Classification of this reduced input is an observation, not an
optical/artifact or whole-resolution image-quality claim.

Select `VNClassifyImageRequest` revision 2 and
`VNGenerateImageFeaturePrintRequest` revision 2 explicitly, refusing when either
revision is unsupported. Feature-print scaling uses `scaleFit`. The adapter
revision includes the numerical macOS version, host CPU architecture and
input/scale contract; a different OS/CPU/revision/input cohort is not
interchangeable. Retain at most 32
distinct classifier identifiers with finite confidence from 0.5 through 1,
ordered by decreasing confidence then identifier. Labels use the existing
NFC/control/128-byte bounds. User labels remain owned by the Library writer.

Feature prints are opaque secure-coded `VNFeaturePrintObservation` archives,
at most 16 KiB, with revision 2, finite element/data bounds and an exact archive
digest. Swift owns secure decoding and Vision distance computation; Elixir
must not interpret or invent feature vectors. A comparison admits at most 16
distinct candidate master IDs per batch, checks the same adapter cohort and
secure archive type/revision before use, and returns finite nonnegative
distances ordered by distance then master ID. Larger distance means less
similarity; it is not a percentage or confidence in a semantic match. Invalid
or non-comparable archives refuse the batch rather than silently dropping them.

One native worker slot covers analysis and comparison. Caller deadlines are
ten seconds; cancellation invokes Vision's cooperative `cancel()` and resolves
the caller once with a finite result. A timed-out/cancelled operation retains
the slot until its actual worker exits, discards late results and admits no
replacement worker meanwhile. Inputs, results and archives stay in memory in
this adapter; it reads no external paths and performs no network request. Core
observation persistence, background scheduling and Library similarity UI retain
their own joined consumer acceptance and are not established by an adapter test.

Acceptance requires actual Vision requests/secure round trip and comparable
same-image distances on the inspected macOS/SDK, malformed/target/cohort refusal,
finite input/output checks, cancellation/timeout and slot custody under a
non-cooperative fixture. This does not establish semantic labeling accuracy,
another macOS revision, the installed accessibility matrix or network-isolation
measurement. Upstream contracts and the inspected SDK are recorded in the
[software stack research](../research/software-stack.md#native-vision-source-check).

### Vision observation persistence and background labeling

`recordVision` is an ordinary authenticated receipt-bound command. It names one
active master, the observed metadata revision, the adapter cohort, input-pixel
and renderer digests, up to 32 Vision labels and the bounded secure archive with
its SHA-256 identity. The core checks exact fields, cohort/label bounds and
archive bytes/digest; secure decoding and inference remain the Swift adapter's
responsibility. These are adapter observations, not a signed classifier or
render/profile qualification. Caller pixels, paths and replacement artwork are
absent from this command.
The secure archive crosses the command boundary as at most three canonical
base64 chunks of at most 8,192 bytes each (6,144 decoded bytes per full chunk),
with a 16 KiB aggregate decoded ceiling. The existing IPC string/request limits
remain in force; the read response returns one bounded base64 archive.

The Library writer replaces only that master's Vision rows, preserving title,
user/filename/metadata labels, immutable content and delivery references. It
refuses removed/missing masters, stale metadata, duplicate label identities or
more than 64 combined labels before mutation. Labels, their FTS projection, one
bounded `master_analysis` record and a redacted audit fact commit together.
The analysis record stores the exact archive and its input/cohort/digest identity
as local derived metadata, not an ANN index or a second master. At most 16 KiB
per master is retained in SQLite; it falls outside the object-byte budget's
explicit artwork accounting. Backup/restore copies it with the metadata DB.
Replacing an observation does not grow a history of native feature vectors.

`libraryAnalysis` reads one active master's record and verifies archive size and
digest before returning it. Missing analysis is an explicit unavailable result.
`libraryAnalysisPending` accepts only a bounded adapter cohort and returns at
most 16 digest-ordered active IDs whose observation is absent or belongs to
another cohort, plus a `hasMore` indication. Removed masters are excluded.
Neither read follows a caller path or authorizes artwork/intent changes.

The native shared session schedules background labeling after successful import
and ordinary refresh. Each activation admits at most 16 pending IDs, runs one
analysis at a time and does not retry failures automatically. Existing same-
cohort observations are reused; explicit reanalysis can replace them and add a
previously dismissed machine observation again. Import returns before labeling
and remains successful if labeling fails. The selected Library item offers local
analysis/cancellation and readable status. Stopping pauses automatic import
labeling until an ordinary refresh or explicit analysis. Cancellation discards
results before command submission; an already accepted save may finish. A
receipt-unknown commit needs fresh metadata review, never blind replay.
Selection, unsaved metadata/instructions and pins survive background updates.
Concurrent edits refuse stale observations rather than overwriting user work.

Acceptance joins actual native Vision, verified source preview, authenticated
IPC, transactional label/archive/FTS/audit persistence, restart and backup
readback. Fixtures cover stale/removed/duplicate/count/archive refusal, audit
rollback, empty classifier results, independent user labels, pending bounds,
background scheduling/selection/draft races and cancellation. Visual similarity
pagination/ranking/UI remains a separate read-only consumer of these archives.

### Local visual similarity

Similarity is an explicit Library action on one selected active master. It uses
that master's saved feature print from the current native cohort; missing or
incompatible observations ask for local analysis instead of changing source or
calling a generation provider. Results occupy a separate named section, leaving
literal title/label search, selection, pins, drafts and frame intent intact.
The current source/pin/paired-frame facets constrain candidates. A facet or source
selection change clears results and invalidates pending responses; entering text
also clears similarity. Selecting a result selects its exact master normally.

`librarySimilarityCandidates` is an authenticated read with exact source item ID,
cohort, source feature digest, optional exclusive digest cursor and the existing
bounded facet object. The Library checks active source/archive identity on every
page and refuses a replaced source, unknown frame or malformed cursor/facet. It
returns at most 16 active same-cohort candidates in digest order, excluding the
source, with verified bounded archives and title/pin projections. Frame filtering
uses retained master or artifact-recipe custody, never physically displayed art.
Corrupt candidate archives refuse the page rather than silently dropping records.
The page and its source identity remain below the existing 1 MiB response ceiling.
Reads do not create commands, render pixels, mutate metadata or qualify a profile.

The native consumer reads at most 32 pages (512 candidates), compares one page at
a time with the existing secure Vision adapter, and retains at most 100 nearest
results sorted by finite nonnegative distance then master ID. It verifies source
identity again after scanning. Distances express Apple feature-print difference,
not match probabilities or semantic accuracy. If candidates remain after the
ceiling, the UI explicitly identifies a partial scan; it cannot claim the nearest
artwork in the whole Library. Results cover observed pages, not an atomic catalog
snapshot: concurrent candidate edits/removal can change subsequent reads.

One shared native worker still covers classification and comparison. Similarity
and background labeling cannot overlap in the shared shell; controls explain the
busy state. A scan has a thirty-second caller deadline, cooperative cancellation
which resolves visible status without admitting a replacement scan until the
current scan owner returns. IPC reads retain
their finite socket deadlines; cancellation never promises to kill a native thread
or undo accepted work. Timeout, malformed/non-comparable archive or stale source
clears the result and returns a readable retry/reanalysis state. No automatic
retry, upload, ANN service or new generic search engine is introduced.

Acceptance covers multi-page exact ordering and facets before limits, source
replacement/removal, incompatible/corrupt archives, bounded response bytes and
unchanged Library/intent/audit state. Native tests cover full/partial scans, finite
ranking, the 100-result ceiling, deadline/cancellation, changing facets/selection,
late responses and draft preservation. The packaged join compares actual persisted
Vision prints from distinct masters through real authenticated IPC. Synthetic
same-input distances establish this join, not a semantic-quality threshold or
installed accessibility acceptance.

## Editable metadata and recovery contract

Artwork bytes, source provenance, dimensions, recipes and variant lineage remain
immutable. Title and local labels are editable Library metadata; changing them
MUST NOT rehash the master, render an artifact or alter frame intent. The
authenticated `libraryMetadata` read names one master digest and returns its
title, source kind/dimensions, labels with provenance/confidence/model revision,
and a revision digest over the exact title and ordered labels. It exposes no
source path, arbitrary provenance document or database handle.

`updateMetadata` accepts the master ID, expected metadata revision, title,
complete user-label set and explicit machine-label dismissals. The writer
refuses removed/missing masters and stale revisions before changing anything.
Titles are NFC-normalized, trimmed, nonempty and at most 256 UTF-8 bytes.
Labels are NFC-normalized, trimmed, nonempty, at most 128 UTF-8 bytes each, with
no control characters. Each master holds at most 64 labels, including at most
32 user labels; machine revision strings are at most 128 bytes. ASCII case
duplicates within a provenance use the existing SQLite NOCASE identity;
non-ASCII spelling remains distinct. User labels replace only user rows. A
dismissal names an existing label and its machine provenance (`vision`,
`filename` or `metadata`); correction adds the desired user label and dismisses
the observed machine row. Other machine rows retain confidence and revision.
New machine observations change the revision and therefore refuse a stale edit.
Dismissal removes the current observation; it is not a permanent classifier
suppression preference. Automatic labeling remains a separate adapter feature.

Title/label changes, their FTS projection and a redacted audit fact commit in
one transaction. Audit details contain no titles, labels or image provenance.
The successful command returns the committed metadata revision; a lost response
uses the existing command receipt/unknown-outcome contract, without write replay.
An already-applied receipt returns current shell state rather than an invented
original metadata revision; the editor retains its draft and asks for explicit
reload when that committed revision is absent.
The native editor preserves per-master drafts across selection, refresh and
window closure. New edits typed while a save is pending survive its response;
they retain the revision that was actually committed. Explicit reload discards
the local draft and reads current metadata. Stale edits show a review/reload
action and never silently overwrite another writer.

The authenticated `libraryRecovery` read returns at most 50 removed masters per
page, ordered by digest with an exclusive digest cursor and `nextCursor`.
Concurrent changes may alter later pages; refresh starts a new listing. Each
row includes title, removal time, storage state and current retention reasons
(pin, frame reference, rendered artifact or recipe source). Retention means
the host bytes cannot be collected; it does not claim that the artwork is
currently displayed. `restore` names one digest, verifies its retained bytes,
and atomically restores active metadata and its FTS projection with an audit
fact. Missing/corrupt bytes or database failure leave the item removed. An
interrupted filesystem move is reconciled from the recorded storage state;
restore cannot substitute bytes from another object. Already active restore is
idempotent. Neither listing nor restore changes pins or frame intent.

Recently Removed offers refresh, pagination and restore with visible retention
state. There is no permanent-delete action in this contract. Unreferenced
collection moves bytes to recoverable trash; it is not destruction. Backup and
offline whole-library restore retain their separate maintenance contract.
Acceptance covers concurrent metadata edits, transactional FTS/audit rollback,
bounded Unicode input, machine provenance preservation, pagination beyond one
page, protected removal, corrupt/missing restore, interrupted moves and restart.
Native fixtures cover draft/selection/save races and paginated recovery;
packaged IPC probes join the actual Swift and core commands. Installed visual,
keyboard and VoiceOver evidence remains a separate acceptance tier.

## Acceptance criteria

1. A renderer can reproduce a golden artifact byte-for-byte.
2. Cancelled or crashed work leaves no committed partial artifact.
3. Changing one recipe field changes the cache key.
4. Changing only UI display state does not change the cache key.
5. A profile mismatch is detected before transfer.
6. No pipeline branch accepts or emits video, animated image playback, or audio.
