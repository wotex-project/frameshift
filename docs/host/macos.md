# macOS Host

**Status:** normative product specification; implementation evidence tracked separately

## Role

Frameshift for macOS is the control plane for all frame classes. It owns the
art library, local labels/search, AI generation recipes, deterministic target
rendering, frame identities, outboxes, still-image playlists, synchronization,
and the audit trail.

The Mac is not a frame's life support. Once a still asset is current, quitting
Frameshift, sleeping the Mac, or losing the network does not blank it.

## Process architecture

```text
Frameshift.app
  SwiftUI MenuBarExtra
  Apple framework bridge
  Apple unified-log bridge for structured core records
       |
       | local authenticated length-framed IPC
       v
  FrameshiftCore (Elixir/OTP per-user process)
       |-- metadata store
       |-- content-addressed files
       |-- bounded metric collector and read-only diagnostics IPC
       |-- job/outbox supervisors
       |-- WoT Consumer/ExposedThing runtime + binding clients/servers
       `-- frameshift-raster (supervised Zig executable)
```

### Swift application

The native shell owns `MenuBarExtra`, app lifecycle, accessibility, file and
photo selection, drag/drop, Keychain, Vision, Core Image/Image I/O, Bonjour,
notifications, and MediaGenerationKit. It presents snapshots received from the
core and sends commands; it does not create a second source of truth.
The packaged app runs as a menu-bar agent. Its dropdown is the primary shell
control surface and remains available after it is dismissed. The selected
perspective-frame mark appears directly on a transparent field in Finder and
the dropdown. Finder uses the dark silhouette from the bundle icon; the running
app selects a dark silhouette in light appearance and a white silhouette in
dark appearance. A monochrome template silhouette appears in the menu bar. A
small labeled
power control in the dropdown header and Command-Q quit the agent and its
bundled core; relaunch reads the durable library again. The header repeats the
selected mark beside the name, while a native behind-window material gives the
dropdown a translucent backdrop that follows macOS accessibility settings.

The optional browser-guide URL supplies only an in-memory class/profile hint.
The menu shows that hint and allows a matching paired target to be selected
only after an explicit user action; it never pairs, imports, or sends artwork
from a URL. See [guide handoff](guide-handoff.md).

### Elixir core

The core is a conventional supervised OTP release. Each long-running job has
one owner, one deadline, bounded input, explicit cancellation, and one terminal
result. Queues are bounded. Provider and frame failures are typed data, not
crashes or prose parsed from logs.

The core owns network policy. It validates Thing Descriptions, selects
advertised compatible Forms deterministically, and never derives an endpoint
from a vendor name. Its binding clients disable automatic mutation redirects
and hidden retries. Frame credentials are fetched from the Swift Keychain
bridge only at the transport boundary and immediately discarded after request
construction. A successful binding exchange is not accepted as display truth;
the core reconciles the frame `state` Property or completion Event.

### Zig raster worker

The worker receives no provider or frame credentials. It processes bounded
canonical image buffers and returns deterministic target bytes. The core
monitors the port, kills it at deadline, and restarts after failure. A worker
crash fails one render job without terminating the library or UI.

## Local IPC

The shell and core communicate over a per-user Unix domain socket in an app-
owned directory. The socket has user-only permissions. Each launch delivers a
random session token through a one-use protected bootstrap file; connecting to
the path alone is insufficient. The shell checks that the socket accepts a
connection before sending its first request, so a leftover socket file does
not masquerade as a ready core after a restart.

Messages are length-prefixed and versioned. Maximum message size is fixed
before allocation. Commands carry a unique ID and receive progress snapshots
plus exactly one terminal response. Reconnection obtains a fresh full snapshot
and does not replay completed UI commands blindly.

Before executing a mutation, the core durably binds its command ID to the
SHA-256 digest of its RFC 8785 canonical form. Completed outcomes remain in the
library so the same ID and digest return the prior disposition without running
the effect again; reuse of an ID for different content is rejected. Receipts
contain no command payload, source path, temporary path, artwork, or credential.
If the core stops after claiming an ID but before recording its terminal
outcome, that ID remains pending and returns `command_outcome_unknown` rather
than risking a duplicate effect. The shell then reads a fresh authoritative
snapshot and asks the user to review it before issuing a new command ID. This
is an explicit durable at-most-once boundary, not a false exactly-once claim.

A connected command whose write, framing, response decoding or correlation
cannot be confirmed is reported as `command_outcome_unknown`. It is not
replayed by the transport. Known correlated domain refusals remain explicit;
read cancellation suppresses presentation without implying a mutation rollback.
During quiescence, reconciliation waits for an explicit later review instead
of starting another snapshot request.

The implemented v1 boundary currently uses one four-byte-big-endian-length
prefixed JSON request and response per connection, a 64 KiB request ceiling,
bounded JSON depth/node/string/collection admission, duplicate-member
rejection, request correlation, a 5 second socket deadline, and explicit
command field allowlists. The application-support directory is mode `0700`
and the socket is mode `0600`; the server refuses to replace a non-socket path.
Both local listeners inspect the socket directory with `lstat` before changing
its permissions or binding. A symlink or non-directory at that path fails
startup without changing the target. A live socket is never removed as stale.
On every core launch the Swift owner generates a fresh 256-bit token, writes it
to a uniquely named mode `0600` file inside the private directory, and passes
only that path to the release. The core validates and removes the bootstrap
file before opening the socket. Every request must carry the token and the core
compares it in constant time, so knowing the socket path is insufficient. The
release and packaged-app checks perform authenticated snapshot, durable command,
import, and refreshed-snapshot round trips and reject missing or wrong tokens.

The message schema includes no raw private key material. Large image bytes move
through app-owned files/file descriptors rather than base64 JSON.

The diagnostic CLI uses a separate read-only local transport and verifies the
connecting peer and private socket directory. It never borrows the shell's
in-memory mutation token. Health, metric rollups, and audit are paginated and
size-limited; the CLI never opens the database. See the
[diagnostics contract](../architecture/diagnostics.md).

The implemented import boundary admits one still image with Image I/O, rejects
multi-image containers and inputs above 128 MiB or 16,777,011 decoded pixels,
applies embedded orientation, converts to sRGB RGBA8 with straight alpha, and
writes a mode `0600` handoff inside a mode `0700` temporary directory. The core
re-sniffs the original media type, checks dimensions and exact byte length,
verifies the SHA-256 handoff digest, and stores a versioned immutable package
containing both exact original bytes and normalized pixels. It never persists
the caller's source or temporary canonical path.

## Persistence

```text
Application Support/Frameshift/
  metadata.sqlite
  objects/sha256/ab/cdef...
  previews/sha256/...
  work/<job-id>/
  trash/<date>/...
