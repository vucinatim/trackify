# Trackify Validation Record

Last updated: 2026-08-11

This document records reproducible V1 through Goal 5 checks separately from product design. It does not treat a locally built archive as a published release or live update test.

## Completion hardening record — 2026-08-11

- All 152 tests in 10 suites pass; strict formatting, fixture privacy, shell syntax, workflow YAML, Git whitespace, release build, and the schema-v2 two-day simulation pass. The preceding 149-test integration commit also passed with code coverage enabled in CI.
- Summary v5 uses semantic message origin/kind rather than display role, so human/delegated intent remains prominent while provider notifications and agent progress cannot be mislabeled as user requests. A 12-hour pacing regression proves each refresh upgrades at most one newest half-hour leaf, live current/day composition uses no provider call, and the closed day receives exactly one provider synthesis only after all leaves are upgraded.
- Default safeguards are 48 calls/day, 2 million tokens/day, 30 million tokens/month, and 3% of the observed weekly Codex allowance. Existing default settings migrate forward while explicit user values remain unchanged.
- Ctrl-C/SIGTERM and app shutdown now terminate only Trackify-owned provider children. An actual CLI/provider signal drill exited 130 with no orphan, no surviving lease, and an immediate explicit cancelled terminal record. Catch-up spends allowance on at most one newest eligible half-hour per refresh, then rebuilds visible parents locally without waiting behind old gaps.
- The exact Universal 2 direct-release path passed for app, CLI, and every nested Sparkle component: hardened-runtime ad-hoc signing, deep validation, identifiers, architectures, version/origin, Ed25519 archive signing and verification, and generated appcast. The permanent public key is pinned in source and both release secrets are configured in the protected GitHub environment.
- CI now requests a Swift 6 runner and validates the current simulation schema instead of the obsolete schema-v1 field set.

## Goal 4 completion protocol

Goal 4 validation is deliberately bounded to today plus the preceding six local
calendar days. Exhaustive Codex or Claude cache import is not a completion gate.
The production validation must use the same application use case as the shipped
app and CLI:

```bash
trackify data rebuild --from-sources --days 7 --verify --json
trackify data rebuild --from-sources --days 7 --verify --replace --json
trackify doctor --json
```

The retained audit must record the exact half-open coverage interval, per-source
files considered/opened, bytes read, records observed/accepted, semantic health,
and a deterministic ledger fingerprint. A second isolated rebuild of that same
interval must match the fingerprint. The immediate incremental pass must add no
duplicates, while a subsequently arriving source event must appear through
ordinary continuous collection.

CLI day/range, Activity, Projects, search, summaries, reports, and agent-context
results must reconcile with the native Overview, Activity, Projects, and menu
surfaces for the activated ledger. The fixture privacy audit, complete automated
suite, deterministic simulation, UI capture matrix, packaged bundle validation,
and installed-app smoke test remain required. Results belong in this document
only after the corresponding command has actually passed.

### Goal 4 completion record — 2026-08-07

The production rebuild and an independent guarded dry rebuild both reconstructed
the exact half-open interval
`2026-07-31T22:00:00Z..<2026-08-07T15:52:05Z`. Both produced 267 canonical
work turns, 2,051 canonical work messages, 566 diagnostic records, 37,028
control records, zero unresolved records, and healthy semantic and SQLite
audits. Their fingerprints matched exactly:

- canonical work: `dd29c8808105d0f4679e5f11aa495ac338d9f89a42a261c3a214a2e8c56598d3`;
- normalized evidence: `cbab6a71f9baf654ba539b9f33a96d9b472612a4fd470931c7901de636b02679`.

The bounded read audit recorded:

- Codex current history: 7/7 files opened, 1,160,206,392 bytes, 145,972
  records observed, and 50,303 accepted; 425 other current-history files and 13
  archive files were seeded by metadata without opening their contents;
- Claude Code history: 310/310 candidate files opened, 457,640,825 bytes,
  91,248 records observed, and 5,464 accepted; 1,174 other files were seeded by
  metadata without opening their contents;
- Claude Desktop Code history: no file overlapped the interval; two known files
  were seeded by metadata without being opened;
- Git: 60 Personal and 42 Work repositories inspected, producing 170 and 328
  accepted observations respectively.

