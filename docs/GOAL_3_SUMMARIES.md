# Trackify Goal 3: Canonical Work Summaries

Status: Implemented and locally validated
Last updated: 2026-08-14

Summary semantics are versioned as `work-summary-v6`. V6 has one deliberately
simple cadence: Trackify refreshes the not-yet-finalized current-work snapshot
programmatically every 15 minutes, generates one permanent provider-backed
summary for the immediately preceding hour when it contains work, and composes
daily rollups locally. Older missing hours reconcile locally instead of causing
a surprise provider backlog after restart or sleep.
Reports remain independently configurable outputs built from these summaries
and direct evidence.

Goal 3 separates Trackify's automatic understanding of work from user-directed
outputs. It replaces the overloaded legacy `WorkReport` concept with two clear,
one-way paradigms:

```text
evidence ledger -> WorkSummary -> ReportArtifact -> optional destination
```

`WorkSummary` is automatic, canonical, hierarchical, and visible in Overview,
the menu-bar dropdown, and the Activity timeline. `ReportArtifact` is created
from a user-configured template, manually or by a user-configured reporter.
Reports may consume summaries; summaries never consume reports.

## 1. Outcome

After Goal 3:

1. Overview shows a summary for the selected period, never a generic latest
   report.
2. The menu-bar dropdown shows the latest current-work summary.
3. The Activity timeline contains summary checkpoints alongside commits,
   conversations, changes, and tests.
4. Completed active hours use Codex or Claude when the selected provider is
   ready and hourly AI summaries are enabled; otherwise the hour receives an
   honest local fallback.
5. Reports remain user-configured outputs with useful defaults such as
   Clockify, stand-up, and timesheet descriptions.
6. Daily and later weekly summaries cover the complete eligible timeline by
   composing smaller, provenance-backed summaries instead of sampling a few
   recent events.
7. Existing reports and generated artifacts remain readable. Migration starts
   no provider process and never relabels old model output as fresh evidence.

## 2. Product language

### Summary

A summary is Trackify's automatic account of a period of work. Users do not
create templates or reporters for summaries. They can choose the summary
provider policy, pause model generation, inspect provenance, or request a
refresh, but cannot replace the locked evidence and safety prompt.

Visible built-in summary kinds are:

- **Current work** — a programmatic snapshot of the not-yet-finalized work,
  refreshed on quarter-hour boundaries and shown in Overview/menu-bar UI.
- **Hourly summary** — one permanent Codex/Claude summary for each completed
  active clock hour, or an explicitly labelled local fallback.
- **Daily rollup** — a programmatic composition of the day's hourly summaries
  and current snapshot.

Internal segment and chunk summaries provide complete hierarchical coverage.
They appear in Activity as compact checkpoints when useful but do not clutter
the Reports workspace.

### Report

A report is a user-directed rendering for a purpose and audience. Templates,
one-off instructions, scope, schedules, provider overrides, copying, delivery,
and report history belong here. Examples include Clockify entries, stand-up
drafts, Slack updates, emails, and client notes.

Default templates are product conveniences, not canonical summaries. A report
cannot replace the summary displayed on Overview or in the menu-bar dropdown.

## 3. Evidence coverage contract

Every eligible event in a summarized interval must be represented by exactly
one leaf input before a parent summary is generated. Coverage is measured and
persisted; `coveredEventCount` must equal `eligibleEventCount` for a summary to
be eligible as a canonical parent input.

The locally enforced value policy is:

| Evidence | Provider representation |
|---|---|
| User messages | Complete sanitized and redacted text; never silently truncated |
| Git commits | Complete commit message and available line/file statistics |
| Assistant messages | Sanitized and redacted text, bounded per response; truncation is explicit |
| Working-tree events | Branch, clean state, changed files, additions, and deletions |
| Builds and tests | Suite/result/state and available timestamps |
| Other core actions | Allowlisted structured fields and timestamps |
| Statistics | Complete deterministic activity snapshot for the covered period |

“Complete user message” means the entire normalized message after Trackify's
existing security redaction. If a user message cannot fit in one provider
packet, the compiler splits it into ordered fragments and includes every
fragment across packets. It does not discard the tail.

