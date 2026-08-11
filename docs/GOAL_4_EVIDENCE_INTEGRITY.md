# Trackify Goal 4: Canonical Evidence Integrity

Status: Complete — bounded seven-day ledger activated and collecting forward
Last updated: 2026-08-07

Goal 4 rebuilds Trackify's conversation-evidence boundary so that every visible
statistic, project association, search result, summary, and CLI answer is based
on canonical logical work rather than raw provider records.

The current evidence ledger is disposable. Codex, Claude Code, Claude Desktop,
and Git retain the authoritative reconstructable history. Goal 4 therefore does
not preserve incorrect derived data for compatibility. It builds and validates
a new ledger for a bounded coverage window, carries forward only explicitly
user-owned configuration, and replaces the old evidence store after the new one
passes all integrity checks. Continuous collection then extends that ledger
forward.

The goal is not to hide unusual activity or make charts look plausible. It is
to record what providers actually emitted, interpret only semantics supported
by source provenance, keep uncertainty explicit, and make future compatibility
failures immediately visible.

## 1. Outcome

After Goal 4:

1. `LLM turns` means distinct canonical work turns, not the number of records
   carrying a `user` role.
2. Human prompts, delegated agent tasks, assistant progress, tool traffic,
   provider failures, hooks, control envelopes, and Trackify-internal activity
   remain distinguishable throughout ingestion and querying.
3. A provider record may be observed more than once or copied into several
   forked sessions without creating additional logical work.
4. Repeating the same short prompt in two real turns still counts twice.
5. Project attribution is resolved per turn or message from contemporaneous
   source context, never from one final session-wide working directory.
6. Unknown source semantics are quarantined as visible unresolved observations.
   They do not silently become work evidence and are not silently discarded.
7. Overview, Activity, project views, search, summaries, reports, and CLI
   context all consume one canonical work-evidence query boundary.
8. Provider discovery and health inspection cannot create provider sessions or
   consume tokens.
9. Semantic health monitoring detects schema drift, unexplained record ratios,
   unresolved lineage, internal-run leakage, and projection inconsistency as
   part of ordinary collection.
10. A clean bounded backfill can rebuild the configured coverage window
    deterministically at any time.

### 1.1 Completion scope

Goal 4 completion uses one deliberately bounded production scenario:

- backfill today and the preceding six local calendar days;
- use a captured rebuild cutoff, producing the half-open interval from local
  midnight six days before the current day through that cutoff;
- activate only after that seven-day window passes the complete integrity audit;
- run an immediate incremental collection after activation; and
- continue collecting new evidence normally from that point onward.

This goal does **not** require importing every historical Codex or Claude cache.
Older caches remain untouched and reconstructable. Exhaustive historical import
is a separate optional product capability, not a Goal 4 correctness or release
gate.

The boundary applies to work as well as data:

- source adapters must narrow candidates with provider-supported structural
  metadata before opening files when that can be done without false negatives;
- parsers must independently enforce the requested event-time interval;
- Git queries must use the same explicit date interval;
- diagnostics must report files considered, files opened, bytes read, records
  observed, and records accepted for each source; and
- an anomaly outside the seven-day interval is recorded as later work rather
  than expanding this goal.

Performance or memory work belongs in Goal 4 only when the problem is reproduced
by this bounded rebuild or by ordinary continuous collection. The full local
cache corpus may be used later as an opt-in stress benchmark, never as the
default rebuild path or a completion requirement.

## 2. Why this is a root refactor

Provider transcript files are event streams, not ready-made work ledgers. A
record labelled `user` can represent any of the following:

- a prompt written by the developer;
- a steering message during an active turn;
- an agent delegating work to a subagent;
- a tool result returned through a user-role transport record;
- stop-hook feedback or a retry instruction;
- an interruption envelope;
- restored transcript history copied into a fork or resumed session;
- provider-generated context or metadata;
- a command accidentally interpreted as a prompt.

