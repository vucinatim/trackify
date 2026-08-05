# Trackify V1 UI Specification

Status: Proposed
Last updated: 2026-08-05

The application icon and menu-bar template are defined in [BRAND.md](./BRAND.md).

## 1. Purpose

Trackify is primarily a passive observer. Its UI exists to make the ledger understandable at a glance and explorable when needed; it is not a workspace where users manually maintain tasks, timers, or reports.

This document specifies the V1 menu bar and main-window experience. Product scope is defined in [V1.md](./V1.md), and repository discovery behavior is defined in [REPOSITORY_DISCOVERY.md](./REPOSITORY_DISCOVERY.md).

## 2. UI principles

### Glance first

The menu bar should answer what is happening now, how today is progressing, and what the latest outcome was within a few seconds.

### Observation over administration

The application emphasizes timelines, reports, history, and search. Setup, exclusions, pause, refresh, and diagnostics are secondary controls.

### Honest empty and unfinished states

Inactive periods remain visible. Work in progress is not presented as completed. Missing or stale sources are shown without making the entire application feel broken.

### Dense but calm

Trackify displays meaningful information without filling the interface with oversized metric cards. Statistics use compact rows, timelines, and native lists.

### Progressive detail

The information hierarchy is:

```text
Menu bar glance
→ Today timeline
→ Hour/day detail
→ Repository or session evidence
```

### Passive source grouping

Repositories are automatically grouped by discovery root and folder hierarchy. The menu shows only repositories active today; the main repository view provides the complete catalog.

### Guided initial setup

When Trackify is installed by Codex or Claude, the installer agent presents one concise recommendation covering provider, primary repository groups, evidence import, and recent report generation. The native app displays the same prepared recommendation when installation is manual.

```text
Recommended setup

Work       ~/Developer/Work       38 repositories
Personal   ~/Developer/Personal   24 repositories

History    Import all available evidence
Reports    Generate the last 14 days initially
Provider   Claude · Opus · medium

[Use recommended setup]     [Review]
```

The UI does not display every repository during this decision. `Review` expands only the candidate roots, estimated report workload, and excluded or unassigned repository count.

Application update behavior is specified in [UPDATES.md](./UPDATES.md).

## 3. Menu bar item

The collapsed item shows tracked work and current pace:

```text
┌─────────────────────────────────────────────────────────────┐
│  Finder   File   Edit                         ◉ 4h12 ↑18%   │
└─────────────────────────────────────────────────────────────┘
```

States:

```text
◉ 4h12 ↑18%    tracking with current activity
○ 4h12 ↑18%    tracking with no current activity
Ⅱ 4h12         collection paused
! 4h12         degraded collection requiring attention
```

The precise symbols may use native iconography, but the state must not rely on color alone.

## 4. Menu bar dropdown

### 4.1 Active state

```text
┌──────────────────────────────────────────────────┐
│ Trackify                              ● Tracking │
├──────────────────────────────────────────────────┤
│ NOW                                              │
│                                                  │
│ ● Codex · trackify                         18m   │
│   Implementing Git repository discovery          │
│                                                  │
│ ◌ Tests · trackify                          3m   │
│   Swift test suite running                       │
├──────────────────────────────────────────────────┤
│ TODAY · Wednesday, August 5                      │
│                                                  │
│  4h 12m work       3h 06m agents                │
│  6 commits         24 files                     │
│  +842  −317        3 repositories               │
│                                                  │
│  Pace  ↑18% compared with 14-day average         │
│                                                  │
│  08  09  10  11  12  13  14  15  16            │
│  ▁   ▅   █   ▆   ·   ▂   ▇   ▅   ▃             │
├──────────────────────────────────────────────────┤
│ LATEST · 15:00–16:00              IN PROGRESS   │
│                                                  │
│ Continued implementing repository discovery.    │
│ The scanner is working, but tests are still      │
│ running and the changes remain uncommitted.      │
│                                                  │
│ trackify · 7 files · +184 −32                    │
│                                                  │
│ [ Copy report ]                 [ Open Trackify ]│
├──────────────────────────────────────────────────┤
│ Updated 11 seconds ago                       ↻ ⚙ │
└──────────────────────────────────────────────────┘
```

