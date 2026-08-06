# Trackify Goal 2: Configurable Work Intelligence

Status: Source implementation complete; signed-release validation pending
Last updated: 2026-08-06

Implementation status: Milestones 1 through 5 are implemented. The deterministic
compiler, capability discovery, passive Preferences, persisted report queue,
usage and budget ledger, versioned recipes, immutable artifacts, privacy
profiles, local destinations, migrations, simulation, and CLI parity are in
place. The source acceptance result and the remaining credential/soak gates are
recorded in [GOAL_2_ACCEPTANCE_AUDIT.md](./GOAL_2_ACCEPTANCE_AUDIT.md); measured
results are recorded in [VALIDATION.md](./VALIDATION.md).

Goal 2 is the next product milestone after the V1 evidence ledger. It is an
incremental extension of V1, not a rewrite and not a commitment to a remote
Trackify service.

The V1 scope remains defined by [V1.md](./V1.md). The durable product principles
remain defined by [VISION.md](./VISION.md), and the existing privacy boundary
remains the minimum contract defined by
[PRIVACY_SECURITY.md](./PRIVACY_SECURITY.md).

## 1. Outcome

Goal 2 turns Trackify's raw reporting capability into a production-ready,
configurable work-intelligence system.

After Goal 2, Trackify should:

1. Discover local Codex and Claude capabilities without reading or copying
   provider credentials.
2. Clearly distinguish conversation-history sources from providers capable of
   generating a report.
3. Compile small, representative evidence packets that preserve intent,
   outcomes, parallel projects, failures, and unfinished state.
4. Generate reports from versioned recipes instead of one hardcoded prompt.
5. Record the measured usage, duration, provider, model, result, and honest cost
   interpretation of every Trackify-initiated model run.
6. Enforce predictable call, token, and optional monetary budgets without ever
   interrupting evidence collection.
7. Store every generated result as a reusable, provenance-backed artifact.
8. Expose the same capabilities through the native app and a stable CLI.
9. Provide clean extension points for later Clockify, Slack, email, and other
   destinations without embedding those services in the reporting engine.

The system must remain useful when no model provider is installed, authenticated,
reachable, or enabled. Local collection, deterministic statistics, search,
history, and deterministic reports are never secondary modes.

## 2. Product boundary

### Goal 2 includes

- Smart, deterministic evidence compilation.
- Capability-based Codex and Claude discovery.
- A passive Sources, Summaries, Usage, and Recipes preferences experience.
- Explicit provider selection, automatic selection, and local-only operation.
- A report-run queue separated from collection.
- Per-run usage and cost provenance.
- Call, token, and optional monetary budgets.
- Versioned report recipes with bounded custom instructions.
- Immutable report artifacts and local export/copy destinations.
- Migration of existing reports into the artifact model without new model calls.
- CLI parity and a versioned JSON contract for the new capabilities.
- Deterministic simulation and fixture-backed validation of all of the above.

### Goal 2 prepares, but does not implement

- Clockify API synchronization.
- Slack, email, social, issue-tracker, or webhook delivery.
- Automatic posting or sending of external communications.
- A general plugin marketplace or in-process third-party plugin runtime.
- Remote provider-account billing aggregation.
- Team accounts, remote sync, or cross-device history.
- Ordinary Claude Desktop chat scraping or unsupported private API access.
- Automatic mutation of Codex or Claude configuration files.
- A productivity score or inferred billable duration.

The destination boundary is implemented in Goal 2 so later integrations are
small adapters. Networked destinations themselves should be promoted only after
a real workflow and permission model are validated.

## 3. Non-negotiable principles

### Evidence remains the authority

Model output is a derived interpretation. It cannot change imported evidence,
metric totals, period state, or the distinction between completed and unfinished
work. A provider can word a report; it cannot declare structural facts that the
ledger does not support.

### Sources and generators are separate capabilities

Finding a Codex or Claude history does not prove that its CLI can generate a
report. Conversely, an authenticated CLI can generate a report even when there
is no local history for that provider. The UI, settings, and data model must not
collapse these into one "connected" flag.

### Passive defaults, explicit network effects

Trackify should choose sensible defaults and require no daily administration.
Users can see and control model use in Preferences. New outbound destinations
are opt-in, and any communication sent to another person defaults to a draft or
manual approval.

