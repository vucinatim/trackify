# Trackify Goal 5: Live Evidence and Responsive UI

Status: Implemented and locally validated
Last updated: 2026-08-11

Completion hardening also covers process lifecycle: CLI interruption and app shutdown terminate only Trackify-owned provider children, and exact lease ownership lets the terminating process immediately mark its interrupted runs terminal. Bounded summary catch-up prioritizes the newest eligible half-hour so recovery cannot starve current work behind old gaps.

Goal 5 makes Trackify feel continuously current without changing what counts as
work. Supported Git, Codex, and Claude evidence should move the visible current
hour, counters, project list, and Activity ledger within a few seconds of being
durably written on the machine.

The goal is not a keystroke logger, foreground-app timer, or synthetic activity
clock. Trackify remains an evidence ledger. It becomes responsive by collecting
new durable evidence when macOS reports a relevant filesystem change, then
refreshing presentation from the canonical ledger immediately after a successful
mutation.

Filesystem notifications are hints, not evidence. Durable source caches, Git,
source cursors, and the canonical ledger remain authoritative. A periodic full
reconciliation stays in place so dropped, coalesced, permission-delayed, or
sleep-time notifications can never create a permanent gap.

## 1. Outcome

After Goal 5:

1. A newly persisted Codex or Claude work message normally appears in Trackify
   within five seconds.
2. A Git commit or meaningful working-tree transition normally updates the
   current-hour chart and statistics within five seconds.
3. Overview, Activity, Projects, and the menu-bar dropdown refresh from one
   ledger-mutation signal instead of independently waiting for arbitrary polls.
4. The current-time chart marker advances on the clock even when no evidence is
   written; evidence bars advance only when real evidence arrives.
5. Event storms are debounced and coalesced by source and repository. One save
   operation cannot cause several full collections.
6. Trackify never rescans every repository or rereads complete conversation
   histories merely because one path changed.
7. Sleep, wake, notification overflow, atomic file replacement, truncation,
   repository moves, and app restart converge through bounded reconciliation.
8. Automatic summaries and user-configured reports remain separately paced and
   budgeted. Live statistics do not imply one model call per event.
9. The CLI reports live-collector health, pending dirty scopes, last trigger,
   convergence latency, and last successful reconciliation without introducing
   a second control service.
10. Idle resource use remains appropriate for an always-running menu-bar app on
    a machine with more than 100 repositories and large provider caches.

## 2. Definition of “live”

Goal 5 targets human-perceived responsiveness, not hard realtime guarantees.

| Signal | Normal target | Recovery target |
|---|---:|---:|
| Codex/Claude cache append | ledger within 5 s | next reconciliation |
| Git commit/ref/index change | ledger within 5 s | next reconciliation |
| Working-tree transition | ledger within 10 s | next reconciliation |
| Ledger mutation to visible UI | within 1 s | next 30 s fallback refresh |
| Current-time chart marker | every minute | next UI clock tick |
| Wake from sleep | converged within 30 s | next reconciliation |
| Notification overflow/drop | bounded reconciliation immediately | periodic reconciliation |

Targets are measured from the source's durable local write time. Trackify cannot
display a provider message before that provider flushes it to a supported cache.
UI animation is never included in the evidence timestamp.

The periodic full reconciliation remains 30 minutes by default. It is a repair
path, not the normal latency path.

## 3. Product behavior

### 3.1 What updates immediately

After an accepted evidence batch, Trackify refreshes:

- current-hour and selected-range chart buckets;
- evidence, turn, commit, file, line, and repository statistics;
- active project names and repository state;
- the latest-evidence time and status badge;
- matching Activity timeline entries;
- the selected project's visible details; and
- CLI queries, because they read the same committed ledger.

The menu may briefly show `Recording` while a small incremental batch is being
committed and `Syncing` during a larger recovery pass. `Up to date` means no
known dirty scope remains; it does not claim that an external provider has
already flushed every in-memory event.

### 3.2 What remains paced

Live collection must not turn semantic generation into a noisy stream.

- Canonical 30-minute segment summaries retain their evidence-fingerprint
  identity and provider budget.
- New evidence marks the relevant summary ancestry stale immediately.
- Deterministic current facts may refresh without a provider call.
- Codex/Claude generation happens only at the established closed-period or
  explicit recovery boundary.
- Reports keep their manual or configured schedule.

The UI can show that a summary is stale or regenerating while continuing to
display the previous successful revision. Charts and facts never wait for an
LLM.