Both rebuilds reported that a second collection pass changed no canonical
history. The activated ledger received a bounded current-day catch-up, after
which its immediate forward pass added no duplicate event. A later installed-CLI
pass observed a newly appended Codex source event and advanced the ledger from
3,307 to 3,308 events through ordinary collection. Passive collection was then
resumed.

The compatibility audit also found three Claude compacted-context records in
the window. Their structural `isCompactSummary` and
`isVisibleInTranscriptOnly` fields now classify them as system control evidence
under adapter v6; they create no human work turn. The rebuilt ledger contains
zero unresolved records and no metric-affecting problems. Two non-metric
heuristics remain visible as warnings without falsely degrading overall health.

User-owned state survived activation: two discovery roots, seven report
templates, and two disabled scheduled reporters. The installed native
development bundle is `0.4.0-dev` build `400`; its ad-hoc deep signature, bundled
CLI, healthy doctor output, running app process, local report preview, and
forward collection passed. The deterministic UI matrix captured every required
Overview, Activity, Projects, Reports, and Settings state and was visually
inspected. Source caches were never modified.

## Goal 5 live-evidence completion record — 2026-08-11

The app-owned live collector was exercised in the installed native development
bundle against the production ledger, 101 cataloged repositories, and the real
Codex and Claude cache roots. The app published live status without opening its
menu or main window. A real recursive FSEvents integration test passed, while
ordinary file storms remained capped and coalesced in virtual-time tests.

Ordinary installed-app convergence settled at a 2.70-second median and
3.56-second p95 in the final bounded sample, below the five-second product
target. A clean five-second interval after convergence consumed no measurable
process CPU at `ps` centisecond resolution. `vmmap` reported a 58.3 MB physical
footprint after convergence; higher RSS values included shared
macOS frameworks and allocator reserve.

The validation exposed and fixed production-only feedback paths before
completion: SQLite WAL changes under the watched data root, optional Git index
refresh writes from observational commands, and repeated global repository
association/index maintenance. It also removed FSEvents `WatchRoot` mode, whose
synchronous root opens can repeatedly invoke macOS Desktop-folder authorization
for ad-hoc development builds. Incremental batches now update only touched
sources, use exact conversation files or known repositories, and record a
separate `live-collector` heartbeat. Complete reconciliation retains its own
authoritative timestamp.

CLI pause and resume changed the running app between `stopped` and active modes
within the bounded check. Cross-process notification is backed by the watched
settings file and a 30-second reconciliation read, so a launch-time notification
race cannot leave runtime state stale. Sleep, wake, launch, and resume all use
bounded provider recovery plus at most 16 recently active repositories; the
provider families and repositories are paced in small slices so ordinary work
can converge between them. The 30-minute complete reconciliation remains the
authority for every root.

The final native bundle passed deep ad-hoc signature verification, installed at
`~/Applications/Trackify.app`, launched successfully, migrated through
`0014_live_collector_status`, and reported healthy ledger/evidence state. No
summary or report provider was invoked by live collection.

The final local development build uses an ad-hoc signature with a stable bundle
identifier. Public releases use the separate hardened-runtime ad-hoc-signing
and EdDSA-pinned Sparkle pipeline documented in `UPDATES.md`.

An interrupted real Codex summary invocation was then used to validate restart
recovery. The provider process exited without releasing its generation lease,
leaving run `ea138e67-0a3e-4f91-a998-488a1b1a631b` in `running`. Installed build
`0.3.0-dev` (`503`) reclaimed the lease only after proving its local owner PID
was gone, changed the run to explicit `failed/cancelled` state at app startup,
and left no running summary records. A focused regression also proves that a
lease owned by a still-live process is never reclaimed.

Final installed build `0.3.0-dev` (`505`) applies the same startup contract to
configurable report runs, creating their deterministic fallback artifact rather
than leaving stale running state. Its app signature, doctor result, live process,
and zero-running summary/report checks pass; no `Trackify.app.previous` remains
in the installation directory.

Final audit build `0.3.0-dev` (`509`) additionally prioritizes the newest closed
half-hour during bounded provider catch-up and owns generation as a cancellable
app task. A live Codex drill selected `14:30–15:00` before older gaps; Ctrl-C
terminated the exact child, exited 130, released the lease, and immediately
changed the run to `failed/cancelled`. Doctor remained healthy, no running run
or provider child remained, and the installer rollback was moved to Trash.

