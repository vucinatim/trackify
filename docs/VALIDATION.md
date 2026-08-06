# Trackify Validation Record

Last updated: 2026-08-06

This document records reproducible V1 and Goal 2 checks separately from product design. It does not treat unavailable signing credentials as a successful signed-release test.

## Automated checks

- `swift test`: 102 tests across domain, store, engine, adapters, macOS application state, Goal 2 capability discovery, Claude Desktop Code audit ingestion, queue isolation/recovery, usage and budgets, versioned recipes, privacy profiles, immutable artifacts, idempotent delivery, stable pagination, one-year/120-repository query scale, deterministic simulation, migrations, privacy, updates, and CLI surfaces.
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
- Adapter upgrades: a legacy conversation cursor replays once through message-evidence adapter version 2, then returns to incremental collection without duplicate stable records.
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
- Release automation and normal CI/Pages workflows parse as YAML; the release job is protected, credential-gated, and cannot publish before signing, notarization, stapling, Team-ID/Gatekeeper, architecture, version, Sparkle, manifest, checksum, and SBOM steps succeed.

## Native UI smoke test

`scripts/validate-ui.sh` builds the native app, creates isolated populated and empty ledgers, fixes the UI clock, and disables background collection and login-item mutation. It captures Overview in seven-day, Today/hourly, and historical-day/hourly modes; Activity and Projects at the default window size; Activity at 1600×1100 points; empty Overview/Activity states; and Goal 2 Sources, Summaries, Usage, and Recipes Preferences in light and dark appearance. The harness verifies that every window appears at the requested dimensions. The screenshots were visually inspected for hierarchy, clipping, date selection, correct hourly versus daily chart semantics, sticky-header spacing, report/evidence distinction, provider/source separation, honest cost language, recipe/artifact provenance, empty-state centering, and tall-window fill. The app did not read the normal ledger or invoke a report provider during this test.

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
  artifacts, stable page cursors, bounded artifact-list summaries, explicit
  full-provenance lookup, Markdown, and versioned JSON against the 42-day
  showcase ledger.
- The installed production-ledger check reduced a two-artifact JSON list from
  more than 21 KB of embedded evidence identifiers to a 2.1 KB schema-3 summary
  page. `artifacts show` and export remain the intentional full-record surfaces.

The per-criterion result and remaining release-owner gates are in
[GOAL_2_ACCEPTANCE_AUDIT.md](./GOAL_2_ACCEPTANCE_AUDIT.md).

## Goal 2 packaged local build

The final source state was packaged as release-mode Universal build `0.2.0`
(`201`) with the bundled CLI and Sparkle framework. Deep ad-hoc signature
validation, bundle metadata, Universal architecture, bundled CLI version
resolution, fresh schema-6 ledgers, and diagnostics all passed natively on arm64
and through Rosetta on x86_64. The app, CLI, Sparkle framework, Autoupdate,
Updater, Downloader XPC, and Installer XPC all contain both slices. The
development installer preserved
the previous application as a timestamped backup, installed the new build at
`~/Applications/Trackify.app`, refreshed the stable `~/.local/bin/trackify`
link, launched the app, and diagnosed the existing production ledger as healthy.
The installed CLI reports all four supported conversation-history locations and
selects ready Codex when Claude generation readiness is unverified.
The first reconciliation after launch completed in about 96 seconds against the
existing 873 MB ledger and large Codex/Claude caches, advanced the collector
heartbeat, returned the app process to idle, and left SQLite integrity healthy
with no collector issue.

An additional unsigned direct-origin contract build proved that app-local,
external-symlink, native, and Rosetta CLI invocation all resolve version `0.2.0`,
build `201`, direct origin, and Sparkle as the sole update authority. The test
uses a non-release placeholder key and does not claim cryptographic validity.

This local package is deliberately not described as the public release
candidate: it is ad-hoc signed. The Developer ID,
notarization, stapling, Gatekeeper, Sparkle enclosure, and elapsed-soak gates
remain in the acceptance audit.

## Universal bundle

`scripts/build-app-bundle.sh` produced a release-mode `0.1.0-v1-rc` development bundle (build `127`) with both `arm64` and `x86_64` slices. Validation confirmed:

- valid `Info.plist`, bundle identifier, macOS 14 minimum, version, build, menu-bar identity, and development update origin;
- a 1024-by-1024 Trackify icon and embedded Sparkle framework;
- `@executable_path/../Frameworks` runtime search path on both app slices;
- no linked dependency or runtime search path containing a user directory or developer-machine Xcode toolchain path;
- Universal 2 slices for the app, bundled CLI, Sparkle framework, Autoupdate helper, Updater app, and both XPC services;
- native arm64 CLI execution and x86_64 execution through Rosetta;
- a valid bundle-level ad-hoc development signature after final packaging.

The local bundle is ad-hoc signed only. Developer ID signing, hardened-runtime signature verification, notarization, stapling, Gatekeeper assessment, Sparkle enclosure signing, and a live update remain release-owner gates.

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

## Remaining release validation

- Seven-day sleep/wake and failure-recovery soak with the app continuously running.
- Clean install, upgrade, rollback/repair, and uninstall on every confirmed workplace architecture.
- Developer ID, notarization, Sparkle, appcast, SBOM, and live update verification with protected release credentials.
- Workplace macOS baseline confirmation; broader public promotion would also reopen the documented name-clearance checklist.
