# Frameshift core

This OTP application owns Frameshift's durable library and protocol state. It
does not own macOS presentation, Apple framework calls, raster transforms, or
frame electronics.

The implemented core currently provides:

- embedded Frame Protocol v0.1 schema validation with no runtime schema fetch;
- an authenticated bounded Unix-socket command boundary whose fresh per-launch
  challenge is consumed from a one-use user-only bootstrap file, with durable
  command receipts that suppress completed replays and expose crash-window
  outcomes for authoritative state reconciliation;
- a single-owner SQLite library backed by immutable content-addressed files;
  the shared writer rolls back statement failures, returns database
  errors, and records transaction outcomes without terminating the Library;
- a read-only peer-authenticated local diagnostics socket with bounded health,
  metric, and redacted audit pages; a supervised telemetry reporter retains
  minute/hour rollups and reports collection loss and coverage;
- transactional command/audit correlation and pure push/pull delivery decision
  rules that cannot advance current state on an unconfirmed response;
- canonical recipe identities and artifact cache relationships;
- master import, generated-variant lineage, labels, search, pinning, recoverable
  removal, and frame-reference protection;
- a durable paired-frame registry that retains the admitted universal Thing
  Description, capability instance, pinned server fingerprint, and opaque
  Keychain credential reference without storing private key material;
- a fixed pre-pair HTTPS binding with bounded QR/request parsing, frame SPKI
  pinning before secret transmission, TLS client-key proof, a physical-only
  five-minute window, and fail-closed simulator custody that consumes the
  secret before acknowledging a host; its live socket test requires local
  network permission, while hardware key storage and commissioning UI remain
  separate acceptance gates;
- a one-shot Wotex HTTP client for finite JSON interactions that admits only
  the credential's exact advertised HTTPS authority and local addresses,
  performs mutual TLS with an SPKI-pinned frame, refuses pooling and redirects,
  and enforces absolute deadlines plus bounded headers and response bodies;
- a direct-frame reference HTTPS synchronizer that follows selected Wotex
  Forms, uploads digest-addressed binary artifacts with exact profile metadata,
  applies strong-ETag desired-state preconditions, performs only explicitly
  safe bounded retries, and confirms display truth from the state Property;
- a push-only queue path that renders through Zig, resolves ephemeral client
  identity through a configurable credential-resolver contract, records the
  desired artifact durably before network mutation, and advances current and
  previous-known-good only after direct state confirms display; the bundled
  macOS menu process now supplies an authenticated Keychain signing broker,
  but commissioned identities and live interoperability remain unverified;
- startup reconciliation for interrupted active/trash file moves;
- durable per-frame sleeping outboxes with monotonic revisions, supersession,
  acknowledgement checks, and current/previous-known-good reference rotation;
- a frame-scoped outbox request handler that derives one paired identity from
  the TLS peer certificate's SPKI, rejects ambiguous pins, serves only that
  frame's current manifest and exact digest-verified artifact, enforces finite
  asset ceilings and content length/digest, and accepts schema-valid
  acknowledgements; its HTTP/1.1 exchange parser rejects ambiguous lengths,
  transfer coding, pipelining, and oversize requests before dispatch; a
  supervised TLS 1.3 listener requires a paired client certificate and serves
  one bounded exchange per connection, but installed Keychain identity
  provisioning, app lifecycle wiring, and a physical frame-side client remain open;
- a supervised, single-job Zig renderer port with bounded framing, typed worker
  failures, explicit deadlines, diagnostic redaction, and restart-on-failure;
- a vendor-neutral profile compiler that selects advertised capability
  structure, creates a deterministic centered composition, and queues exact
  RGB24 output for sleeping pull targets;
- a versioned immutable master package that retains exact source bytes and
  canonical sRGB RGBA8, then binds durable masters to composition recipes,
  cached artifacts, outboxes, and simulator convergence;
- an explicit still-generation provider contract with preflight, deadline,
  canonical cache, provenance, and no retry or fallback;
- a persistent frame simulator with bounded storage, desired/current state,
  sleeping pull convergence, still playlists, redundant metadata records, and
  injected contact, transfer, display, storage, timing, and power-loss failures.

A separate Docker receiver exercises the actual mutual-TLS outbox with the
default Paper, Photo, and Pixel manufacturer candidate geometries. It uses
exact-size RGB24 **software proxy** artifacts; panel wire packing, electrical
timing, optics, and physical persistence remain hardware gates. Run
`scripts/check container` from the repository root with a Docker-compatible
daemon. CI runs this lane independently of the ordinary core gate. See the
[receiver contract](../../docs/architecture/container-frame-simulator.md).
The separate `scripts/check linux-ipc` lane exercises actual Linux kernel
peer credentials on pinned OTP in a network-disabled container; it does not
qualify an installed Linux service or its group permissions.

The Linux `frameshiftctl discover` command returns a finite, unauthenticated
DNS-SD introduction snapshot using installed Avahi/coreutils dependencies.
`scripts/check linux-discovery` builds a separate dated Debian Avahi/D-Bus
fixture and checks the actual producer, nonroot CLI, refusal and daemon restart.
It needs network access for signed snapshot packages and an isolated Docker
bridge for local discovery. The Linux IPC lane retains no external network and
uses an executable temporary filesystem only for owned deadline-test helpers.
These are software fixtures, not supported Ubuntu install or hardware evidence.