```

Exact filesystem placement uses Apple-provided application-support URLs rather
than hard-coded paths. The metadata database stores object relationships and
state; artwork bytes remain content-addressed files. Temporary work is never
treated as committed content.

Important records are:

- master image and provenance;
- generated variant and parent;
- generation recipe;
- composition/render recipe;
- target artifact and exact capability/profile revision;
- frame identity, certificate reference, friendly local name, and last state;
- desired/current/outbox state;
- playlist and item dwell;
- user labels, Vision labels, confidence/revision, and feature print reference;
- pin/removal/collection state;
- operation audit entries with redacted error data.

Database migrations are transactional and reversible where practical. Startup
reconciles temporary/orphan files without deleting anything referenced, pinned,
queued, current, previous-known-good, or inside the trash retention window.

## Background operation

The first distribution target is one Developer ID signed, hardened-runtime,
notarized, stapled DMG. Direct download, Homebrew Cask, and Sparkle updates
consume that same versioned artifact under the
[installation contract](../architecture/install-and-guide.md). The current
development bundle does not satisfy these release claims. App Store
constraints are a separate product decision.

Use Apple's `SMAppService` to register a bundled per-user login item or launch
agent only after the user enables background synchronization. The app must show
registration state and provide a working disable path. It never installs a root
daemon. Apple describes `SMAppService` as the supported interface for bundled
login items and launch agents: [Service Management documentation](https://developer.apple.com/documentation/servicemanagement/).

The first native setting registers the main menu-bar app with
`SMAppService.mainApp` only when Launch at Login is enabled. A separate helper
remains unnecessary while the app owns the bundled core lifecycle. Settings
distinguishes macOS approval-required state from enabled state and links to
Login Items when approval is pending.

Settings uses a vertically scrolling, resizable window with full-width grouped
sections. Frame identities and explanatory text wrap; pairing actions occupy
their own row and share the dropdown's flat labeled button style. See the
[settings layout contract](menu-bar-interface.md#settings-boundary).

The background process wakes only for pending jobs, frame contact, or scheduled
outbox availability. It does not poll powered frames aggressively. Sleeping
frames control their own contact interval; the host reports “waiting for next
contact,” not “offline.”

### Shell task ownership and quiescence

Use structured concurrency for work whose lifetime belongs to an asynchronous
operation, and SwiftUI `.task`/`.task(id:)` for work whose lifetime belongs only
to a view. The shared shell session owns work that must survive closing the
popover. Retain handles for app/model tasks that require cancellation or joining,
including startup warm-up, search debounce and automatic labeling. Use the
existing `ShellModel`/`CoreClient` boundary rather than another scheduler.
Sources: [Swift concurrency](https://docs.swift.org/latest/documentation/the-swift-programming-language/concurrency/)
and [SwiftUI task lifecycle](https://developer.apple.com/documentation/swiftui/view/task(id:name:priority:file:line:_:)).

Cancellation is cooperative: check it before starting a superseded read and
before publishing its result. Preserve the existing request revision and
artwork/target identity checks because cancellation alone cannot exclude a late
response. A newer search cancels the older pending debounce; cancellation of
that delay must return instead of proceeding immediately. Expected cancellation
does not create a failure alert. Report an actual startup failure through the
existing connection/error presentation with an explicit retry; an ignored error
must not imply a ready core. UI publication remains on the main actor, and
blocking native/process work must not occupy that actor.

Beginning normal or updater-triggered quit quiesces the shared model and core
owner once. Stop new startup, debounce, refresh and automatic-labeling work;
cancel owned presentation/read tasks and prevent their late completions from
reopening a surface or starting more work. An already admitted mutation keeps
its command identity and authoritative completed/unknown outcome; presentation
cancellation neither rolls it back nor authorizes replay. Closing one view
does not shut down the app session or cancel an admitted command merely because
its initiating view disappeared.

If core exit remains uncertain and the user keeps the app open, the model stays
quiescing and mutation controls stay disabled. Retry Quit observes the retained
core as specified below. Cleanup of tasks and observers is idempotent; it must
not release process, token, credential or log custody before confirmed exit.

Acceptance extends the existing shell-model and owned-core fixtures with
delayed startup/search/preview responses, canceled debounce without a request,
superseded results, repeated quiescence, failure/retry presentation and an
admitted command whose reply becomes unknown. Confirm no new work or duplicate
mutation after quiescence and retain the existing real-process/modal-loop checks.
These local fixtures require no production update channel or signing identity.

The implementation retains shared startup, debounce, preview and metadata tasks
in `ShellModel`, with read cancellation at `LocalCoreClient` and quiescence
joined by `CoreTerminationCoordinator`. The Settings storage and similarity
owners also refuse new work. Seven lifetime fixtures and three command-reply
groups pass within all 98 Swift tests on macOS 27.0.1 arm64 / Xcode 27. The
real socket fixtures establish request receipt and unknown reply classification,
not server-side effect completion. Fresh packaging, authenticated IPC/offline
maintenance and the real deferred-quit fixture pass with the shared model
quiescent before confirmed core exit. Native focus, uncertain-alert interaction
and installed updater acceptance remain separate.

### Owned core termination

Normal quit and updater-triggered quit must quiesce the shell's owned core
before releasing its process, token, credential broker or log bridge. Once
termination starts, refuse new core exchanges and automatic restart. Signal
the retained owned launcher once and observe its actual exit; never equate a
successful signal send with a stopped core. Do not signal an externally supplied
developer core that the shell did not launch.

Use `applicationShouldTerminate(_:)` with `.terminateLater` and an asynchronous
reply on the main actor. Share concurrent stop requests under one ten-second
monotonic observation budget. The main actor must keep servicing events while
waiting. Deliver the reply through the main run loop, including when AppKit's
deferred-quit modal loop is nested inside an active main dispatch/actor job;
queuing another job behind that caller must not deadlock termination.
Only observed launcher exit permits cleanup and a positive termination
reply. The launcher must continue waiting for its owned OTP child; library and
native-worker shutdown still belong to that child, rather than an installer.

If the deadline expires or observation is cancelled without confirmed exit,
retain the launcher and credential/log custody, keep the shell quiescing, return
an explicit uncertain result and cancel normal quit. Give a fixed explanation
and explicit Retry Quit or Keep Open controls. A retry observes the same retained
process without sending another signal or replaying a library command. Do not
force-kill an unknown process, clear data or permit an update installation while
exit remains unconfirmed. Forced OS termination and physical power loss require
separate recovery evidence; this normal-quit handshake cannot prevent them.

Acceptance requires real process exit, cooperative TERM, a TERM-ignoring
process reaching the bounded uncertain result and later read-only recovery,
cancelled observation, main-actor asynchronous termination behavior, and a fresh
packaged host quit with its actual OTP/native children gone. Pure process fixtures
do not establish the last product-level condition or installed Sparkle behavior.
The maintained `core-quit-fixture.mjs` clones the freshly packaged app into a
private diagnostic stage, substitutes the release-built check executable and
uses the production coordinator. It requires ready/deferred/confirmed AppKit
events, exit zero, the previously observed OTP PID gone, its PID file removed
and unchanged original app/probe bytes. It invokes quit from an actor job to
exercise modal-loop delivery; no OS UI input or installed updater is involved.
An idle-core pass does not establish active native-worker shutdown, keyboard/
VoiceOver quit interaction or the ten-second uncertain-alert interaction.

### Native updater lifecycle

The application owns one main-actor `SPUStandardUpdaterController` and retains
its delegates. Use Sparkle's standard user interface behind the smallest shell
adapter needed by Settings/menu actions and fixtures. Development or otherwise
ineligible distribution profiles show an explicit unavailable state and perform
no update checks. Stopped-controller fixtures must remain available without a
live feed, production key or installation. Sources: [standard controller](https://sparkle-project.org/documentation/api-reference/Classes/SPUStandardUpdaterController.html)
and [update settings](https://sparkle-project.org/documentation/customization/).

Initial defaults belong in `Info.plist`; runtime preference setters respond to
user choices. Preserve Sparkle's standard permission flow and stored preferences,
and keep automatic checking distinct from automatic download/install. Do not
reset preferences on every launch or infer installation consent from permission
to check. Bind Check for Updates availability to the updater's published
`canCheckForUpdates` state; canceled/failed cycles cannot retain a false ready
state or overwrite a newer operation's presentation.

The existing signed-channel contract requires `SURequireSignedFeed` and
`SUVerifyUpdateBeforeExtraction` enabled, with
`SUSignedFeedFailureExpirationInterval` set to `0`. Retain the independently
pinned public key and admitted feed/artifact identity. Use documented delegate
hooks only where Frameshift needs to enforce that contract. A relaunch
postponement hook does not cover every installation/termination path, so normal
and updater-triggered quit both retain the owned-core exit guard. Sources:
[signed-feed settings](https://sparkle-project.org/documentation/customization/)
and [updater delegate](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html).

The existing `CoreTerminationCoordinator` owns the shared exit guard. Normal
AppKit quit and `prepareForUpdaterRelaunch(_:)` must quiesce the same model and
advertisements once, share one outstanding owned-core stop observation, and
proceed only after confirmed direct exit. Keep the normal AppKit reply and
updater completion distinct. Deliver them through the main run loop's common
modes so a nested termination/modal loop cannot starve a main-dispatch task.
Confirmation can be retained for this one shell/core lifetime; an uncertain
observation must allow explicit later read-only retry without unpausing work or
replaying a signal or installation action.

Allow only one pending updater completion. A second pending request refuses
without replacing it. Return a request UUID for cancellation; cancellation of
that exact pending callback suppresses its installation continuation but does
not cancel the shared core observation, discard core custody or resume artwork
work. A stale UUID cannot cancel a newer request. Completion must consume its
pending callback before invocation, and a stale exit-job delivery cannot clear
a newer job. If exit is already confirmed, normal quit consumes any queued
updater continuation before returning `.terminateNow`; its later queued delivery
must have no second effect. Unknown/uncertain exit never invokes an installation
continuation as confirmed. The adapter owns its uncertainty/cancellation UI and
must retain its SDK handler for review or invalidate it when its operation ends.
This hook can be skipped by Sparkle, so the normal termination guard is required
independently. No installed-update or descendant-exit claim follows from this
in-memory coordination.

Acceptance checks actual packaged defaults and preserved user choices, disabled
and stopped setup, repeated checks, canceled/failed cycles, stale completion,
and deferred/uncertain/confirmed core exit. Join valid and tampered signed-feed
fixtures to the actual pinned SDK. Installed direct/Cask/Sparkle updates, native
Intel/older-system execution and production signing remain separate R2 gates.
The Cask and direct channels continue to consume the same DMG; this review does
not introduce a Homebrew subprocess updater.

The shared `CoreTerminationCoordinator` API now passes five focused groups within
all 108 Swift tests in 24 suites on macOS 27.0.1 arm64 / Xcode 27. Pending
replacement refusal, uncertain exit and explicit retry, matching/stale
cancellation, canceled queued confirmation and immediate normal quit before
queued confirmation preserve one-shot continuation and quiescence semantics.
All 102 Mac release fixture groups pass without exclusions. The final fresh
native package, authenticated IPC/offline maintenance and both normal/shared
updater callback AppKit probes pass; the latter records its continuation before
the normal quit reply, with the actual launcher exited, OTP PID absent and PID
file removed. Original app/probe bytes and strict seals remain unchanged by the
probe. This updater callback join uses the production core coordinator, not a
running Sparkle installer. Actual SDK startup/preferences/cycles, signed-feed
runtime tamper, native UI, installed updates and production qualification remain
independent H3-L3/R2 work.

#### Signed channel admission and initial defaults

Before constructing a running updater, compare the app's `SUFeedURL` and
`SUPublicEDKey` with separately supplied release pins. The pin source and
distribution eligibility belong to the qualified release/runtime integration;
neither a plist boolean nor this parser establishes signing, notarization or
installation evidence. An absent pin, development profile or invalid channel
leaves updates explicitly unavailable and starts no SDK. Do not manufacture a
production key or use a sample channel as a shipping fallback.

Admit a bounded HTTPS feed string of at most 2,048 UTF-8 bytes, with a lowercase
ASCII DNS host, no credentials, query, fragment, control characters or backslash,
and unchanged Foundation URL serialization. Reject an empty/invalid DNS label,
trailing dot, explicit default port and invalid port. Require a canonical base64
encoding of exactly 32 public-key bytes. The app metadata must match both pins
exactly; a valid alternative channel/key still refuses.

Require actual CFBoolean `true` for `SURequireSignedFeed` and
`SUVerifyUpdateBeforeExtraction`, actual CFBoolean `false` for
`SUAllowsAutomaticUpdates`, `SUAutomaticallyUpdate`, `SUSendProfileInfo` and the
initial `SUEnableAutomaticChecks`, and a nonboolean finite numeric zero for
`SUSignedFeedFailureExpirationInterval`. These are initial bundle defaults,
not values to write into user defaults on every launch. Preserve the user's
subsequent automatic-check choice independently of automatic download/install.
The native adapter must return the admitted feed through Sparkle's documented
delegate hook so a stored URL override cannot change the channel. Do not add
feed parameters or delete stored preferences.

The pure shell gate must remain SDK-free and perform no network, preference,
Keychain or signature operation. Acceptance checks actual packaged/default
metadata, scalar types, exact pins, URL/key bounds and malformed values. Actual
controller startup, preference/KVO/cycle behavior, signed-feed tamper, UI/quit
and installed update remain separate joins.

`SignedUpdateChannel` now implements this SDK-free gate. Five groups pass within
all 103 Swift tests in 23 suites on macOS 27.0.1 arm64 / Xcode 27. Real XML/binary
metadata, actual source and freshly packaged defaults, exact independent pins,
boolean/numeric types, canonical base64, DNS/port/URL refusal and the actual
2,048/2,049-byte boundary pass without modifying the input. Foundation permits
empty and overflowing ports to appear as absent; comparing the original
canonical authority closes that observed ambiguity. All 102 Mac release fixture
groups pass without exclusions, with fresh ad-hoc closure/seals, packaged IPC
and actual core quit. No production feed/key or running updater is configured;
SDK adapter, user-choice/cycle/UI/quit joins and runtime signed-feed tamper remain
H3-L3 work, alongside separate packaging/installed release gates.

## Discovery and pairing

The Swift layer uses Bonjour/Network framework to browse privacy-minimal WoT
Introduction records. The core retrieves and admits the full TD only after
binding authentication, then selects interactions from its Forms. Full metadata
appears only after authorization. Pairing
shows the selected physical QR image for explicit confirmation, requires the frame's physical
pair mode, stores host credentials in Keychain, and records a friendly name
only on the Mac unless the user explicitly writes it to the frame.

The native discovery list treats Bonjour TXT as an untrusted hint. It accepts
only the bounded v0.1 reference keys and an HTTPS introduction path, limits
the visible set, and withholds duplicate device IDs from selection. A row may
show physical pair-mode availability, but it never claims a frame is paired
or safe to contact from the advertisement alone. Browsing starts while the
pairing settings are visible and stops when they close. The installed app
declares its Bonjour service and local-network purpose to macOS. After an
explicit selection, the shell resolves that exact service under a deadline to
a bounded local HTTPS origin; the core still re-resolves the host, admits only
local addresses, and verifies the QR-pinned frame key before sending a secret.

The physical bootstrap secret crosses the authenticated local socket only in
transient pairing or explicit read-only recovery operations. It is parsed under
the protocol bounds and must never enter the durable command receipt, audit,
native log, or metric record. The operation matches the selected discovery ID
to the QR record,
resolves a Keychain identity at the transport boundary, pins the frame's SPKI
before sending the secret, retrieves the fixed authenticated TD introduction,
checks its device ID and reference HTTPS origin, then commits the paired record.
A TD that changes the credential audience is refused. A failed or uncertain
network exchange must not invent a paired target. The shell retains no QR
secret after the operation completes.

After an uncertain or incomplete exchange, Settings offers an explicit
"Recover pairing" action. It asks for the physical QR image again, confirms
the selected image, and performs only an authenticated TD read. It does not
retry the one-time pair POST or assume that the frame accepted it. The user
can run recovery even after physical pair mode closes.

For the local reference binding, the Mac creates one P-256 host key in
Keychain and a bounded self-issued X.509 certificate with client and server
authentication purposes. It reuses that identity for paired frames and the
host outbox. The private key never crosses the local broker or enters a file;
OTP receives only the certificate and a bounded signing callback. Keychain
denial or an incomplete certificate/key record fails closed. Identity rotation
remains an explicit authenticated operation rather than an automatic retry.

The core starts the host outbox listener only while a pull-capable frame is
paired to one shared host identity. It uses the same broker signing callback,
chooses an available local port, and reports its bound port through the
authenticated read-only local IPC. The shell advertises that port through a
privacy-minimal Bonjour record while it is available. A failed listener or
broker lookup does not invalidate paired records or pending work. A Bonjour
publication failure is retried with a delay while the listener remains active;
the shell withdraws the record when the listener becomes unavailable.

USB commissioning is allowed for initial Wi-Fi and identity setup. A cable used
during commissioning is not an installed power architecture.

## AI integration

Provider selection and fallback policy live in Settings, not in the compact
popover. Local execution is preferred. The effective provider, exact model,
download/storage requirement, license, destination, and cost class are visible
before first use.

The host never treats a consumer ChatGPT or Gemini subscription as API access.
It never automates provider websites. Manual image import is always supported.
See [AI image generation research](../research/ai-image-generation.md).

## Labeling and search

Apple Vision performs default on-device classification and image feature-print
generation. Machine labels retain confidence and Vision revision. User labels
are never overwritten. Search combines literal title/label terms, frame/profile
filters, pinned state, and optional local visual similarity.

Cloud labeling is a separate explicit opt-in and is disabled by default.

## Security and privacy

- Keychain stores provider tokens and frame client identities.
- Prompt text and source images remain local unless the selected job explicitly
  names a cloud provider.
- Logs contain digests and typed operation IDs, not artwork bytes, prompts,
  tokens, bootstrap secrets, Wi-Fi credentials, or private filesystem paths.
- The shell and core write operational logs to Apple unified logging for
  Console.app and `/usr/bin/log`; persisted audit and metrics remain separate.
- Imported metadata is parsed as untrusted input.
- Frames can access only rendered outbox artifacts addressed to their identity,
  not the general host library.
- Deleting a library item is recoverable until trash retention expires.

## Packaging gates

### Mac release tooling implementation

Swift owns build-time Mac closure inspection, pinned SDK/cache admission,
private CPU derivation, universal assembly, app sealing and DMG construction.
Portable source/manifest/receipt/archive policy and channel rendering/signing
have one [Elixir owner](../architecture/release-manifest.md#release-tooling-ownership-and-migration).
The application remains a thin Swift/SwiftUI shell; release tools must not link
`FrameshiftShell`, start its Elixir core, or ship in the application bundle.
The [research](../research/software-stack.md#release-tooling-language-boundary)
records the rationale and unqualified adapter work.

The separate package is `release/macos/Package.swift`, with the reusable
`FrameshiftMacRelease` library, `frameshift-mac-release` executable and package
tests under the selected Xcode/Swift toolchain. Its `mac-release` workspace owner
and validation lane have no application dependencies. The descriptor/hash
foundation below exists; full inspection and packaging ports remain open. Keep
command parsing inside that package; introduce a pinned parser dependency only
for demonstrated needs.

Preserve existing `scripts/check-macos-closure`, packaging and source-admission
interfaces, argument meanings, exit codes and record profiles. Wrappers remain
small POSIX shell commands. Cut over each wrapper only after its Swift command
and shared dependencies pass the [migration gates](../architecture/implementation-plan.md#release-tooling-migration);
the replacement must not invoke the former Node command internally.

Native readers must use descriptor-based no-follow, nonblocking admission,
finite byte/entry/depth budgets, checked integer arithmetic and pre/post named
and descriptor custody. Foundation pathname reads alone do not establish this.
Use typed property-list decoding and bounded Mach-O parsing for admitted
profiles. Retain exact framework aliases, original SDK bytes, derived CPU bytes
and regenerated seals as distinct facts. Evaluate SwiftPM manifests in private
scratch without repairing or resetting the original compiler workspace.

Signature verification must explicitly inspect both universal CPU slices,
every OTP/NIF/renderer role and the fixed nested Sparkle containers. A
`SecStaticCodeCheckValidity` adapter must request the applicable strict,
all-architecture and nested checks and separately validate code outside normal
bundle locations. It must preserve the selected signature/trust profile and
custody checks. Adoption of that API instead of `codesign` requires parity
tests; merely calling the API is not acceptance. Static signatures do not
prove loader closure, older-OS symbols, notarization or installed execution.

Invoke Apple `codesign`, `ditto`, `lipo`, `hdiutil`, `xcrun notarytool` and
`xcrun stapler` through fixed executable/argument arrays and the selected
toolchain. Do not interpret records as shell commands or reproduce Apple's
signing/notarization algorithms. Observe monotonic deadlines, bound and drain
stdout/stderr concurrently, close child input and retain custody until actual
exit. Deadline/cancellation failure must preserve private incomplete state and
the previous accepted output. Shell wrappers must not grow binary parsers or
receipt state machines.

Qualification ports the existing compiled Mach-O, real SDK, strict nested-seal,
mutation, child-timeout, archive readback and replay fixtures. Tests must
compare unchanged public bytes and refusal/retention behavior, including a
corrupt nested resource hidden beneath a resealed outer app and a wrong
non-native CPU slice. Actual native Intel/arm64, supported older OS,
credentialed signing/notarization and installed update proof remain separate
release gates. Existing Node test results do not qualify the Swift port.

### Native release input foundation

`AdmittedFile.read(_:policy:)` admits at most 16 MiB into memory;
`AdmittedFile.sha256(_:policy:)` streams at most 8 GiB through 64 KiB blocks.
Each consumer supplies a smaller explicit minimum/maximum where its profile
requires one. `FileReadPolicy` refuses negative/inverted/overflowing bounds and
nonfinite, nonpositive or over-900-second budgets before accessing a path.
Leaf admission uses `lstat`, `open(O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)`
and `fstat`. It accepts regular files only and compares device, inode, size,
mode, owner/group, link count and nanosecond modification/change times before
and after the stream. Short reads, growth, replacement and metadata changes
refuse, and every opened descriptor closes on success or failure.

The caller selects ordinary regular-file policy, protected root/current-user
ownership with no group/other writes or special permission bits, or a private
current-user file with mode 0400/0600 and one link. Other profiles may also
require one link. Parent-directory identity/aliases remain the consuming
operation's responsibility; this leaf reader does not claim that boundary.
Monotonic deadlines are checked between synchronous filesystem calls. They do
not preempt an already blocked kernel or filesystem operation.

`frameshift-mac-release verify-sparkle-archive ARCHIVE` uses protected single-link
admission and the exact pinned 10,193,895-byte Sparkle 2.10.0 ZIP/SHA-256. Its
only success output is `Sparkle 2.10.0 archive verified` plus LF. Usage failures
exit 64; admission failures exit 65 with a fixed category containing no paths,
input content or key material. It performs no fetch, extraction, SwiftPM
resolution, cache repair or write. Success establishes archive bytes/custody,
not SDK closure, signing, runtime integration or an installed update.

`AdmittedFileTests` exercise FIFO/device/directory/symlink refusal, replacement
between naming/opening and after opening/reading, truncation/growth/same-byte
rewrite, permission changes, hard links, sparse oversize files, invalid bounds,
monotonic expiry and descriptor cleanup. Independently running the CLI on the
pinned actual ZIP joins this foundation to upstream bytes. Native closure,
closure and SDK ports require their own acceptance before a release wrapper
switches. Owned-process and property-list foundations are defined below.

### Native release child custody

`AppleCommand` selects a fixed `/usr/bin/` Apple executable and a literal
argument array. It admits at most 256 arguments, 8 KiB per string and 256 KiB
aggregate argument bytes; NUL and relative working directories refuse. Native
consumers own command-specific semantics and selected SDK evidence. No shell
command string or record-selected executable is interpreted. Child environment
keeps a fixed system PATH/locale and only HOME/USER/LOGNAME/TMPDIR/DEVELOPER_DIR/
SDKROOT context; DYLD and language-runtime hooks are excluded.

`OwnedCommand.run(_:limits:)` owns one direct `posix_spawn` launch attempt. It
closes stdin, closes unrelated inherited descriptors and drains separate
nonblocking stdout/stderr pipes in finite fair turns. Default capture is 64 KiB
per pipe and 30 seconds; validated limits cap at 16 MiB per pipe and 900 seconds.
The monotonic budget starts before spawn. As with file admission, a synchronous
kernel spawn call cannot be preempted by this library. The Mac 14 deployment
build uses the older working-directory extension before Mac 26 and the standard
API from Mac 26; compilation is not proof of an older installed tool host.

Success requires `waitpid` to reap exit zero and both output pipes to reach EOF
within the deadline. Nonzero/signal exit, output flood, cancellation and deadline
return a fixed refusal. A refusal requests TERM at most once for this unreaped
direct child; it never escalates or signals a process group. The retained monitor
continues bounded draining/discarding and observing actual exit after the caller
receives a refusal. A TERM request does not change custody to stopped. This
monitor lasts within the running tool process; its existence is not a durable
cross-process recovery journal.

`status()` reports not-started, running PID, reaped exit/signal or unconfirmed
custody. `observeExit(seconds:)` observes that same child without another signal,
restart or command replay. A used owner refuses another launch. Unexpected
wait/reap failure reports unconfirmed custody and permits no further signal.
Traced stop notifications are not classified as exit. When a reaped child's
pipes remain inherited by a descendant, refuse incomplete output after 200 ms
and close the readers; direct-child exit does not establish descendant exit.

For a one-shot CLI, keep the failed command's ownership objects alive until each
started direct child has a confirmed reaped exit. Print the existing fixed
refusal immediately and emit no observation. `retainUntilExitAfterRefusal()`
performs read-only retention outside the failed admission budget, ignores caller
task cancellation, and never signals, restarts or replays an effect. Not-started
and reaped owners permit error exit; running or unconfirmed custody does not.
Do not claim a finite process-exit deadline for a child that will not stop or a
custody error that cannot be resolved. An external termination of the tool leaves
its scratch incomplete and does not establish child/descendant exit; the monitor
is still process-local, with no PID-only recovery or cross-process journal.
Expose borrowed ownership for the Sparkle archive child and both SwiftPM capture
phases so the CLI can retain the actual objects used by the library. A late zero
exit permits only the original error exit; it never admits late bytes or deletes
the failed scratch. Independent finite GUI observations keep their existing
cancellable `observeExit(seconds:)` semantics.

A failed native producer must keep its private incomplete stage and the previous
accepted output, even if the failed child later exits zero. It must never promote
that late output or assume cancellation stopped an effect. A fresh invocation
refuses retained partial state under the producer's owning profile. The twelve
`OwnedCommandTests` cover both-pipe pressure/closed stdin, each-pipe floods,
deadline/actual exit, ignored TERM and late private-stage mutation, exactly one
TERM across read-only observations, cancellation before/after launch, nonzero
exit, inherited-pipe refusal, failed-launch descriptor cleanup, selected Xcode
execution, working-directory isolation and argument/limit refusal.

The CLI now borrows and retains the exact library ownership objects for manifest
and original-archive extraction. Two additional retention groups pass within all
78 Mac release-tool tests on macOS 27.0.1 arm64 / Xcode 27 with both actual SDK
inputs and no exclusions. A controlled child handles TERM once, remains running
through cancellation of the retaining caller, writes only its late pending bytes
and exits zero; retention observes that actual exit without another signal,
relaunch, accepted-file change or output promotion. Unused, already reaped and
failed-launch owners return their known status. Actual pinned extraction and
SwiftPM capture expose the actual stopped phase owners through the public API.
Release-built CLI facts still match all retained SDK/compiler bytes with complete
input custody unchanged; early failure and failure after actual manifest exit
preserve fixed text/no observation and the original malformed state. The active
ignored-TERM lifetime is shared-owner test evidence, not a claim that the pinned
Apple tools ignored TERM in that CLI experiment. Unknown custody and external
termination remain incomplete states; no cross-process or descendant proof is
established by this local retention change.

### Native release property lists

`NativePropertyList.read(_:protection:)` uses the admitted protected single-link
file reader with a 64 KiB cap. `decode(_:)` accepts an immutable XML or bplist00
root dictionary and returns typed `NativePlistValue` strings, booleans, signed
Int64 integers, finite reals, arrays and dictionaries. Numeric 0/1 are not
booleans. Preserve Unicode value bytes and reject duplicate or canonically
ambiguous dictionary keys instead of silently collapsing them. Data/date/UID/
set/null, OpenStep, unsupported markers and non-dictionary roots are outside
this native metadata profile. This is not a portable release-wire encoder.

Before Foundation decoding, bound the reachable graph to depth 32, 8192 expanded
nodes and 1 MiB expanded UTF-8 string payload. The binary preflight checks trailer
counts/widths, exact offset-table extent, distinct in-range object offsets,
object/ref extents, extended-length arithmetic, dictionary keys and ancestor
cycles. Repeated references count toward expansion rather than bypassing limits.
XML preflight validates element/key/value structure and bounds depth/nodes/text.
Disable external resolution and reject entity declarations/references even if
unused; the ordinary Apple plist DOCTYPE remains admitted without loading its
external DTD. Validate XML integer range before Foundation can narrow it.

Foundation decodes the admitted bytes without a pathname reopen. Typed conversion
rechecks graph/type/range limits. Bound its compact JSON-compatible metadata to
256 KiB, retaining the current converter's output cap; these internal size-check
bytes are never emitted as a release record or signature message. Foundation's
synchronous calls are not preemptible. This finite-input/graph qualification
makes no measured whole-job RSS claim. Plist, offset, expansion, duplicate-key
and field-type failures return a fixed category without private input content.
Sources: [Apple plist formats](https://developer.apple.com/documentation/foundation/propertylistserialization/propertylistformat),
[external entity policy](https://developer.apple.com/documentation/foundation/xmlparser/externalentityresolvingpolicy-swift.property)
and [pinned binary-format source](https://github.com/apple/swift-corelibs-foundation/blob/b2112d2d80c4365dbb32479d89bb3177bfda8ea8/Sources/CoreFoundation/CFBinaryPList.c).

`frameshift-mac-release verify-sparkle-plist PLIST` checks seven exact typed
identity fields of the pinned framework: identifier/executable/package type,
display version 2.10.0, build 2064, declared minimum 12.0 and MacOSX platform.
Its fixed success line is `Sparkle 2.10.0 plist identity verified` plus LF; usage
and admission exits remain 64/65. It does not establish native CPU minimums,
whole-framework bytes, cache/archive equality or signatures. Those separate
closure/SDK gates remain required. The nine `NativePropertyListTests` qualify
Apple-generated XML/binary values, exact type/Unicode preservation, duplicate
keys, entity refusal, malformed/cyclic binary references, all truncations,
integer/real/type refusal, exact depth/node/metadata bounds, descriptor custody
and typed SDK identities. Independently run the command on the actual pinned
SDK Info.plist; fixture identities alone do not prove that upstream input.

### Native release loader metadata

The Swift release owner ports the existing bounded loader observation before
the whole-bundle gate changes. `MachOInspector.inspect(_:)` uses the same
no-follow/nonblocking descriptor custody as file admission and reads only
bounded regions, not a whole native file into memory. File size caps at 128 MiB,
each region at 1 MiB, reads at 64 KiB and the admission budget at 60 seconds.
An internal synchronous borrowed view exposes no descriptor, is not Sendable,
and refuses after its scope closes, including if the descriptor number is reused.

Admit little-endian 64-bit thin Mach-O and big-endian 32/64-bit fat tables with
one or two distinct arm64/x86_64 slices. Fat offsets, lengths, alignments,
reserved fields, containment, overlap and exact table/header CPU agreement must
validate before allocating command bytes. Accept arm64 subtype 0 and x86_64
subtype 3 or `0x80000003`; specialized or other CPU profiles refuse. Supported
file types are executable, dylib and bundle, with 1–4096 commands whose total
is at most 1 MiB per slice. Every command is contained, at least eight bytes,
eight-byte aligned, and the declared count consumes the exact command region.

Observe ordered dylib imports and run paths as nonempty terminated UTF-8 strings
of at most 512 bytes without U+0000–U+001F or U+007F. The dynamic linker must be
`/usr/lib/dyld`. Retain the existing unsupported-loader-command refusals. Require
one macOS deployment command: exact legacy minimum layout or exact build-version
layout with macOS platform and at most 32 tool entries. Preserve its packed
major/minor/patch value, with major at least 10. Other structurally valid commands
are skipped under this metadata profile; instruction, symbol, segment, code-sign
and runtime dyld validation are separate. Source layout: Apple cctools
[loader.h](https://github.com/apple-oss-distributions/cctools/blob/e0d56624eca2a76c2ace4c21850df9e666de4ca5/include/mach-o/loader.h)
and [fat.h](https://github.com/apple-oss-distributions/cctools/blob/e0d56624eca2a76c2ace4c21850df9e666de4ca5/include/mach-o/fat.h),
inspected through `gh` on 2026-10-06.

Return slices sorted by architecture with the unchanged observation fields
`arch`, `filetype`, `minimum`, `dependencies` and `rpaths`. The standalone
`frameshift-mac-release inspect-macho INPUT` emits that bounded JSON array plus
LF; output caps at 16 MiB, and usage/admission exits remain 64/65. It does not
execute the input, resolve imports, repair a binary, validate a signature or
grant publication authority. The whole closure and wrapper cutover remain RT2
work. Acceptance requires malformed thin/fat/string/deployment and truncation
refusals, descriptor mutation/deadline/cleanup, borrowed-view reuse refusal,
actual compiled arm64/Intel/universal metadata and pinned SDK parity against the
retained parser. Intel metadata is not Intel execution proof.

Ten `MachOInspectorTests` pass within the 43-test Swift release package gate.
They include real compiled CPU/universal inputs and actual descriptor-number
reuse after the borrowed view closes. The release-built CLI matches retained
observations on 34 real compiled/SDK/app files and 40 CPU slices while preserving
hashes and inode metadata. The actual pinned Sparkle ZIP also verifies. This
qualifies the bounded metadata observer; the following whole-bundle admission
and SDK/signature ports retain their separate RT2 gates.

### Native closure admission

Before accepting a development or release bundle, inspect every regular file
for Mach-O code, including dynamically opened OTP NIFs. The local static gate
is `scripts/check-macos-closure APP arm64|x86_64|universal`. Its JSON observation
records directory paths/modes, relative file identities, CPU slices, native
deployment minima and
loader references; it grants no publication authority. Required code includes
the shell, CLI, renderer, one OTP emulator, SQLite NIF, Exile NIF and spawner.
Every native item must contain the selected CPU, or both CPUs for `universal`.
Specialized CPU subtypes, non-macOS platforms, objects and malformed or
unsupported Mach-O loader metadata refuse rather than becoming compatibility claims.

The Swift replacement is `NativeBundleInspector.inspect(_:architecture:)` in
the separate release-tool package. Its directory walk must stream bounded
`readdir` entries through an admitted no-follow directory descriptor rather
than allocate an unbounded pathname listing. Keep each directory's identity
checked against its descriptor and name before/after its children. Reuse leaf
descriptor/hash/header/plist owners and repeat the complete tree inventory;
do not treat an unchanged file list alone as unchanged source custody.

Preserve schema-two observation fields, array traversal order and native load
order. The native observation renderer must reproduce the existing JSON member
order and string/number bytes because retained bundle observations are hashed.
This is a fixed native observation format, not another portable receipt encoder.
The implemented `frameshift-mac-release check-bundle APP CPU` command uses the
existing closure usage/refusal exits 64/1 and fixed refusal text. Only after
whole-profile parity may `scripts/check-macos-closure` dispatch to it. SDK
resource/cache/archive and signature admission retain their additional gates.
`scripts/check-macos-closure` now dispatches to the qualified native inspector.
Preserve its exact argument count, CPU selector, usage/refusal text and exits.
Resolve relative app paths from the caller's physical working directory before
SwiftPM changes its own directory. Build the separate release-tool product with
Apple's selected toolchain and automatic resolution/netrc/Keychain use disabled,
then execute the completed release binary directly. SwiftPM's concurrent lock
messages must not enter native observations or fixed admission errors. A failed
tool build returns the existing refusal with no observation; the `mac-release`
check lane exposes compiler diagnostics separately. This is developer tool
setup outside the inspector's job budget, with no shipped SwiftPM/Node runtime.
Retained Node library consumers still require their individual native joins.

The two selected wrappers pass all fifteen existing closure/resource test groups
on macOS 27.0.1 arm64 / Xcode 27 with actual resource input and no exclusions.
Actual arm64/Intel/universal compiler-role inputs preserve exact observation
bytes and 64/1 messages through absolute and caller-relative invocation with
Node unavailable. Concurrent setup/admission remains quiet. The retained full
native host's 1,419 files and 24 native records reproduce all schema-two bytes
on both path forms with every original identity unchanged. This qualifies the
inspection entry point; retained packaging/receipt library callers, actual
SDK-bearing host/around-compiler integration, native Intel/older OS and installed
release retain their separate acceptance gates.

The observation is bounded to 16 MiB including the command's final LF. String
escaping preserves exact Unicode bytes and traversal uses UTF-16 lexical order,
matching the retained format. Typed property-list admission deliberately refuses
malformed/ambiguous metadata before it can become a closure fact.

Six `NativeBundleInspectorTests` groups pass within the 49-test release-tool
lane on macOS 27.0.1 arm64 / Xcode 27. Actual compiled arm64, Intel and universal
bundles, a universal fixture containing the pinned real SDK, and the fresh
development app match the retained observer's schema-two bytes exactly.
Additional Unicode/escaping, malformed SDK alias/role, missing/duplicate code,
outside/missing/inherited imports, false minimum, mode/link/FIFO/sparse input,
native-count, exact 8,192-entry boundary, same-byte rewrite and added-empty-tree
refusals preserve input custody. These checks establish static observation
parity; they do not prove SDK resource/archive equality, signatures, code
execution on Intel/older macOS or installed update acceptance.

This initial closure profile accepts Apple system imports below `/usr/lib/`
and `/System/Library/`, and bundle-contained loader-relative imports. An
executable-relative import is admitted only in an executable, whose launch
context is explicit. The target must be an inspected dylib with the matching
CPU. Inherited `@rpath` imports are unavailable: an ambiguous run-path stack
must never be guessed. The explicit Sparkle profile below admits its one shell
import through the shell's own declared framework directory. Search paths outside the bundle or Apple
system directories refuse, including unused developer-toolchain paths.
System imports are recorded, not proved to exist or supply symbols on an older
OS. Dynamically constructed loads still require their own runtime fixtures.

Admission is bounded to 8,192 entries, 32 directory levels, 512-byte relative
paths, 128 MiB per file, 512 MiB total file bytes, 128 native files, two CPU
slices and 1 MiB of load commands per slice. Files and directories must be
regular, without links or group/world writes, except the exact versioned
framework symlinks below. The reader checks descriptor and
named-file custody, records SHA-256 and modes, and repeats the entire inventory
after inspection. Its two-minute monotonic processing budget is a software
check, not a promise to interrupt a stalled filesystem syscall.

`LSMinimumSystemVersion` must be at least the greatest native minimum in the
bundle. Development packaging requests macOS 14 for the renderer and locally
compiled NIFs, then derives the declaration from the actual closure; a newer
OTP minimum remains visible. It must never lower a Mach-O deployment header
to manufacture support. Only a private disposable packaging stage may remove
an unused RPATH under the selected Xcode compiler toolchain, and only when
that native file has no `@rpath` imports. Changed code is signed from nested
leaves outward before the app signature and the final closure check. A failed
build or admission preserves the previously accepted app.

Acceptance requires actual small arm64/x86_64 and universal Mach-O fixtures,
missing/wrong CPU, unsupported platform, malformed lengths, outside/missing
loader targets, links, oversized input and false OS declaration refusals.
The real fresh development app must then pass closure and packaged IPC,
import, restart and offline maintenance checks on the observed Mac. Those
checks do not qualify macOS 14, Intel execution, universal OTP/NIF packaging,
Developer ID, hardened runtime, notarization or installed DMG/update behavior.

### Private native development preparation

The native producer prepares only `Frameshift.app` inside a real current-user,
mode-0700 `.package.` directory with an alphanumeric suffix. Retain its directory
descriptor and complete named identity throughout the job. It never publishes,
replaces an accepted app or removes a failed stage. A one-shot caller retains
the exact last child after refusal until direct-child exit is known, as defined
by [child custody](#native-release-child-custody).

`scripts/package-macos` builds the dependency-free release tool separately, then
calls `prepare-development-bundle` and the native final `check-bundle` directly
for its current SDK-free development app. It invokes no Node preparation command.
Its failure/interrupt trap reports and retains `.package.*` work; it does not
remove a stage whose child custody or admission failed. Only successful
preparation and final closure allow the existing local artifact replacement.
An externally interrupted shell/tool does not establish child or descendant
exit. Candidate/source-bound producers remain separate consumers; SDK inclusion
must select its explicit updater profile and original/compiler/CPU gates.

Use the selected `/usr/bin/xcrun --find swift` result to identify its canonical
`usr/lib/` prefix. Before mutation, admit the complete bounded closure with only
two preparation exceptions: its plist may understate the actual native minimum,
and unused canonical search paths below that exact prefix may remain. Any native
file containing both a removable search path and an `@rpath` import refuses.
Foreign search paths, unresolved imports, malformed metadata, CPU/role errors
and unsafe input retain their strict inspection refusals. This is an internal
producer admission, never a public inspection-policy bypass or an admission of
the separately observed Swift updater shell.

Remove signatures before deleting those search paths with fixed Apple tools.
Set only `LSMinimumSystemVersion` to the greatest actual native minimum, preserving
every other typed plist value. Never alter deployment headers or imported names.
Sign native leaves except the outer main executable, fixed pinned SDK containers
inside out, then the outer app. Complete closure and strict all-architecture,
nested signature admission must pass before returning the prepared observation.

Complete inventory/custody checkpoints bracket each command. Only the command's
named native file, plist or fixed container `CodeResources` seal may change;
only its fixed `_CodeSignature` directory may be created or removed. Preserve
all other file identities and bytes, exact aliases, native roles, modes, CPU
membership, deployment minima and imports. Directory identities and modes remain
stable; timestamp changes are permitted only on ancestors of the command's
mutable paths. A private stage has one writer; these checks detect observed
interference rather than making concurrent writes to the tool's own mutable
target safe.

The job admits at most 512 child launches within a five-minute monotonic budget,
with 15 seconds and 64 KiB separately per output pipe for each child. Check
cancellation between phases and operations; no failed or cancelled result can
promote late child output. Budgets do not preempt blocked filesystem or Security
calls. Acceptance requires real arm64/Intel/universal preparation and exact final
closure observation, actual nested SDK seals, wrong-stage/loader/typed-metadata
refusal, unrelated and final mutation refusal, cancellation and retained child
exit. Producer/library cutover and fresh full-host lifecycle remain separate
checks before this command replaces retained packaging consumers.

Seven `DevelopmentBundlePreparerTests` groups pass within all 85 release-tool
tests on macOS 27.0.1 arm64 / Xcode 27 with actual SDK/resource inputs and no
exclusions. Actual arm64, Intel and universal preparation matches every retained
schema-two byte and the exact success line. The real pinned universal SDK's
five code roles and nested containers receive strict complete seals. Wrong
stage/mode/alias, foreign/noncanonical paths, run-path imports, unrelated
same-byte/namespace/parent and final mutation, actual child deadline and
cancellation after real plist preparation refuse while retaining stage/custody.
A private copy of the retained full host also matches all 1,419 files/24 native
records with strict seals and unchanged original identities. This is local
producer/static evidence; fresh host lifecycle and packaging/library cutover,
Swift updater loader profile, CPU merge, DMG and installed release remain open.

The SDK-free development packager cutover passes on macOS 27.0.1 arm64 /
Xcode 27: fresh native preparation and strict seals produce 1,419 files and
24 native roles with the actual macOS 15.0.0 minimum. Packaging and packaged
IPC/offline maintenance pass with a deliberately invalid Node startup option;
authenticated import/snapshot, backup/verify/restore refusals and actual deferred
AppKit quit with launcher exit/OTP PID removal pass. An isolated fixture executes
the actual packager trap/admission/publication tail with a deliberately broken
native role: refusal preserves the failed stage and every prior output identity,
with no output promotion. This tail fixture does not simulate a complete compiler
failure or external process interruption. Current development packaging does
not include the SDK; source-bound candidate and updater joins remain open.

#### Swift updater shell preparation profile

Select `swift-updater-shell-preparation-v1` explicitly through
`DevelopmentBundlePreparer.prepareSwiftUpdater(_:architecture:)` and the
`prepare-swift-updater-bundle` tool command. It is a distinct native producer
operation; a retained producer receipt cannot be relabeled as its execution.
The archive/cache/source admission remains required before using the SDK, and
the completed native observation retains the strict existing closure profile.

Admit only the main `Contents/MacOS/Frameshift` executable with the fixed pinned
framework shape/aliases, exact Sparkle import and a recorded absolute
`/usr/lib/swift/libswiftCore.dylib` import in every required slice. Its only
`@rpath` dependency must be `@rpath/Sparkle.framework/Versions/B/Sparkle`, resolving
to the inspected owned framework with matching CPU. For this observed toolchain,
accept only these ordered incoming search paths: `/usr/lib/swift`, optionally
the selected Xcode compiler's `usr/lib/swift-6.2/macosx`, then exactly one own
`@loader_path/../Frameworks` or `@executable_path/../Frameworks` path. Another
runtime-directory revision requires new evidence/profile qualification.

Remove the first two paths in the private stage after signature removal, leaving
only the owned Frameworks path. Preserve every import, native deployment header,
CPU/type, common SDK byte except the fixed regenerated seals, and alias; sign and verify with the same command,
custody and budget rules above. Other native files retain the original rule
that removable selected paths combined with any `@rpath` import refuse. Do not
infer inherited or external run-path resolution, rewrite imported names or
relax public inspection. A missing SDK, another imported/search path, noncanonical
runtime path or ambiguous role refuses before mutation. Already prepared/replayed
output is admitted read-only by its receiver, not prepared again under a fresh
producer claim.

Acceptance requires actual Swift and SwiftPM-produced shells linked to the
pinned SDK, both CPU/universal metadata, preserved original inputs, exact final
strict closure/seals, malformed/import/path/profile refusal and an arm64 stopped
standard-controller execution after preparation. Local execution does not prove
Intel/older-OS symbols or dynamically constructed system loads; production and
installed update retain their separate matrix gates.

Four `SwiftUpdaterPreparationTests` groups pass within all 89 release-tool
tests on macOS 27.0.1 arm64 / Xcode 27, with actual SDK/resource inputs and no
exclusions. Actual direct Swift fixtures exercise both observed input profiles
for arm64, Intel and universal metadata, exact final strict closure/seals and
stopped-controller execution on the native CPU. Three groups require the pinned
archive; the missing-framework group also runs without it. Six foreign/changed/
noncanonical/runtime/import/context variations, legacy-profile refusal, late
mutation/cancellation and descriptor cleanup preserve refusal and stage custody.

The separately built actual SwiftPM consumer emits
`usr/lib/swift-6.2/macosx` despite the Swift 6.4 compiler version; the profile uses
that observed path rather than guessing from the compiler version. Its native
command result matches all 94 file/12 native/nine alias observation bytes and
the independent Apple-tool producer's success line. The full original SDK/cache,
ZIP, manifest and workspace identities remain unchanged; the stopped standard
controller executes after preparation. A prepared result refuses a fresh claim
under this incoming profile. The fixture's physical launch path also resolves
the observed AppKit sandbox-extension warning from `/tmp` aliases; this is a
local experiment, not an installed/older-OS rule or use of a private API.
Actual Frameshift SDK/controller, source-bound packaging/CPU derivation and
installed/production joins remain independent work.

### Native release development signatures

`NativeSignatureVerifier.verifyDevelopmentBundle(_:architecture:)` is the Swift
replacement for development signature admission. Admit the complete closure
first, then create fresh `SecStaticCode` references for every inventoried native
file, the four fixed Sparkle containers where present, and the outer app. Request
`kSecCSCheckAllArchitectures`, `kSecCSStrictValidate` and
`kSecCSCheckNestedCode`, with `kSecCSRestrictSymlinks` and
`kSecCSRestrictSidebandData`; do not skip executable or resource validation.
Explicit leaf checks cover OTP/NIF/renderer code outside Apple's standard nested
bundle locations. The outer app must carry `kSecCodeSignatureAdhoc` according to
validated typed signing information. This is the existing development profile,
not a Developer ID, certificate trust, notarization or Gatekeeper decision.

Repeat complete closure admission after signature checks and require the exact
native observation plus directory/link/file descriptor identities to match the
first admission, including nanosecond change times. A same-byte rewrite or added
empty directory still refuses. Read-only inspection never repairs, re-signs or
executes candidate code. Use a two-minute monotonic job budget checked between
admission/API operations; it cannot preempt a blocked Security/filesystem call.
Do not enable network certificate evaluation or substitute signing information
for a successful validity check.

The implemented `frameshift-mac-release verify-development-bundle APP CPU` command
returns the unchanged schema-two observation plus LF only on complete success.
Usage exits 64; admission exits 1 with fixed development-signature refusal text.
Acceptance requires actual signed arm64/Intel/universal inputs, unsigned or
corrupt nonstandard native leaves, a corrupt non-native CPU slice, outer resource
tamper and corrupt nested SDK resources hidden under a resealed outer app. Compare
Apple `codesign` and native API results, preserve original bytes and custody, and
join the fresh ad-hoc app before any production wrapper cutover.

Five `NativeSignatureVerifierTests` groups pass within the 54-test tool lane on
macOS 27.0.1 arm64 / Xcode 27. Actual signed arm64/Intel/universal bundles match
`codesign`; an unsigned nonstandard NIF beneath a resealed app refuses. A corrupt
Intel slice passes the default native-CPU Security check and refuses both the
all-architecture adapter and Apple tool. Resource tamper, resource-fork sideband
data, same-byte rewrite and added empty directories refuse without repair.
The release-built command also matches exact observation bytes for five real
compiled/SDK/fresh-app closures. Altered sealed updater/framework plists beneath
an outer-only reseal refuse in both verifiers. The SDK's unsealed `PkgInfo` passes
both signature verifiers, so full SDK byte/archive comparison remains required.
These are local static fixtures; production trust and installed evidence remain
independent gates.

### Embedded Sparkle framework custody

The initial updater profile pins Sparkle 2.10.0 at upstream commit
`eef1a539a373c1f1a320624b1130fc5de7b2e100`, with binary-package SHA-256
`17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959`.
Source/SDK admission must independently bind that package to the frozen inputs;
an embedded version string alone is not binary provenance. Preserve the
upstream framework's symlinks and executable permissions when embedding it at
`Contents/Frameworks/Sparkle.framework`. Do not flatten it or rewrite imported
library names to bypass closure admission.

Admit only its nine exact aliases: `Versions/Current` to `B`, and `Autoupdate`,
`Headers`, `Modules`, `PrivateHeaders`, `Resources`, `Sparkle`, `Updater.app` and
`XPCServices` to their corresponding `Versions/Current/` member. Record each
relative path and exact target separately from regular files. Links count
toward inventory limits; their targets must resolve through only these aliases
to an inventoried real file or directory inside the bundle. Check link owner,
single-link custody and unchanged identity/target before and after inspection.
Link permission bits do not authorize writes to targets. Missing, altered,
dangling, cyclic, absolute, outside-framework or unrelated symlinks refuse.

Require the framework's real `Versions/B/Sparkle` dylib and four executables:
`Versions/B/Autoupdate`, the nested `Updater.app` main executable, and the
Downloader/Installer XPC main executables. Each must have the requested CPU(s)
and recorded deployment minimum; unknown additional native roles inside this
framework refuse. Check its plist's identifier, executable and exact 2.10.0
display version. These shape/identity checks do not authenticate the SDK.

Require the shell's exact `@rpath/Sparkle.framework/Versions/B/Sparkle` import.
Resolve it only from that executable's single own `@loader_path/../Frameworks` or
`@executable_path/../Frameworks` run path, with an inventoried real Frameworks
directory and matching dylib CPU. Do not inherit parent run paths, search an
SDK checkout, allow arbitrary `@rpath` imports or enable this exception for
another executable/NIF. Every other import retains the original refusal rules.

Private development preparation signs native leaves, nested updater/XPC
containers, then the framework and outer app. Verify every nested signature and
the complete app after the final seals. Architecture thinning/merging must use
the actual slices and preserve aliases; transport admission must preserve and
recheck those same link facts. A transport profile that cannot do so refuses
the bundle. Old bundles without an updater retain their existing observation
shape; updater observations also carry the exact link inventory.

Acceptance uses actual compiled shell imports and the independently pinned SDK,
both CPU metadata, exact alias inventory, framework/native/plist mismatch,
missing/dangling/changed/extra link and forbidden run-path/import refusals,
inside-out ad-hoc preparation and strict nested signature verification. A
successful local join does not establish installed update, production signing,
Gatekeeper, older OS execution or a public channel.

### Pinned updater material and private CPU derivation

Before using a cached updater framework for compilation or packaging, admit the
exact 10,193,895-byte upstream Swift-package ZIP against the checksum above.
Copy admitted bytes into an owner-only temporary directory, then extract only
its fixed `Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework` member tree.
Hash and compare every regular file, directory mode and exact admitted alias
with the framework actually used by the compiler. A version string or SwiftPM
workspace declaration cannot replace this byte comparison. Refuse extra,
missing, aliased, changed, unsafe, oversized or special members. Retain the
archive and cache unchanged; a missing or altered cache is not repaired by the
admission consumer. Independently bound extraction time and tree processing.

The native replacement is
`PinnedSparkleFramework.verify(archive:framework:)` in the Mac release-tool
package, with `frameshift-mac-release verify-sparkle-framework ARCHIVE FRAMEWORK`.
Use the already qualified protected archive/leaf reader, scoped directory
descriptors, Mach-O metadata and owned Apple `unzip` command. Extract from a
0600 copy of admitted archive bytes in a new 0700 private scratch directory;
never extract into or repair the actual compiler cache. Bound the fixed tree to
512 entries, 24 directory levels, 512-byte relative paths, 16 MiB per file and
64 MiB total. Compare all 85 files, 57 directories and nine exact aliases, then
retain both CPU facts for the five fixed native roles. Preserve the existing
schema-one JSON member/array bytes, including the pinned names' English ordering,
within 64 KiB including LF. These are native observations, not a second portable
receipt encoder.

Bracket extraction/comparison with complete expected/cache inventories and full
original/copied archive custody checks. A same-byte rewrite, empty name, mode,
owner, link or namespace change refuses. The child has a thirty-second bound;
the job has a two-minute monotonic budget checked between operations, without a
promise to preempt a blocked syscall. Failure retains private scratch and the
owned-child monitor; no late result may become success. Only a completed,
custody-confirmed scratch is removed. Usage/admission exits are 64/1 with fixed
pinned-material refusal text. Require actual pinned ZIP/cache byte parity and
mutation/alias/resource/child-failure refusal before wrapper or capture cutover.

Seven `PinnedSparkleFrameworkTests` groups pass within all 65 tool tests on
macOS 27.0.1 arm64 / Xcode 27 with actual pinned inputs and zero exclusions.
Complete cache/archive observation bytes match the retained observer on repeated
release-built CLI admission; all original file/directory/link/archive identities
remain unchanged. Wrong size/hash/alias before extraction, changed unsealed
`PkgInfo`, missing/extra resources, retargeted aliases, modes, actual header hard
links, FIFOs and unknown links refuse without cache repair. Late original/copied
archive, expected/cache tree, same-byte and scratch namespace changes refuse
with descriptor cleanup. Actual 512/513-entry, file/aggregate/path/depth limits,
an owned unzip deadline with confirmed retained exit, and cancellation after
child success refuse without returning a late observation. Fixed 64/1 CLI
refusals pass. Without `FRAMESHIFT_SPARKLE_ARCHIVE`, six live groups are explicitly
excluded. Compiler workspace capture, CPU derivation/package cutover and runtime
updater/installed/production qualification retain their independent gates.

Single-CPU development packaging derives the five SDK native files with actual
`lipo -thin` operations in an unpublished private `.package.*` stage. Keep all
other files, permissions and nine aliases from the admitted archive; never thin
or sign the shared compiler cache. Confirm the exact requested CPU, native file
type and unchanged loader metadata before later inside-out signing. Refuse an
existing framework or output outside that private stage. Archive identity and
pre/post derived inventories must be available to the source-bound producer;
final seals and app closure remain separate checks. These local inputs do not
establish upstream build derivation, license clearance or production authority.

The native producer is `SparkleFrameworkStager.stage(archive:app:architecture:)`
with `frameshift-mac-release stage-sparkle-framework ARCHIVE PRIVATE_APP CPU`.
It reuses original ZIP admission before any SDK copy, then brackets all seven
fixed children (unzip, ditto and five lipo calls) with original/private-stage
custody. Frameworks must be absent, including dangling links. Its exclusive
0700 `.sparkle-work` directory stays inside the new Frameworks directory;
outputs never change the retained `.package.*` parent's namespace. Admit each
single-link, protected, bounded native output and compare the exact selected
Mach-O facts before replacing only its corresponding copied role. Complete
checkpoints preserve common files and aliases, and detect same-byte rewrites,
namespace changes or foreign mutations. The stage is caller-owned with one
writer; this custody check does not identify a competing writer to the exact
file currently being written by its owned Apple child.

Return the existing ordered schema-one derivation JSON (`archive`, requested
`architecture`, complete `source`/`derived` trees and selected `native` facts),
below 64 KiB including LF, with publication authority none. This is a native
observation for the existing producer join, not a portable receipt encoder.
The job has a two-minute monotonic budget; each owned child has a fifteen-second
and separate 64-KiB pipe bound. Refusals use fixed 64/1 usage/admission exits and
retain the failed app, scratch, work and exact last child until its direct exit
is known. No late bytes become success. Only completed, custody-confirmed
scratch/work is removed. Compiler cache admission, source-bound producer joins,
CPU assembly and final app seals remain independent requirements.

Six `SparkleFrameworkStagerTests` groups pass within all 95 release-tool tests
with actual SDK/resource inputs and zero exclusions on macOS 27.0.1 arm64 /
Xcode 27. Both CPU derivation CLI records match every existing JSON byte;
original archive/cache/manifest/workspace identities stay unchanged. Actual
SwiftPM consumer, native arm64 derivation and Swift preparation join at 94 files,
12 single-CPU native roles and nine aliases, with strict nested/all-CPU seals
and native stopped-controller execution. Unsafe/existing stages, universal CPU,
wrong archive, late common/native/alias/namespace/parent/archive mutation,
intermediate same-byte output mutation, cancellation and actual extraction
deadline refuse with retained work and child custody. Four live groups are
explicitly excluded without the pinned archive. This separate consumer fixture
does not establish Frameshift's shipping SDK/controller or a source-bound
packaging profile; no packaging/library consumer has switched yet.

Acceptance compares the actual pinned archive and cached framework, checks
same-size archive/cache changes, missing/extra/retargeted aliases and unsafe
custody, derives both CPU profiles, and verifies requested slices and preserved
common bytes. Later compiler/cache/source joining, universal assembly and the
running update client must consume these checks before claiming a full updater
candidate.

### Tagged native Mac build candidate

`scripts/package-macos-candidate TAG COMMIT SOURCE_RECORD arm64|x86_64 OUTPUT`
builds an ad-hoc single-CPU app from the exact clean tagged checkout and the
independently retained source record under
[release inputs](../architecture/release-manifest.md#frozen-source-inputs).
Source, lock/toolchain files, package recipe, both `CFBundleShortVersionString`
and `CFBundleVersion`, and core application version must equal the stable tag's
three-component version before creating output. The producer checks both plist
fields in source, built and copied apps; receivers repeat the same join before
and after assembly. A fixed build counter cannot identify successive Sparkle
updates. Development fixtures use the same version grammar; this does not
qualify an installed updater or alter retained source-bound archives. Refuse dirty/moved/hidden
source, unsupported CPU and architecture mismatch before a build. The native
build execution must match the physical host CPU; Rosetta is not native Intel
producer evidence.

Record the inspected macOS build, physical CPU, Xcode/SDK/Swift, OTP/Elixir and
Zig observations. Bound each tool's output and deadline. Capture bounded
regular dependency and Gleam package input files before and after building,
excluding Git/private tool metadata, build directories and the explicitly
generated Exile/SQLite native outputs. Changed retained material refuses.
These recorded cache bytes and installed-tool version strings do not prove
upstream provenance, compiler authenticity or license admission.

Before capturing a new candidate, require the
[canonical fetched Gleam metadata](../architecture/release-manifest.md#canonical-fetched-gleam-metadata-for-candidate-builds)
profile. The caller prepares only that generated ignored metadata before source
receipts; the producer repeats preparation after the package child, then compares
every captured material fact. Equivalent upstream table order is canonicalized;
changed versions, source or other bytes still refuse. Retained candidate replay
uses its original byte-bound material and performs no preparation.

Build with the existing package recipe, check shell/core runtime version
descriptors against the tag, copy the admitted app into a private mode `0700`
output and verify its complete closure, signatures and exact copy identity.
Repeat source, material and tool checks before syncing the app and a bounded
mode `0600` candidate record. The record binds source-input SHA-256, tag/commit,
native execution/material facts and the final app observation with publication
authority `none`. It is a native build candidate, not a conforming universal
release manifest artifact. Both candidate cohorts must still be joined and
qualified before production distribution.

An identical completed rerun verifies retained app/source/material/tool facts
without rebuilding or signing. Source/version/CPU/material/output changes and
incomplete output refuse while preserving custody. Before a new build, require
at least 1 GiB available plus twice the admitted source-material bytes; the
build still needs filesystem/resource qualification. Bound material to 8,192
entries, 128 MiB per file, 512 MiB total, a two-minute software inventory budget
and a 16 MiB record. The build has a thirty-minute child deadline; source/read
budgets do not promise to interrupt a stalled syscall or terminate OS services.

Acceptance requires positive exact-source compiler fixtures and before/after
source/material/tool mutation, version/CPU mismatch, copied-byte change,
unknown/incomplete output and no-build replay refusals. Record an actual full
native host build against its exact isolated tagged source before claiming
that producer cohort; synthetic native-role fixtures do not substitute for
the OTP/NIF/runtime join. Installed OS/CPU, licenses, production signing,
notarization and physical product claims retain their separate gates.

The complete isolated tagged arm64 producer now passes on macOS 27.0.1 with
Xcode 27.0/SDK 27.0, Swift 6.4, Elixir 1.20.4/OTP 29.1 and Zig 0.16.0. Its
24-native-file app declares 15.0.0, binds 1,464 retained material files and
passes packaged authenticated IPC/import/restart/offline maintenance checks.
No-build replay preserves its source and candidate hashes. This is a local
test-purpose tag and captured source-cache cohort, not a public release or
authenticated upstream dependency/Intel/installed-distribution qualification.

### Candidate dependency source join

`scripts/check-macos-material TAG COMMIT SOURCE_RECORD arm64|x86_64 CANDIDATE
CANDIDATE_SHA256 CORE_RECEIPT CORE_SHA256 GLEAM_RECEIPT GLEAM_SHA256 OUTPUT`
joins separately pinned source receipts to an admitted retained native candidate.
It performs no fetch, build, merge, signing, extraction or publication. Admit
bounded canonical private core/Gleam receipts against independently supplied
SHA-256 values and the exact frozen product/tag/version/commit/source-input
digest. Validate their literal lock/manifest identities against frozen source,
their supported schemas, unique bounded source facts/directories and matching
pinned Hex parser observations. Retained receipt assertions do not authenticate
the original execution or publisher.

Every admitted core/Gleam source file must appear in the candidate's captured
material with identical path, bytes, mode and SHA-256. Gleam's bounded fetched
metadata must match its recorded hash/mode too. All remaining captured inputs
must belong to the explicit generated profile: the five EarmarkParser/Erlex
lexer/parser `.erl` outputs with corresponding admitted `.xrl`/`.yrl` inputs,
FileSystem's `priv/mac_listener` with admitted native source, and the empty
regular `gleam.lock`. Preserve their captured facts and separate classification
in the joined record. Do not call them authenticated source, regenerate them or
rewrite a candidate. Missing/mismatched proved files or any unexplained input
refuse. Compiler/runtime inputs outside the candidate's material remain separate.

Reuse the candidate receiver's real version/closure/seal checks before and after
joining. Recheck source, both receipts, candidate, namespaces and private output
custody before syncing a new bounded `dependency-inputs.json`. Output is 0700,
pending/record files are 0600, receipts are at most 16 MiB, the joined record is
at most 64 KiB, and processing has a three-minute software budget with existing
finite child bounds. Partial/conflicting output remains retained and refused;
completed replay verifies without rewriting or repeating release effects.

Acceptance includes independently pinned receipt/source/candidate conflicts,
missing/extra/aliased/unsafe/resource inputs, mutation during inspection and
unchanged replay using actual admitted compiler-role candidates. The retained
full native host joins its actual source receipts separately. This closes the
captured-source comparison, with publication authority `none`; independent
publisher/registry trust, rights, generated-code/toolchain authenticity, native
execution attestation, installed acceptance and production distribution remain
open. Source-bound universal assembly still requires its independent common-byte
and compiler-cohort checks.

### Dependency source receipt archive handoff

Native capture must use SwiftPM's parsed binary target and recorded compiler
artifact, not a separately supplied parallel framework. For the exact Sparkle
target, admit workspace-state versions six and seven with their respective
`xcframework` kind encodings, one root-package `macos` artifact, exact package
location, URL/checksum and fixed cache path. Refuse external package artifacts,
other dependencies/prebuilts, unknown formats, redirected/aliased/unsafe parents
and changed manifest/state/cache custody during capture. Bound manifest parsing
to 60 seconds, workspace input to 128 KiB and complete capture to three minutes.
Compare the artifact with the pinned archive before returning any SDK facts.
Evaluate the manifest in a separate private scratch workspace: SwiftPM can reset
unsupported workspace state even when only dumping a manifest. Preserve the
actual compiler-state file when refusing it. Keep the complete SDK's 152 members
and binary bytes within the existing aggregate inventory ceilings.
Perform no fetch, resolution, compilation, thinning, signing or cache repair
in this capture gate. Repeat admission around native compilation; when the
parsed package has no binary target, preserve the existing input inventory.

The native replacement is `SwiftPMInputCapture.capture(repository:)` with
`frameshift-mac-release capture-swiftpm-inputs REPOSITORY`. Resolve the repository
with POSIX
`realpath` to preserve the physical path actually recorded by SwiftPM. Retain
no-follow parent descriptors from that repository through every manifest, state,
archive and framework parent; compare their device/inode, type, mode and owner
at completion. Directory write timestamps may change during owned compiler work,
but redirected or replaced parents may not. Manifest and state leaves require
single-link protected custody and complete unchanged bytes/times. Require mode
`0600` for the recorded original ZIP. A parsed no-binary package returns the
existing empty SDK inventory only after manifest and parent rechecks.

Use an owned `/usr/bin/swift` manifest child with `package`, explicit
`--package-path` and separate `--scratch-path`, then `dump-package`. Apply a
sixty-second deadline and separate 512 KiB output bounds. Scratch is newly created mode `0700`, separate from `.build`. Validate
strict UTF-8 JSON before interpreting the bounded manifest/workspace: at most
32 container levels, 8,192 values, 64 KiB per string and 512 KiB aggregate string
storage; duplicate object keys, malformed numbers/escapes, trailing content and
Boolean version values refuse. Workspace versions are integer tokens `6`/`7`,
with exactly their defined keys and the fixed root artifact; absent targets or
unrecognized binary identities refuse. Repeat complete SDK/cache/archive and
manifest/state/parent custody before returning the existing ordered bare JSON
file array, within 64 KiB including LF. The complete SDK charges 152 entries
against its producer's shared ceiling, although only 86 regular-file facts are
returned. Usage/admission exits are 64/1 with fixed compiler-input refusal text.
Check cancellation and the three-minute monotonic software budget between
operations; do not claim blocked syscall preemption. Failure retains scratch and
owned-child custody, and late child success cannot become admitted input. Remove
only completed, custody-confirmed scratch. Require actual SwiftPM-produced
schema-seven cache/state, separately identified synthetic schema-six acceptance,
retained malformed state, alias/size/key/type/custody refusal and existing
consumer byte parity before capture or wrapper cutover.

Eleven `SwiftPMInputCaptureTests` groups pass within all 76 Mac release-tool tests
on macOS 27.0.1 arm64 / Xcode 27 with both actual SDK inputs and no exclusions.
Real SwiftPM-produced schema-seven state and separately synthetic schema-six
state return the same admitted file facts with original custody preserved.
Repeated release-built CLI capture matches all retained 86-file JSON bytes,
including member/order conventions, and preserves every manifest/state/ZIP and
framework file/directory/alias identity. Malformed retained state remains intact
for an actual no-binary manifest; missing packages return `[]` without a child.
Unknown/duplicate/type/format/redirected identities and external dependency/
prebuilt claims, unsafe manifest/state leaves and parents, exact JSON node/depth/
string limits, same-byte manifest/state/ZIP/header rewrites, replaced parents,
child deadline/output overflow and cancellation after child success refuse with
retained scratch and descriptor cleanup. Read-only exit observation confirms
both refused children stopped; it does not prove all descendants stopped.
Fixed CLI 64/1 refusals pass. Without `FRAMESHIFT_SPARKLE_ARCHIVE`, four actual
compiler-artifact groups are explicitly excluded; the remaining seven retain
manifest/parser/refusal coverage. This closes the native capture port's local
acceptance, with wrapper/native producer joins, shared aggregate integration,
actual updater execution, Intel/older-OS and installed/production gates separate.

Updater-bearing candidates must additionally join an independently hashed
`sparkle-material.json` from the pinned updater source gate. Capture its 85
regular framework files below
`apps/macos/.build/artifacts/macos/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/`
and its exact archive as
`apps/macos/.build/sparkle/Sparkle-for-Swift-Package-Manager.zip`, mode `0600`.
The source join must compare every captured path, mode, length and digest with
the receipt, require the frozen package hash, and refuse missing, partial,
unexpected or mismatched SDK inputs. Keep these 86 binary inputs separate from
the core/Gleam source-file count and generated-input exceptions. An embedded
SDK and its complete captured input scope must occur together. Its CPU thinning
and final seals remain independently checked by bundle admission; original SDK
hashes are not hashes of the derived native slices.

Append `SPARKLE_RECEIPT SPARKLE_SHA256` to `scripts/check-macos-material` for
this profile. Append `SPARKLE_SHA256` to `scripts/stage-macos-material`, and
include mode `0600` `macos-material/sparkle-material.json` as the archive's
fifth member, bounded to 64 KiB. Recompute the join from all three received
source receipts and require exact equality with the fourth, joined receipt.
Bind the SDK receipt hash and binary-input count in both local records. Missing
or unexpected optional arguments/members refuse; Ubuntu never admits this
extension. The no-updater profile retains its four members and unchanged
record format. Recheck SDK receipt bytes and namespace after every child and
on replay. This consumer contract does not substitute for the native producer's
SwiftPM-cache capture, compiler-input custody or installed updater acceptance.

`scripts/stage-macos-material TAG COMMIT SOURCE_RECORD arm64|x86_64 CANDIDATE
CANDIDATE_SHA256 ARCHIVE ARCHIVE_SHA256 CORE_SHA256 GLEAM_SHA256 JOIN_SHA256
OUTPUT` transports source evidence separately from the strict app-candidate
archive. Independently supply the exact candidate, archive and three receipt
digests. For the no-updater profile, the uncompressed POSIX USTAR has exactly four members: mode `0700`
`macos-material/`, and mode `0600` `core-material.json`, `gleam-material.json`
and `dependency-inputs.json` beneath it. No other path, directory or archive
profile is admitted. Bound the archive to 33 MiB, each source receipt to 16 MiB,
the joined receipt to 64 KiB and the member count to four before extraction.
Reuse the shared USTAR regular-member, byte/mode, checksum, padding, terminator,
descriptor and two-minute processing rules. Keep the existing app and Ubuntu
archive formats intact.

Create a new owner-only receiver directory with a private pending marker and
extract directly from the verified archive descriptor. Compare received receipt
digests before passing the two source receipts and separately admitted candidate
to the source join. The receiver's own `verification/dependency-inputs.json`
must equal the received joined receipt byte for byte. This proves the received
assertions agree with the candidate and frozen locks; it does not authenticate
their original execution or publisher. Refuse a mismatched joined result even
when all supplied transport digests agree.

Recheck source, archive, extracted members, candidate/app, namespaces and output
custody after all child consumers and before completion. Sync a private bounded
`handoff.json` binding source, candidate, archive and all receipt digests with
publication authority `none`. Complete replay verifies retained evidence without
extraction, fetching, building, merging, signing or rewriting. Partial/conflicting
output remains retained and refused. Acceptance includes actual BSD USTAR for
separate CPU compiler fixtures, independent hash/source/join conflicts, invalid
member/permission/resource profiles, retained byte/namespace mutation and
unchanged CLI replay. Exercise the full retained native host and its actual source
receipts separately; hosted/native Intel, upstream trust, rights, generated-code,
toolchain, installed and production distribution evidence remain open.

### Native Mac candidate workflow

`.github/workflows/macos-candidate.yml` is an explicit manual candidate workflow
requiring an existing stable tag and independently known exact source commit.
The read-only source job resolves the remote tag before checkout, freezes the
clean source/version record and rechecks the remote identity. Both native target
jobs must reproduce that exact source-record digest. Credentials are limited to
explicit remote-identity steps; checkout does not retain them. Pin actions by
full commit and use independent run/attempt artifact identities.

Select explicit `macos-26` arm64 and `macos-26-intel` x86_64 profiles, with
Xcode 26.6 (`17F113`) and SDK 26.5. Assert OS, selected Xcode/SDK and physical
native CPU before fetching material or building. Capture actual tool/OS facts
in the native candidate record; runner labels and version strings alone are
not authenticated toolchain or installed acceptance. Hosted image changes that
violate the inspected profile refuse rather than switching silently.

Fetch exact locked project material, explicitly prepare generated Gleam metadata,
then run the no-fetch core and Gleam source gates before building. Select the
inspected Gleam 1.18.1 macOS archive cache below the existing user cache directory;
an absent or differing cache refuses. Build with the frozen native producer and
run the packaged IPC/import/restart/offline maintenance join. Replay both source
receipts after the build and join their independently retained digests to the
exact candidate record. These preparation/build/source consumers receive no
GitHub token. Keep remote-identity checks in their own credentialed steps.

Write two POSIX USTAR files with AppleDouble metadata disabled: the unchanged
strict app-candidate profile and the separate source-receipt profile. Verify
unchanged producer custody, stage the app archive, and stage the evidence archive
against that received app using the independently retained candidate/core/Gleam/
join digests. Recheck frozen source and remote identity after both receivers,
then compare both archive digests before upload. Retain each single verified TAR
under its own CPU/tag/run/attempt identity without automatic ZIP transformation
or overwriting an earlier attempt. The job summary records source, candidate,
both archive and all three receipt digests plus both artifact IDs. A downstream
receiver requires these independent custody inputs; a filename or artifact ID
alone cannot qualify received bytes.

This workflow stages CPU candidates with publication authority `none`. It
contains no signing/deployment credentials, GitHub Release/Cask/Sparkle/site
promotion or automatic push/fork trigger. Full source-bound universal assembly
and independent native/installed acceptance remain subsequent gates. Acceptance
includes pinned/read-only/manual workflow invariants, real shared remote/source
refusal fixtures, and the local full producer/packaged/USTAR receiver joins.
Record hosted execution separately; authoring or static checking this workflow
does not count as an actual GitHub run.

### Native candidate archive handoff

`scripts/stage-macos-candidate TAG COMMIT SOURCE_RECORD arm64|x86_64 ARCHIVE
ARCHIVE_SHA256 OUTPUT` admits a bounded uncompressed POSIX USTAR under the same
frozen source. Independently supply the archive digest. Its sole root is
`macos-candidate/` with mode `0700`; it contains exactly the completed app and
private candidate record. Use the release USTAR reader's regular-file/directory,
checksum, UTF-8/path, mode, member/byte/deadline and complete-terminator rules.
The Mac candidate profile also admits the embedded Sparkle profile's nine
exact symlink paths/targets below `macos-candidate/Frameshift.app/`; every other
alias, device, extension, compressed input, outside path or duplicate refuses.
Each link has zero payload, no special permission bits and its exact canonical
relative target. Link permission bits are metadata rather than target access
authority; do not apply them to the referent. Before output creation, require
the complete nine-link set and all terminal targets as real archive members.
Every member's parent must be an explicit real directory, never an alias.
Copy file bytes/modes, then create only those admitted links after regular
members are complete. Do not execute an extraction tool on received paths.

Create a new private receiver output and retain a pending marker until exact
archive member readback, source checks, complete candidate-record/app version/
closure/signature admission and final byte checks pass. Sync a bounded private
handoff record binding source-input, transport and candidate-record digests with
publication authority `none`. A completed rerun verifies the same retained
archive and candidate without extraction, building, merging, signing or replacing
bytes. Partial/conflicting custody refuses and remains retained.

Mac producers disable AppleDouble metadata when writing POSIX USTAR and verify
the actual archive through this receiver before transport. SHA-256 custody does
not authenticate the upstream dependency cache or prove remote native execution.
Acceptance includes actual BSD USTAR from separate CPU compiler fixtures, exact
copied native seals/modes, source/transport/candidate/namespace mutation and
no-extraction replay, plus a full retained arm64 host archive readback. Full
native Intel, hosted runner, installed and production signing evidence remains
separate. The shared Ubuntu profile retains its own `ubuntu-candidate/` root and
existing acceptance corpus.

Link acceptance adds actual BSD USTAR containing the complete fixed framework,
readback of exact link type/target/owner/single-link and unchanged inode custody,
wrong/partial/absolute/cyclic/extra-link and link-parent/payload refusal before
creation, retained link mutation refusal, and strict native framework seal
verification after transport. Ubuntu and material profiles continue to refuse
all symbolic links; no generic archive alias support is introduced.

Five Mac handoff fixture groups pass actual BSD USTAR staging/replay for both
compiler CPU candidates, followed by source-bound universal assembly. Wrong
source/transport/CPU/profile, same-size candidate-record replacement, added
directories and source/namespace changes during readback refuse. The retained
full arm64 host also passes a 40,922,624-byte archive and unchanged replay;
both retained full Ubuntu GNU USTAR candidates pass the shared byte comparison.
These are local transport/consumer results, with publication authority `none`.

### Source-bound universal candidate

`scripts/package-macos-cohort TAG COMMIT SOURCE_RECORD ARM_CANDIDATE ARM_SHA256
INTEL_CANDIDATE INTEL_SHA256 OUTPUT` joins two retained native candidate
directories under the same exact frozen source. Supply each candidate-record
SHA-256 independently of the received directory. Admit bounded private canonical
records, exact source/tag/product/version identities, single-CPU app observations,
native seals and actual shell/core version descriptors. Repeat record/app/source
checks after assembly and before acknowledging completion.

Both candidates must capture the same ordered dependency-material facts and
the same Xcode/SDK, Swift compiler version, Elixir/ERTS version and Zig cohort.
Their physical CPU/OS observations remain per-producer. A receiver validates
the retained assertions and bytes; it does not independently prove that a
remote producer ran natively or authenticated its dependency cache. Their
independent expected digests are custody inputs, not a release signature or
substitute for runner provenance and installed acceptance.

Use the existing universal development join for every native role and common
byte/directory/plist check. Retain its output in a private child directory and
sync a bounded parent cohort record binding source-input digest, both candidate
digests and the resulting universal record digest. Publication authority remains
`none`. Completed replay verifies all retained bytes without rebuilding, merging
or signing; source/material/compiler/version/digest/output conflicts and partial
outputs refuse and remain retained. Do not normalize differing opaque BEAM,
configuration or resource bytes to conceal a producer conflict.

Acceptance includes actual separate CPU compiler fixtures joined to one real
Git/Mix source record, final universal seals, unchanged no-effect replay, wrong
source/digest/material/compiler/runtime identities and mutation during joining.
The captured full arm64 host can enter receiver validation independently; full
universal host acceptance still requires its matching qualified native Intel
producer. Candidate-record inspection is bounded to 16 MiB each and the parent
record to 64 KiB; all underlying bundle/source/tool limits remain in force.

Seven receiver/cohort fixture groups pass actual source/version consumers,
separate CPU compilation/merging/seals, native arm64 fixture execution and
unchanged replay, alongside source/digest/material/compiler/runtime/alias/
namespace and mutation refusal. The retained full arm64 host also passes
receiver admission against its independently pinned record digest. The Intel
fixture is cross-compiled purpose code, not a full native Intel OTP producer.

### Universal development bundle join

`scripts/package-macos-universal ARM_APP INTEL_APP OUTPUT` joins two admitted
ad-hoc development bundles without building either source or selecting a
production signing identity. Each input must contain exactly its one generic
CPU in every native file, and pass closure and all native/app seal checks.
Their directory paths/modes and relative file sets must agree. Every non-native
byte and mode must agree,
except the enclosing app's regenerated `Contents/_CodeSignature/CodeResources`
and `Contents/Info.plist`. For the complete admitted Sparkle profile, require
identical exact alias inventories and permit differences only in its four
fixed framework/Updater/Downloader/Installer `CodeResources` files, whose seals
must verify independently before merging and be regenerated after merging.
Do not ignore other SDK resources, headers, plists or arbitrary signature paths.
Parse both plists with Apple's parser and require
equal properties except `LSMinimumSystemVersion`, with matching nonempty bundle
ID, version and build number. Refuse differing BEAM files, configuration,
resources, dependency versions, native roles or file types; never pick one
architecture's conflicting common bytes silently.

Copy the admitted common tree into a private stage and merge every native
file with `lipo`, preserving its mode. Do not keep one architecture's OTP
helpers or NIFs. Admit both slices in every result, derive the greatest actual
native OS minimum, and sign merged leaves, then the fixed nested SDK containers
and framework, before the app. Preserve and recheck every alias and verify every
native/container and enclosing seal. Re-read both
sources before completion. Sync the final app and a bounded private record
binding both complete input observations to the exact universal observation;
its publication authority is `none`. A retained rerun verifies inputs, output,
closures and signatures without merging, re-signing or replacing bytes.
An interrupted or changed output remains retained and refuses.

Use the closure reader's member/byte/path/native limits. Bound the completed
record to 1 MiB and require twice the conservative output byte estimate plus
256 MiB free before staging; reserve 1 MiB per native file for merge padding,
and refuse estimates over the closure's per-file or total byte ceilings.
Bound subprocess output and deadlines. Acceptance includes actual separately
compiled arm64/x86_64 inputs, merged executable and dylib slices, native arm64
fixture execution, final seals, unchanged replay, resource/plist/CPU/type/input
mutation and interrupted/failed-merge refusal. The exact merged fixture can
then enter the development DMG readback gate.
The updater join additionally requires both actually thinned SDK inputs, all
twelve merged fixture native roles, arm64 real-controller initialization with
the updater stopped, unchanged replay and SDK resource/alias/seal refusals.
Intel metadata and cross-compilation remain distinct from native Intel execution.

This join checks byte custody and static structure, not semantic equivalence
of separately compiled CPU code. Exact tagged source, reproducible common
resources, the full native Intel/Apple Silicon OTP/NIF producer cohort and
execution on each supported OS/CPU remain required before production
distribution. Missing source or installed evidence must not become a release
claim merely because a universal fixture was successfully joined.

### Development disk-image custody

`scripts/package-macos-dmg APP arm64|x86_64|universal OUTPUT` creates only a
private development candidate from an already admitted, ad-hoc-signed app.
It performs no source build, signing-identity selection, notarization, upload
or installed-app replacement. The image name and enclosed reading text label
it development; its completed observation has publication authority `none`.
This prerequisite does not relax the universal signed production DMG gate.

Before creating a new mode `0700` output, admit the source closure and every
native signature. Copy into a private payload, repeat admission and compare
the exact app inventory with the source. The disk image contains only that
app, a fixed `/Applications` link and development reading text, apart from
explicitly recognized filesystem metadata. Use a compressed, read-only HFS+
UDIF image, verify its container, mount it read-only at a private explicit
mountpoint without Finder opening, and check the mounted app's exact
inventory, closure, native signatures and reading/link bytes. Detach that
exact mountpoint before acknowledging completion; a refused detach retains
the private working directory rather than deleting through a mount.

Bind the admitted app observation and final DMG size/SHA-256 in synced
mode `0600` metadata, capped at 1 MiB. The DMG is bounded to 1 GiB; require
twice the source byte count plus 256 MiB free before staging, with bounded
tool output and finite tool deadlines. A completed rerun verifies retained
metadata, the unchanged source and DMG, and performs mounted readback again;
it never rebuilds or replaces those bytes. A changed source, changed archive,
unexpected member or interrupted private output refuses and stays retained.
Disk-image creation need not produce the same bytes on independent builds;
identity comes from retaining one verified candidate.

Acceptance includes actual image creation/mount/readback/detach with small
compiler fixtures and the complete development app on the observed Mac,
unchanged replay, tamper/source-change/incomplete-output refusal, and finite
creator/attach/detach failure fixtures. A mounted copy and valid ad-hoc seals
do not prove Gatekeeper, notarization, Intel execution, installed lifecycle,
the oldest supported OS, production licensing or update behavior.

### Installed distribution evidence

1. clean installation and removal on a fresh supported macOS account;
2. notarization and hardened-runtime validation;
3. shell/core version skew produces a clear upgrade error;
4. crash/relaunch tests for shell, core, raster worker, and generation provider;
5. idle energy-impact measurement with no pending work;
6. Keychain denial/lock behavior;
7. migration and rollback with a copy of real metadata;
8. no undeclared network requests during local-only operation;
9. project-owned app/build scripts contain no Python; any upstream toolchain
   exception follows the pinned isolated-build policy;
10. direct download, Homebrew Cask, and Sparkle update paths preserve the
    same signed bundle identity, data, and background registration state;
11. nested OTP runtime, Exqlite NIF, Zig worker, and update helpers pass
    Developer ID/hardened-runtime validation in the installed artifact.