Assistant responses are usually the highest-volume and least-authoritative
input. They may be bounded to a documented limit. The digest records
`originalCharacterCount`, `includedCharacterCount`, and `wasTruncated` so later
generations never mistake a partial response for a complete one.

Coverage is about eligible canonical evidence, not duplicate cache records.
Existing source canonicalization, message alias resolution, reachable-commit
filtering, privacy policy, and redaction run before coverage is calculated.

## 4. Summary hierarchy

The permanent leaf interval is one clock hour in the user's current calendar
and time zone. Empty hours do not invoke a provider. Trackify waits 15 minutes
after an hour closes before finalizing it so local caches have time to flush.

```text
eligible ledger events
  -> bounded ordered chunks
  -> one completed-hour AI summary
  -> programmatic current-work snapshot
  -> programmatic daily rollup
  -> later weekly/monthly summaries
```

Each parent receives all complete child summaries in chronological order and
deterministic statistics for its full period. Child summaries are compressed
interpretations and are labelled as such; commits and direct evidence remain
authoritative. User-configured reports add selected direct anchors when they
consume the hierarchy.

Parent provider packets carry one bounded, project-labelled signal for every
project in every child interval. They do not repeat the child's full evidence-ID
arrays. Exact child links and transitive evidence provenance remain in the local
ledger. This keeps a busy day in one coherent provider call without sampling a
subset or allowing a three-project menu preview to hide a fourth project.

Once an hour has a successful provider-backed summary it is final. Late evidence
remains in the authoritative ledger and is available directly to Reports, but
does not silently change or re-spend the permanent hourly account. A local
fallback may upgrade to one provider-backed revision after availability or
budget recovery. Derived records remain immutable and linked by revision.

## 5. Refresh policy

Summary scheduling is separate from report scheduling.

- At each quarter-hour boundary Trackify refreshes the current programmatic
  snapshot if meaningful evidence exists.
- At `HH:15`, the preceding clock hour is eligible for exactly one built-in AI
  summary if it contains meaningful evidence.
- Quiet hours produce no card and no provider call.
- Missing older hours reconcile locally. Automatic refresh never hunts backward
  for an hour to spend provider work on; historical AI backfill must be an
  explicit user action.
- Daily rollups are always local compositions and never consume model budget.
- Provider unavailability or budget exhaustion creates a visible local fallback
  for that hour without blocking evidence collection.
- A local fallback can upgrade after recovery; a successful AI hour is final.
- Report schedules, manual report generation, prompts, scopes, and provider
  overrides remain completely separate from this built-in cadence.

Meaningful activity is determined from evidence presence and state changes, not
a productivity formula. User messages, commits, project changes, working-tree
changes, builds, and tests are meaningful evidence.

## 6. Provider and fallback policy

Summary generation has one setting:

```text
Automatic | Codex | Claude | Local only
```

Automatic deterministically selects the first ready supported provider. An
explicit provider is never silently replaced by another billable provider. If
the selected provider is missing, unauthenticated, fails, or exceeds a budget,
Trackify creates an honest local summary for that revision and records the
reason. The previous successful model summary may remain the preferred visible
revision until its staleness policy expires.

Model and local implementations return the same structured content:

- full narrative;
- compact narrative written specifically for dense menu-bar display;
- project sections, each with its own narrative, intents, outcomes, open work,
  and blockers;
- project names;
- intents;
- outcomes;
- open work;
- blockers;
- topics;
- evidence references.

The full narrative and project sections may be long enough to preserve the
important work threads; they are not forced into the menu-bar character limit.
The compact narrative is a separate model output, not an arbitrary prefix of
the full text. It should identify the active projects and the most important
current state in roughly two dense sentences.

The UI shows `Codex`, `Claude`, `Programmatic`, `Programmatic rollup`, or
`Local fallback` directly on the card. Provider choice changes quality, not
the existence of the summary feature.

## 7. Storage model

### `work_summaries`

Immutable summary revisions contain:

- stable ID, kind, period, generated time, state, and revision link;
- structured content JSON plus the primary narrative;
- generation source, provider/model, generator/prompt/schema versions;
- source fingerprint and child-summary IDs;
- eligible, covered, truncated-assistant, and chunk counts;
- activity snapshot and evidence provenance.