Likewise, a provider session is not necessarily one independent body of work.
It may contain inherited parent history, sidechains, retries, compaction
snapshots, or work that changes repository during the session.

Text-prefix filtering can remove known symptoms, but it cannot establish who
created a record, which logical turn it belongs to, whether it is copied
history, or which repository it concerns. Goal 4 therefore separates observed
provider records from canonical messages, turns, and work evidence.

### 2.1 Audit baseline

The structural audit performed on 2026-08-07 found the following known cases in
the current development ledger. These are regression windows for the clean
rebuild, not totals that the new implementation must preserve:

- 256 Trackify-created Claude authentication-probe sessions containing a
  literal `auth` prompt and an invalid-key response;
- 1,363 Claude stop-hook feedback messages and roughly 1,041 provider-limit
  responses;
- 415 Claude Desktop user-role records during a two-hour interval backed by
  only 13 recorded run starts;
- a 1,031-turn chart spike on 2026-07-17 dominated by hook/retry traffic;
- large Codex fork/replay clusters around 2026-04-08 and 2026-07-27, including
  long messages repeated across and within sessions;
- approximately 45,900 more raw message-event instances than canonical message
  rows, which repository context queries could count because they bypassed
  alias resolution;
- at least 3,800 known control/diagnostic messages present in the ordinary
  message search index;
- session-wide repository association despite provider records carrying more
  precise turn-time context;
- a healthy `trackify doctor` result despite these semantic failures.

The Git audit did not find an equivalent commit-identity problem. Reachable
commits remain keyed by repository and hash, and baseline working-tree
observations remain excluded from activity. Goal 4 keeps those rules while
routing them through the shared canonical query boundary.

## 3. Evidence principles

The implementation follows these non-negotiable principles.

### 3.1 Observe before interpreting

An adapter first emits an immutable normalized observation containing only
allowlisted source fields. Classification and canonicalization happen in a
separate rebuildable projection. Changing a classifier never changes what was
originally observed.

### 3.2 Prefer identity over text

Provider record IDs, prompt/turn IDs, parent IDs, session lineage, record type,
and occurrence time establish identity. Text is supporting evidence, not the
primary global deduplication key.

Trackify never globally merges records merely because their text matches.
`do it` in two distinct turns is two turns. A copied record with the same stable
provider identity is one logical record, even when it appears in two sessions.

### 3.3 Unknown is a first-class state

When Trackify cannot safely classify a new record family, it stores a bounded
structural observation with an `unresolved` disposition and a reason. The raw
provider cache remains the source of truth. Unknown records do not create work
metrics until an adapter version understands them.

This is neither invention nor omission: the ledger explicitly says that a
record was observed but its work meaning is not yet known.

### 3.4 Diagnostics are retained but do not impersonate work

Provider errors, quota failures, hooks, retries, interruptions, and transport
records remain inspectable as diagnostic incidents. Repeated identical failures
are collapsed into an incident with a count and time span. They do not create
LLM turns or evidence hours by themselves.

A failure attached to a real work turn may be included as that turn's blocker
or terminal state. An isolated health-probe failure belongs only to system
diagnostics.

### 3.5 Derived state is disposable

Canonical mappings, classifications, metrics, search indexes, rollups, project
associations, summaries, and reports derived from evidence are rebuildable.
Source observations and explicitly user-owned configuration have different
lifecycles and are never conflated.

## 4. Layered data model

Goal 4 establishes four explicit layers:

```text
local provider caches and Git
        |
        v
normalized source observations       immutable, allowlisted provenance
        |
        v
canonical conversation graph         logical turns, messages, lineage, projects
        |
        v
work-evidence projection             work / diagnostic / control / unresolved
        |
        v
activity, search, summaries, reports, CLI, UI
```

### 4.1 Normalized source observations

Each provider observation records, when exposed by that source:

- source family and entrypoint;
- source file identity and adapter version;
- source record ID and record family;
- source session ID and parent/fork/sidechain identity;
- prompt or turn ID;
- parent record ID;
- message/response ID distinct from the record ID;
- role as reported by the provider;
- content-block kinds;
- `isMeta`, tool-result, hook, and sidechain flags;
- occurrence and observation timestamps;
- contemporaneous working directory and repository hint;
- sanitized allowlisted text only when the record kind permits retaining it;
- a structural fingerprint and source byte-range identity;
- parse status and unresolved reason.

Raw reasoning, credentials, arbitrary environment payloads, image/audio bytes,
tool arguments, raw terminal output, and unrestricted diagnostic bodies remain
outside the ledger. Unknown records retain structural identity and hashes, not
an unsafe copy of their entire payload.

### 4.2 Canonical logical turns

A logical turn is one substantive request submitted to an agent and its related
execution lifecycle. It contains:

- provider-scoped canonical turn ID;
- source prompt/turn IDs and aliases;
- actor origin: `human`, `agentDelegation`, or `unknown`;
- session and parent-turn lineage;
- start, terminal, and last-observed timestamps;
- state: in progress, waiting, completed, interrupted, failed, or unknown;
- repository association plus method and confidence;
- canonical messages and attached diagnostic incidents.

Provider IDs are authoritative when present. Fallback identities are scoped to
the provider and source graph. An ambiguous fallback does not become a turn; it
remains unresolved until compatibility improves.

### 4.3 Canonical logical messages

A logical message separates its semantic identity from the source instances in
which it appeared. Multiple source records may map to one message when:

- they share a stable provider message ID;
- two documented record families expose the same provider message;
- a fork contains an inherited parent message;
- an incremental source replay emits an already-observed record;
- an attachment-bearing and text-only representation are documented aliases.

Every mapping stores its reason and classifier/canonicalizer version. Source
instances remain traceable. Content-only global merging is forbidden.

### 4.4 Work-evidence projection

Classification uses independent axes instead of one overloaded enum:

| Axis | Values |
|---|---|
| Origin | human, agent, assistant, tool, hook, provider, system, Trackify, unknown |
| Semantic kind | intent, steering, progress, outcome, lifecycle, control, failure, diagnostic, unknown |
| Disposition | work, diagnostic, control, unresolved |
| Canonical state | primary, alias, replay, unresolved |

The projection records a version, rule/reason code, confidence, canonical
message/turn IDs, and effective repository association. It can be rebuilt from
normalized observations without rereading user content into application code.

## 5. Provider-specific normalization

Provider adapters own source syntax. Domain and query layers never check for
Claude- or Codex-specific text prefixes.

### 5.1 Codex

The Codex adapter must distinguish and preserve:

- `session_meta`, `turn_context`, `event_msg`, and `response_item` families;
- `turn_id` and message/client IDs as separate fields;
- actual user messages versus developer/app/internal context;
- agent messages versus reasoning and transport events;
- task start, completion, interruption, and failure lifecycle;
- original session/thread identity and any available fork/archive lineage;
- per-turn working directory from `turn_context`;
- the relationship between duplicate `event_msg` and `response_item`
  representations.

When a Codex fork copies parent history, inherited records map to the parent's
logical messages. Only newly created child turns add work. When source metadata
is insufficient, exact timestamp/content/sequence overlap may support a
high-confidence legacy alias, but ambiguous repeated text is retained as
unresolved rather than guessed away.

### 5.2 Claude Code and Claude Desktop

The Claude adapters must distinguish and preserve:

- record `uuid`, message/response ID, `promptId`, and `parentUuid` separately;
- `isSidechain`, `isMeta`, `userType`, entrypoint, and request identity;
- direct text input versus tool results and source-tool responses;
- hook feedback, task notifications, system records, API errors, fallbacks,
  retries, and interruptions;
- assistant message chunks sharing one response ID;
- terminal and Desktop audit-stream differences;
- contemporaneous `cwd` and branch context.

A Claude `user` role is work intent only when provenance establishes human or
agent-authored input. Tool results and meta records can remain attached to the
turn without incrementing its turn count.