### Collection cannot depend on reporting

Repository and conversation collection writes durable evidence first. Report
compilation and provider work happen through a separate bounded queue. Provider
latency, rate limits, cancellation, or failure cannot hold the collection lease
or make the ledger appear stale.

### Privacy is enforced before invocation

Redaction, selection, aliasing, and size enforcement happen locally before a
provider process starts. Custom instructions cannot weaken those controls or
grant the provider tools, filesystem access, or network access beyond the
provider's normal service call.

### Cost language must be honest

Trackify can precisely attribute calls it starts and usage a provider reports.
It cannot always know the user's incremental financial charge. Subscription,
enterprise, gateway, Bedrock, Vertex, and API-key billing contexts have different
semantics and must not be presented as one exact dollar value.

### One domain model, several clients

The menu bar app, main window, CLI, future MCP adapter, and future destinations
must use the same domain services. None may read or reinterpret SQLite directly.

## 4. Current baseline

V1 already provides the foundation Goal 2 should preserve:

- A local SQLite evidence ledger with stable provenance.
- Git, Codex, and Claude history collectors.
- Deterministic statistics, period state, reports, simulation, and backfill.
- Provider-neutral `SummaryProvider` behavior for Codex and Claude CLIs.
- Tool-free, read-only, non-persistent provider invocations.
- Bounded redacted evidence packets and validated structured output.
- Provider failure fallback that leaves collection operational.
- A native menu/main-window experience and a first-class CLI.

The pre-Goal-2 evidence packet was safe and bounded, but not selective enough. It
took up to the latest 200 events, capped excerpts at 600 characters, and capped
the complete packet at 256 KiB. On a busy real day, packet inspection showed that
hourly reports could consume about 165,000 input tokens before the daily report,
with individual hours around 16,000 tokens on average. The exact provider spend
was zero when no summary provider was configured, but the potential shape was too
large and too biased toward the newest raw events.

Goal 2 fixes that before adding more report types.

## 5. Target experience

### Default first run

Trackify quietly discovers:

- supported Codex history locations;
- supported Claude Code and Claude Desktop Code history locations;
- a usable Codex CLI;
- a usable Claude Code CLI;
- version and bounded authentication-readiness information where officially
  exposed.

If exactly one generator is ready, Automatic mode may select it. If both are
ready, Automatic uses a documented deterministic priority and displays the
effective provider. An explicitly selected provider is never silently replaced
by another billing provider. If none is ready, Trackify stays Local only without
degrading the ledger.

Trackify never reads provider authentication files or Keychain entries. It uses
only documented executable/version/status commands and learns the result of a
real generation call only after the user has enabled model reports or requested
a provider test.

### Preferences

Preferences should contain four Goal 2 sections:

1. **Sources** — detected history surfaces, location, compatibility state,
   imported record count, last successful sync, permissions, and rescan.
2. **Summaries** — Automatic, Codex, Claude, or Local only; effective provider;
   model profile; cadence; budgets; and a bounded test preview.
3. **Usage** — calls, tokens, duration, failures, cost interpretation, and budget
   progress by day and month.
4. **Recipes** — built-in and custom report recipes, scope, privacy profile,
   output shape, and preview.

Most users should never need to open these views. Their job is visibility and
control, not required setup ceremony.

Because current and archived caches can contain the same logical conversation,
the displayed record count and last-import time are explicitly scoped to the
deduplicated Codex or Claude ledger family. Trackify does not pretend those
overlapping records can be attributed to one cache surface after deduplication;
surface availability and permissions are still probed independently.

### Report history

The existing Activity timeline remains the chronological work view. Reports and
other generated outputs are artifacts attached to periods and evidence. They can
be inspected from the relevant day, project, or timeline entry and filtered in
an artifact history when necessary. Goal 2 must not restore a redundant top-level
Reports tab that duplicates the Activity timeline.

## 6. Architecture

The Goal 2 pipeline is:

```text
local sources
    -> durable evidence ledger
    -> deterministic evidence compiler
    -> versioned report recipe
    -> bounded report-run queue
    -> local renderer or selected model provider
    -> validated immutable artifact
    -> optional destination adapter
```

The important dependency direction is inward:

