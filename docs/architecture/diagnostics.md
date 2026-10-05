# Host Diagnostics Contract

**Status:** normative software design; targets require platform qualification

This contract covers the local host and the separate companion-server extension
below. The local audit/SQLite writer and native OS log access remain authoritative
for frame operations. Server Ash domains and Refpath do not share those records.

## Companion server metrics and diagnostic access

[PC-08](producer-contracts.md) assigns the library delivery and joined outage/
restore tests. Pure Conjunct calls are measured by the invoking host or harness;
they do not start collectors or perform telemetry I/O. Producer implementation
and operational qualification remain separate from the metric definitions here.

The [build-platform contract](build-platform.md) requires first-class telemetry
with each implemented slice. Ash domains own domain transition/audit meaning;
Conjunct owns compiler/procedure assessment meaning, Refpath owns runtime
task/attempt/effect meaning, and Rivure owns any later financial facts. Emit measurements after the
corresponding durable fact, with explicit definitions preventing double counting
at both boundaries. Operational logs and metrics never establish an external
purchase, refund or physical display outcome.

Each versioned metric definition names its owner, trigger, count/gauge/histogram
type, unit, bounded dimensions, reset/coverage semantics, aggregation, retention,
sampling and resource budget. Use explicit duration units, currency for money,
and no aggregation across currencies without an attributed conversion. Record
queue age and absence of data separately from zero activity. Define alert
thresholds and service targets from measured baselines and product requirements
before production activation; a dashboard alone is not an operating contract.

| Family | Required measurements | Owner / first milestone |
| --- | --- | --- |
| Composition | Compile/decision count by bounded outcome/reason, duration, stale-fact refusal and browser/server disagreement | Conjunct producer + Frameshift profile / C |
| Verification | Queue depth/age, duration, bounds class, typed outcome, witness replay, cache hit/invalidation and resource refusal | Producer verification + product admission / C |
| Geometry and procedures | Import/conversion refusal, unsupported capability, stale feature/step binding and rights/revocation refusal, duration and resource ceilings | Producer adapters + product evidence / C–D |
| Independent instructions | Successful/failed save/export/print preparation, viewer fallback, latency and contract errors without recording private artwork or selected parts as labels | Web boundary / D |
| Research | Source freshness, candidate/admission/quarantine counts, eligible unattended completion denominator, manual interventions and pending exception age | Catalog + Refpath / E |
| Inference | Requests, input/output tokens, estimated/reserved/actual cost, retries, failures, abstentions, latency, model/task qualification results | Refpath provider boundary / E |
| Diagnostics | Investigation count/duration, tokens/cost, budget refusal, observation redaction failures, dropped telemetry and process/queue overhead | Beamlens host boundary / B/E |
| Purchasing | Confirmed/refused/unknown outcomes, unknown age, reconciliation, partial-order count, expired/revoked mandates and completion duration | Purchasing + Refpath / F |
| Money and care | Read projections of authoritative authorized/captured/refunded amounts, fee reversals and disputes; late parcels and case age | Rivure integration + product care / optional F |

The F families apply only to a resumed, enabled service profile. They neither
require a Frameshift ledger nor block the independent composition/instruction
profile. Financial reconciliation is not inferred from telemetry totals.

Quality evaluation reports include false acceptance, coverage and calibration
with task/dataset version and uncertainty; production self-reported model
confidence is not a correctness measurement. Fixed allowlists bound model,
provider, operation, market and error labels. Customer/seller/order/frame IDs,
source URLs, prompts, full model digests, component IDs and arbitrary errors
belong only in authorized redacted trace/audit detail, never metric dimensions.

Export structured logs, metrics and traces through existing operational tools.
Use immutable domain audit for accepted terms, authority changes and confirmed
effects, with access and retention policies. Correlation links connect domain
commands to Refpath tasks/attempts/effects without creating a second effect
journal. Preserve native Console.app and `log` plus the local diagnostic CLI;
no custom log-reader UI is required for either product lane.

CJ.07 selects GreptimeDB as the shared-host metric/time-series destination with
Prometheus/OpenTelemetry-compatible ingestion. Retain the current Prometheus
exporter and qualify the exact receiver version, collector, authentication,
label mapping, retention/disk budget, redaction and outage behavior before
claiming this integration works. Do not introduce a separate ELK stack or use
telemetry storage as a receipt/effect journal. Structured log/trace collection
and GreptimeDB deployment are planned; the current bounded exporter is the
implemented boundary. GreptimeDB log/trace features are optional until qualified;
bounded journald/structured files and an approved collector are a separate path.

