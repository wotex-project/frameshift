# Protocol Foundations

**Research date:** 2026-09-22
**Evidence state:** selected standards and implementation reference

## Outcome

Frameshift uses the W3C Web of Things interaction model as its universal IoT
boundary. Frames and host outboxes are Things described by Thing Description
1.1 documents; reusable behavior is described by Thing Models; properties,
actions, events, and Forms keep display semantics independent from transports
and hardware vendors.

Frameshift adds only the vocabulary needed for immutable still assets,
display-state truth, artifact profiles, playlists, and frame capabilities. A
reference HTTPS binding is required for the first interoperable release, but
canonical paths are binding details rather than the semantic protocol. Other
bindings can be added when they preserve the same operation and security
contracts.

## Primary standards

| Concern | Foundation | Frameshift use |
| --- | --- | --- |
| Interaction model | [W3C WoT Architecture 1.1](https://www.w3.org/TR/wot-architecture11/) | Thing, Consumer, Property, Action, Event, protocol binding, and deployment roles |
| Capability/interface description | [W3C WoT Thing Description 1.1](https://www.w3.org/TR/2023/REC-wot-thing-description11-20231205/) | TD instances, Forms, DataSchemas, security definitions, extension vocabulary, and reusable Thing Models |
| Discovery | [W3C WoT Discovery](https://www.w3.org/TR/2023/REC-wot-discovery-20231205/) | privacy-preserving Introduction and authenticated Exploration |
| HTTP semantics | [RFC 9110](https://www.rfc-editor.org/rfc/rfc9110) | idempotent methods, validators, conditional requests, and explicit response semantics |
| Upload integrity | [RFC 9530](https://www.rfc-editor.org/rfc/rfc9530) | `Content-Digest` for streamed artifact representations |
| Structured failures | [RFC 9457](https://www.rfc-editor.org/rfc/rfc9457) | `application/problem+json` transport errors |
| Local introduction | [mDNS RFC 6762](https://www.rfc-editor.org/rfc/rfc6762) and [DNS-SD RFC 6763](https://www.rfc-editor.org/rfc/rfc6763) | link-local discovery of an authenticated Exploration URL |
| Requirements language | [RFC 8174](https://www.rfc-editor.org/rfc/rfc8174) | normative requirement words |

Thing Description is deliberately not another low-level wire protocol. It
describes stable interaction affordances and the Forms that bind them to one or
more concrete protocols. That separation is the reason a frame with an HTTPS
server, a sleeping CoAP endpoint, or a gateway-backed device can implement the
same Frameshift semantics without host code branching on its vendor.

The current [W3C WoT Profiles](https://www.w3.org/TR/2025/WD-wot-profile-20251104/)
document is a Working Draft dated 2025-11-04, not a Recommendation. The WoT
Binding Templates series was retired by W3C on 2025-11-04. Frameshift may use
their concepts and the TD 1.1 `profile` member, but it MUST describe its binding
mappings as Frameshift contracts and MUST NOT claim W3C Profile or Binding
Templates conformance. Wotex makes the same evidence distinction for its HTTP
mapping.

## Wotex implementation reference

The dependency source was inspected at commit
`e6aa01a69ea35447afa989d5dea061618d20b3cf` dated 2026-09-22 from the Wotex
GitHub organization at `https://github.com/wotex-project/wotex.git`. The
repository declares
Apache-2.0; the inspected `LICENSE` SHA-256 is
`f5b91731217e7913145b2b9ad04f63656a8a16d2b0e9ecca9bd256fbfc26a4d9`.
No package was published to Hex at the inspected revision.

Wotex is an implementation reference, not the Frameshift protocol authority.
Its specifications provide concrete patterns that Frameshift adopts:

1. **Bounded admission before use.** TD JSON has byte, depth, node, string, and
   collection limits; duplicate members and invalid UTF-8 fail explicitly.
2. **Extension preservation.** Unknown namespaced JSON members survive
   parse/map/encode. Preservation does not imply that an extension is
   understood or authorized.
3. **No remote context loading.** Runtime parsing never dereferences JSON-LD
   contexts, schemas, vocabularies, or Thing Model references.
4. **Deterministic Form selection.** Selection follows document order and an
   explicit ordered binding preference; absence is typed rather than guessed.
5. **Explicit application ownership.** The consuming application owns
   canonical state, authorization, credentials, endpoint policy, persistence,
   supervision, retries, and proof of physical effects.
6. **Ephemeral credentials.** Credentials are resolved at the last transport
   boundary and never enter TDs, domain requests, results, telemetry, or public
   errors.
7. **Protocol success is not effect truth.** A successful exchange cannot by
   itself prove that a panel refreshed. Frameshift reconciles `currentAsset`
   and display state after adapter completion.
8. **Passive libraries and caller-owned work.** Libraries start no global
   processes; long-lived observations return child specifications for the
   product supervisor.
9. **No hidden retry.** Bindings classify failure, while the product decides
   whether an operation is safe and still within one absolute deadline.
10. **Scoped conformance evidence.** Value, runtime, binding, live transport,
    hardware, certification, and production are different evidence profiles;
    a simulator result cannot satisfy a hardware claim.

The inspected Wotex HTTP package supports JSON property/action operations and
SSE through a consumer-supplied client. It intentionally does not provide an
HTTP server, connection pool, TLS policy, binary artifact representation, or
proof of Action effects. Frameshift therefore must supply its own bounded
binary artifact mapping, mutual-TLS client/server ownership, and display-state
reconciliation around the selected Wotex Forms.

Frameshift consumes `wotex`, `wotex_runtime`, and `wotex_binding_http`, all
pinned in `apps/core/mix.lock` to the inspected full commit from the Wotex
GitHub organization. No sibling path participates in the build; `../wotex` may
advance independently. At that revision WTX.01 through WTX.04 and WRT.01
through WRT.03 are catalogued as implemented, with their claims explicitly
limited to the listed TD/TM/value/runtime mechanics rather than full W3C
conformance. The packages declare Apache-2.0 and include the inspected license;
`wotex` also ships a notice for its modified W3C TD schema. Frameshift tests
the exact admission, selection, and HTTP-port behavior it relies on instead of
inheriting a broader upstream claim. Repository-wide license and notice
assembly is still required before distribution.

## Universal semantic boundary

The Frame Protocol specification is divided into three layers:

1. **Thing Model and vocabulary:** hardware-independent Properties, Actions,
   Events, DataSchemas, state meanings, and extension terms.
2. **Capability and artifact profiles:** exact geometry, color, storage,
   refresh, power, packing, and adapter revisions. Vendor-specific measured
   profiles live here as data.
3. **Protocol bindings:** HTTPS first; future CoAP, MQTT, BLE, Matter, or
   gateway bindings only where their operation mapping, integrity,
   authentication, deadlines, and recovery semantics are fully specified.

A binding does not change the meaning of `desiredAsset`, `currentAsset`, or a
display-completion event. A hardware profile does not create a new endpoint
family. A manufacturer name is never a compatibility algorithm.

## Discovery privacy

WoT Discovery separates Introduction from Exploration. Frameshift follows that
split:

- DNS-SD advertises an opaque instance, supported exploration schemes, and an
  Exploration URL or path; it does not advertise owner, room, artwork, panel
  model, dimensions, battery state, or credentials;
- an unpaired frame exposes only the physical-pairing introduction surface;
- the full TD requires authentication and authorization; and
- a TD Directory or gateway is optional and cannot become a mandatory cloud.

mDNS is link-local. Routed or remote discovery requires a separately specified
and authorized directory/relay deployment; it is not achieved by leaking the
full TD in TXT records.

### Linux discovery adapter

On 2026-10-04 the bounded CLI adapter selects the existing system Avahi client
rather than embedding a second multicast stack or introducing a general D-Bus
client solely for discovery. [Avahi's API guidance](https://avahi.org/doxygen/html/)
recommends its daemon APIs and discourages multiple desktop mDNS stacks. The
command uses the upstream client through fixed arguments and the existing
system bus; it does not interpret TXT as an authenticated TD. Native D-Bus
integration remains an alternative if a measured long-lived service requires
it, not an extra implementation alongside this snapshot.

`gh` source inspection covers [Avahi v0.8 browse/resolve output](https://github.com/avahi/avahi/blob/f060abee2807c943821d88839c013ce15db17b58/avahi-utils/avahi-browse.c)
(`print_service_line`, `service_resolver_callback`, `check_terminate`; blob
`4101895ee208df33b3a7de3b4472a69dfd521d84`) and [TXT string encoding](https://github.com/avahi/avahi/blob/f060abee2807c943821d88839c013ce15db17b58/avahi-common/strlst.c)
(`avahi_string_list_to_string`; blob `f09ec3885555d106383e56f5353e0cba63779129`).
TXT quoting escapes quote/backslash and uses three-digit decimal bytes outside
printable ASCII; service labels have distinct DNS escapes in
[domain.c](https://github.com/avahi/avahi/blob/f060abee2807c943821d88839c013ce15db17b58/avahi-common/domain.c).
Splitting TXT on spaces/semicolons or turning it into a map before duplicate
detection loses required information. The same output boundaries were checked
in current upstream commit `3ed8102c8a881e6fe273bbf06f45e86dccf51e02`.

[GNU timeout source](https://github.com/coreutils/coreutils/blob/a2415242cbb428b6cbf66fe00fceb1eba21af514/src/timeout.c)
creates a process group and propagates the chosen signal to the child and
group. KILL avoids relying on the helper to cooperate with a deadline. Runtime
fixtures must check actual child exit, bounded output and finite unavailable
results; source inspection alone proves none of these joins. The existing
Linux/OTP fixture image contains coreutils 9.7-3 but no Avahi or D-Bus, so its
helper doubles cannot establish actual Avahi discovery. The separate
`scripts/check linux-discovery` lane builds an isolated producer fixture from
that exact base and the signed Debian snapshot `20260930T000000Z`, pinning
Avahi `0.8-16` and D-Bus `1.16.2-2`. The 2026-10-04 arm64 run passes actual
browse/resolve, clean nonroot CLI, private/duplicate TXT and conflicting-ID
refusal, daemon loss and restart. The snapshot authenticates public package
bytes with the Debian archive keyring and retained checksums; its HTTP download
uses no credentials, and only archive expiry is disabled for the fixed date.
This is Debian software-fixture evidence, not an Ubuntu installed release,
native SQLite/renderer closure or physical-frame qualification. Target package
dependency closure remains required.

## Pairing conclusion

A short numeric PIN without a reviewed password-authenticated key exchange is
not sufficient against an active local attacker. The hardware-independent
contract uses physical possession plus high-entropy bootstrap material:

1. provisioning creates a unique device identity and at least 128 bits of
   one-time bootstrap entropy;
2. a QR or equivalent physical record carries device identity, pinned public
   key fingerprint, and bootstrap material;
3. a physical action opens a bounded pairing window;
4. the Mac pins the device identity, sends its client identity, and proves
   private-key possession;
5. the frame stores the authorized client fingerprint and destroys or rotates
   the bootstrap material; and
6. normal Forms require mutually authenticated transport security.

The exact credential type can differ by qualified controller and binding. A
software key on a prototype and a secure element in a manufactured device are
different evidence levels, not different interaction semantics. Rotation,
multi-owner policy, lost-host recovery, factory reset, and independent review
remain mandatory security gates.

## Binding selection

HTTPS is the first reference binding because macOS and embedded stacks support
TLS, conditional methods, streamed bodies, digest fields, and inspection during
bring-up. It is not the definition of Frameshift itself.

CoAP with Block1/Block2 and DTLS or OSCORE is a credible sleeping-device
binding, and MQTT is a credible powered/gateway interaction binding. Neither is
claimed until a complete Form mapping covers binary assets, idempotence,
preconditions, authentication, deadlines, state reconciliation, and negative
conformance cases. The host chooses among Forms the frame actually advertises.

## Prohibited shortcuts

- Do not derive compatibility from a vendor or model name.
- Do not make canonical HTTP paths the only source of operation semantics;
  consume the advertised Forms.
- Do not advertise a complete TD or private metadata in DNS-SD TXT records.
- Do not fetch arbitrary remote contexts, schemas, models, or artwork URLs.
- Do not accept a digest only from mutable JSON; hash streamed representation
  bytes and compare the URI and `Content-Digest` identities.
- Do not forward credentials across an unapproved redirect or Form target.
- Do not retry a mutation or physical Action merely because a transport error
  was classified transient.
- Do not equate an accepted response with a physically displayed image.
- Do not use simulator, binding, or protocol evidence as hardware evidence.