```text
UI / CLI / future MCP / destinations
              |
        application services
              |
 compiler / recipes / runs / artifacts / budgets
              |
      evidence queries and store ports
              |
      GRDB and provider adapters
```

Provider adapters know how to discover and invoke a provider. Destination
adapters know how to deliver an existing artifact. Neither owns evidence
selection, recipe policy, budget policy, or artifact storage.

### 6.1 Core domain types

Names may change during implementation, but these responsibilities must remain
separate.

#### `SourceCapability`

Describes one readable history surface:

- source family and surface, such as Codex CLI, Claude Code CLI, or Claude
  Desktop Code;
- discovered location and compatibility-adapter version;
- available, permission denied, unsupported, or degraded state;
- last probe and last successful import;
- supported operations, currently history import only.

Ordinary Claude Desktop chat is not inferred from Claude Desktop Code and is not
scraped. A future officially supported export can become another explicit source
adapter.

#### `GenerationCapability`

Describes one executable capable of generating a report:

- provider identifier, executable location, and CLI version;
- authentication state: ready, unknown, unavailable, or not installed;
- structured-output support;
- usage-reporting support;
- hard monetary-cap support;
- requested and effective model support;
- invocation-contract version and last probe.

Capability checks belong inside versioned adapters. Provider/version conditionals
must not leak across scheduling, preferences, and report code.

#### `ReportRecipe`

A versioned recipe contains:

- stable recipe identifier and immutable version;
- name, purpose, audience, and cadence;
- repository/group scope;
- custom focus instructions;
- typed output format and maximum length;
- privacy profile;
- provider/model profile;
- per-run budget overrides when allowed;
- optional destination references.

Editing a recipe creates a new version. Existing artifacts continue to reference
the exact version that produced them.

#### `CompiledEvidencePacket`

A transient, deterministic value containing:

- schema and compiler version;
- period and locally derived state;
- aggregate metrics;
- project/session partitions;
- selected aliased evidence;
- final repository state and unfinished-work signals;
- omission counts, selection reasons, and truncation metadata;
- estimated serialized bytes and input tokens.

The full packet is not persisted by default. Its compiler version, safe summary
metadata, selection counts, and alias-to-evidence mapping needed for provenance
are persisted with the run/artifact. Diagnostics may render a redacted preview
only through an explicit user action.

#### `ReportRun`

An append-only operational record containing:

- recipe and recipe version;
- period and provider-selection mode;
- requested provider/model and effective provider/model;
- compiler, prompt, invocation, and output-schema versions;
- input bytes and estimated preflight tokens;
- measured input, cached input, output, and reasoning tokens when reported;
- cost value, currency, cost kind, and billing-context interpretation;
- queue, execution, and total duration;
- pending, running, succeeded, fallback, cancelled, timed out, or failed state;
- safe classified failure details;
- resulting artifact identifier.

Raw provider output, prompts, environment values, and credentials are not stored
in the run record.

#### `Artifact`

An immutable output ready for inspection or delivery:

- artifact identifier, type, format, and creation time;
- recipe identifier and version;
- report-run identifier when model-generated;
- period, project/group scope, and privacy profile;
- validated content;
- evidence references and locally derived state;
- revision relationship when a user explicitly regenerates it.

Artifacts are stored before any delivery attempt. Regeneration creates a new
artifact; it does not mutate history.

#### `Destination` and `DeliveryAttempt`

Goal 2 implements the interface plus local clipboard/file destinations. A later
networked adapter receives an artifact and records:

- destination type and non-secret configuration;
- explicit permission state;
- idempotency key;
- pending, delivered, failed, or cancelled state;
- bounded retry metadata and safe external identifier.

Provider and destination credentials remain owned by their provider when
possible. Credentials Trackify must own for a future destination belong in the
macOS Keychain; only a non-secret reference belongs in settings or SQLite.

### 6.2 Storage and compatibility

Goal 2 adds versioned GRDB migrations for recipes, recipe versions, report runs,
artifacts, artifact evidence, destinations, and delivery attempts. Migrations
must preserve the V1 evidence tables and stable identifiers.

Existing V1 reports are migrated into legacy report artifacts locally:

- no model is invoked during migration;
- original report identifiers and evidence references remain resolvable;
- missing telemetry is stored as unknown, never guessed;
- existing `trackify show report` and report queries remain compatible through
  an application-layer compatibility view;
- migration backups continue to follow the private-file contract.

The migration must be reversible by restoring the pre-migration backup, not by
attempting lossy down-migrations.

## 7. Smart evidence compiler

This is the first implementation milestone because every later feature otherwise
multiplies avoidable token use and low-quality context.

### 7.1 Selection policy

For each period, the compiler must:

1. Partition evidence by repository and session so parallel work is preserved.
2. Identify user messages that express goals, corrections, questions, and
   decisions.
3. Pair related assistant progress with user intent only when repository/session
   provenance supports the relationship.
4. Prefer concrete commits, tests, failures, working-tree changes, and final
   state over repeated progress narration.
5. Preserve blockers, investigations, abandoned approaches, and explicit
   unfinished state.
6. Deduplicate repeated observations and near-identical messages.
7. Allocate a minimum share to each active project before distributing remaining
   capacity by evidence importance.
8. Record why each item was selected and how many lower-priority items were
   omitted.

Selection is deterministic for the same ledger, compiler version, recipe, and
clock. It uses typed rules and bounded scoring, not another model call.

### 7.2 Packet shape and budget

Initial targets, to be validated against real ledgers:

- 20–30 evidence records per hourly packet;
- 240–320 characters per selected excerpt;
- 12–20 KiB serialized hourly packet;
- approximately 3,000–6,000 input tokens per active hour;
- explicit per-project and per-evidence-type omission counts.

These are engineering budgets, not product promises. Fixture and real-ledger
measurements decide the final defaults before release.

Packet-local aliases such as `e1`, `r1`, and `s1` replace repeated long database
identifiers in the provider input. Trackify maps validated aliases back to stable
ledger identifiers after generation. Stable identifiers remain in local
provenance; they do not need to consume provider context repeatedly.

### 7.3 Hierarchical daily reports

A daily report must not summarize the final slice of raw events. It is compiled
from:

- validated hourly artifacts or deterministic hourly summaries;
- day-level commits and outcomes;
- per-project totals;
- final repository state;
- unresolved or continued work carried across hour boundaries.

The compiler may add a small number of day-level evidence items not represented
in hourly artifacts. It must preserve quiet periods and must not turn several
unfinished hourly updates into a completed daily claim.

### 7.4 Expected improvement

The release target is a 5–10x reduction from the current busy-day input shape,
with roughly 20,000–50,000 input tokens for a heavy reporting day as a target
range. Quality and evidence coverage are release gates; token reduction alone is
not success.

## 8. Recipes and prompt policy

### 8.1 Built-in recipes

Goal 2 ships a deliberately small set:

- **Hourly work note** — compact private evidence summary.
- **Daily work summary** — outcomes, parallel projects, and unfinished state.
- **Stand-up draft** — completed, current, and blocked.
- **Timesheet description** — concise project-scoped description without
  inventing duration.

Additional recipes should be user-created or added only when they represent a
distinct stable output contract.

### 8.2 Customization boundary

Users can customize focus, tone, audience, length, and typed format. They cannot
override the base policy that requires:

- supplied evidence only;
- honest unfinished/inactive state;
- local secret redaction and bounded input;
- no tools, filesystem inspection, or arbitrary commands;
- schema-valid output;
- evidence provenance;
- privacy-profile and destination eligibility checks.

Custom instructions are data inside a fixed Trackify prompt envelope, not a raw
replacement system prompt.

### 8.3 Privacy profiles

Recipes use one of four initial profiles:

- **Private** — local personal report; may include redacted conversation intent.
- **Team** — removes personal/private material and keeps work-safe project facts.
- **Client** — includes only explicitly eligible repositories/groups and
  client-safe evidence classes.
- **Public** — excludes Work/client groups by default and uses the strictest
  content allowlist.

Moving an artifact to a less-private destination requires a recipe compiled for
that privacy profile. A private artifact is not merely relabeled public at
delivery time.

## 9. Provider discovery and selection

### 9.1 Discovery

Each provider adapter probes documented paths and commands without shell
interpolation:

- PATH and supported common application-bundled locations;
- CLI version;
- bounded non-interactive authentication status where the installed version
  supports it;