Installed build `0.3.0-dev` (`510`) applies the final pacing contract: one real
production-ledger refresh upgraded one provider-backed leaf, rebuilt the local
leaf/current/day ancestry, returned zero issues, and exited normally in 18.4
seconds. The same backlog had kept the pre-cap refresh alive for roughly 47
minutes. Usage moved from 41 to 42 of 48 daily calls, no generation remained
running, and intentional deferred leaves are recorded as `localOnly`, not as a
provider outage.

Installed build `0.3.0-dev` (`511`) contains the exact validated source plus the
final `localOnly` telemetry clarification. Its deep bundle signature passes,
doctor remains healthy, and no summary run, report run, provider child, or
installer rollback is left active.

Installed build `0.3.0-dev` (`512`) recognizes Codex
`event_msg.thread_rolled_back` as non-metric control evidence. Migration 15
reclassified the one previously unresolved live record without inspecting or
changing conversation text, recomputed its canonical structural identity, and
removed the adapter issue only after the unresolved count reached zero. Live
doctor returned healthy with no problems; the migration and installer rollback
snapshots were moved to Trash after verification.

## Automated checks

- `swift test`: 152 tests across domain, store, engine, adapters, macOS application state, Goal 2 capability discovery, canonical evidence integrity, Codex rollback classification and migration repair, bounded rebuild coverage, Claude sidechain and compacted-context classification, Claude Desktop Code audit ingestion, live FSEvents planning and delivery, queue isolation/recovery, provider-process cancellation, exact-owner signal recovery, newest-first bounded summary catch-up, dead-owner lease reclamation, interrupted-summary startup recovery, cross-process provider-generation coalescing, weekly allowance attribution, live menu budget state, budget-fallback recovery without retry churn, provider credit rates, budget migration, usage and budgets, versioned templates, independently managed scheduled reporters, pre-compilation repository-group scoping, run-specific instructions, repeated manual generation, canonical summary coverage/upgrades, internal-message filtering, privacy profiles, immutable artifacts, idempotent delivery, stable pagination, dense hourly and one-year/120-repository query scale, deterministic simulation, migrations, privacy, updates, and CLI surfaces.
- `swift format lint --recursive --strict`: clean using the repository configuration.
- `git diff --check`: clean.
- `scripts/check-fixture-privacy.sh`: sanitized fixture structure and credential/path checks pass.
- Deterministic two-day simulation: 9 core events, 2 repositories, 4 sessions, 7 durable conversation messages, 2 commits, quiet periods, and one honestly unfinished final session.
- Deterministic 42-day showcase simulation: 4 grouped repositories, quiet and parallel-project days, commits, Codex/Claude conversation evidence, tests, completed/investigating/in-progress reports, and explicit uncommitted work.
- Preserved simulation ledger: ordinary `trackify day` query returns 3 active evidence hours, 2 LLM turns, 4 conversation messages, and one commit for the first virtual day.
- Migration recovery: a private `0600` SQLite backup is created before applying a pending supported migration.
- Canonical message repair: migration 3 preserves raw evidence while merging equivalent cache observations into one searchable/session message, and snapshot queries resolve historical aliases without double-counting.
- Message privacy repair: migration 5 sanitizes stored message/report text, removes transport-only image markup, merges attachment-bearing cache variants, preserves source aliases, and rebuilds full-text search from the repaired canonical records.
- Agent CLI contract: `context --today --all` returns one bounded cross-project ledger; complete JSON including encoding overhead remains within `--max-characters`; session inspection returns the latest requested tail in chronological order; and report JSON exposes evidence counts while omitting the potentially large identifier list unless `--evidence-limit` is explicit.
- Data export: a live-ledger SQLite snapshot remains consistent, uses mode `0600`, and refuses destination overwrite.
- Diagnostic export: an allowlisted `0600` JSON file excludes the database path, a hostile absolute source path, and a synthetic provider token while preserving operational counts.
- Report deletion: generated reports, artifacts, report runs, delivery history, and report search documents are removed transactionally while evidence and recipe configuration remain separate.
- Update authority: direct, Homebrew, managed, and development origins select exactly one updater; unsigned or keyless direct builds stay disabled.
- Provider readiness: Codex login-status success/failure and Claude's explicit authentication-unknown state are covered without reading credential files or launching an interactive Claude command.
- Cache recovery: JSONL cursors restart safely after atomic file replacement and same-inode truncation; incomplete tails remain retryable and duplicate hook/cache observations remain idempotent.
- Adapter upgrades: a legacy conversation cursor replays once through a newer message-evidence adapter and then returns to incremental collection without duplicate stable records; adapter v6 additionally recognizes Claude compacted transcript context from structural flags.
- Date-range backfill: conversation import honors the explicit half-open period even after the live cursor reached EOF; Git backfill imports an older requested period independently from a later cursor; both repeat idempotently.
- Git transitions: clean, dirty, unchanged, clean, and repeated-dirty states retain every real transition without producing events for unchanged polls or collapsing a later repeated state.
- Subprocess safety: provider commands use a 180-second deadline, authentication probes use 5 seconds, general Git commands use a 300-second ceiling, output remains bounded, and a stuck exact child is terminated and reaped in the regression test.
- Reporting semantics: message-only evidence remains observed, dirty working-tree evidence is in progress, failed builds/tests are investigating, commits are completed, and empty periods remain inactive. Lifecycle-only hooks do not manufacture report activity; restart catch-up fills older evidence-bearing hours deterministically without expanding provider calls.
- Provider failure isolation: a failed model invocation has a durable classified run and persists an evidence-backed deterministic artifact, while an inactive period remains provider-free.
- Narrative evidence: report packets join bounded normalized Codex/Claude message excerpts and repository association by stable identifiers without copying transcript bodies into event payloads. Exact repository paths and home usernames are removed before provider serialization.
- Structured provider validation: fabricated, duplicate, missing, or out-of-packet evidence references are rejected before a model narrative can be accepted.
- Smart evidence compilation: fixed-clock regressions prove deterministic
  selection, short provider-visible aliases, stable local provenance recovery,
  parallel-project coverage, user-intent/failure/final-state priority, bounded
  assistant narration, payload allowlisting, secret redaction, hierarchical daily
  inputs, quiet-hour metadata, and the 20 KiB cap.
