---
name: decision-research
description: Resolve architecture, protocol, runtime, component, or sourcing decisions when required facts or the reason for an existing boundary are missing. Apply before revising those decisions or turning external claims into requirements; use repository evidence and current primary sources.
user-invocable: false
---

# Decision research

**Inputs:** the decision or unresolved question, affected owner, existing
requirements, and evidence available in the repository or named sources.

**Output:** a supported recommendation with source locators, alternatives,
uncertainty, affected boundaries, and the next check that could reject it.
Return it in chat unless the task calls for maintained decision or research
content; extend the existing owning document in that case.

## Reconstruct the decision

1. Read the relevant [decision ledger](../../../docs/decisions/README.md), owning
   specification, consumers, code, and tests. Consult
   [open questions](../../../docs/research/open-questions.md) and targeted Git
   history when they bear on the question.
2. Identify the protected user outcome or invariant, alternatives considered,
   evidence available at the time, and later changes. Separate an intentional
   boundary from a convenient prototype detail. If the reason is not recorded,
   say so and label any reconstruction as inference.
3. For a proposed reversal, trace the affected interfaces and lifecycle:
   host/frame ownership, capability selection, accepted identities, offline
   operation, security, physical constraints, and recovery. Review only the
   surfaces the change can affect; do not expand into unrelated subsystems.

## Resolve missing facts

1. State the requirement, alternatives, and disqualifying conditions before
   comparing solutions. Prefer standards, manufacturer drawings/manuals,
   upstream documentation and source, or reproducible technical research.
2. Record exact URLs or repository paths, source revisions, relevant locators,
   and observation/retrieval dates. Reconcile contradictory, superseded, and
   missing evidence instead of counting agreeing sources.
3. For hardware, distinguish document revision from received part revision and
   compare the complete installation envelope. For a runtime or library,
   inspect the relevant exported boundary and consumer fixture; a product page
   or successful compile does not establish integration behavior.
4. Show calculated inputs, units, formula, and margins. Separate supplier price
   and stock observations from technical fit. Identify missing facts that
   prevent the decision and the inspection or experiment that can resolve them.
5. Recommend a bounded next action and explain what would invalidate it.
   Reference exact test evidence for a validation claim. When an authorized
   change alters a recorded product decision, update its canonical statement
   and dependent requirements without leaving contradictory current guidance.
