# Architecture follow-ups

## Goal 3 implementation notes

- Keep `WorkSummary` and `ReportArtifact` as separate persisted aggregates.
  Sharing provider adapters, usage accounting, and evidence utilities is good;
  sharing lifecycle or presentation semantics is not.
- Retire the legacy `reports` table only in a future major migration after at
  least one released rollback window. Goal 3 stops writing it but preserves it
  as migrated source history.
- If real ledgers regularly require multi-call leaf chunking, introduce a
  provider-side prompt cache only through a provider-neutral adapter contract;
  do not leak provider cache semantics into summary identity.

These are deliberate post-V1 improvements, not hidden release blockers. Add them only when real usage demonstrates the need.

1. The event-driven collection work has been promoted from an optional follow-up to the planned [Goal 5 specification](docs/GOAL_5_LIVE_EVIDENCE.md). Periodic reconciliation remains the recovery authority.
2. Persist hourly/daily rollups only if a real ledger makes the current bounded batch queries perceptibly slow. Migration 1 reserves the cache tables, while the query API remains authoritative, so this does not require UI or CLI changes.
3. Add a versioned local app-control endpoint only when agents genuinely need remote pause/update operations. V1 intentionally avoids an always-listening IPC surface.
4. Add cooperative cancellation tied to app shutdown if real provider runs need it. V1 already enforces process deadlines, terminates the exact child, drains output concurrently, and bounds captured bytes.
5. Add automatic Codex/Claude hook configuration only after their supported configuration contracts stabilize. The current allowlisted `integrations emit` bridge and cache reconciliation already provide a safe integration target.
6. Before public distribution, finish the external release work: workplace fleet confirmation, Developer ID certificate, notarization credentials, Sparkle EdDSA key, signed appcast, SBOM, and a seven-day release-build soak measurement.
7. Add a read-only MCP adapter or provider-specific agent packages only if real usage shows that the versioned CLI JSON contract creates meaningful friction. They should remain thin adapters over the existing domain queries, not a second integration API.
8. Add a repository-specific bounded detail query if real 99-repository usage shows that a quiet project can fall outside the main window's 500 newest timeline entries. Keep Overview totals on complete batched activity snapshots and avoid growing the global UI query without evidence that it is needed.
9. Goal 2's provider queue, recipes, artifacts, usage ledger, privacy profiles, and local destination boundary are implemented. Keep networked Clockify, Slack, email, and social adapters outside the core until their real workflows, credentials, approval defaults, and retry semantics are validated against the existing destination protocol.
10. Add an explicit, recoverable migration-backup retention command before the next schema migration. The accumulated local snapshots were manually cleared after Goal 3 validation, but Trackify should never silently delete future backups; users need a safe way to inspect and prune superseded snapshots once a migrated ledger has soaked successfully.
11. Retire the legacy `WorkReport` compatibility table after one full schema cycle. New UI and CLI report creation is artifact/run based, while V1 reports remain mirrored only so older queries and migrations keep working. Removing that mirror should be a dedicated, tested migration rather than an opportunistic cleanup.
12. Remove the legacy cadence field from a future report-template schema only when recipe JSON compatibility is intentionally versioned. Scheduled reporters are already the sole runtime scheduling authority; retaining cadence on immutable historical recipe versions for now avoids a destructive compatibility rewrite.
13. Treat exhaustive local-history import as a separate opt-in product feature,
    not part of Goal 4. If real users request it, design it as a resumable,
    cancellable migration with a coverage selector, progress and read-volume
    reporting, disk preflight, checkpointed activation, and explicit retention
    controls. It must reuse the bounded rebuild use case instead of introducing
    another ingestion path.
14. The Codex allowance reader intentionally treats the app-server method as an
    optional adapter capability because that protocol is experimental. Keep the
    provider-credit ledger authoritative for Trackify-owned usage and add a
    Claude allowance adapter only if Claude publishes a similarly supported,
    read-only local usage contract. Do not scrape either provider's human UI.