- Degraded health: persisted collector failures remain visible through lightweight status refreshes until a healthy collection clears them.
- Local install, repair, and recoverable-uninstall scripts pass Zsh syntax validation and refuse unrelated CLI-link replacement by construction.
- Release automation and normal CI/Pages workflows parse as YAML; the release job is protected, credential-gated, and cannot publish before deep ad-hoc signing, architecture, identity, version, Sparkle, manifest, checksum, and SBOM steps succeed.

## Native UI smoke test

`scripts/validate-ui.sh` builds the native app, creates isolated populated and empty ledgers, fixes the UI clock, and disables background collection and login-item mutation. It captures Overview in Today, historical-day, seven-day, and 30-day modes, including every selectable chart metric and an edge-clamped tooltip; Activity and Projects at the default window size; populated and empty Reports History at default and tall window sizes; Reports Templates and Scheduled; the New Report composer and New Template editor; Activity at 1600×1100 points; empty Overview/Activity states; and in-window Sources, AI Providers, and Usage settings in light and dark appearance. The harness verifies that every window appears at the requested dimensions and resolves the exact validation process before capture. The screenshots were visually inspected for hierarchy, clipping, stable date-control positions, complete chart domains, hourly density across ranges, major/minor axis guides, selected-metric feedback, tooltip containment, sticky-header spacing, report/template/reporter separation, full-size item-backed sheets, provider/source separation, honest cost language, template/artifact provenance, empty-state centering, and tall-window fill. The app did not read the normal ledger or invoke a report provider during this test.

The full matrix remains the release and broad-refactor check. Isolated UI changes use named cases so validation stays proportional:

```bash
zsh scripts/validate-ui.sh .build/ui-validation-focused \
  reports-history-empty reports-history-empty-tall
```

When no case names follow the output directory, the script captures the complete matrix.

## Goal 2 work-intelligence validation

- Source and generator discovery are separate. The live machine reports Codex
  current/archive, Claude terminal, and Claude Desktop Code audit history as four
  independent source surfaces; Codex and Claude readiness remain independent
  generation capabilities.
- Generation discovery prefers the newest Claude Desktop-bundled Code CLI before
  an older terminal installation. A live Codex synthetic run succeeded and
  retained its emitted input/output usage; the live Claude test classified the
  bundled CLI's expired OAuth session as authentication-required without logging
  the provider response.
