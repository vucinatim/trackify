# Trackify V1 Readiness Checklist

Status: Product source implemented; first-release validation remains
Last updated: 2026-08-11

## 1. Purpose

This is the canonical checklist between product design and implementation. It distinguishes work that must happen before scaffolding, before freezing the first ledger schema, before opening the public repository, and before publishing a signed V1 release.

The checklist is intentionally limited to decisions that prevent security problems, compatibility failures, or expensive architectural rework. It is not a new feature backlog.

## 2. Readiness conclusion

Trackify's V1 source implementation is at release-candidate stage.

The headless ledger, native app, CLI, adapters, reporting, bootstrap, simulation, and bundle tooling are implemented and validated by the repository test suite. Remaining gates are first-release publication, fleet confirmation, elapsed soak measurements, and live-update verification.

The criterion-by-criterion evidence and exact remaining proof are maintained in [V1_ACCEPTANCE_AUDIT.md](./V1_ACCEPTANCE_AUDIT.md).

The remaining external gates are:

1. Confirm the workplace macOS/architecture fleet and run the release-build soak measurement.
2. Publish the first release with the already pinned and protected Sparkle key, then validate first installation, appcast publication, and a signed update.
3. Revisit the provisional-name clearance scope only before promotion beyond the intended workplace-focused V1.

## 3. Decisions completed now

- [x] Keep `Trackify` as the provisional V1 working and workplace name.
- [x] Add a name-clearance checkpoint before broad public promotion or signed release publication.
- [x] Use a native Swift/SwiftUI menu-bar application and shared Swift packages.
- [x] Use SQLite/GRDB as a local, user-owned evidence ledger.
- [x] Keep durable source evidence separate from rebuildable interpretation.
- [x] Use injected wall clocks and explicit cutoffs for collection/backfill/simulation, with one app-owned cadence loop and deterministic scheduled-period policy.
- [x] Use one app-owned scheduler; do not introduce a daemon in V1.
- [x] Keep V1 process coordination minimal: shared queries plus a database-backed collection lease; defer IPC until app-control commands require it.
- [x] Provide an optional provider-neutral normalized lifecycle bridge for low-latency state while keeping persisted caches authoritative for recovery and backfill; defer raw provider-hook adapters and configuration mutation.
- [x] Normalize and deduplicate hook and cache observations through one source-evidence contract.
- [x] Use `~/Library/Application Support/Trackify/` as the canonical data root.
- [x] Target macOS 14 or later provisionally and build Universal 2 release artifacts.
- [x] Distribute a non-App-Sandbox, hardened-runtime, ad-hoc-signed application with EdDSA-pinned updates.
- [x] Use user-only filesystem permissions for the ledger, configuration, hook inbox, backups, and logs.
- [x] Make V1 local-first with no Trackify analytics or automatic crash-report upload.
- [x] Send only bounded, deterministically redacted evidence packets through the explicitly selected report provider.
- [x] Rely on user-only permissions and FileVault for at-rest protection in V1 rather than adding application-level database encryption.
- [x] Define initial background resource budgets and soak-test expectations.
- [x] Keep Clockify export, semantic search, cloud sync, editor plugins, and composite scoring outside V1.

The privacy and data-handling decisions are specified in [PRIVACY_SECURITY.md](./PRIVACY_SECURITY.md).

## 4. Name decision

`Trackify` is acceptable as the provisional name for the workplace-focused V1. A small open-source project can be renamed later, and GitHub repository redirects reduce the mechanical cost.

It is not a strong globally unique public identity. A preliminary search found:

- Existing commercial software using the Trackify name, including [Trackify App](https://www.trackifyapp.com/terms-of-service).
- An exact-name [Trackify VS Code extension](https://marketplace.visualstudio.com/items?itemName=arunp0.trackify) that also tracks code changes and coding activity.

This does not establish that Trackify cannot be used and is not a legal conclusion. It creates a practical discoverability and confusion risk, particularly because the intended public description is close to the VS Code extension's category. Public messaging also should not imply affiliation with Clockify merely because the names feel related.

The [USPTO recommends](https://www.uspto.gov/trademarks/search/federal-trademark-searching) checking exact wording, similar marks, related goods and services, internet usage, and live status as part of clearance. Before a broadly promoted or monetized release:

- [ ] Perform a proper word-mark and similar-mark search in the relevant jurisdictions.
- [ ] Check GitHub, package registries, domains, Mac App Store listings, and general web usage.
- [ ] Decide whether to keep or rename Trackify before filing marks or spending materially on promotion.
- [ ] Recheck the icon silhouette against relevant application marks.
- [ ] Obtain qualified legal advice if the product moves beyond internal/workplace use or creates meaningful commercial exposure.

The current icon and `T` motif remain the V1 direction while the provisional name is in use.

## 5. Before scaffolding

- [x] Product vision and V1 boundary documented.
- [x] Menu-bar and main-window UX documented.
- [x] Repository discovery and automatic grouping documented.
- [x] Codex and Claude report-provider boundaries documented.
- [x] Backfill and accelerated-time simulation documented.
- [x] Agent-driven installation and update delivery documented.
- [x] Application icon and menu-bar template prepared.
- [x] Privacy and network boundaries documented.
- [x] App–CLI process and control ownership documented.
- [x] Provisional macOS and architecture target chosen.
- [ ] Confirm that every intended workplace Mac runs macOS 14 or later.
- [ ] Confirm whether any intended workplace Mac requires Intel support.
- [x] Use `vucinatim/trackify` as the public GitHub repository.
- [x] Use the `com.zoulabs.trackify` reverse-DNS namespace, centralized so it can change before signing if required.
- [x] Deliberately avoid a paid Developer ID dependency for the workplace-focused release.

Scaffolding may begin before the final five items are complete, but identifiers should remain centralized build settings rather than copied literals.

## 6. Compatibility spike before migration 1

This is the highest-priority implementation validation.

### Codex fixtures

- [x] Capture redacted completed turns.
- [x] Capture an active lifecycle with unmatched `task_started` evidence.
- [x] Capture explicit failed, aborted, interrupted, and error record variants.
- [x] Verify session identity, timestamps, working directory, message roles, and lifecycle evidence for the observed version.
- [x] Exclude internal report runs through ephemeral execution plus a defense-in-depth marker.

### Claude Code fixtures

- [x] Capture a redacted completed `end_turn` session record.
- [x] Capture active `tool_use` and a deliberately truncated final record.
- [x] Capture the explicit top-level Claude API-error variant; error-like nested content remains ordinary evidence rather than lifecycle state.
- [x] Verify session identity, timestamps, working directory, message roles, and lifecycle evidence for Claude Code 2.1.29.
- [x] Exclude internal report runs through `--no-session-persistence` plus a defense-in-depth marker.

### Cross-adapter contract

- [x] Define the smallest normalized source-evidence contract both adapters can support honestly.
- [x] Decide which tool payloads are normalized and which are discarded.
- [x] Test file replacement, in-place truncation, duplicates, large streamed histories, and truncated final-line recovery; future provider format versions still require a fixture before support is advertised.
- [x] Prepare only deterministic sanitized fixtures for the public repository.
- [x] Define the hook bridge as a bounded local structural-event path that cannot block provider work or replace cache reconciliation.
- [x] Test synthetic allowlisted Codex and Claude hook envelopes and dual-path hook/cache deduplication without retaining real hook payloads.
- [x] Freeze migration 1 only after both adapters pass their contract fixtures.

V1 does not require identical richness from Codex and Claude. Missing lifecycle signals remain explicit unknowns rather than inferred completions.

## 7. Platform and identity gate

Provisional platform baseline:

```text
Minimum deployment target   macOS 14.0
Release architecture        Universal 2: arm64 + x86_64
Distribution                Ad-hoc signed, not notarized, outside Mac App Store
App Sandbox                 Disabled
Hardened runtime            Enabled
Data root                   ~/Library/Application Support/Trackify/
Default app location        ~/Applications/Trackify.app
Default CLI link            ~/.local/bin/trackify
```

The deployment target favors a modern SwiftUI implementation while remaining broad enough for a mixed workplace fleet. It is provisional until the real fleet is checked. Lowering it later may require an API-availability audit, so the fleet check should happen before significant UI work.

Still required:

- [x] Provisional application bundle identifier: `com.zoulabs.trackify`.
- [x] Provisional CLI signing identifier: `com.zoulabs.trackify.cli`.
- [x] GitHub repository URL: `https://github.com/vucinatim/trackify`.
- [x] Stable V1 installer endpoint: `https://vucinatim.github.io/trackify/install-agent/`; no custom-domain purchase required.
- [x] Generate and pin the final Sparkle key; feed URL is `https://vucinatim.github.io/trackify/appcast.xml`. The private key is held by the protected release environment and the owner's macOS Keychain.
- [x] Fixture baseline: Codex CLI `0.147.0-alpha.1.2` and Claude Code `2.1.29`; support is schema-fingerprint based.

## 8. App–CLI coordination contract

Read-only CLI queries read the SQLite ledger through shared store code. One-shot collection and rebuild operations use a database-backed lease. App-only lifecycle actions remain in the app for V1; there is no always-listening local IPC surface.

Requirements:

- [x] The app remains the only continuous scheduler owner.
- [x] One-shot CLI collection proceeds only after acquiring the database lease.
- [x] UI and CLI business logic stays in shared engine/store use cases.

An IPC endpoint remains a later addition if remote pause/update control becomes a proven need.

## 9. Resource budgets

Initial budgets are acceptance targets, not user configuration:

| Condition | Initial target |
|---|---|
| Idle CPU after startup reconciliation | Below 1% average over 10 minutes on the reference Mac |
| Idle resident memory | Below 150 MB |
| Bounded backfill resident memory | Below 350 MB; import must stream rather than load full history |
| Repository inspection concurrency | Maximum 4 concurrent Git inspections |
| Report-provider concurrency | 1 provider process by default |
| Idle full-root reconciliation | No more often than every 30 minutes; hooks and manual refresh provide lower latency |
| Event burst handling | Debounced and coalesced before Git inspection |
| Database growth | Visible in Diagnostics; backfill estimates required before large imports |
| Network activity | Only update checks and explicitly enabled report-provider calls |

Required validation:

- [x] Measure first-import and incremental Git budgets using the Universal release CLI; results are recorded in [VALIDATION.md](./VALIDATION.md).
- [ ] Run a seven-day soak scenario with at least 60 repositories.
- [ ] Include active agents, no-activity periods, sleep/wake, moved repositories, large working trees, backfill, and provider failure.
- [x] Confirm no unbounded in-memory transcript, filesystem-tree, diff, or report queue; imports stream in capped batches, smart-compiled evidence is capped at 20 KiB, and provider prompts retain a 256 KiB defense-in-depth cap.
- [x] Bound subprocess output and execution time; provider runs use 180-second deadlines, login probes use 5 seconds, and timed-out children are terminated and reaped.
- [ ] Confirm missed work is reconciled after throttling, restart, and sleep.
- [x] Record benchmark hardware and dataset characteristics with each result.

Budget changes require evidence from profiling; they do not become exposed preferences in V1.

## 10. Open-source repository gate

Before making the repository the canonical public project:

- [x] Create the public repository at `https://github.com/vucinatim/trackify`.
- [x] Use Apache-2.0 for code, documentation, and assets; its explicit patent grant and trademark clause fit the project.
- [x] Cover icon assets with Apache-2.0 without granting additional trademark rights.
- [x] Add `README.md`, `LICENSE`, `NOTICE`, `CONTRIBUTING.md`, `SECURITY.md`, and `CODE_OF_CONDUCT.md`.
- [x] Add a clear privacy statement linking to [PRIVACY_SECURITY.md](./PRIVACY_SECURITY.md).
- [x] Add sanitized fixtures and an automated privacy check that rejects personal paths and credential patterns.
- [x] Enable GitHub secret scanning, push protection, and private vulnerability reporting.
- [x] Protect `main`, require pull requests and the fixture-privacy check, enforce linear history and resolved conversations, and block force pushes and deletion.
- [x] Add required Swift build/test, simulation, fixture-privacy, and native bundle checks.
- [x] Release automation references the Sparkle private/public keys only through the protected `release` environment; the permanent key is provisioned there and retained in the owner's macOS Keychain.
- [x] Support the latest stable release line only until explicitly expanded, and use private GitHub vulnerability reporting without promising an unpublished response SLA.
- [x] Generate and attach a SwiftPM dependency SBOM in the protected release workflow; the first published output remains a release operation.

No contributor agreement or DCO is required for the first personal release. Add one only if contribution volume or ownership requirements make it necessary.

## 11. Before signed V1 release

- [ ] All V1 acceptance criteria in [V1.md](./V1.md) pass.
- [x] Compatibility fixtures cover every advertised source version.
- [x] Report redaction and allowlisted diagnostic export tests reject known synthetic secrets and private paths.
- [ ] Resource budgets and seven-day soak test pass.
- [ ] Clean install, upgrade, repair, and uninstall pass on every supported architecture.
- [x] Database migration and private pre-migration backup tests pass from every currently supported schema.
- [ ] App, CLI, manifest, appcast, tag, and release notes report the same version.
- [ ] Hardened-runtime ad-hoc signing, first-open guidance, Sparkle signature, and live update verification pass.
- [x] The user consciously accepted `Trackify` for the intended workplace-focused V1; broader promotion still requires the expanded clearance checklist above.
- [x] The public documentation clearly explains local storage and provider-bound reporting evidence.

## 12. Explicitly not blocking V1

- Clockify integration.
- Cloud or multi-device synchronization.
- Semantic or embedding search.
- Editor-specific plugins.
- Manual timers or task management.
- User-edited reports.
- Composite productivity scoring.
- Team dashboards or employee monitoring.
- Full application-level database encryption.
- Custom workday boundaries beyond local calendar days.
- Beta channels, phased updates, and delta updates.

These may be added behind existing boundaries after real V1 usage demonstrates a need.

## 13. Recommended implementation start

```text
compatibility fixture capture
→ Swift package and CLI scaffold
→ clock, identifiers, store, and migration harness
→ import one Git repository and one session from each provider
→ ingest one lifecycle hook from each provider and reconcile it with the same cached session
→ run a deterministic two-day simulation
→ verify backfill and rebuild idempotency
→ freeze migration 1
→ add the menu-bar UI over shared queries
```

The first meaningful success is not a polished window. It is one real repository plus one Codex and one Claude session producing the same deterministic ledger through live import, backfill, and simulation.
