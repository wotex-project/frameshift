# AI Image Generation Research

**Research dates:** 2026-09-22; provider/source recheck 2026-10-04

**Decision:** local-first, provider-neutral, still-image generation. Generated
masters are cached permanently unless the user removes them.

AI is an optional source and editing tool. The deterministic renderer remains
responsible for fitting a result to Photo, Paper, or Pixel capabilities. No AI
provider runs on a frame.

## Provider assessment

| Provider | Execution | Billing fit | Integration maturity | Decision |
| --- | --- | --- | --- | --- |
| Draw Things / MediaGenerationKit | Local Apple Silicon | Local compute | Public Swift package; exact SDK/model cohort still needs qualification | **Primary local candidate** |
| Ollama image generation | Local macOS | Local compute | Experimental; older endpoint regressions do not establish current runtime behavior | **Adapter and actual-generation qualification required** |
| Draw Things+ | Managed cloud | Subscription includes a monthly task allowance, then metered | Existing account can request an API key | **Preferred subscription-backed fallback** |
| Gemini Nano Banana | Google API | Metered API | Strong generation/editing REST API | **Optional paid fallback** |
| Consumer ChatGPT/Gemini UI | Hosted app | Subscription | No supported Frameshift automation entitlement | **Manual import only** |

### Draw Things

MediaGenerationKit is the clearest fit for a native Mac app. Its public API can
run a model locally, against a local gRPC server, or against Draw Things Cloud.
The announcement says an existing Draw Things+ account can request an API key;
the free key includes up to 20 generation tasks per month and Draw Things+ up to
200 before pay-as-you-go. The public package is LGPL-3.0 and currently asks
clients to pin a revision because it pins its own dependency by revision.