### 5.3 Trackify-internal provider activity

Executable discovery is a pure filesystem operation. It may resolve symlinks
and inspect executable metadata but never starts a provider.

Provider authentication is represented as:

```text
not installed | installed, unverified | verified by successful generation |
last invocation failed authentication
```

An explicit provider test may invoke the documented no-persistence generation
contract after user action. Automatic `auth status` probing is removed.

Every Trackify provider invocation receives a private operation ID, internal
environment marker, no-session-persistence/ephemeral flags, and a private
temporary working directory. The operation is registered before launch. If a
provider violates no-persistence guarantees, source reconciliation recognizes
the operation structurally and records an internal diagnostic instead of work.

## 6. Canonical identity and replay handling

Canonicalization applies evidence in descending order of authority:

1. Stable documented provider record/message/turn identity.
2. Explicit parent, fork, sidechain, or replay lineage.
3. Documented dual record-family equivalence within the same logical turn.
4. Exact source-record reobservation after file replay, rename, truncation, or
   incremental cursor recovery.
5. High-confidence legacy graph overlap using timestamp, role, content hash,
   neighboring identities, and sequence position together.
6. Unresolved classification when none of the above is safe.

The following are explicit invariants:

- Importing the same source twice does not change logical counts.
- Copying parent history into a child session does not change parent counts.
- New child turns count once and retain their child/parent relationship.
- Equal text with distinct authoritative turn IDs counts separately.
- A missing source ID never causes global text-only deduplication.
- Aliases and replays retain traceable source instances and resolution reasons.
- Canonicalization is deterministic and idempotent for a fixed adapter version.

## 7. Repository attribution

Repository attribution belongs to each logical turn/message, not merely its
session. Resolution uses:

1. an exact contemporaneous working directory carried by the source record;
2. the nearest preceding turn context inside the same source session;
3. an explicit provider worktree/sidechain association;
4. the session working directory only as a lower-confidence fallback;
5. unknown when no supported mapping exists.

The mapping stores method, confidence, and validity time. A session may work in
several projects without applying its final directory retroactively. Inherited
fork history keeps the original work's repository and does not manufacture
activity in the child's current repository.

## 8. Metric contract

All activity calculations consume the work-evidence projection.

### LLM turns

`LLM turns` is the count of distinct canonical logical turns whose disposition
is `work` and whose origin is `human` or `agentDelegation`.

The primary UI remains one simple number. Detail and hover surfaces may show:

- human prompts;
- delegated/automated work turns;
- provider split.

Tool calls, tool results, assistant chunks, hooks, retries, provider errors,
transport envelopes, Trackify operations, aliases, and replayed history never
increment this metric.

### Evidence hours

An evidence hour exists when at least one canonical work event occurred during
that clock hour. Meaningful assistant progress, commits, working-tree changes,
tests, and builds may establish evidence. Diagnostic/control events alone may
not.

This remains evidence presence, not claimed human attention or invented elapsed
time.

### Conversation messages

Conversation-message counts use canonical work messages. Source-instance and
diagnostic counts remain available in evidence diagnostics but do not appear as
ordinary throughput.

### Projects and Git

Project counts use the effective per-event repository mapping. Commit counts
continue to use reachable repository/hash identity. Baseline working-tree
observations remain excluded from core activity.

## 9. Summaries, reports, search, and context

### Summaries

Canonical summaries receive:

- complete sanitized human intent messages;
- complete sanitized agent-delegation instructions;
- bounded assistant progress/outcome messages with explicit truncation;
- complete commit messages and deterministic Git statistics;
- builds, tests, and meaningful working-tree transitions;
- collapsed failure incidents only when attached to actual work;
- deterministic project and activity statistics from the same projection.

Transport traffic, replayed history, and isolated provider-health failures are
not summary evidence. Coverage counts canonical eligible evidence, not source
records.

Any classification or canonicalization version change invalidates affected
summary fingerprints. Corrected summaries become new immutable revisions.
Historical model output is not silently relabelled as corrected.