### 3.3 What Trackify still does not infer

Trackify does not:

- increment an activity timer just because the computer is awake;
- equate keyboard, mouse, editor focus, CPU usage, or foreground application
  time with development work;
- treat a filesystem notification as a work event;
- invent completion because a working tree became quiet;
- count temporary file churn as multiple meaningful work transitions; or
- claim sub-second latency when the source cache itself is delayed.

## 4. Current baseline and reason for change

The app currently rereads the ledger every 30 seconds, but ordinary source
collection is primarily a 30-minute reconciliation. A fast presentation poll
therefore often sees an unchanged ledger. Optional lifecycle hooks can improve
specific cases, but they are not a general source-notification architecture.

The existing foundations are suitable for Goal 5:

- source adapters already use durable incremental cursors;
- collection is idempotent and persists before advancing a cursor;
- the app is the sole continuous scheduler;
- the CLI and GUI already share collection and query use cases;
- normalized evidence and derived projections have explicit boundaries; and
- a collection lease already prevents concurrent mutation races.

Goal 5 changes when those use cases are invoked and how their successful
mutations invalidate presentation. It does not add a second ingestion path.

## 5. Architecture

```text
macOS FSEvents / optional hook / wake / periodic timer
                         |
                         v
                  ChangeMonitor adapters
                         |
                         v
             coalesced DirtyScope queue (actor)
                         |
                         v
              LiveCollectionCoordinator
                         |
             existing incremental collectors
                         |
                         v
              canonical SQLite transaction
                         |
                         v
                 LedgerMutation signal
                         |
                         v
             shared AppModel snapshot refresh

Periodic reconciliation --------------------^  recovery authority
```

### 5.1 New application boundary

Introduce one `LiveCollectionCoordinator` owned by `Trackify.app`. It is an
application scheduler, not a source parser and not a second collector.

Its dependencies are small protocols with production and deterministic test
implementations:

```text
ChangeMonitor
  start(handler)
  stop()

CollectionTrigger
  source family
  affected paths
  observed time
  reason: filesystem | hook | wake | manual | reconciliation
  mustReconcile: Bool

DirtyScope
  conversation source IDs
  repository IDs or unresolved root paths
  hook inbox
  discovery roots

LedgerMutation
  committed time
  changed evidence range
  affected repositories
  changed event families
```

The coordinator is an actor and owns all in-memory trigger, debounce,
backpressure, and cancellation state. Business logic remains in the existing
source adapters, collection coordinator, ledger store, and query services.

### 5.2 Trigger semantics

Triggers are lossy scheduling hints. They may be merged or discarded after a
broader trigger supersedes them. They are never written as evidence and do not
advance source cursors.

Priority order:

1. explicit manual collection;
2. provider cache or hook-inbox change;
3. Git commit/ref/index change;
4. ordinary working-tree change;
5. discovery-root structural change;
6. periodic reconciliation.

A higher-priority trigger may absorb compatible lower-priority triggers. A
running collection is never launched concurrently with another collection.
New triggers arriving during a run form the next coalesced batch.

## 6. Source monitors

### 6.1 Codex and Claude

Use macOS FSEvents at each supported provider history root. The monitor records
only path identity, flags, and observation time. It does not parse content.

When a known session file changes:

1. map it to the existing source adapter;
2. debounce rapid append bursts for roughly one second;
3. invoke the adapter with its durable cursor and ordinary bounds;
4. leave incomplete JSONL tails for the next notification; and
5. commit accepted normalized observations before publishing a mutation.

Atomic replacement, file rotation, inode changes, and truncation reuse the
existing cursor recovery rules. Unknown paths inside a known source root trigger
bounded candidate discovery, not a scan of the full cache corpus.

The optional hook inbox remains a low-latency supplement. Hook and durable-cache
observations reconcile through canonical identity and cannot double-count.

### 6.2 Git and working trees

Use one recursive FSEvents stream per configured discovery root, not one watcher
per repository or file. Resolve changed paths against the persisted repository
catalog.

For a known repository:

- `.git/HEAD`, refs, index, and packed-ref changes schedule Git inspection;
- ordinary worktree changes schedule a debounced status/diff-stat inspection;
- dependency, build, generated, and excluded trees are filtered before work is
  queued where safe;
- many changed paths in one repository collapse to one repository scope; and
- changes across repositories remain independently attributable.

