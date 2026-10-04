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

### Composition recipe

Records target frame/profile, crop rectangle, focal point, rotation, mat-safe
inset, background treatment, renderer revision, palette/profile revision, and
all medium-specific controls. It is canonicalized before hashing.

### Artifact

The immutable output sent to a frame. Its identity is the SHA-256 of the exact
wire bytes. A database row links it to its master and recipes, but the digest
does not depend on database IDs.

## Deterministic stages

1. Decode through a bounded, memory-safe system codec path.
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

## Auto-labeling

User labels win. Filename/metadata terms and Apple Vision classifications are
stored with provenance and confidence. Vision feature prints support local
similarity search. Labeling does not upload an image by default and has no role
in artifact correctness.

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