- The Claude Desktop Code adapter is incremental and bounded, reads only
  `audit.jsonl` plus allowlisted `sessionId`, `cliSessionId`, and `cwd` metadata,
  and never reads `.audit-key` or persists audit HMAC/account/configuration data.
- Persisted run states cover pending, running, succeeded, deterministic fallback,
  failed, timed out, and cancelled. Interrupted runs recover locally without
  replaying a model process.
- Usage preserves separate input, cached-input, output, and reasoning tokens,
  provider-emitted cost when present, and explicit unknown billing context when
  absent. Budget checks happen before invocation and include a conservative
  16,000-token provider-CLI context allowance; actual emitted usage replaces the
  estimate after a run. The tiny live Codex payload measured 14,128 input tokens,
  demonstrating why payload tokens alone are not presented as total spend.
- Existing V1 reports migrate to immutable legacy artifacts with evidence links
  and unknown historical telemetry; migration triggers no model call.
- Artifacts are stored before delivery. Clipboard, Markdown, JSON, and mock
  destinations enforce permission, privacy rank, idempotency, and no conflicting
  overwrite.
- A synthetic 120-repository, 365-day ledger with 2,190 events completed the 365
  dashboard snapshots, grouped catalog, and bounded recent-event query in under
  one second on the reference machine.
- Isolated CLI validation exercised source/provider status, usage/runs, recipes,
  scheduled reporter create/update/enable/disable/delete, artifacts, stable page cursors, bounded artifact-list summaries, explicit
  full-provenance lookup, Markdown, and versioned JSON against the 42-day
  showcase ledger.
- The installed production-ledger check reduced a two-artifact JSON list from
  more than 21 KB of embedded evidence identifiers to a 2.1 KB schema-3 summary
  page. `artifacts show` and export remain the intentional full-record surfaces.

The per-criterion result and remaining release-owner gates are in
[GOAL_2_ACCEPTANCE_AUDIT.md](./GOAL_2_ACCEPTANCE_AUDIT.md).

## Goal 2 packaged local build

The final source state was packaged as release-mode Universal development build `0.3.0-dev`
(`307`) with the bundled CLI and Sparkle framework. Deep ad-hoc signature
validation, bundle metadata, Universal architecture, bundled CLI version
resolution, fresh schema-8 ledgers, and diagnostics all passed natively on arm64
and through Rosetta on x86_64. The app, CLI, Sparkle framework, Autoupdate,
Updater, Downloader XPC, and Installer XPC all contain both slices. The
development installer preserved
the previous application as a timestamped backup, installed the new build at
`~/Applications/Trackify.app`, refreshed the stable `~/.local/bin/trackify`
link, launched the app, and diagnosed the existing production ledger as healthy.
The installed CLI reports all four supported conversation-history locations and
selects ready Codex when Claude generation readiness is unverified.
The installed production ledger migrated through `0008_report_schedules`,
seeded its hourly and daily reporters, passed integrity diagnostics, and the
launched app process remained healthy. Both installed binaries contain arm64
and x86_64 slices.
The first reconciliation after launch completed in about 96 seconds against the
existing 873 MB ledger and large Codex/Claude caches, advanced the collector
heartbeat, returned the app process to idle, and left SQLite integrity healthy
with no collector issue.

Build 307 adds the selectable Overview trend. Evidence hours, LLM turns,
commits, and committed lines each drive the same hourly bar-chart surface across
Day, 7-day, and 30-day ranges. Ordered non-overlapping snapshots are partitioned
in one pass, and a regression proves that the dense buckets preserve the totals
of the complete range snapshot. Deterministic captures verified stable date
controls, end-to-end domains, hour/day guide hierarchy, selected-card feedback,
and a tooltip clamped above and inside the chart panel. The packaged and
installed app and CLI both contain arm64 and x86_64 slices; strict deep signature,
version/build metadata, the running installed process, and production-ledger
diagnostics all passed.

The Evidence hours selection intentionally plots evidence-item density within
each hour while retaining hours-with-evidence as the card total. A macOS model
regression prevents this drill-down from reverting to binary `0/1` occupancy,
which makes adjacent active hours appear to be continuous measured work.

Build 307 also resolves template group names through discovery-root membership
before the bounded evidence compiler ranks events. Declared scopes fail closed
if they were not resolved before packet-local repository aliases are created. A
live Work-scoped Clockify preview selected both Work repositories, 12 useful
items from 539 candidates, and no Personal repositories. Its single explicit
Codex run used a 5.5 KB packet, 15,444 reported input tokens, 287 output tokens,
and stored an evidence-linked in-progress artifact; Codex CLI did not report a
billing amount.