- structured output and usage-reporting capabilities.

The Claude adapter treats terminal Claude Code history, Claude Desktop Code
history, and the report-generation CLI as separate observed capabilities even
when they share an underlying engine. Desktop Code history can be imported when
its documented local format is compatible. Claude Desktop's ordinary chat is out
of scope.

### 9.2 Selection modes

```text
automatic
codex
claude
local_only
```

- `automatic` selects a ready provider by documented priority and displays the
  effective choice before a call.
- `codex` and `claude` never silently fail over to the other provider.
- `local_only` makes no provider calls.
- Any provider failure publishes a deterministic fallback when a report is due.

The first implementation preserves V1 model defaults. Models and invocation
contracts are versioned provider profiles so later changes do not scatter model
names through the application.

### 9.3 Provider tests

A Preferences or CLI provider test:

- states whether it will send a synthetic payload;
- sends no repository or conversation evidence;
- uses a tiny hard limit when supported;
- records its own usage as a test run, separate from work reports;
- never changes global provider configuration.

## 10. Usage, cost, and budgets

### 10.1 Usage ledger

Every Trackify-started generation records the best provider-reported usage
available. The parser must preserve distinct categories instead of reducing them
to one number:

- input tokens;
- cached input tokens;
- output tokens;
- reasoning tokens where exposed;
- provider-reported cost where exposed;
- requested/effective model;
- duration, status, and failure class.

Unknown values remain null/unknown.

### 10.2 Cost interpretation

The UI and CLI use an explicit `costKind`:

```text
provider_estimate
equivalent_api_estimate
included_subscription
contract_or_gateway_unknown
unknown
```

Examples of honest labels:

- "Provider-estimated cost: $0.08"
- "Equivalent API estimate: $0.08"
- "Included with provider subscription; incremental cost unknown"
- "Billing managed by your organization"

Trackify never claims to be the authoritative provider billing dashboard and
never estimates the user's total Codex or Claude account usage. It reports only
calls Trackify initiated.

Rate-card estimates require a versioned local rate card with model, effective
date, currency, and source. If the effective model or billing context is unknown,
Trackify does not fabricate a dollar total.

### 10.3 Budget enforcement

Budgets are evaluated in this order:

1. Compile the local packet.
2. Check active-period eligibility and recipe cadence.
3. Check calls-per-day.
4. Check estimated input-token allowance.
5. Check daily token allowance.
6. Check optional monetary allowance only when its cost semantics are usable.
7. Apply the provider's runtime hard cap when supported.
8. Record actual usage after completion.

Initial controls:

- maximum serialized input and estimated input tokens per call;
- maximum generation calls per day;
- daily Trackify token ceiling;
- optional monthly token ceiling;
- optional daily/monthly monetary ceiling where meaningful;
- maximum concurrent model runs of one;
- process deadline and cancellation;
- no model calls for inactive periods;
- no automatic catch-up storm after sleep, upgrade, or backfill.

When a budget is exhausted, the job becomes a deterministic artifact and the UI
shows `LLM budget paused`. Collection and future eligible periods continue.

## 11. Scheduling and concurrency

Goal 2 introduces an explicit report-run queue owned by the engine:

- collection commits evidence and releases its lease first;
- report jobs refer to closed periods and recipe versions;
- the queue deduplicates by period, recipe version, and generation intent;
- current-hour previews remain deterministic;
- historical evidence backfill never implies historical model backfill;
- model backfill requires a plan preview and explicit confirmation;
- wake/relaunch coalesces eligible recent work and does not replay every missed
  hour;
- one model process runs at a time by default;
- cancellation and timeout terminate only the exact child process;
- failure classification controls retry eligibility, but deterministic fallback
  is immediately available.

The UI exposes distinct state labels such as `Syncing evidence`, `Summarizing`,
`Up to date`, and `LLM budget paused`. A provider spinner must never imply that
the ledger itself is stale.

## 12. Artifact and destination boundary

Generation ends when a validated artifact has been stored. Delivery begins after
that boundary.

Goal 2 includes:

- copy artifact as plain text;
- export artifact as Markdown or versioned JSON;
- inspect recipe, evidence, state, provider, usage, and revision provenance;
- a destination protocol and mocked delivery contract.