Beamlens is an explicit read-only server integration with one supervision owner,
bounded observations and operator authorization. Qualify generic skills and
Frameshift observations for composition, verifier/research queues and optional-F
purchasing reconciliation. Its BAML provider configuration, resource ceilings
and inference spend are independently enforced and included in central usage
accounting. No diagnostic skill can mutate domain state or call purchasing tools.
Redact secrets, customer content and sensitive source material before inference.

Acceptance includes actor isolation, malicious/log-injected observations,
secret redaction, metric cardinality, sampling/coverage, provider timeout,
budget exhaustion, process failure and measured idle/load overhead. Normal
telemetry, alerts, logs and application actions must survive diagnostic failure.
Local Ollama incident reasoning requires its own evaluation; passing a simple
intent-routing evaluation does not qualify the diagnostic model.

### Server catalog v3 and collection limits

The server uses `Telemetry.Metrics` definitions with an explicit Prometheus
reporter backed by `prometheus.erl` fixed histogram buckets. It must aggregate
observations on arrival; retaining every sample until a scrape is prohibited.
The server's registry is separate from upstream runtime registries. Register
only this catalog, normalize dimensions before storage and reject non-numeric,
negative or over-limit measurements. No raw telemetry metadata enters storage.

| Name suffix (`frameshift_platform_`) | Event / owner | Type and unit | Dimensions / aggregation |
| --- | --- | --- | --- |
| `catalog_source_total` | Source action after transaction / Catalog | Counter, actions | `outcome=ok,error,other`; sum per outcome; not a durable audit count |
| `catalog_profile_total` | Profile action after transaction / Catalog | Counter, actions | `outcome=ok,error,other`; sum per outcome; not a durable audit count |
| `http_responses_total`, `http_duration_seconds` | Endpoint response preparation / Web | Counter, responses; histogram, seconds | `route=sources,profiles,health,metrics,page,other`, `outcome=success,client_error,server_error,other`; sum counters/buckets across instances |
| `http_transport_exceptions_total` | Bandit exception for this endpoint / Web | Counter, exceptions | Same fixed route enum; independent of prepared responses |
| `database_duration_seconds`, `database_queue_seconds` | Host Repo query completion / Repo | Histogram, seconds | No query text, table, actor or error labels; includes both owned schemas |
| `vm_memory_bytes`, `vm_processes`, `vm_run_queue` | Ten-second sample / runtime | Gauge, bytes or processes | No labels; report per instance; sums only for fleet totals |
| `collector_started_seconds`, `collector_sampled_seconds` | Reporter initialization and ten-second sample / reporter | Gauge, Unix seconds | No labels; compare per instance, never sum |
| `telemetry_rejected_total` | Invalid measurement / reporter | Counter, observations | No labels; invalid events are omitted from their target metric |

Duration buckets are 0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1 and 5 seconds plus
infinity. Accept elapsed native integers up to one day and sample counts/bytes
up to JavaScript's safe integer maximum. Responses are counted once before
transmission; duration excludes subsequent socket/body transmission. Bandit
exceptions are counted separately and must not be added to that denominator:
an exception can follow response preparation. Scraping and static assets are
included in HTTP traffic. Partial requests that emit no completion are not
invented as successful samples.

Counters/histograms reset when this reporter restarts. `collector_started_seconds`
marks the beginning of the current observation interval. A sampling delay does
not establish zero activity. Expose no scrape while the reporter is unavailable;
alert on missing scrapes and a sample age exceeding 30 seconds for two minutes.
No completeness is claimed across restarts or known rejected observations. All
accepted events are measured without sampling; gauges sample every ten seconds.
Fixed series and buckets bound storage independently of time and traffic. The
acceptance workload sends at least 100,000 observations without scraping, checks
stable storage size and concurrent counts, and checks reporter restart/outage.
The qualified remote receiver owns retention (initial deployment contract:
30 days, subject to an explicit disk budget); the app keeps only current
aggregates. Existing Prometheus scrape/alert fixtures remain evidence for that
path, not evidence of GreptimeDB ingestion. Latency and
availability objectives still require an admitted workload baseline.

## Signals and privacy

Audit, logs, and metrics answer different questions. Audit records a durable
state change or terminal command disposition in the same transaction as that
change. Logs explain a causal sequence and may be sampled or dropped. Metrics
aggregate bounded measurements and never establish whether one frame actually
displayed an image. The authoritative delivery state is the source for that
claim.

