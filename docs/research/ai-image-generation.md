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

`gh` still resolves the public wrapper to `8868a9685d9c299816f43ef53efd455ffca437f0`
and its implementation dependency to `d473a2f148b3e7dc9b90d0b7cfccc5cda999eb66`.
An isolated Swift 6.4/macOS SDK 27 consumer resolves 33 dependency identities,
then fails compilation with filesystem `ENOSPC` while compiling plugins/Clang
modules. It supplies no successful API build, Intel build or runtime evidence.
No model/helper is invoked and no weights are downloaded. Disposable build
material and the newly fetched CCV cache were removed; the probe source, lock
and finite failure log remain local research inputs. Check available space
before repeating the full dependency/native build; there is no measured final
build-space requirement yet.

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

The next consumer experiment must build the exact public exports on the claimed
Mac architectures, freeze its resolved inputs, test offline catalog lookup and
installed resource custody with an empty private model root, and observe attempted
network operations. Before generation activation, qualify an explicit offline
initialization/refusal boundary, full selected-model byte identity, private
native ownership/output and cancellation/deadline completion. A public upstream
offline initializer or qualified platform network denial are candidate ways to
meet that boundary; assuming every known filename stays local is insufficient.
Keep producer internals out of Frameshift and preserve unavailable/refusal until
these checks pass. Model source/license/size disclosure and distribution license
review remain separate admission gates.

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
