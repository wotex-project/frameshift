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

`scripts/stage-macos-material TAG COMMIT SOURCE_RECORD arm64|x86_64 CANDIDATE
CANDIDATE_SHA256 ARCHIVE ARCHIVE_SHA256 CORE_SHA256 GLEAM_SHA256 JOIN_SHA256
OUTPUT` transports source evidence separately from the strict app-candidate
archive. Independently supply the exact candidate, archive and three receipt
digests. The uncompressed POSIX USTAR has exactly four members: mode `0700`
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
and `Contents/Info.plist`. Parse both plists with Apple's parser and require
equal properties except `LSMinimumSystemVersion`, with matching nonempty bundle
ID, version and build number. Refuse differing BEAM files, configuration,
resources, dependency versions, native roles or file types; never pick one
architecture's conflicting common bytes silently.

Copy the admitted common tree into a private stage and merge every native
file with `lipo`, preserving its mode. Do not keep one architecture's OTP
helpers or NIFs. Admit both slices in every result, derive the greatest actual
native OS minimum, and sign the merged leaves before the app. Re-read both
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
