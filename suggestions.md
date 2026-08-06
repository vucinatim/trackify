# Architecture follow-ups

These are deliberate post-V1 improvements, not hidden release blockers. Add them only when real usage demonstrates the need.

1. Replace the 30-minute root reconciliation poll with coalesced filesystem notifications if real use needs lower-latency Git-only updates across 60+ repositories. Keep periodic reconciliation as recovery.
2. Persist hourly/daily rollups only if a real ledger makes the current bounded batch queries perceptibly slow. Migration 1 reserves the cache tables, while the query API remains authoritative, so this does not require UI or CLI changes.
3. Add a versioned local app-control endpoint only when agents genuinely need remote pause/update operations. V1 intentionally avoids an always-listening IPC surface.
4. Add cooperative cancellation tied to app shutdown if real provider runs need it. V1 already enforces process deadlines, terminates the exact child, drains output concurrently, and bounds captured bytes.
5. Add automatic Codex/Claude hook configuration only after their supported configuration contracts stabilize. The current allowlisted `integrations emit` bridge and cache reconciliation already provide a safe integration target.
6. Before public distribution, finish the external release work: workplace fleet confirmation, Developer ID certificate, notarization credentials, Sparkle EdDSA key, signed appcast, SBOM, and a seven-day release-build soak measurement.
7. Add a read-only MCP adapter or provider-specific agent packages only if real usage shows that the versioned CLI JSON contract creates meaningful friction. They should remain thin adapters over the existing domain queries, not a second integration API.
8. Add a repository-specific bounded detail query if real 99-repository usage shows that a quiet project can fall outside the main window's 500 newest timeline entries. Keep Overview totals on complete batched activity snapshots and avoid growing the global UI query without evidence that it is needed.
9. Goal 2's provider queue, recipes, artifacts, usage ledger, privacy profiles, and local destination boundary are implemented. Keep networked Clockify, Slack, email, and social adapters outside the core until their real workflows, credentials, approval defaults, and retry semantics are validated against the existing destination protocol.
10. Add an explicit, recoverable migration-backup retention command before the next schema migration. The current production ledger has five private migration snapshots totaling about 3.3 GB; Trackify should never silently delete them, but users need a safe way to inspect and prune superseded snapshots once a migrated ledger has soaked successfully.