### 4.2 No current activity

The `NOW` section becomes quiet without implying that the day contained no work:

```text
│ NOW                                              │
│                                                  │
│ ○ No project activity detected                   │
│   Last activity 28 minutes ago in trackify       │
```

### 4.3 No activity today

```text
│ TODAY · Wednesday, August 5                      │
│                                                  │
│ No project activity detected today.              │
│ Collection is operating normally.                │
```

### 4.4 Degraded collection

Failures appear as a compact status row rather than replacing healthy data:

```text
│ ⚠ Claude history has not updated for 3 hours     │
│   Git and Codex collection are operating normally│
```

Selecting the row opens Diagnostics with the affected source selected.

### 4.5 Dropdown behavior

- The `NOW` section shows all active recognized runs, ordered by start time.
- Selecting a run opens its session or evidence detail.
- Selecting an hour in the mini timeline opens Today with that hour selected.
- The latest report is the latest closed or meaningfully provisional period.
- `Copy report` copies plain text suitable for a status update or timesheet.
- Refresh triggers idempotent reconciliation rather than clearing or rebuilding history.
- Settings and diagnostics remain secondary icon actions.
- The dropdown does not contain repository filters, full charts, or a complete repository list.

### 4.6 Update available

An available direct-install update adds one row above the normal footer without replacing activity or report content:

```text
├──────────────────────────────────────────────────┤
│ ↑ Trackify 1.2.0 is available                    │
│   Adapter compatibility and reporting fixes      │
│                                                  │
│ [ Later ]                    [ Update & Relaunch ]│
├──────────────────────────────────────────────────┤
│ Updated 11 seconds ago                       ↻ ⚙ │
└──────────────────────────────────────────────────┘
```

Download progress remains in this row. Installation pauses Trackify's own jobs safely, relaunches the app, and resumes collection through normal reconciliation. Homebrew- and organization-managed installations show their owning update action instead of `Update & Relaunch`.

The Settings update section shows the current and available version, stable channel, concise release notes, automatic-check preference, optional automatic download, and the correct action for the recorded installation origin.

## 5. Main application shell

The application uses a native sidebar, content area, and optional contextual inspector.

Primary navigation:

```text
Today
Calendar

Repositories
  grouped recent repositories

History
  Search
  Reports

System
  Sources
  Diagnostics
```

The sidebar shows only recently active repositories beneath their automatic root groups. `View all…` opens the repository catalog.

## 6. Today view

```text
┌────────────────────────────────────────────────────────────────────────────────────────────────────┐
│ ● Trackify                                     Today · Aug 5                  ● Tracking    ⌕  ⚙   │
├───────────────────┬──────────────────────────────────────────────────────────────┬─────────────────┤
│                   │ TODAY                                                        │ CURRENT         │
│ ● Today           │                                                             │                 │
│   Calendar        │  4h 12m tracked    3h 06m agents    6 commits    ↑18% pace  │ ● Codex   18m  │
│                   │  +842 −317 lines   24 files          3 repositories          │   trackify      │
│ REPOSITORIES      │                                                             │                 │
│ ▾ Work            ├─────────────────────────────────────────────────────────────┤ Implementing    │
│     client-api    │ ACTIVITY TIMELINE                                           │ repository      │
│     internal-tools│                                                             │ discovery       │
│ ▾ Personal        │        08   09   10   11   12   13   14   15   16           │                 │
│     trackify      │ Work    ░░   ██   ██   ██        ░░   ██   ██   ▒▒           │ ◌ Tests    3m  │
│     View all…     │ Codex        ├───────────┤             ├─────────────►       │   trackify      │
│                   │ Claude                 ├──────┤                            │                 │
│ HISTORY           │ Builds                      ├─┤              ├──────►       ├─────────────────┤
│   Search          │ Commits          ◆       ◆                 ◆    ◆ ◆         │ OPEN WORK      │
│   Reports         │                                                             │                 │
│                   │                 Selected: 15:00–16:00                       │ Repository      │
│ SYSTEM            ├─────────────────────────────────────────────────────────────┤ discovery      │
│   Sources         │ HOURLY REPORTS                                              │                 │
│   Diagnostics     │                                                             │ Started 09:14  │
│                   │ 15:00–16:00  IN PROGRESS                     trackify       │ Last 16:22     │
│                   │ Continued implementing repository discovery. The scanner    │                 │
│                   │ is working, but tests remain active and the changes are      │ 3 sessions     │
│                   │ uncommitted.                                  +184 −32       │ 9 files        │
│                   │                                                             │ 2 commits      │
│                   │ 14:00–15:00  COMPLETED                       client-api      │                 │
│                   │ Fixed token refresh handling and added regression tests.     │ In progress    │
│                   │ Commit 92fc81a created.                        +96 −41        │                 │
│                   │                                                             │ [View episode] │
│                   │ 13:00–14:00  NO ACTIVITY                                    │                 │
│                   │                                                             │                 │
│                   │ 12:00–13:00  INVESTIGATING                   client-api      │                 │
│                   │ Investigated intermittent authentication failures. No        │                 │
│                   │ confirmed resolution was reached during this hour.           │                 │
└───────────────────┴──────────────────────────────────────────────────────────────┴─────────────────┘
```