An additional unsigned direct-origin contract build proved that app-local,
external-symlink, native, and Rosetta CLI invocation all resolve version `0.2.0`,
build `201`, direct origin, and Sparkle as the sole update authority. The test
uses a non-release placeholder key and does not claim cryptographic validity.

This local package is deliberately not described as a published release
candidate: it has no production Sparkle key or signed enclosure. Those gates,
the non-notarized first-open drill, live update, and elapsed soak remain in the
acceptance audit.

## Universal bundle

`scripts/build-app-bundle.sh` produced a release-mode `0.1.0-v1-rc` development bundle (build `127`) with both `arm64` and `x86_64` slices. Validation confirmed:

- valid `Info.plist`, bundle identifier, macOS 14 minimum, version, build, menu-bar identity, and development update origin;
- a 1024-by-1024 Trackify icon and embedded Sparkle framework;
- `@executable_path/../Frameworks` runtime search path on both app slices;
- no linked dependency or runtime search path containing a user directory or developer-machine Xcode toolchain path;
- Universal 2 slices for the app, bundled CLI, Sparkle framework, Autoupdate helper, Updater app, and both XPC services;
- native arm64 CLI execution and x86_64 execution through Rosetta;
- a valid bundle-level ad-hoc development signature after final packaging.

The local bundle is ad-hoc signed. Hardened-runtime signature verification passes; production Sparkle enclosure signing, recoverable key custody, non-notarized first-open validation, and a live update remain release-owner gates.

A second native bundle validation injected `direct` installation origin, build `77`, version `0.1.0-origin-test`, and a non-production Sparkle public-key placeholder. Both direct execution and an external symlink invocation resolved the enclosing bundle metadata and selected Sparkle as the sole update authority. This validates packaging and origin routing, not cryptographic signing or a live feed.

An isolated development-install lifecycle used a task-specific temporary install home and data root. It installed the app and stable CLI link, initialized and diagnosed the private ledger, resolved the bundled version through the link, repaired the link idempotently, reinstalled the same bundle, and preserved the prior app as one timestamped backup. No shell profile or production Trackify data was touched. The full uninstall script is syntax/scope-reviewed but its app-owned login-item removal still requires the signed installed-app matrix below.

## Real repository-scale check

Reference machine: Apple M1 Pro, 16 GiB RAM, arm64, macOS 26.5.2.

Read-only Git metadata collection ran against the two intended discovery roots with conversation providers disabled and an isolated temporary ledger:

| Measurement | Result |
|---|---:|
| Repositories | 99 |
| Commits | 17,920 |
| Evidence events | 18,121 |
| Source issues | 0 |
| First full import | 125.03 s |
| First-import peak memory footprint | ~122 MB |
| Ledger size | 40 MB |
| Incremental reconciliation after cursor optimization | 35.10 s |
| Incremental peak memory footprint | ~77 MB |

The app uses a 30-minute reconciliation interval. The incremental run consumed 14.92 CPU-seconds, which is about 0.83% of one core averaged across that interval. Provider hooks and manual refresh provide lower latency without continuously rescanning every repository.

An idempotent production-ledger backfill for 2026-08-04 through 2026-08-05 completed in 46.83 seconds after candidate-cache filtering, with 99 repositories and zero source issues. The resulting evidence-first day queries reported:

| Day | Active evidence hours | LLM turns | Conversation messages | Commits | Committed lines | Repositories |
|---|---:|---:|---:|---:|---:|---:|
| 2026-08-04 | 13 | 49 | 445 | 58 | +29,916 / -5,300 | 5 |
| 2026-08-05 | 13 | 142 | 753 | 70 | +9,016 / -1,250 | 9 |

Migration 3 repaired the production ledger in place after creating a private backup. It retained 2,733 legacy aliases, left zero duplicate normalized message groups, and preserved raw observations/events for audit. Snapshot queries and report evidence resolve those aliases canonically.

Migration 4 repaired dual-cache Codex representations whose session, role, normalized text, and timestamps identify the same logical message within 500 milliseconds. It created a third private pre-migration backup, reduced 144,693 stored message rows to 109,112 canonical messages, and retained 38,362 stable aliases while preserving raw observations and events. The duplicate seen in the live Activity capture now resolves to one row; future ingest applies the same bounded rule.

