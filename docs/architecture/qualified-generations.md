# Qualified Render and Transfer Generations

**Status:** normative design; implementation and conformance evidence are tracked
separately in the [verification map](verification.md)

## Purpose and ownership

Frameshift may change a renderer build, frame capability instance, artifact
profile, generation provider, or transfer binding while accepted work is in
flight. The host must bind each new job and delivery intent to one exact,
qualified combination. This is a local contract for the Rendering and Delivery
boundaries under the single SQLite writer. It does not create a SaaS tenant or
move original assets, recipe lineage, rendered bytes, or confirmed display
state out of Frameshift.

The September 2026 adaptive adoption atlas proposes an asset/profile
generation for this repository. This specification narrows that proposal to
the bytes and effects that require stable compatibility.
SwiftUI presentation may change independently. A generation provider is part
of the generation recipe that produces a master; a target render generation
pins the resulting immutable master and its recipe lineage.

## Immutable identity and outcome

A qualification manifest describes a reusable renderer/profile/transfer
binding. It is versioned canonical JSON, identified by SHA-256 of those exact
canonical bytes. It excludes source art so one admitted binding can serve many
masters. Required identity fields are:

- frame ID and admitted canonical Thing Description digest;
- selected artifact profile ID and canonical profile/capability digest;
- renderer binary digest, renderer protocol revision, and deterministic
  algorithm revision;
- transfer binding identity, selected advertised Form contract, connector
  implementation revision, and required security/effect semantics.

An accepted work manifest combines one admitted qualification digest, source
master digest, and canonical composition recipe digest. Its digest is SHA-256
of its own versioned canonical bytes. It exists before rendering and is pinned
to that job and its delivery intents. An immutable result binds the work digest
to the exact rendered wire-byte digest, byte count, and media type. The final
artifact digest cannot be an input to the work manifest because it does not
exist before rendering. It remains SHA-256 of the exact wire bytes, independent
of database IDs and manifest metadata. Multiple recipe/profile/renderer
identities may produce the same wire bytes. The library stores one content
object for that digest and a separate durable mapping for each recipe identity;
cache lookup and qualification result validation use the exact mapping.

Manifests contain no credential, provider context, raw source bytes, raw
endpoint URL, UI layout, or mutable health data. No result may rewrite a
qualification, work identity, or artifact identity. Qualification evidence is
recorded separately and names the exact fixture suite or physical cohort.

An operation descriptor for each renderer and transfer connector declares its
version, scope, input/output schema, authority and credential audience, effect
class, evidence shape, compatibility rules, and unavailable or ambiguous
outcomes. The host admits only an exact compatible descriptor and profile
combination. Optional WoT extensions are preserved; required unknown profiles
fail closed. The frame receives the existing protocol artifact digest and
profile. A work digest is host custody metadata unless a separately
versioned frame affordance is specified and qualified.

## Admission, pinning, and rollback

Candidate qualification validates the admitted frame identity, profile,
renderer, and connector without a network effect. It records the exact
software fixture suite and, for a physical cohort, measured device evidence.
Candidate, admitted, and retired states are durable. One active qualification
pointer per frame selects *new* work. A candidate cannot activate itself. A
cohort promotion selects admitted bindings for up to 64 distinct paired frames
in one local SQLite transaction. Every binding must still match its frame's
current capability and transfer contract. A refusal leaves all active pointers
and activation audit records unchanged, including when a database write fails
after an earlier frame in the cohort was updated. The Library must stay alive
and report that storage failure. Repeating a successful selection is
idempotent. The single writer serializes validation and promotion, so another
local command cannot change a frame between those steps. New work also
validates its master and recipe before claiming a work digest. Product queue
commands select the active binding's artifact profile and transfer mode before
compiling a render job.

An accepted render job and both push and pull delivery intents record the
work digest and qualification digest. Retries, acknowledgements, and
reconciliation use that frozen record even after another qualification is
activated. Revision, request
ID, artifact digest, authenticated frame identity, and authoritative display
state still govern confirmation. Only confirmed display advances current and
previous-known-good. Both accepted pending work and last-good bytes remain
protected from collection. Rollback changes the pointer for future work; it
never reassigns an in-flight intent or claims that a frame changed display.

Existing pre-qualification work is preserved across restart with an explicit
legacy/unqualified marker. It can be reconciled using its original identity
and digest, but must not be reported as having passed new qualification. Once a
frame has an active admitted binding, a new pull or push intent must carry an
accepted work digest. A pending legacy push may replay only its exact request,
artifact, and profile; its original confirmation can still finish after a
restart. A previously queued legacy pull acknowledgement may also finish, but
neither path may create new unqualified work under the active binding.

## Diagnostic and verification contract

Audit and native logs include work, qualification, command, and attempt IDs with bounded
public fields. Metrics count qualification refusal, render outcome, transfer
attempt, unknown network outcome, and confirmed display with bounded dimensions such
as outcome and mode. Work, qualification, frame, recipe, and attempt IDs are excluded
from metric labels. Health exposes qualification coverage and loss/reset status.

The software conformance suite must cover incompatible geometry/color,
changed profile content under the same display name, renderer build change and
rollback, exact byte replay, unsupported connector substitution, duplicate
transfer, power-off timeout, candidate switch during pending work, restart
recovery, last-good retention, and reconciliation of pre-qualification pending
work. Physical panel refresh, certificate custody, signing, packaging, and
independent device interoperability remain separate release evidence gates.
