# Menu-Bar Interface

**Status:** interaction specification

**Reference:** the selected perspective-frame mark on a transparent field,
with a dark silhouette in light appearance and a white silhouette in dark
appearance.
[FrameshiftMark.svg](../../apps/macos/App/Icons/FrameshiftMark.svg) is its
canonical vector source.

## Product posture

Frameshift is a quiet menu-bar utility, not a dashboard. The primary flow is:

```text
open -> choose frame -> describe or choose image -> generate/render -> send
```

The packaged macOS app runs as a menu-bar agent. Its dropdown is the primary
control surface and stays available after dismissal. The transparent mark
appears in Finder, and its unboxed silhouette appears in the menu bar.

Advanced provider, model, storage, pairing, and hardware details live in
Settings. The popover shows only information needed to choose artwork and know
whether it reached the selected frame.

## Menu-bar item

- Use the supplied mark's silhouette as a monochrome template at 18 points
  with 1×, 2×, and 3× representations. Test its optical weight at 16, 18, and
  20 points; keep the menu-bar rendering unboxed.
- Accessibility label: “Frameshift.”
- Primary click toggles the window-style popover.
- A small, keyboard-focusable power icon in the dropdown header quits the app.
  Its help text and accessibility label say “Quit Frameshift”; Command-Q also
  works while the dropdown has focus. Quitting stops the bundled core.
- A labeled settings icon beside Quit opens the native Settings scene without
  depending on the dropdown remaining open.
- No animated menu-bar icon. Busy state uses a subtle static badge/dot or text
  inside the popover.