Migration 5 repaired the production ledger after creating a fourth private pre-migration backup. The resulting 1.09 GB database passed SQLite integrity checks. A previously stored contextual credential is represented only by a redaction marker in Trackify-owned message and search surfaces; the corresponding attachment-bearing prompt resolves to one canonical message with no transport markup. Live CLI checks confirmed that a 2,000-character JSON context is exactly 2,000 bytes, the all-project day ledger summarized four active projects in one call, recent session tails are chronological, and a 200-reference report returns zero evidence identifiers by default while retaining its count.

An installed build-114 Overview was captured against that ledger after the consolidated UI installation. Its complete seven-day snapshots reported 47 evidence hours, 264 LLM turns, 145 commits, +44,139 / -6,719 committed lines, and project focus across the real repository catalog. The app opened on Today / 7 days, showed reports and folder-associated projects, and retained no synthetic duration or agent-runtime claims.

Installed build 118 validated the compact menu against the live ledger. It retained all six statistics, replaced the indefinite spinner with a semantic status capsule, anchored the hourly bars to a labeled `00 / 06 / 12 / 18 / 24` baseline, added a minute-accurate red current-time rule, reduced report state to colored text, and collapsed secondary actions into a verified overflow menu. The live ledger contained local evidence-backed `report-v4` records without a configured provider or token use. Concrete token-free summaries prefer commit titles or the latest repository-associated assistant update over generic metric restatement.

Installed build 119 validated Activity against 458 live-ledger entries. Day headers remained pinned on a solid detail-pane surface without extending beneath the sidebar. Flattening each day into the outer `LazyVStack` restored actual viewport-driven row construction; the rendered accessibility tree contained 66 static-text elements rather than constructing all 458 entries. Repository and report lookups are precomputed once per render, and conversation previews are bounded to 600 characters without truncating stored or searchable evidence. Both the initial and scrolled live states were visually inspected.

Installed build 121 validated typed conversation roles against the live ledger and deterministic showcase. Activity presents user prompts as blue person-marked `You` rows and assistant responses as purple sparkle-marked `Agent` rows; Projects reports separate prompt and agent-update counts. `report-v5` carries typed message roles, treats user messages as intent and assistant messages as progress context, and pairs them only within a supporting session or repository. A parallel-work regression proves an unrelated repository commit cannot be attached to another project's request. The corrected live token-free report paired its request and update within `novartis-ai-frontend`, retained the honest in-progress state, and did not claim completion. Two reports created by the superseded validation build were removed by exact identifier; the corrected revision and all source evidence remain.

Installed build 122 corrected Overview chart semantics. Day now queries and renders 24 real hourly evidence snapshots instead of placing one daily aggregate in a time-series frame; historical Day selection performs the same ledger-backed query for the selected date. Seven- and 30-day ranges remain daily evidence-hour trends. Deterministic screenshots validated Today, a populated historical day, seven-day history, and empty states. Native pointer inspection exposes period, evidence, turns, commits, line deltas, and repositories on the trend, while calendar-cell hover exposes the corresponding daily summary.

Installed build 123 completed the chart and surface-polish pass. Trend hover rules now use the same hour/day calendar unit as their marks, placing the rule on the selected bar or point. The heatmap footer has a fixed height, preventing hover-driven layout movement; Today is pink and selected dates use a pale-blue outline. Activity and Projects use one gray, icon-bearing search field, and the repository list uses the normal window background rather than a second sidebar material. Populated, empty, default-size, and tall-window captures passed after the change.

Installed build 124 removed the ambiguous global refresh icon from the main-window toolbar. Automatic collection is unchanged, and the explicit Sync now fallback remains in the labeled menu-bar overflow. The complete native UI capture matrix passed with a clean title-bar edge.

Installed build 125 corrected the history-date popover layout. The redundant visible field label is hidden, and the graphical calendar uses a deliberate compact width instead of being compressed beside its label. The installed popover was opened through the accessibility hierarchy and verified at its final native size.

Installed build 126 completed the agent-CLI privacy and bounded-output pass. The live migration created its fourth private backup, applied schema 0005, rebuilt search, and passed integrity diagnostics. The installed Universal app and bundled CLI both contain `arm64` and `x86_64` slices; the ad-hoc development signature verifies, the app launches, and the installed CLI reports `0.1.0-v1-rc`. Strict formatting, fixture privacy, all 76 tests, and the complete isolated native screenshot matrix pass on the packaged source state.

