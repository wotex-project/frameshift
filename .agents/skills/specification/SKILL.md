---
name: specification
description: Define or review requirements when changing product behavior, architecture, protocol, host interaction, or hardware constraints, and before implementing a contract whose behavior or acceptance evidence is unclear. Combine specification authoring with a review of the affected implementation boundary.
user-invocable: false
---

# Specification

**Inputs:** requested behavior or contract question, owning document,
implementation and consumers, relevant evidence, and known constraints.

**Output:** observable requirements in the existing owning document when edits
are requested, or a review in chat. Identify concrete contract gaps, their
file/line locations, and the evidence needed to close them. Do not create a
separate readiness report or require one for a narrow, already-specified fix.

## Define the affected contract

1. Read the owning specification and both sides of each changed interface.
   Check implementation, tests, linked research, and relevant decision history.
   Resolve facts needed for the requirement using decision research; do not
   replace unknown behavior with plausible names or APIs.
2. State the owner, scope, inputs/outputs, accepted identities and revisions,
   invariants, lifecycle transitions, and failure/recovery behavior. Include
   offline operation, authorization, privacy, compatibility, and physical
   constraints where the mechanism makes them relevant.
3. Define acceptance at the tier the requirement needs: pure fixtures, joined
   producer/consumer tests, live transport, installed lifecycle, or exact
   physical measurements. Name the environment, observable pass condition,
   existing test or required fixture, and remaining external dependency.
4. Extend the existing document's structure. Keep intended requirements,
   candidate implementation directions, and completed evidence distinguishable.
   Use normative keywords only for deliberate requirements.

## Review before implementation

- Trace each changed requirement through its actual consumer and refusal or
  recovery path. Check that capability/profile selection, state transitions,
  accepted work identities, and rollback meaning remain consistent.
- Check proposed paths, commands, types, and exports against the repository or
  exact upstream revision. Mark proposals and missing producer exports plainly.
- Verify that an implementer can act without inventing ownership, behavior, or
  acceptance conditions. An unavailable device or credential is an evidence
  dependency; undecided behavior is a contract gap. Continue independent work
  whose contract is defined.
- Align changed requirements with the
  [implementation plan](../../../docs/architecture/implementation-plan.md) and
  [verification map](../../../docs/architecture/verification.md) when their
  scope or evidence changes. Keep review findings and actual test results
  separate from planned acceptance.