Every admitted command gets a correlation ID. Each delivery attempt gets its
own attempt ID linked to the command. Persist IDs in receipts and relevant
audit/state rows; carry them in logs, never as metric labels. Record UTC event
time and monotonic process duration separately. End-to-end delivery duration
across sleep or restart uses persisted timestamps and records clock uncertainty.

For direct push and read-only reconciliation, the core records a random
128-bit attempt ID and hashed command correlation in an audit fact before
network I/O. It records the terminal attempt outcome afterward; a crash can
leave only the started fact and a pending intent. A confirmed display fact
carries the exact attempt ID that observed it. Native logs carry the same
allowlisted attempt ID, while the attempt-count metric uses only mode and
outcome dimensions. A transport timeout or lost response after the intent is
durable has an `unknown` attempt outcome: the request may have reached the
frame, so the host retains the pending intent and reconciles by read-only
observation. `failed` is reserved for a definite local or protocol refusal.
An unknown attempt never advances current display state and is counted
separately in audit, native logs, and the bounded attempt metric. A sleeping
pull contact spans separate manifest, asset, and
acknowledgement requests. Frame Protocol v0.1 has no contact ID echoed in the
acknowledgement, so revision and frame identity alone cannot attribute a
confirmation to one contact attempt. A versioned protocol change must carry
the host-issued random attempt ID from manifest to acknowledgement, reject an
unknown or mismatched ID, and keep an interrupted contact pending. Until that
round trip is implemented, pull attempts remain an explicit correlation gap.

Default diagnostic fields are enum outcome, stable operation name, safe error
code, revision, duration, byte count, and random correlation ID. No tokens,
private keys, artwork bytes, prompt text, raw source paths, full URLs, or raw
Thing Descriptions. Digest and device identifiers require an explicit
redaction policy for export. Diagnostic failures cannot change domain outcomes.

## Metric catalog

The catalog is version 2 when `unknown` is added to the direct-attempt outcome
dimension; historical version 1 rollups retain their stored labels. Each
metric has a documented owner, event, type, unit, allowed dimensions,
aggregation, retention, and coverage rule. The catalog definition is versioned.
Allowed dimensions are bounded enums such as `operation`, `outcome`, `delivery_mode`,
and `error_class`; unknown values map to `other`. Frame IDs, command IDs,
artwork digests, provider inputs, and network addresses are forbidden labels.

| Metric family | Measurement | Source of truth |
| --- | --- | --- |
| Command | completed/replayed/unknown count and completion duration | IPC admission and durable receipt |
| Qualification | candidate, admission, activation, cohort, work, and result decision counts by succeeded/refused outcome | Single SQLite writer after each qualification command |
| Render | duration, cache hit, timeout, worker restart | Rendering job lifecycle |
| Delivery | intent count, pending age, confirmation duration, retry/reconcile and unknown count | Durable Delivery state and frame confirmation |
| Outbox listener | started, stopped, and unavailable counts with bounded state labels | Supervised listener lifecycle; no frame identity in metric dimensions |
| Storage | transaction duration/busy result, object bytes, WAL bytes | SQLite owner and filesystem sampling |
| Runtime | core restart, process memory, queue depth, diagnostic drops | Supervisor and bounded samplers |

The implemented pull outbox exchange metrics count completed HTTP requests and
measure their server-side duration. They classify only `manifest`, `asset`,
`playlist`, `ack`, or `invalid` routes and bounded response outcomes. Partial
requests do
not emit a completed-exchange sample. These measurements do not imply that a
frame displayed an image; only authoritative acknowledgement advances display
state. Frame IDs, request paths, and asset digests never become metric labels.

The primary service indicator is the fraction of eligible updates confirmed
displayed within a target window. Report awake push and sleeping pull
separately; sleeping contact cadence is part of the denominator definition.
Also report an explicit unknown outcome rate and measurement coverage. Choose
numeric objectives only after measurements on the exact supported hardware
and workload. A queued or transport-accepted update is never counted as
displayed.