Unresolved structural paths schedule bounded discovery under the affected root.
A new repository can therefore appear without rescanning unrelated roots.

Working-tree inspection remains transition-based. Repeated notifications that
produce the same canonical state create no evidence event.

### 6.3 Ledger changes outside the app scheduler

The app remains the continuous owner, but CLI backfill, simulation activation,
or an explicit CLI collection may mutate the same ledger. Goal 5 adds a tiny
cross-process invalidation hint after a successful transaction, using a local
Darwin notification or equivalent one-way macOS notification.

The notification carries no evidence content and grants no control authority.
If it is lost, the app's lightweight fallback refresh observes the committed
ledger. Goal 5 does not add an HTTP server, daemon, socket protocol, or
always-listening agent endpoint.

## 7. Debounce, coalescing, and backpressure

Suggested initial policy:

| Trigger family | Debounce | Maximum delay |
|---|---:|---:|
| Provider append / hook | 1 s | 3 s |
| Git metadata | 1 s | 3 s |
| Working tree | 2 s | 8 s |
| Root discovery | 5 s | 15 s |
| UI ledger invalidation | 100 ms | 1 s |

Policies are injected values, not scattered sleeps.

The coordinator must:

- keep at most one collection transaction active;
- merge duplicate source and repository scopes;
- cap one batch and carry excess dirty scopes into the next batch;
- apply a short retry backoff after operational failure;
- escalate repeated or overflow events to reconciliation;
- preserve manual collection responsiveness;
- never hold the collection lease while waiting for an LLM; and
- expose pending and delayed scope counts through diagnostics.

No durable trigger queue is required. The durable cursor plus periodic
reconciliation is simpler and more reliable than persisting filesystem hints.

## 8. UI update model

### 8.1 One invalidation path

After a committed `LedgerMutation`, AppModel refreshes one consistent snapshot
for the visible range. Views do not query SQLite independently and do not each
run their own timer.

Queries remain complete and bounded:

- today/current-range statistics use existing batched snapshots;
- only visible timeline and project details are reloaded;
- historical calendar ranges are invalidated only when their dates overlap the
  mutation; and
- a full snapshot remains available after recovery or uncertain scope.

Start with correct whole-snapshot refreshes behind one invalidation boundary.
Introduce finer persisted rollups only if profiling proves the bounded queries,
not collection, are the actual bottleneck.

### 8.2 Presentation behavior

- Numeric changes animate briefly without moving the surrounding layout.
- The current-hour bar updates in place.
- A new timeline row appears without changing the user's scroll position.
- The current-time marker advances independently once per minute.
- `Recording` reflects queued or committing incremental evidence.
- `Syncing` reflects reconciliation or a large carried batch.
- `Up to date` returns only after the dirty queue drains.
- Historical views do not jump back to Today when current evidence changes.

The 30-second fallback refresh is a bounded ledger observation, not source
collection. Ordinary updates use the post-transaction mutation path and do not
wait for this fallback.

## 9. Time, ordering, and correctness

Every record keeps separate source occurrence and Trackify observation times.
Live arrival does not rewrite history to “now.” Late provider flushes and late
Git discovery are inserted at their source time, and all affected derived ranges
are invalidated.

Ordering rules:

- source identity and canonicalization still determine deduplication;
- two notifications for one source record remain one observation;
- a late event may revise an earlier chart bucket and summary fingerprint;
- notification order cannot change canonical identity;
- wall-clock changes and time-zone changes do not corrupt half-open intervals;
  and
- injected clocks and schedulers control every debounce and validation test.

## 10. Lifecycle and recovery

### Sleep and wake

Before sleep, stop monitors cleanly and preserve only durable cursors. On wake:

1. restart monitors;
2. schedule a bounded forward reconciliation from each cursor;
3. refresh the current UI snapshot; and
4. resume ordinary event-driven collection.

### Notification overflow or root replacement

FSEvents overflow, dropped-history flags, root moves, permission changes, or an
unresolvable path mark that root uncertain. Trackify schedules bounded
reconciliation and reports degraded monitor health until it converges.

### App crash or force quit

No filesystem hint is required for recovery. The next launch starts monitors,
runs ordinary forward reconciliation from durable cursors, and then returns to
event-driven operation.

### Source incompatibility

A future provider record remains unresolved under the Goal 4 evidence contract.
Live scheduling must never weaken compatibility quarantine merely to make the
UI move.

## 11. Performance and privacy budgets