### Reports

Reports consume corrected summaries and direct canonical work anchors. Existing
artifacts remain immutable provenance records if retained, but a clean
development-ledger reset may omit unfinished Goal 2/3 derived artifacts. New
reports can never consume unresolved or diagnostic evidence as user intent.

### Search

Default search indexes canonical work content only. A separate diagnostics
scope may search safe diagnostic labels and incident metadata. Internal
contexts, raw tool output, secrets, and quarantined payload bodies are never
placed in the full-text index.

### CLI context

Repository and portfolio context use the same application query service as the
GUI. They never count raw `events` rows or independently reinterpret roles.
Canonical counts in Overview, `trackify today`, `trackify context`, summaries,
and reports must match for the same range and scope.

## 10. Semantic integrity monitoring

Goal 4 adds semantic health alongside storage and collector health. Collection
does not wait for a human to notice a chart spike.

### Hard invariants

The following conditions immediately mark evidence quality degraded:

- a work message lacks a canonical logical turn when its source requires one;
- one authoritative provider identity maps to conflicting content or roles;
- a canonical turn has incompatible origins or terminal states;
- an alias/replay cycle exists;
- a Trackify internal operation reaches the work projection;
- two application query paths disagree for the same projection version;
- a summary claims evidence outside its eligible canonical set;
- a projection rebuild is non-idempotent.

### Compatibility and anomaly signals

The collector also records and surfaces:

- unknown record families or content-block kinds;
- a provider/source version newer than the validated compatibility range;
- unresolved records and their proportion of a collection batch;
- unusual source-records-per-logical-turn ratios;
- sudden replay/alias or provider-failure bursts;
- sessions with unexplained large inherited sequence overlap;
- project attribution falling back to session-wide or unknown context;
- repeated diagnostic incidents with no attached work turn;
- summaries made stale by a classification-version change.

Volume alone never proves corruption. Thresholds create a diagnostic signal;
structural invariants and provenance determine whether evidence is work.

### User-visible behavior

`trackify doctor` reports separate states:

```text
Storage       healthy
Collection    healthy
Evidence      degraded: 2 unresolved Claude record families
Summaries     stale: rebuild required
```

The app shows an unobtrusive amber source/evidence-quality badge only when
current visible statistics may be incomplete. Details live in Settings >
Sources and the CLI. A degraded classifier never masquerades as a healthy zero.

## 11. Clean rebuild and backfill strategy

Goal 4 uses a shadow rebuild rather than an in-place repair of incorrect
evidence.

### 11.1 Rebuild inputs

For the requested seven-day coverage interval, the rebuild reads only relevant
candidates from:

- configured Git discovery roots;
- reachable Git commits inside the interval plus the current working-tree state;
- Codex active and archived session caches;
- Claude Code terminal history;
- Claude Desktop local-agent audit history;
- explicitly supported normalized hook inbox records, if retained.

The existing evidence tables, aliases, rollups, search documents, summaries,
and reports are not used as source truth. Candidate filtering is an optimization;
the parser's event-time check remains the authoritative inclusion boundary.

### 11.2 User-owned state

Before replacement, Trackify exports and validates only user-owned state that
is not reconstructable evidence:

- discovery roots and exclusions;
- app preferences;
- report templates/recipes;
- explicitly user-created reporters/schedules;
- destination configuration without secret material.

Seeded defaults may be recreated from code. Provider readiness, collection
cursors, summaries, usage derived from discarded runs, cached search data, and
old activity rollups are not copied.

For the first development rollout, replacing the disposable derived ledger is
acceptable. The production command still preserves user-owned configuration by
default so future users do not need to make the same tradeoff.

### 11.3 Shadow validation and replacement

The rebuild sequence is:

1. Pause scheduling while leaving source caches untouched.
2. Create a new private ledger beside the active ledger.
3. Import user-owned configuration through a versioned export contract.
4. Capture the rebuild cutoff and stream only candidates that can overlap the
   seven-day coverage interval through the new adapters.