Future Clockify behavior should use the Clockify timer or user-reviewed entry as
the duration authority. Trackify's evidence hours are not elapsed or billable
hours. A Clockify adapter may fill a description, project, tags, and propose an
entry for review; it must not silently turn evidence observations into billed
duration.

Future person-facing destinations default to draft/manual approval. Automatic
delivery, if added, requires an explicit per-destination opt-in, scoped
credentials, idempotency, an audit trail, safe retries, and a visible off switch.

## 13. CLI contract

Exact spelling may be refined during implementation, but Goal 2 must expose these
operations through the shared domain services:

```bash
trackify sources status --json

trackify providers status --json
trackify providers use automatic
trackify providers use codex
trackify providers use claude
trackify providers use local
trackify providers test codex --json

trackify usage today --json
trackify usage month --json
trackify usage runs --since 7d --json

trackify recipes list --json
trackify recipes show <recipe-id> --json
trackify recipes create --from <file>
trackify recipes preview <recipe-id> --period <period>

trackify artifacts list --since 7d --json
trackify artifacts show <artifact-id> --json
trackify artifacts export <artifact-id> --format markdown
```

Mutation commands require explicit arguments and return the effective saved
configuration. JSON schemas are versioned, bounded, and contract-tested. A future
MCP server remains a thin adapter over these same services.

## 14. Decisions and validation spikes

### Decided now

1. Extend the Swift/SwiftUI/GRDB architecture; do not introduce a web runtime or
   second backend.
2. Implement the deterministic evidence compiler before adding recipes or
   destinations.
3. Separate source discovery from generation capability.
4. Separate collection from the provider-run queue.
5. Store immutable artifacts before delivery.
6. Version recipes and provider/prompt/compiler contracts.
7. Preserve explicit local-only operation and deterministic fallback.
8. Never silently switch an explicitly selected provider.
9. Record usage with honest cost semantics rather than a universal dollar claim.
10. Keep provider and destination adapters outside the core domain.
11. Keep networked destinations out of the Goal 2 release boundary.

### Validate before locking defaults

1. The exact event-priority weights and per-project allocation in the compiler.
2. The 20–30 record, 12–20 KiB, and 3,000–6,000 token packet defaults.
3. How provider versions expose cached/reasoning token categories and effective
   model identifiers.
4. Which Claude CLI versions expose safe non-interactive auth status.
5. Claude Desktop Code history compatibility across supported releases.
6. The most useful default daily call and token ceilings.
7. Whether hourly model reports should be on by default or whether daily plus
   on-demand hourly reports gives a better cost/utility balance.
8. Whether artifact history needs a dedicated filtered surface after real usage,
   or remains best embedded in Activity/day/project views.

Each item is a bounded spike with fixtures or measurements and a written outcome,
not an invitation to add a new abstraction pre-emptively.

## 15. Implementation plan

### Milestone 1: Evidence compiler

Deliver:

- typed selection reasons and deterministic prioritization;
- project/session partitioning and fair bounded allocation;
- user-intent, outcome, failure, and final-state selection;
- packet-local aliases and provenance mapping;
- hierarchical daily input;
- packet preview diagnostics and size/token estimates.

Exit gate:

- golden fixtures prove that parallel projects, user intent, commits, tests,
  blockers, and unfinished state survive truncation;
- no hourly fixture exceeds the configured cap;
- real-ledger measurement shows at least 5x median input reduction without
  losing required evidence categories.

### Milestone 2: Capability discovery and Preferences

Deliver:

- separate source and generation capability records;
- versioned Codex and Claude probes;
- Automatic, explicit-provider, and Local-only modes;
- Sources and Summaries preferences;
- synthetic provider test and clear readiness/degraded states.

Exit gate:

- the install matrix works for Codex only, Claude CLI only, Claude Desktop Code
  history only, both, neither, unauthenticated, and managed-provider machines;
- Trackify never reads credentials or changes provider configuration;
- an explicit provider never silently fails over.

### Milestone 3: Report queue, telemetry, and budgets

Deliver:

- persisted report-run queue and state machine;
- collection/reporting separation;
- provider usage parsers and run telemetry;
- Usage preferences and CLI queries;
- per-call, daily, and monthly budgets;
- cancellation, timeout, coalescing, and no-catch-up-storm policy.

