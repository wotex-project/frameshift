# Frameshift macOS application

This Swift package is the native menu-bar application. It owns SwiftUI
presentation, Apple framework integration, image decoding, secure handoff, and
application lifecycle. Durable library, recipe, outbox, render, and frame state
remain owned by the bundled Elixir core.

The packaged app runs as a menu-bar agent. The dropdown is its primary control
surface; dismissing it leaves the process and bundled core running. Its Finder
icon uses the selected perspective-frame mark on a transparent field, and the
menu bar uses the matching monochrome silhouette. The labeled power icon in the
dropdown header and Command-Q quit the agent and its bundled core.
The dropdown header also shows the approved Finder mark; its translucent
backdrop uses a native macOS visual-effect material.
Settings opens separately with full-width Connection, Image generation, Nearby
frames, and Startup sections. Its resizable window scrolls vertically; frame
identifiers, status, and help text wrap. Settings and the dropdown share the
same flat labeled action buttons.
`scripts/build-macos-icons` generates the packaged `.icns` and menu-bar PNG
resources from the committed SVG sources.

`LocalCoreClient` communicates with the versioned bounded Unix-domain-socket
protocol using a fresh 256-bit per-launch token delivered through a one-use
user-only bootstrap file. Startup checks whether the socket accepts connections
before sending the first request, including when a stale socket file remains.
Imports use Image I/O to admit one still image, apply
its orientation, convert into canonical sRGB RGBA8, and write a user-only
temporary handoff. The core verifies the handoff digest and persists an
immutable master containing the exact original bytes and normalized pixels. The
handoff is removed after the terminal core response.

The bundled menu process also hosts a private, token-authenticated Keychain
broker for the core. Paired frames store opaque persistent identity references;
only the public certificate and bounded TLS signatures cross the broker
socket. Private-key bytes are never exported. This boundary is type-checked
and its core protocol is unit-tested, but a commissioned identity and live
mutual-TLS frame exchange are still required for end-to-end acceptance.

The packaged app embeds and supervises the production OTP release and Zig
renderer. It is deliberately usable without a generation provider. Frame
pairing and identity provisioning, Keychain-backed local/session identity,
exact target previews, live direct push interoperability, Vision metadata,
Developer ID signing, hardened runtime, and notarization remain
tracked product gates.

The shell forwards sanitized core records to Apple unified logging. Read them
in Console.app or from Terminal with:

```sh
/usr/bin/log show --last 1h --info --style compact --predicate 'subsystem == "io.frameshift.app"'
```

The packaged `Contents/MacOS/frameshiftctl` reads health, local metric
rollups, and redacted audit pages without a Frameshift UI:

```sh
Frameshift.app/Contents/MacOS/frameshiftctl diagnostics health
Frameshift.app/Contents/MacOS/frameshiftctl diagnostics metrics --limit 50
Frameshift.app/Contents/MacOS/frameshiftctl diagnostics audit --limit 50
```

The read-only socket checks the kernel-reported peer UID. It uses a separate
authorization path from the one-use mutation token. The CLI needs the core
running; the current bundled core stops with the menu process. Background
service registration remains a separate product gate.

The packaged offline maintenance command backs up, verifies, and restores a
library without the menu UI. Quit Frameshift before backup. Restore always
targets an absent directory; it does not replace the current library:

```sh
Frameshift.app/Contents/Resources/bin/frameshift-maintenance backup /path/to/backup
Frameshift.app/Contents/Resources/bin/frameshift-maintenance verify /path/to/backup
Frameshift.app/Contents/Resources/bin/frameshift-maintenance restore /path/to/backup /path/to/restored-data
```

Set `FRAMESHIFT_DATA_DIR` to back up a separate installation. See
[the backup contract](../../docs/architecture/library-backup.md) for the
manifest, checks, and migration behavior.

Build and test with the system Swift 6 toolchain:

```sh
../../scripts/check macos
```

The Swift Package test target exercises model identity, command encoding,
authoritative state reconciliation, and error redaction. The check executable
also exercises real Apple image decoding. The repository check passes the
toolchain's Swift Testing macro library explicitly when it is installed as
part of Command Line Tools, then builds and checks the packaged app.
The IPC probe performs a real instruction and image-import round trip against a
production core release. Neither check executable is copied into the app.

`swift run frameshift-menu` launches the Swift executable directly, but the
bundled core is available only in the packaged `.app`. The package script
creates an ad-hoc-signed local artifact; release signing and notarization require
external Apple credentials and services.

Development packaging rebuilds the renderer and local NIFs with explicit macOS
14 targets, signs native leaves before the app and declares the greatest actual
native minimum. The current OTP runtime makes the bundle require macOS 15.0.0;
that declaration does not establish execution on macOS 15. Inspect a bundle with:

```sh
../../scripts/check-macos-closure .build/artifacts/Frameshift.app arm64
```

Use `x86_64` or `universal` for those requested CPU profiles. The bounded gate
records relative hashes, modes, native CPU/minimum/loader metadata and refuses
links, unsafe permissions, unsupported run-path contexts, missing native roles
and understated OS declarations. See the
[closure contract](../../docs/host/macos.md#native-closure-admission) for its
limits and the independent installed/signing requirements.

Create a private development DMG from the already packaged app:

```sh
../../scripts/package-macos-dmg .build/artifacts/Frameshift.app arm64 /path/to/new-candidate
```

The output contains a labelled development image and private records binding
the admitted app and archive hashes. Packaging verifies the mounted read-only
app, every native seal and its `/Applications` link, then detaches before
completion. The same command verifies unchanged retained bytes on rerun.
Interrupted or changed output refuses without replacement. The
[disk-image contract](../../docs/host/macos.md#development-disk-image-custody)
keeps production signing, notarization and installed acceptance separate.

Join separately built development CPU bundles before creating a universal image:

```sh
../../scripts/package-macos-universal /path/to/arm64/Frameshift.app /path/to/intel/Frameshift.app /path/to/new-universal
```

Both admitted ad-hoc inputs must have matching directories, common bytes and
product identities. Every native file is merged and signed again in the new
private output. The record binds both input observations and the final
universal bundle. A rerun verifies retained custody without merging or signing
again. Differing resources, incomplete output and changed source/output refuse.
See the [join contract](../../docs/host/macos.md#universal-development-bundle-join);
the tool does not supply exact-source provenance or installed CPU qualification.

For an exact clean stable test/release tag, `scripts/package-macos-candidate`
joins the frozen source record, physical native CPU, captured dependency/tool
facts, app/core versions and copied bundle closure. Its retained private record
and no-build replay are candidate custody, with publication authority `none`.
See the [native producer contract](../../docs/host/macos.md#tagged-native-mac-build-candidate)
for the passed full arm64 software join and remaining release gates.

`scripts/package-macos-cohort` joins independently pinned native candidate
records to one frozen source and matching material/compiler facts before using
the universal assembler. Its private retained parent/child records have no
publication authority. See the [source-cohort contract](../../docs/host/macos.md#source-bound-universal-candidate)
for receiver/refusal and actual producer evidence boundaries.

`scripts/stage-macos-candidate` receives the native candidate's independently
pinned POSIX USTAR, preserving exact member bytes/modes before source-cohort
admission. Actual BSD archive fixtures and the full retained arm64 host pass;
see the [handoff contract](../../docs/host/macos.md#native-candidate-archive-handoff).
