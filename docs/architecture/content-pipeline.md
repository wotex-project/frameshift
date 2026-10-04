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

## Acceptance criteria

1. A renderer can reproduce a golden artifact byte-for-byte.
2. Cancelled or crashed work leaves no committed partial artifact.
3. Changing one recipe field changes the cache key.
4. Changing only UI display state does not change the cache key.
5. A profile mismatch is detected before transfer.
6. No pipeline branch accepts or emits video, animated image playback, or audio.