Exit gate:

- slow or failing providers cannot delay a completed collection transaction;
- every Trackify invocation has a run record with explicit known/unknown fields;
- budget exhaustion produces a deterministic artifact with no provider call;
- sleep/wake and backfill simulations generate no unexpected burst.

### Milestone 4: Recipes and artifacts

Deliver:

- versioned built-in and custom recipes;
- locked base prompt/privacy policy;
- artifact and revision storage;
- migration of V1 reports without generation;
- recipe preview and artifact inspection in app and CLI;
- private/team/client/public profiles.

Exit gate:

- old reports remain resolvable;
- editing a recipe cannot alter old artifacts;
- malicious custom instructions cannot enlarge the packet, enable tools, escape
  the schema, or weaken redaction;
- artifacts retain exact run, recipe, state, and evidence provenance.

### Milestone 5: Local destinations and release hardening

Deliver:

- clipboard, Markdown, and JSON destinations;
- destination/delivery protocols with mock adapters;
- idempotency and retry state tests;
- complete CLI JSON schemas and compatibility tests;
- UI accessibility, performance, and visual validation;
- upgrade/rollback, diagnostics, and documentation.

Exit gate:

- repeated delivery cannot duplicate a successful operation;
- exported content matches the artifact and privacy profile exactly;
- the full validation matrix passes on a signed release candidate;
- Goal 2 adds no network endpoint beyond existing provider/update behavior.

## 16. Validation strategy

### 16.1 Domain tests

- Same evidence, clock, compiler version, and recipe produce the same packet.
- User intent remains visually and semantically distinct from assistant output.
- Parallel repositories each receive bounded representation.
- Commits/tests/failures/final state outrank repeated assistant narration.
- In-progress and investigating periods never become completed from unsupported
  language.
- Quiet periods produce no provider call.
- Daily compilation is based on the full day's hierarchy, not the newest suffix.
- Aliases map only to supplied stable evidence identifiers.

### 16.2 Privacy and adversarial tests

- Synthetic provider, GitHub, AWS, Slack, bearer, path, username, and arbitrary
  secret fixtures are redacted before serialization.
- Unsupported payload categories never enter packets.
- Prompt-injection text inside imported conversations remains untrusted evidence.
- Custom recipe text cannot request tools, raw files, credentials, or unrestricted
  transcripts.
- Private/client/public scope rules fail closed.
- Raw prompt and provider output never enter normal logs or the ledger.

### 16.3 Provider contract tests

- Codex and Claude valid structured output.
- Malformed JSON, schema mismatch, unsupported evidence alias, oversized output,
  non-zero exit, timeout, cancellation, auth failure, rate limit, and unavailable
  model.
- Usage parsing with missing, added, and reordered provider fields.
- Effective-model and cost metadata preservation.
- Hard budget flag applied only when the adapter advertises support.
- Executable arguments are never shell-interpolated.

### 16.4 Source compatibility tests

Sanitized fixtures cover:

- supported Codex CLI/Desktop histories;
- supported Claude Code terminal histories;
- supported Claude Desktop Code histories;
- truncated, partially written, duplicated, moved, and future-version records;
- permissions denied and histories absent;
- Trackify internal-run feedback-loop exclusion.

Compatibility is versioned per source surface. A provider generation update
cannot silently change history ingestion.

### 16.5 Store and migration tests

- Fresh install and upgrade from every supported V1 schema.
- Existing reports become legacy artifacts without a model call.
- Unknown historical telemetry remains unknown.
- Stable identifiers and evidence links survive migration.
- Interrupted migration restores cleanly from the private backup.
- Artifact, run, and delivery idempotency constraints reject duplicates.
- Retention/export/delete behavior includes all new Goal 2 records.

### 16.6 Scheduler and simulation tests

Use the existing injected clock and isolated data roots to simulate:

- two busy days with parallel projects;
- quiet hours and a completely quiet day;
- work spanning midnight;
- sleep/wake with several closed periods;
- collection during a slow 180-second provider run;
- token/call/cost budget exhaustion and reset;
- provider loss and recovery;
- evidence backfill with model backfill disabled;
- explicitly approved bounded model backfill;
- retry after transient failure without duplicate artifacts.

