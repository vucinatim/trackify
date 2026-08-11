# Trackify V1 Acceptance Audit

Status: Product source proven; first release and elapsed-runtime gates remain
Last updated: 2026-08-11

## 1. Audit rule

This audit maps every acceptance criterion in [V1.md](./V1.md#16-v1-acceptance-criteria) to current authoritative evidence. “Implemented” is not treated as proof of a runtime or distribution claim. A criterion is marked:

- **Proven locally** when a focused test, inspected artifact, deterministic CLI result, or native smoke test directly exercises it.
- **Implemented; external validation pending** when the required code exists but the criterion requires credentials, a different machine, a long-running observation, or a live provider/release service.

The detailed command outputs and reference-machine measurements are recorded in [VALIDATION.md](./VALIDATION.md).

## 2. Current validation baseline

- Strict Swift formatting passes.
- All 151 tests in 10 suites pass; the preceding 149-test integration revision
  also passed with code coverage enabled in CI.
- Fixture privacy, shell syntax, workflow YAML, and Git whitespace checks pass.
- The deterministic two-day simulation produces 9 core events across 2 repositories and 4 sessions: 7 durable conversation messages and 2 commits, with one honestly unfinished session.
- A normal CLI query against the preserved simulation ledger returns 3 active evidence hours, 2 LLM turns, 4 conversation messages, and one commit for its first day.
- The authoritative `0.1.0-v1-rc` development bundle is rebuilt for each validated source revision with valid metadata and a valid bundle-level ad-hoc signature.
- All seven Mach-O files in the app are Universal 2: app, CLI, Sparkle framework, Autoupdate, Updater, Downloader XPC, and Installer XPC.
- Native arm64 and Rosetta x86_64 CLI execution pass. No packaged dependency or runtime search path contains a user directory or developer-machine Xcode path.
- The 99-repository reference collection recorded no source issues and met the 30-minute average CPU target. The required seven-day soak has not yet run.

## 3. Requirement-by-requirement result

| # | Criterion | Result | Authoritative evidence |
|---:|---|---|---|
| 1 | Launch at login and passive collection | Implemented; external validation pending | `SMAppService.mainApp` registration, first-launch default, app-owned scheduler, and isolated native UI smoke test exist. A signed installed login/reboot cycle remains part of the release matrix. |
| 2 | Reconcile configured repositories after restart or sleep | Implemented; external validation pending | Collection is cursor-based and the app performs immediate startup plus 30-minute reconciliation. Restart/sleep recovery must still be observed in the seven-day soak. |
| 3 | Discover and group newly cloned repositories | Proven locally | Discovery and root-persistence tests cover nested repositories, dependency-tree exclusions, stable relative paths, and folder-owned grouping; every reconciliation rescans enabled roots. |
| 4 | Import Codex and Claude histories idempotently | Proven locally | Sanitized fixture, recent-cache prioritization, oversized-record recovery, incremental-directory, cursor-recovery, and repeated-import tests cover both adapters. |
| 5 | Backfill historical evidence by date range | Proven locally | A regression proves explicit half-open conversation ranges work after the live cursor reaches EOF, repeat idempotently, and leave the live cursor unchanged; Git accepts the same collection range. |
| 6 | Re-query views and regenerate reports without changing evidence | Proven locally | Activity snapshots are deterministic range queries, report regeneration creates traceable revisions, and immutable-ingestion tests keep both separate from source evidence. |
| 7 | Run multi-day simulation in seconds and isolation | Proven locally | The two-day foundation scenario and 42-day rich showcase scenario pass against separate data roots; the latter drives deterministic native UI screenshots. |
| 8 | Reconstruct core activity without machine idleness | Proven locally | Activity snapshots count durable Git and conversation evidence by local clock hour and never consult HID, file-idle, or machine-idle state. |
| 9 | Keep optional lifecycle telemetry outside core history | Proven locally | Lifecycle-only and stale unmatched-run regressions produce zero core evidence hours while the separate low-level interval derivation remains available for optional telemetry. |
| 10 | Avoid double-counting snapshots and rewritten Git history | Proven locally | Git transition revisions preserve repeated real states while suppressing unchanged polls; reachability reconciliation retains historical commits while excluding unreachable commits from core activity and reports. Exact and near-time canonical-message regressions plus migration 4 collapse dual Codex cache representations into stable aliases without deleting raw observations or events. |
| 11 | Distinguish observed, completed, in-progress, investigating, and inactive reports | Proven locally | Focused report-state tests prove message-only evidence remains merely observed, dirty trees are in progress, failed builds/tests are investigating, commits are completed, and empty periods remain inactive. |
| 12 | Link reports to evidence and generator version | Proven locally | Report generation tests verify stable evidence references, revisions, provider/model metadata, typed user/assistant context, intent-aware deterministic summaries, and `report-v5`. |
| 13 | Keep statistics/history available without summarization | Proven locally | A forced provider failure persists an evidence-backed deterministic report, surfaces one operational issue, and leaves inactive periods provider-free. |
| 14 | Serve Overview, Activity, and Projects from shared queries, with integrated date browsing, reports, and search | Proven locally | The native views compile over `TrackifyEngine`/`TrackifyStore`; the deterministic harness captured all three primary screens plus tall-window and empty-state variants, while focused query/store tests cover bounded history, canonical messages, repository catalog, reports, and search. |
| 15 | Expose ledger operations and JSON through the CLI | Proven locally | The built CLI advertises status, today/day/timeline, search, context, backfill, doctor, data, provider, integration, collection, simulation, and update surfaces; versioned JSON is exercised by CLI and simulation checks. |
| 16 | Recover useful project context with one command | Proven locally | Context regression resolves the current working copy and reports branch/HEAD, active evidence hours, observed window, recent messages/commits, and uncommitted file and line counts under a character budget. |
| 17 | Surface collector failures and permissions | Proven locally | Collector issues persist, lightweight app refresh keeps degraded state visible, and `doctor` plus allowlisted diagnostic export are tested. |
| 18 | Preserve the ledger through migrations | Proven locally | Migration tests create a private usable ledger and a mode-`0600` recoverable snapshot before applying a pending supported migration. |
| 19 | Require no timers or report maintenance | Proven locally | Normal operation is evidence-driven and scheduled; the V1 app contains no task/timer/report-editing workflow. |
| 20 | Generate through either authenticated Codex or Claude CLI | Implemented; external validation pending | Both provider commands, model defaults, isolation flags, bounded I/O, timeout behavior, and structured-response contracts are tested with process doubles. Live authenticated Codex generation passes with measured usage; a successful live Claude invocation on a machine with current Claude Code authentication remains a release check. |
| 21 | Prevent report runs from modifying repositories or re-entering history | Proven locally | Codex is ephemeral/read-only/tool-isolated; Claude is non-persistent/tool-free/MCP-isolated; both run outside repositories, and persisted synthetic internal sessions are excluded in a defense-in-depth test. |
| 22 | Install, bootstrap, diagnose, and open from one stable agent link | Implemented; external validation pending | Stable GitHub Pages installer protocol, verified install/repair/uninstall scripts, bootstrap CLI, and release workflow exist. The promise cannot pass until an actual GitHub release is installed from that public endpoint and its one-time non-notarized first-open flow is exercised. |
| 23 | Recommend bounded primary groups | Proven locally | Bootstrap inspection recognizes `zerodays` as Work and `MyProjects`/Projects/Developer as Personal, reports only aggregate repository/history counts, and emits bounded provider-call/token ceilings. |
| 24 | Backfill all evidence while limiting initial model reports | Proven locally | Bootstrap supports `all|none` evidence import, caps initial report history at 14 days, skips inactive periods, and falls back deterministically on provider failure. |
| 25 | Apply a signed direct update in one action | Implemented; external validation pending | Sparkle ownership, UI action, appcast/release automation, manifest, and signature verification gates exist. The permanent EdDSA key is configured; publishing two releases and applying the live update remain release operations. |
| 26 | Preserve state and bundled CLI through update | Implemented; external validation pending | State lives outside the app bundle; migrations, backup, origin routing, and bundled CLI version checks pass. Preservation still requires a live signed upgrade test. |
| 27 | Defer Homebrew, managed, and development updates correctly | Proven locally | Installation-origin regression and built development CLI prove exactly one update owner and disabled Sparkle for non-direct builds. |
| 28 | Send no Trackify analytics or automatic crash uploads | Proven locally | Dependency/source audit and network design expose only Sparkle update checks and explicitly selected provider processes; no analytics or crash-upload SDK is present. |
| 29 | Remove known synthetic secrets before provider/diagnostic export | Proven locally | Tests cover token patterns, exact repository paths, home usernames, transient bounded report packets, discarded provider failure output, and content-free diagnostic export. |
| 30 | Meet resource budgets and seven-day 60-repository soak | Implemented; external validation pending | A real 99-repository benchmark meets incremental CPU and memory targets. The required seven-day sleep/wake/failure soak has not run. |
| 31 | Accept optional immediate lifecycle telemetry from configured hooks | Implemented; external validation pending | `trackify integrations emit` writes a validated, maximum-64-KiB structural record without opening SQLite, Git, network, or a provider. Hook records are explicitly excluded from core historical activity. |
| 32 | Remain correct with absent/lost/duplicate hooks | Proven locally | Cache-only collection, absent inbox behavior, locked incremental inbox delivery, duplicate hook reads, hook/cache canonical deduplication, and lifecycle-only activity isolation are tested. Persisted caches remain the backfill authority. |

## 4. Remaining release gates

No additional V1 source feature is currently identified. The remaining proof requires external state or elapsed runtime:

1. Confirm the workplace fleet baseline and whether Intel support is actually needed.
2. Publish one release candidate with the provisioned Sparkle key and verify version/tag/manifest/appcast/SBOM consistency, ad-hoc code-signature integrity, hardened runtime, enclosure signature, checksum, and honest non-notarized first-open guidance.
3. Run clean install, launch-at-login/reboot, live Codex report, live Claude report, update/relaunch, repair, and uninstall on each supported architecture.
4. Complete the seven-day 60-plus-repository soak including sleep/wake, restart, moved/new repositories, large working trees, backfill, absent hooks, provider failure, and recovery without missed or duplicated work.

Trackify should remain described as **release-candidate source** until these gates are recorded as passing. A successful local build is not a substitute for them.