Sources: [MediaGenerationKit announcement](https://releases.drawthings.ai/p/introducing-mediagenerationkit-hybrid),
[public repository and license](https://github.com/drawthingsai/media-generation-kit),
and [Draw Things pricing](https://drawthings.ai/pricing/).

Before shipping, legal review must record dynamic-linking/relinking obligations,
notices, source-offer requirements, the pinned commit, and every selected
model's independent license. The Draw Things community application is GPL-3.0;
Frameshift must not copy or bundle its application internals merely because the
public SDK has a different license.

### Ollama

Ollama announced experimental macOS image generation in January 2026 with
Z-Image Turbo and FLUX.2 Klein. The 4B FLUX.2 Klein weights are Apache-2.0;
the 9B variant is non-commercial. Official model pages recommend 1024×1024 and
show materially larger storage for higher-precision variants.

The integration is not qualified as a product dependency. Issue #17893 reports
endpoint rejection on macOS with Ollama 0.32.14 despite image-capable model
listings. The issue is closed when rechecked on 2026-10-04; it does not establish
whether 0.35.0 has that defect. An adapter must qualify an actual bounded
generation for its exact runtime/model cohort rather than enable generation
from `/api/tags`. Failure exposes unavailable without an automatic downgrade.

Sources: [Ollama image announcement](https://ollama.com/blog/image-generation),
[FLUX.2 Klein model page](https://ollama.com/x/flux2-klein), and the current
[capability/endpoint regression report](https://github.com/ollama/ollama/issues/17893).

### Exact source and local inspection, 2026-10-04

GitHub API inspection through `gh` resolves the MediaGenerationKit wrapper main
to [8868a9685d9c299816f43ef53efd455ffca437f0](https://github.com/drawthingsai/media-generation-kit/commit/8868a9685d9c299816f43ef53efd455ffca437f0).
Its [Package.swift](https://github.com/drawthingsai/media-generation-kit/blob/8868a9685d9c299816f43ef53efd455ffca437f0/Package.swift)
declares Swift 5.9/macOS 13 and pins `draw-things-community` to
`d473a2f148b3e7dc9b90d0b7cfccc5cda999eb66`; the public target depends on
`_MediaGenerationKit`. This is source inspection, not a successful Frameshift
consumer build or license/model admission.

The [public API guide](https://github.com/drawthingsai/media-generation-kit)
describes async pipeline construction, configuration on the pipeline, explicit
local/remote/cloud backends and still-result file/image access. Catalog sync
overloads are offline/cache-only; network-capable operations are async.
Preflight must use offline inspection and must not call a model-download helper.
An exact consumer must check actual exports, build both supported Mac targets,
and qualify cancel, timeout, edit input and still output before activation.

The local read-only `/api/version` probe reports Ollama server 0.35.0; its CLI
reports 0.35.1. The tags probe finds no installed Z-Image Turbo or FLUX.2 Klein
candidate. No weights were downloaded and no image-generation call ran. The
runtime discrepancy and absent model prevent a live provider claim; private
model inventory is not copied into this research. A future model download needs
the specified source/license/size disclosure first.

The first implemented prerequisite is canonical result custody: exact
model/decoder revisions in recipes, verified edit-parent bytes, canonical master
packaging, corrupt-cache refusal and joined master-to-Zig/outbox fixtures.
Fixture pixels establish that boundary only. Next qualify a platform codec and
the exact SDK/model cohort, then expose provider selection, model admission and
cancellation through native Settings and the authenticated host command owner.

### Exact SDK consumer boundary, 2026-10-05

`gh` resolves the public wrapper to `8868a9685d9c299816f43ef53efd455ffca437f0`
and its implementation dependency to `d473a2f148b3e7dc9b90d0b7cfccc5cda999eb66`.
An isolated Swift 6.4/Xcode 27 (`27A266a`) consumer builds the exact public
exports for arm64 and cross-compiles x86_64 on macOS 27.0.1 arm64. Automatic
resolution is disabled; all 33 checked-out identities still match the preserved
resolved lock. The arm64 executable runs only its link marker. Constructor,
configuration, generation and PNG-result methods type-check without invoking
models, pipeline initialization or generation. The Intel result is compiler
proof, not native Intel execution. Neither binary qualifies macOS 13 runtime
compatibility; both Mach-O build commands report minimum/SDK fields 13.0 despite
the observed Xcode 27 build environment. The isolated dependency/build tree uses
about 4.2 GiB after the first arm64 build; this is an observation, not a universal
space requirement. No weights are downloaded.

Consumer inputs/results retain these SHA-256 identities:

| Input/result | SHA-256 |
| --- | --- |
| Package manifest | `08682eb862f4aeb919b030108c38c55793e3f9cf3df05be9fc6f310ebbf8efcb` |
| Resolved lock, 33 pins | `a9b4a6a176157b2caf82ae9824f3bafd1649e23a2b405d174317ce3d8ad1e82b` |
| Public-export consumer source | `23727d1170584790bde13e2ca9cd061e7e693f1a21015b7410883c43f2604434` |
| Linked arm64 consumer | `6b8932f84942ffec5655396bea4d80bd4aa1c306b29d7b9ae99caf20145d10b0` |
| Linked x86_64 consumer | `e9cb7985f6f772e67d93dcd638f8259c5d20cbe12bdfa11c6ad4bc07b2ed5e7d` |

Build commands use `swift build --configuration debug --jobs 2
--disable-automatic-resolution` and, for Intel compilation,
`--triple x86_64-apple-macosx13.0`. The disposable consumer depends on the public
`MediaGenerationKit` product at the wrapper revision above, with a macOS 13
package platform. Its checked public calls include synchronous
`MediaGenerationEnvironment.default.inspectModel(model, offline: true)`, async
`MediaGenerationPipeline.fromPretrained(model, backend: .local(directory: root))`,
configuration width/height/steps, `generate(prompt:negativePrompt:)` and
`result.write(to:type: .png)`. Only the explicit inspection fixture below invokes
SDK operations; the generation methods are compile-only evidence.

The preserved consumer lock selects these exact Git revisions. Version labels
are lock observations; none admits a package's rights or shipping scope.

| Dependency | Revision | Version label |
| --- | --- | --- |
| [ccv](https://github.com/liuliu/ccv) | `ae1de9962437c14ff7d84af9bac66305e7ce5927` | Revision pin |
| [dflat](https://github.com/liuliu/dflat) | `73925e51e4f44add842177a229f9990cb13711ff` | Revision pin |
| [draw-things-community](https://github.com/drawthingsai/draw-things-community) | `d473a2f148b3e7dc9b90d0b7cfccc5cda999eb66` | Revision pin |
| [flatbuffers](https://github.com/google/flatbuffers) | `c92e78a9f841a6110ec27180d68d1f7f2afda21d` | Revision pin |
| [grpc-swift](https://github.com/grpc/grpc-swift) | `65d0084f6d7db34b0dfcb1c956b8dd8da8ef9d23` | 1.27.6 |
| [media-generation-kit](https://github.com/drawthingsai/media-generation-kit) | `8868a9685d9c299816f43ef53efd455ffca437f0` | Revision pin |
| [s4nnc](https://github.com/liuliu/s4nnc) | `e3a83b351b84a7917fefd28366a3b9417fee3b2e` | Revision pin |
| [swift-algorithms](https://github.com/apple/swift-algorithms) | `87e50f483c54e6efd60e885f7f5aa946cee68023` | 1.2.1 |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | `6a52f3251125d74daf04fcbd5e6f08a75d074382` | 1.8.2 |
| [swift-asn1](https://github.com/apple/swift-asn1) | `3b6410f7dee09eb33cdd26260c5fd47fda19b0e2` | 1.7.3 |
| [swift-async-algorithms](https://github.com/apple/swift-async-algorithms) | `13713a4ffdee8abd929f92568ee9462a46ae26e0` | 1.1.7 |
| [swift-atomics](https://github.com/apple/swift-atomics) | `0442cb5a3f98ab802acb777929fdb446bda11a34` | 1.3.1 |
| [swift-certificates](https://github.com/apple/swift-certificates) | `ff86b924ead66f853b8baf91f3c41926a8f36177` | 1.21.0 |
| [swift-collections](https://github.com/apple/swift-collections) | `98ef3c98609a1e31b7e157b5b619579001a789d6` | 1.7.1 |
| [swift-crypto](https://github.com/apple/swift-crypto) | `95ba0316a9b733e92bb6b071255ff46263bbe7dc` | 3.15.1 |
| [swift-fickling](https://github.com/liuliu/swift-fickling) | `5c982bf479c4cdf8c7f72002cd79ec88b553ab34` | Revision pin |
| [swift-fpzip-support](https://github.com/weiyanlin117/swift-fpzip-support) | `0ec6d4668c9c83bc3da0f8b2d6dfc46da0b98609` | Revision pin |
| [swift-http-structured-headers](https://github.com/apple/swift-http-structured-headers) | `933538faa42c432d385f02e07df0ace7c5ecfc47` | 1.7.0 |
| [swift-http-types](https://github.com/apple/swift-http-types) | `bff4b6903cdc99dda49649dd52f46c11cfd3ed50` | 1.8.0 |
| [swift-log](https://github.com/apple/swift-log) | `9c6fb14227f55d8f711ce3847dc2f419fb0ecacb` | 1.15.1 |
| [swift-log-datadog](https://github.com/jagreenwood/swift-log-datadog) | `e47aa092908764bdd625bb18d72e4db5bf9d7c4e` | 0.3.0 |
| [swift-nio](https://github.com/apple/swift-nio) | `21de5f08c1a166a6dd293d0e587ad977bf8dac5d` | 2.103.0 |
| [swift-nio-extras](https://github.com/apple/swift-nio-extras) | `41449336c8ecfadac6b4b5be75f9c3c306e61ced` | 1.35.1 |
| [swift-nio-http2](https://github.com/apple/swift-nio-http2) | `0f3e54e29c944c2e835ad52159da7d9e1c94ac69` | 1.46.0 |
| [swift-nio-ssl](https://github.com/apple/swift-nio-ssl) | `322f3c2a4a21df31c84ca416bf65ee5e9059e440` | 2.37.5 |
| [swift-nio-transport-services](https://github.com/apple/swift-nio-transport-services) | `67787bb645a5e67d2edcdfbe48a216cc549222d5` | 1.28.0 |
| [swift-numerics](https://github.com/apple/swift-numerics) | `0c0290ff6b24942dadb83a929ffaaa1481df04a2` | 1.1.1 |
| [swift-package-support-sentencepiece](https://github.com/weiyanlin117/swift-package-support-sentencepiece) | `a39a5be0b3e3ad9bcb19b085af7dd891c00aa3d2` | Revision pin |
| [swift-png](https://github.com/kelvin13/swift-png) | `075dfb248ae327822635370e9d4f94a5d3fe93b2` | Revision pin |
| [swift-protobuf](https://github.com/apple/swift-protobuf) | `d57a5aecf24a25b32ec4a74be2f5d0a995a47c4b` | Revision pin |
| [swift-sentencepiece](https://github.com/liuliu/swift-sentencepiece) | `8d17bf2e017c97563e8805545d676be9739b6c0e` | Revision pin |
| [swift-service-lifecycle](https://github.com/swift-server/swift-service-lifecycle) | `7f9326b0326ff86e3646295ea6e891f68c471c5e` | 2.12.0 |
| [swift-system](https://github.com/apple/swift-system) | `fbd61a676d79cbde05cd4fda3cc46e94d6b8f0eb` | Revision pin |

The exact source defines boundaries that the consumer must preserve:

- [Pipeline construction](https://github.com/drawthingsai/draw-things-community/blob/d473a2f148b3e7dc9b90d0b7cfccc5cda999eb66/Libraries/MediaGenerationKit/Sources/MediaGenerationPipeline.swift#L741-L778)
  and its local backend pass `offline: false` to model/configuration resolution.
  Resolution can fall through to remote catalogs. `.local` identifies the
  inference backend; it is not a complete network refusal policy.
- [Environment ensure](https://github.com/drawthingsai/draw-things-community/blob/d473a2f148b3e7dc9b90d0b7cfccc5cda999eb66/Libraries/MediaGenerationKit/Sources/MediaGenerationEnvironment.swift#L71-L109)
  uses `offline` for catalog resolution, then calls the weight-readiness helper
  without that flag. Therefore `ensure(offline: true)` is not an offline
  preflight and cannot authorize an undisclosed download.
- [Weight verification](https://github.com/drawthingsai/draw-things-community/blob/d473a2f148b3e7dc9b90d0b7cfccc5cda999eb66/Libraries/MediaGenerationKit/Sources/MediaGenerationEnvironment%2BEnsure.swift#L146-L194)
  skips full hashing above 300 MiB and can trust a cached expected digest.
  SDK `isDownloaded` and this cache do not prove exact model bytes. Frameshift
  needs independently verified identities for every selected weight/dependency.
- [Resource lookup](https://github.com/drawthingsai/draw-things-community/blob/d473a2f148b3e7dc9b90d0b7cfccc5cda999eb66/Libraries/MediaGenerationKit/Sources/MediaGenerationResourceLoader.swift#L4-L19)
  checks the main bundle, then a compile-time source path. The SwiftPM target
  does not declare these JSON resources. Qualification must copy/check the
  exact required resources and run after removing access to the source checkout;
  a development source-path fallback cannot qualify an installed worker.
- [Local execution](https://github.com/drawthingsai/draw-things-community/blob/d473a2f148b3e7dc9b90d0b7cfccc5cda999eb66/Libraries/MediaGenerationKit/Sources/MediaGenerationExecutionUtilities.swift#L157-L239)
  queues native work and connects cancellation through callback feedback and a
  generator cancellation closure. A requested Swift cancellation is not a
  measured deadline or proof of worker exit; qualify actual completion/exit.
  Environment/model roots and weight-cache settings have process-wide effects.

The [ModelZoo path implementation](https://github.com/drawthingsai/draw-things-community/blob/d473a2f148b3e7dc9b90d0b7cfccc5cda999eb66/Libraries/ModelZoo/Sources/ModelZoo.swift#L2400-L2426)
also consults and attempts to create the user's Documents/Models directory even
when an external root is set. Therefore `DRAWTHINGS_MODELS_DIR` does not isolate
all model IO. Qualification must deny roots outside owned custody rather than
inspect or modify an existing user's models.

An arm64 offline-only consumer runs inside a private copied `.app` fixture with
an empty model root. It sets `DRAWTHINGS_MODELS_DIR`, clears the cloud API-key
environment entry, calls only synchronous `inspectModel(..., offline: true)` and
`downloadableModels(..., offline: true)`, and uses finite outputs. A URLProtocol
interceptor refuses every request; a canary verifies interception before counting
SDK calls. A disposable `sandbox-exec` policy denies network and Documents/Models
IO, then additionally denies checkout reads. A raw loopback-connect canary returns
`EPERM` under both policies and a different result without them. A source-read
canary also refuses; these qualify the disposable policy on macOS 27.0.1 only,
not a shipping entitlement or supported installed sandbox mechanism.

| Fixture | Catalog entries | Selected f16 FLUX.2 Klein 4B / Z Image Turbo | SDK URLSession attempts |
| --- | --- | --- | --- |
| Checkout readable, no bundled JSON | 313 | Both resolve; neither downloaded | 0 |
| Checkout inaccessible, no bundled JSON | 114 | Both refuse resolution | 0 |
| Checkout inaccessible, exact bundled JSON | 313 | Both resolve; neither downloaded | 0 |

The model root remains empty and stderr remains empty in all three fixtures.
The SDK silently retains a reduced builtin catalog when resources are absent;
Frameshift must verify required resources explicitly before presenting this as
an admitted cohort. `models.json` is 125,897 bytes with SHA-256
`b50e05acf0410422bb1513b61dc81542e94bea5e5d7c3ed9a94ca47ca89c0134`;
`configs.json` is 47,709 bytes with SHA-256
`37180f6a7b21bf718e30e1f72efcc1241691daa5d3dc4ef32fc5d9fe7ec50f86`.
Both come from the pinned implementation revision. Only model catalog/resource
lookup is exercised; copying configs does not qualify pipeline configuration.
The instrumented consumer source SHA-256 is
`65d29b92dcecd2fd3cbc7b894a115f6f5cb98655e2c2fcc10b028fbb1ba72b75`;
its arm64 executable SHA-256 is
`91e507746c965a1fc05f73b29cce7edf8fd922a20655d982ccb6afa8ea99c826`.

Next implement selected-weight admission, qualify the
shipping worker's network/root refusal and actual native ownership/output, then
measure cancellation/deadline completion on an admitted model cohort. Public
pipeline initialization still has the network-capable boundary described above.
Preserve unavailable/refusal until these checks pass; assuming every known
filename stays local is insufficient. Native Intel/older macOS execution, model
source/license/size disclosure and distribution license review remain separate
admission gates. Keep producer internals out of Frameshift.

### Protected SDK resource admission

The [resource check](../architecture/content-pipeline.md#pinned-sdk-resource-custody-check)
now admits only the two fixed JSON names in a current-user 0700 directory with
unaliased regular 0600 descriptors. It checks complete bounded bytes, the
recorded sizes/hashes and full file/directory custody without decoding JSON or
invoking SDK/model IO. Extra/partial/unsafe or conflicting material refuses
without fetching, copying or repairing it. Its finite revision/fact result has
publication authority none and includes no private root.

Five groups pass against the actual pinned resources with zero exclusions,
including unchanged CLI replay and missing/changed/oversized/extra/aliased/unsafe/
linked/special-file and mutation-during-read refusals. The two actual-resource
groups are explicitly excluded when their local fixture input is unavailable;
synthetic refusal checks do not substitute for that positive evidence. The real
copied-app offline consumer passes this admission before and after its child;
full resource inode/mode/owner/size/modification/change identities remain
unchanged. The catalog remains 313 entries, both selected models resolve with
downloaded false, URLSession attempts remain zero and the model root stays empty.
This closes the implemented resource-byte prerequisite for this private fixture;
weights, shipping root/network isolation, inference, native cancellation and
rights remain separate activation gates.

### Provider callback logging and failure boundary

**Observation:** 2026-10-05, pinned Elixir 1.20.4/OTP 29.1 source and real core
fixtures. `gh` identifies the
[task supervisor source](https://github.com/elixir-lang/elixir/blob/v1.20.4/lib/elixir/lib/task/supervised.ex#L103-L138)
as blob `c34a05daba8c1bc7d0ae757aae2138dd5a5961e7`. Its fault path logs a raw
exception, thrown term or exit reason before reporting task exit to the caller.
Returning `provider_crashed` afterward cannot remove that earlier event.
The [OTP Logger source](https://github.com/erlang/otp/blob/OTP-29.1/lib/kernel/src/logger.erl#L1877-L1903),
blob `cf69ea0349479cb1ba69b927d06f30efa3c390c2`, merges process metadata into
each record. The existing primary private-process filter can therefore suppress
the owned callback task's records before every handler. The selected trusted
adapter must preserve that marker; independently owned children/native output
are outside this process's protection.

Regression fixtures first reproduced raw provider-context/fault logging,
private arbitrary error replies and a malformed-reply caller crash. The corrected
coordinator admits and marks the task before callbacks, exposes only finite
error classes, and catches rejected task admission without changing Library
objects. Actual raw-handler fixtures cover preflight/generation raise, throw and
exit with private context and verified edit input, while ordinary host logs
remain visible. Filter conflict preserves policy and cache reads; real task
capacity refusal/recovery and deadline worker exit pass. These are core software
observations. They do not admit a live SDK/model, cancel native/cloud effects or
establish Keychain/installed logging qualification. The
[owning callback contract](../architecture/content-pipeline.md#generation-callback-privacy-and-refusal)
keeps those acceptance tiers explicit.

### Nano Banana

Google's current native image family includes Gemini 3.1 Flash Lite Image,
Gemini 3.1 Flash Image (Nano Banana 2), and Gemini 3 Pro Image. The API supports
text-to-image, image editing, multiple references, and explicit aspect ratio and
resolution. It is technically a strong fallback, particularly for steering an
existing result, but API use is metered. A consumer Gemini subscription is not
an API contract and Frameshift must not automate its web UI.

The provider stores the exact model identifier because model aliases and
deprecation dates change. Generated images contain SynthID according to the
official guide. Source: [Gemini image generation documentation](https://ai.google.dev/gemini-api/docs/image-generation).

The same rule applies to OpenAI: ChatGPT subscriptions and API billing are
separate. Source: [OpenAI billing guidance](https://help.openai.com/en/articles/9039756).

## Provider contract

Every provider implements the same conceptual operations:

```text
preflight(configuration) -> availability + capabilities + disclosures
generate(recipe, destination) -> generation result
edit(parent, recipe, destination) -> generation result
cancel(job_id) -> acknowledged | too_late
```

`preflight` reports exact provider/model revision, local/cloud destination,
model availability, required download bytes, license identifier, supported
input count, output sizes, seed support, and cost class. It must not download a
model or send user content.

Before the first model download, Frameshift shows the model name, source,
license, storage requirement, and destination. Before every newly selected
cloud provider, it shows what source images and prompt text will leave the Mac
and whether the request consumes an allowance or metered balance.

No adapter may silently fail over from local to cloud. The user chooses a
fallback policy in Settings. The default is “ask before cloud use.”

## Generation recipe and cache key

Generation is immutable. The cache key is SHA-256 over a canonical recipe that
contains at least:

- source master digests in stable order;
- target display profile identifier and revision;
- hidden Frameshift base instruction revision;
- user instruction and negative instruction;
- provider and exact model identifier/revision;
- generation mode, seed, sampler, steps, guidance, dimensions, and safety
  settings when the provider exposes them;
- application and provider-adapter versions.

The cache stores the provider's original output before Frameshift resizing or
palette conversion. Display artifacts have separate renderer cache keys.
“Regenerate” creates a sibling recipe with a new seed or provider job identity;
it never overwrites the parent. “Steer” creates a child whose parent digest and
new instruction are recorded.

Provider responses that cannot reproduce a seed still cache correctly; the
recipe marks reproducibility as `best_effort` and stores the service request ID.

## Display base instructions

Base instructions are versioned product data, not hidden magic strings in UI
code. They describe medium constraints without overriding the user's subject:

- **Photo:** preserve natural detail and composition; avoid tiny text and edge
  content hidden by the mat; produce a clean still artwork master.
- **Paper:** prefer broad color regions, deliberate contrast, and detail that
  survives the advertised pigment palette and slow global refresh.
- **Pixel:** simplify into strong silhouette, readable clusters, limited local
  detail, and composition that survives the exact low-resolution grid.

The user sees a concise summary and can disable or replace the base instruction
in advanced settings. The full effective prompt is stored with the recipe and
available in provenance details.

AI should generate a useful master, not final HUB75 or e-paper bytes. The Zig
renderer performs the final deterministic downsample, palette map, and dither.

## Auto-labeling and search

Labeling is local by default:

1. retain user labels, filename terms, and safe embedded metadata;
2. run Apple's Vision `ClassifyImageRequest` and store identifier, confidence,
   framework revision, and locale-independent identifier;
3. generate a Vision feature print for similarity search;
4. optionally ask a configured local vision-language model for captions;
5. use a cloud labeler only through a separate explicit opt-in.

Vision produces classification observations and supports image feature prints
for similarity. Sources: [ClassifyImageRequest](https://developer.apple.com/documentation/vision/classifyimagerequest)
and [Vision image comparison APIs](https://developer.apple.com/documentation/vision/vngenerateimagefeatureprintrequest).

Machine labels never replace user labels. Low-confidence labels remain hidden
from the compact popover but can aid search. Search results must state when a
match came from semantic similarity rather than literal text.

## Failure behavior

- A generation timeout leaves no library item unless a valid result was fully
  written and hashed.
- Provider refusal and safety errors are shown as provider results, not retried
  against another provider automatically.
- Authentication failure disables only that provider.
- Quota exhaustion offers configured alternatives without changing providers
  on the user's behalf.
- Removing a generation moves its unreferenced host files to a recoverable
  trash area. Pinned or displayed derivatives remain until explicitly unpinned
  and no frame references them.

## Acceptance tests

1. Repeating an identical deterministic recipe returns the cached master
   without a provider call.
2. Regenerate produces a separate variant and preserves the original.
3. A local-only policy produces zero outbound provider traffic.
4. A cloud transition always requires the configured confirmation.
5. Secrets remain in Keychain and never enter recipes, logs, or frame payloads.
6. The library can export an image and its full provenance without access to
   the original provider.