### `summary_runs`

Summary invocation telemetry is separate from report runs and records queue,
provider, model, token, duration, cost, failure, fallback, fingerprint, and
result summary identifiers. Usage queries aggregate both summary and report
runs without presenting unknown cost as zero.

### `report_run_summaries`

Each configurable report run records the exact immutable summary IDs compiled
into its evidence packet. The artifact therefore remains reproducible even
after later summary revisions are generated.

### Legacy data

Migration imports every legacy `reports` row as a `migrated` `WorkSummary`
revision. It preserves original content, state, provider/model, and evidence
links and records that full coverage is unknown. Normal queries and search show
only the newest revision for an exact period while older revisions remain
addressable by stable ID.
Legacy rows and report artifacts remain untouched for rollback and history.

The two seeded automatic report schedules are disabled because summaries own
that responsibility. User-created report schedules remain unchanged.

## 8. Report input contract

Report generation resolves scope before compilation and receives:

1. all complete canonical summaries overlapping the requested period and
   scope, in chronological order;
2. deterministic statistics for the complete period;
3. direct evidence anchors chosen for verification and very recent uncovered
   work;
4. the immutable report template and optional one-off instructions.

A report packet records summary coverage and direct-evidence selection
separately. Missing or stale summaries are visible in preview and cause the
compiler to include uncovered raw evidence rather than silently omitting it.

## 9. UI and CLI

### Menu bar

The dropdown shows `Current work`, its state, compact narrative, project names,
provider, and generated/staleness time. It never shows a Clockify or other
manual report.

### Overview

The report panel becomes `Summary`. Day mode shows the full summary grouped by
project; broader ranges show the relevant final day summaries. Summary
checkpoints remain part of Activity and search.

### Reports

Reports keeps History, Templates, and Reporters. Automatic hourly/daily summary
reporters disappear from the default experience. Manual and custom scheduled
outputs remain fully configurable.

### CLI

New commands expose the same summary service:

```text
trackify summaries list
trackify summaries show <id>
trackify summaries refresh [--days 1...366]
trackify summaries status
```

`trackify reports ...` continues to manage only user-configured output.
Versioned JSON distinguishes `summary` and `reportArtifact` records.

## 10. Migration sequence

1. Add summary domain types and migration 0009 tables/indexes.
2. Import legacy period reports without invoking providers.
3. Add the full-coverage compiler and deterministic local summary renderer.
4. Add summary provider generation, run telemetry, hierarchy, invalidation,
   budgets, and coordinator.
5. Change report evidence compilation from prior reports to canonical
   summaries.
6. Replace AppModel's `reports` dashboard source with `summaries`.
7. Replace Overview/dropdown wording and selection; add summaries to Activity.
8. Add summary CLI commands and remove automatic-report ambiguity from status.
9. Disable only the two seeded automatic report schedule IDs.
10. Validate migrations, complete coverage, chunking, fallback, hierarchy,
    late evidence, report consumption, UI states, simulation, packaging, and
    live installation.

## 11. Acceptance criteria

Goal 3 is complete only when:

1. Every eligible leaf event is covered, or generation fails closed with an
   explicit coverage error.
2. Tests prove full user-message and commit-message preservation, ordered
   fragmentation, assistant truncation metadata, and privacy redaction.
3. Parent summaries consume every complete child summary for their period.
4. Late evidence creates a new leaf revision and invalidates/rebuilds parents.
5. No provider, provider failure, and budget exhaustion all produce useful
   local summaries without blocking collection.
6. Overview and the menu bar display summaries only.
7. Activity includes summaries with provenance and clear visual distinction.
8. Reports remain separately configurable and consume summary coverage.
9. Legacy reports/artifacts survive migration with no provider invocation.
10. Summary and report usage are both visible and honestly attributed.
11. App and CLI use application services rather than direct SQLite
    reinterpretation.
12. Fixed-clock simulation can generate and inspect two days of hierarchical
    summaries deterministically.
13. The full automated suite, privacy audit, formatting, migration checks,
    packaged universal app, and live local smoke test pass.
