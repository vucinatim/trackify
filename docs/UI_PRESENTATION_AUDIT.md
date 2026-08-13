# Trackify UI presentation audit

Status: Implemented, installed, and validated
Last updated: 2026-08-14

## 1. Scope and rule

This audit compares every macOS surface with the authoritative domain records it
presents. The surfaces are Overview, Activity, Projects, Reports, Settings, the
menu-bar dropdown, and the menu-bar label. The rule is that the UI must not hide,
rename, or guess state that changes how a user interprets the ledger.

Important metadata must be visible where the corresponding content appears:

- direct AI, deterministic, migrated, and locally rolled-up provenance;
- the user's local period and the evidence/report state;
- complete, partial, or unknown evidence coverage;
- measured versus estimated model usage;
- resolved project names rather than internal identifiers;
- collector freshness, pending work, failures, and application errors; and
- current configuration rather than historical or legacy implementation terms.

## 2. Findings and resolution

### 2.1 Summary provenance and coverage

The Activity summary cards hid provider and model until expansion. Overview and
the menu inferred `Local` from a missing direct provider, which mislabeled
migrated summaries and concealed that local current/day rollups can contain
Codex or Claude child summaries.

All summary surfaces now use one provenance resolver based on
`generationSource`, direct provider/model, and child-summary lineage. Cards show
Codex, Claude, Local, Migrated, or a Local rollup with its underlying AI sources.
Coverage labels now distinguish complete, partial, and unknown coverage and
disclose shortened assistant responses. Activity search also matches provider,
source, state, and provenance.

### 2.2 Time presentation

Summary cards used the local time zone, while provider prompts exposed only UTC
ISO timestamps. This allowed generated prose to describe a different clock
period from the card.

Provider prompts now contain the current macOS time-zone identifier and a
localized display interval, explicitly forbid quoting raw UTC clock values, and
normally ask the model to omit the period because the UI already owns it. The
prompt contract is versioned. Activity cards show the full local start/end
interval rather than only the end time. The Overview chart shows the same pink
current-time marker as the menu chart when today is in range.

### 2.3 Activity and project context

Conversation rows distinguished user and assistant roles but hid whether the
conversation came from Codex or Claude. Project metrics were derived from the
globally capped timeline list, so a quiet or older project could show incomplete
counts without saying so.

Conversation rows now show their provider source. Project metrics are loaded
from a repository-scoped authoritative 42-day activity query and use the same
Evidence hours, LLM turns, and Commits language as Overview. Repository detail
also exposes the branch, short HEAD, selectable path, optional remote identity,
and observation time.

### 2.4 Reports, templates, and scheduled reporters

Several implemented report capabilities were either hidden or lossy in the GUI:

- a failed preview stayed on “Preparing” indefinitely;
- new templates discarded the useful starter instructions;
- template provider and scope were persisted but not editable or visible;
- scheduled group scopes were persisted but not editable;
- a one-project schedule rendered the raw repository ID;
- report token labels did not distinguish measured and estimated input usage;
- template search ignored instructions; and
- the All history view could expose broken internal-envelope legacy artifacts.

Preview loading now has explicit loading, ready, and unavailable states. New
templates retain starter instructions. Template and schedule editors expose
folder group, individual project, and provider selection without erasing an
existing multi-scope configuration. Details resolve names and effective provider
behavior. Token labels are honest about measurement. Search covers names and
instructions. Corrupted/legacy artifacts remain durable and CLI-accessible but
are excluded from the normal GUI; All revisions means valid report revisions.

### 2.5 Usage and provider state

Usage totals included Trackify model work, but the Recent runs list displayed
only user/scheduled reports and omitted automatic summary runs. Provider/source
status used a boolean green/gray treatment that could not distinguish degraded,
permission-denied, unknown, and unavailable states. A provider-test failure was
immediately erased by the refresh that followed it.

Recent runs now merges summary and report runs chronologically and labels type,
provider/model, state, measured/estimated usage, time, and failure detail.
Status colors preserve healthy, uncertain/degraded, and unavailable meanings.
Provider-test failures survive refresh and are visible through the shared app
error surface.

### 2.6 Collection, errors, roots, and freshness

`AppModel.errorMessage` was populated by many operations but never rendered in
the main window. Collection freshness was largely confined to Settings and the
menu dropdown. Discovery-root rows hid enabled state, last scan, and exclusions.

The sidebar now has an always-visible runtime status and last successful update
or pending repository-scope count. A shared banner presents actionable errors
and degraded state in the main window, routes to Settings, and lets transient
errors be dismissed. General settings expose the last successful update,
pending scopes/signals, and typical live latency. Root rows show enabled state,
last scan, path, and exclusion count. Startup is labeled Starting rather than Up
to date while the collector is still stopped.

### 2.7 Shared controls and terminology

MainWindow and Reports had separate search-field implementations, and the menu
called the same metric Active hours while Overview called it Evidence hours.
The implementations could drift in color, padding, clearing behavior, and
meaning.

All searches now use one native shared component. Evidence hours is the product
term on Overview, Projects, and the menu. The selected Overview chart explicitly
labels its more granular bars as Evidence events by hour.

## 3. Deliberate boundaries

- Raw legacy reports and internal transport envelopes are not deleted by a UI
  cleanup. They remain auditable through the ledger and CLI.
- The UI does not claim exact cost when a provider supplies only token usage or
  when subscription billing is unknown.
- A local rollup is not relabeled as directly AI-generated. It discloses the AI
  sources in its child summaries while retaining Local rollup as its own origin.
- Collection notifications remain triggers, not a second user-visible work
  ledger.
- Full repository statistics are loaded only for the selected project rather
  than precomputing 100+ project snapshots on every app refresh.

## 4. Validation gates

- presentation-unit tests for direct, migrated, local, and AI-backed rollup
  provenance;
- presentation-unit tests proving Usage merges automatic summaries and reports;
- provider-process test proving the local time-zone contract reaches the model;
- full Swift test suite and strict formatting;
- fixture privacy and Git whitespace checks;
- focused native validation of Activity, Settings/Usage, Reports/Templates, and
  the menu dropdown at standard and constrained window sizes; and
- installed-app verification against the live ledger without mutating or
  exporting raw conversation content.

All gates passed on build 514. The full Swift suite contains 157 tests in 10
suites. Strict formatting, fixture privacy, shell syntax, and Git whitespace
checks pass. Focused isolated native captures verified Activity, Projects,
Reports templates and reporters, the actual attached New Report and New Template
sheets, Sources, Usage, and Overview. A startup race in the screenshot harness
was found during this inspection and replaced with an explicit model-ready
signal before the final populated captures. Sheet validation then found and
fixed the same class of race in template inheritance: New Report now hydrates
instructions and provider configuration when a selected template finishes
loading, while an explicit regeneration prompt remains untouched. The installed
Universal app passed deep signature verification, launched from
`~/Applications/Trackify.app`, and read the healthy production ledger through
the bundled CLI.
