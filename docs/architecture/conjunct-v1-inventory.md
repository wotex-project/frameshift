# Retained v1 source inventory

**Status:** specified; implementation and qualification are required. This
extends the [retained input boundary](conjunct-v1-inputs.md) at BuildSpec. It
enumerates original JSON nodes independently of a future conversion report.
Its complete coverage concerns the named syntax scope, not physical meaning,
the thirteen frame-check stages or successor execution support.

## Public boundary and coverage

`FrameshiftBuild.ConjunctAdapter.v1_inventory/5` and browser `v1Inventory`
accept the same five arguments as `v1_inputs/5`. First apply that complete
validation, limits, pin resolution, context comparison and refusal vocabulary.
Retain all original bytes and identities. Perform no source retrieval, I/O,
worker startup, evidence promotion, storage mutation or successor selection.
Two callers receive independent immutable results. Browser arrays are
snapshotted before hashing, as required by the input boundary.

Success is `{ok:true,value}` in JavaScript and `{:ok, value}` in Elixir. Its
value has exactly `format`, `inputs`, `inventory` and `nodes`. The format is
`frameshift.conjunct.v1-inventory/1`; `inputs` is the complete existing retained
input result, including every original byte string. All browser result objects
and nested arrays are frozen.

The inventory has exactly these fields, matching the producer's existing
`cj/mapping-report/0.1` source-inventory shape:

```text
artifact: {reference: inputs.context_identity,
           format: "frameshift.compilation", version: "1"}
coverage_scope: "frameshift/v1-closure-json-nodes/1"
complete: true
concepts: [{id, locator, requirements: ["CJ1-07", "CJ3-11"]}, ...]
```

The verified compilation context binds the assembly and mapping/layout pins;
the assembly binds every supplied profile. Coverage includes each document's
root, every object member and every array element, including empty containers.
It therefore retains source citations, unknown/conflicting states, bounds,
case-sensitive IDs, ordered connections, placements and repeated occurrences.
It supplies no claims about source truth, rights, physical equivalence or
permission. A future report must independently inventory its actual target;
it cannot obtain either inventory by copying its own mapping records.

Each concept ID and locator is the compound **text** `kind@identity#pointer`,
where kind and identity come from its verified original document. This is not
a URI or a media-type fragment convention. The pointer is the empty string
for the root, otherwise the JSON-string form of
[RFC 6901 sections 3–5](https://www.rfc-editor.org/rfc/rfc6901.html): replace
`~` with `~0` and `/` with `~1` in object keys; array indices are zero-based
decimal integers without leading zeroes. No Unicode normalization, native-ID
folding or array sorting occurs. The selected v1 codecs already require ASCII.
This source was inspected on 2026-10-06; the compound locator and coverage
scope are product decisions, rather than requirements supplied by the RFC.

Each node has exactly `id`, `document_kind`, `document_identity`, `pointer` and
`value`. The value describes that node without duplicating its descendants:
an object is `{type:"object",keys:[sorted exact keys]}`; an array is
`{type:"array",length:n}`; a string, integer or boolean is `{type,value}`;
null is `{type:"null"}`. Sorting uses ASCII. Preserve integers exactly under
the existing v1 bounds. Sort nodes and concepts by complete ID, and include
each exactly once. The original JSON tree must reconstruct exactly from these
descriptors. Empty, missing, false and zero retain their distinct meanings.

At most 10000 nodes may occur across the complete closure. An otherwise valid
closure exceeding that limit returns `too_many_concepts`, with no partial
inventory. This selected ceiling is below the producer schema's 20000-concept
maximum. All earlier v1 input ceilings remain binding. Removing an unused
document is not an automatic recovery: the caller must supply a new complete
valid closure, and preserve the refused original.

## Authored acceptance and remaining boundaries

Commit `packages/build-spec/test/fixtures/conjunct-v1-inventory.expected.json`
before mechanism or measurement. It retains full source bytes and complete
expected results for all prior input hands plus a valid oversized node closure.
Derive expected document IDs with the existing domains and standard SHA-256;
enumerate expectations from original JSON without invoking the candidate.
Retain complete expanded inputs, expected and actual results before comparison.

Both runtimes execute every hand and 100 schedules at each seed `20261006`,
`27182818` and `31415926`. Permute complete document lists, omit optional
bindings with their corresponding original context, or truncate/substitute
context bytes. Independently reconstruct every successful JSON tree from
its node descriptors and require equality with the original parsed document.
Verify all root/source/empty-container nodes, exact IDs, ordering, full input
custody, browser immutability, two independent callers and passive import.

Compile and execute two actual faults per runtime: omit the compilation-context
document from enumeration; omit empty containers. Their completed wrong
inventories must differ semantically from authored expectations. Compile/import
failures do not kill faults. Retain full source and actual BEAM, original and
actual fault outputs, and up to eight reduction trials. Reduce each full closure
to the authored no-binding closure while keeping its missing required nodes.

The null budget selects `complete` and `without-bindings`, each repeated five
times per runtime after full-result preflight. Preserve all ten elapsed samples
and full results, including failed attempts under ignored
`var/conjunct-v1-inventory/`. This qualifies source syntax custody only.
Installed producer resolution, a physical successor mapper, read/write/execute
negotiation, thirteen-stage replacement and physical acceptance remain open.