Initial acceptance budgets on the reference machine:

- under 1% average CPU while idle over a 30-minute sample;
- no sustained wakeups caused by unchanged repositories or caches;
- no complete provider-cache reread during an ordinary append;
- no full-root Git scan for a change mapped to a known repository;
- at most one source collection and one model invocation owner at a time;
- bounded monitor memory independent of event-storm size; and
- no new raw content, credentials, arbitrary paths, or provider payloads in
  diagnostics.

Paths shown in exported diagnostics continue through existing redaction. Monitor
telemetry records counts, source families, durations, and failure classes—not
file content.

## 12. CLI and diagnostics

Extend existing status surfaces rather than introducing a second API.

`trackify collection status --json` includes:

- mode: `up-to-date`, `pending`, `collecting`, `degraded`, or `stopped`;
- current pending trigger and path counts;
- last trigger and incremental collection start/finish;
- last ledger mutation;
- ordinary live source-to-ledger latency percentiles;
- last full reconciliation; and
- a content-free operational failure description and consecutive-failure count.

Per-root monitor counters and recovery counts remain derivable test diagnostics,
not persisted production telemetry. This keeps the live status row bounded and
prevents arbitrary watched paths from entering exports.

`trackify doctor` verifies monitor configuration, path accessibility, stale
cursors, repeated failures, reconciliation freshness, and mutation convergence.
Agents continue to query work through `today`, `timeline`, `search`, `context`,
and summaries; no new agent-only ledger is created.

## 13. Implementation sequence

### Phase 1 — Instrument and isolate scheduling

- Extract the current 30-second UI refresh and 30-minute collection timing into
  injected scheduler policy.
- Add collection-trigger and mutation result types.
- Measure current source-to-ledger and ledger-to-UI latency.
- Keep behavior unchanged while establishing deterministic tests.

Exit: all current collection paths go through one scheduler boundary.

### Phase 2 — Conversation and hook responsiveness

- Add FSEvents monitors for supported Codex and Claude roots.
- Route changed files through existing bounded incremental adapters.
- Coalesce hook/cache observations and incomplete JSONL tails.
- Publish ledger mutation after commit.

Exit: a sanitized appended fixture reaches the visible ledger within the target
without a full source scan.

### Phase 3 — Git responsiveness

- Add root-level FSEvents monitoring and repository resolution.
- Separate Git metadata, worktree, and discovery triggers.
- Debounce editor/build churn into canonical working-tree transitions.
- Preserve excluded-tree and 100+ repository scale behavior.

Exit: commits and meaningful dirty/clean transitions update within target while
unchanged churn produces no evidence.

### Phase 4 — Reactive presentation

- Publish one post-transaction `LedgerMutation` stream.
- Refresh AppModel from mutations and a small fallback observation timer.
- Add stable `Recording`, `Syncing`, `Up to date`, and degraded states.
- Update charts, counters, projects, and Activity without resetting selection or
  scroll position.

Exit: every visible live surface converges from the same mutation.

### Phase 5 — Lifecycle, diagnostics, and hardening

- Implement sleep/wake restart and immediate forward reconciliation.
- Handle FSEvents overflow, permission loss, root replacement, and app restart.
- Add status/doctor telemetry and latency measurements.
- Run energy, cache-size, event-storm, and 100+ repository validation.

Exit: event loss and lifecycle changes recover without manual action or metric
corruption.

## 14. Validation plan

All time and monitor behavior uses injected clocks, schedulers, and synthetic
change streams. Tests do not wait for wall-clock debounce intervals.

Required automated coverage:

1. one cache append creates one canonical event and one UI mutation;
2. 1,000 notifications for one file coalesce into one bounded collection;
3. an incomplete JSONL tail is accepted after the next append;
4. atomic replacement and truncation resume from the correct cursor;
5. hook and cache copies remain one logical work turn;
6. known-repository changes inspect only that repository;
7. excluded dependency/build churn schedules no work where filtering is safe;
8. repeated identical Git state creates no extra evidence;
9. changes in parallel repositories remain independently attributed;
10. a new repository under a watched root is discovered without a full-machine
    scan;
11. triggers arriving during collection form exactly one following batch;
12. collection failure backs off without losing later reconciliation;
13. sleep/wake catches up events written while the app was suspended;
14. overflow forces bounded reconciliation and clears degraded state afterward;
15. late evidence updates the correct historical bucket, not the observation
    time bucket;