### Today interactions

- Selecting an hour filters the visible report and evidence while keeping the full timeline visible.
- Selecting an agent run opens its session detail.
- Selecting a commit opens its repository and commit evidence.
- The inspector shows current runs and derived open work episodes.
- The inspector collapses when the window is narrow.
- No editable tasks or manual timers appear.

## 7. Calendar view

```text
┌────────────────────────────────────────────────────────────────────────────────────────────────────┐
│ ● Trackify                                  Calendar · August 2026              ● Tracking    ⌕  ⚙ │
├───────────────────┬───────────────────────────────────────────────────────────┬────────────────────┤
│                   │  ‹ July             AUGUST 2026             September ›   │ WEDNESDAY, AUG 5   │
│   Today           │                                                           │                    │
│ ● Calendar        │   Mon      Tue      Wed      Thu      Fri      Sat   Sun   │ 4h 12m tracked     │
│                   │                                                           │ 3h 06m agents      │
│ REPOSITORIES      │                                      01 ·     02 ·        │ 6 commits          │
│ ▾ Work            │                                                           │ +842 −317          │
│ ▾ Personal        │   03 ▂     04 ▆    [05 █]    06 ▅     07 ▃    08 ·  09 ·  │                    │
│                   │                                                           │ ↑18% vs average    │
│ HISTORY           │   10 ▇     11 █     12 ▅      13 ▂     14 ·    15 ·  16 ·  ├────────────────────┤
│   Search          │                                                           │ SUMMARY            │
│   Reports         │   17 ▄     18 ▆     19 █      20 ▆     21 ▃    22 ·  23 ·  │                    │
│                   │                                                           │ Worked primarily   │
│ SYSTEM            │   24 ·     25 ·     26 ·      27 ·     28 ·    29 ·  30 ·  │ on Trackify’s      │
│   Sources         │                                                           │ repository scanner │
│   Diagnostics     │   31 ·                                                    │ and authentication │
│                   │                                                           │ fixes in client-   │
│                   │   · none   ▂ light   ▅ typical   █ high                   │ api. Repository    │
│                   │                                                           │ discovery remains  │
│                   ├───────────────────────────────────────────────────────────┤ in progress.       │
│                   │ SELECTED DAY                                              │                    │
│                   │                                                           │ [Copy summary]     │
│                   │ 08  09  10  11  12  13  14  15  16                       │ [Open day]         │
│                   │ ▁   ▅   █   ▆   ·   ▂   ▇   ▅   ▃                        │                    │
│                   │                                                           │                    │
│                   │ trackify       2h 38m   3 commits   +514 −181             │                    │
│                   │ client-api     1h 21m   3 commits   +328 −136             │                    │
│                   │ website          13m    0 commits      files inspected     │                    │
└───────────────────┴───────────────────────────────────────────────────────────┴────────────────────┘
```