Simulation must use a mock provider by default. Real provider tests are opt-in,
synthetic, and protected by a tiny hard budget.

### 16.7 UI validation

- Fixed-clock showcase data covers ready, unknown, unavailable, running, failed,
  fallback, and budget-paused states.
- Preferences remain legible with neither, one, or both providers available.
- Usage distinguishes tokens from money and known from unknown cost.
- Report/artifact provenance is inspectable without exposing raw secrets.
- Empty states are centered and actionable without implying missing evidence.
- Scrolling and filtering remain responsive with at least 100 repositories, one
  year of activity, and realistic conversation volume.
- Screenshots are captured for light/dark mode and supported window sizes.
- VoiceOver labels, keyboard navigation, reduced motion, and contrast are checked.

### 16.8 CLI validation

- Human and JSON outputs agree on effective provider and budget state.
- JSON fixtures are schema-versioned and backwards compatible.
- All list commands are bounded and paginatable where volume can grow.
- Mutation commands are explicit and idempotent.
- Agents can answer "what was I doing today?" using documented commands without
  reading SQLite or application UI.

### 16.9 Live release matrix

Before Goal 2 release, manually validate:

| Machine state | Expected behavior |
| --- | --- |
| Codex ready only | Codex available; both supported histories still import |
| Claude CLI ready only | Claude available; both supported histories still import |
| Claude Desktop Code history only | History imports; generation remains local |
| Both ready | Automatic shows its choice; explicit choice is stable |
| Neither installed | Full local ledger and deterministic reports |
| Installed, unauthenticated | Honest unknown/unavailable state; no loop |
| Managed/enterprise provider | Usage retained; cost may remain contract-unknown |
| Provider times out | Collection stays current; deterministic artifact appears |
| Budget exhausted | No invocation; visible budget-paused fallback |
| Sleep and wake | Recent jobs coalesce; no catch-up storm |

At least one opt-in live run per supported provider is reconciled against the
provider's own emitted usage. Trackify's display must match the captured run or
label unavailable fields honestly.

## 17. Release acceptance criteria

Goal 2 is complete only when all of the following are true:

1. Collection and deterministic reporting operate with no provider installed.
2. Source import and report-generation capability are represented separately.
3. Codex and Claude can each generate the same validated artifact contract.
4. An explicitly selected provider never silently changes.
5. Provider work never blocks or holds the collection lease.
6. The smart compiler preserves required evidence across parallel work while
   meeting its tested packet cap.
7. Daily reports cover the entire day through hierarchical inputs.
8. Custom recipes cannot bypass evidence, privacy, schema, or tool restrictions.
9. Every provider call has a durable run record and honest usage/cost semantics.
10. Budgets prevent calls before invocation and fall back locally.
11. Backfill never causes model use without a preview and explicit confirmation.
12. Existing V1 reports remain available after migration without regeneration.
13. Artifacts are immutable, versioned, and traceable to evidence and recipe.
14. Clipboard/Markdown/JSON delivery is idempotent and privacy-profile aware.
15. App and CLI expose the same provider, recipe, usage, and artifact state.
16. No provider or destination credential is read, copied, logged, or stored
    outside its documented owner/Keychain boundary.
17. Fixed-clock simulation and the live install matrix pass.
18. The signed release candidate completes the normal V1 release gates and a
    dedicated Goal 2 soak without collection stalls or unexpected provider calls.

## 18. Recommended build order

The milestones should be implemented in order. In particular:

```text
compiler
  -> capability model and preferences
  -> queue, telemetry, and budgets
  -> recipes and artifacts
  -> local destinations and release hardening
```

Recipes before the compiler would multiply expensive inputs. Destinations before
artifacts would couple external services directly to generation. Usage UI before
a run ledger would produce unreliable numbers. The order is therefore part of
the architecture, not merely project management.

## 19. After Goal 2

The first candidate for the next milestone is a Clockify draft/export adapter,
because it has a concrete workplace use and can consume the Goal 2 artifact
contract without changing generation. Slack/email/social drafts can use the same
boundary later.

Automatic external delivery should remain later than draft delivery. A read-only
MCP adapter or provider-specific discovery package can also be added when real
agent use shows that the CLI creates meaningful friction. Neither should create
a second ledger or reporting API.
