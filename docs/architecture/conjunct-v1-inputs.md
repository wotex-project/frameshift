# Exact retained v1 migration inputs

**Status:** specified; implementation and qualification are required. This
contract extends CI-03's [five retained formats](conjunct-integration.md#existing-format-and-migration)
at the existing `packages/build-spec` owner. It prepares complete original
inputs for S3. It does not create Conjunct successors, replace a planning stage,
change persisted identities or admit a physical configuration.

## Public boundary

`FrameshiftBuild.ConjunctAdapter.v1_inputs/5` accepts canonical assembly bytes,
lists of profile, signal-mapping and artifact-layout bytes, and the original
canonical compilation-context bytes, in that order. The browser equivalent is
asynchronous `v1Inputs` in `js/conjunct-adapter.mjs`. Elixir returns
`{:ok, value}` or `{:error, code}`; JavaScript returns `{ok:true,value}` or
`{ok:false,error:code}`. Refusals contain a bounded code without echoed inputs.

The importer first checks binary/string inputs, dense document lists of at
most 64 entries each, a 262144-byte ceiling for every document and a 4194304-byte
ceiling for the entire supplied closure, including the context. Check these
limits before cryptography or decoding. Existing depth-16, ASCII, field order,
collection, integer, source and reference requirements remain in force.
JavaScript snapshots all three caller arrays before its first await; later
caller mutation cannot change the accepted closure.

Use the existing v1 codec and standard-cryptography identity boundaries for
every supplied document. Resolve exact profiles, mappings and layouts through
`FrameshiftBuild.resolve_context/4` or browser `resolveContext`; never trust
caller-supplied IDs, parse an unvalidated profile or look up another revision.
Those existing resolvers permit missing profile bodies. This importer instead
returns `missing_profile` if any assembly pin lacks its exact body. Check that
disposition before comparing the supplied context. Existing malformed,
noncanonical, duplicate, unreferenced and stale-reference codes pass through.

Reconstruct canonical compilation-context bytes from the verified assembly and
resolved mapping/layout closure. Require byte-for-byte equality with the
supplied context, including its final LF. A mismatch returns `context_mismatch`;
do not normalize an altered context or accept its apparent digest. Hash the
verified context in the existing `frameshift.compilation.v1` LF domain.

Success has exactly these fields:

```text
format: "frameshift.conjunct.v1-inputs/1"
assembly_identity: the verified frameshift.build.v1 identity
context_identity: the verified frameshift.compilation.v1 identity
documents: [{kind, identity, bytes}, ...]
```

Include every supplied original document once, without reconstructing its
bytes. Kinds are `assembly`, `artifact-layout`, `compilation-context`,
`component-profile` and `signal-mapping`; order records by kind, then identity,
using ASCII lexical order. Identity domains remain exactly CI-03's table.
The JavaScript success value, its document array and each record are frozen.
Two callers retain independent immutable records. No library loading or import
call starts a worker, performs I/O, changes global settings, promotes evidence
or applies a catalog/device mutation. Only the explicit crypto facility used
by the existing identity boundary is required.

Full retained bytes preserve missing and conflicting facts, all source
citations, original integer bounds, case-sensitive IDs, repeated occurrences,
placements and exact mapping/layout scope. Successful custody is not a
state-preserving successor mapping: citation-only conflicts still cannot become
invented contradictory Conjunct claims. Read/write support remains v1; successor
read/write/execute support and all thirteen frame obligations stay open.

## Authored acceptance

Commit `packages/build-spec/test/fixtures/conjunct-v1-inputs.expected.json`
before implementing or measuring this boundary. Its shared source dictionary
contains complete original bytes; each case specifies complete argument
references and a full expected result. References expand only to that retained
dictionary, never measured producer output. Resource cases use the declared
repeat operation; retain their complete expanded arguments before invocation.

Execute every authored success/refusal on both runtimes. Positive cases cover
all five domains, reordered inputs, absent optional mapping/layout lists and
preserved missing/conflicting fact states. Negative cases cover missing pinned
bodies, context substitution/truncation, invalid types, collection/budget
ceilings, noncanonical bytes, duplicate bodies, stale mapping scope and an
unreferenced profile. Recompute expected IDs independently with the specified
domains and standard SHA-256. Preserve the exact source dictionary and full
original/expected/actual records before comparisons.

For each seed `20261006`, `27182818` and `31415926`, run 300 schedules that
permute the retained closure, optionally omit both binding kinds with the
independently authored corresponding context, or substitute/truncate context
bytes. Derive expectations from the original v1 bytes and domain rules before
calling an adapter. Also mutate caller arrays during actual asynchronous
hashing and verify the original complete closure wins; inspect the full frozen
output and untouched caller inputs.

Execute two actual implementation faults per runtime: omit the context-byte
comparison; accept missing profile bodies. Compile and retain the faulty Elixir
BEAM and source; import and retain the faulty JavaScript source in a fresh
process. A compile, import or harness failure cannot count as fault detection.
Retain up to eight reduction trials and the full reduced witnesses: a complete
closure with its context's final LF removed, and the authored assembly with
empty profile/mapping/layout lists and its independently constructed no-binding
context. Only a complete semantic mismatch kills a fault.

The null budget selects `complete` and `without-bindings`, each repeated five
times per runtime after an untimed full-result preflight. Retain all ten elapsed
samples and complete results. No controlled latency, memory, installed consumer,
successor migration or physical claim follows. Preserve failed attempts under
ignored `var/conjunct-v1-inputs/`; required checks must fail rather than skip.