Calendar intensity reflects tracked work time relative to the user's recent active-day distribution. It is a navigation aid, not a quality score.

## 8. Repository catalog

The catalog handles machines with dozens or hundreds of repositories without filling the sidebar.

```text
┌──────────────────────────────────────────────────────────────────────────┐
│ Repositories                                                Search ⌕    │
├──────────────────────────────────────────────────────────────────────────┤
│ ▾ Work · 38 repositories                                              │
│   client-api          1h 21m today    3 commits    ● active             │
│   internal-tools      42m today       1 commit                          │
│   website             13m today       —                                 │
│   clients/client-a    Last active Aug 4                                 │
│                                                                          │
│ ▾ Personal · 24 repositories                                          │
│   trackify           2h 38m today     3 commits    ● active             │
│   finance-tool       Last active Aug 2                                  │
│   experiments/demo   Last active Jul 29                                 │
│                                                                          │
│ ▸ Other · 3 repositories                                               │
└──────────────────────────────────────────────────────────────────────────┘
```

Behavior:

- Root groups are sorted by configured order.
- Active repositories appear first within a group, followed by recent activity.
- Search matches repository names, aliases, and relative paths.
- Folder paths remain visible when needed to distinguish repositories with similar names.
- Chains of single-child folders are visually collapsed.
- Selecting a repository opens its timeline, reports, commits, files, sessions, and working-copy locations.

## 9. Day detail

The Day view is the full evidence-backed story for one date:

```text
09:00–10:00  IN PROGRESS
Started repository discovery and added the initial scanner.
trackify · 5 files · +143 −12 · Codex session 8f2…

10:00–11:00  IN PROGRESS
Separated Git inspection from filesystem discovery. Tests had
not been completed and the working tree remained dirty.
trackify · 7 files · +184 −32

11:00–12:00  COMPLETED
Finished the scanner, added tests, and created commit e815ba2.
trackify · 1 commit · +92 −21

12:00–13:00  NO ACTIVITY
```

Evidence rows expand on demand. Raw session messages or file lists are not shown by default.

## 10. Search

Search is global and passive:

```text
Search: repository discovery

REPORTS
Aug 5, 15:00 · trackify
Continued implementing repository discovery…

SESSIONS
Aug 5, 09:12 · Codex · trackify
“Implement Git repository discovery…”

COMMITS
Aug 5, 11:47 · e815ba2 · trackify
Add recursive repository scanner

FILES
Sources/TrackifyEngine/RepositoryDiscovery.swift
```

Filters for date, source, repository, and record type are available in the toolbar. There is no semantic search in V1.

## 11. Visual state vocabulary

States should use consistent native labels and icons:

```text
● Active
◐ In progress
✓ Completed
? Investigating
◌ Waiting
· No activity
⚠ Degraded
Ⅱ Paused
```

Actual colors should follow macOS accessibility and appearance settings. Text and icon shape must carry the meaning when color is unavailable.

## 12. V1 UI acceptance criteria

1. The dropdown communicates current activity, today's core statistics, and the latest report without opening the main window.
2. No-activity and degraded-source states remain understandable and honest.
3. Machines with more than 60 repositories do not produce an unusable menu or sidebar.
4. Only recently active repositories appear directly in the sidebar.
5. The complete repository catalog is searchable and grouped by discovery root.
6. Today shows overlapping agent and work activity without double-counting wall-clock time.
7. Calendar navigation exposes inactive days as well as active days.
8. Hourly reports clearly distinguish unfinished, completed, investigating, waiting, and inactive periods.
9. Report and evidence details are progressively disclosed rather than permanently filling the interface.
10. Normal operation requires no manual timer, task, or report maintenance.
11. Guided setup presents one bounded recommendation instead of requiring repository-by-repository configuration.
12. An available direct-install update is visible without obscuring today's work and can be applied with one `Update & Relaunch` action.
13. Update progress, failure, and recovery states are available in Settings and through the same underlying service as the CLI.
