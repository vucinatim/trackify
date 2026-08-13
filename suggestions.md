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

1. Goal 5 event-driven collection is implemented. Keep periodic reconciliation as the recovery authority, and add finer persisted hourly rollups only if longer real-world profiling proves the bounded presentation queries—not collection—to be the bottleneck.
2. Persist hourly/daily rollups only if a real ledger makes the current bounded batch queries perceptibly slow. Migration 1 reserves the cache tables, while the query API remains authoritative, so this does not require UI or CLI changes.
3. Add a versioned local app-control endpoint only when agents genuinely need remote pause/update operations. V1 intentionally avoids an always-listening IPC surface.
4. Add automatic Codex/Claude hook configuration only after their supported configuration contracts stabilize. The current allowlisted `integrations emit` bridge and cache reconciliation already provide a safe integration target.
5. Before public distribution, finish the external release proof: workplace fleet confirmation, one non-notarized first-open drill, signed Sparkle appcast/update, SBOM verification, and a seven-day release-build soak measurement. The permanent EdDSA key is already pinned, stored in the protected release environment, and retained in the owner's macOS Keychain.
6. Add a read-only MCP adapter or provider-specific agent packages only if real usage shows that the versioned CLI JSON contract creates meaningful friction. They should remain thin adapters over the existing domain queries, not a second integration API.
7. Add a repository-specific bounded detail query if real 99-repository usage shows that a quiet project can fall outside the main window's 500 newest timeline entries. Keep Overview totals on complete batched activity snapshots and avoid growing the global UI query without evidence that it is needed.
8. Goal 2's provider queue, recipes, artifacts, usage ledger, privacy profiles, and local destination boundary are implemented. Keep networked Clockify, Slack, email, and social adapters outside the core until their real workflows, credentials, approval defaults, and retry semantics are validated against the existing destination protocol.
9. Add an explicit, recoverable migration-backup retention command before the next schema migration. The accumulated local snapshots were manually cleared after validation, but Trackify should never silently delete future migration backups; users need a safe way to inspect and prune superseded snapshots once a migrated ledger has soaked successfully. Local app installation now retains at most one rollback bundle and build outputs retain none.
10. Retire the legacy `WorkReport` compatibility table after one full schema cycle. New UI and CLI report creation is artifact/run based, while V1 reports remain mirrored only so older queries and migrations keep working. Removing that mirror should be a dedicated, tested migration rather than an opportunistic cleanup.
11. Remove the legacy cadence field from a future report-template schema only when recipe JSON compatibility is intentionally versioned. Scheduled reporters are already the sole runtime scheduling authority; retaining cadence on immutable historical recipe versions for now avoids a destructive compatibility rewrite.
12. Treat exhaustive local-history import as a separate opt-in product feature,
    not part of Goal 4. If real users request it, design it as a resumable,
    cancellable migration with a coverage selector, progress and read-volume
    reporting, disk preflight, checkpointed activation, and explicit retention
    controls. It must reuse the bounded rebuild use case instead of introducing
    another ingestion path.
13. The Codex allowance reader intentionally treats the app-server method as an
    optional adapter capability because that protocol is experimental. Keep the
    provider-credit ledger authoritative for Trackify-owned usage and add a
    Claude allowance adapter only if Claude publishes a similarly supported,
    read-only local usage contract. Do not scrape either provider's human UI.
14. `WorkSummaryKind.segment` now means the stable completed-hour summary at the
    storage boundary. Rename that persisted value only in a future intentional
    schema-version migration; the current presentation and CLI already use
    “hourly summary,” so a cosmetic database rewrite would add risk without
    improving the architecture.
15. Keep historical AI summary backfill an explicit preview-and-confirm workflow
    if it is added. Automatic refresh deliberately reconciles older gaps locally
    and never searches backward for provider work.