16. UI invalidation preserves selected date, range, metric, project, and scroll
    state;
17. live evidence causes no automatic provider call before the summary boundary;
18. simulation can advance hours/days instantly with deterministic trigger
    delivery; and
19. CLI and GUI read identical totals after every mutation.

Production validation uses sanitized fixtures and ordinary local development
activity. It does not recreate the full screenshot matrix for every scheduler
change. Targeted UI cases plus ledger/CLI assertions validate live movement;
the complete visual matrix remains a release/refactor check.

## 15. Acceptance criteria

Goal 5 is complete when:

- normal Codex/Claude and Git evidence meets the latency table in at least 95%
  of measured local events;
- the UI is never more than five seconds behind a committed ledger mutation
  during ordinary operation;
- notification storms remain bounded and do not multiply evidence;
- a deliberately dropped notification is repaired by reconciliation;
- sleep/wake and app restart converge without user action;
- idle CPU and wakeup budgets pass on the reference machine;
- 100+ repositories and large real provider caches do not trigger broad rescans
  for ordinary changes;
- no live trigger starts a summary/report provider outside its existing policy;
- status and doctor explain degraded monitor state and last convergence;
- automated virtual-time, privacy, migration, collection, UI model, and CLI
  suites pass; and
- an installed universal development bundle runs continuously for a bounded
  soak without stale charts, duplicate activity, or runaway CPU/IO.

## 16. Explicit non-goals

Goal 5 does not add:

- a daemon separate from `Trackify.app`;
- a cloud service, telemetry SDK, or remote event stream;
- editor plugins or keystroke/mouse monitoring;
- per-repository watcher processes;
- an always-listening HTTP/socket control API;
- provider-cache scraping beyond supported local source adapters;
- model generation after every message or file save;
- a synthetic productivity timer; or
- persisted trigger/event-notification history as a second ledger.

Those boundaries keep the implementation small: notifications decide when to
run existing authoritative work; they never decide what the work means.

## 17. Implementation and validation record

Goal 5 is delivered through one app-owned `LiveCollectionCoordinator`, recursive
FSEvents monitors, targeted conversation and Git collection plans, durable
cursors, a local cross-process ledger-mutation notification, and one AppModel
presentation invalidation boundary. Application startup is owned by the macOS
application delegate, so collection does not depend on opening the menu or main
window.

The production path was validated against the local ledger containing 102
repositories and large Codex and Claude cache catalogs. Important measured and
proven outcomes:

- an installed launch creates live status without opening any UI;
- ordinary live convergence measured about 1.25 seconds after removing global
  maintenance from incremental batches;
- event storms remain capped and coalesced, and triggers arriving during a run
  form exactly one following batch;
- one known repository change opens only that repository;
- one provider append opens only the affected JSONL file while retaining every
  unrelated durable cursor;
- recovery remains scoped to the affected source family;
- SQLite/WAL changes are ignored by FSEvents, preventing a status-write feedback
  loop;
- observational Git commands disable optional index writes, preventing Git from
  manufacturing its own worktree notifications;
- recursive FSEvents avoid `WatchRoot` root opens; periodic reconciliation owns
  root-replacement recovery without inducing repeated macOS folder prompts;
- startup cache recovery and up to 16 recently active repositories are paced;
  the 30-minute full reconciliation remains authoritative for all roots;
- incremental batches update diagnostics only for touched sources; global
  evidence-quality repair remains in full reconciliation;
- repeated repository observations no longer rerun global session association
  or repository search indexing unless the mapping or indexed metadata changed;
- the hidden menu-bar app measured roughly 93–180 MB physical footprint during
  live validation; larger `ps` RSS values primarily represented shared macOS
  framework pages and allocator reserve; and
- live collection never invokes a summary or report provider. Model generation
  remains behind the existing summary/report scheduler and budget policy.

The final installed bounded sample recorded a 2.70-second median and
3.56-second p95 ordinary convergence, followed by a five-second stable interval
with no measurable process CPU at `ps` centisecond resolution. CLI pause/resume
also converged in the running app; notification delivery is backed by the
watched settings file and the periodic reconciliation read so launch timing
cannot leave the runtime out of sync.

Automated validation covers virtual-time coalescing, scoped planning, targeted
source reads, real recursive FSEvents delivery, migrations, privacy, CLI status,
store round-trips, application state, and the existing evidence/report suites.
The fixture privacy guard and installed-bundle diagnostics remain required before
release commits.