Named `:telemetry` events are the portable instrumentation boundary.
`Telemetry.Metrics` definitions require a real reporter. Handler work is
bounded and nonblocking: project only catalog-approved scalar measurements and
enum dimensions into a bounded message for a supervised collector. Raw event
metadata never enters its mailbox; the handler performs no SQL, network, or
log formatting in the caller. The collector
maintains fixed-size histograms and bounded enum dimensions, batches rollups
through the existing single writer, and reports its own dropped-event count.
Concurrent emitters reserve one of 10,000 queue slots atomically before
sending, and release it when the collector dequeues that event. A full queue
records a drop immediately. A pre-send mailbox-length observation is not a
capacity bound because multiple emitters can observe the same free slot.
The versioned diagnostic read exposes metric units, histogram upper bounds,
allowed dimensions, and collector reset time alongside each metric page.
`lossFreeSinceMs` is null after a known drop or while the collector is down;
`lastFlushedAtMs` identifies the most recent committed batch. A collector
restart resets in-memory loss accounting, so queries must not infer historical
completeness across that boundary.

The retention budget is minute buckets for 24 hours and hour buckets for 30
days. The writer must prune oldest rollups when their SQLite table and index
pages exceed 32 MiB, in addition to the 20,000-row cap. This active-page
budget excludes reusable free pages and the shared database WAL; physical file
size and long-running resource ceilings still require platform measurement.
The collector runs one maintenance pass after restart, even if no new samples
arrive, so an older oversized store converges to the current limits.
The health read reports active metric page bytes and the enforced page budget.
If the SQLite build cannot measure metric pages, health reports that gap and
metric writes fail without changing delivery state; coverage cannot claim a
loss-free interval after a failed flush.
Each query includes a coverage interval and reset marker so missing
observations cannot be represented as zero.

## Log and audit access

The macOS shell logs with Swift `Logger`. It supervises the bundled core and
drains its stdout/stderr pipes. A bounded parser and 512-record emission queue
forward only allowlisted, structured core records to Apple unified logging under subsystem
`io.frameshift.app`, with stable categories; arbitrary third-party output is
discarded. The shell counts records dropped when parsing or queue capacity is
exceeded. Pipe and bridge failure must not
block a command. A small rotating OTP file captures sanitized critical
failures when the bridge is unavailable. Console.app and `/usr/bin/log` are the
macOS log readers; the product does not build a logs UI. Apple controls
unified-log persistence, so it is not the audit store. Ubuntu sends sanitized
operational logs to journald for `journalctl`. The Nerves Pi appliance has no
journal and uses a bounded OTP circular disk log.

### Private callback logging