5. Build canonical turns/messages and the work-evidence projection.
6. Run hard semantic invariants, privacy checks, SQLite integrity, and
   deterministic metric reconciliation.
7. Generate local-only summaries and search documents for the seven-day window.
8. Compare a structural audit report, not the old incorrect totals.
9. Atomically activate the new ledger only after every required check passes.
10. Move the discarded development ledger to Trash or remove it according to
    the explicit rebuild option. Never delete provider caches.
11. Run one immediate incremental pass, then resume ordinary forward collection.

Failure before activation leaves the active ledger unchanged and the failed
shadow ledger inspectable through bounded diagnostics.

### 11.4 Rebuild command

The CLI should expose one application use case rather than a collection of
repair scripts:

```text
trackify data rebuild --from-sources --days 7 --verify
trackify data rebuild --from-sources --days 7 --verify --replace
```

Seven days is the product default and the Goal 4 acceptance value. The command
prints the exact start, cutoff, source read measurements, semantic audit, and
projected replacement action before activation. `--replace` activates the
shadow only after validation. A test-only fixed clock and isolated data root
exercise the identical application use case.

The bounded interval is part of the application-use-case input, audit record,
and resulting ledger coverage metadata. It is not a CLI-only filtering trick.
The app, CLI, and doctor output can therefore state exactly how far the active
ledger has been reconstructed.

### 11.5 Scope guardrails

The rebuild must stop rather than silently broaden its work when:

- a source cannot prove that accepted records lie inside the requested interval;
- a provider format requires an unbounded scan to answer the bounded request;
- activation would leave the ledger without explicit coverage metadata;
- required validation fails; or
- disk, memory, or runtime behavior is unsafe during the seven-day run.

The failure report identifies the affected source and keeps the shadow ledger
inspectable. It does not trigger an all-history repair, explore unrelated legacy
anomaly windows, or modify provider caches.

## 12. Application architecture

Goal 4 introduces one shared application boundary, conceptually:

```text
CanonicalWorkEvidenceService
  - activity(range, scope)
  - timeline(range, scope, diagnosticsPolicy)
  - messages(range, scope)
  - context(range, scope, budget)
  - summaryEvidence(range, scope)
  - quality(range, source)
```

The service owns projection-version checks, canonical ID resolution,
classification policy, repository association, and reachable-commit filtering.
Presentation code, report compilers, and CLI formatters receive domain results;
they do not join raw tables or count roles themselves.

Provider adapters depend only on source compatibility contracts. They do not
know about charts or report prompts. The canonicalizer and classifier depend on
normalized observations, not raw JSON. Persistence stores facts and mappings;
it does not embed UI policy.

## 13. Implementation sequence

### Phase 1 — contain new contamination

1. Make executable discovery pure and remove automatic Claude `auth status`
   execution.
2. Represent authentication from explicit successful/failed invocations.
3. Register and structurally exclude every Trackify provider invocation.
4. Add regression tests proving discovery and status refresh create no files,
   sessions, tokens, or provider processes.

Exit condition: leaving Trackify open cannot manufacture conversation history.

### Phase 2 — establish the normalized observation contract

1. Add provider-neutral observation, identity, lineage, and parse-status domain
   types.
2. Add the new storage schema and adapter/classifier version fields.
3. Rewrite Codex, Claude Code, and Claude Desktop adapters to retain required
   provenance.
4. Keep unknown fields forward-compatible and quarantine unknown record
   families structurally.
5. Update sanitized compatibility fixtures and privacy validation.

Exit condition: every supported fixture can explain origin, logical identity,
turn association, and repository context without inspecting text heuristically.

### Phase 3 — canonical conversation graph and classifier

1. Build deterministic logical turn/message resolution.
2. Add replay, alias, parent/fork, dual-family, and source-reobservation
   mappings with reasons.
3. Add origin, semantic-kind, disposition, confidence, and incident
   classification.
