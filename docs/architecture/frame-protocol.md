# Universal Frame Protocol v0.1

**Status:** normative implementation draft; security review required before
production

**Scope:** vendor-neutral discovery, transfer, activation, observation, and
scheduling of still-image artifacts

The words MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY are interpreted as in
[RFC 8174](https://datatracker.ietf.org/doc/html/rfc8174).

## 1. Design goals

1. Work on a local network without a Frameshift cloud.
2. Support continuously powered frames and deeply sleeping battery frames.
3. Describe displays by capabilities, not vendor/model branches.
4. Keep expensive transforms and AI off the frame.
5. Make every mutation bounded, authenticated, idempotent, and recoverable.
6. Never replace valid artwork with partial, corrupt, or incompatible bytes.
7. Report physical display outcome separately from network acceptance.
8. Carry still images and still-image playlists only.
9. Separate semantic interactions from HTTP, CoAP, MQTT, BLE, Matter, or
   gateway bindings.
10. Permit exact vendor and panel profiles without making a vendor name part of
    the interoperability algorithm.

## 2. Roles and terms

- **Host:** the trusted Frameshift controller that owns masters and renders
  artifacts.
- **Frame:** a paired display device.
- **Artifact:** immutable bytes in one advertised display profile.
- **Digest:** lowercase hexadecimal SHA-256 of the exact artifact bytes.
- **Desired asset:** the digest the frame should display next.
- **Current asset:** the digest last confirmed by the display adapter.
- **Previous-known-good:** the prior confirmed current asset retained for
  recovery.
- **Host work digest:** local identity of the admitted binding, source, and
  recipe that produced an artifact; it does not replace the artifact digest on
  the wire.
- **Direct mode:** an awake frame exposes the API and the host pushes.
- **Outbox mode:** a sleeping frame wakes, connects to the host, and pulls.

## 3. Interaction model

Frames expose a [W3C WoT Thing Description 1.1](https://www.w3.org/TR/2023/REC-wot-thing-description11-20231205/)
instance of the Frameshift Frame Thing Model. A paired host exposes a separate
Host Outbox Thing for sleeping pull. The Thing Model and namespaced Frameshift
vocabulary define semantics; Forms bind each interaction to a concrete
transport.

The universal contract has three independent version axes:

- the W3C TD/TM standards revision;
- the Frameshift semantic profile revision; and
- each advertised protocol-binding and artifact-profile revision.

The TD top-level `profile` member declares required Frameshift profile URIs.
`urn:frameshift:profile:frame:0.1` identifies this semantic profile. Binding
profiles and the Host Outbox profile use separate identifiers. These are
Frameshift contracts; v0.1 does not claim conformance to the W3C WoT Profiles
Working Draft.

A host MUST select a compatible advertised Form. It MUST NOT synthesize an
endpoint from a manufacturer, model, reference class, or assumed path. A frame
MAY publish multiple Forms for one affordance. Form order and the host's
explicit binding preference determine selection; failure to find a compatible
Form is explicit and never triggers an unadvertised fallback.

Frameshift tooling MUST preserve unknown namespaced fields, MUST NOT fetch
remote JSON-LD contexts or Thing Models during admission, and MUST distinguish
an optional unknown extension from a required unknown profile. A consumer MUST
accept unknown optional response members but MUST NOT generate undeclared
input members.

Protocol major `0` identifies the pre-1.0 Frameshift semantic profile. An
incompatible semantic change increments the major; additive optional
affordances increment the minor. Binding revisions and artifact profiles evolve
without changing semantic major when their observable interaction meaning is
unchanged.

### 3.1 Frame Thing affordances

The Frame Thing Model defines these hardware-independent affordances:

| Kind | Name | Meaning |
| --- | --- | --- |
| Property | `capabilities` | Immutable or revisioned geometry, color, refresh, power, storage, artifact profiles, and supported transfer modes |
| Property | `state` | Desired/current/previous-known-good assets, display state, pending request, revision, and last typed failure |
| Property | `playlist` | Current complete still playlist and revision |
| Action | `installAsset` | Store and verify one immutable artifact without activating it |
| Action | `removeAsset` | Collect one unreferenced artifact |
| Action | `setDesired` | Atomically request a verified asset for display |
| Action | `replacePlaylist` | Atomically replace the complete still playlist |
| Action | `retryDisplay` | Retry the current desired asset after an explicit failure |
| Event | `stateChanged` | Optional bounded notification that state should be read and reconciled |
| Event | `displayCompleted` | Optional notification of adapter-confirmed success or typed failure |

Pairing, commissioning, firmware update, diagnostics, and device management are
separate profiles. Their absence does not alter still-display semantics, and
their presence is never inferred from a vendor.

### 3.2 Host Outbox Thing affordances

The host outbox exposes `manifest` and `artifact` read interactions and an
`acknowledge` Action to an already paired frame. Authorization derives frame
identity from the authenticated binding, never from an input `frameId`. The
outbox TD advertises exact Forms and representation constraints; a sleeping
frame does not assume an HTTPS path merely because an earlier implementation
used one.

### 3.3 Capability instances

Vendor, controller, panel, and firmware identifiers MAY appear as descriptive
metadata and as exact revision identities inside an artifact profile. Host
selection uses declared capabilities and profile compatibility. Vendor-specific
code is confined to a display adapter or renderer profile selected by that
identity after semantic compatibility is established.

## 4. Discovery

### 4.1 Direct frames

An awake paired-capable frame advertises `_frameshift._tcp.local` using DNS-SD.
The instance label is an opaque random identifier. TXT records contain only:

| Key | Value |
| --- | --- |
| `v` | Frameshift semantic profile major, currently `0` |
| `id` | opaque device ID or its non-reversible short form |
| `td` | authenticated Exploration URL or path; the reference HTTPS binding uses `/.well-known/wot` |
| `scheme` | one or more bounded advertised binding schemes |
| `pair` | `1` only while physical pair mode is active |

The advertisement MUST NOT include owner, room, artwork, friendly name, panel
model, dimensions, battery level, or network credentials. The full TD requires
authentication. This follows W3C WoT Discovery's introduction/exploration
privacy split.

### 4.2 Host outbox

The Mac MAY advertise `_frameshift-host._tcp.local` while its outbox is
available. TXT contains only semantic profile major, an opaque paired-host ID,
and an authenticated outbox TD introduction URL. A sleeping frame already
knows the host identity and accepts no unpaired outbox.

mDNS is link-local. v0.1 does not discover across routed networks or provide
internet remote access.

## 5. Commissioning and pairing

Commissioning installs network credentials and cryptographic identities;
pairing authorizes a host identity. They are distinct even if one UI performs
both.

The hardware-independent v0.1 requirements are:

1. Every frame has a unique TLS key/certificate and at least 128 bits of random
   one-time bootstrap secret.
2. A QR label or equivalent physical record carries device ID, SHA-256 SPKI
   fingerprint, and the bootstrap secret. The secret MUST NOT appear in mDNS.
   The v0.1 QR payload is bounded UTF-8 JSON with exactly `version: 1`,
   `deviceId`, `serverSpki`, and `secret` fields, as defined by
   `pairing-bootstrap.schema.json`. The secret is canonical unpadded base64url
   for 16–64 random bytes. A QR payload contains no URL: the host discovers
   an endpoint separately and checks its pinned certificate and device ID
   before transmitting the secret.
3. A physical action enables a five-minute pairing window. Network requests
   alone cannot enable it.
4. The host pins the device SPKI fingerprint before sending the bootstrap
   secret and its own client certificate.
5. The frame verifies proof of possession of the client private key, stores the
   allowed certificate fingerprint, and destroys or rotates the one-time secret.
6. Normal protocol traffic uses mutually authenticated TLS.

The pre-pair reference HTTPS exchange is a distinct, fixed bootstrap binding,
not a private TD Form. While physical pair mode is active, the frame accepts
`POST /.well-known/frameshift/pair` over TLS 1.3 with a client certificate.
The host checks the frame certificate's QR-pinned SPKI **before** sending the
secret. The frame validates the TLS certificate and proof of possession, then
parses `pairing-request.schema.json`: exactly `version`, `requestId`,
`deviceId`, and `secret`. A certificate supplied in JSON is never authority.
The request ID is a bounded idempotency key; after success, only the same ID
from the same authenticated host certificate may replay successfully. The
one-time secret is consumed on first success. Five rejected attempts close the
window until another physical action, and the window expires after five
minutes. The successful response identifies the device and allowed host
certificate fingerprint but never echoes the secret. Errors use bounded
problem documents without disclosing whether the ID, secret, or certificate
was wrong. The host then retrieves the full TD through the authenticated
DNS-SD introduction URL and checks its device ID against the QR record.
The reference simulator serves `GET /.well-known/wot` only to the exact host
certificate admitted by the physical pairing state. The pre-pair route never
exposes the TD, including to a TLS client presenting another certificate.

If the pair response or subsequent TD read is lost, the host MUST NOT send the
one-time secret again under a new request ID. An explicit recovery action may
read only the fixed authenticated TD introduction after rechecking the physical
QR record, selected discovery ID, existing host identity, and pinned frame
certificate. The QR secret may cross the protected local IPC again for strict
record parsing, but recovery never puts it on the frame network. Admission
still requires the matching device ID and HTTPS origin. A failed recovery
leaves the frame unpaired locally and reports an uncertain or incomplete state.

Persisting that admitted identity is idempotent only for the same canonical TD,
credential reference, and pinned frame SPKI. A changed pin, credential
reference, or TD is not accepted by replaying pairing admission. One server
SPKI cannot be assigned to two device IDs. Explicit certificate rotation and
TD refresh need separately authenticated, versioned operations that preserve
pending delivery and content references.

Firmware must obtain the actual peer certificate from the completed TLS session;
its absence always refuses pairing and protected operations. Before first
pairing, certificate-chain trust may be unavailable: an explicitly profiled
bootstrap handshake can admit that uncertainty only while requiring the client
certificate, TLS proof of private-key possession and the physical/secret/request
checks above. Optional chain verification is not authorization. After pairing,
every protected request checks the exact durable admitted fingerprint; another
CA-valid certificate is insufficient. Missing peer export, malformed certificate,
failed private-key proof or an unavailable authority store fails closed. Keep
certificate bytes, per-session identity and handshake/body/task lifetimes bounded;
no application header or payload can substitute for TLS identity.

The [pinned ESP-IDF/Mbed TLS inspection and native handshake matrix](../research/hardware-platforms.md#tls-commissioning-pinned-source-and-native-handshake-findings)
identify candidate-specific configuration traps. Firmware acceptance must join
its actual SDK peer/session export to these request checks, including anonymous
and wrong-peer refusal, authority restart and lost-response recovery. Native
library handshakes alone do not complete that join or qualify device key storage.

A temporary USB setup connection is permitted and does not violate a cable-free
installed frame. BLE or temporary access-point commissioning MAY be added by a
hardware profile, but cannot weaken certificate pinning or physical pair mode.

Short numeric PIN authentication without a reviewed PAKE is prohibited. Device
private keys SHOULD live in secure hardware on manufactured devices. Recovery,
host replacement, and factory reset require physical access.

## 6. Transport and binding rules

- Every Form used for private state or mutation MUST select a binding profile
  that provides mutual peer authentication, integrity, confidentiality, bounded
  messages, and an explicit absolute deadline.
- The v0.1 reference LAN binding is HTTPS with mutual TLS. TLS 1.3 SHOULD be
  used; any TLS 1.2 fallback must be explicitly profiled and independently
  reviewed.
- A CoAP, MQTT, BLE, Matter, or gateway binding MAY coexist when its complete
  operation mapping and security profile are advertised and pass conformance.
- Frame and host validate the pinned or allowlisted peer identity required by
  the selected Form, not merely a public hostname or transport connection.
- Mutating requests MUST NOT follow redirects.
- Mutating requests MUST NOT be retried unless the method, digest, and
  precondition make the retry idempotent.
- Every request has an absolute deadline. A timeout is an unknown result until
  state is read again.
- Credentials are resolved immediately before transport and never serialized
  into domain requests, results, recipes, TDs, or logs.
- Control JSON uses UTF-8 and `application/json`. Duplicate object keys are
  rejected.
- HTTP errors use `application/problem+json` as defined by RFC 9457. Other
  bindings map the same stable Frameshift problem codes without copying
  transport exception text or credentials.

## 7. Bounds

An implementation MAY advertise smaller values. It MUST enforce bounds before
allocation where possible.

| Item | v0.1 upper bound |
| --- | --- |
| Thing Description | 256 KiB decoded bytes |
| Other control JSON | 64 KiB decoded bytes |
| JSON nesting | 32 levels |
| Request target | 1 KiB |
| Header fields | 64 |
| One header value | 8 KiB |
| Asset bytes | advertised `maximumAssetBytes` |
| Playlist entries | advertised `maximumPlaylistLength` |

Asset upload/pull requires a known content length. A frame MAY reject chunked
asset transfer in v0.1. Decompression bombs are avoided by negotiating exact
artifact profiles and validating decoded dimensions before commit.

## 8. Reference HTTPS binding

The paths below define the v0.1 HTTPS Form profile. They are interoperable
defaults for that binding, not the semantic identity of an operation. The TD
Form is authoritative and a host MUST follow its `href`, method, content type,
operation, security, and Frameshift binding metadata.

| Method and path | Purpose | Success |
| --- | --- | --- |
| `GET /.well-known/wot` | Authenticated Thing Description | `200` |
| `GET /v0/capabilities` | Read `capabilities` Property | `200` |
| `GET /v0/state` | Read `state` Property | `200` |
| `HEAD /v0/assets/sha256/{digest}` | Test immutable asset presence | `200` or `404` |
| `PUT /v0/assets/sha256/{digest}` | Store verified immutable asset | `201` new, `204` already identical |
| `GET /v0/assets/sha256/{digest}` | Retrieve for audit/recovery when allowed | `200` |
| `DELETE /v0/assets/sha256/{digest}` | Collect an unreferenced asset | `204` |
| `PUT /v0/desired` | Invoke idempotent `setDesired` | `200` current or `202` pending |
| `GET /v0/playlist` | Read `playlist` Property | `200` |
| `PUT /v0/playlist` | Invoke idempotent `replacePlaylist` | `200` or `202` |
| `POST /v0/actions/retry-display` | Retry current desired asset | `202` |
| `GET /v0/events/state` | Optional `stateChanged` / `displayCompleted` event stream | `200` stream |

Pairing and firmware-update resources are intentionally separate profiles. They
are never inferred from the existence of the display API.

An SSE Event Form declares `contentType: application/json` because its data is
the Interaction Affordance representation, and declares `subprotocol: sse` for
the HTTP stream mapping. `text/event-stream` is the wire response media type,
not the Form's event-data representation type.

## 9. Asset upload

The upload request MUST contain:

```text
Content-Type: <advertised media type>
Content-Length: <bounded byte count>
Content-Digest: sha-256=:<RFC 9530 base64 digest>:
Frameshift-Artifact-Profile: <advertised profile id>
If-None-Match: *
```

The URI hex digest and `Content-Digest` MUST identify the same bytes. The frame
streams into an inactive temporary slot while hashing. It validates size,
profile, dimensions/header, and digest before atomically publishing the digest
path. A mismatch returns a digest problem and deletes the candidate.

If the digest is already present with matching metadata, the operation is a
successful no-op. If bytes or profile metadata conflict for the same digest,
the frame returns `409` and marks storage health degraded; SHA-256 identity is
never silently redefined.

Upload does not change desired or current state.

Artifact metadata must retain the canonical digest of its exact artifact
profile, color and geometry snapshot. Use the same RFC 8785/SHA-256 projection
as [render qualification](qualified-generations.md); retain profile fields and
limits, but exclude surrounding storage availability and health. A profile ID
alone is insufficient. Cache eligibility, desired
acceptance, retry, playlist advancement and the already-displayed outbox path
must compare that frozen digest with the advertised snapshot before claiming
compatibility or completion. Missing or changed identity refuses.

Restart retains last-valid bytes and desired/current/previous pointers when a
profile changes, but reports recovering/degraded state and cannot replay the
asset or issue a fresh displayed acknowledgement under the new profile.
Reinstalling a digest with conflicting metadata must preserve its original
association and report the existing conflict outcome with durable degraded
storage health. No automatic rehash, metadata rewrite, artwork deletion or
profile migration is authorized. A firmware/profile update that requires such
a migration needs its own qualified recovery contract; ordinary firmware
updates that preserve the artifact contract remain independent.

The closed [indexed4 artifact contract](content-pipeline.md#closed-indexed4-software-profile)
uses explicit `packing`, `paletteRevision` and `colorProfileRevision` fields.
Palette array positions and hardware `wireCode` values are distinct. Its exact
length is native width × height / 2, with even rows and both nibbles belonging to
the advertised code set. Reject wrong length, undeclared codes, unknown packing
and stale profile identity before publication or activation. Controller row
slicing belongs to the physical adapter; it cannot alter the artifact digest.

## 10. Desired and current state

Reading the selected `state` Property Form includes at least:

```json
{
  "stateRevision": 42,
  "displayState": "displayed",
  "desiredAsset": "sha256:0123...",
  "currentAsset": "sha256:0123...",
  "previousKnownGood": "sha256:abcd...",
  "pendingRequestId": null,
  "lastError": null
}
```

The response has a strong ETag derived from `stateRevision`.

Invoking `setDesired` contains `assetDigest`, `artifactProfile`, and a host-generated
`requestId`. It MUST include `If-Match` with the last read state ETag or
`If-None-Match: *` for initial empty state. The referenced asset must already be
verified.

Processing order is:

1. atomically store desired digest, profile, and request ID;
2. prepare the display adapter without changing `currentAsset`;
3. perform the physical still-image update;
4. on confirmed success, move old current to previous-known-good and desired to
   current in one metadata transaction;
5. on failure, retain current and record a typed error against the request.

Repeating the same PUT with the same request ID and body returns the same
operation/state. Reusing a request ID with different content returns `409`.
A `202` means accepted/pending, not displayed. The host confirms success by
observing `currentAsset` and `displayState: displayed`.

`displayState` is one of `empty`, `preparing`, `refreshing`, `displayed`,
`failed`, or `recovering`.

## 11. Still-image playlists

A playlist is a complete replace operation containing a revision, mode, and
ordered entries:

```json
{
  "revision": "sha256:...",
  "mode": "cycle",
  "entries": [
    {"assetDigest": "sha256:...", "dwellMs": 21600000}
  ]
}
```

All referenced assets MUST already exist. Every dwell MUST meet the capability
minimum. The frame either accepts the whole playlist or none of it. Mode `hold`
shows one selected entry; `cycle` swaps complete cached stills. Crossfades,
scrolling, interpolation, animated formats, and motion transitions are invalid.
The frame owns the relative timer, starts each dwell after confirmed display,
and persists enough cursor/deadline state to recover without skipping or
claiming an unconfirmed image. The optional profile suggestion and explicit
per-frame pinned loop intent are defined in [display timing](display-timing.md).

Wall-clock schedules are optional and require an advertised trustworthy-clock
capability. Relative dwell playlists do not.

## 12. Sleeping-frame outbox mode

A sleeping frame initiates the connection. Mutual TLS maps the caller to one
device, so the host never accepts a caller-supplied identity as authorization.
When at least one paired pull-capable frame exists, the Mac host binds a
supervised local-network listener using its Keychain identity and publishes a
privacy-minimal `_frameshift-outbox._tcp` Bonjour service with only the v0
version hint. The frame discovers candidate hosts locally, checks the pinned
host certificate before sending an authenticated outbox request, and selects
the Host Outbox Thing's advertised Forms. Bonjour is never identity evidence.
If no pull-capable frame is paired, the listener and advertisement stop. A
listener startup failure leaves desired work durable and visible as pending.

The Host Outbox Thing advertises these semantic interactions. Its reference
HTTPS Forms use the paths shown, but a frame consumes the advertised Forms.

| Reference HTTPS Form | Purpose |
| --- | --- |
| `GET /v0/outbox/manifest` | Return desired digest/profile/playlist revision or `204` |
| `GET /v0/outbox/assets/sha256/{digest}` | Stream exact artifact with `Content-Digest` |
| `GET /v0/outbox/playlists/sha256/{digest}` | Fetch the complete canonical playlist whose digest is in the manifest |
| `POST /v0/outbox/ack` | Report verified storage, refresh outcome, and current digest |

When `playlistRevision` is present, the receiver fetches that exact complete
playlist before acknowledgement, verifies its canonical revision and every
referenced cached or newly fetched asset, and installs it atomically. The
manifest `desiredAsset` is its first entry. The host authorizes all entries of
only the current pending revision to the authenticated frame. A failed body,
asset, or display step leaves the old active playlist and current image intact;
the host retains the pending intent. After confirmed display of the first entry,
one matching acknowledgement activates the pending playlist and releases the
old playlist references. A single-image desired update suspends the prior loop.

The frame first compares the manifest digest with local desired/current state.
It downloads only missing bytes. The host keeps a manifest until a confirmed
ack or the user supersedes it. If the host is absent, authentication fails, or
no work exists, the frame returns to sleep without changing current artwork.

An optional always-on bridge may host the same outbox later. It receives only
rendered artifacts and frame instructions, never AI credentials or the full
host library.

## 13. Error model

Problem details include a stable `type`, human-readable `title`, HTTP `status`,
and `requestId` when safe. Candidate problem types include:

- `urn:frameshift:problem:authentication-required`
- `urn:frameshift:problem:pair-mode-required`
- `urn:frameshift:problem:unsupported-protocol`
- `urn:frameshift:problem:unsupported-profile`
- `urn:frameshift:problem:asset-too-large`
- `urn:frameshift:problem:digest-mismatch`
- `urn:frameshift:problem:asset-missing`
- `urn:frameshift:problem:state-precondition`
- `urn:frameshift:problem:request-id-conflict`
- `urn:frameshift:problem:storage-full`
- `urn:frameshift:problem:display-failed`
- `urn:frameshift:problem:power-insufficient`

Problems MUST NOT contain credentials, bootstrap secrets, private paths, prompt
text, or artwork bytes.

## 14. Storage and recovery

- Current and previous-known-good artifacts are protected.
- Temporary assets older than the profile's recovery window may be removed at
  boot after their metadata journal is examined.
- Garbage collection deletes only unreferenced verified artifacts.
- Metadata updates use redundant records, checksums, and monotonic revisions or
  an equivalent power-loss-safe scheme.
- Boot verifies current metadata and artifact digest before asking the adapter
  to restore output.
- A bistable frame does not refresh merely because it rebooted if the retained
  panel image and confirmed metadata are consistent.

Missing, wrong-length, corrupt or nonregular cached objects cannot authorize
activation or a fresh displayed acknowledgement, including the cached outbox
shortcut. Verify exact recorded length and SHA-256 within a bounded read before
using cached bytes. Boot must remain available for recovery, retain protected
metadata/pointers and any surviving bytes, and report recovering display state
with degraded storage health. Do not delete, overwrite or manufacture content
for a recorded digest. Successful display of a different verified asset does
not establish repair of corrupt storage. The receiver's physical completion
signal and flash/power-loss qualification remain independent of these checks.

## 15. Compliance tests

A conforming v0.1 implementation must demonstrate:

1. unpaired LAN clients cannot read the full TD, upload, activate, or list
   artwork;
2. power loss at every upload and metadata-write boundary retains a valid
   current asset;
3. a wrong digest, profile, dimension, or oversized body never reaches the
   display adapter;
4. repeated identical PUTs are safe and request-ID conflicts are rejected;
5. a `202` is never reported as physically displayed;
6. current and previous-known-good survive collection and firmware update;
7. a sleeping frame can miss multiple wake windows and later converge on the
   newest outbox manifest;
8. playlist switches are discrete still-image changes;
9. no endpoint accepts video, animated image playback, audio, or arbitrary
   remote fetch URLs;
10. secrets are absent from TDs, logs, errors, and packet captures after the
    encrypted transport boundary.
11. two TDs with the same semantic affordances but different valid Form targets
    interoperate without code changes or vendor branching;
12. unknown optional extension terms survive a read/modify/write round trip,
    while an unknown required profile fails before any transport call;
13. binding selection is deterministic and never falls back to an unadvertised
    scheme; and
14. each conformance result names its evidence profile: value, runtime,
    binding, live transport, firmware, hardware, security, or production.

## 16. Open gates before v1.0

- independent pairing and TLS review;
- exact secure-element and certificate rotation profile;
- commissioning transport per controller;
- versioned Thing Models, conformance fixtures, and canonical TD examples;
- live interoperability of at least two independent Form targets for the same
  semantic interaction;
- final artifact media-type registration/naming;
- measured retry/deadline values for each hardware class;
- recovery behavior when a panel update is interrupted electrically;
- multi-host ownership and revocation policy.
