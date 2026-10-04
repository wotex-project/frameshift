# Display Timing and Pinned Artwork Loops

**Status:** protocol contract and implementation plan; physical energy defaults await measurement

## Terms and authority

`minimumDwellMs` is the receiver's hard lower bound between completed still
updates. An optional `recommendedDwellMs` is a profile suggestion for a new
cycling playlist, not a panel scan rate or a claim of optimal battery life.
`recommendationBasis` is either `measured-energy` (whole assembled frame,
including sleep, wake, contact, transfer, and refresh) or
`provisional-profile` (an explicit product starting point). The recommendation
also carries a `recommendationRevision` that identifies its evidence or
provisional profile. It must be at least the minimum. An operator override is stored per frame and
clamped to its current capability minimum when submitted. The host displays
the source and basis, and warns if a changed profile forces a longer dwell.

The Paper Waveshare E6 candidate guide recommends at least 180 seconds between
refreshes, at least one refresh per 24 hours while in use, and panel sleep or
power removal after refresh. Frameshift enforces the 180-second lower bound in
its provisional receiver profile; the source remains a manufacturer
recommendation, not an absolute electrical rating or measured energy optimum. Until assembled-frame measurements exist, Frameshift
uses a provisional six-hour cycling suggestion for this candidate. Its
receiver advertises `minimumDwellMs: 180000`,
`recommendedDwellMs: 21600000`, and
`recommendationBasis: provisional-profile`, with revision
`frameshift-paper-e6-v1`. A 24-hour maintenance refresh of
unchanged content is a separate receiver policy and must not advance a
playlist or falsely report new art. This policy needs panel/controller
qualification before hardware release. [Waveshare E6 manual](https://www.waveshare.com/wiki/13.3inch_e-Paper_HAT%2B_%28E%29_Manual).

Photo and Pixel require continuous panel/backlight or matrix scan power while
visible. A longer artwork dwell alone has no established display-energy
benefit. Their candidate profiles advertise their safe minimum but no energy
recommendation; a user can choose an interval for aesthetic reasons. Brightness,
current limits, and scheduled off periods are the relevant power controls.
The [Waveshare P3 specification](https://www.waveshare.com/wiki/RGB-Matrix-P3-64x64)
lists each module at 5 V/4 A and up to 20 W, independent of artwork changes.

## Pinned loop intent

Pin is a library retention action. The explicit per-frame **Loop pinned
artwork** action takes an ordered snapshot of pinned master identifiers. Pinning
or unpinning later proposes a new revision; it does not silently mutate an
active frame playlist. The UI shows the included count, order, interval,
profile suggestion or user override, and pending/active status. Without a
paired frame it may prepare a draft but cannot claim a running loop.

The host renders every master for the exact selected frame profile, validates
capacity, transfers and verifies every immutable asset, then atomically
replaces the complete `cycle` playlist. If preparation fails, the old playlist
remains active. Removal cannot collect a referenced asset. A new single-image
Send explicitly suspends the loop or requires the user to resume it; the host
never races independent desired and playlist writers. The host persists an
idempotent intent, revision, target capability revision, and acknowledgement
under its single writer. A sleeping frame fetches the playlist body by revision
at contact after all assets, verifies it, and acknowledges installation; a
manifest containing only a revision is not sufficient to execute a loop.

The host outbox persists and serves a complete playlist created from rendered
artifacts. It protects active and pending references through replacement and
activates only after a matching first-display acknowledgement. The menu's
explicit **Loop pins** action snapshots the ordered pin set, renders each
master for the selected profile, and submits this transaction. A single-image
send supersedes a pending playlist or suspends an active one when confirmed.
When a replacement is pending, the previous active loop continues on the frame.
The host snapshot marks this as a pending replacement so the menu can show both
the new intent and the continuing display truth.
Repeating **Loop pins** after suspension may queue the same canonical revision
as a fresh pending intent; the previous suspension is replaced atomically.
Further single-image sends leave a suspended loop record and its protected
references intact until an explicit new loop is queued.
The local library projection marks every member of the selected frame's
pending, active, or suspended revision. It does not infer loop membership from
the manifest's first `desiredAsset`.
The compact panel shows the selected revision's still count and dwell interval
beside its pending, active, or suspended state. A pending replacement labels
the previous active loop as continuing until the frame confirms the new one.
The compact menu offers fixed intervals and custom intervals above the receiver
minimum, bounded to one year. The focused Library owns the ordered-set editor.
Physical RTC and whole-frame energy qualification remain hardware release gates.

## Local ordered-set and resume contract

The authenticated local `loopArtwork` command accepts `targetID`, an ordered
`itemIDs` list and optional integer `dwellMs`. It snapshots 1–64 distinct active
master identities, within the selected receiver's playlist capacity; pins are
not required. Missing/removed masters, duplicate identities, unsupported pull
mode or invalid intervals fail before rendering. The host renders in that exact
order and uses the existing single-writer playlist/outbox transaction. Preparation
failure leaves the previous active/pending intent intact. Rendered artifacts
must also be distinct: two masters producing identical bytes cannot manufacture
two distinct receiver entries.

An explicit override is 1–31,536,000,000 ms and is clamped to the current minimum.
Native input offers milliseconds, seconds, minutes and hours as whole positive
integers; unit conversion uses checked multiplication and validates the same
bound. Successful queueing atomically saves the interval choice per frame,
including requested/applied dwell, profile recommendation revision and the exact
capability digest. Failed preparation or storage cannot replace this preference.
The editor uses the saved override as its default; a separately selected profile
suggestion resets it to that suggestion. A changed minimum or recommendation is
shown for review, rather than described as measured energy improvement.

Snapshots expose the selected revision's ordered master identities and titles,
independently of search pagination and later pin changes. An editor draft is
shared between native surfaces, scoped to one frame, and survives refresh and
surface dismissal. Changing targets retains each target's draft. Add/remove and
move-up/down actions are available from keyboard controls; queuing submits an
immutable copy so further local edits cannot rewrite an in-flight command.

`resumePlaylist` accepts only `targetID` and the exact `playlistRevision` shown
as suspended. Under the library writer it refuses a stale/non-suspended revision,
any newer queued delivery, or changed capability digest. Otherwise it revalidates
the protected artifact/profile/work custody and atomically queues the saved
canonical body with a fresh outbox intent. It preserves order, dwell, source
identities and playlist revision without consulting current pins or re-rendering.
Missing artifacts, capacity/profile failures and database errors leave the paused
record and references intact. Resume starts the saved cycle from its first entry
after receiver confirmation; it does not promise the previous device index or
deadline. Pending/active truth still comes only from the receiver acknowledgement.

Acceptance uses native state fixtures and a real Zig-renderer/core/outbox joined
test for ordered masters, clamping, changed pins, restart, exact saved-body resume,
stale revision, pending-delivery refusal and injected transaction rollback.
These establish software intent/custody behavior; installed native accessibility,
receiver timing and physical display/energy acceptance remain separate gates.

## Receiver clock and failure behavior

The receiver owns relative dwell timing and cycles cached stills even when the
host is offline. The deadline is based on confirmed display completion, not
queue or transfer time. Paper uses an RTC wake, initializes the panel, refreshes,
confirms completion, cuts panel power, and sleeps. Photo holds the framebuffer;
Pixel scans the held buffer. Both swap only at a dwell boundary. No display
class interprets playlist entries as animation frames.

On boot, the receiver restores the playlist revision, current entry, and
deadline. It reconciles an interrupted refresh with physical truth before
advancing the index. Failure retains the last confirmed current image and
retries with bounded backoff; elapsed time never causes a burst of catch-up
refreshes. Monotonic time is used while awake. Sleep deadlines require a
qualified RTC and clock-error policy. A frame without that evidence must
advertise playlist cycling unavailable rather than let the Mac simulate a
running loop. State/telemetry distinguish playlist accepted, next wake,
refreshing, displayed, and failed. Tests cover long offline periods, restart,
power loss, clock jumps, full storage, unsupported dwell, and revision races.

## Qualification gate

For each exact hardware revision, record the measured full energy cycle at
several dwells and temperatures, sleep current, RTC drift, refresh duration,
and visible behavior. Replace the provisional Paper suggestion only when the
measurements support it. Show the measurement revision in capabilities and
retain it with each playlist intent so a firmware/profile change triggers
revalidation.
