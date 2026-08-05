# Trackify Vision

The implementation-facing release scope is defined in [V1.md](./V1.md), and the full technical design is defined in [DESIGN.md](./DESIGN.md).

## The idea

Trackify is a private, native macOS work ledger for software development.

It continuously observes the work already happening across local Git repositories and AI coding sessions, turns that evidence into simple statistics and short narrative reports, and makes the resulting history available through both a menu bar application and a command-line interface.

Trackify should make it effortless to answer:

> What did I work on, what changed, how long was meaningful work happening, and where did I leave things?

The goal is not to supervise the user, judge whether a day was good, or invent a scientific definition of productivity. The goal is to create a useful and honest memory of development work.

## Why Trackify should exist

Development work is increasingly fragmented across repositories, branches, terminals, editors, background builds, and long-running AI agents. Existing time trackers generally assume that meaningful work is equivalent to keyboard and mouse activity. Git contribution charts only show committed output. Conversation histories contain valuable context but are isolated by provider and difficult to search as a unified project history.

This leaves several gaps:

- Meaningful work performed by an AI agent may happen while the computer appears idle.
- Features frequently span hours or days and remain unfinished between reporting periods.
- Commits are useful checkpoints, but they are not reliable representations of completed tasks.
- Uncommitted investigation, debugging, refactoring, and failed attempts are part of the work history.
- Reconstructing what happened across Git, Codex, and Claude requires manually searching several disconnected sources.
- It is difficult to produce accurate hourly summaries, timesheet notes, or project handoffs after the fact.

Trackify closes these gaps by preserving a local ledger of evidence and deriving clear, inspectable reports from it.

## Product promise

Trackify will provide:

1. **A live view of today** — current work, tracked time, agent runtime, repositories, commits, changed lines, and recent outcomes.
2. **An honest historical record** — completed work, work still in progress, investigations, waiting periods, and periods with no detected activity.
3. **Short verbal reports** — concise hourly and daily summaries based on observable evidence rather than generic activity claims.
4. **Simple comparisons** — today and each metric compared with a recent moving average, without an opaque productivity formula.
5. **A searchable project memory** — a unified ledger of repository activity and supported AI coding conversations.
6. **A first-class CLI** — every important view of the ledger accessible to humans, scripts, and coding agents.

## The experience

Trackify should feel quiet, immediate, and trustworthy.

Most of the time it lives in the macOS menu bar. A glance should show what is happening now, how the day is progressing, and the latest meaningful summary. A larger native window provides a calendar, detailed timelines, charts, repository history, and search.

The CLI provides the same underlying information in human-readable and structured formats. An agent joining a repository should be able to request recent context without reading every commit and transcript:

```bash
trackify context --repo current --since 14d
```

That command should explain recent work, current unfinished state, important outcomes, and the evidence behind them.

## Principles

### Facts first, interpretation second

Imported evidence and normalized events are the durable record. Statistics, intervals, rollups, and language-model reports are derived views that can be recalculated as the product improves.

### Project activity is not physical activity

Keyboard and mouse idleness must not end a work session while an AI agent, build, test suite, or other meaningful project process is still running. Trackify measures detected project activity, not physical presence at the computer.

### Be honest about unfinished work

Activity does not imply completion. Trackify should say that work was started, continued, investigated, left in progress, or completed only when the evidence supports that language. Periods with no activity should be shown plainly.

### Keep the statistics simple

Trackify should expose intuitive facts: tracked work time, agent runtime, commits, files, lines changed, repositories, sessions, and focus periods. Each metric can be compared with a moving average. A mysterious composite productivity score is not part of the core vision.

### The CLI and GUI are equal clients

The macOS application must not become the only way to access the product. Both interfaces use the same domain model, queries, and local ledger. Anything valuable to the user should eventually be accessible to an agent through the CLI.

### Local by default

The ledger belongs to the user and lives on the user's machine. Source code, transcripts, and derived history should not be uploaded unnecessarily. Language-model integrations receive the smallest useful evidence packet and remain replaceable.

### Quiet automation, visible evidence

Trackify should require little or no manual bookkeeping. At the same time, users must be able to inspect why a report says what it says and trace it back to commits, sessions, files, and events.

### Minimal, extensible architecture

The first implementation should remain small: a native app, a shared Swift package, a CLI, and a local SQLite ledger. Source-specific behavior belongs behind adapters. New collectors, summarizers, and exports should extend stable boundaries instead of accumulating special cases.

## What Trackify is not

Trackify is not intended to be:

- Employee monitoring or surveillance software.
- A keystroke logger.
- A project-management system.
- A replacement for Git, Codex, Claude, or an issue tracker.
- An authority that decides whether a person was productive.
- A system that treats lines of code or commit counts as intrinsically good.
- A manual timer that requires the user to remember to start and stop every task.

Integrations with systems such as Clockify may export Trackify's reports and time intervals later, but Trackify itself remains the evidence-backed development ledger.

## Initial scope

The first useful version should:

- Run as a native macOS menu bar application and launch at login.
- Discover and monitor configured local Git repositories.
- Import supported Codex and Claude sessions from their local caches.
- Generate reports through either an authenticated Codex CLI or Claude Code CLI.
- Backfill real historical evidence from repositories and conversation caches.
- Record normalized activity in a local SQLite ledger.
- Derive tracked work time and agent runtime without relying on machine idleness.
- Produce hourly and daily statistics.
- Generate concise reports that distinguish completed, in-progress, investigating, waiting, and inactive periods.
- Show live daily totals, a timeline, and recent reports.
- Provide a calendar and day-history view.
- Provide a CLI with human-readable and JSON output.
- Provide full-text search and a concise agent-oriented context command.
- Support accelerated, isolated simulations of multi-day activity for development and testing.
- Support secure agent-driven installation from one stable link, leaving only provider login and macOS privacy approvals to the user when required.

## Longer-term direction

Once the ledger and reporting model are dependable, Trackify can grow through focused integrations:

- Clockify-compatible summaries and time exports.
- One-click copying of hourly, daily, or project reports.
- Additional coding-agent and editor adapters.
- Repository grouping into clients, products, or workspaces.
- Issue and pull-request references.
- Optional local summarization models.
- Custom comparison windows and workday definitions.
- Safe import and export of the complete ledger.
- Agent tools that use the ledger for handoffs, retrospectives, and project reorientation.

These additions should build on the ledger rather than expanding Trackify into a general project-management platform.

## What success looks like

Trackify succeeds when:

- The menu bar provides a truthful understanding of the current day in seconds.
- A past day's work can be reconstructed without manually searching repositories and transcripts.
- Hourly summaries remain useful even when work was unfinished or performed mostly by agents.
- An agent can recover recent project context through one predictable CLI command.
- Reports are accurate enough to copy into a timesheet or status update with minimal editing.
- Missing or inactive periods are represented honestly instead of filled with invented narratives.
- The system can add new activity sources without changing its central model.

The product's lasting value is not any individual chart. It is the accumulated, searchable, evidence-backed memory of work.