Installed build 127 corrected the application-time boundary. Production refreshes now obtain a fresh instant from `SystemWallClock`, while deterministic UI validation retains `FixedWallClock`; collection heartbeats, report scheduling, dashboard cutoffs, history, hourly charts, navigation, and midnight rollover therefore share one advancing time source. Regression tests prove that production time advances between reads and validation time remains fixed. Strict formatting, fixture privacy, all 78 tests, and the complete isolated native screenshot matrix pass on the packaged source state.

Goal 2 Milestone 1 was measured read-only against the production ledger without
saving a report or invoking Codex/Claude. Across 12 active hours, the compiler
reduced 682 candidate events to 201 selected records. The 12 hourly packets total
24,396 estimated input tokens, with a 2,167-token median and 2,894-token maximum;
the full-day hierarchical packet was about 2,500 tokens and retained all four
active contexts. The earlier suffix-based inspection estimated 164,591 input
tokens for the same busy-day hourly shape before its daily report, so measured
hourly input fell by approximately 6.7x. `trackify report --preview` and
`--preview-hour` performed the measurement and made no provider calls.

## Goal 3 canonical summary validation

The schema-0009 implementation has automated coverage for:

- private summary tables, evidence/child links, immutable revisions, search,
  run telemetry, and the complete migration list;
- full long user-message and commit-message reconstruction across chunks;
- explicit assistant truncation metadata and a hard 20 KiB packet ceiling;
- project-structured model content plus dedicated compact menu copy;
- stable closed-half-hour identity, zero provider work on unchanged refresh,
  and late-evidence leaf/parent revision rebuilding;
- daily configurable-report compilation from complete canonical summaries;
- provider/report usage aggregation and fallback behavior;
- fixed-clock AppModel behavior and all prior collection, privacy, queue, and
  UI-query regressions.

The isolated simulator now runs the same local SummaryCoordinator after evidence
ingestion, so `simulate --days 2` and the showcase ledger contain inspectable
segment/current/day summary objects without provider calls.

The final 42-day native validation ledger generated 143 immutable summary
revisions with no provider calls or issues. All 31 retained day summaries fit
their complete ordered child coverage into one parent packet. The populated,
empty, historical, chart-tooltip, Activity, Projects, Reports, composer,
template-editor, and in-window settings screenshot matrix passed.

The production ledger migrated through schema 0009 with a private backup and
passed SQLite integrity checks. The final Codex-backed day summary covered all
1,245 eligible events through 29 ordered half-hour children across
`novartis-ai-backend`, `novartis-ai-frontend`, `trackify`, and `twittex`. Its
single 15,679-byte parent packet estimated 19,920 input tokens; Codex reported
18,499 input and 2,293 output tokens. The structured result contains a detailed
project section for every project, preserves explicit unfinished work, and has
a separately authored 375-character menu narrative. Transport/control records,
temporary paths, and AGENTS instructions do not appear in the result. The CLI
reported cost as unknown because Codex CLI emitted no billing amount.

The final source state was packaged and installed as release-mode Universal
development build `0.3.0-dev` (`311`). Deep ad-hoc signature verification
passed, and both the app and bundled CLI contain `arm64` and `x86_64` slices.
The development installer preserved the previous app, installed and launched
`~/Applications/Trackify.app`, refreshed `~/.local/bin/trackify`, and diagnosed
the 873 MB production ledger as healthy through schema 0009. An installed-CLI
smoke read returned the same version-4 Codex summary, four project sections,
and complete 1,245/1,245 coverage. Reopening the app triggered no additional
provider call. The three deliberately triggered live validation generations
used 72,607 input and 8,511 output tokens in total; the ordinary 50,000-token
daily limit was restored afterward. Monetary cost remains unknown because the
Codex CLI did not expose billing data.

## Remaining release validation

- Seven-day sleep/wake and failure-recovery soak with the app continuously running.
- Clean install, upgrade, rollback/repair, and uninstall on every confirmed workplace architecture.
- First release publication, appcast/SBOM inspection, non-notarized first-open, and live update verification using the already provisioned protected Sparkle key.
- Workplace macOS baseline confirmation; broader public promotion would also reopen the documented name-clearance checklist.
