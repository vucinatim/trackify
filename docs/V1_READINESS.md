# Trackify V1 Readiness Checklist

Status: Ready to scaffold; validation gates remain
Last updated: 2026-08-05

## 1. Purpose

This is the canonical checklist between product design and implementation. It distinguishes work that must happen before scaffolding, before freezing the first ledger schema, before opening the public repository, and before publishing a signed V1 release.

The checklist is intentionally limited to decisions that prevent security problems, compatibility failures, or expensive architectural rework. It is not a new feature backlog.

## 2. Readiness conclusion

Trackify is ready to begin V1 implementation.

The product boundary, user experience, evidence model, time semantics, repository discovery, report providers, installation, updates, simulation, backfill, and visual identity are sufficiently defined. Further speculative feature design should stop until the headless vertical slice is working.

Two implementation gates remain intentionally open:

1. Real Codex and Claude cache fixtures must validate the adapter and source-evidence schema before migration 1 is frozen.
2. The public release identity—name clearance, bundle identifiers, signing identity, domain, and repository license—must be finalized before publishing signed releases.

## 3. Decisions completed now

- [x] Keep `Trackify` as the provisional V1 working and workplace name.
- [x] Add a name-clearance checkpoint before broad public promotion or signed release publication.
- [x] Use a native Swift/SwiftUI menu-bar application and shared Swift packages.
- [x] Use SQLite/GRDB as a local, user-owned evidence ledger.
- [x] Keep durable source evidence separate from rebuildable interpretation.
- [x] Use injected clocks and schedulers for live operation, backfill, and simulation.
- [x] Use one app-owned scheduler; do not introduce a daemon in V1.
- [x] Use a small versioned local Unix socket for app–CLI control operations.
- [x] Use `~/Library/Application Support/Trackify/` as the canonical data root.
- [x] Target macOS 14 or later provisionally and build Universal 2 release artifacts.
- [x] Distribute a non-App-Sandbox, hardened-runtime Developer ID application.
- [x] Use user-only filesystem permissions for the ledger, configuration, runtime socket, backups, and logs.
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
- [x] Select Zou Labs LLC Apple Team `PNTJNS22UU` for the personal public project.
- [ ] Create and install a Developer ID Application certificate for that team; only development certificates are currently present.

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
- [ ] Test file replacement, cache rotation, duplicates, and large version changes during implementation; truncated final-line behavior is fixture-covered.
- [x] Prepare only deterministic sanitized fixtures for the public repository.
- [ ] Freeze migration 1 only after both adapters pass their contract fixtures.

V1 does not require identical richness from Codex and Claude. Missing lifecycle signals remain explicit unknowns rather than inferred completions.

## 7. Platform and identity gate

Provisional platform baseline:

```text
Minimum deployment target   macOS 14.0
Release architecture        Universal 2: arm64 + x86_64
Distribution                Developer ID, notarized, outside Mac App Store
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
- [x] Apple Team ID: `PNTJNS22UU` for Zou Labs LLC.
- [x] GitHub repository URL: `https://github.com/vucinatim/trackify`.
- [x] Stable V1 installer endpoint: `https://vucinatim.github.io/trackify/install-agent/`; no custom-domain purchase required.
- [ ] Generate the final Sparkle key during release-pipeline setup; feed URL is `https://vucinatim.github.io/trackify/appcast.xml`.
- [x] Fixture baseline: Codex CLI `0.147.0-alpha.1.2` and Claude Code `2.1.29`; support is schema-fingerprint based.

## 8. App–CLI control contract

Read-only CLI queries continue to read the SQLite ledger through shared store code. Operations owned by the running application—pause, resume, refresh, update, scheduler state, and graceful shutdown—use a versioned local control endpoint:

```text
~/Library/Application Support/Trackify/Runtime/control.sock
```

Requirements:

- [x] Unix-domain only; no TCP listener or remote API.
- [x] Parent directory mode `0700`; socket accessible only to the current user.
- [x] Versioned request and response envelopes.
- [x] Stable request identifiers for asynchronous operations.
- [x] Bounded message sizes and strict decoding.
- [x] The app remains the only continuous scheduler owner.
- [x] Business logic stays in shared use cases rather than the socket handler.
- [x] If the app is absent, an app-owned operation launches it; one-shot CLI collection may proceed only after acquiring the database lease.
- [ ] Prototype launch, connect, reconnect-after-sleep, stale-socket cleanup, and app-relaunch behavior.
- [ ] Add contract and permission tests before exposing mutating CLI commands.

This control socket is not a daemon and does not contain a second implementation of application behavior.

## 9. Resource budgets

Initial budgets are acceptance targets, not user configuration:

| Condition | Initial target |
|---|---|
| Idle CPU after startup reconciliation | Below 1% average over 10 minutes on the reference Mac |
| Idle resident memory | Below 150 MB |
| Bounded backfill resident memory | Below 350 MB; import must stream rather than load full history |
| Repository inspection concurrency | Maximum 4 concurrent Git inspections |
| Report-provider concurrency | 1 provider process by default |
| Idle full-root reconciliation | No more often than every 15 minutes; event-driven updates remain primary |
| Event burst handling | Debounced and coalesced before Git inspection |
| Database growth | Visible in Diagnostics; backfill estimates required before large imports |
| Network activity | Only update checks and explicitly enabled report-provider calls |

Required validation:

- [ ] Measure and adjust budgets using a release build rather than debug observations.
- [ ] Run a seven-day soak scenario with at least 60 repositories.
- [ ] Include active agents, no-activity periods, sleep/wake, moved repositories, large working trees, backfill, and provider failure.
- [ ] Confirm no unbounded in-memory transcript, filesystem-tree, diff, or report queue.
- [ ] Confirm missed work is reconciled after throttling, restart, and sleep.
- [ ] Record benchmark hardware and dataset characteristics with each result.

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
- [ ] Add required Swift build/test checks when the package is scaffolded.
- [ ] Keep signing, notarization, and Sparkle private keys only in a protected release environment.
- [ ] Define supported-version and security-reporting expectations.
- [ ] Produce an SBOM with signed releases.

No contributor agreement or DCO is required for the first personal release. Add one only if contribution volume or ownership requirements make it necessary.

## 11. Before signed V1 release

- [ ] All V1 acceptance criteria in [V1.md](./V1.md) pass.
- [ ] Compatibility fixtures cover every advertised source version.
- [ ] Privacy packet-redaction tests pass with adversarial secret fixtures.
- [ ] Resource budgets and seven-day soak test pass.
- [ ] Clean install, upgrade, repair, and uninstall pass on every supported architecture.
- [ ] Database migration and recovery tests pass from every supported schema.
- [ ] App, CLI, manifest, appcast, tag, and release notes report the same version.
- [ ] Developer ID signing, hardened runtime, notarization, stapling, Gatekeeper, and Sparkle verification pass.
- [ ] The name gate is consciously accepted for the intended release scope.
- [ ] The public documentation clearly explains local storage and provider-bound reporting evidence.

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
→ run a deterministic two-day simulation
→ verify backfill and rebuild idempotency
→ freeze migration 1
→ add the menu-bar UI over shared queries
```

The first meaningful success is not a polished window. It is one real repository plus one Codex and one Claude session producing the same deterministic ledger through live import, backfill, and simulation.