SwiftUI's `MenuBarExtra` with `.window` style is the implementation baseline.
Apple explicitly positions window style for richer popover-like content:
[MenuBarExtra documentation](https://developer.apple.com/documentation/SwiftUI/MenuBarExtra).

## Popover layout

Target a compact width in the 360–420 point range and let content scroll before
growing into a large editor.
The approved perspective-frame mark sits beside the app name and short purpose
line at the top, optically centered against the two text lines, without a
colored tile or other background. The mark has a
transparent field and uses a dark silhouette in light appearance and a white
silhouette in dark appearance. The labeled Quit icon sits opposite it. The
backdrop uses an active native
behind-window material so desktop color shows through; system Reduce
Transparency may make it opaque. Cards use a lighter material while retaining
text contrast.

```text
┌──────────────────────────────────────┐
│ Paper — Hallway             status ⏻ │
│                                      │
│ What should this frame show?         │
│ ┌──────────────────────────────────┐ │
│ │ instructions…                    │ │
│ └──────────────────────────────────┘ │
│ [＋ Image]  [⌕ Library]   [Generate] │
│                                      │
│ Search: forest, blue, pinned…        │  conditional
│ ┌─────────┐ ┌─────────┐ ┌─────────┐ │
│ │ preview │ │ preview │ │ preview │ │
│ │ ↻  pin ×│ │ ↻  pin ×│ │ ↻  pin ×│ │
│ └─────────┘ └─────────┘ └─────────┘ │
│                                      │
│ Waiting for next contact · 18:00     │
│ Settings…                         │
└──────────────────────────────────────┘
```

The drawing is structural, not a visual-style prescription.

### Task-first native composition

Compose the shell around the current task, not a dashboard or browser device
class. The compact menu-bar popover covers selecting a target, choosing or
describing one still, sending or queueing it, and reading its concise delivery
state. Artwork comparison, playlist editing and recovery that need persistent
space open a focused native sheet or window. Frame management, provider and
privacy configuration, storage, accessibility and diagnostics remain in the
resizable Settings scene. Do not translate CSS breakpoints or web container
profiles into SwiftUI width checks.

Each presentation carries one state envelope: selected frame and advertised
capability revision; master, variant, rendered artifact and display-profile
identity; current library selection, search, draft instruction, focus and
playlist order; source/provider and cloud-destination disclosure; command and
delivery intent identity; and queued, transferred, refreshing, displayed,
failed, cancelled or outcome-unknown state. Opening a larger surface preserves
that envelope. Dismissing or resizing a surface cannot reinterpret a send,
discard an acknowledged draft or describe transferred bytes as displayed.

The first focused surface is one native **Library** window, opened from the
popover or Command-L. It uses the same `ShellModel` instance as the popover
and Settings. Selection names the exact master identity; search changes the
visible result set without discarding that selection. A successful removal
clears a selected master, while a failed/unknown command retains it for review.
The core snapshot remains authoritative for target, pins and delivery state.
Search and draft instruction are presentation state shared across surfaces.
A refresh adopts a changed core instruction only when the local draft is clean;
unsaved text, including edits made while a save is awaiting acknowledgement,
survives refresh, pin/remove/target commands and opening/closing the window.
The window displays source-master identity and queued/loop state explicitly;
it cannot infer a rendered preview or physical display from that identity.
The selected master has a bounded local source preview when unpaired and an
approximate target-crop preview for a supported paired profile. The focused
window and selected compact card share it. Identity, dimensions and exact pixel
digest are checked before display; changed selection clears old pixels, and a
late response cannot replace the new selection. Unsupported/stale/busy previews
show refusal and retry. Comparison remains a separate software slice. See the
[bounded preview contract](../architecture/content-pipeline.md#bounded-native-preview-contract).

Use SwiftUI's native [window scenes and open-window action](https://developer.apple.com/documentation/swiftui/windows)
with a 700 × 520 point minimum and an initial 860 × 640 point size for this
Library surface. List selection, search, instruction editing and toolbar
actions remain keyboard accessible. Automated state tests establish shared
selection/draft behavior; manual VoiceOver, focus return and layout/settings
acceptance retain their separate evidence requirements.

The compact popover must not hide the selected target, still-artwork identity,
provider destination, required confirmation, current failure or relevant
recovery action. Artwork cards remain appropriate because each result is an
independently selectable still. Other sections do not become cards by default,
and Frameshift does not add a dashboard unless a recurring monitoring decision
requires one. No presentation mode adds video, motion, audio or streaming
controls to the artwork path.

Native material and accessibility settings apply in every mode. Reduce
Transparency may replace translucent material with an opaque system result;
Increase Contrast, Reduce Motion, text scaling, Full Keyboard Access and
VoiceOver must preserve hierarchy, focus order and status meaning. Evidence
covers the compact popover at 360 and 420 points and the resizable Settings or
focused window at its admitted minimum and representative expanded size. These
are native layout fixtures, not a CSS breakpoint system.

### Target row

The first row selects a paired frame or an explicitly configured offline render
profile. It shows one concise state: displayed, sending, refreshing, waiting
for contact, needs attention, or unpaired. Sleeping frames show the next
expected contact rather than an alarm-colored offline state.

### Instruction editor

One native multiline text editor accepts the user's generation/edit
instruction, including Return-delimited paragraphs. It has a visible
placeholder aligned with the insertion text inset when empty, a bounded height
with internal scrolling and an accessible label. Saving preserves embedded
newlines. The selected display
profile contributes a versioned base instruction. A small
“Paper recipe,” “Photo recipe,” or “Pixel recipe” disclosure opens the full
effective instruction and allows advanced override; it does not clutter the
default flow.

When the selected item is an imported image, the field steers an edit or target
interpretation. When empty, it creates a new generated master. Provider absence
never blocks normal image import/render.

### Image source and search

- **Image** opens file/photo selection and accepts drag/drop or paste.
- Import and save controls use flat native buttons with clear photo-add and
  checkmark symbols; labels remain visible alongside their symbols.
- **Library** reveals a single search field and recent/pinned results.
- Search matches titles, user labels, local Vision labels, selected frame,
  source/provider, and pinned state.
- A “similar” action may use local Vision feature prints; the UI identifies
  similarity results rather than pretending they are text matches.

The core's title and label search uses a SQLite FTS5 projection maintained in
the same transaction as those rows. Text input is treated as literal Unicode
word prefixes, with a bounded number of terms and results; FTS operators are
never accepted from the search field. Empty search keeps pinned-first library
ordering. The index is rebuildable from masters and labels and excludes
removed masters. Frame, source, and pin filters are separate facets of the
full library view.
The library writer exposes an explicit transactional index rebuild from active
masters and labels for recovery; a rebuild never changes artwork, pins, or
frame delivery state.
The compact panel sends the entered text over authenticated, read-only local
IPC and displays the matching cards without changing the selected target or
instruction. Empty text returns the ordinary recent/pinned set. Search results
from an older edit cannot replace results for the current text; after a library
mutation, the visible search is refreshed from the core.

Auto-labeling runs in the background and does not interrupt import. Generated
or machine labels remain editable in the full library/settings view.

### Result strip/grid

Each card is one immutable master or generated variant with a target preview.
The library results own the remaining dropdown height and scroll independently
when cards exceed it; the target and instruction controls stay visible. An
unpaired target reads “No frame paired” beneath the Target heading.
The card exposes exactly three compact actions:

| Symbol | Action | Behavior |
| --- | --- | --- |
| `arrow.clockwise` | Regenerate | Creates a new sibling/child variant; preserves this result |
| `bookmark` / `bookmark.fill` | Pin | Protects the item and makes it easy to retrieve |
| `trash` or `xmark` | Remove | Removes from the active library and moves unreferenced data to recoverable trash |

Actions appear on hover/focus but pinned state remains visible. Every symbol
has a tooltip, accessibility label, keyboard focus, and command equivalent.
Remove does not immediately destroy a displayed or frame-referenced artifact.

Selecting a card previews it for the current frame. The primary button becomes
“Send,” “Queue for next contact,” or “Displayed” according to frame state.

## Slideshow editing

The compact UI may add selected stills to a playlist, reorder them, and set a
dwell. It never exposes transition effects because there are none. A frame's
minimum dwell is enforced. More complex schedule editing belongs in a separate
window opened from Settings/Manage Frames.

An explicit per-frame “Loop pinned artwork” action snapshots the ordered pins.
Its interval starts from the profile suggestion when one exists, labels a
provisional suggestion as such, and accepts a per-frame override above the
minimum. Photo and Pixel present interval as a viewing preference, without an
energy-saving claim. The UI separates prepared, pending, and frame-confirmed
active states. See [display timing](../architecture/display-timing.md).

The compact menu exposes this as **Loop pins** with a provisional suggestion
when advertised, fixed choices filtered by the receiver minimum, and a custom
interval field. The custom control validates the receiver minimum
and a one-year upper bound before submission; the core applies the receiver
minimum again.
It shows pending, active, or suspended state from the durable core snapshot.
The status shows the selected revision's still count and interval, including
while confirmation is pending.
For a pending replacement it says that the current loop continues until the
frame confirms the new revision.
Each visible library card in that frame's selected playlist carries the same
state, including entries after the first still; the outbox's first desired
asset alone does not describe the whole loop.
The core renders the pin set and queues a complete authenticated pull playlist;
the receiver performs the offline cycle. Repeating **Loop pins** after a single
still has paused it queues a fresh intent, including when the revision is the
same. The focused Library presents the included master titles in order, allows
selected artwork or current pins to seed a draft, and provides add/remove and
move-up/down controls. Per-frame drafts survive refresh and target changes.
Whole-integer milliseconds, seconds, minutes and hours allow sub-minute dwell
where admitted; the saved per-frame override is the next editor default.
**Resume saved loop** submits the exact suspended revision and uses its retained
set and interval. It refuses stale intent, pending delivery and changed
capabilities for review. It does not recreate a playlist from current pins.
Capability/recommendation changes are labelled before queueing. A photo or pixel
interval is a viewing choice, not a measured energy optimization. Optical
preview comparison and the installed accessibility/layout matrix remain open.

## Progress and failure

Use one line of plain status:

- “Generating locally…”
- “Rendering 192×128 Pixel artifact…”
- “Queued for Paper frame · next contact around 18:00”
- “Refreshing Paper frame · about 19 seconds”
- “Displayed”

Cancellation is offered while the operation can still be cancelled. Provider
refusal, authentication, quota, render, transfer, and display failures are kept
distinct and offer one relevant recovery action. The app never silently changes
AI provider or cloud destination.

## Settings boundary

The native Settings window uses full-width grouped cards beneath clear section
headings. It scrolls vertically and can be resized; explanatory text, frame
identifiers, status, and errors wrap instead of truncating. Nearby frame actions
sit below the frame identity so their labels cannot squeeze the identity or
pairing status. Pair, Recover, and Login Items actions share the dropdown's
flat labeled button style and visible symbols. Disabled actions remain visibly
disabled and keyboard accessible controls retain their native semantics.

The implemented settings are grouped as Connection, Image generation, Nearby
frames, and Startup.

Settings contains:

- frames, commissioning, pairing, names, and certificates;
- local/cloud provider order, models, licenses, quotas, and privacy policy;
- model/storage downloads and cache/trash retention;
- background launch and outbox availability;
- an opt-in Launch at Login switch for the main menu-bar app using
  `SMAppService.mainApp`, with enabled, approval-required, and disabled states
  visible and a working unregister path;
- renderer defaults and full base instructions;
- accessibility and notification preferences;
- diagnostics/export with automatic secret redaction.

## Accessibility and keyboard behavior

- All icon-only actions have labels and Help tags.
- Full keyboard traversal follows visual order.
- Return runs the current primary action; Command-Return generates when the
  instruction field is focused; Escape closes transient search/popover state.
- Do not rely on color alone for status or pinned state.
- Respect reduced motion; the product has no content motion and needs no
  decorative popover animation beyond system behavior.
- VoiceOver reads result provenance and state without reading the entire prompt
  or digest unless the user opens details.

## Acceptance scenarios

1. Import a local image and queue it to a sleeping Paper frame without setting
   up an AI provider.
2. Generate locally, regenerate one variant, pin the preferred result, and
   remove the rejected variant without losing either unintentionally.
3. Search an auto-labeled library and distinguish literal from similar results.
4. Queue one still for each configured frame class without exposing
   video/animation controls.
5. Complete every action with keyboard and VoiceOver.
6. Quit from the dropdown or Command-Q, observe the bundled core stop, and
   relaunch the menu-bar agent without losing durable artwork.
7. Understand whether bytes are queued, transferred, refreshing, or physically
   displayed from the compact status alone.
8. Move from the compact popover to a focused or Settings window and back while
   preserving the exact selected frame, artwork, instruction draft, focus
   return, command identity and delivery state. Exercise 360- and 420-point
   popovers plus admitted minimum and expanded window sizes with VoiceOver,
   Full Keyboard Access, increased text size, Increase Contrast and Reduce
   Transparency.