4. Resolve repository association per turn/message.
5. Add idempotence and contradiction invariants.

Exit condition: known replay, hook, tool-traffic, provider-failure, and genuine
parallel-work fixtures produce correct canonical graphs.

### Phase 4 — one canonical query boundary

1. Implement `CanonicalWorkEvidenceService`.
2. Move Activity and Overview metrics to it.
3. Move repository/portfolio context and timeline to it.
4. Rebuild search from canonical work content.
5. Move summary coverage and report evidence compilation to it.
6. Remove direct raw-event role counting and duplicated visibility filters.

Exit condition: every consumer returns the same counts and eligible IDs for an
identical range/scope.

### Phase 5 — semantic health and observability

1. Persist source compatibility and projection health.
2. Extend doctor/status JSON and human output.
3. Add bounded diagnostic incidents and anomaly thresholds.
4. Add Settings > Sources evidence-quality details and a restrained degraded
   state in the main/menu UI.
5. Ensure health checks never expose private message text.

Exit condition: every intentionally injected corruption/schema-drift fixture is
detected before it can appear as healthy work statistics.

### Phase 6 — clean bounded rebuild

1. Implement shadow-ledger rebuild and user-state export/import.
2. Make the seven-day coverage interval an explicit shared use-case input.
3. Filter source candidates structurally, enforce event-time bounds while
   parsing, and record per-source read measurements.
4. Run semantic, privacy, integrity, and cross-query validation.
5. Inspect anomalies found inside the requested interval through bounded
   structural diagnostics.
6. Activate the new ledger and rebuild local summaries/search.
7. Run an incremental collection pass and prove it adds no duplicate logical
   work.

Exit condition: the active app and CLI use only the validated rebuilt ledger.

### Phase 7 — product and release validation

1. Validate Overview day/7-day/30-day charts and hover values against CLI JSON.
2. Validate Activity role/origin styling and diagnostic filtering.
3. Validate parallel projects, forks, repository changes, quiet periods, and
   unfinished work.
4. Run deterministic two-day simulation and the production seven-day backfill.
5. Run full tests, formatting, fixture privacy audit, package/bundle validation,
   and a live installed-app smoke test.

Exit condition: Goal 4 acceptance criteria pass against synthetic fixtures and
the freshly rebuilt seven-day local ledger, and continuous collection advances
that ledger without duplication.

## 14. Required validation corpus

Sanitized fixtures must include:

1. One human prompt and a normal assistant response.
2. Two legitimate identical prompts in distinct turns.
3. One prompt producing hundreds of user-role tool/meta records.
4. Stop-hook feedback repeated until provider quota failure.
5. API/authentication failure before any work turn.
6. User and provider interruptions.
7. Task/subagent notification records.
8. A Codex record exposed through both `event_msg` and `response_item`.
9. A parent session copied into one and several child forks.
10. New unique work in parallel children.
11. A transcript replay after truncation, replacement, and incremental cursor
    recovery.
12. A session changing repositories between turns.
13. Claude terminal and Desktop records with equivalent logical semantics.
14. A provider schema containing unknown record/content types.
15. A Trackify internal summary/report invocation that violates persistence
    expectations.
16. Missing source identifiers with both safely resolvable and ambiguous cases.
17. Late/out-of-order lifecycle records.
18. A genuine high-volume session that must not be treated as corruption merely
    because it is large.

Property and integration tests must prove:

- raw normalized observation counts are stable after repeated import;
- logical counts are stable after replay and fork inheritance;
- ambiguity remains visible;
- privacy filtering happens before persistence/indexing;
- classification and canonicalization are deterministic and versioned;
- rebuilding the same bounded interval twice produces identical canonical IDs,
  statistics, coverage, and health;
- all query surfaces agree;
- summaries cover every and only eligible canonical work item;
- no provider process runs during migration, discovery, or local-only rebuild.

## 15. Acceptance criteria

Goal 4 is complete only when:

1. Provider discovery and passive status refresh are proven side-effect-free.
2. Codex, Claude Code, and Claude Desktop adapters retain the provenance needed
   to distinguish intent, agent work, tools, hooks, failures, and replay.
3. A user role alone is nowhere used as the definition of a work turn.
4. No production query counts raw message events directly.
5. Forked/restored history is canonicalized without losing unique child work.
6. Repeated genuine prompts remain distinct.
7. Unknown semantics are quarantined and visibly degrade evidence health.
8. Repository attribution is temporal and per-turn/message.
9. Overview, Activity, project context, search, summaries, reports, and CLI use
   the shared canonical service.
10. Known diagnostic/control loops create no work turns or evidence hours.
11. Attached failures remain available as honest blockers/terminal state.
12. Semantic doctor checks detect every required injected anomaly.
13. A shadow rebuild can reconstruct and verify the explicit seven-day coverage
    interval before activation without scanning unrelated history.
14. The current development evidence ledger is replaced by that clean bounded
    backfill, with provider caches untouched, coverage recorded, and user-owned
    configuration handled explicitly.
15. A second independent rebuild of the same interval produces identical
    logical history; the post-activation incremental pass adds no duplicate
    canonical work.
16. Corrected local summaries and search indexes are rebuilt from the new
    projection.
17. Fixed-clock simulation, privacy audit, automated tests, native UI capture,
    packaged bundle, and live-app smoke tests pass.
18. CLI and app queries for the rebuilt week agree on day/range totals, projects,
    canonical conversation activity, search results, summaries, and evidence
    health.
19. Doctor and rebuild audit output disclose the active coverage interval and
    bounded per-source read measurements.
20. The scheduler is resumed and a new in-range source event becomes visible
    through the ordinary collection path without another rebuild.

### 15.1 Completion evidence

Goal 4 is not complete because the schema compiles, a synthetic fixture passes,
or one shadow database was created. Completion requires one retained validation
record containing:

- the exact seven-day start and captured cutoff;
- source candidate/read/accept measurements and boundedness assertions;
- both independent rebuild fingerprints and the incremental-pass delta;
- SQLite, semantic-health, privacy, and cross-surface reconciliation results;
- CLI output for doctor, day/range, activity, projects, search, summaries, and
  agent context;
- native Overview, Activity, Projects, and summary/menu verification against the
  same ledger;
- confirmation that user configuration survived, source caches were untouched,
  scheduling resumed, and newly arriving evidence appeared; and
- the full automated/build/package validation results.

The work followed the phase order above until every acceptance criterion had
that evidence. Any future regression should narrow the next task to the failing
criterion; it must not reopen older history or introduce a parallel repair
architecture.

The retained completion evidence is recorded in
[`VALIDATION.md`](VALIDATION.md#goal-4-completion-record--2026-08-07). It includes
the exact interval, source read volumes, matching independent canonical and
normalized-evidence fingerprints, semantic audit, incremental collection delta,
CLI/UI/package checks, preserved user configuration, resumed scheduler, and the
installed build identity.

## 16. Explicit non-goals

Goal 4 does not:

- infer human attention or elapsed work duration from record gaps;
- use an LLM to decide whether raw evidence counts as work;
- delete or rewrite Codex or Claude source caches;
- retain raw secrets, reasoning, tool payloads, or environment dumps;
- globally deduplicate messages by text;
- suppress legitimate high-volume or parallel agent work because it looks
  unusual;
- add cloud telemetry or upload evidence-quality diagnostics;
- preserve incorrect derived history merely to keep current chart totals stable;
- automatically spend provider tokens regenerating all historical summaries.
- exhaustively import, audit, or repair source history older than the seven-day
  completion window;
- make optional all-history migration performance a release gate;
- chase legacy anomalies outside the configured coverage interval.

The durable promise is simple: Trackify records what it can prove, labels what
it cannot yet interpret, derives work through one inspectable versioned model,
and notices immediately when a source stops satisfying that model.