The [generation callback boundary](content-pipeline.md#generation-callback-privacy-and-refusal)
admits the same primary private-process filter used by original-byte codec and
upload tasks. It marks its owned task before provider preflight or generation.
Raw messages, private metadata and OTP fault reports from that process MUST be
dropped before all handlers, rather than relying on one sink's formatter.
Other operational records keep their existing policy. A conflicting filter
refuses new provider work without replacing unrelated configuration; verified
cached results stay usable. Provider error replies expose only the declared
finite classes, never arbitrary exception or service-response terms. Independent
adapter children/native workers require their own private-output qualification.
Raw-handler fixtures establish this callback process's protection; they do not
establish live-model, Keychain, external-effect cancellation or installed logging
acceptance.

### Fallback handler failure and custody

The Mac fallback uses OTP `logger_std_h` at error level with the existing
allowlisted formatter, a 2 MiB rotation threshold and three retained archives.
The current file and all supported archive names are admitted as regular files
inside a real owner-only `0700` directory; existing files and the initial active
file are restricted to `0600`. New rotated files remain private through that
directory. Unsafe paths and permission/open failures refuse installation, but
MUST NOT raise through host startup or terminate the Library, renderer or command
boundary. Diagnostic failure cannot replace a committed command result.

Installation is idempotent only for the exact handler module, path, formatter,
level and limits. A conflicting existing handler refuses without reconfiguring
or removing it. A newly added handler whose initial file cannot be secured is
removed; unrelated handlers remain owned by OTP and their callers.

The fallback sets equal sync/drop thresholds of 256 records, a flush threshold
of 512, and a 500-record/second burst limit. OTP selects drop before sync at equal
thresholds, so this sink does not impose synchronous overload backpressure on
command callers. These are overload controls, not an atomic mailbox capacity or
loss-free logging claim. The formatter bounds retained fields; raw error reports
and exception text never enter this sink. See the pinned OTP 29.1 sources
`logger_olp:check_load/1` and the
[OTP handler/overload documentation](https://www.erlang.org/doc/apps/kernel/logger_chapter.html#protecting-the-handler-from-overload).

Authenticated diagnostic health includes fallback configuration availability,
finite state, rotation/archive limits and an explicit null loss-free interval.
Missing or changed handler configuration reports unavailable. Availability
describes the configured sink, not current disk writability, durable audit
coverage or every subsequent write. Real-handler fixtures exercise rotation and
sanitization at a reduced threshold, failed admission, configuration conflict and
handler removal; long-running Mac/Linux storage and failure measurements remain
separate evidence.

`frameshiftctl diagnostics health|metrics|audit` is a read-only client of the
versioned local IPC contract. Responses are size-limited and audit queries use
stable pagination and explicit retention metadata. A standalone client cannot
reuse the menu shell's in-memory bootstrap token. Its separate read-only
authentication must verify the Unix peer identity and private socket directory
on each platform. The current Mac mutation endpoint retains its boot token;
Linux peer/group admission follows the Linux host contract. The CLI does not open
the database or read the Apple unified log store programmatically. Explicit
local export is redacted, bounded, and records its own audit fact.

Linux group-authorized command claims/completions retain the kernel UID in the
private receipt and expose only its policy-bound SHA-256 `actorId` in diagnostic
audit detail. That hash supports correlation and is not anonymization of a
numeric OS account. Raw UID, PID, username and group membership never become
metric labels or operational log fields. Private launch-token commands omit
`actorId`. Receipt identity and conflict/recovery behavior are owned by the
[Linux command contract](../host/linux.md#group-owned-command-endpoint-and-receipts).

Before the OTP fallback file handler starts, the core must inspect the final
diagnostics directory and any existing log file without following a symlink.
It must refuse a symlink or non-regular log target, require a private directory,
and restrict an existing regular log to owner-only access. A failed admission
must leave the fallback sink unavailable while the authoritative core continues;
it must never redirect records into an attacker-chosen file. This local path
check does not replace installed filesystem, ownership, or race-condition
acceptance testing.

### Local connection admission

The command listener admits at most sixteen live connection workers;
read-only diagnostics independently admits sixteen. Kernel listen backlogs
remain sixteen, without a user-space request queue. At capacity the listener
closes the new connection before decoding or claiming a command; a worker's
actual exit releases its slot. Authentication and bounded framing are unchanged.
A stalled partial request retains the existing five-second read deadline.

The ordinary application task supervisor has a hard sixty-four-child ceiling,
including acceptors and other supervised work. Diagnostics has a separate
seventeen-child supervisor (one acceptor and sixteen workers), so exhausted
ordinary task capacity cannot deny a diagnostic worker. A rejected task start
closes the socket without creating a receipt or retry. These are process and
admission bounds, not measured RSS, a deadline for every downstream operation,
Linux control-group qualification or guaranteed SQLite responsiveness during
a storage failure.

The pinned Elixir 1.20.4 `Task.Supervisor` passes `max_children` to its dynamic
supervisor and returns `{:error, :max_children}` on rejected child admission.
Its [upstream source at v1.20.4](https://github.com/elixir-lang/elixir/blob/v1.20.4/lib/elixir/lib/task/supervisor.ex)
and installed source were inspected on 2026-10-04; the GitHub source blob is
`0164e9b8111312f44c394339190dcb5c47c1b35a`. Real Unix-socket fixtures must close
overflow without mutation, read diagnostics while ordinary tasks are saturated,
and admit a fresh request after worker exit. Packaged startup must exercise the
separate supervised owners. Physical disk/power and full operated-load
measurements retain their separate gates.

## Failure and acceptance cases

- Reconstruct a failed update from command ID through render, durable intent,
  network attempt, and frame-confirmed or pending state after core restart.
- Verify no secret or private content appears in Console, fallback logs,
  metrics, audit export, or error responses.
- Crash and restart the log bridge and metric collector during delivery;
  product state remains correct and diagnostics report loss/coverage.
- Prove the metric and fallback-log disk ceilings and idle CPU/wakeup budget on
  macOS and a supported Linux/Pi host.
- Verify the CLI rejects an unauthenticated or wrong-user peer, never permits
  mutations, and returns deterministic pagination under concurrent writes.

Primary upstream references: [Apple unified logging](https://developer.apple.com/documentation/os/logging/),
[OSLogStore local-store permissions](https://developer.apple.com/documentation/oslog/oslogstore/local%28%29),
[Telemetry handler semantics](https://telemetry.hexdocs.pm/),
[Telemetry.Metrics reporters](https://telemetry-metrics.hexdocs.pm/Telemetry.Metrics.html),
and [Google SRE service indicators](https://sre.google/workbook/implementing-slos/).
