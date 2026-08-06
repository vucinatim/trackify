# Trackify V1 UI Specification

Status: Implemented and visually validated
Last updated: 2026-08-06

The application icon and menu-bar template are defined in [BRAND.md](./BRAND.md). Product scope is defined in [V1.md](./V1.md), and repository grouping is defined in [REPOSITORY_DISCOVERY.md](./REPOSITORY_DISCOVERY.md).

## 1. Purpose

Trackify is a passive observer. Its UI makes the local work ledger understandable at a glance and explorable when needed; it is not a workspace for manually maintaining tasks, timers, or reports.

The native SwiftUI application has two surfaces:

1. A compact menu-bar panel for the current day.
2. A history-first main window with Overview, Activity, and Projects.

## 2. UI principles

### Evidence before estimates

Core numbers come from durable Git and conversation evidence. The UI says “evidence hours,” not “time worked,” and does not infer activity from keyboard, mouse, foreground-window, or machine-idle state.

### Honest unfinished states

In-progress, investigating, waiting, failed, quiet, and completed periods stay distinct. A working-tree change or active agent response never becomes a completed outcome merely because time passed.

### Observation over administration

Activity, reports, history, projects, and search are primary. Setup, exclusions, provider configuration, diagnostics, pause, refresh, and updates remain secondary or agent/CLI-owned workflows.

### Dense but calm

The main window uses native sidebar navigation, restrained panels, semantic system colors, monospaced numeric values, and compact list/detail layouts. It is designed and validated at 1180×800 points while remaining usable down to 1040×700.

### Complete history without a giant sidebar

Repositories are grouped inside Projects by discovery root. The sidebar contains stable product sections rather than expanding 60-plus repositories.

## 3. Menu-bar item and dropdown

The collapsed item shows today’s evidence hours and, when a baseline exists, the active-day comparison:

```text
◉ 4h +18%      evidence recorded today
○ 0h           no evidence recorded today
Ⅱ 4h           collection paused
! 4h           degraded collection requiring attention
```

The dropdown answers four questions quickly:

- Is collection healthy, paused, or degraded?
- When was the latest concrete evidence observed?
- What are today’s evidence hours, LLM turns, commits, files, lines, and repositories?
- What does the latest stored report say, including whether it remains unfinished?

The header uses a non-animated status capsule: Up to date, Syncing, Paused, or Needs attention. The hourly chart labels six-hour intervals so gaps retain time context and draws a thin red line at the current minute. Open Trackify and pause/resume remain immediately visible; an overflow menu contains Sync now, Settings, update check, and Quit. Report copy stays in the full Activity view. The dropdown never lists the full repository catalog or hides healthy historical data behind a collector warning.

## 4. Main application shell

The native `NavigationSplitView` has three stable destinations:

```text
WORK LEDGER
  Overview
  Activity
  Projects
```

Settings remains a separate native scene. The app defaults to 1180×800 and uses a 1040×700 minimum so list/detail views do not collapse into unusable layouts.

The main window has no global refresh control: collection is automatic, and the explicit Sync now fallback remains in the menu-bar overflow and diagnostics surfaces.

Calendar selection, reports, and search remain first-class capabilities without becoming duplicate destinations. Date browsing lives in Overview; reports and search live in Activity.

## 5. Overview

Overview is the glanceable historical dashboard. It provides:

- Today, 7-day, and 30-day range selection.
- Evidence hours, LLM turns, commits, and committed-line totals.
- Per-active-day context rather than a synthetic productivity score.
- An adaptive trend chart: Day shows 24 hourly evidence-record bars, while 7-day and 30-day ranges show daily evidence hours.
- Native pointer hover on every trend point, showing its period, evidence or evidence hours, LLM turns, commits, committed lines, and repository count.
- A compact clickable six-week evidence heatmap that preserves quiet days and immediately reveals date, evidence hours, turns, and commits on hover without changing layout height. Today uses a pink marker; the selected date uses a pale-blue outline.
- Recent stored reports with state badges and copy actions.
- Project focus measured as active days in the selected range.

The selected date is always visible in the header. Today receives an explicit label and marker; selecting a heatmap cell opens that day, and a compact label-free graphical date-picker popover plus previous/next controls support direct historical navigation.

All totals and trend points use shared `ActivityQueries` snapshots. Historical Day selection loads the selected date's 24 hourly snapshots on demand; it never approximates an hourly shape from a daily total. Report copy and project focus are supplemental views over the same ledger, not alternate tracking systems.

## 6. Activity