`Frameshift.NativeCodec` owns one original-byte normalization job against a
verified staged executable and exact revision. It requires existing private
nonroot `0700` temporary custody for Exile's descriptor handshake. Source bytes
are bounded; environment/stderr and upstream crash logs cannot expose them.
The deadline/watchdog awaits native exit before admitting another job; unknown
custody preserves its replacement fence. Core tests join actual PNG/JPEG normalization
to immutable package/SQLite readback and Zig rendering. `scripts/check linux-codec`
also builds target SQLite/Exile NIFs/helpers against pinned OTP headers and exercises
nonroot arm64/amd64 worker deadlines, shutdown and abrupt-owner refusal.

The Ubuntu development closure compiles this core, SQLite/Exile and the codec
against pinned Ubuntu 24.04 / OTP 29.1, with a target-baseline Zig worker and
bundled runtime. The installed service/CLI launchers select fixed public group
policy and private persistent temporary custody. `scripts/check linux-release`
uses each staged architecture in a clean, read-only/network-disabled Ubuntu
fixture; its exact source/pixel/restart and unsafe-custody checks complement the
[platform contract](../../docs/host/linux.md#initial-deb-runtime-and-service-contract).
The `linux-deb` lane installs actual development archives, exercises package
lifecycle/refusals and retains data, credential sentinels and crash custody.
Booted systemd and native installed acceptance remain required.

The Linux group endpoint joins private upload staging, this codec and exact
actor-bound Library results. Configure `FRAMESHIFT_CODEC_PATH` and an existing
service-owned real `0700` temporary directory. Missing or abandoned custody
leaves imports unavailable while Library/status/diagnostics continue. The clean
`frameshiftctl import FILE [--title TITLE] --id ID` streams verified originals;
`frameshiftctl import-status ID` reads durable recovery without FILE. Lost
chunks stop intake and lost finish replies retain exit 75; neither retries.
Installed release qualification remains separate work.

The Library retains the exact imported master ID in the actor-bound command
receipt, committed with registration and audit. Pending imports refuse replay;
completed imports return their original result without restoring removed artwork.
The unreleased original schema includes this result field. Existing development
databases are preserved and are not automatically upgraded or reset; use a new
data directory for fresh-schema fixtures. Streaming and recovery follow
the [Linux import contract](../../docs/host/linux.md#streamed-original-import).

The separate bundled `frameshift-identity import` command accepts one bounded
certificate/private-key PEM on closed stdin while running as the configured
nonroot service UID. Set `FRAMESHIFT_SERVICE_UID` and an existing service-owned
`0700` `FRAMESHIFT_CREDENTIAL_DIRECTORY`. It validates and installs an opaque
certificate-bound reference without replacing an existing file or starting the
host. Exit 75 preserves an uncertain installation for inspection. Issuance and
encrypted identity backup are separate from artwork backup; see the
[Linux custody and recovery contract](../../docs/host/linux.md#offline-protected-identity-import).

Run the complete core check from this directory:

```sh
mise exec -- mix check
```

`mix check` runs the locked dependency check, unused dependency check,
warnings-as-errors compile, formatter, strict Credo, dependency audits, Doctor
documentation and type coverage, warning-free ExDoc build, ExCoveralls tests,
Dialyzer, and whitespace validation. Protocol and renderer-wire property tests
use StreamData. Checks stop at the first failed tool; retry remains disabled so
each run starts the complete configured lane. Run `mix bench` separately to
regenerate the checked Markdown reports in `bench/output/`; timings are
machine-specific evidence, not a release threshold. Run `make index` at the
repository root to create or refresh Dexter's local code index in the ignored
`.dexter/` directory.

The explicit environment cleanup avoids inheriting a stale developer-level Mix
installation. It does not affect the application runtime.

Development and production startup supervise the worker at
`renderer/zig-out/bin/frameshift-raster` by default. Set
`FRAMESHIFT_RENDERER_PATH` to the bundled executable path when assembling a
release. Tests build and start the worker explicitly so a failed renderer build
or wire incompatibility fails the renderer integration tests directly.

Production releases require `FRAMESHIFT_RENDERER_PATH` at runtime rather than
capturing a build-machine path. The repository check assembles the OTP release,
starts it with isolated data, verifies a real Swift instruction/import round
trip, and terminates it cleanly. The packaging check embeds and supervises the
release and renderer inside the macOS app; Developer ID signing, hardened
runtime, notarization, and Service Management registration remain distribution
gates.

The Mac shell bridges allowlisted structured core logs to Apple unified
logging. The core keeps a rotating, sanitized error fallback under
`<data-dir>/diagnostics/core-fallback.log`. Neither log sink is the durable
audit trail. On macOS use Console.app or `/usr/bin/log` with subsystem
`io.frameshift.app` to inspect operational logs. The bundled
`frameshiftctl diagnostics health|metrics|audit` reads diagnostic state through
the separate socket without the menu UI. Metric disk, idle-energy, Linux
logging, and independent-device gates remain open in the verification map.