Activity combines interpretation with concrete evidence in reverse chronological order. Entries are grouped by day and use a continuous visual rail. Day labels remain sticky using a solid detail-pane surface and inset separator rather than toolbar material. Rows are constructed lazily, repository/report lookups are precomputed, and long conversation text is bounded only for display while full text remains searchable and available through the CLI. Search and type filtering are inline, so finding a report, commit, conversation, repository, or change does not require leaving the ledger.

Activity and Projects share one neutral native search-field treatment with an explicit search icon and clear action. Project navigation uses the normal window surface rather than a separate sidebar material, so repository scale does not create a visually nested second application sidebar.

V1 entry types are:

- Reports, including evidence counts and report state.
- Commits, including committed additions, deletions, and file counts when available.
- User prompts and assistant updates associated with a repository. User prompts use a person icon, blue treatment, and the explicit label `You`; assistant responses use a purple sparkle and the label `Agent`.
- Working-tree changes, including explicit uncommitted/in-progress state.
- Test outcomes, including failures that need attention.

The All, Reports, Commits, Conversations, and Changes filters are local view filters. Conversations includes both user intent and assistant progress in chronological context. Search recognizes role terms such as user, prompt, request, agent, assistant, and response. The store supplies a bounded newest-first event query so the app never loads the entire ledger merely to render history.

### Reports in Activity

Reports appear as visually distinct cards in chronological context, rather than duplicating the same history in a separate browser. Each card provides:

- Report date and exact hourly or daily period.
- Completed, in-progress, investigating, waiting, observed, or no-activity state.
- Evidence count, provider, model, and copy action.
- Full summary alongside the concrete commits, messages, tests, and unfinished states around it.

Report generation treats a user message as intent, an assistant message as a progress claim or implementation context, and commits, tests, working-tree changes, and final period state as concrete outcome evidence. A report pairs requests and outcomes only when their session or repository association supports the relationship, so parallel projects cannot be blended into a fabricated narrative. Unfinished or investigating evidence takes precedence over unrelated completed commits, and an assistant completion claim is never sufficient proof by itself.

Reports are read-only in V1. Regeneration and evidence inspection remain stable CLI operations.

### Search in Activity

The visible Activity search field filters report summaries, commit messages and hashes, repository names, paths, and normalized Codex or Claude messages. Results retain their type, timestamp, repository association, and stable record identity. Advanced filters and semantic/vector search are deferred.

## 7. Projects

Projects automatically groups every repository by configured discovery root, such as Work and Personal. Its list/detail layout remains usable with more than 60 repositories.

The list exposes repository name and root-relative path. The detail view exposes:

- Discovery group, branch, canonical path, and latest observation.
- Counts from the bounded recent ledger window.
- Separate recent user-prompt and agent-update counts, plus commits, working-tree states, and tests associated with the repository.

No repository-by-repository setup is required. Agents recommend a small number of primary roots during installation; passive discovery owns the catalog afterward.

## 8. Guided setup and updates

The installer agent presents one bounded recommendation covering:

- Codex or Claude report provider and inexpensive default model.
- Primary Work and Personal discovery roots.
- Available evidence backfill.
- A maximum initial report-generation range.

The app itself remains passive. Signed direct installations use Sparkle’s standard update UI and GitHub-hosted release artifacts. Homebrew, managed, and development installations defer to their recorded update owner.

## 9. Visual validation contract

`scripts/validate-ui.sh` creates isolated populated and empty ledgers, fixes the application clock, disables collection/login-item side effects, and captures deterministic native screenshots for:

- Overview
- Activity
- Projects
- Activity in a tall window
- Empty Overview
- Empty Activity

The showcase contains multiple discovery roots, parallel projects, quiet days, commits, Codex and Claude conversations, tests, completed reports, investigating reports, and explicitly unfinished work. It is ingested through the production collection/store path rather than a view-only mock.

The harness also rejects missing windows and screenshots below the minimum expected dimensions. Screenshots remain local build artifacts under `.build/ui-validation` by default.

## 10. V1 acceptance criteria

1. The dropdown communicates current evidence, health, and latest report without opening the main window.
2. Core statistics never depend on machine-idle or foreground-window inference.
3. Unfinished and quiet periods remain explicit.
4. Overview compares simple totals across today, 7 days, and 30 days without a synthetic score.
5. Activity keeps reports and concrete evidence distinguishable but contextual.
6. Reports support practical history browsing, filtering, detail, and copy without duplicating Activity.
7. More than 60 repositories do not produce an unusable sidebar.
8. Repositories are grouped by discovery root and expose their associated recent evidence.
9. Overview makes today and the selected historical day obvious while keeping calendar navigation compact.
10. Activity search has a centered native empty state and searches every documented ledger record kind.
11. Normal operation requires no manual timer, task, or report maintenance.
12. The deterministic visual harness captures all three primary screens plus tall-window and empty-state variants.
